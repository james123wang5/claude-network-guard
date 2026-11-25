import Darwin
import Foundation

struct AppConnectionObservation: Sendable {
    struct ProcessRow: Identifiable, Sendable {
        let id: pid_t
        let role: String
        var connections: Int?
        var interfaces: Set<String> = []
    }

    let processes: [ProcessRow]
    let date: Date
    let identities: [AppProcessExitCheck.Identity]
    let unidentified: [pid_t]

    static func descendants(in snapshot: String, root: pid_t, bundlePath: String) -> [pid_t: ProcessRow] {
        var children: [pid_t: [(pid_t, String)]] = [:]
        for line in snapshot.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count == 3, let pid = pid_t(fields[0]), let parent = pid_t(fields[1]), pid > 0 else { continue }
            children[parent, default: []].append((pid, String(fields[2])))
        }
        var result = [root: ProcessRow(id: root, role: "Claude 主程序")]
        var queue = [root]
        var index = 0
        while index < queue.count && queue.count < 64 {
            let parent = queue[index]
            index += 1
            for (id, executable) in children[parent] ?? [] where result[id] == nil {
                if queue.count >= 64 { break }
                let role = executable.hasPrefix(bundlePath + "/") ? "Claude 辅助进程" : "Claude 派生工具"
                result[id] = ProcessRow(id: id, role: role)
                queue.append(id)
            }
        }
        return result
    }

    // Netglass's source shows that per-flow interface is on the row following the
    // process summary. Attribute only rows with a concrete remote endpoint.
    static func observe(_ output: String, candidates: [pid_t: ProcessRow]) -> [ProcessRow] {
        var found: [pid_t: ProcessRow] = [:]
        var current: pid_t?
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }
            // Several macOS nettop versions omit the leading timestamp column.
            let index = fields.count >= 5 ? 1 : 0
            let value = fields[index].trimmingCharacters(in: .whitespaces)
            let endpoints = value.components(separatedBy: "<->")
            if endpoints.count == 1 {
                current = value.split(separator: ".").last.flatMap { pid_t($0) }
                if let current, var candidate = candidates[current] {
                    candidate.connections = 0
                    found[current] = candidate
                }
                continue
            }
            guard endpoints.count == 2, !endpoints[1].contains("*"), let current, var row = found[current] else { continue }
            row.connections = (row.connections ?? 0) + 1
            let interface = fields[index + 1].trimmingCharacters(in: .whitespaces)
            if !interface.isEmpty { row.interfaces.insert(interface) }
            found[current] = row
        }
        return found.values.sorted { $0.id < $1.id }
    }

    static func processTree(pid: pid_t, bundlePath: String) async -> [pid_t: ProcessRow]? {
        guard let processList = await NativeDiagnostics.command("/bin/ps", ["-ax", "-o", "pid=,ppid=,comm="]),
              processList.status == 0 else { return nil }
        return descendants(in: processList.text, root: pid, bundlePath: bundlePath)
    }

    static func sample(pid: pid_t, bundlePath: String) async -> Self? {
        guard let candidates = await processTree(pid: pid, bundlePath: bundlePath) else { return nil }
        let children = candidates.keys.filter { $0 != pid }
        let identities = children.compactMap(AppProcessExitCheck.Identity.read)
        let identified = Set(identities.map(\.pid))
        let selection = candidates.keys.sorted().flatMap { ["-p", String($0)] }
        let output = await NativeDiagnostics.command("/usr/bin/nettop",
            ["-n", "-L", "1", "-J", "interface,state"] + selection)
        let observed = output.flatMap { $0.status == 0 ? observe($0.text, candidates: candidates) : nil } ?? []
        let missingRoot = observed.contains { $0.id == pid } ? [] : candidates[pid].map { [$0] } ?? []
        return Self(processes: missingRoot + observed, date: Date(), identities: identities,
                    unidentified: children.filter { !identified.contains($0) })
    }
}
