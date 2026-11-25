import AppKit
import Network
import SystemConfiguration

enum NetworkEvent: String, CaseIterable, Codable, Sendable {
    case path = "网络路径变化"
    case interface = "网卡或地址变化"
    case vpn = "VPN 配置或状态变化"
    case dns = "DNS 设置变化"
    case proxy = "系统代理变化"
    case sleep = "Mac 即将睡眠"
    case wake = "Mac 已唤醒"

    static func classify(_ keys: [String]) -> Set<Self> {
        Set(keys.compactMap { key in
            if key.hasSuffix("/DNS") { return .dns }
            if key.hasSuffix("/Proxies") { return .proxy }
            if ["/VPN", "/PPP", "/IPSec"].contains(where: { key.hasSuffix($0) }) { return .vpn }
            if key.contains("/Interface/") { return .interface }
            if key.hasSuffix("/IPv4") || key.hasSuffix("/IPv6") { return .path }
            return nil
        })
    }
}

@MainActor
final class NetworkEvents {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "local.appnetworkguard.events")
    private var previousPath: String?
    private var store: SCDynamicStore?
    private var observers: [NSObjectProtocol] = []
    private let handler: @MainActor (NetworkEvent) -> Void

    init(handler: @escaping @MainActor (NetworkEvent) -> Void) {
        self.handler = handler
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        store = SCDynamicStoreCreate(nil, "App Network Guard" as CFString, { _, keys, info in
            guard let info else { return }
            let watcher = Unmanaged<NetworkEvents>.fromOpaque(info).takeUnretainedValue()
            let events = NetworkEvent.classify(keys as? [String] ?? [])
            Task { @MainActor in
                for event in NetworkEvent.allCases where events.contains(event) { watcher.handler(event) }
            }
        }, &context)
        if let store {
            let patterns = [
                "State:/Network/Global/(IPv4|IPv6|DNS|Proxies)",
                "(State|Setup):/Network/Service/[^/]+/(IPv4|IPv6|DNS|Proxies|VPN|PPP|IPSec)",
                "State:/Network/Interface/[^/]+/(Link|IPv4|IPv6|AirPort)"
            ]
            SCDynamicStoreSetNotificationKeys(store, nil, patterns as CFArray)
            SCDynamicStoreSetDispatchQueue(store, .main)
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let state = "\(path.status)|\(path.availableInterfaces.map(\.name).sorted())"
            Task { @MainActor in
                if let self {
                    if let previousPath = self.previousPath, previousPath != state { self.handler(.path) }
                    self.previousPath = state
                }
            }
        }
        monitor.start(queue: queue)

        let center = NSWorkspace.shared.notificationCenter
        for (name, event) in [(NSWorkspace.willSleepNotification, NetworkEvent.sleep),
                              (NSWorkspace.didWakeNotification, NetworkEvent.wake)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handler(event) }
            })
        }
    }

    deinit {
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
        monitor.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}

enum ResolverEvidence: Sendable {
    case matching, different

    var summary: String {
        switch self {
        case .matching: "系统默认 DNS 与当前主要网络服务的配置一致"
        case .different: "系统默认 DNS 与当前主要网络服务的配置不同，可能存在分流解析"
        }
    }

    static func read() -> Self? {
        guard let store = SCDynamicStoreCreate(nil, "Guard DNS" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
              let ip = (SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any])
                    ?? (SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv6" as CFString) as? [String: Any]),
              let service = ip["PrimaryService"] as? String,
              let scoped = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(service)/DNS" as CFString) as? [String: Any],
              let main = global["ServerAddresses"] as? [String], !main.isEmpty,
              let local = scoped["ServerAddresses"] as? [String], !local.isEmpty else { return nil }
        return main == local ? .matching : .different
    }
}
