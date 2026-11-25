import Foundation
import XCTest
@testable import ClaudeNetworkGuard

final class TargetProfileTests: XCTestCase {
    func testHostsAreOptionalAndValidatedWithoutNetworkAccess() throws {
        XCTAssertEqual(try TargetProfile.normalizedHosts(""), [])
        XCTAssertEqual(try TargetProfile.normalizedHosts("WWW.Example.org，api.example.org, www.example.org"),
                       ["www.example.org", "api.example.org"])
        for bad in ["https://example.org/a", "user@example.org", "127.0.0.1", "bad..example.org", "-no.example.org"] {
            XCTAssertThrowsError(try TargetProfile.normalizedHosts(bad))
        }
    }

    func testSelectionReadsBundlePathAndNestedHelper() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("Fixture.app")
        let nested = app.appendingPathComponent("Contents/Helpers/Fixture Helper.app")
        try makeBundle(app, identifier: "org.example.fixture.target")
        try makeBundle(nested, identifier: "org.example.fixture.helper")
        let profile = try TargetProfile.inspect(app, hosts: ["api.example.org"])
        XCTAssertEqual(profile.identity.bundleID, "org.example.fixture.target")
        XCTAssertTrue(profile.identity.executable.hasSuffix("/Contents/MacOS/fixture"))
        XCTAssertEqual(profile.helpers.map(\.bundleID), ["org.example.fixture.helper"])
        XCTAssertEqual(try profile.checked().serviceHosts, ["api.example.org"])
        var stale = profile
        stale.serviceHosts = ["file:///etc/hosts"]
        XCTAssertThrowsError(try stale.checked())
    }

    private func makeBundle(_ root: URL, identifier: String) throws {
        let contents = root.appendingPathComponent("Contents")
        let binaries = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        let executable = binaries.appendingPathComponent("fixture")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: executable)
        let manifest = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "fixture", "CFBundlePackageType": "APPL"]
        let plist = try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
    }
}
