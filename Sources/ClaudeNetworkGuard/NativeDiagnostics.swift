import Darwin
import Foundation

struct NativeDiagnostics: Sendable {
    var hosts: [String] = []
    /// 当前不是所选线路，为避免暴露地址而没有访问的服务。
    var skippedHosts: [String] = []

    enum Verdict: Sendable {
        case passed, warning, failed, unknown
    }

    struct Row: Identifiable, Sendable {
        let id: String
        let title: String
        let evidence: String
        let verdict: Verdict
    }

    struct Service: Sendable {
        let status: Int
        let milliseconds: Int

        var verdict: Verdict {
            switch status {
            case 200..<400: .passed
            case 400..<500: .warning
            default: .failed
            }
        }
    }

    struct NetworkOwner: Sendable {
        let asn: String
        let name: String?
    }

    struct Report: Sendable {
        let date: Date
        let routes: [IPFamily: Route]
        var exits: [IPFamily: NativeNetworkMonitor.Exit]
        let stablePaths: Bool
        let resolved: Set<String>
        let services: [String: Service]
        var serviceHosts: [String] = []
        var skippedHosts: [String] = []
        var owner: NetworkOwner?
        var requiredRegion: String? = nil
        var change: NativeNetworkMonitor.Failure? = nil
        var independentReachable: Bool? = nil
        var resolverEvidence: ResolverEvidence? = nil

        var exitProofAvailable: Bool {
            guard stablePaths, !routes.isEmpty, routes.keys.allSatisfy({ exits[$0]?.disagrees == false }) else {
                return false
            }
            switch change {
            case .routeChanged, .exitChanged, .noRoute, .internetUnavailable, .exitProofExpired, .sampleInterrupted:
                return false
            default:
                return requiredRegion == nil || exits.values.allSatisfy { $0.country != nil }
            }
        }

        var failure: NativeNetworkMonitor.Failure? {
            if let change { return change }
            if !stablePaths { return .routeChanged }
            if routes.isEmpty { return .noRoute }
            if exits.values.contains(where: \.disagrees) { return .inconsistentProbes }
            if routes.count != exits.count { return .unavailable }
            if let requiredRegion {
                if exits.values.contains(where: { $0.country.map { $0 != requiredRegion } == true }) {
                    return .unexpectedRegion
                }
                if exits.values.contains(where: { $0.country == nil }) { return .regionUnverified }
            }
            if !Set(serviceHosts).isSubset(of: resolved) { return .dnsUnavailable }
            if serviceHosts.contains(where: { (services[$0]?.verdict ?? .failed) == .failed }) {
                return .serviceUnavailable
            }
            return nil
        }

        enum FollowUp: Equatable {
            case healthy, warn(NativeNetworkMonitor.Failure), reconsiderDisconnect, stop(NativeNetworkMonitor.Failure)
        }

        var followUp: FollowUp {
            guard let failure else { return .healthy }
            switch failure {
            case .noRoute, .routeChanged, .exitChanged, .unexpectedRegion:
                return .stop(failure)
            case .unavailable where exits.isEmpty && independentReachable == false && services.isEmpty:
                return .reconsiderDisconnect
            default:
                return .warn(failure)
            }
        }

        var regionName: String? {
            requiredRegion.map { Locale(identifier: "zh_CN").localizedString(forRegionCode: $0) ?? $0 }
        }

        var latency: Int? { serviceHosts.first.flatMap { services[$0]?.milliseconds } }

