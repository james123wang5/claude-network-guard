import Foundation

enum ReportFreshness: Equatable {
    case current, refreshing, waiting, expired

    init(measuredAt: Date, now: Date, checking: Bool, networkChanged: Bool) {
        if networkChanged {
            self = .waiting
        } else if checking {
            self = .refreshing
        } else if now.timeIntervalSince(measuredAt) >= VerificationProgress.reportLifetime {
            self = .expired
        } else {
            self = .current
        }
    }

    var isHistorical: Bool { self != .current }

    var explanation: String? {
        switch self {
        case .current: nil
        case .refreshing: "正在检测。下方保留上一次结果。"
        case .waiting: "网络发生变化。复查完成前，下方仅供回看。"
        case .expired: "这份报告已过期。请重新检查当前网络。"
        }
    }
}

struct VerificationProgress {
    static let reportLifetime: TimeInterval = 30
    static let exitDeadline: Duration = .seconds(60)
    static let minimumUnverifiedSamples = 3

    private(set) var lastSuccess: Date?
    private(set) var lastVerifiedExit: Date?
    private(set) var consecutiveWarnings = 0
    private(set) var unverifiedSince: Date?
    private(set) var consecutiveUnverified = 0
    private var unknownStarted: ContinuousClock.Instant?

    mutating func record(_ report: NativeDiagnostics.Report, now: ContinuousClock.Instant) -> Bool {
        if report.failure == nil {
            lastSuccess = report.date
            consecutiveWarnings = 0
        } else {
            consecutiveWarnings += 1
        }

        if report.exitProofAvailable {
            lastVerifiedExit = report.date
            unverifiedSince = nil
            unknownStarted = nil
            consecutiveUnverified = 0
            return false
        }

        if unknownStarted == nil {
            unknownStarted = now
            unverifiedSince = report.date
        }
        consecutiveUnverified += 1
        return consecutiveUnverified >= Self.minimumUnverifiedSamples &&
            (unknownStarted?.duration(to: now) ?? .zero) >= Self.exitDeadline
    }
}
