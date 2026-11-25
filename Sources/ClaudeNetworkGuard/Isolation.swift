import AppKit
import BoundTransport
import Foundation
import GuardCore

/// 受限组内自检的结果。每次启动和恢复前都会主动尝试从其他线路联网。
struct IsolationProof: Decodable, Equatable, Sendable {
    let gid: Int
    let tcp: String
    let tcpForced: String
    let relay: String?
    let udp: String
    let quic: Bool
    let quicForced: Bool
    let lan: Bool?
    let ipv6: Bool
    /// 连得上公共 DNS 的 TCP 53，说明进程级限制没管住它。
    var dnsTCP: Bool? = nil
    /// 自检是否在进程级限制下运行；不支持限制的应用，裸 UDP 只提示不拦截启动。
    var confined: Bool? = nil
    var locked: Bool? = nil

    struct Row: Identifiable, Sendable {
        let id: String
        let passed: Bool
        let detail: String
        var blocking = true
    }

    /// usb 为绑定网卡测得的 USB 出口，other 为 Mac 默认线路出口。
    func rows(usb: String, other: String) -> [Row] {
        [
            Row(id: "TCP 默认路径", passed: tcp == usb || (locked == true && tcp.isEmpty),
                detail: tcp.isEmpty ? (locked == true ? "已拒绝（锁死模式）" : "未连通") : "出口 \(tcp)"),
            Row(id: "TCP 强行绑定原线路", passed: tcpForced.isEmpty || tcpForced == usb,
                detail: tcpForced.isEmpty ? "已拒绝" : tcpForced == usb ? "被改回 USB" : "泄漏到 \(tcpForced)"),
            Row(id: "本机转发器", passed: relay == usb, detail: relay.flatMap { $0.isEmpty ? nil : "出口 \($0)" } ?? "未连通"),
            Row(id: "QUIC / HTTP3", passed: !quic && !quicForced, detail: quic || quicForced ? "原线路仍可用" : "已封锁"),
            Row(id: "局域网直连", passed: lan != true, detail: lan == true ? "仍可直连" : "已封锁"),
            Row(id: "IPv6", passed: !ipv6, detail: ipv6 ? "仍可直连" : "已封锁"),
            Row(id: "DNS（TCP 53）", passed: dnsTCP == false, detail: dnsTCP == nil ? "没有测" : dnsTCP == true ? "仍可连接" : "已封锁", blocking: confined != false),
            Row(id: "其他 UDP", passed: udp.isEmpty || udp == usb,
                detail: udp.isEmpty ? "已拒绝" : udp == usb ? "出口为 USB" : confined == false
                    ? "它不支持进程级限制，由审计发现后封锁" : "泄漏到 \(udp)", blocking: confined != false)
        ]
    }

    func passed(usb: String, other: String) -> Bool {
        usb != other && rows(usb: usb, other: other).allSatisfy { $0.passed || !$0.blocking }
    }
}

struct LineExit: Equatable, Sendable {
    let address: String
    let country: String?

    static func read(interface: String?) async -> Self? {
        await Task.detached(priority: .userInitiated) {
            for url in ["https://1.1.1.1/cdn-cgi/trace", "https://1.0.0.1/cdn-cgi/trace"] {
                var body = [CChar](repeating: 0, count: 8192)
                guard guard_https_get(url, interface, nil, 6000, &body, body.count) == 1 else { continue }
                var values: [String: String] = [:]
                for line in String(cString: body).split(separator: "\n") {
                    let parts = line.split(separator: "=", maxSplits: 1)
                    if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
                }
                guard let ip = values["ip"] else { continue }
                return Self(address: ip, country: values["loc"].flatMap { $0.count == 2 && $0 != "XX" ? $0 : nil })
            }
            return nil
        }.value
    }
}

@MainActor
final class IsolationModel: ObservableObject {
    @Published private(set) var status: ControlStatus?
    @Published private(set) var lines: [USBLine] = []
    @Published private(set) var installing = false
    @Published private(set) var message: String?
    @Published var strictDNS = UserDefaults.standard.object(forKey: "strictDNS") as? Bool ?? true {
        didSet { UserDefaults.standard.set(strictDNS, forKey: "strictDNS") }
    }
    /// 锁死模式：只允许经转发器联网。
    @Published var lockdown = UserDefaults.standard.bool(forKey: "lockdown") {
        didSet { UserDefaults.standard.set(lockdown, forKey: "lockdown") }
    }
    /// 受保护应用最近一次有数据往来的时间。随 status 一起刷新，不单独通知界面。
    private(set) var trafficAt: Date?
    /// 用户放行的内网地址，原样保存；启动时不合格就拒绝启动。
    @Published var allowedText = UserDefaults.standard.string(forKey: "allowedHosts") ?? "" {
        didSet { UserDefaults.standard.set(allowedText, forKey: "allowedHosts") }
    }
    var allowed: [AllowedHost]? { AllowedHost.parse(allowedText) }
    private var task: Task<Void, Never>?
    private var knownEvents: Set<UUID>?
    var onEvent: ((ControlStatus.Event) -> Void)?

