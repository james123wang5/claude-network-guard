import XCTest
@testable import GuardCore

final class IsolationTests: XCTestCase {
    private func usb(_ armed: Bool = true) -> PFRules {
        var rules = PFRules(gid: 701, mode: .usb, armed: armed, interface: "en7", address: "172.20.10.3", gateway: "172.20.10.1")
        rules.quicFallback = "en0"
        rules.relayPort = 49800
        rules.localProxyPorts = [7890]
        rules.guardedDNS = ["172.20.10.1"]
        return rules
    }

    private func parse(_ text: String) throws -> Int32 {
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
        process.arguments = ["-n", "-f", "-"]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(text.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testRulesAreAcceptedBySystemParser() throws {
        XCTAssertEqual(try parse(usb().text()), 0)
        XCTAssertEqual(try parse(usb(false).text()), 0)
        for (name, address) in [("utun4", ""), ("en0", "172.20.10.4")] {
            for armed in [true, false] {
                let pin = PFRules(gid: 701, mode: .pin, armed: armed, interface: name, address: address, gateway: "")
                XCTAssertEqual(try parse(pin.text()), 0, name)
            }
        }
    }

    func testAllowedHostsAreNarrow() throws {
        XCTAssertEqual(AllowedHost("10.1.2.12:22")?.text, "10.1.2.12:22")
        for bad in ["10.1.2.12", "10.1.2.0/24:22", "8.8.8.8:53", "160.79.104.10:443", "172.32.0.1:22", "10.1.2.3:0", "10.1.2.3:70000",
                    "host:22", "[fd00::1]:22", "10.1.2.3:22 group 20", "10.1.2.3:+22", "::ffff:10.1.2.3:22"] { XCTAssertNil(AllowedHost(bad), bad) }
        XCTAssertEqual(AllowedHost.parse("")?.count, 0)
        XCTAssertEqual(AllowedHost.parse("10.1.2.3:22，10.1.2.3:22")?.count, 1)
        XCTAssertNil(AllowedHost.parse("10.1.2.3:22, 8.8.8.8:53"))
        XCTAssertNil(AllowedHost.parse("10.0.0.1:1 10.0.0.2:1 10.0.0.3:1 10.0.0.4:1 10.0.0.5:1"))
        XCTAssertTrue(AllowedHost.usable(interface: "utun4"))
        for bad in ["en0", "en7", "lo0", "utun", nil] { XCTAssertFalse(AllowedHost.usable(interface: bad)) }

        let host = try XCTUnwrap(AllowedHost("10.1.2.12:22"))
        let wanted = "pass out quick on utun4 inet proto tcp from any to 10.1.2.12 port 22 group 701 no state"
        for mode in [IsolationMode.usb, .pin] {
            for armed in [true, false] {
                var rules = PFRules(gid: 701, mode: mode, armed: armed, interface: mode == .usb ? "en7" : "en0", address: "172.20.10.4", gateway: "172.20.10.1")
                rules.allowed = [AllowedRoute(host: host, interface: "utun4")]
                let lines = rules.text().split(separator: "\n").map(String.init)
                XCTAssertEqual(lines.contains(wanted), armed)
                if armed {
                    let at = try XCTUnwrap(lines.firstIndex(of: wanted))
                    let deny = try XCTUnwrap(lines.firstIndex { $0.contains("block return out quick on !") })
                    XCTAssertLessThan(at, deny)
                }
                XCTAssertEqual(lines.last, "block return out quick all group 701")
                XCTAssertEqual(try parse(rules.text()), 0)
            }
        }
    }

    func testBlockedRulesContainNoExternalPass() {
        for rules in [usb(false), PFRules(gid: 701, mode: .pin, armed: false, interface: "utun4", address: "", gateway: "")] {
            for line in rules.text().split(separator: "\n") where line.hasPrefix("pass") { XCTAssertTrue(line.contains("on lo0"), String(line)) }
            XCTAssertFalse(rules.text().contains("nat "))
            XCTAssertFalse(rules.text().contains("route-to"))
        }
    }

    func testEveryVariantEndsWithCatchAll() {
        for rules in [usb(), usb(false), PFRules(gid: 701, mode: .pin, armed: true, interface: "utun4", address: "", gateway: "")] {
            XCTAssertEqual(rules.text().split(separator: "\n").last, "block return out quick all group 701")
        }
    }

    func testStateIsInterfaceBoundAndRedirectIsStateless() {
        let text = usb().text()
        XCTAssertTrue(text.contains("keep state (if-bound)"))
        XCTAssertFalse(text.split(separator: "\n").contains { $0.contains("route-to") && !$0.contains("no state") })
    }

    func testLocalProxyAndRelayAreRestricted() {
        let lines = usb().text().split(separator: "\n").map(String.init)
        let loopback = lines.firstIndex(of: "pass quick on lo0 all no state")!
        XCTAssertLessThan(lines.firstIndex { $0.contains("port 7890") && $0.hasPrefix("block") }!, loopback)
        XCTAssertLessThan(lines.firstIndex { $0.contains("port 49800") && $0.hasPrefix("pass") && $0.contains("group 701") }!,
                          lines.firstIndex { $0.contains("port 49800") && $0.hasPrefix("block") }!)
    }

    func testQUICFallbackOnlyOnDefaultPath() {
        XCTAssertTrue(usb().text().contains("block return out quick on en0 proto udp from any to any port { 80 443 }"))
        var same = usb()
        same.quicFallback = "en7"
        XCTAssertFalse(same.text().contains("port { 80 443 }"))
    }

    func testConfinedSessionDoesNotTouchOtherAppsUDP() {
        var rules = usb()
        rules.quicFallback = nil
        XCTAssertFalse(rules.text().contains("port { 80 443 }"))
        for line in rules.text().split(separator: "\n") where line.contains("udp") { XCTAssertTrue(line.contains("group 701"), String(line)) }
    }

    func testSocketRulesAreExactAndParse() throws {
        let rules = PFRules.socketRules([.init(udp: true, local: "1.2.3.4", localPort: 5000, remote: "9.9.9.9", remotePort: 443),
                                         .init(udp: false, local: "::", localPort: 5001, remote: "2606:4700::1", remotePort: 443)])
        XCTAssertEqual(try parse(rules), 0)
        XCTAssertTrue(rules.contains("from any port 5000 to 9.9.9.9 port 443"))
    }

    func testOutsidersAreFoundByResponsibility() {
        func entry(_ pid: pid_t, _ gid: gid_t, uid: uid_t = 501) -> ProcessEntry { .init(pid: pid, uid: uid, gid: gid, realGID: gid, name: "p\(pid)") }
        let all = [entry(10, 701), entry(11, 701), entry(20, 20), entry(30, 20), entry(40, 20, uid: 0)]
        let members = ProcessAudit.members(of: 701, in: all)
        XCTAssertEqual(members.map(\.pid), [10, 11])
        let found = ProcessAudit.outsiders(of: members, gid: 701, uid: 501, in: all) { [20: 10, 30: 30, 40: 10][$0] }
        XCTAssertEqual(found.map(\.pid), [20])
    }

    func testOwnSocketsAreReadable() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(fd) }
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = UInt16(9).bigEndian
        inet_pton(AF_INET, "192.0.2.7", &target.sin_addr)
        let result = withUnsafePointer(to: &target) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        try XCTSkipIf(result != 0, "没有默认路由")
        let found = ProcessAudit.sockets(of: getpid()).first { $0.remote == "192.0.2.7" }
        XCTAssertEqual(found?.udp, true)
        XCTAssertEqual(found?.remotePort, 9)
        XCTAssertEqual(found?.external, true)
    }

