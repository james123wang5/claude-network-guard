import CoreWLAN
import Foundation
import SystemConfiguration

enum NativeProtectionMode: String, CaseIterable, Identifiable, Sendable {
    /// 只检查，不保护。
    case current = "当前网络"
    case vpn = "Mac VPN"
    case hotspot = "iPhone 无线热点"
    case usb = "iPhone USB 专线"

    static let protecting: [Self] = [.vpn, .hotspot, .usb]
    var id: Self { self }

    var instructions: String {
        switch self {
        case .current: "只检查这台 Mac 现在走的网络，不做保护。"
        case .vpn: "先自行连接全机 VPN。Guard 会检查实际访问路径和是否存在可见的分流。"
        case .hotspot: "先在 Mac 的 Wi-Fi 里连接 iPhone 热点。Guard 会核对当前热点并监测是否换线。"
        case .usb: "用数据线连接 iPhone 并打开个人热点。只有 Claude 走 USB，Mac 其他应用保持原来的网络。"
        }
    }
}

struct NativeProtectionPolicy: Sendable {
    struct RequirementError: Error {
        let reason: String
    }

    struct Evidence: Sendable {
        let mode: NativeProtectionMode
        let interface: String
        let hotspotID: String?
        let checkedTargets: Int
        let dnsRoutes: Int

        var summary: String {
            "\(mode.rawValue) · \(interface) · 核对了 \(checkedTargets) 个目标路径"
        }

        func matches(_ previous: Self) -> Bool {
            mode == previous.mode && interface == previous.interface && hotspotID == previous.hotspotID
        }
    }

    private static let internetTargets = ["1.1.1.1", "149.112.112.112", "208.67.222.222",
                                          "2606:4700:4700::1111", "2620:fe::fe"]

    static func evaluate(_ mode: NativeProtectionMode, routes: [String: Route],
                         hotspotIDs: [String: String], proxy: Bool,
                         serviceTargets: [String] = [], dnsTargets: [String] = []) throws -> Evidence {
        if proxy {
            throw RequirementError(reason: "检测到系统代理或自动代理。无法确认 Claude 会沿所选线路联网。")
        }
        guard let primary = routes["1.1.1.1"], routes["149.112.112.112"] != nil,
              routes["208.67.222.222"] != nil else {
            throw RequirementError(reason: "无法核对所有必要的 IPv4 系统路径。")
        }
        let name = primary.interface
        let hotspotID: String?
        switch mode {
        case .vpn:
            guard name.range(of: #"^(utun|ppp|ipsec)[0-9]+$"#, options: .regularExpression) != nil else {
                throw RequirementError(reason: "当前公网路径没有经过 VPN 隧道。请先连接全机 VPN。")
            }
            hotspotID = nil
        case .hotspot:
            guard let identity = hotspotIDs[name] else {
                throw RequirementError(reason: "当前公网线路无法确认为 iPhone 热点。请在 Mac 的 Wi-Fi 中核对连接。")
            }
            hotspotID = identity
        case .current:
            throw RequirementError(reason: "当前网络只用来检查，不能启动保护。")
        case .usb:
            throw RequirementError(reason: "USB 专线使用独立的启动检查。")
        }
        if routes.values.contains(where: { $0.interface != name }) {
            throw RequirementError(reason: "抽查发现部分目标经其他网卡，当前线路不满足全机保护条件。")
        }
        let hasIPv6Path = routes.keys.contains { IPFamily.v6.normalizedAddress($0) != nil }
        if !serviceTargets.allSatisfy({ routes[$0] != nil || (!hasIPv6Path && IPFamily.v6.normalizedAddress($0) != nil) }) {
            throw RequirementError(reason: "Claude 服务的部分已解析地址没有可核对的路径。")
        }
        return Evidence(mode: mode, interface: name, hotspotID: hotspotID,
                        checkedTargets: routes.count, dnsRoutes: dnsTargets.filter { routes[$0] != nil }.count)
    }

    static func inspect(_ mode: NativeProtectionMode, extraTargets: [String] = [],
                        dnsTargets: [String] = []) async throws -> Evidence {
        try await Task.detached(priority: .utility) {
            let targets = Set(internetTargets + extraTargets + dnsTargets)
            var routes: [String: Route] = [:]
            for target in targets {
                if let route = NetworkCheck.route(to: target) { routes[target] = route }
            }
            var hotspotIDs: [String: String] = [:]
            if mode == .hotspot, let primary = routes["1.1.1.1"],
               let id = NetworkCheck.nativeHotspotIdentity(primary.interface) {
                hotspotIDs[primary.interface] = id
            }
            return try evaluate(mode, routes: routes, hotspotIDs: hotspotIDs,
                                proxy: hasSystemProxy(), serviceTargets: extraTargets, dnsTargets: dnsTargets)
        }.value
    }

    static func serviceTargets(_ hosts: [String]) async -> [String] {
        await withTaskGroup(of: [String].self) { group in
            for host in hosts {
                group.addTask { Array((await NativeDiagnostics.systemAddresses(for: host)).sorted().prefix(8)) }
            }
            var addresses: Set<String> = []
            for await groupAddresses in group { addresses.formUnion(groupAddresses) }
            return addresses.sorted()
        }
    }

    static func defaultDNSTargets() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "Guard Scoped DNS" as CFString, nil, nil),
              let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
              let addresses = dns["ServerAddresses"] as? [String] else { return [] }
        return Array(addresses.filter { !$0.hasPrefix("127.") && $0 != "::1" &&
            !$0.lowercased().hasPrefix("fe80:") && !$0.contains("%")
        }.prefix(8))
    }

    static func hasSystemProxy() -> Bool {
        guard let values = SCDynamicStoreCopyProxies(nil) as? [String: Any] else { return false }
        return activeProxy(values)
    }

    static func activeProxy(_ values: [String: Any], autoDiscoveryResolves: () -> Bool = wpadResolves) -> Bool {
        let flags = ["HTTPEnable", "HTTPSEnable", "SOCKSEnable"]
        if flags.contains(where: { (values[$0] as? NSNumber)?.boolValue == true }) { return true }
        let automatic = ["ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"]
        if automatic.contains(where: { (values[$0] as? NSNumber)?.boolValue == true }) {
            // 只打开“自动发现”而网络里并没有 wpad 主机时，系统实际直连，不应拒绝启动。
            let host = (values["ProxyAutoConfigURLString"] as? String).flatMap { URL(string: $0)?.host }
            if let host, host != "wpad" { return true }
            if autoDiscoveryResolves() { return true }
        }
        for key in ["__SCOPED__", "__SUPPLEMENTAL__"] {
            if let nested = values[key] as? [String: [String: Any]],
               nested.values.contains(where: { activeProxy($0, autoDiscoveryResolves: autoDiscoveryResolves) }) { return true }
            if let nested = values[key] as? [[String: Any]],
               nested.contains(where: { activeProxy($0, autoDiscoveryResolves: autoDiscoveryResolves) }) { return true }
        }
        return false
    }

    private static let wpadCache = WPADCache()

    static func wpadResolves() -> Bool { wpadCache.value() }
}

private final class WPADCache: @unchecked Sendable {
    private let lock = NSLock()
    private var checked: ContinuousClock.Instant?
    private var result = false

    func value() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let checked, checked.duration(to: .now) < .seconds(20) { return result }
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        result = getaddrinfo("wpad", "80", &hints, &list) == 0
        if let list { freeaddrinfo(list) }
        checked = .now
        return result
    }
}
