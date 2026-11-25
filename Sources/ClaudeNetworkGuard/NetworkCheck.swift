import BoundTransport
import CryptoKit
import Darwin
import Foundation
import SystemConfiguration

enum IPFamily: String, CaseIterable, Identifiable, Sendable {
    case v4 = "IPv4"
    case v6 = "IPv6"

    var id: Self { self }
    var addressFamily: Int32 { self == .v4 ? AF_INET : AF_INET6 }
    var target: String { self == .v4 ? "1.1.1.1" : "2606:4700:4700::1111" }
    var url: String {
        self == .v4 ? "https://\(target)/cdn-cgi/trace" : "https://[\(target)]/cdn-cgi/trace"
    }

    func normalizedAddress(_ value: String) -> String? {
        let address = String(value.prefix(while: { $0 != "%" }))
        var binary = in6_addr()
        guard inet_pton(addressFamily, address, &binary) == 1 else { return nil }
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(addressFamily, &binary, &output, socklen_t(output.count)) != nil else { return nil }
        return String(cString: output)
    }
}

struct Route: Equatable, Sendable {
    let interface: String
    let gateway: String?
    var displayName: String? = nil
}

enum NetworkCheck {
    static func interfaceLabels() -> [String: String] {
        let hardware = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        var labels: [String: String] = [:]
        for item in hardware {
            if let id = SCNetworkInterfaceGetBSDName(item) as String?,
               let label = SCNetworkInterfaceGetLocalizedDisplayName(item) as String? {
                labels[id] = label
            }
        }
        return labels
    }

    static func systemRoutes(labels: [String: String] = [:]) -> [IPFamily: Route] {
        var routes: [IPFamily: Route] = [:]
        for family in IPFamily.allCases {
            if var found = route(family) {
                found.displayName = labels[found.interface]
                routes[family] = found
            }
        }
        return routes
    }

    private static func interfaces(_ matches: (String, String) -> Bool) -> Set<String> {
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        return Set(interfaces.compactMap { interface in
            let label = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? ""
            let type = SCNetworkInterfaceGetInterfaceType(interface) as String? ?? ""
            return matches(label, type) ? SCNetworkInterfaceGetBSDName(interface) as String? : nil
        })
    }

    static func nativeHotspotIdentity(_ interface: String) -> String? {
        guard interfaces({ _, type in type == "IEEE80211" }).contains(interface),
              let store = SCDynamicStoreCreate(nil, "Guard Hotspot" as CFString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String] else { return nil }
        for key in keys {
            if let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
               let identity = hotspotIdentity(value, interface: interface) { return identity }
        }
        return nil
    }

    /// 系统网络状态里的一条 IPv4 配置是否为 iPhone 热点；返回网关硬件地址的摘要，用来发现换了另一台手机。
    /// 不用 arp 命令：macOS 的本地网络隐私会让本 App 启动的 arp 查不到网关。
    static func hotspotIdentity(_ value: [String: Any], interface: String) -> String? {
        guard value["InterfaceName"] as? String == interface, value["Router"] as? String == "172.20.10.1",
              value["ARPResolvedIPAddress"] as? String == "172.20.10.1",
              (value["SubnetMasks"] as? [String])?.contains("255.255.255.240") == true,
              let hardware = value["ARPResolvedHardwareAddress"] as? String, !hardware.isEmpty else { return nil }
        return SHA256.hash(data: Data(hardware.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func route(to address: String) -> Route? {
        guard let family = IPFamily.allCases.first(where: { $0.normalizedAddress(address) != nil }) else { return nil }
        return route(family, target: address)
    }

    /// 直接向内核查询路由，不启动子进程，可以高频调用。
    private static func route(_ family: IPFamily, target: String? = nil) -> Route? {
        var interface = [CChar](repeating: 0, count: 32)
        var gateway = [CChar](repeating: 0, count: 64)
        var blocked: Int32 = 0
        guard guard_route(target ?? family.target, &interface, interface.count, &gateway, gateway.count, &blocked) == 1,
              blocked == 0 else { return nil }
        let name = String(cString: gateway)
        return Route(interface: String(cString: interface), gateway: name.isEmpty || name == "link" ? nil : name)
    }
}
