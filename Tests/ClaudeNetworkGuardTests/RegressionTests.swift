import XCTest
@testable import ClaudeNetworkGuard

final class RegressionTests: XCTestCase {
    func testAutoDiscoveryWithoutWPADHostIsNotAProxy() {
        let wpad: [String: Any] = ["ProxyAutoDiscoveryEnable": 1, "ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "http://wpad/wpad.dat"]
        XCTAssertFalse(NativeProtectionPolicy.activeProxy(wpad, autoDiscoveryResolves: { false }))
        XCTAssertTrue(NativeProtectionPolicy.activeProxy(wpad, autoDiscoveryResolves: { true }))
        XCTAssertTrue(NativeProtectionPolicy.activeProxy(["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "http://p.example/x.pac"],
                                                        autoDiscoveryResolves: { false }))
        XCTAssertTrue(NativeProtectionPolicy.activeProxy(["HTTPEnable": 1], autoDiscoveryResolves: { false }))
        XCTAssertFalse(NativeProtectionPolicy.activeProxy(["__SCOPED__": ["en0": wpad]], autoDiscoveryResolves: { false }))
    }

    func testSameTeamUpdateIsAcceptedButOtherChangesAreNot() {
        func identity(hash: String = "a", team: String? = "T", id: String = "app.x", valid: Bool = true) -> TargetProfile.Identity {
            .init(bundleID: id, executable: "/Applications/X.app/Contents/MacOS/X", signingID: id, teamID: team, codeHash: hash, signatureValid: valid)
        }
        XCTAssertTrue(identity().accepts(identity(hash: "b")))
        XCTAssertFalse(identity().accepts(identity(hash: "b", team: "U")))
        XCTAssertFalse(identity().accepts(identity(id: "app.y")))
        XCTAssertFalse(identity().accepts(identity(valid: false)))
        XCTAssertFalse(identity(team: nil).accepts(identity(hash: "b", team: nil)))
        XCTAssertTrue(identity(team: nil).accepts(identity(team: nil)))
    }

    func testKernelRouteMatchesSystemTool() async throws {
        let tool = await NativeDiagnostics.command("/sbin/route", ["-n", "get", "1.1.1.1"])
        let line = tool?.text.split(separator: "\n").first { $0.contains("interface:") }
        XCTAssertEqual(NetworkCheck.route(to: "1.1.1.1")?.interface,
                       line?.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) })
    }

    func testProofRequiresUSBExitAndNoLeak() {
        func proof(tcp: String = "1.1.1.9", forced: String = "", relay: String = "1.1.1.9", quic: Bool = false, udp: String = "", dnsTCP: Bool? = false) -> IsolationProof {
            .init(gid: 501, tcp: tcp, tcpForced: forced, relay: relay, udp: udp, quic: quic, quicForced: false, lan: false, ipv6: false, dnsTCP: dnsTCP)
        }
        XCTAssertTrue(proof().passed(usb: "1.1.1.9", other: "2.2.2.9"))
        XCTAssertFalse(proof(dnsTCP: true).passed(usb: "1.1.1.9", other: "2.2.2.9"))
        XCTAssertFalse(proof(dnsTCP: nil).passed(usb: "1.1.1.9", other: "2.2.2.9"))
        XCTAssertFalse(proof().passed(usb: "1.1.1.9", other: "1.1.1.9"))
        XCTAssertFalse(proof(tcp: "2.2.2.9").passed(usb: "1.1.1.9", other: "2.2.2.9"))
        XCTAssertFalse(proof(forced: "2.2.2.9").passed(usb: "1.1.1.9", other: "2.2.2.9"))
        XCTAssertFalse(proof(relay: "").passed(usb: "1.1.1.9", other: "2.2.2.9"))
        XCTAssertFalse(proof(quic: true).passed(usb: "1.1.1.9", other: "2.2.2.9"))
        XCTAssertFalse(proof(tcp: "").passed(usb: "1.1.1.9", other: "2.2.2.9"))
    }
}
