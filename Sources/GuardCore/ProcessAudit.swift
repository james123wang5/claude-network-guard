import Darwin
import Foundation

public struct ProcessEntry: Equatable, Sendable {
    public let pid: pid_t
    public let uid: uid_t
    public let gid: gid_t
    public let realGID: gid_t
    public let name: String
}

public struct InternetSocket: Equatable, Sendable, Hashable {
    public init(udp: Bool, local: String, localPort: UInt16 = 0, remote: String, remotePort: UInt16) {
        self.udp = udp; self.local = local; self.localPort = localPort; self.remote = remote; self.remotePort = remotePort
    }

    public let udp: Bool
    public let local: String
    public var localPort: UInt16 = 0
    public let remote: String
    public let remotePort: UInt16

    public var external: Bool {
        !(remote.isEmpty || remote == "0.0.0.0" || remote == "::" || remote == "::1" || remote.hasPrefix("127.") || remote.hasPrefix("::ffff:127."))
    }
}

public enum ProcessAudit {
    private typealias Responsible = @convention(c) (pid_t) -> pid_t
    private static let responsibleFunction: Responsible? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: Responsible.self)
    }()

    public static func responsible(for pid: pid_t) -> pid_t? { responsibleFunction.map { $0(pid) } }

    public static func processes() -> [ProcessEntry] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        return pids.prefix(max(0, Int(count))).compactMap { pid in
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard pid > 0, proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size, info.pbsi_status != UInt32(SZOMB) else { return nil }
            let name = withUnsafeBytes(of: info.pbsi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return ProcessEntry(pid: pid, uid: info.pbsi_uid, gid: info.pbsi_gid, realGID: info.pbsi_rgid, name: name)
        }
    }

    public static func members(of gid: gid_t, in all: [ProcessEntry]) -> [ProcessEntry] {
        all.filter { $0.gid == gid || $0.realGID == gid }
    }

    /// 由受保护应用负责、却不在受限组内的进程（系统按需启动的 XPC、WebKit 网络进程、虚拟机等）。
    public static func outsiders(of members: [ProcessEntry], gid: gid_t, uid: uid_t, in all: [ProcessEntry],
                                 responsible: (pid_t) -> pid_t? = { Self.responsible(for: $0) }) -> [ProcessEntry] {
        let inside = Set(members.map(\.pid))
        guard !inside.isEmpty else { return [] }
        return all.filter { entry in
            entry.uid == uid && !inside.contains(entry.pid) && (responsible(entry.pid).map { inside.contains($0) } ?? false)
        }
    }

    public static func sockets(of pid: pid_t) -> [InternetSocket] {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var table = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 32)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &table, Int32(table.count * stride))
        guard filled > 0 else { return [] }
        var result: [InternetSocket] = []
        for item in table.prefix(Int(filled) / stride) where item.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, item.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { continue }
            let family = info.psi.soi_family
            guard family == AF_INET || family == AF_INET6, [IPPROTO_TCP, IPPROTO_UDP].contains(info.psi.soi_protocol) else { continue }
            let udp = info.psi.soi_protocol == IPPROTO_UDP
            let net = udp ? info.psi.soi_proto.pri_in : info.psi.soi_proto.pri_tcp.tcpsi_ini
            let v6 = net.insi_vflag & UInt8(INI_IPV6) != 0
            result.append(InternetSocket(
                udp: udp,
                local: v6 ? text(net.insi_laddr.ina_6) : text(net.insi_laddr.ina_46.i46a_addr4),
                localPort: UInt16(truncatingIfNeeded: net.insi_lport).byteSwapped,
                remote: v6 ? text(net.insi_faddr.ina_6) : text(net.insi_faddr.ina_46.i46a_addr4),
                remotePort: UInt16(truncatingIfNeeded: net.insi_fport).byteSwapped))
        }
        return result
    }

    private static func text(_ value: in_addr) -> String {
        var value = value
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return inet_ntop(AF_INET, &value, &buffer, socklen_t(buffer.count)) == nil ? "" : String(cString: buffer)
    }

    private static func text(_ value: in6_addr) -> String {
        var value = value
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        return inet_ntop(AF_INET6, &value, &buffer, socklen_t(buffer.count)) == nil ? "" : String(cString: buffer)
    }
}
