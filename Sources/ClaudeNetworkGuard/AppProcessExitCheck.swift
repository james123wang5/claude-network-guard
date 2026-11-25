import Darwin
import Foundation

struct AppProcessExitCheck {
    struct Identity: Equatable {
        let pid: pid_t
        let seconds: UInt64
        let microseconds: UInt64

        static func read(_ pid: pid_t) -> Self? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            return Self(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
        }

        var startedAt: Date { Date(timeIntervalSince1970: Double(seconds) + Double(microseconds) / 1_000_000) }

        func stillExists() -> Bool? {
            if let current = Self.read(pid) { return current == self }
            errno = 0
            if kill(pid, 0) == -1 && errno == ESRCH { return false }
            return nil
        }
    }

    struct Result {
        let tracked: Int
        let remaining: [pid_t]
        let unconfirmed: [pid_t]

        var hasOutstanding: Bool { !remaining.isEmpty || !unconfirmed.isEmpty }

        var sessionTitle: String? {
            if !remaining.isEmpty { return "Claude 主程序已退出，仍有相关进程" }
            if !unconfirmed.isEmpty { return "Claude 主程序已退出，部分进程未确认" }
            return nil
        }

        var notes: [String] {
            var notes: [String] = []
            if !remaining.isEmpty { notes.append("仍在运行 · PID " + remaining.map(String.init).joined(separator: "、")) }
            if !unconfirmed.isEmpty { notes.append("无法确认 · PID " + unconfirmed.map(String.init).joined(separator: "、")) }
            return notes
        }

        var summary: String {
            if tracked == 0 { return "没有采集到可核对的辅助进程。" }
            if remaining.isEmpty && unconfirmed.isEmpty {
                return "已核对本次观察到的 \(tracked) 个辅助进程和工具均已退出。"
            }
            return "已核对 \(tracked) 个进程，仍在运行 \(remaining.count) 个，无法确认 \(unconfirmed.count) 个。"
        }
    }

    private var tracked: [pid_t: Identity] = [:]
    private var unavailable: Set<pid_t> = []

    mutating func remember(_ identities: [Identity], unavailable pids: [pid_t]) {
        for identity in identities {
            tracked[identity.pid] = identity
            unavailable.remove(identity.pid)
        }
        unavailable.formUnion(pids.filter { tracked[$0] == nil })
    }

    mutating func captureChildren(of root: pid_t) {
        var queue = [root]
        var seen: Set<pid_t> = [root]
        var index = 0
        while index < queue.count, queue.count < 64 {
            let parent = queue[index]
            index += 1
            var buffer = [pid_t](repeating: 0, count: 64)
            let bytes = Int32(buffer.count * MemoryLayout<pid_t>.stride)
            let count = buffer.withUnsafeMutableBytes { proc_listchildpids(parent, $0.baseAddress, bytes) }
            guard count > 0 else { continue }
            for pid in buffer.prefix(min(Int(count), buffer.count)) where pid > 0 && seen.insert(pid).inserted {
                guard queue.count < 64 else { break }
                queue.append(pid)
                if let identity = Identity.read(pid) {
                    remember([identity], unavailable: [])
                } else {
                    remember([], unavailable: [pid])
                }
            }
        }
    }

    func status() -> Result {
        var remaining: [pid_t] = []
        var unconfirmed = unavailable.filter { pid in
            kill(pid, 0) == 0 || errno != ESRCH
        }
        for identity in tracked.values {
            switch identity.stillExists() {
            case true?: remaining.append(identity.pid)
            case false?: break
            case nil: unconfirmed.insert(identity.pid)
            }
        }
        return Result(tracked: tracked.count + unavailable.count, remaining: remaining.sorted(),
                      unconfirmed: unconfirmed.sorted())
    }
}
