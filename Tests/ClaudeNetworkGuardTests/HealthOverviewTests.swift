import GuardCore
import SwiftUI
import XCTest
@testable import ClaudeNetworkGuard

@MainActor
final class HealthOverviewTests: XCTestCase {
    private let now = Date()
    private let route = Route(interface: "en0", gateway: "192.0.2.1")
    private let usbExit = LineExit(address: "198.51.100.7", country: "SG")

    private func armed(_ edit: (inout ControlStatus) -> Void = { _ in }) -> ControlStatus {
        var status = ControlStatus()
        status.state = .armed
        status.mode = .usb
        status.strictDNS = true
        status.exitCheckedAt = now.addingTimeInterval(-8)
        var shield = ControlStatus.Shield()
        shield.verified = true
        shield.networks = ["192.0.2.0/24"]
        status.shield = shield
        edit(&status)
        return status
    }

    private func proof(udp: String = "") throws -> IsolationProof {
        try JSONDecoder().decode(IsolationProof.self, from: Data("""
        {"gid":1,"tcp":"198.51.100.7","tcpForced":"","relay":"198.51.100.7","udp":"\(udp)","quic":false,"quicForced":false,"lan":false,"ipv6":false,"dnsTCP":false}
        """.utf8))
    }

    private func usb(_ status: ControlStatus?, locked: Bool = false, busy: String? = nil, proof: IsolationProof?, hide: Bool = true) -> HealthOverview {
        .usb(app: "Claude", status: status, locked: locked, busy: busy, exit: usbExit, proof: proof, proofAt: now.addingTimeInterval(-600),
             trafficAt: now.addingTimeInterval(-3), hideAddresses: hide, now: now)
    }

    private func line(_ report: NativeDiagnostics.Report?, mode: NativeProtectionMode? = nil, freshness: ReportFreshness = .current, warning: String? = nil) -> HealthOverview {
        .line(app: "Claude", mode: mode, report: report, freshness: report == nil ? nil : freshness, warning: warning, shield: nil, hideAddresses: true, approved: true)
    }

    private func report(_ edit: (inout NativeDiagnostics.Report) -> Void = { _ in }) -> NativeDiagnostics.Report {
        var value = NativeDiagnostics.Report(date: now, routes: [.v4: route], exits: [.v4: .init(address: "198.51.100.9", country: "SG")],
                                             stablePaths: true, resolved: [], services: [:], skippedHosts: ["claude.ai"], owner: nil)
        value.resolverEvidence = .matching
        edit(&value)
        return value
    }

    func testHealthyUSBIsGreenAndHidesAddress() throws {
        let value = usb(armed(), proof: try proof())
        XCTAssertEqual(value.tone, .positive)
        XCTAssertEqual(value.facts.first?.value, "已隐藏")
        XCTAssertFalse(value.tiles.contains { $0.tone == .off })
        XCTAssertEqual(usb(armed(), proof: try proof(), hide: false).facts.first?.value, "198.51.100.7")
    }

    func testUSBProblemsAreNeverGreen() throws {
        let good = try proof()
        XCTAssertEqual(usb(armed(), locked: true, proof: good).tone, .failed)
        XCTAssertEqual(usb(armed { $0.state = .blocked; $0.reason = "exit_changed" }, proof: good).tone, .failed)
        XCTAssertEqual(usb(nil, proof: good).tone, .warning)
        XCTAssertEqual(usb(armed { $0.exitCheckedAt = self.now.addingTimeInterval(-90) }, proof: good).tone, .warning)
        XCTAssertEqual(usb(armed { $0.exitCheckedAt = nil }, proof: good).tone, .warning)
        XCTAssertEqual(usb(armed { $0.shield = nil }, proof: good).tone, .warning)
        XCTAssertEqual(usb(armed { $0.shield?.verified = false }, proof: good).tone, .warning)
        XCTAssertEqual(usb(armed { $0.shield?.programs = ["ego"] }, proof: good).tone, .warning)
        XCTAssertEqual(usb(armed { $0.events = [.init(kind: "udp", detail: "", date: self.now)] }, proof: good).tone, .warning)
        XCTAssertEqual(usb(armed(), busy: "正在准备", proof: nil).tone, .neutral)
    }

