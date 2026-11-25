import BoundTransport
import Foundation

/// 启动前对所选线路的一次检查。通过后由用户去网站核对，再决定认可不认可这个 IP。
struct LineCheck: Equatable, Sendable {
    static let lifetime: TimeInterval = 600

    let mode: NativeProtectionMode
    let date: Date
    var address: String?
    var country: String?
    /// 没有通过的原因；nil 表示 Guard 自己的检查都通过。
    var problem: String?

    func usable(for mode: NativeProtectionMode, now: Date) -> Bool {
        self.mode == mode && problem == nil && address != nil && now.timeIntervalSince(date) < Self.lifetime
    }

    /// 只经 USB 网卡读取，不碰 Mac 的默认线路。
    static func usb(lines: [String], region: String?) async -> Self {
        var check = Self(mode: .usb, date: Date())
        guard lines.count == 1, let interface = lines.first else {
            check.problem = lines.isEmpty ? "没有识别到 iPhone USB。请插好数据线、解锁手机并打开个人热点。" : "同时识别到多台 iPhone，请只保留一台。"
            return check
        }
        async let first = LineExit.read(interface: interface)
        async let backups = LineExit.backups(interface: interface)
        let (main, others) = await (first, backups)
        check.address = main?.address
        check.country = main?.country
        check.problem = problem(main: main, others: others, region: region)
        return check
    }

    static func problem(main: LineExit?, others: [String], region: String?) -> String? {
        guard let main else { return "USB 已连接，但没读到公网 IP。请检查手机信号。" }
        if others.isEmpty { return "只有一个来源读到了公网 IP，没法互相核对。请再试一次。" }
        if others.contains(where: { $0 != main.address }) { return "几个来源读到的公网 IP 不一样，没法确定是哪一个。" }
        if let region, main.country != region { return "出口地区是\(main.country ?? "未知")，和你要求的\(region)不一样。" }
        return nil
    }
}

/// 用户在网站上看过、亲自认可的 IP。每种线路记一个，24 小时内有效，IP 一变就不算数。
struct ApprovedLine: Codable, Equatable {
    static let lifetime: TimeInterval = 24 * 3600
    private static let key = "approvedLines"

    let mode: String
    let address: String
    let date: Date

    func covers(_ mode: NativeProtectionMode, _ address: String?, now: Date) -> Bool {
        self.mode == mode.rawValue && address == self.address && now.timeIntervalSince(date) >= 0 && now.timeIntervalSince(date) < Self.lifetime
    }

    static func load(_ defaults: UserDefaults = .standard) -> [Self] {
        (defaults.data(forKey: key)).flatMap { try? JSONDecoder().decode([Self].self, from: $0) } ?? []
    }

    static func save(_ lines: [Self], _ defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(lines), forKey: key)
    }
}

extension LineExit {
    static func backups(interface: String) async -> [String] {
        await withTaskGroup(of: String?.self) { group in
            for url in ["https://checkip.amazonaws.com/", "https://api.ipify.org/"] {
                group.addTask {
                    await Task.detached {
                        var body = [CChar](repeating: 0, count: 256)
                        guard guard_https_get(url, interface, nil, 6000, &body, body.count) == 1 else { return nil }
                        return IPFamily.v4.normalizedAddress(String(cString: body).trimmingCharacters(in: .whitespacesAndNewlines))
                    }.value
                }
            }
            var result: [String] = []
            for await value in group { if let value { result.append(value) } }
            return result
        }
    }
}

enum SiteBrowser {
    /// 用来在 USB 里临时打开检测网站的浏览器。用全新的空白资料目录，不碰用户自己的窗口、登录和插件。
    static let candidates = ["Google Chrome", "Microsoft Edge", "Brave Browser", "Chromium", "Vivaldi"]

    static func find() -> URL? {
        candidates.map { URL(fileURLWithPath: "/Applications/\($0).app") }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func arguments(profile: String) -> [String] {
        ["--user-data-dir=\(profile)", "--no-first-run", "--no-default-browser-check", "--disable-sync", "--disable-extensions",
         "--disable-background-networking", "--disable-component-update", ThirdPartyCheck.url.absoluteString]
    }
}

/// 用户主动点了才做：从所选线路连一次 Claude，看它能不能用、看到的是哪个 IP。
struct ServiceProbe: Equatable, Sendable {
    enum Verdict: Equatable, Sendable { case usable, refused(Int), unreachable, differentExit }

    let address: String
    let date: Date
    let verdict: Verdict

    static func run(interface: String?, expected: String) async -> Self {
        await Task.detached(priority: .userInitiated) {
            var body = [CChar](repeating: 0, count: 8192)
            var seen: String?
            if guard_https_get("https://claude.ai/cdn-cgi/trace", interface, nil, 8000, &body, body.count) == 1 {
                seen = String(cString: body).split(separator: "\n").first { $0.hasPrefix("ip=") }.map { String($0.dropFirst(3)) }
            }
            let status = Int(guard_https_status("https://api.anthropic.com/v1/models", interface, nil, 8000, &body, body.count))
            return Self(address: expected, date: Date(), verdict: judge(seen: seen, expected: expected, status: status, body: String(cString: body)))
        }.value
    }

    /// 没带密钥时，正常的回答是“需要密钥”（401）。
    static func judge(seen: String?, expected: String, status: Int, body: String) -> Verdict {
        if let seen, seen != expected { return .differentExit }
        if status == 0 { return .unreachable }
        if status == 401, body.contains("authentication_error"), seen == expected { return .usable }
        if status == 401, seen == nil { return .unreachable }
        return .refused(status)
    }

    var text: String {
        switch verdict {
        case .usable: "能连上，看到的就是这个 IP"
        case .refused(let code): "被拒绝（HTTP \(code)），可能是地区或 IP 不允许"
        case .unreachable: "连不上或没读全"
        case .differentExit: "看到的是另一个 IP"
        }
    }

    var tone: StatusTone {
        switch verdict {
        case .usable: .positive
        case .refused, .differentExit: .failed
        case .unreachable: .warning
        }
    }
}