    /// 安装脚本在 App 包内；组件版本必须与 App 一致。
    var installed: Bool { status != nil }
    var current: Bool { status?.version == GuardContract.version }
    var ready: Bool { installed && current }

    #if DEBUG
    func preview(_ status: ControlStatus?) { self.status = status }
    #endif

    func monitor() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func refresh() async {
        let (next, usb) = await Task.detached(priority: .utility) {
            (try? ControlClient.send(.init(.status), timeout: 5), USBLine.interfaces().compactMap(USBLine.read))
        }.value
        if let next, let old = status, next.state == .armed, next.upload + next.download + next.redirected > old.upload + old.download + old.redirected {
            trafficAt = Date()
        } else if next?.state != .armed { trafficAt = nil }
        if status != next { status = next }
        if lines != usb { lines = usb }
        guard let next else { return }
        let ids = Set(next.events.map(\.id))
        if let knownEvents { for event in next.events where !knownEvents.contains(event.id) { onEvent?(event) } }
        knownEvents = ids
    }

    nonisolated static func command(_ request: ControlRequest) async throws -> ControlStatus {
        try await Task.detached(priority: .userInitiated) { try ControlClient.send(request) }.value
    }

    func install() { administer("install-component.sh", done: "隔离组件已安装。") }
    func uninstall() { administer("uninstall-component.sh", done: "隔离组件已移除。") }

    private func administer(_ script: String, done: String) {
        guard !installing, let path = Bundle.main.url(forResource: script, withExtension: nil)?.path,
              let tools = Bundle.main.executableURL?.deletingLastPathComponent().path else {
            message = "App 不完整，请重新安装。"
            return
        }
        installing = true
        message = nil
        Task {
            func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let command = "/bin/bash " + quoted(path) + " " + quoted(tools) + " \(getuid())"
            let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let source = "do shell script \"\(literal)\" with prompt \"Claude Network Guard 需要管理员授权来管理网络隔离组件。\" with administrator privileges"
            let result = await NativeDiagnostics.command("/usr/bin/osascript", ["-e", source], timeout: 180)
            let text = result?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            message = result?.status == 0 ? done : text.isEmpty ? "没有完成，可能取消了授权。" : text
            await refresh()
            installing = false
        }
    }

    /// 在受限组内运行自检程序。
    nonisolated static func prove(usb: String, other: String, port: UInt16, confined: Bool, locked: Bool) async -> IsolationProof? {
        guard let result = await NativeDiagnostics.command(GuardContract.runner, [GuardContract.checker, usb, other, String(port)], timeout: 60,
                                                           environment: confined ? (locked ? ["GUARD_CONFINE": "", "GUARD_LOCK": "1"] : ["GUARD_CONFINE": ""]) : [:]),
              result.status == 0 else { return nil }
        var proof = try? JSONDecoder().decode(IsolationProof.self, from: Data(result.text.utf8))
        proof?.confined = confined
        proof?.locked = locked
        return proof
    }

    /// 以受限组身份启动应用主程序。返回的 PID 就是应用自己的 PID。
    nonisolated static func launch(_ target: TargetProfile, port: UInt16?, locked: Bool = false, extra: [String] = []) throws -> pid_t {
        var arguments = [target.identity.executable]
        if target.usesChromium {
            if let port { arguments.append("--proxy-server=http://127.0.0.1:\(port)") }
            arguments += ["--disable-quic", "--force-webrtc-ip-handling-policy=disable_non_proxied_udp"]
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: GuardContract.runner)
        process.arguments = arguments + extra
        var environment = ProcessInfo.processInfo.environment
        if target.canConfine { environment["GUARD_CONFINE"] = target.usesChromium ? target.path + "/Contents/Frameworks" : "" }
        if let port {
            environment["GUARD_PROXY"] = String(port)
            if target.canConfine, locked { environment["GUARD_LOCK"] = "1" }
        }
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process.processIdentifier
    }

    nonisolated static func explain(_ code: String) -> String {
        switch code {
        case "line_missing", "line_lost": "线路已断开"
        case "line_changed": "线路的网卡或地址已变化"
        case "path_changed": "Mac 的默认线路已变化"
        case "relay_exited", "relay_failed": "USB 转发器未能运行"
        case "rules_tampered": "防火墙规则被其他程序清空或关闭，约 1 秒内可能有请求走了原线路"
        case "pf_lost", "pf_load_failed", "enforce_failed", "pf_enable_failed": "系统防火墙规则无法生效"
        case "pf_anchor_missing": "系统防火墙配置缺少标准入口，可能被其他软件改动"
        case "not_iphone_usb": "没有识别到 iPhone USB 网络"
        case "no_separate_path": "Mac 没有独立于 USB 的默认网络"
        case "not_default_path": "所选线路不是 Mac 当前的默认线路"
        case "members_running": "Claude 仍在保护中运行"
        case "mode_mismatch": "上一场会话的进程尚未退出"
        case "daemon_restarted", "daemon_stopped": "隔离守护进程重启过"
        case "user_blocked": "已手动断网"
        case "exit_changed": "公网 IP 和你认可的不一样了"
        case "invalid_allowed": "允许的内网地址写得不对"
        case "shield_load_failed": "无法装载对保护外软件的拦截规则"
        default: code
        }
    }
}
