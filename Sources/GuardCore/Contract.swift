import Darwin
import Foundation

/// 隔离组件与界面之间的约定。界面不参与执行：界面退出或崩溃后，守护进程和内核规则继续生效。
public enum GuardContract {
    public static let version = "0.9.0"
    public static let group = "appnetguard"
    public static let directory = "/Library/PrivilegedHelperTools/AppNetworkGuard"
    public static let runner = directory + "/guardrun"
    public static let checker = directory + "/guardcheck"
    public static let relay = directory + "/guardrelay"
    public static let stateDirectory = "/var/db/appnetworkguard"
    public static let ownerFile = stateDirectory + "/owner"
    public static let socket = "/var/run/appnetworkguard/control.sock"
    public static let label = "local.appnetworkguard.netd"
    public static let resolverMark = "# App Network Guard"
}

public enum IsolationMode: String, Codable, Sendable { case usb, pin }
public enum IsolationState: String, Codable, Sendable { case idle, armed, blocked }

public struct ControlRequest: Codable, Sendable {
    public enum Command: String, Codable, Sendable { /// permit：断网期间让用户在新线路上看检测网站，受保护应用仍然断网。
        case status, arm, block, release, terminate, permit }
    public var command: Command
    public var mode: IsolationMode?
    public var interface: String?
    public var domains: [String]?
    public var strictDNS: Bool?
    /// 目标应用是否以进程级限制启动（禁 UDP、禁系统代办）。
    public var confined: Bool?
    /// 用户认可、启动检查时又核对过的公网 IPv4 地址；会话期间持续核对，变了就断网。
    public var expectedExit: String?
    /// 用户放行的内网“地址:端口”。
    public var allowed: [String]?

    public init(_ command: Command, mode: IsolationMode? = nil, interface: String? = nil, domains: [String]? = nil, strictDNS: Bool? = nil, confined: Bool? = nil, expectedExit: String? = nil, allowed: [String]? = nil) {
        self.allowed = allowed
        self.expectedExit = expectedExit
        self.strictDNS = strictDNS
        self.confined = confined
        self.command = command
        self.mode = mode
        self.interface = interface
        self.domains = domains
    }
}

public struct ControlStatus: Codable, Sendable, Equatable {
    public struct Member: Codable, Sendable, Equatable, Identifiable {
        public var id: Int32 { pid }
        public let pid: Int32
        public let name: String
        public init(pid: Int32, name: String) { self.pid = pid; self.name = name }
    }
    public struct Event: Codable, Sendable, Equatable, Identifiable {
        public let id: UUID
        public let date: Date
        public let kind: String
        public let detail: String
        public init(kind: String, detail: String, date: Date = Date(), id: UUID = UUID()) {
            self.kind = kind; self.detail = detail; self.date = date; self.id = id
        }
    }
    public struct Day: Codable, Sendable, Equatable, Identifiable {
        public var id: String { day }
        public let day: String
        public var upload: UInt64
        public var download: UInt64
        public init(day: String, upload: UInt64, download: UInt64) { self.day = day; self.upload = upload; self.download = download }
    }

    /// 服务拦截的现状。
    public struct Shield: Codable, Sendable, Equatable {
        /// 规则已装载，且用假地址验证过真的在拦。
        public var verified = false
        public var networks: [String] = []
        /// 落在共享 CDN 上、按地址拦会误伤其他网站的域名。
        public var uncovered: [String] = []
        public var blockedPackets: UInt64 = 0
        /// 想从其他线路连接该服务而被拦的程序（尽力识别）。
        public var programs: [String] = []
        /// 每个想从其他线路连的程序一条；program 为空表示拦到了但没认出来。旧组件没有这一项。
        public var hits: [Hit]?

        public struct Hit: Codable, Sendable, Equatable, Identifiable {
            public var id: String { (program ?? "?") + "|" + (interface ?? "?") }
            public let program: String?
            /// 认出程序时是它实际用的网卡；没认出时是当时的 Mac 默认网卡。
            public let interface: String?
            public let first: Date
            public var last: Date
            public init(program: String?, interface: String?, first: Date, last: Date) {
                self.program = program; self.interface = interface; self.first = first; self.last = last
            }
        }

        public mutating func note(_ program: String?, interface: String?, at date: Date) {
            var list = hits ?? []
            let hit = Hit(program: program, interface: interface, first: date, last: date)
            if let index = list.firstIndex(where: { $0.id == hit.id }) { list[index].last = date } else { list.append(hit) }
            hits = Array(list.suffix(20))
        }
        public init() {}
    }

    public var version = GuardContract.version
    public var shield: Shield?
    public var exitCheckedAt: Date?
    public var state = IsolationState.idle
    public var mode: IsolationMode?
    public var interface: String?
    public var reason: String?
    public var relayPort: UInt16?
    public var members: [Member] = []
    public var events: [Event] = []
    public var upload: UInt64 = 0
    public var download: UInt64 = 0
    /// 未使用转发器、由内核直接改道到 USB 的字节数。
    public var redirected: UInt64 = 0
    public var days: [Day] = []
    public var protectedDomains: [String] = []
    /// 会话期间全机 DNS 由 USB 线路解析。
    public var strictDNS = false
    public var confined = false
    /// 会话期间是否正在影响其他应用：临时封锁 QUIC、临时关闭 TSO。
    public var quicFallback = false
    public var offloadDisabled = false
    /// 当前真正放行着的内网地址（VPN 没开时为空）。
    public var allowed: [String]?
    public var error: String?

    public init() {}
}

public enum GuardNames {
    public static func interface(_ value: String) -> Bool {
        value.range(of: #"^(en|utun|ppp|ipsec)[0-9]{1,4}\z"#, options: .regularExpression) != nil
    }

    public static func domain(_ value: String) -> Bool {
        value.utf8.count <= 253 && value.range(
            of: #"^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?\z"#,
            options: .regularExpression) != nil
    }
}

public enum ControlClient {
    public enum Failure: Error { case unavailable, refused(String) }

    public static func send(_ request: ControlRequest, timeout: Int = 20, path: String = GuardContract.socket) throws -> ControlStatus {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { close(fd) }
        var limit = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        guard withUnixAddress(path, { connect(fd, $0, $1) }) == 0 else { throw Failure.unavailable }
        var payload = try JSONEncoder().encode(request)
        payload.append(10)
        guard payload.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == payload.count else { throw Failure.unavailable }
        var answer = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            answer.append(contentsOf: buffer.prefix(count))
            if answer.count > 1 << 20 { throw Failure.unavailable }
        }
        guard let status = try? JSONDecoder().decode(ControlStatus.self, from: answer) else { throw Failure.unavailable }
        if let error = status.error { throw Failure.refused(error) }
        return status
    }

    public static func withUnixAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            let bytes = Array(path.utf8.prefix(target.count - 1))
            target.copyBytes(from: bytes)
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
}
