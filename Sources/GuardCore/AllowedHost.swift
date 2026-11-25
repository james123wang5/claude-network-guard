import Foundation

/// 用户明确放行的一个内网地址和端口，例如公司服务器 10.1.2.3:22。只接受单个内网 IPv4，不接受网段和域名。
public struct AllowedHost: Equatable, Sendable {
    public static let limit = 4
    private static let ranges = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10"].compactMap(AddressBlock.init)

    public let address: String
    public let port: UInt16

    public init?(_ text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }), let block = AddressBlock(String(parts[0])),
              block.isIPv4, block.prefix == 32, Self.ranges.contains(where: { $0.contains(block) }),
              parts[1].allSatisfy({ $0.isASCII && $0.isNumber }), let port = UInt16(parts[1]), port > 0 else { return nil }
        address = block.bytes.map(String.init).joined(separator: ".")
        self.port = port
    }

    public var text: String { "\(address):\(port)" }

    /// 有任何一项不合格就返回 nil，不悄悄丢掉。
    public static func parse(_ input: String) -> [Self]? {
        let items = input.split { $0.isWhitespace || $0 == "," || $0 == "，" }.map(String.init)
        let hosts = items.compactMap(Self.init)
        guard hosts.count == items.count, hosts.count <= limit else { return nil }
        return hosts.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    /// 只有路由走 VPN 虚拟网卡时才放行；VPN 没开时它会指向 Wi‑Fi，那就不放。
    public static func usable(interface: String?) -> Bool {
        interface?.range(of: #"^(utun|ppp|ipsec)[0-9]{1,4}\z"#, options: .regularExpression) != nil
    }
}

public struct AllowedRoute: Equatable, Sendable {
    public let host: AllowedHost
    public let interface: String
    public init(host: AllowedHost, interface: String) { self.host = host; self.interface = interface }
}
