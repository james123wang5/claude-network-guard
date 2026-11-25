import AppKit
import Darwin
import Foundation
import GuardCore

/// 一条提醒。只在用得上时出现，每条都说清楚怎么办。
struct Reminder: Identifiable, Equatable {
    enum Action: Equatable { case component, quitClaude, download, help }

    let id: String
    let tone: StatusTone
    let title: String
    let detail: String
    var action: Action?

    /// 启动之前。
    static func beforeStart(claude: ClaudeApp.Status, running: Bool, installed: Bool, current: Bool, mode: NativeProtectionMode, around: Surroundings) -> [Reminder] {
        var list: [Reminder] = []
        switch claude {
        case .missing:
            list.append(.init(id: "missing", tone: .failed, title: "没有找到 Claude Desktop", detail: "先装到「应用程序」里。网页版和终端里的 claude 不归这里管。", action: .download))
        case .untrusted(let reason):
            list.append(.init(id: "untrusted", tone: .failed, title: "这个 Claude 不能用", detail: reason + "请从官网重新安装。", action: .download))
        case .searching, .ready: break
        }
        guard mode != .current else { return list }
        if !installed {
            list.append(.init(id: "component", tone: mode == .usb ? .failed : .warning, title: "还没安装隔离组件",
                              detail: mode == .usb ? "USB 专线必须有它。装一次就行，要输一次 Mac 密码。" : "没有它，线路出问题时只能退出 Claude，中间可能短暂走别的线路。", action: .component))
        } else if !current {
            list.append(.init(id: "outdated", tone: .failed, title: "隔离组件要更新", detail: "和这个版本的 Guard 不配套，更新后才能启动。要输一次 Mac 密码。", action: .component))
        }
        if running {
            list.append(.init(id: "running", tone: .warning, title: "Claude 正开着", detail: "要从这里启动才受保护，所以先完全退出（⌘Q）。只关窗口不算退出。", action: .quitClaude))
        }
        if around.systemProxy {
            list.append(.init(id: "proxy", tone: mode == .usb ? .warning : .failed, title: "开着系统代理",
                              detail: mode == .usb ? "Claude 不会走它。但里面写死了代理端口的命令可能从代理出去，建议先关掉。" : "没法确认流量走哪条线，这种情况不会启动。请先在代理软件里关掉系统代理。"))
        }
        if around.dnsProxy {
            list.append(.init(id: "dns", tone: .warning, title: "有软件接管了域名查询（DNS）",
                              detail: "常见于公司或学校的安全软件。到「系统设置 › 网络 › 过滤条件与代理」看看有没有“DNS 代理”。它可能让少量域名查询不走所选线路。", action: .help))
        }
        if around.otherClaude > 0 {
            list.append(.init(id: "terminal", tone: .warning, title: "终端或编辑器里开着 claude",
                              detail: mode == .usb ? "它不受保护。USB 保护启动后它会连不上。" : "它不受保护。线路正常时它照样能连，断线后会被拦。", action: .help))
        }
        return list
    }

    /// 保护进行中。
    static func whileRunning(shield: ControlStatus.Shield?, closedOutsideAt: Date?, mode: NativeProtectionMode, around: Surroundings, now: Date) -> [Reminder] {
        var list: [Reminder] = []
        if let shield, !shield.programs.isEmpty {
            list.append(.init(id: "shield", tone: .warning, title: "拦下了 \(shield.programs.joined(separator: "、"))",
                              detail: "它们在保护外，想从别的线路连 Claude。常见的是浏览器的 Claude 插件，或者打开着的 claude.ai 网页。移除插件、关掉网页就好。", action: .help))
        }
        if let shield, !shield.uncovered.isEmpty {
            list.append(.init(id: "uncovered", tone: .warning, title: "有 \(shield.uncovered.count) 个域名拦不到", detail: "它们和别的网站共用地址。Claude 自己不受影响，只是保护外的软件能连到它们。"))
        }
        if let closedOutsideAt, now.timeIntervalSince(closedOutsideAt) < 1800 {
            list.append(.init(id: "relaunch", tone: .warning, title: "Claude 在保护外打开过，已关掉", detail: "多半是自动更新后自己重开的，也可能是你从程序坞点开了。请只从这里启动。"))
        }
        if around.dnsProxy {
            list.append(.init(id: "dns", tone: .warning, title: "有软件接管了域名查询（DNS）", detail: "少量域名查询可能不走所选线路。", action: .help))
        }
        if around.otherClaude > 0 {
            list.append(.init(id: "terminal", tone: .neutral, title: "终端或编辑器里开着 claude",
                              detail: mode == .usb ? "它不受保护，现在连不上 Claude。" : "它不受保护，只是刚好走同一条线路。", action: .help))
        }
        return list
    }
}