    func testControlNamesRejectInjection() {
        for value in ["en7; pass all", "lo0", "../x", "en", "en7\n"] { XCTAssertFalse(GuardNames.interface(value), value) }
        for value in ["../etc/passwd", "a b.com", "com", "x.com/", "-a.com"] { XCTAssertFalse(GuardNames.domain(value), value) }
        XCTAssertTrue(GuardNames.interface("en7"))
        XCTAssertTrue(GuardNames.domain("claude.ai"))
    }

    func testSystemProxyPorts() {
        XCTAssertEqual(SystemProxy.localPorts(["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7890,
                                               "SOCKSEnable": 0, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 1]), [7890])
        XCTAssertEqual(SystemProxy.localPorts(["HTTPSEnable": 1, "HTTPSProxy": "10.0.0.2", "HTTPSPort": 8080]), [])
    }

    func testShieldRulesAreAcceptedAndNeverPass() throws {
        let networks = ["160.79.104.0/23", "34.54.194.141", "2607:6bc0::/48"].compactMap(AddressBlock.init)
        for rules in [ServiceShield.rules(interface: "en7", networks: networks), ServiceShield.rules(interface: nil, networks: networks),
                      ServiceShield.rules(interface: "en0", address: "172.20.10.4", networks: networks),
                      ServiceShield.rules(interface: "utun4", networks: [])] {
            XCTAssertEqual(try parse(rules), 0, rules)
            for line in rules.split(separator: "\n") { XCTAssertTrue(line.hasPrefix("block drop out quick"), String(line)) }
        }
        // 断线时不能给任何网卡留例外。
        XCTAssertFalse(ServiceShield.rules(interface: nil, networks: networks).contains(" on "))
    }