    func testUnprovenUDPIsNotShownAsBlocked() throws {
        let tile = { (value: HealthOverview) in value.tiles.first { $0.title.contains("UDP") } }
        XCTAssertEqual(tile(usb(armed(), proof: nil))?.tone, .neutral)
        XCTAssertEqual(tile(usb(armed(), proof: try proof(udp: "203.0.113.1")))?.tone, .neutral)
        XCTAssertEqual(tile(usb(armed(), proof: try proof(udp: "198.51.100.7")))?.value, "只走 USB")
    }

    func testManualCheckSaysItIsNotProtecting() {
        let value = line(report())
        XCTAssertEqual(value.tone, .positive)
        XCTAssertTrue(value.footnote?.contains("保护没有开启") == true && value.footnote?.contains("没有连 Claude") == true)
        XCTAssertEqual(value.tiles.first { $0.title.contains("DNS") }?.tone, .neutral)
        XCTAssertFalse(value.tiles.contains { $0.tone == .off })
        XCTAssertNotEqual(line(report(), freshness: .expired).tone, .positive)
        XCTAssertNotEqual(line(report(), freshness: .waiting).tone, .positive)
        XCTAssertEqual(line(nil).tone, .off)
    }

    func testManualCheckFailures() {
        XCTAssertEqual(line(report { $0.exits[.v4]?.disagrees = true }).tone, .failed)
        XCTAssertEqual(line(report { $0.requiredRegion = "JP" }).tone, .failed)
        XCTAssertEqual(line(NativeDiagnostics.Report(date: now, routes: [:], exits: [:], stablePaths: true, resolved: [], services: [:], owner: nil)).tone, .failed)
        XCTAssertEqual(line(report { $0.resolverEvidence = .different }).tone, .warning)
    }

    func testLiveLineShowsExitChangeAndWarnings() {
        XCTAssertEqual(line(report { $0.change = .exitChanged }, mode: .vpn).tone, .failed)
        XCTAssertEqual(line(report(), mode: .vpn, warning: "目标应用会话继续，等待复查。").tone, .warning)
        XCTAssertNil(line(report(), mode: .vpn).footnote)
    }

    func testApprovalCoversOnlySameModeAddressAndDay() {
        let line = ApprovedLine(mode: NativeProtectionMode.usb.rawValue, address: "198.51.100.7", date: now)
        XCTAssertTrue(line.covers(.usb, "198.51.100.7", now: now.addingTimeInterval(60)))
        XCTAssertFalse(line.covers(.usb, "198.51.100.8", now: now))
        XCTAssertFalse(line.covers(.usb, nil, now: now))
        XCTAssertFalse(line.covers(.vpn, "198.51.100.7", now: now))
        XCTAssertFalse(line.covers(.usb, "198.51.100.7", now: now.addingTimeInterval(25 * 3600)))
        XCTAssertFalse(line.covers(.usb, "198.51.100.7", now: now.addingTimeInterval(-60)))
    }

    func testLineCheckNeedsAgreeingSources() {
        XCTAssertNil(LineCheck.problem(main: usbExit, others: [usbExit.address], region: nil))
        XCTAssertNotNil(LineCheck.problem(main: nil, others: [usbExit.address], region: nil))
        XCTAssertNotNil(LineCheck.problem(main: usbExit, others: [], region: nil))
        XCTAssertNotNil(LineCheck.problem(main: usbExit, others: ["203.0.113.1"], region: nil))
        XCTAssertNotNil(LineCheck.problem(main: usbExit, others: [usbExit.address], region: "JP"))
        var check = LineCheck(mode: .usb, date: now, address: usbExit.address)
        XCTAssertTrue(check.usable(for: .usb, now: now))
        XCTAssertFalse(check.usable(for: .vpn, now: now))
        XCTAssertFalse(check.usable(for: .usb, now: now.addingTimeInterval(601)))
        check.problem = "x"
        XCTAssertFalse(check.usable(for: .usb, now: now))
    }

