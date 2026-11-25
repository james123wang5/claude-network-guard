import Foundation

@MainActor
final class SessionWatchdog {
    struct Event: Decodable {
        let id: String
        let date: Date
        let reason: String
        let mainExited: Bool

        var message: String {
            let cause = reason == "guard_exited" ? "Guard 已退出" : "Guard 的监测心跳中断"
            return cause + (mainExited ? "，守护进程已结束 Claude 主程序。辅助进程未复核。"
                : "，守护进程未确认 Claude 主程序退出。")
        }
    }

    private let process: Process
    private let heartbeat: FileHandle

    private init(process: Process, heartbeat: FileHandle) {
        self.process = process
        self.heartbeat = heartbeat
    }

    static func start(pid: pid_t, executable: String) async -> SessionWatchdog? {
        guard let tool = Bundle.main.url(forAuxiliaryExecutable: "guardwatch") else { return nil }
        try? FileManager.default.createDirectory(at: GuardPaths.watchdogLog.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard let identity = AppProcessExitCheck.Identity.read(pid) else { return nil }
        let input = Pipe()
        let output = Pipe()
        let process = Process()
        process.executableURL = tool
        process.arguments = [String(pid), executable, String(identity.seconds), String(identity.microseconds), GuardPaths.watchdogLog.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // A dead watchdog must not make writes terminate the app with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        do { try process.run() } catch { return nil }
        let ready = await Task.detached {
            (try? output.fileHandleForReading.read(upToCount: 6)) == Data("ready\n".utf8)
        }.value
        guard ready else {
            try? input.fileHandleForWriting.close()
            return nil
        }
        return SessionWatchdog(process: process, heartbeat: input.fileHandleForWriting)
    }

    func beat() -> Bool {
        guard process.isRunning else { return false }
        do {
            try heartbeat.write(contentsOf: Data([1]))
            return true
        } catch {
            return false
        }
    }

    func close() { try? heartbeat.close() }

    static func eventHistory() -> [Event] {
        let path = GuardPaths.watchdogLog
        guard let lines = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return lines.split(whereSeparator: \.isNewline).compactMap { try? decoder.decode(Event.self, from: Data($0.utf8)) }
    }
}
