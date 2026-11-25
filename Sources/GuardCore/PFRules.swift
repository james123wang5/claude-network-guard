import Foundation

/// 生成 PF 规则。实测结论（macOS 27.2，见 ARCHITECTURE_USB.md）：
/// - TCP 可按组归属；UDP 在有内容过滤器的系统上归到 root，不能依赖 group 匹配。
/// - route-to + NAT 必须使用 if-bound 状态，否则后续包会回到默认网卡。
public struct PFRules: Equatable, Sendable {
    public static let anchor = "com.apple/300.AppNetworkGuard"
    /// 逐条连接的封锁：只针对审计到的那个套接字，套接字关闭后规则随之消失。
    public static let socketAnchor = "com.apple/301.AppNetworkGuardSockets"

    public static func socketRules(_ sockets: Set<InternetSocket>) -> String {
        sockets.map { socket in
            "block return out quick proto \(socket.udp ? "udp" : "tcp") from any port \(socket.localPort) to \(socket.remote) port \(socket.remotePort)"
        }.sorted().joined(separator: "\n") + "\n"
    }

    static let privateNetworks = "{ 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10 224.0.0.0/4 }"

    public var gid: UInt32
    public var mode: IsolationMode
    public var armed: Bool
    public var interface: String
    public var address: String
    public var gateway: String
    /// 仅当目标应用不能套用进程级限制时，才在默认线路上临时封锁 QUIC（会影响其他应用）。
    public var quicFallback: String?
    public var relayPort: UInt16?
    public var localProxyPorts: [UInt16] = []
    /// 受保护域名使用的 DNS 服务器，禁止从 USB 以外的网卡访问。
    public var guardedDNS: [String] = []

    /// 用户放行的内网地址，以及它当前走的 VPN 虚拟网卡。只在没有断网时生效。
    public var allowed: [AllowedRoute] = []

    public init(gid: UInt32, mode: IsolationMode, armed: Bool, interface: String, address: String, gateway: String) {
        self.gid = gid; self.mode = mode; self.armed = armed
        self.interface = interface; self.address = address; self.gateway = gateway
    }

    public func text() -> String {
        var lines: [String] = []
        if mode == .usb {
            if armed { lines.append("nat on \(interface) inet proto tcp from ! \(address) to any -> \(address)") }
        }
        if let relayPort {
            lines.append("pass out quick on lo0 inet proto tcp from any to 127.0.0.1 port \(relayPort) group \(gid) no state")
            lines.append("block return out quick on lo0 inet proto tcp from any to 127.0.0.1 port \(relayPort)")
        }
        // 本机代理会替应用从别的线路出去，因此对受保护组关闭。
        for port in Set(localProxyPorts).sorted() where port != relayPort {
            lines.append("block return out quick on lo0 proto tcp from any to any port \(port) group \(gid)")
        }
        lines.append("pass quick on lo0 all no state")
        if armed {
            for item in allowed {
                lines.append("pass out quick on \(item.interface) inet proto tcp from any to \(item.host.address) port \(item.host.port) group \(gid) no state")
            }
        }
        if mode == .usb {
            for server in guardedDNS { lines.append("block return out quick on ! \(interface) inet from any to \(server)") }
            if let quicFallback, quicFallback != interface {
                lines.append("block return out quick on \(quicFallback) proto udp from any to any port { 80 443 }")
            }
            lines.append("block return out quick proto udp all group \(gid)")
            if armed {
                lines.append("pass out quick on \(interface) inet proto tcp all keep state (if-bound)")
                lines.append("block return out quick on ! \(interface) inet proto tcp from any to \(Self.privateNetworks) group \(gid)")
                lines.append("pass out quick on ! \(interface) route-to (\(interface) \(gateway)) inet proto tcp all group \(gid) no state label \"angredirect\"")
            }
        } else if armed {
            lines.append("block return out quick on ! \(interface) proto { tcp udp } all group \(gid)")
            if !address.isEmpty {
                // 同一块 Wi-Fi 网卡换到其他网络时，源地址改变即被内核拒绝。
                lines.append("block return out quick on \(interface) inet proto { tcp udp } from ! \(address) to any group \(gid)")
            }
            // 认可的是 IPv4 出口，因此和 USB 一样只放行 IPv4。能套进程级限制时 UDP 也在那一层关闭。
            lines.append("block return out quick on \(interface) inet6 proto { tcp udp } all group \(gid)")
            lines.append("pass out quick on \(interface) inet proto { tcp udp } all group \(gid) no state")
        }
        lines.append("block return out quick all group \(gid)")
        return lines.joined(separator: "\n") + "\n"
    }
}
