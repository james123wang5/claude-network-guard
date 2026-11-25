import Darwin
import Foundation

/// 一段 IP 地址（IPv4 或 IPv6）。
public struct AddressBlock: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]
    public let prefix: Int

    public init?(_ text: String) {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2, let first = parts.first else { return nil }
        let host = String(first.prefix { $0 != "%" })
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { bytes = withUnsafeBytes(of: &v4) { Array($0) } }
        else if inet_pton(AF_INET6, host, &v6) == 1 { bytes = withUnsafeBytes(of: &v6) { Array($0) } }
        else { return nil }
        guard let length = parts.count == 2 ? Int(parts[1]) : bytes.count * 8, (0...bytes.count * 8).contains(length) else { return nil }
        prefix = length
    }

    public var isIPv4: Bool { bytes.count == 4 }

    public func contains(_ other: AddressBlock) -> Bool {
        guard bytes.count == other.bytes.count, prefix <= other.prefix else { return false }
        for bit in 0..<prefix where (bytes[bit / 8] ^ other.bytes[bit / 8]) & (0x80 >> UInt8(bit % 8)) != 0 { return false }
        return true
    }

    public var description: String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let family = isIPv4 ? AF_INET : AF_INET6
        let text = bytes.withUnsafeBytes { inet_ntop(family, $0.baseAddress, &buffer, socklen_t(buffer.count)) == nil ? "" : String(cString: buffer) }
        return prefix == bytes.count * 8 ? text : "\(text)/\(prefix)"
    }
}

/// 服务拦截：保护期间，受保护应用以外的任何程序都不能经所选线路以外的网卡访问该应用的服务地址。
/// 受保护应用自己的改道规则在前一个锚点里先命中，不受影响。
public enum ServiceShield {
    public static let anchor = "com.apple/302.AppNetworkGuardService"
    public static let label = "angservice"
    public static let canaryLabel = "angcanary"
    /// RFC 5737 文档专用地址，不属于任何人。用它验证规则真的在拦，不需要碰真实服务。
    public static let canary = "192.0.2.1"

    /// 服务方公布的自有地址段：不与任何其他网站共用，可以整段拦截。
    private static let dedicated: [(domains: Set<String>, networks: [String])] = [
        (["claude.ai", "claude.com", "anthropic.com", "claudeusercontent.com"], ["160.79.104.0/23", "2607:6bc0::/48"])
    ]

    /// 常见子域名，与所填域名一起解析。
    private static let labels = ["", "www", "api", "a", "a-api", "a-cdn", "s-cdn", "cdn", "assets", "assets-proxy", "static", "downloads",
                                 "releases", "bridge", "console", "platform", "auth", "login", "mcp-proxy", "config", "support", "code", "docs"]

    /// 大型共享 CDN：一个地址上有许多无关网站，按地址拦会误伤，只如实报告“拦不到”。
    private static let shared: [AddressBlock] = """
    173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20
    197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22
    2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32
    151.101.0.0/16 199.232.0.0/16 146.75.0.0/16 2a04:4e40::/32 2a04:4e42::/32
    3.160.0.0/14 13.32.0.0/15 13.35.0.0/16 13.224.0.0/14 13.249.0.0/16 18.64.0.0/14 18.154.0.0/15 18.160.0.0/15 18.164.0.0/15 18.172.0.0/15
    18.238.0.0/15 18.244.0.0/15 52.84.0.0/15 54.182.0.0/16 54.192.0.0/16 54.230.0.0/16 54.239.128.0/18 99.84.0.0/16 108.138.0.0/15
    108.156.0.0/14 143.204.0.0/16 204.246.160.0/19 205.251.192.0/19 2600:9000::/28
    2.16.0.0/13 23.0.0.0/12 23.32.0.0/11 23.64.0.0/14 23.72.0.0/13 23.192.0.0/11 95.100.0.0/15 96.6.0.0/15 96.16.0.0/15 104.64.0.0/10
    184.24.0.0/13 184.50.0.0/15 184.84.0.0/14 2600:1400::/24 2a02:26f0::/29
    """.split(whereSeparator: \.isWhitespace).compactMap { AddressBlock(String($0)) }

    private static let local: [AddressBlock] = ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12",
        "192.168.0.0/16", "224.0.0.0/3", "::/8", "fc00::/7", "fe80::/10", "ff00::/8"].compactMap(AddressBlock.init)

    public static func fixedNetworks(for domains: [String]) -> [AddressBlock] {
        dedicated.filter { !$0.domains.isDisjoint(with: domains) }.flatMap(\.networks).compactMap(AddressBlock.init)
    }

    public static func names(for domains: [String]) -> [String] {
        domains.flatMap { domain in labels.map { $0.isEmpty ? domain : "\($0).\(domain)" } }
    }

    public static func isShared(_ address: AddressBlock) -> Bool { shared.contains { $0.contains(address) } }
    public static func isBlockable(_ address: AddressBlock) -> Bool { !isShared(address) && !local.contains { $0.contains(address) } }

    public static func rules(interface: String?, address: String = "", networks: [AddressBlock], canaryAnywhere: Bool = false) -> String {
        // 断线时不留任何例外：网卡名可能被别的设备重新占用。
        let target = interface.map { " on ! \($0)" } ?? ""
        // 所选线路就是默认线路时（VPN / 热点），验证用的包必然从它出去，带网卡条件就永远数不到。
        var lines = ["block drop out quick\(canaryAnywhere ? "" : target) inet from any to \(canary) label \"\(canaryLabel)\""]
        func add(_ condition: String, _ family: String, _ list: [AddressBlock]) {
            guard !list.isEmpty else { return }
            lines.append("block drop out quick\(condition) \(family) to { \(list.map(\.description).sorted().joined(separator: " ")) } label \"\(label)\"")
        }
        let v4 = networks.filter(\.isIPv4), v6 = networks.filter { !$0.isIPv4 }
        add(target, "inet from any", v4)
        add(target, "inet6 from any", v6)
        // 热点模式：同一块网卡换了网络，源地址就会变。
        if let interface, !address.isEmpty {
            add(" on \(interface)", "inet from ! \(address)", v4)
            add(" on \(interface)", "inet6 from any", v6)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// pfctl -s labels 的输出：每条规则一行“标签 评估 包数 字节 …”。
    public static func packets(in labels: String, label: String) -> UInt64? {
        let counts = labels.split(separator: "\n").compactMap { line -> UInt64? in
            let fields = line.split(separator: " ")
            return fields.count >= 3 && fields[0] == label ? UInt64(fields[2]) : nil
        }
        return counts.isEmpty ? nil : counts.reduce(0, +)
    }

    public static func exitAddress(in trace: String) -> String? {
        trace.split(separator: "\n").first { $0.hasPrefix("ip=") }.map { String($0.dropFirst(3)) }.flatMap { AddressBlock($0) == nil ? nil : $0 }
    }
}