    func testShieldSkipsSharedAndLocalAddresses() {
        XCTAssertTrue(ServiceShield.isBlockable(AddressBlock("160.79.104.10")!))
        XCTAssertTrue(ServiceShield.isBlockable(AddressBlock("2607:6bc0::10")!))
        for text in ["104.18.2.3", "151.101.1.1", "2606:4700::1", "192.168.1.1", "127.0.0.1", "fe80::1", "0.0.0.0", "::1"] {
            XCTAssertFalse(ServiceShield.isBlockable(AddressBlock(text)!), text)
        }
        XCTAssertEqual(ServiceShield.fixedNetworks(for: ["claude.ai"]).map(\.description), ["160.79.104.0/23", "2607:6bc0::/48"])
        XCTAssertTrue(ServiceShield.fixedNetworks(for: ["example.com"]).isEmpty)
    }

    func testAddressBlocks() {
        let block = AddressBlock("160.79.104.0/23")!
        XCTAssertTrue(block.contains(AddressBlock("160.79.105.255")!))
        XCTAssertFalse(block.contains(AddressBlock("160.79.106.0")!))
        XCTAssertFalse(block.contains(AddressBlock("2607:6bc0::10")!))
        for text in ["", "1.2.3", "1.2.3.4/33", "1.2.3.4/", "a/8", "1.2.3.4; pass"] { XCTAssertNil(AddressBlock(text), text) }
    }

    func testShieldCounterAndTraceParsing() {
        let labels = "angcanary 10 2 60 0 0 0 0\nangservice 9 3 120 0 0 0 0\nangservice 9 4 120 0 0 0 0\n"
        XCTAssertEqual(ServiceShield.packets(in: labels, label: "angservice"), 7)
        XCTAssertNil(ServiceShield.packets(in: "", label: "angcanary"))
        XCTAssertEqual(ServiceShield.exitAddress(in: "fl=1\nip=1.2.3.4\nloc=SG\n"), "1.2.3.4")
        XCTAssertNil(ServiceShield.exitAddress(in: "ip=<html>\n"))
    }

    func testOldDaemonStatusStillDecodes() throws {
        var status = ControlStatus()
        status.version = "0.3.0"
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as! [String: Any]
        object["shield"] = nil
        object["exitCheckedAt"] = nil
        XCTAssertNoThrow(try JSONDecoder().decode(ControlStatus.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}
