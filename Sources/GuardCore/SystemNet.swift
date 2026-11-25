import Darwin
import Foundation
import SystemConfiguration

public struct LinkState: Equatable, Sendable {
    public let index: UInt32
    public let addresses: Set<String>

    /// 网卡在线时的索引和可用地址；离线或无地址返回 nil。
    public static func read(_ name: String) -> Self? {
        let index = if_nametoindex(name)
        guard index != 0 else { return nil }
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var result: Set<String> = []
        var next = head
        while let item = next?.pointee {
            next = item.ifa_next
            guard String(cString: item.ifa_name) == name, let address = item.ifa_addr,
                  item.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
                  [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family)) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host).prefix { $0 != "%" }
            if text.hasPrefix("fe80:") || text.hasPrefix("169.254.") { continue }
            result.insert(String(text))
        }
        return result.isEmpty ? nil : Self(index: index, addresses: result)
    }

    /// 正在使用这个本机地址的网卡。
    public static func interface(holding address: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var next = head
        while let item = next?.pointee {
            next = item.ifa_next
            guard let value = item.ifa_addr, [AF_INET, AF_INET6].contains(Int32(value.pointee.sa_family)) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(value, socklen_t(value.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            if String(String(cString: host).prefix { $0 != "%" }) == address { return String(cString: item.ifa_name) }
        }
        return nil
    }

    public var ipv4: String? { addresses.filter { !$0.contains(":") }.sorted().first }
}

public struct USBLine: Equatable, Sendable {
    public let interface: String
    public let link: LinkState
    public let address: String
    public let gateway: String
    public let dns: [String]

    private static let cacheLock = NSLock()
    private static var cache: (key: String, names: [String])?

    /// 枚举硬件端口较慢；只在网卡集合（含索引）变化时重新枚举。重新插拔会改变索引。
    public static func interfaces() -> [String] {
        var key = ""
        if let list = if_nameindex() {
            var item = list
            while item.pointee.if_index != 0 {
                key += "\(item.pointee.if_index):\(String(cString: item.pointee.if_name)) "
                item += 1
            }
            if_freenameindex(list)
        }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cache, cache.key == key { return cache.names }
        let names = enumerate()
        cache = (key, names)
        return names
    }

    private static func enumerate() -> [String] {
        let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        return all.compactMap { item in
            let label = SCNetworkInterfaceGetLocalizedDisplayName(item) as String? ?? ""
            guard label.localizedCaseInsensitiveContains("iPhone"), label.localizedCaseInsensitiveContains("USB") else { return nil }
            return SCNetworkInterfaceGetBSDName(item) as String?
        }.sorted()
    }

    public static func read(_ interface: String) -> Self? {
        guard interfaces().contains(interface), let link = LinkState.read(interface), let address = link.ipv4,
              let store = SCDynamicStoreCreate(nil, "App Network Guard" as CFString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String] else { return nil }
        for key in keys {
            guard let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  value["InterfaceName"] as? String == interface, let router = value["Router"] as? String,
                  (value["Addresses"] as? [String])?.contains(address) == true else { continue }
            let service = key.replacingOccurrences(of: "/IPv4", with: "/DNS")
            let dns = (SCDynamicStoreCopyValue(store, service as CFString) as? [String: Any])?["ServerAddresses"] as? [String] ?? []
            let usable = dns.filter { !$0.contains(":") }
            return Self(interface: interface, link: link, address: address, gateway: router, dns: usable.isEmpty ? [router] : usable)
        }
        return nil
    }
}

public enum SystemProxy {
    /// 指向本机的系统代理端口（包括按网卡和补充配置）。
    public static func localPorts(_ values: [String: Any]? = nil) -> [UInt16] {
        guard let values = values ?? (SCDynamicStoreCopyProxies(nil) as? [String: Any]) else { return [] }
        var ports: [UInt16] = []
        for kind in ["HTTP", "HTTPS", "SOCKS"] {
            guard (values[kind + "Enable"] as? NSNumber)?.boolValue == true, let host = values[kind + "Proxy"] as? String,
                  host == "localhost" || host.hasPrefix("127.") || host == "::1",
                  let port = (values[kind + "Port"] as? NSNumber)?.uint16Value, port > 0 else { continue }
            ports.append(port)
        }
        for key in ["__SCOPED__", "__SUPPLEMENTAL__"] {
            if let nested = values[key] as? [String: [String: Any]] { nested.values.forEach { ports += localPorts($0) } }
            if let nested = values[key] as? [[String: Any]] { nested.forEach { ports += localPorts($0) } }
        }
        return Array(Set(ports)).sorted()
    }
}
