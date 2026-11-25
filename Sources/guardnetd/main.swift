import BoundTransport
import Darwin
import Foundation
import GuardCore
import SystemConfiguration

// 隔离守护进程（root，launchd 常驻）。只有在保护会话期间才加载 PF 规则；空闲时系统网络不受任何影响。
// 一切不确定状态都归为 blocked：受限组只能访问本机，直到用户重新检查并启动。

struct Refusal: Error { let code: String; init(_ code: String) { self.code = code } }

func run(_ path: String, _ arguments: [String], input: String? = nil) -> (status: Int32, output: String) {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
    process.standardOutput = output
    process.standardError = output
    let feed = input.map { _ in Pipe() }
    process.standardInput = feed ?? FileHandle.nullDevice
    do { try process.run() } catch { return (-1, "") }
    if let feed, let input {
        try? feed.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try? feed.fileHandleForWriting.close()
    }
    let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    timeout.cancel()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

func routeInterface(_ target: String) -> String? {
    var name = [CChar](repeating: 0, count: 32), gateway = [CChar](repeating: 0, count: 64)
    var blocked: Int32 = 0
    guard guard_route(target, &name, name.count, &gateway, gateway.count, &blocked) == 1, blocked == 0 else { return nil }
    return String(cString: name)
}

func defaultInterface() -> String? {
    var name = [CChar](repeating: 0, count: 32), gateway = [CChar](repeating: 0, count: 64)
    var blocked: Int32 = 0
    guard guard_route("1.1.1.1", &name, name.count, &gateway, gateway.count, &blocked) == 1, blocked == 0 else { return nil }
    return String(cString: name)
}

final class Relay {
    let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private(set) var port: UInt16 = 0
    private let lock = NSLock()
    private var totals: (UInt64, UInt64) = (0, 0)

    init?(_ line: USBLine, port wanted: UInt16) {
        process.executableURL = URL(fileURLWithPath: GuardContract.relay)
        // nobody / nobody：转发器不需要任何特权。
        process.arguments = [line.interface, line.dns.joined(separator: ","), String(wanted), String(UInt32(bitPattern: -2)), String(UInt32(bitPattern: -2))]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let ready = DispatchSemaphore(value: 0)
        var pending = Data()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { handle.readabilityHandler = nil; ready.signal(); return }
            pending.append(data)
            while let end = pending.firstIndex(of: 10) {
                let fields = String(decoding: pending[pending.startIndex..<end], as: UTF8.self).split(separator: " ")
                pending.removeSubrange(pending.startIndex...end)
                if fields.count == 2, fields[0] == "port", let value = UInt16(fields[1]) { self.port = value; ready.signal() }
                if fields.count >= 3, fields[0] == "bytes", let up = UInt64(fields[1]), let down = UInt64(fields[2]) {
                    self.lock.lock(); self.totals = (up, down); self.lock.unlock()
                }
            }
        }
        guard ready.wait(timeout: .now() + 4) == .success, port != 0 else { stop(); return nil }
    }

    var bytes: (UInt64, UInt64) { lock.lock(); defer { lock.unlock() }; return totals }
    var alive: Bool { process.isRunning }

    func stop() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}

/// 以独立的补充解析器接管默认域名解析（VPN 软件的标准做法），绑定 USB 网卡。
/// 不修改任何现有网络服务，不写入系统偏好；删除该项即完全还原，重启也会消失。
final class StrictDNS {
    private static let key = "State:/Network/Service/AppNetworkGuard/DNS" as CFString
    private(set) var active = false

    private func store() -> SCDynamicStore? { SCDynamicStoreCreate(nil, "App Network Guard DNS" as CFString, nil, nil) }

    private static let lanKey = "State:/Network/Service/AppNetworkGuardLAN/DNS" as CFString

    func apply(_ server: String, interface: String) {
        guard let store = store() else { return }
        if active, SCDynamicStoreCopyValue(store, Self.key) != nil { return }
        // 路由器下发的内网域名（如 lan）继续由原来的 DNS 解析，内网设备不受影响。
        if let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
           let service = global["PrimaryService"] as? String, let primary = global["PrimaryInterface"] as? String, primary != interface,
           let dns = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(service)/DNS" as CFString) as? [String: Any],
           let servers = dns["ServerAddresses"] as? [String] {
            let domains = Array(Set(((dns["SearchDomains"] as? [String]) ?? []) + [dns["DomainName"] as? String].compactMap { $0 })).filter { !$0.isEmpty }
            if !domains.isEmpty {
                let local: [String: Any] = ["ServerAddresses": servers, "InterfaceName": primary, "SupplementalMatchDomains": domains,
                                            "SupplementalMatchDomainsNoSearch": 1]
                SCDynamicStoreSetValue(store, Self.lanKey, local as CFDictionary)
            }
        }
        let value: [String: Any] = [
            "ServerAddresses": [server], "InterfaceName": interface,
            "SupplementalMatchDomains": [""], "SupplementalMatchOrders": [1], "SupplementalMatchDomainsNoSearch": 1
        ]
        active = SCDynamicStoreSetValue(store, Self.key, value as CFDictionary)
    }

