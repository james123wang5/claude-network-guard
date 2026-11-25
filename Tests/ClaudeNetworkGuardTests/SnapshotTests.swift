import AppKit
import GuardCore
import SwiftUI
import XCTest
@testable import ClaudeNetworkGuard

/// 设置 GUARD_SNAPSHOT=目录 时把各页面画成图片，供人工查看。不联网，地址都是文档专用地址。
@MainActor
final class SnapshotTests: XCTestCase {
    func testPages() throws {
        guard let folder = ProcessInfo.processInfo.environment["GUARD_SNAPSHOT"] else { throw XCTSkip("未要求截图") }
        let identity = TargetProfile.Identity(bundleID: ClaudeApp.bundleID, executable: "/Applications/Claude.app/Contents/MacOS/Claude", signingID: ClaudeApp.bundleID,
                                              teamID: ClaudeApp.teamID, codeHash: nil, signatureValid: true)
        let ready = ClaudeApp.Status.ready(TargetProfile(path: "/Applications/Claude.app", displayName: "Claude", identity: identity, helpers: [], serviceHosts: ClaudeApp.hosts))
        let exit = LineExit(address: "198.51.100.7", country: "SG")
        let check = LineCheck(mode: .usb, date: Date(), address: exit.address, country: "SG")
        let proof = try JSONDecoder().decode(IsolationProof.self, from: Data("""
        {"gid":1,"tcp":"198.51.100.7","tcpForced":"","relay":"198.51.100.7","udp":"","quic":false,"quicForced":false,"lan":false,"ipv6":false,"dnsTCP":false}
        """.utf8))
        var idle = ControlStatus()
        idle.state = .idle
        var armed = ControlStatus()
        armed.state = .armed; armed.mode = .usb; armed.interface = "en7"; armed.strictDNS = true; armed.exitCheckedAt = Date(); armed.upload = 4_200_000; armed.download = 51_000_000
        armed.protectedDomains = ClaudeApp.hosts
        armed.members = [.init(pid: 1, name: "Claude"), .init(pid: 2, name: "Claude Helper"), .init(pid: 3, name: "Claude Helper"), .init(pid: 4, name: "claude")]
        var shield = ControlStatus.Shield()
        shield.verified = true
        armed.shield = shield
        var warned = armed
        warned.shield?.programs = ["Google Chrome Helper"]; warned.shield?.blockedPackets = 12
        warned.shield?.note("Google Chrome Helper", interface: "en0", at: Date())
        var blocked = armed
        blocked.state = .blocked; blocked.reason = "line_lost"

        func shot(_ name: String, page: Page = .home, status: ControlStatus?, around: Surroundings = .init(), claudeRunning: Bool = false, width: CGFloat = 1040, height: CGFloat = 860, dark: Bool = false, prepare: (GuardSession) -> Void) throws {
            let session = GuardSession(), model = GuardModel(), surroundings = SurroundingsModel()
            UserDefaults.standard.set(name != "home-first", forKey: "introSeen")
            session.isolation.preview(status)
            surroundings.preview(around, running: claudeRunning)
            prepare(session)
            let view = Dashboard(model: model, session: session, isolation: session.isolation, surroundings: surroundings, page: page)
                .frame(width: width, height: height)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder + "/\(name)\(dark ? "-dark" : "").png"))
        }

        try shot("home-first", status: nil, around: .init(otherClaude: 1, systemProxy: false, dnsProxy: true), claudeRunning: true, height: 1180) { $0.preview(claude: ready, mode: .usb) }
        for dark in [false, true] {
            try shot("home-start", status: idle, dark: dark) { $0.preview(claude: ready, mode: .vpn) }
            try shot("home-approve", status: idle, height: 940, dark: dark) { $0.preview(claude: ready, mode: .usb, check: check, seen: true) }
            try shot("home-ready", status: idle, height: 940, dark: dark) { $0.preview(claude: ready, mode: .usb, check: check, seen: true, approved: true) }
            try shot("running", status: armed, dark: dark) { $0.preview(claude: ready, mode: .usb, running: .current, usb: true, title: "USB 专线会话进行中", detail: "", proof: proof, exit: exit) }
            try shot("running-warned", status: warned, around: .init(otherClaude: 1), height: 1000, dark: dark) { $0.preview(claude: ready, mode: .usb, running: .current, usb: true, title: "USB 专线会话进行中", detail: "", proof: proof, exit: exit) }
            try shot("cut", status: blocked, dark: dark) { $0.preview(claude: ready, mode: .usb, running: .current, usb: true, cut: true, title: "USB 已断开，Claude 已断网", detail: "线路已断开。Claude 保持打开但无法联网，不会换到 Wi‑Fi 或 VPN。", proof: proof, exit: exit) }
        }
        try shot("details", page: .details, status: armed, height: 1120) { $0.preview(claude: ready, mode: .usb, running: .current, usb: true, title: "", detail: "", proof: proof, exit: exit) }
        try shot("settings", page: .settings, status: idle, height: 1120) { $0.preview(claude: ready, mode: .usb) }
        try shot("help", page: .help, status: idle, height: 1420) { $0.preview(claude: ready, mode: .usb) }
        try shot("small", status: idle, around: .init(dnsProxy: true), width: 840, height: 628) { $0.preview(claude: ready, mode: .usb, check: check, seen: true) }
        for (name, setup) in [("menu-ok", { (s: GuardSession) in s.preview(mode: .usb, running: .current, usb: true, title: "", detail: "") }),
                              ("menu-cut", { (s: GuardSession) in s.preview(mode: .usb, running: .current, usb: true, cut: true, title: "", detail: "") })] {
            let session = GuardSession()
            session.isolation.preview(armed)
            setup(session)
            let host = NSHostingView(rootView: MenuCard(session: session, isolation: session.isolation))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder + "/\(name).png"))
        }
        try shot("missing", status: idle) { $0.preview(claude: .missing, mode: .hotspot) }
    }
}
