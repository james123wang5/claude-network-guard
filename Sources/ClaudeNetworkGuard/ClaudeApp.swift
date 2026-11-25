import AppKit
import Foundation

/// Guard 只管一个应用：Anthropic 签名的 Claude Desktop。
enum ClaudeApp {
    static let bundleID = "com.anthropic.claudefordesktop"
    static let teamID = "Q6L2SF6YDW"
    static let hosts = ["claude.ai", "claude.com", "anthropic.com", "claudeusercontent.com"]

    enum Status: Equatable {
        case searching
        case missing
        case untrusted(String)
        case ready(TargetProfile)

        var profile: TargetProfile? { if case .ready(let profile) = self { profile } else { nil } }
    }

    /// 优先用「应用程序」里的；别处的副本只在那里没有时才考虑。
    @MainActor static func locate() -> URL? {
        let usual = URL(fileURLWithPath: "/Applications/Claude.app", isDirectory: true)
        if Bundle(url: usual)?.bundleIdentifier == bundleID { return usual }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func inspect(_ url: URL) -> Status {
        guard let profile = try? TargetProfile.inspect(url, hosts: hosts) else { return .untrusted("这个 Claude 不完整，读不到它的信息。") }
        return judge(profile)
    }

    static func judge(_ profile: TargetProfile) -> Status {
        guard profile.identity.bundleID == bundleID else { return .untrusted("找到的应用不是 Claude Desktop。") }
        guard profile.identity.signatureValid, profile.identity.teamID == teamID else {
            return .untrusted("它不是 Anthropic 签名的原版，或者文件被改动过。")
        }
        return .ready(profile)
    }

    @MainActor static var running: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
    }
}