    func restore() {
        active = false
        guard let store = store() else { return }
        for key in [Self.key, Self.lanKey] where SCDynamicStoreCopyValue(store, key) != nil { SCDynamicStoreRemoveValue(store, key) }
    }
}

/// 改道的连接按原网卡能力生成 TSO 大包，而 iPhone USB 网卡不支持分段卸载，上传会严重卡顿。
/// 会话期间关闭 TSO（只影响新连接的 CPU 开销），结束后还原；标记落盘，崩溃后也能还原。
enum SegmentationOffload {
    private static let mark = GuardContract.stateDirectory + "/tso.saved"

    static func disable() {
        guard !FileManager.default.fileExists(atPath: mark) else { return }
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("net.inet.tcp.tso", &value, &size, nil, 0) == 0, value != 0,
              (try? String(value).write(toFile: mark, atomically: true, encoding: .utf8)) != nil else { return }
        var zero: Int32 = 0
        sysctlbyname("net.inet.tcp.tso", nil, nil, &zero, MemoryLayout<Int32>.size)
    }

    static func restore() {
        guard let text = try? String(contentsOfFile: mark, encoding: .utf8), var value = Int32(text) else { return }
        if sysctlbyname("net.inet.tcp.tso", nil, nil, &value, MemoryLayout<Int32>.size) == 0 { unlink(mark) }
    }
}

final class Daemon {
    private struct Session: Codable {
        let mode: IsolationMode
        let interface: String
        let index: UInt32
        let addresses: Set<String>
        let address: String
        let gateway: String
        let domains: [String]
        var strictDNS = false
        var confined = false
        var shield: [String]? = nil
        var expectedExit: String? = nil
        var allowed: [String]? = nil
    }

    private let queue = DispatchQueue(label: "guard.netd")
    private let gid: gid_t
    private let owner: uid_t
    private var status = ControlStatus()
    private var session: Session?
    private var line: USBLine?
    private var relay: Relay?
    private var token: String?
    private var loaded = ""
    private var blockedSockets: Set<InternetSocket> = []
    private var counted: (UInt64, UInt64) = (0, 0)
    private var timer: DispatchSourceTimer?
    private var listener: DispatchSourceRead?
    private var tickCount = 0
    private var reported: Set<String> = []
    private let strictDNS = StrictDNS()
    private var rulesGuardDNS = false
    private var emptyTicks = 0
    private var hadMembers = false
    private let background = DispatchQueue(label: "guard.netd.background", attributes: .concurrent)
    private var shieldLoaded = ""
    private var shieldNetworks: [AddressBlock] = []
    private var shieldPackets: UInt64 = 0
    private var shieldScans = 0
    private var unexplained: (date: Date, interface: String?)?
    private var resolvingShield = false
    private struct Permit { let interface: String; let link: LinkState; let until: Date }
    private var permitted: Permit?
    private var checkingExit = false
    private var exitFailures = 0
    private let sessionFile = GuardContract.stateDirectory + "/session.json"
    private let trafficFile = GuardContract.stateDirectory + "/traffic.json"
    private let eventFile = GuardContract.stateDirectory + "/events.json"

