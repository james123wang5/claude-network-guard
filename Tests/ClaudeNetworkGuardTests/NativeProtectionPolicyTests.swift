import XCTest
@testable import ClaudeNetworkGuard

final class NativeProtectionPolicyTests: XCTestCase {
    private func routes(on interface: String) -> [String: Route] {
        Dictionary(uniqueKeysWithValues: ["1.1.1.1", "149.112.112.112", "208.67.222.222"].map {
            ($0, Route(interface: interface, gateway: nil))
        })
    }

    func testVPNRequiresRoutesOnTunnelAndChecksIPv6AndServiceRoutes() throws {
        XCTAssertThrowsError(try NativeProtectionPolicy.evaluate(.vpn, routes: routes(on: "en0"), hotspotIDs: [:], proxy: false))
        var sampled = routes(on: "utun9")
        sampled["198.51.100.21"] = Route(interface: "utun9", gateway: nil)
        XCTAssertNoThrow(try NativeProtectionPolicy.evaluate(.vpn, routes: sampled, hotspotIDs: [:], proxy: false,
            serviceTargets: ["198.51.100.21", "2001:db8::1"]))
        sampled["2620:fe::fe"] = Route(interface: "en0", gateway: nil)
        XCTAssertThrowsError(try NativeProtectionPolicy.evaluate(.vpn, routes: sampled, hotspotIDs: [:], proxy: false))
        sampled.removeValue(forKey: "2620:fe::fe")
        sampled["198.51.100.21"] = Route(interface: "en0", gateway: nil)
        XCTAssertThrowsError(try NativeProtectionPolicy.evaluate(.vpn, routes: sampled, hotspotIDs: [:], proxy: false))
    }

    func testHotspotNeedsCurrentIdentityAndDetectsChangeOnSameWiFiInterface() throws {
        let path = routes(on: "en0")
        XCTAssertThrowsError(try NativeProtectionPolicy.evaluate(.hotspot, routes: path, hotspotIDs: [:], proxy: false))
        let first = try NativeProtectionPolicy.evaluate(.hotspot, routes: path, hotspotIDs: ["en0": "first"], proxy: false)
        let next = try NativeProtectionPolicy.evaluate(.hotspot, routes: path, hotspotIDs: ["en0": "next"], proxy: false)
        XCTAssertFalse(next.matches(first))
        XCTAssertTrue(first.matches(first))
    }

    func testProxyAndDNSOnAnUnexpectedInterfaceAreRejected() {
        var path = routes(on: "utun9")
        XCTAssertThrowsError(try NativeProtectionPolicy.evaluate(.vpn, routes: path, hotspotIDs: [:], proxy: true))
        path["192.0.2.53"] = Route(interface: "en0", gateway: nil)
        XCTAssertThrowsError(try NativeProtectionPolicy.evaluate(.vpn, routes: path, hotspotIDs: [:], proxy: false,
            dnsTargets: ["192.0.2.53"]))
    }

    func testHotspotRecognitionFromSystemState() {
        let good: [String: Any] = ["InterfaceName": "en0", "Router": "172.20.10.1", "ARPResolvedIPAddress": "172.20.10.1",
                                   "SubnetMasks": ["255.255.255.240"], "ARPResolvedHardwareAddress": "02:00:00:00:00:01"]
        func edit(_ key: String, _ value: Any?) -> [String: Any] { var copy = good; copy[key] = value; return copy }
        XCTAssertNotNil(NetworkCheck.hotspotIdentity(good, interface: "en0"))
        XCTAssertNil(NetworkCheck.hotspotIdentity(good, interface: "en7"))
        XCTAssertNil(NetworkCheck.hotspotIdentity(edit("Router", "192.168.1.1"), interface: "en0"))
        XCTAssertNil(NetworkCheck.hotspotIdentity(edit("SubnetMasks", ["255.255.255.0"]), interface: "en0"))
        XCTAssertNil(NetworkCheck.hotspotIdentity(edit("ARPResolvedHardwareAddress", nil), interface: "en0"))
        XCTAssertNotEqual(NetworkCheck.hotspotIdentity(good, interface: "en0"),
                          NetworkCheck.hotspotIdentity(edit("ARPResolvedHardwareAddress", "02:00:00:00:00:02"), interface: "en0"))
    }
}
