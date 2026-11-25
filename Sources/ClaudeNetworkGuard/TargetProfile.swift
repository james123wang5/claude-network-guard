import AppKit
import Darwin
import Foundation
import Security

enum GuardPaths {
    static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude Network Guard", isDirectory: true)
    static let watchdogLog = support.appendingPathComponent("logs/watchdog-events.jsonl")
}

/// 一个应用的身份：路径、签名、内置组件。
struct TargetProfile: Codable, Equatable, Sendable {
    struct Identity: Codable, Equatable, Sendable {
        let bundleID: String
        let executable: String
        let signingID: String?
        let teamID: String?
        let codeHash: String?
        let signatureValid: Bool

        /// 同一开发团队签名的新版本视为同一应用；没有团队签名的应用仍要求代码哈希一致。
        func accepts(_ current: Self) -> Bool {
            guard bundleID == current.bundleID, executable == current.executable, signingID == current.signingID,
                  teamID == current.teamID, signatureValid == current.signatureValid else { return false }
            return codeHash == current.codeHash || (teamID != nil && current.signatureValid)
        }
    }

    let path: String
    let displayName: String
    let identity: Identity
    let helpers: [Identity]
    var serviceHosts: [String]

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    enum Invalid: LocalizedError {
        case bundle, host, changed
        var errorDescription: String? {
            switch self {
            case .bundle: "读不到这个应用的身份信息。"
            case .host: "服务域名格式不对。"
            case .changed: "Claude 的签名或位置变了，请重新打开 Guard 再试。"
            }
        }
    }

    /// Chromium / Electron 应用支持代理参数，可以避免 QUIC 和系统 DNS。
    var usesChromium: Bool {
        let frameworks = url.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: frameworks, includingPropertiesForKeys: nil)) ?? []
        return items.contains { item in
            item.pathExtension == "framework" &&
                (FileManager.default.fileExists(atPath: item.appendingPathComponent("Resources/icudtl.dat").path) ||
                 FileManager.default.fileExists(atPath: item.appendingPathComponent("Versions/Current/Resources/icudtl.dat").path))
        }
    }

    /// 自带 App Sandbox 的应用（多为 App Store 版）不能再套一层进程级限制。
    var canConfine: Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var properties: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &properties) == errSecSuccess,
              let info = properties as? [String: Any] else { return false }
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        return (entitlements?["com.apple.security.app-sandbox"] as? Bool) != true
    }

    static func normalizedHosts(_ input: String) throws -> [String] {
        let values = input.lowercased().split { $0.isWhitespace || $0 == "," || $0 == "，" }.map(String.init)
        guard values.count <= 8, values.allSatisfy({ host in
            host.utf8.count <= 253 && host.range(
                of: #"^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$"#,
                options: .regularExpression) != nil
        }) else { throw Invalid.host }
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    static func inspect(_ input: URL, hosts: [String] = []) throws -> Self {
        let url = input.resolvingSymlinksInPath().standardizedFileURL
        guard input.isFileURL, url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url), let root = inspectBundle(url),
              root.bundleID != Bundle.main.bundleIdentifier else { throw Invalid.bundle }
        let title = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        let contents = url.appendingPathComponent("Contents", isDirectory: true).resolvingSymlinksInPath()
        let candidates = FileManager.default.enumerator(at: contents,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsHiddenFiles])
        var helpers: [Identity] = []
        if let candidates {
            for case let item as URL in candidates {
                guard helpers.count < 64 else { break }
                if (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
                guard ["app", "xpc", "appex"].contains(item.pathExtension.lowercased()),
                      let helper = inspectBundle(item.resolvingSymlinksInPath()),
                      helper.executable.hasPrefix(contents.path + "/") else { continue }
                helpers.append(helper)
            }
        }
        return Self(path: url.path, displayName: title, identity: root,
                    helpers: helpers.sorted { $0.executable < $1.executable }, serviceHosts: hosts)
    }

    func checked() throws -> Self {
        let values = try Self.normalizedHosts(serviceHosts.joined(separator: " "))
        let current = try Self.inspect(url, hosts: values)
        guard current.path == path, identity.accepts(current.identity) else { throw Invalid.changed }
        return current
    }

    private static func inspectBundle(_ url: URL) -> Identity? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
              id.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$"#, options: .regularExpression) != nil,
              let executable = bundle.executableURL?.resolvingSymlinksInPath().standardizedFileURL.path,
              executable.hasPrefix(url.path + "/"), FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        var code: SecStaticCode?
        _ = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        var properties: CFDictionary?
        if let code { _ = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &properties) }
        let info = properties as? [String: Any]
        let valid = code.map { SecStaticCodeCheckValidity($0, [], nil) == errSecSuccess } ?? false
        let hash = (info?[kSecCodeInfoUnique as String] as? Data)?.map { String(format: "%02x", $0) }.joined()
        return Identity(bundleID: id, executable: executable,
                        signingID: info?[kSecCodeInfoIdentifier as String] as? String,
                        teamID: info?[kSecCodeInfoTeamIdentifier as String] as? String,
                        codeHash: hash, signatureValid: valid)
    }
}

final class AppSessionLock {
    private let descriptor: Int32
    init?() {
        let run = GuardPaths.support.appendingPathComponent("run", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return nil }
        let fd = Darwin.open(run.appendingPathComponent("app-session.lock").path,
                             O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); return nil }
        descriptor = fd
    }

    deinit { Darwin.close(descriptor) }
}