        func rows(hideAddresses: Bool) -> [Row] {
            var rows = IPFamily.allCases.flatMap { family -> [Row] in
                let route = routes[family]
                let exit = exits[family]
                let location = exit?.country.flatMap { Locale(identifier: "zh_CN").localizedString(forRegionCode: $0) }
                let address = exit.map { hideAddresses ? "地址已隐藏" : $0.address }
                let source = exit.map { $0.sources.joined(separator: " / ") }
                let exitDetails = [address, location, source].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                return [
                    Row(id: family.rawValue + "-path", title: "\(family.rawValue) 系统路径",
                        evidence: route?.interface ?? "未找到查询路径",
                        verdict: route == nil ? .unknown : stablePaths ? .passed : .failed),
                    Row(id: family.rawValue + "-exit", title: "\(family.rawValue) 公网出口",
                        evidence: exit?.disagrees == true ? "多个来源返回不同出口 · " + exitDetails :
                            exit.map { _ in exitDetails } ?? "未取得公网地址",
                        verdict: route == nil ? .unknown : exit == nil || exit?.disagrees == true ? .failed : stablePaths ? .passed : .warning)
                ]
            }
            if serviceHosts.isEmpty, !skippedHosts.isEmpty {
                rows.append(Row(id: "service-skipped", title: "Claude 服务",
                                evidence: "没有访问：避免把没认可或刚变化的 IP 交给对方", verdict: .unknown))
            } else if serviceHosts.isEmpty {
                rows.append(Row(id: "service-unconfigured", title: "Claude 服务", evidence: "未配置域名", verdict: .unknown))
            }
            for host in serviceHosts {
                let hasDNS = resolved.contains(host)
                rows.append(Row(id: host + "-dns", title: "DNS · \(host)",
                                evidence: hasDNS ? "Mac 的解析器返回地址" : "Mac 的解析器未返回地址",
                                verdict: hasDNS ? .passed : .failed))
                let service = services[host]
                let evidence = service.map {
                    switch $0.verdict {
                    case .warning: "收到 HTTP \($0.status) · \($0.milliseconds) ms · 实际使用需在 Claude 内确认"
                    default: "HTTP \($0.status) · \($0.milliseconds) ms"
                    }
                } ?? "未收到有效 HTTPS 响应"
                rows.append(Row(id: host + "-https", title: "HTTPS · \(host)", evidence: evidence,
                                verdict: service?.verdict ?? .failed))
            }
            rows.append(Row(id: "dns-path", title: "DNS 路径一致性",
                            evidence: (resolverEvidence?.summary ?? "系统默认与当前服务的 DNS 配置无法同时读取")
                                + "。DNS 实际出站线路及旁路未证实。",
                            verdict: resolverEvidence == .different ? .warning : .unknown))
            if let independentReachable {
                rows.append(Row(id: "control", title: "独立联网复核",
                                evidence: independentReachable ? "Apple HTTPS 可达" : "Apple HTTPS 未确认",
                                verdict: independentReachable ? .passed : .warning))
            }
            if let owner {
                rows.append(Row(id: "asn", title: "出口网络归属（优先 IPv4）",
                                evidence: [owner.asn, owner.name].compactMap { $0 }.joined(separator: " · "),
                                verdict: .passed))
            } else {
                rows.append(Row(id: "asn", title: "出口网络归属（优先 IPv4）", evidence: "尚未取得 ASN 数据", verdict: .unknown))
            }
            let routeVerdict: Verdict = !stablePaths || change == .routeChanged || change == .exitChanged
                ? .failed : routes.isEmpty || routes.count != exits.count ? .unknown : .passed
            rows.append(Row(id: "consistency", title: "检测路径一致性",
                            evidence: routeVerdict == .failed ? "检测期间或相对启动时发生变化" :
                                routeVerdict == .passed ? "复核时系统查询路径一致" : "采样不足",
                            verdict: routeVerdict))
            if let regionName {
                let matches = !exits.isEmpty && exits.values.allSatisfy { $0.country == requiredRegion }
                rows.append(Row(id: "region-rule", title: "启动要求 · 出口地区",
                                evidence: matches ? "已查到的出口都属于\(regionName)" : "出口地区未知或不属于\(regionName)",
                                verdict: matches ? .passed : failure == .regionUnverified ? .unknown : .failed))
            }
            return rows
        }
    }

    static func systemAddresses(for host: String) async -> Set<String> {
        guard let result = await command("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", host]),
              result.status == 0 else { return [] }
        return Set(result.text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[0] == "ip_address:" || fields[0] == "ipv6_address:" else { return nil }
            return String(fields[1])
        })
    }

    var resolve: @Sendable (String) async -> Bool = { host in
        await !systemAddresses(for: host).isEmpty
    }

    var probeService: @Sendable (String) async -> Service? = { host in
        guard let url = URL(string: "https://\(host)/") else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 5
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "HEAD"
        let start = ContinuousClock.now
        guard let (_, response) = try? await session.data(for: request),
              let response = response as? HTTPURLResponse,
              response.url == url else { return nil }
        let duration = start.duration(to: .now).components
        return Service(status: response.statusCode,
                       milliseconds: Int(duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000))
    }

    func serviceChecks() async -> (Set<String>, [String: Service]) {
        await withTaskGroup(of: (String, Bool, Service?).self) { group in
            for host in hosts {
                group.addTask {
                    async let dns = resolve(host)
                    async let https = probeService(host)
                    return await (host, dns, https)
                }
            }
            var resolved: Set<String> = []
            var services: [String: Service] = [:]
            for await (host, dns, https) in group {
                if dns { resolved.insert(host) }
                services[host] = https
            }
            return (resolved, services)
        }
    }

    static func networkOwner(_ exit: NativeNetworkMonitor.Exit?) async -> NetworkOwner? {
        guard let exit else { return nil }
        let ip = exit.address
        let family = IPFamily.v4.normalizedAddress(ip) == nil ? IPFamily.v6 : .v4
        let lookup: String
        if family == .v4 {
            lookup = ip.split(separator: ".").reversed().joined(separator: ".") + ".origin.asn.cymru.com"
        } else {
            var address = in6_addr()
            guard inet_pton(AF_INET6, ip, &address) == 1 else { return nil }
            let digits = withUnsafeBytes(of: &address) { $0.map { String(format: "%02x", $0) }.joined() }
            lookup = digits.reversed().map(String.init).joined(separator: ".") + ".origin6.asn.cymru.com"
        }
        guard let record = await txt(lookup),
              let digits = record.split(separator: "|").first?.split(whereSeparator: \.isWhitespace).first,
              !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let asn = "AS\(digits)"
        let name = await txt("\(asn).asn.cymru.com")?.split(separator: "|").last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return NetworkOwner(asn: asn, name: name)
    }

    private static func txt(_ host: String) async -> String? {
        guard let result = await command("/usr/bin/dig", ["+time=2", "+tries=1", "+short", "TXT", host]),
              result.status == 0,
              let line = result.text.split(whereSeparator: \.isNewline).first,
              line.hasPrefix("\""), line.hasSuffix("\"") else { return nil }
        return String(line.dropFirst().dropLast())
    }

    struct CommandResult: Sendable {
        let status: Int32
        let text: String
    }

    static func command(_ path: String, _ arguments: [String], timeout limit: TimeInterval = 4, environment: [String: String] = [:]) async -> CommandResult? {
        await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            if !environment.isEmpty { process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + limit, execute: timeout)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            guard process.terminationReason == .exit else { return nil }
            return CommandResult(status: process.terminationStatus,
                                 text: String(decoding: data, as: UTF8.self))
        }.value
    }
}

final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
