import Foundation

/// 侧栏用的系统路径快照，以及线路变化记录。
@MainActor
final class GuardModel: ObservableObject {
    struct Event: Identifiable {
        let id = UUID()
        let time = Date()
        let message: String
    }

    @Published private(set) var routes: [IPFamily: Route]?
    @Published private(set) var events: [Event] = []
    private var plain: [IPFamily: Route]?
    private var monitoring: Task<Void, Never>?

    func start() {
        guard monitoring == nil else { return }
        monitoring = Task { [weak self] in
            while !Task.isCancelled {
                let plain = await Task.detached(priority: .utility) { NetworkCheck.systemRoutes() }.value
                guard let self else { return }
                // 网卡名称查询较慢，只在路径变化时进行。
                if plain != self.plain {
                    self.plain = plain
                    let next = await Task.detached(priority: .utility) { NetworkCheck.systemRoutes(labels: NetworkCheck.interfaceLabels()) }.value
                    if self.routes != nil { self.record("Mac 默认线路变为 \(next[.v4]?.interface ?? "无")") }
                    self.routes = next
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func path(_ family: IPFamily) -> String {
        guard let routes else { return "正在读取" }
        guard let route = routes[family] else { return "无可用路径" }
        return route.displayName.map { "\($0) · \(route.interface)" } ?? route.interface
    }

    private func record(_ message: String) {
        events.insert(Event(message: message), at: 0)
        if events.count > 60 { events.removeLast() }
    }
}