    init(gid: gid_t, owner: uid_t) {
        self.gid = gid
        self.owner = owner
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: URL(fileURLWithPath: trafficFile)) { status.days = (try? decoder.decode([ControlStatus.Day].self, from: data)) ?? [] }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: eventFile)) { status.events = (try? decoder.decode([ControlStatus.Event].self, from: data)) ?? [] }
    }

    func start() throws {
        strictDNS.restore()
        let members = ProcessAudit.members(of: gid, in: ProcessAudit.processes())
        if members.isEmpty {
            clear()
        } else {
            // 守护进程重启而受保护进程仍在：内核旧规则可能仍在，统一收紧为阻断。
            session = (try? Data(contentsOf: URL(fileURLWithPath: sessionFile))).flatMap { try? JSONDecoder().decode(Session.self, from: $0) }
            enterBlocked("daemon_restarted")
        }
        try listen()
        schedule()
        record("started", "隔离守护进程已启动")
    }

    /// 被 launchd 停止时：没有受保护进程就完全还原；否则保留内核阻断规则。
    func shutdown() {
        queue.sync {
            if ProcessAudit.members(of: gid, in: ProcessAudit.processes()).isEmpty { clear() }
            else { enterBlocked("daemon_stopped") }
        }
    }

    // MARK: 控制接口

    private func listen() throws {
        let directory = (GuardContract.socket as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        unlink(GuardContract.socket)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, ControlClient.withUnixAddress(GuardContract.socket, { bind(fd, $0, $1) }) == 0,
              chmod(GuardContract.socket, 0o666) == 0, Darwin.listen(fd, 16) == 0 else { throw Refusal("socket") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            self?.handle(client)
        }
        source.resume()
        listener = source
    }

    private func handle(_ client: Int32) {
        defer { close(client) }
        var uid: uid_t = 0, peerGroup: gid_t = 0
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        guard getpeereid(client, &uid, &peerGroup) == 0, uid == owner || uid == 0 else { return }
        var limit = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while !data.contains(10), data.count < 8192 {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { return }
            data.append(contentsOf: buffer.prefix(count))
        }
        var answer: ControlStatus
        do {
            guard let request = try? JSONDecoder().decode(ControlRequest.self, from: data) else { throw Refusal("invalid_request") }
            // 受限组内的进程只能读状态，不能改变自己的保护。
            if request.command != .status, uid != 0, peerGroup == gid { throw Refusal("not_allowed") }
            try perform(request)
            refreshMembers()
            answer = status
        } catch {
            refreshMembers()
            answer = status
            answer.error = (error as? Refusal)?.code ?? "failed"
        }
        answer.events = Array(answer.events.suffix(60))
        guard let payload = try? JSONEncoder().encode(answer) else { return }
        _ = payload.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
    }

    private func perform(_ request: ControlRequest) throws {
        switch request.command {
        case .status: break
        case .arm: try arm(request)
        case .block: if session != nil { enterBlocked("user_blocked") }
        case .terminate:
            kill(ProcessAudit.members(of: gid, in: ProcessAudit.processes()), signal: SIGKILL)
            for _ in 0..<20 where !ProcessAudit.members(of: gid, in: ProcessAudit.processes()).isEmpty { usleep(100_000) }
            try release()
        case .release: try release()
        case .permit: try permit(request)
        }
    }

    /// 受保护应用断网期间，用户要在新线路上看检测网站：只放开保护外软件从这块网卡连服务，受保护组照样断网。
    private func permit(_ request: ControlRequest) throws {
        guard status.state == .blocked, let session, let interface = request.interface, GuardNames.interface(interface),
              interface == defaultInterface(), let link = LinkState.read(interface),
              session.mode == .pin || USBLine.interfaces().contains(interface) else { throw Refusal("not_allowed") }
        permitted = Permit(interface: interface, link: link, until: Date().addingTimeInterval(600))
        try loadShield(armed: false)
    }

    /// 线路一变、到时间或不再是断网状态，就收回。
    private func checkPermit() {
        guard let current = permitted else { return }
        guard status.state == .blocked, Date() < current.until, defaultInterface() == current.interface,
              LinkState.read(current.interface) == current.link else {
            permitted = nil
            try? loadShield(armed: status.state == .armed)
            return
        }
    }

    private func release() throws {
        guard ProcessAudit.members(of: gid, in: ProcessAudit.processes()).isEmpty else { throw Refusal("members_running") }
        if session != nil { record("released", "会话结束，已撤销全部规则") }
        clear()
    }

    private func arm(_ request: ControlRequest) throws {
        guard let interface = request.interface, GuardNames.interface(interface), let mode = request.mode else { throw Refusal("invalid_request") }
        let domains = Array(Set(request.domains ?? [])).sorted()
        guard domains.count <= 32, domains.allSatisfy(GuardNames.domain) else { throw Refusal("invalid_domain") }
        let allowed = request.allowed ?? []
        guard allowed.count <= AllowedHost.limit, allowed.allSatisfy({ AllowedHost($0) != nil }) else { throw Refusal("invalid_allowed") }
        guard run("/sbin/pfctl", ["-sr"]).output.contains("anchor \"com.apple/*\"") else { throw Refusal("pf_anchor_missing") }
        guard let link = LinkState.read(interface) else { throw Refusal("line_missing") }
        // 已有成员时只允许在同一模式下恢复，避免把运行中的应用悄悄换线。
        if let session, !ProcessAudit.members(of: gid, in: ProcessAudit.processes()).isEmpty, session.mode != mode { throw Refusal("mode_mismatch") }

        var next: Session
        relay?.stop(); relay = nil; line = nil
        if mode == .usb {
            guard let usb = USBLine.read(interface) else { throw Refusal("not_iphone_usb") }
            guard let path = defaultInterface(), path != interface else { throw Refusal("no_separate_path") }
            let previous = status.relayPort ?? 0
            guard let relay = Relay(usb, port: previous) ?? Relay(usb, port: 0) else { throw Refusal("relay_failed") }
            self.relay = relay
            line = usb
            counted = (0, 0)
            status.relayPort = relay.port
            next = Session(mode: mode, interface: interface, index: usb.link.index, addresses: usb.link.addresses,
                           address: usb.address, gateway: usb.gateway, domains: domains, strictDNS: request.strictDNS == true, confined: request.confined == true)
        } else {
            guard defaultInterface() == interface else { throw Refusal("not_default_path") }
            status.relayPort = nil
            next = Session(mode: mode, interface: interface, index: link.index, addresses: link.addresses,
                           address: interface.hasPrefix("en") ? (link.ipv4 ?? "") : "", gateway: "", domains: [], confined: request.confined == true)
        }
        next.expectedExit = request.expectedExit.flatMap { AddressBlock($0)?.description }
        next.shield = domains
        next.allowed = allowed
        permitted = nil
        // 同一批域名重新检查时保留已解析到的地址；换了目标则重新收集。
        if session?.shield != domains { shieldNetworks = [] }
        shieldNetworks = Array(Set(shieldNetworks + ServiceShield.fixedNetworks(for: domains)))
        session = next
        status.mode = mode
        status.interface = interface
        do {
            // 先拦保护外的程序，再放行受保护应用。
            try loadShield(armed: true)
            try enforce(armed: true)
        } catch {
            enterBlocked("enforce_failed")
            throw error
        }
        // 这些写操作只在规则生效之后进行，保证不存在“已记录但未强制”的窗口。
        try? JSONEncoder().encode(next).write(to: URL(fileURLWithPath: sessionFile), options: .atomic)
        writeResolvers()
        strictDNS.restore()
        if next.strictDNS, rulesGuardDNS, let server = line?.dns.first { strictDNS.apply(server, interface: next.interface) }
        status.strictDNS = strictDNS.active
        status.state = .armed
        status.reason = nil
        status.exitCheckedAt = nil
        exitFailures = 0
        refreshShieldAddresses()
        reported = []
        record("armed", "\(mode == .usb ? "USB 专线" : "锁定线路") \(interface) 已生效")
    }

    // MARK: 规则

    private func enforce(armed: Bool) throws {
        guard let session else { return }
        if token == nil {
            let output = run("/sbin/pfctl", ["-E"]).output
            token = output.split(whereSeparator: \.isNewline).first { $0.contains("Token") }
                .flatMap { $0.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } }
            guard token != nil else { throw Refusal("pf_enable_failed") }
        }
        var rules = PFRules(gid: gid, mode: session.mode, armed: armed, interface: session.interface,
                            address: session.address, gateway: session.gateway)
        rules.quicFallback = quicFallback(session)
        status.quicFallback = rules.quicFallback != nil
        status.confined = session.confined
        rules.relayPort = session.mode == .usb ? status.relayPort : nil
        rules.localProxyPorts = SystemProxy.localPorts()
        rules.allowed = allowedRoutes(session)
        status.allowed = armed ? rules.allowed.map(\.host.text) : []
        if session.mode == .usb, let line {
            let subnetReused = otherInterfacesUse(prefix: session.gateway.split(separator: ".").prefix(3).joined(separator: "."), except: session.interface)
            rules.guardedDNS = subnetReused ? [] : line.dns.filter { $0 == session.gateway }
            rulesGuardDNS = !rules.guardedDNS.isEmpty
            status.protectedDomains = rules.guardedDNS.isEmpty ? [] : session.domains
        }
        let text = rules.text()
        let result = run("/sbin/pfctl", ["-q", "-a", PFRules.anchor, "-f", "-"], input: text)
        guard result.status == 0, verifyRules() else { throw Refusal("pf_load_failed") }
        loaded = text
    }

    private func quicFallback(_ session: Session) -> String? {
        guard session.mode == .usb, !session.confined, let path = defaultInterface(), path != session.interface else { return nil }
        return path
    }

    private func otherInterfacesUse(prefix: String, except: String) -> Bool {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return true }
        defer { freeifaddrs(head) }
        var next = head
        while let item = next?.pointee {
            next = item.ifa_next
            let name = String(cString: item.ifa_name)
            if name != except, LinkState.read(name)?.addresses.contains(where: { $0.hasPrefix(prefix + ".") }) == true { return true }
        }
        return false
    }

    /// 每个周期都执行的轻量核对：规则被清空时半秒内发现。
    private func rulesPresent() -> Bool {
        run("/sbin/pfctl", ["-a", PFRules.anchor, "-sr"]).output.contains("block return out quick all group = \(gid)")
    }

    private func verifyRules() -> Bool {
        run("/sbin/pfctl", ["-s", "info"]).output.contains("Status: Enabled") &&
            run("/sbin/pfctl", ["-a", PFRules.anchor, "-sr"]).output.contains("block return out quick all group = \(gid)") &&
            run("/sbin/pfctl", ["-sr"]).output.contains("anchor \"com.apple/*\"")
    }

    private func enterBlocked(_ reason: String) {
        permitted = nil
        if session == nil {
            session = Session(mode: .usb, interface: "lo0", index: 0, addresses: [], address: "127.0.0.1", gateway: "127.0.0.1", domains: [])
        }
        do {
            try enforce(armed: false)
            if let domains = session?.shield, !domains.isEmpty {
                shieldNetworks = Array(Set(shieldNetworks + ServiceShield.fixedNetworks(for: domains)))
                try? loadShield(armed: false)
            }
        } catch {
            // 无法在内核中阻断时，唯一可靠的办法是结束受保护进程。
            kill(ProcessAudit.members(of: gid, in: ProcessAudit.processes()), signal: SIGKILL)
            record("killed", "无法装载阻断规则，已结束受保护进程")
        }
        if let session, session.mode == .usb, !session.address.hasPrefix("127.") {
            _ = run("/sbin/pfctl", ["-q", "-k", "0.0.0.0/0", "-k", session.address])
        }
        relay?.stop()
        relay = nil
        strictDNS.restore()  // 断线时其他应用仍要能解析域名；Claude 此时无法建立任何外部连接。
        status.strictDNS = false
        if status.state != .blocked || status.reason != reason {
            status.state = .blocked
            status.reason = reason
            record("blocked", reason)
        }
    }

    private func clear() {
        permitted = nil
        relay?.stop()
        relay = nil
        line = nil
        removeResolvers()
        strictDNS.restore()
        status.strictDNS = false
        for part in ["rules", "nat"] { _ = run("/sbin/pfctl", ["-q", "-a", PFRules.anchor, "-F", part]) }
        if let session, session.mode == .usb, !session.address.hasPrefix("127.") { _ = run("/sbin/pfctl", ["-q", "-k", session.address]) }
        if let token { _ = run("/sbin/pfctl", ["-q", "-X", token]) }
        token = nil
        session = nil
        loaded = ""
        updateSocketBlocks([])
        clearShield()
        status.exitCheckedAt = nil
        status.confined = false
        status.quicFallback = false
        status.offloadDisabled = false
        status.allowed = nil
        SegmentationOffload.restore()
        emptyTicks = 0
        hadMembers = false
        status.state = .idle
        status.mode = nil
        status.interface = nil
        status.reason = nil
        status.relayPort = nil
        status.upload = 0
        status.download = 0
        status.redirected = 0
        status.protectedDomains = []
        try? FileManager.default.removeItem(atPath: sessionFile)
    }

    // MARK: 受保护域名的 DNS（macOS 标准的 /etc/resolver）

    private func writeResolvers() {
        removeResolvers()
        guard !status.protectedDomains.isEmpty, let server = line?.dns.first else { return }
        let directory = "/etc/resolver"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        for domain in status.protectedDomains {
            let path = directory + "/" + domain
            guard !FileManager.default.fileExists(atPath: path) else { record("resolver", "\(domain) 已有其他 DNS 配置，未改动"); continue }
            try? "\(GuardContract.resolverMark)\nnameserver \(server)\ntimeout 3\n".write(toFile: path, atomically: true, encoding: .utf8)
            chmod(path, 0o644)
        }
    }

    private func removeResolvers() {
        let directory = "/etc/resolver"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] {
            let path = directory + "/" + name
            if (try? String(contentsOfFile: path, encoding: .utf8))?.hasPrefix(GuardContract.resolverMark) == true { unlink(path) }
        }
        rmdir(directory)  // 仅在已空时成功
    }

    // MARK: 服务拦截

    private func loadShield(armed: Bool) throws {
        guard let session, session.shield?.isEmpty == false else { clearShield(); return }
        // 断网期间只有用户主动看检测网站时才有例外，并且绑定当时那块网卡的地址。
        let open = armed ? session.interface : permitted?.interface
        let text = ServiceShield.rules(interface: open,
                                       address: armed ? (session.mode == .pin ? session.address : "")
                                           : permitted.map { $0.interface.hasPrefix("en") ? ($0.link.ipv4 ?? "") : "" } ?? "",
                                       networks: shieldNetworks, canaryAnywhere: open != nil && open == defaultInterface())
        guard run("/sbin/pfctl", ["-q", "-a", ServiceShield.anchor, "-f", "-"], input: text).status == 0 else {
            status.shield?.verified = false
            throw Refusal("shield_load_failed")
        }
        shieldLoaded = text
        shieldPackets = 0  // 重新装载后计数从零开始
        var shield = status.shield ?? .init()
        shield.networks = shieldNetworks.map(\.description).sorted()
        status.shield = shield
        // 防火墙未启用时（首次启动）由随后的 enforce 启用，1 秒内的 watchShield 再验证。
        if token != nil { status.shield?.verified = proveShield() }
    }

    private func clearShield() {
        // 守护进程可能是崩溃后重启的，内核里或许还留着旧规则，所以总是清一次。
        _ = run("/sbin/pfctl", ["-q", "-a", ServiceShield.anchor, "-F", "rules"])
        shieldLoaded = ""
        shieldNetworks = []
        shieldPackets = 0
        unexplained = nil
        status.shield = nil
    }

    private func shieldLabels() -> String { run("/sbin/pfctl", ["-a", ServiceShield.anchor, "-s", "labels"]).output }

    /// 向文档专用的假地址发一个包，计数增加才说明规则真的在拦。不接触真实服务。
    private func proveShield() -> Bool {
        guard let before = ServiceShield.packets(in: shieldLabels(), label: ServiceShield.canaryLabel) else { return false }
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(9).bigEndian
        inet_pton(AF_INET, ServiceShield.canary, &address.sin_addr)
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = sendto(fd, "g", 1, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        usleep(20_000)
        return (ServiceShield.packets(in: shieldLabels(), label: ServiceShield.canaryLabel) ?? 0) > before
    }

    private func watchShield() {
        guard let session, session.shield?.isEmpty == false else { return }
        let labels = shieldLabels()
        guard ServiceShield.packets(in: labels, label: ServiceShield.canaryLabel) != nil else {
            once("shield-lost", kind: "shield", detail: "拦截规则被其他程序清掉，已重新装载；空隙里可能有保护外的软件连过服务")
            reported.remove("shield-lost")
            status.shield?.verified = false
            try? loadShield(armed: status.state == .armed)
            return
        }
        if status.shield?.verified != true { status.shield?.verified = proveShield() }
        let packets = ServiceShield.packets(in: labels, label: ServiceShield.label) ?? 0
        if packets > shieldPackets {
            status.shield?.blockedPackets += packets - shieldPackets
            shieldPackets = packets
            shieldScans = 6
            if unexplained == nil { unexplained = (Date(), defaultInterface()) }
            once("shield-hit", kind: "shield", detail: "保护外的软件尝试从其他线路连接 Claude 的服务，已拦截")
        }
        // 平时每 2 秒找一次漏网的连接；刚拦到时每秒找，尽量认出是哪个软件。
        guard shieldScans > 0 || tickCount % 8 == 0 else { return }
        shieldScans = max(0, shieldScans - 1)
        defer {
            // 找了几秒都没认出程序，就如实记一条“没认出”。
            if shieldScans == 0, let miss = unexplained {
                unexplained = nil
                status.shield?.note(nil, interface: miss.interface, at: miss.date)
            }
        }
        let all = ProcessAudit.processes()
        let inside = Set(ProcessAudit.members(of: gid, in: all).map(\.pid))
        for process in all where !inside.contains(process.pid) && process.pid != getpid() {
            for socket in ProcessAudit.sockets(of: process.pid) {
                guard let remote = AddressBlock(socket.remote), shieldNetworks.contains(where: { $0.contains(remote) }),
                      !session.addresses.contains(socket.local), permitted?.link.addresses.contains(socket.local) != true else { continue }
                unexplained = nil
                status.shield?.note(process.name, interface: LinkState.interface(holding: socket.local) ?? defaultInterface(), at: Date())
                var programs = status.shield?.programs ?? []
                if !programs.contains(process.name) {
                    programs.append(process.name)
                    status.shield?.programs = programs.suffix(20)
                }
                once("shield-\(process.name)", kind: "shield", detail: "\(process.name) 不在保护内，想从其他线路连接 Claude 的服务，已拦截")
            }
        }
    }

    /// 域名的地址会变：每分钟重新解析，只增不减，直到会话结束。
    private func refreshShieldAddresses() {
        guard !resolvingShield, let session, let domains = session.shield, !domains.isEmpty,
              session.mode == .pin || !status.protectedDomains.isEmpty else { return }
        resolvingShield = true
        background.async { [weak self] in
            var found: Set<AddressBlock> = [], uncovered: Set<String> = []
            for name in ServiceShield.names(for: domains) {
                for address in Self.resolve(name) {
                    if ServiceShield.isBlockable(address) { found.insert(address) }
                    else if ServiceShield.isShared(address) { uncovered.insert(name) }
                }
            }
            self?.queue.async {
                guard let self else { return }
                self.resolvingShield = false
                guard self.session?.shield == domains else { return }
                self.status.shield?.uncovered = uncovered.sorted()
                let added = found.filter { address in !self.shieldNetworks.contains { $0.contains(address) } }
                guard !added.isEmpty else { return }
                self.shieldNetworks = Array((self.shieldNetworks + added).prefix(256))
                do { try self.loadShield(armed: self.status.state == .armed) }
                catch { self.record("shield", "拦截规则更新失败，沿用原规则") }
            }
        }
    }

    private static func resolve(_ name: String) -> [AddressBlock] {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, "443", &hints, &head) == 0 else { return [] }
        defer { freeaddrinfo(head) }
        var result: [AddressBlock] = []
        var next = head
        while let item = next?.pointee {
            next = item.ai_next
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard let address = item.ai_addr,
                  getnameinfo(address, item.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0,
                  let block = AddressBlock(String(cString: host)) else { continue }
            result.append(block)
        }
        return result
    }

    // MARK: USB 公网地址核对

    private func checkExit() {
        guard !checkingExit, status.state == .armed, let session, let expected = session.expectedExit else { return }
        checkingExit = true
        let interface = session.interface
        background.async { [weak self] in
            func read(_ host: String) -> String? {
                var body = [CChar](repeating: 0, count: 8192)
                guard guard_https_get("https://\(host)/cdn-cgi/trace", interface, nil, 5000, &body, body.count) == 1 else { return nil }
                return ServiceShield.exitAddress(in: String(cString: body)).flatMap { AddressBlock($0)?.description }
            }
            var address = read("1.1.1.1") ?? read("1.0.0.1")
            if let first = address, first != expected {
                // 再确认一次，避免一次异常读数就断网。
                Thread.sleep(forTimeInterval: 1)
                address = read("1.0.0.1") ?? read("1.1.1.1") ?? first
            }
            self?.queue.async {
                guard let self else { return }
                self.checkingExit = false
                guard self.status.state == .armed, self.session?.interface == interface, self.session?.expectedExit == expected else { return }
                guard let address else {
                    self.exitFailures += 1
                    if self.exitFailures == 3 { self.record("exit", "连续几次没能核对公网 IP，会继续尝试") }
                    return
                }
                self.exitFailures = 0
                if address == expected { self.status.exitCheckedAt = Date() } else { self.enterBlocked("exit_changed") }
            }
        }
    }

    // MARK: 监视

    private func schedule() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(25))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard let session else { return }
        tickCount += 1
        checkPermit()
        if status.state == .armed { checkLine(session) }
        if status.state == .armed, session.mode == .usb, relay?.alive != true { enterBlocked("relay_exited") }
        audit()
        if tickCount % 4 == 0 { meter() }
        if tickCount % 4 == 0 { watchShield() }
        if tickCount % 240 == 0, status.state == .armed { refreshShieldAddresses() }
        if tickCount % 20 == 0 { checkExit() }
        if tickCount % 4 == 0 ? !verifyRules() : !rulesPresent() {
            // 空窗期内可能已有请求从原线路发出，不能当作没发生：立即断网，由用户知情后重新检查。
            token = nil
            let wasArmed = status.state == .armed
            enterBlocked(wasArmed ? "rules_tampered" : status.reason ?? "rules_tampered")
            if !wasArmed { record("repair", "阻断规则被其他程序改动，已重新装载") }
        } else if tickCount % 4 == 0, status.state == .armed {
            refreshDynamicRules(session)
            if status.strictDNS, let server = line?.dns.first { strictDNS.apply(server, interface: session.interface) }
        }
    }

    private func checkLine(_ session: Session) {
        guard let now = LinkState.read(session.interface) else { return enterBlocked("line_lost") }
        if now.index != session.index || (session.mode == .usb && now.ipv4 != session.address) ||
            (session.mode == .pin && !session.address.isEmpty && !now.addresses.contains(session.address)) {
            return enterBlocked("line_changed")
        }
        if session.mode == .pin, let path = defaultInterface(), path != session.interface { return enterBlocked("path_changed") }
    }

    private func allowedRoutes(_ session: Session) -> [AllowedRoute] {
        (session.allowed ?? []).compactMap(AllowedHost.init).compactMap { host in
            guard let interface = routeInterface(host.address), AllowedHost.usable(interface: interface) else { return nil }
            return AllowedRoute(host: host, interface: interface)
        }
    }

    /// 默认线路或系统代理改变时更新规则；USB 主体规则不变。
    private func refreshDynamicRules(_ session: Session) {
        if session.mode == .pin {
            guard session.allowed?.isEmpty == false else { return }
            var expected = PFRules(gid: gid, mode: .pin, armed: true, interface: session.interface, address: session.address, gateway: "")
            expected.localProxyPorts = SystemProxy.localPorts()
            expected.allowed = allowedRoutes(session)
            if expected.text() != loaded {
                do { try enforce(armed: true); record("updated", "系统代理或放行的内网地址线路变化，规则已更新") }
                catch { enterBlocked("pf_load_failed") }
            }
            return
        }
        let before = loaded
        var expected = PFRules(gid: gid, mode: .usb, armed: true, interface: session.interface, address: session.address, gateway: session.gateway)
        expected.quicFallback = quicFallback(session)
        expected.relayPort = status.relayPort
        expected.localProxyPorts = SystemProxy.localPorts()
        expected.allowed = allowedRoutes(session)
        expected.guardedDNS = before.contains("to \(session.gateway)\n") ? [session.gateway] : []
        if expected.text() != before {
            do { try enforce(armed: true); record("updated", "Mac 默认线路或系统代理变化，规则已更新") }
            catch { enterBlocked("pf_load_failed") }
        }
    }

    private func audit() {
        let all = ProcessAudit.processes()
        let members = ProcessAudit.members(of: gid, in: all)
        status.members = members.map { .init(pid: $0.pid, name: $0.name) }
        guard !members.isEmpty else {
            // 应用已全部退出（含界面崩溃的情况）：过一会儿自动撤销规则，恢复普通模式。
            emptyTicks += 1
            if emptyTicks >= (hadMembers ? 240 : 480) { record("released", "Claude 已退出，自动恢复普通模式"); clear() }
            return
        }
        emptyTicks = 0
        hadMembers = true
        var wanted: Set<InternetSocket> = []
        // 由应用间接启动、却不在组内的进程：不结束它，只封掉它的外部连接，其余功能照常。
        for outsider in ProcessAudit.outsiders(of: members, gid: gid, uid: owner, in: all) {
            let external = ProcessAudit.sockets(of: outsider.pid).filter { $0.external && $0.localPort != 0 }
            guard !external.isEmpty else { continue }
            wanted.formUnion(external)
            once("escape-\(outsider.name)", kind: "escape", detail: "\(outsider.name)（由 Claude 间接启动、不在隔离组内）尝试联网，已封锁它的连接")
        }
        if let session, session.mode == .usb || session.confined || status.state == .blocked {
            for member in members {
                for socket in ProcessAudit.sockets(of: member.pid) where socket.udp && socket.external && socket.localPort != 0 && (session.mode == .pin || socket.local != session.address) {
                    wanted.insert(socket)
                    once("udp-\(member.name)", kind: "udp", detail: "\(member.name) 尝试 UDP \(socket.remote):\(socket.remotePort)，已封锁该连接")
                }
                // 没套进程级限制的辅助程序直接用 TCP 查 DNS：封掉它；装了 DNS 代理扩展时防火墙看不到这条连接，所以一定要记下来。
                for socket in ProcessAudit.sockets(of: member.pid) where !socket.udp && socket.external && socket.remotePort == 53 {
                    if socket.localPort != 0 { wanted.insert(socket) }
                    once("dns-\(member.name)", kind: "dns", detail: "\(member.name) 直接用 TCP 查 DNS，已要求防火墙封锁；装有 DNS 代理软件时可能封不住")
                }
            }
        }
        updateSocketBlocks(wanted)
    }

    private func updateSocketBlocks(_ wanted: Set<InternetSocket>) {
        guard wanted != blockedSockets else { return }
        blockedSockets = wanted
        if wanted.isEmpty { _ = run("/sbin/pfctl", ["-q", "-a", PFRules.socketAnchor, "-F", "rules"]) }
        else { _ = run("/sbin/pfctl", ["-q", "-a", PFRules.socketAnchor, "-f", "-"], input: PFRules.socketRules(wanted)) }
    }

    private func meter() {
        if let bytes = relay?.bytes {
            let up = bytes.0 &- counted.0, down = bytes.1 &- counted.1
            counted = bytes
            if up > 0 || down > 0 {
                status.upload += up
                status.download += down
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd"
                let today = formatter.string(from: Date())
                if let index = status.days.firstIndex(where: { $0.day == today }) {
                    status.days[index].upload += up
                    status.days[index].download += down
                } else { status.days = Array((status.days + [.init(day: today, upload: up, download: down)]).suffix(60)) }
            }
        }
        // 只有真的出现内核改道流量时才关闭 TSO，平时不碰全局设置。
        if session?.mode == .usb {
            let output = run("/sbin/pfctl", ["-a", PFRules.anchor, "-s", "labels"]).output
            let fields = (output.split(separator: "\n").first { $0.hasPrefix("angredirect ") } ?? "").split(separator: " ")
            if fields.count >= 4, fields[0] == "angredirect", let bytes = UInt64(fields[3]) {
                status.redirected = max(status.redirected, bytes)
                if bytes > 12_000, !status.offloadDisabled { SegmentationOffload.disable(); status.offloadDisabled = true }
            }
        }
        if tickCount % 40 == 0 {
            try? JSONEncoder().encode(status.days).write(to: URL(fileURLWithPath: trafficFile), options: .atomic)
        }
    }

    private func refreshMembers() {
        status.members = ProcessAudit.members(of: gid, in: ProcessAudit.processes()).map { .init(pid: $0.pid, name: $0.name) }
    }

    private func kill(_ entries: [ProcessEntry], signal: Int32) { for entry in entries where entry.pid > 1 { Darwin.kill(entry.pid, signal) } }

    private func once(_ key: String, kind: String, detail: String) {
        guard reported.insert(key).inserted else { return }
        record(kind, detail)
    }

    private func record(_ kind: String, _ detail: String) {
        status.events = Array((status.events + [.init(kind: kind, detail: detail)]).suffix(200))
        try? JSONEncoder().encode(status.events).write(to: URL(fileURLWithPath: eventFile), options: .atomic)
        NSLog("%@ %@", kind, detail)
    }
}

guard geteuid() == 0 else { FileHandle.standardError.write(Data("guardnetd 需要由 launchd 以 root 启动\n".utf8)); exit(77) }
signal(SIGPIPE, SIG_IGN)
umask(0o022)
try? FileManager.default.createDirectory(atPath: GuardContract.stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
guard let entry = getgrnam(GuardContract.group), let text = try? String(contentsOfFile: GuardContract.ownerFile, encoding: .utf8),
      let owner = uid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), owner >= 500 else {
    FileHandle.standardError.write(Data("缺少隔离组或用户配置，请重新运行 install.sh\n".utf8)); exit(78)
}
let daemon = Daemon(gid: entry.pointee.gr_gid, owner: owner)
signal(SIGTERM, SIG_IGN)
let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminate.setEventHandler { daemon.shutdown(); exit(0) }
terminate.resume()
do { try daemon.start() } catch { FileHandle.standardError.write(Data("启动失败 \(error)\n".utf8)); exit(71) }
dispatchMain()
