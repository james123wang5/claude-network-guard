import XCTest
@testable import ClaudeNetworkGuard

final class NativeNetworkMonitorTests: XCTestCase {
    private let v4 = Route(interface: "en0", gateway: "192.0.2.1")
    private let v6 = Route(interface: "en0", gateway: "fe80::1")
    private let address = NativeNetworkMonitor.Exit(address: "198.51.100.10", country: "SG")

    private var diagnostics: NativeDiagnostics {
        NativeDiagnostics(hosts: ["example.test", "api.example.test"], resolve: { _ in true }, probeService: { _ in .init(status: 200, milliseconds: 20) })
    }

    func testHealthySampleCanBeRechecked() async {
        let path: [IPFamily: Route] = [.v4: v4]
        let address = address
        let monitor = NativeNetworkMonitor(routes: { path }, readExit: { _ in address })
        let report = await monitor.report(using: diagnostics, enrich: false, requiredRegion: "SG")
        XCTAssertNil(report.failure)
        let baseline = NativeNetworkMonitor.Baseline(routes: report.routes, exits: report.exits)
        XCTAssertNil(baseline.change(routes: path, exits: [.v4: address]))
    }

    func testMissingIPv6ProbeDoesNotPassWhenIPv6HasARoute() async {
        let path: [IPFamily: Route] = [.v4: v4, .v6: v6]
        let address = address
        let monitor = NativeNetworkMonitor(routes: { path }, readExit: { $0 == .v4 ? address : nil })
        let report = await monitor.report(using: diagnostics, enrich: false)
        XCTAssertEqual(report.failure, .unavailable)
    }

    func testSameRouteWithChangedPublicExitFailsRecheck() {
        let path: [IPFamily: Route] = [.v4: v4]
        let baseline = NativeNetworkMonitor.Baseline(routes: path, exits: [.v4: address])
        XCTAssertEqual(baseline.change(routes: path, exits: [.v4: .init(address: "198.51.100.11")]), .exitChanged)
    }

    func testChangedInterfaceFailsRecheckEvenIfPublicExitMatches() {
        let baseline = NativeNetworkMonitor.Baseline(routes: [.v4: v4], exits: [.v4: address])
        let changed: [IPFamily: Route] = [.v4: Route(interface: "en1", gateway: "192.0.2.1")]
        XCTAssertEqual(baseline.change(routes: changed, exits: [.v4: address]), .routeChanged)
    }

    func testDNSFailureAndServerErrorsBlockLaunchButUnauthenticatedResponsesWarn() async {
        let path: [IPFamily: Route] = [.v4: v4]
        let address = address
        let monitor = NativeNetworkMonitor(routes: { path }, readExit: { _ in address })
        let warning = NativeDiagnostics(hosts: ["example.test", "api.example.test"], resolve: { _ in true }, probeService: { _ in .init(status: 403, milliseconds: 23) })
        let failedDNS = NativeDiagnostics(hosts: ["example.test", "api.example.test"], resolve: { $0 == "example.test" }, probeService: warning.probeService)
        let failedHTTPS = NativeDiagnostics(hosts: ["example.test", "api.example.test"], resolve: { _ in true }, probeService: { _ in .init(status: 503, milliseconds: 30) })
        let warned = await monitor.report(using: warning, enrich: false)
        XCTAssertNil(warned.failure)
        XCTAssertEqual(warned.services["example.test"]?.verdict, .warning)
        let dns = await monitor.report(using: failedDNS, enrich: false)
        XCTAssertEqual(dns.failure, .dnsUnavailable)
        let https = await monitor.report(using: failedHTTPS, enrich: false)
        XCTAssertEqual(https.failure, .serviceUnavailable)
    }

    func testUnexpectedRegionBlocksLaunch() async {
        let path: [IPFamily: Route] = [.v4: v4]
        let address = address
        let monitor = NativeNetworkMonitor(routes: { path }, readExit: { _ in address })
        let report = await monitor.report(using: diagnostics, enrich: false, requiredRegion: "JP")
        XCTAssertEqual(report.failure, .unexpectedRegion)
    }
}