    func testPrecheckIsGreenOnlyWhenApproved() {
        let check = LineCheck(mode: .usb, date: now, address: usbExit.address, country: "SG")
        let value = { (approved: Bool, at: Date) in HealthOverview.usbCheck(app: "Claude", check: check, approved: approved, hideAddresses: true, now: at) }
        XCTAssertEqual(value(true, now).tone, .positive)
        XCTAssertEqual(value(false, now).tone, .warning)
        XCTAssertNotEqual(value(true, now.addingTimeInterval(700)).tone, .positive)
        XCTAssertEqual(HealthOverview.usbCheck(app: "Claude", check: nil, approved: true, hideAddresses: true, now: now).tone, .off)
    }

    func testLockedLineIgnoresIPv6RotationButNotIPv4() {
        let v6 = { NativeNetworkMonitor.Exit(address: $0) }
        let base = NativeNetworkMonitor.Baseline(routes: [.v4: route], exits: [.v4: v6("198.51.100.9"), .v6: v6("2001:db8::1")], ipv4Only: true)
        XCTAssertNil(base.change(routes: [.v4: route, .v6: route], exits: [.v4: v6("198.51.100.9"), .v6: v6("2001:db8::2")]))
        XCTAssertEqual(base.change(routes: [.v4: route], exits: [.v4: v6("198.51.100.10")]), .exitChanged)
        XCTAssertEqual(base.change(routes: [.v4: Route(interface: "en1", gateway: nil)], exits: [.v4: v6("198.51.100.9")]), .routeChanged)
    }

    func testPinOnlyAllowsIPv4OnChosenLine() {
        let text = PFRules(gid: 701, mode: .pin, armed: true, interface: "utun4", address: "", gateway: "").text()
        XCTAssertTrue(text.contains("block return out quick on utun4 inet6 proto { tcp udp } all group 701"))
        XCTAssertFalse(PFRules(gid: 701, mode: .pin, armed: false, interface: "utun4", address: "", gateway: "").text().contains("pass out quick on utun4"))
    }

    func testCutLineIsRed() {
        XCTAssertEqual(HealthOverview.line(app: "Claude", mode: .vpn, report: report(), freshness: .current, warning: nil, shield: nil, hideAddresses: true, cut: "线路已断开。").tone, .failed)
        XCTAssertEqual(HealthOverview.line(app: "Claude", mode: nil, report: report(), freshness: .current, warning: nil, shield: nil, hideAddresses: true, problem: "没有 VPN").tone, .failed)
    }

    func testServiceProbeNeedsBothAnswers() {
        let ip = "198.51.100.7", body = "{\"error\":{\"type\":\"authentication_error\"}}"
        XCTAssertEqual(ServiceProbe.judge(seen: ip, expected: ip, status: 401, body: body), .usable)
        XCTAssertEqual(ServiceProbe.judge(seen: ip, expected: ip, status: 403, body: ""), .refused(403))
        XCTAssertEqual(ServiceProbe.judge(seen: ip, expected: ip, status: 200, body: ""), .refused(200))
        XCTAssertEqual(ServiceProbe.judge(seen: ip, expected: ip, status: 401, body: "portal"), .refused(401))
        XCTAssertEqual(ServiceProbe.judge(seen: "203.0.113.1", expected: ip, status: 401, body: body), .differentExit)
        XCTAssertEqual(ServiceProbe.judge(seen: nil, expected: ip, status: 401, body: body), .unreachable)
        XCTAssertEqual(ServiceProbe.judge(seen: nil, expected: ip, status: 0, body: ""), .unreachable)
    }

