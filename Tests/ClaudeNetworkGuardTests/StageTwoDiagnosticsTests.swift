import XCTest
@testable import ClaudeNetworkGuard

final class StageTwoDiagnosticsTests: XCTestCase {
    private let route = Route(interface: "en0", gateway: "192.0.2.1")

    func testIndependentExitReadsFallbackAndDisagreement() throws {
        let apple = NativeNetworkMonitor.Source(name: "first", url: "https://one.example/")
        let backup = NativeNetworkMonitor.Source(name: "fallback", url: "https://two.example/")
        let a = NativeNetworkMonitor.Exit(address: "198.51.100.10")
        let b = NativeNetworkMonitor.Exit(address: "198.51.100.11")
        let fallback = try XCTUnwrap(NativeNetworkMonitor.consensus([(backup, b)]))
        XCTAssertEqual(fallback.address, b.address)
        XCTAssertEqual(fallback.sources, ["fallback"])
        XCTAssertFalse(fallback.disagrees)
        XCTAssertEqual(NativeNetworkMonitor.consensus([(apple, a), (backup, a)])?.disagrees, false)
        XCTAssertEqual(NativeNetworkMonitor.consensus([(apple, a), (backup, b)])?.disagrees, true)
    }

    func testServiceAndDetectorOutagesDoNotStopSession() {
        let address = NativeNetworkMonitor.Exit(address: "198.51.100.10")
        let serviceFault = NativeDiagnostics.Report(date: Date(), routes: [.v4: route], exits: [.v4: address],
            stablePaths: true, resolved: Set(["example.test", "api.example.test"]), services: [:], serviceHosts: ["example.test", "api.example.test"], owner: nil)
        XCTAssertEqual(serviceFault.followUp, .warn(.serviceUnavailable))

        var detectorFault = NativeDiagnostics.Report(date: Date(), routes: [.v4: route], exits: [:],
            stablePaths: true, resolved: [], services: [:], serviceHosts: ["example.test", "api.example.test"], owner: nil, independentReachable: true)
        XCTAssertEqual(detectorFault.followUp, .warn(.unavailable))
        detectorFault.independentReachable = false
        XCTAssertEqual(detectorFault.followUp, .reconsiderDisconnect)
        detectorFault.change = .routeChanged
        XCTAssertEqual(detectorFault.followUp, .stop(.routeChanged))
    }

    func testAppleEventKindsAreRecognized() {
        XCTAssertEqual(NetworkEvent.classify([
            "State:/Network/Interface/en0/Link",
            "State:/Network/Global/IPv4",
            "Setup:/Network/Service/a/VPN",
            "State:/Network/Global/DNS",
            "State:/Network/Global/Proxies"
        ]), [.interface, .path, .vpn, .dns, .proxy])
    }

    func testNettopAssociatesOnlyOwnedProcessRowsAndInterfaces() {
        let tree = """
         21  1 /Applications/目标应用.app/Contents/MacOS/目标应用
         22 21 /Applications/目标应用.app/Contents/Frameworks/目标应用Helper
         23 22 /usr/bin/python3
         24  1 /usr/bin/python3
        """
        let observed = """
        time,,interface,state,
        00:00,目标应用.21,,,
        00:00,tcp4 10.0.0.1:123<->198.51.100.10:443,en0,Established,
        00:00,Helper.22,,,
        00:00,udp6 2001:db8::5.5001<->2001:db8::1.443,utun9,,
        00:00,python.23,,,
        00:00,udp4 *:*<->*:*,,,
        00:00,python.24,,,
        00:00,tcp4 10.0.0.1:123<->198.51.100.10:443,en0,Established,
        """
        let candidates = AppConnectionObservation.descendants(in: tree, root: 21, bundlePath: "/Applications/目标应用.app")
        let rows = AppConnectionObservation.observe(observed, candidates: candidates)
        XCTAssertEqual(rows.map(\.id), [21, 22, 23])
        XCTAssertEqual(rows.map(\.connections), [1, 1, 0])
        XCTAssertEqual(rows[1].interfaces, ["utun9"])
        XCTAssertEqual(rows[2].role, "Claude 派生工具")
    }
}
