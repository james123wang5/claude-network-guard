import Foundation
import XCTest
@testable import ClaudeNetworkGuard

final class VerificationProgressTests: XCTestCase {
    private let path: [IPFamily: Route] = [.v4: Route(interface: "en0", gateway: "192.0.2.1")]

    private func report(exit: Bool, service: Bool, at date: Date = Date()) -> NativeDiagnostics.Report {
        let results = ["example.test", "api.example.test"].map { ($0, NativeDiagnostics.Service(status: 200, milliseconds: 42)) }
        return NativeDiagnostics.Report(date: date, routes: path,
            exits: exit ? [.v4: .init(address: "198.51.100.10")] : [:],
            stablePaths: true, resolved: Set(["example.test", "api.example.test"]),
            services: service ? Dictionary(uniqueKeysWithValues: results) : [:], serviceHosts: ["example.test", "api.example.test"], owner: nil)
    }

    func testOnlyFreshReportsRetainCurrentStatus() {
        let report = Date()
        func freshness(_ seconds: TimeInterval, checking: Bool = false, changed: Bool = false) -> ReportFreshness {
            ReportFreshness(measuredAt: report, now: report.addingTimeInterval(seconds),
                            checking: checking, networkChanged: changed)
        }
        XCTAssertEqual(freshness(29), .current)
        XCTAssertFalse(freshness(29).isHistorical)
        XCTAssertEqual(freshness(30), .expired)
        XCTAssertTrue(freshness(30).isHistorical)
        XCTAssertEqual(freshness(1, checking: true), .refreshing)
        XCTAssertTrue(freshness(1, checking: true).isHistorical)
        XCTAssertEqual(freshness(1, changed: true), .waiting)
        XCTAssertTrue(freshness(1, changed: true).isHistorical)
    }

    func testResidualProcessesAndUnconfirmedProcessesRemainDistinct() {
        let residual = AppProcessExitCheck.Result(tracked: 3, remaining: [42], unconfirmed: [43])
        XCTAssertTrue(residual.hasOutstanding)
        XCTAssertEqual(residual.sessionTitle, "Claude 主程序已退出，仍有相关进程")
        XCTAssertEqual(residual.notes, ["仍在运行 · PID 42", "无法确认 · PID 43"])

        let unconfirmed = AppProcessExitCheck.Result(tracked: 2, remaining: [], unconfirmed: [43])
        XCTAssertTrue(unconfirmed.hasOutstanding)
        XCTAssertEqual(unconfirmed.sessionTitle, "Claude 主程序已退出，部分进程未确认")

        let cleared = AppProcessExitCheck.Result(tracked: 2, remaining: [], unconfirmed: [])
        XCTAssertFalse(cleared.hasOutstanding)
        XCTAssertNil(cleared.sessionTitle)
    }

    func testUnknownExitExpiresOnlyAfterTimeAndThirdSample() {
        var progress = VerificationProgress()
        let start = ContinuousClock.now
        let failed = report(exit: false, service: true)
        XCTAssertFalse(progress.record(failed, now: start))
        XCTAssertFalse(progress.record(failed, now: start.advanced(by: .seconds(60))))
        XCTAssertTrue(progress.record(failed, now: start.advanced(by: .seconds(61))))
        XCTAssertEqual(progress.consecutiveUnverified, 3)
        XCTAssertEqual(progress.consecutiveWarnings, 3)
    }

    func testTransientFailureResetsWhenExitReturns() {
        var progress = VerificationProgress()
        let start = ContinuousClock.now
        let healthy = report(exit: true, service: true)
        XCTAssertFalse(progress.record(report(exit: false, service: true), now: start))
        XCTAssertFalse(progress.record(healthy, now: start.advanced(by: .seconds(62))))
        XCTAssertEqual(progress.lastSuccess, healthy.date)
        XCTAssertEqual(progress.lastVerifiedExit, healthy.date)
        XCTAssertNil(progress.unverifiedSince)
        XCTAssertEqual(progress.consecutiveWarnings, 0)
    }

    func testServiceFaultDoesNotStartExitDeadline() {
        var progress = VerificationProgress()
        let start = ContinuousClock.now
        let serviceDown = report(exit: true, service: false)
        for offset in [0, 30, 62, 100] {
            XCTAssertFalse(progress.record(serviceDown, now: start.advanced(by: .seconds(offset))))
        }
        XCTAssertEqual(progress.lastVerifiedExit, serviceDown.date)
        XCTAssertNil(progress.lastSuccess)
        XCTAssertEqual(progress.consecutiveWarnings, 4)
        XCTAssertEqual(progress.consecutiveUnverified, 0)
    }

    func testRegionUnknownIsNotTreatedAsConfirmedMismatch() {
        var unknown = report(exit: true, service: true)
        unknown.requiredRegion = "SG"
        XCTAssertEqual(unknown.failure, .regionUnverified)
        XCTAssertEqual(unknown.followUp, .warn(.regionUnverified))
        XCTAssertFalse(unknown.exitProofAvailable)
        unknown.exits[.v4]?.country = "JP"
        XCTAssertEqual(unknown.followUp, .stop(.unexpectedRegion))
    }

    func testObservedChildCanBeDistinguishedWhileAliveAndAfterExit() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["15"]
        try child.run()
        defer {
            if child.isRunning {
                child.terminate()
                child.waitUntilExit()
            }
        }
        var check = AppProcessExitCheck()
        check.captureChildren(of: getpid())
        XCTAssertTrue(check.status().remaining.contains(child.processIdentifier))
        let identity = try XCTUnwrap(AppProcessExitCheck.Identity.read(child.processIdentifier))
        let wrong = AppProcessExitCheck.Identity(pid: identity.pid, seconds: identity.seconds, microseconds: identity.microseconds + 1)
        XCTAssertEqual(wrong.stillExists(), false)
        child.terminate()
        child.waitUntilExit()
        XCTAssertFalse(check.status().remaining.contains(child.processIdentifier))
        XCTAssertFalse(check.status().unconfirmed.contains(child.processIdentifier))
    }
}