    func testCurrentNetworkIsCheckOnly() {
        let value = HealthOverview.line(app: "Claude", mode: nil, report: report(), freshness: .current, warning: nil, shield: nil, hideAddresses: true, checkOnly: true, usbIdle: true)
        XCTAssertEqual(value.tone, .positive)
        XCTAssertFalse(value.tiles.contains { $0.title == "你的认可" })
        XCTAssertTrue(value.footnote?.contains("iPhone USB 也连着") == true)
        XCTAssertFalse(NativeProtectionMode.protecting.contains(.current))
        XCTAssertThrowsError(try NativeProtectionPolicy.evaluate(.current, routes: ["1.1.1.1": route, "149.112.112.112": route, "208.67.222.222": route], hotspotIDs: [:], proxy: false))
        let bad = HealthOverview.line(app: "Claude", mode: nil, report: report(), freshness: .current, warning: nil, shield: nil, hideAddresses: true, checkOnly: true,
                                      probe: ServiceProbe(address: "198.51.100.9", date: now, verdict: .refused(403)))
        XCTAssertNotEqual(bad.tone, .positive)
    }

    func testOtherSoftwareOnlyShownWhenSomethingHappened() {
        var shield = ControlStatus.Shield()
        shield.verified = true
        XCTAssertNil(HealthOverview.others(shield, app: "Claude", labels: [:]))
        shield.blockedPackets = 3
        shield.programs = ["ego"]
        shield.note("ego", interface: "en0", at: now)
        shield.note("ego", interface: "en0", at: now.addingTimeInterval(5))
        shield.note(nil, interface: "utun9", at: now)
        XCTAssertEqual(shield.hits?.count, 2)
        let tile = HealthOverview.others(shield, app: "Claude", labels: ["en0": "Wi-Fi"])
        XCTAssertEqual(tile?.tone, .warning)
        XCTAssertTrue(tile?.details.first?.contains("ego：想走 Wi-Fi（en0）") == true)
        XCTAssertTrue(tile?.details.last?.contains("没认出是哪个软件") == true && tile?.details.last?.contains("VPN 或系统隧道（utun9）") == true)
        shield.verified = false
        XCTAssertNotNil(HealthOverview.others(shield, app: "Claude", labels: [:]))
    }

    /// 旧组件的状态里没有 hits，新界面也要能读。
    func testOldComponentStatusStillDecodes() throws {
        let old = Data(#"{"verified":true,"networks":[],"uncovered":[],"blockedPackets":1,"programs":["ego"]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ControlStatus.Shield.self, from: old).hits)
    }

    /// 热点和 VPN 的默认线路就是所选线路：验证包要能被数到，真正的拦截仍只放行所选线路。
    func testCanaryIsCountableWhenLineIsDefault() {
        let text = ServiceShield.rules(interface: "en0", address: "192.0.2.5", networks: [AddressBlock("160.79.104.0/23")!], canaryAnywhere: true)
        XCTAssertTrue(text.contains("block drop out quick inet from any to 192.0.2.1 label \"angcanary\""))
        XCTAssertTrue(text.contains("block drop out quick on ! en0 inet from any to { 160.79.104.0/23 }"))
        XCTAssertTrue(ServiceShield.rules(interface: "en7", networks: []).contains("on ! en7 inet from any to 192.0.2.1"))
    }

    func testPermitOnlyOpensChosenInterfaceAndAddress() {
        let nets = [AddressBlock("160.79.104.0/23")!]
        let closed = ServiceShield.rules(interface: nil, networks: nets), open = ServiceShield.rules(interface: "en0", address: "192.0.2.5", networks: nets)
        XCTAssertFalse(closed.contains("on !"))
        XCTAssertTrue(open.contains("block drop out quick on ! en0 inet from any to { 160.79.104.0/23 }"))
        XCTAssertTrue(open.contains("block drop out quick on en0 inet from ! 192.0.2.5 to { 160.79.104.0/23 }"))
        let usb = Route(interface: "en7", gateway: nil)
        XCTAssertTrue(ThirdPartyCheck.wholeMacOnUSB(routes: [.v4: usb], usb: ["en7"]))
        XCTAssertFalse(ThirdPartyCheck.wholeMacOnUSB(routes: [.v4: usb, .v6: route], usb: ["en7"]))
        XCTAssertFalse(ThirdPartyCheck.wholeMacOnUSB(routes: [:], usb: ["en7"]))
    }
}
