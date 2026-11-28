import GuardCore
import XCTest
@testable import ClaudeNetworkGuard

final class ReminderTests: XCTestCase {
    private func profile(id: String = ClaudeApp.bundleID, team: String? = ClaudeApp.teamID, valid: Bool = true) -> TargetProfile {
        TargetProfile(path: "/Applications/Claude.app", displayName: "Claude", identity: .init(bundleID: id, executable: "/Applications/Claude.app/Contents/MacOS/Claude",
                      signingID: id, teamID: team, codeHash: nil, signatureValid: valid), helpers: [], serviceHosts: ClaudeApp.hosts)
    }

    func testOnlyAnthropicSignedClaudeIsAccepted() {
        XCTAssertNotNil(ClaudeApp.judge(profile()).profile)
        XCTAssertNil(ClaudeApp.judge(profile(id: "com.example.claude")).profile)
        XCTAssertNil(ClaudeApp.judge(profile(team: "AAAAAAAAAA")).profile)
        XCTAssertNil(ClaudeApp.judge(profile(team: nil)).profile)
        XCTAssertNil(ClaudeApp.judge(profile(valid: false)).profile)
    }

    func testTerminalClaudeIsToldApartFromDesktop() {
        XCTAssertTrue(Surroundings.isTerminal("claude", "/Users/x/.local/bin/claude"))
        XCTAssertTrue(Surroundings.isTerminal("2.1.330", "/Users/x/.local/share/claude/versions/2.1.330"))
        XCTAssertFalse(Surroundings.isTerminal("claude", "/Users/x/Library/Application Support/Claude/claude-code/2.1.330/x/claude.app/Contents/MacOS/claude"))
        XCTAssertFalse(Surroundings.isTerminal("Claude", "/Applications/Claude.app/Contents/MacOS/Claude"))
        XCTAssertFalse(Surroundings.isTerminal("python3", "/usr/bin/python3"))
    }

    private func before(_ status: ClaudeApp.Status? = nil, running: Bool = false, installed: Bool = true, current: Bool = true, mode: NativeProtectionMode = .usb, _ around: Surroundings = .init()) -> [String] {
        Reminder.beforeStart(claude: status ?? .ready(profile()), running: running, installed: installed, current: current, mode: mode, around: around).map(\.id)
    }

    func testNothingIsShownWhenNothingIsWrong() {
        XCTAssertEqual(before(), [])
        XCTAssertEqual(Reminder.whileRunning(shield: .init(), closedOutsideAt: nil, mode: .usb, around: .init(), now: Date()), [])
    }

    func testBeforeStart() {
        XCTAssertEqual(before(.missing), ["missing"])
        XCTAssertEqual(before(.untrusted("x")), ["untrusted"])
        XCTAssertEqual(before(installed: false, current: false), ["component"])
        XCTAssertEqual(before(current: false), ["outdated"])
        XCTAssertEqual(before(running: true, Surroundings(otherClaude: 2, systemProxy: true, dnsProxy: true)), ["running", "proxy", "dns", "terminal"])
        XCTAssertEqual(before(running: true, installed: false, mode: .current, Surroundings(otherClaude: 2, systemProxy: true, dnsProxy: true)), [], "只检查时不打扰")
    }

    func testWhileRunning() {
        var shield = ControlStatus.Shield()
        shield.programs = ["Google Chrome"]
        shield.uncovered = ["a.claude.ai"]
        let now = Date()
        XCTAssertEqual(Reminder.whileRunning(shield: shield, closedOutsideAt: now.addingTimeInterval(-60), mode: .vpn, around: Surroundings(otherClaude: 1, dnsProxy: true), now: now).map(\.id),
                       ["shield", "uncovered", "relaunch", "dns", "terminal"])
        XCTAssertEqual(Reminder.whileRunning(shield: .init(), closedOutsideAt: now.addingTimeInterval(-3600), mode: .usb, around: .init(), now: now), [], "半小时后不再提")
    }

    /// TCP 53 要在进程级限制里拒绝：系统的 DNS 代理扩展在防火墙之前接管它。
    func testConfinementDeniesTCPDNS() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let confine = try String(contentsOf: root.appendingPathComponent("Sources/GuardConfine/GuardConfine.c"), encoding: .utf8)
        XCTAssertTrue(confine.contains(#"(deny network-outbound (remote tcp \"*:53\"))"#))
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("Sources/guardrelay/main.c"), encoding: .utf8).contains("if (port == 53)"))
    }

    /// 主按钮跟着走：每一步只有一个下一步，没看过网站到不了认可，没认可到不了启动。
    func testStageLeadsThroughOneStepAtATime() {
        var f = Stage.Facts()
        f.claude = .ready(profile())
        XCTAssertEqual(Stage.of(f), .check)
        f.checking = true
        XCTAssertEqual(Stage.of(f), .checking)
        f.checking = false
        f.checked = true
        XCTAssertEqual(Stage.of(f), .site)
        f.claudeRunning = true
        XCTAssertEqual(Stage.of(f), .quitClaude, "从 USB 打开网站前 Claude 要退出")
        f.mode = .vpn
        XCTAssertEqual(Stage.of(f), .site)
        f.seen = true
        XCTAssertEqual(Stage.of(f), .quitClaude)
        f.claudeRunning = false
        XCTAssertEqual(Stage.of(f), .approve)
        f.seen = false
        f.approved = true
        XCTAssertEqual(Stage.of(f), .launch, "认可过的 IP 不用再看网站")
        f.approved = false
        XCTAssertEqual(Stage.of(f), .site)
    }

    func testStageStopsForMissingPiecesAndSessions() {
        var f = Stage.Facts()
        f.claude = .missing
        XCTAssertEqual(Stage.of(f), .download)
        f.claude = .ready(profile())
        f.installed = false
        f.current = false
        XCTAssertEqual(Stage.of(f), .component)
        f.mode = .vpn
        XCTAssertEqual(Stage.of(f), .component, "VPN 和热点没有可用组件也不能启动，不降级成只监测")
        f.mode = .hotspot
        XCTAssertEqual(Stage.of(f), .component)
        f.mode = .current
        XCTAssertNotEqual(Stage.of(f), .component, "只检查不需要组件")
        f.mode = .vpn
        f.installed = true
        XCTAssertEqual(Stage.of(f), .component, "装了但不配套就不能启动")
        f.mode = .current
        XCTAssertEqual(Stage.of(f), .check, "只检查时不看组件")
        f.active = true
        XCTAssertEqual(Stage.of(f), .starting)
        f.launched = true
        XCTAssertEqual(Stage.of(f), .running)
        f.cut = true
        XCTAssertEqual(Stage.of(f), .cut)
        f.siteTesting = true
        XCTAssertEqual(Stage.of(f), .siteTesting)
    }
}
