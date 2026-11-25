import Foundation

struct NativeNetworkMonitor: Sendable {
    struct Exit: Equatable, Sendable {
        let address: String
        var country: String? = nil
        var sources: [String] = []
        var disagrees = false
    }

    struct Baseline: Equatable, Sendable {
        let routes: [IPFamily: Route]
        let exits: [IPFamily: Exit]
        /// 内核已把受保护应用限制在 IPv4 时，IPv6 地址轮换不算变化。
        var ipv4Only = false

        func sameRoutes(_ other: [IPFamily: Route]) -> Bool { ipv4Only ? other[.v4] == routes[.v4] : other == routes }

        func change(routes: [IPFamily: Route], exits: [IPFamily: Exit]) -> Failure? {
            if !sameRoutes(routes) { return .routeChanged }
            if ipv4Only { return exits[.v4]?.address == self.exits[.v4]?.address ? nil : .exitChanged }
            if exits.mapValues(\.address) != self.exits.mapValues(\.address) { return .exitChanged }
            return nil
        }
    }

    enum Failure: Error {
        case noRoute, routeChanged, unavailable, exitChanged, dnsUnavailable, serviceUnavailable, unexpectedRegion, inconsistentProbes, internetUnavailable, regionUnverified, exitProofExpired, sampleInterrupted

        var explanation: String {
            switch self {
            case .noRoute: "未找到可用的 Mac 网络路径。"
            case .routeChanged: "Mac 的网络路径已改变。"
            case .unavailable: "无法确认当前公网出口。"
            case .exitChanged: "当前公网出口已改变。"
            case .dnsUnavailable: "Mac 无法解析 Claude 的服务域名。"
            case .serviceUnavailable: "Claude 服务没有返回可用的 HTTPS 响应。"
            case .unexpectedRegion: "出口地区不符合设定。"
            case .regionUnverified: "无法确认出口是否属于设定地区。"
            case .exitProofExpired: "出口连续多次无法核验，已达到 60 秒容忍期限。"
            case .sampleInterrupted: "复查期间收到新的网络变化，结果暂不能确认。"
            case .inconsistentProbes: "公网检测来源返回不同地址，无法确认统一出口。"
            case .internetUnavailable: "公网出口、独立连通性和 Claude 服务探测同时失败。"
            }
        }
    }

    var routes: @Sendable () async -> [IPFamily: Route] = {
        await Task.detached(priority: .utility) { NetworkCheck.systemRoutes() }.value
    }
    var readExit: @Sendable (IPFamily) async -> Exit? = { await Self.readExit($0) }

    func report(using diagnostics: NativeDiagnostics, enrich: Bool, requiredRegion: String? = nil) async -> NativeDiagnostics.Report {
        let initial = await routes()
        async let checks = diagnostics.serviceChecks()
        let exits = await sampleExits(initial)
        let (resolved, services) = await checks
        let independentReachable = initial.count != exits.count
            ? await diagnostics.probeService("www.apple.com").map { $0.status < 500 } : nil
        let owner = enrich ? await NativeDiagnostics.networkOwner(exits[.v4] ?? exits[.v6]) : nil
        return NativeDiagnostics.Report(date: Date(), routes: initial, exits: exits,
                                        stablePaths: await routes() == initial, resolved: resolved,
                                        services: services, serviceHosts: diagnostics.hosts, skippedHosts: diagnostics.skippedHosts, owner: owner, requiredRegion: requiredRegion, independentReachable: independentReachable, resolverEvidence: ResolverEvidence.read())
    }

    private func sampleExits(_ routes: [IPFamily: Route]) async -> [IPFamily: Exit] {
        await withTaskGroup(of: (IPFamily, Exit?).self) { group in
            for family in routes.keys {
                group.addTask { (family, await readExit(family)) }
            }
            var values: [IPFamily: Exit] = [:]
            for await (family, exit) in group { values[family] = exit }
            return values
        }
    }

    struct Source: Sendable {
        let name: String
        let url: String
        var trace = false
    }

    static func consensus(_ readings: [(Source, Exit)]) -> Exit? {
        guard var first = readings.first?.1 else { return nil }
        first.sources = readings.map { $0.0.name }
        first.disagrees = Set(readings.map { $0.1.address }).count > 1
        return first
    }

    private static func readExit(_ family: IPFamily) async -> Exit? {
        let backups = family == .v4
            ? [Source(name: "AWS", url: "https://checkip.amazonaws.com/"),
               Source(name: "ipify", url: "https://api.ipify.org/")]
            : [Source(name: "icanhazip", url: "https://ipv6.icanhazip.com/"),
               Source(name: "ipify", url: "https://api6.ipify.org/")]
        let sources = [Source(name: "Cloudflare", url: family.url, trace: true)] + backups
        return await withTaskGroup(of: (Int, Exit?).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask { (index, await fetch(source, family: family)) }
            }
            var samples: [Int: Exit] = [:]
            for await (index, exit) in group { samples[index] = exit }
            return consensus(sources.enumerated().compactMap { index, source in
                samples[index].map { (source, $0) }
            })
        }
    }

    private static func fetch(_ source: Source, family: IPFamily) async -> Exit? {
        guard let url = URL(string: source.url) else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 4
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        guard let (data, response) = try? await session.data(from: url),
              let response = response as? HTTPURLResponse,
              response.statusCode == 200, response.url == url,
              data.count <= 8192,
              let body = String(data: data, encoding: .utf8) else { return nil }
        let lines = body.split(whereSeparator: \.isNewline)
        let ip = source.trace ? lines.first(where: { $0.hasPrefix("ip=") }).map { String($0.dropFirst(3)) }
            : body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let address = ip.flatMap(family.normalizedAddress), isPublic(address, family: family) else { return nil }
        let region = source.trace ? lines.first(where: { $0.hasPrefix("loc=") }).map { String($0.dropFirst(4)) } : nil
        let country = region.flatMap { $0.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil && $0 != "XX" ? $0 : nil }
        return Exit(address: address, country: country)
    }

    private static func isPublic(_ address: String, family: IPFamily) -> Bool {
        if family == .v6 { return address.hasPrefix("2") || address.hasPrefix("3") }
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (0, _), (10, _), (100, 64...127), (127, _), (169, 254), (172, 16...31),
             (192, 168), (198, 18...19), (224...255, _): return false
        default: return true
        }
    }
}