/// 会影响保护的周边情况。只看本机状态，不连 Claude。
struct Surroundings: Equatable, Sendable {
    var otherClaude = 0
    var systemProxy = false
    var dnsProxy = false

    static func isTerminal(_ name: String, _ path: String) -> Bool { SurroundingsModel.isOtherClaude(name: name, path: path) }
}

@MainActor
final class SurroundingsModel: ObservableObject {
    @Published private(set) var now = Surroundings()
    @Published private(set) var claudeRunning = false
    private var task: Task<Void, Never>?

    #if DEBUG
    func preview(_ value: Surroundings, running: Bool) { now = value; claudeRunning = running }
    #endif

    func monitor() {
        guard task == nil else { return }
        task = Task { [weak self] in
            var round = 0
            while !Task.isCancelled {
                guard let self else { return }
                let running = !ClaudeApp.running.isEmpty
                if running != self.claudeRunning { self.claudeRunning = running }
                if round % 3 == 0 {
                    let checkDNS = round % 30 == 0
                    let found = await Task.detached(priority: .utility) {
                        (Self.countOtherClaude(), NativeProtectionPolicy.hasSystemProxy(), checkDNS ? Self.dnsIntercepted() : nil)
                    }.value
                    let next = Surroundings(otherClaude: found.0, systemProxy: found.1, dnsProxy: found.2 ?? self.now.dnsProxy)
                    if next != self.now { self.now = next }
                }
                round += 1
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// 终端或编辑器里的 claude 命令：不是 Claude Desktop 自带的，也不在隔离组里。
    nonisolated static func countOtherClaude() -> Int {
        let group = getgrnam(GuardContract.group)?.pointee.gr_gid
        return ProcessAudit.processes().filter { entry in
            guard entry.uid == getuid(), group == nil || (entry.gid != group && entry.realGID != group) else { return false }
            guard entry.name == "claude" || entry.name.first?.isNumber == true else { return false }
            var buffer = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(entry.pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
            return isOtherClaude(name: entry.name, path: String(cString: buffer))
        }.count
    }

    nonisolated static func isOtherClaude(name: String, path: String) -> Bool {
        if path.contains("/Claude.app/") || path.contains("/Application Support/Claude/") { return false }
        return name == "claude" || path.contains("/claude/versions/")
    }

    /// 连一个不存在的地址（RFC 5737 文档专用）的 53 端口：连得上、而 54 连不上，说明有软件在本机接管 DNS。
    /// 两个都连得上多半是 VPN 在本机应答一切连接，不算。
    nonisolated static func dnsIntercepted() -> Bool {
        connects(port: 53) && !connects(port: 54)
    }

    private nonisolated static func connects(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var to = sockaddr_in()
        to.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        to.sin_family = sa_family_t(AF_INET)
        to.sin_port = port.bigEndian
        inet_pton(AF_INET, "203.0.113.9", &to.sin_addr)
        let result = withUnsafePointer(to: &to) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var wait = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&wait, 1, 1500) > 0 else { return false }
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 && error == 0
    }
}
