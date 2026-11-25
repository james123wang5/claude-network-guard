import AppKit
import SwiftUI

struct ActivityPanel: View {
    let network: [GuardModel.Event]
    let sessions: [GuardSession.Entry]

    private enum Filter: String, CaseIterable {
        case all = "全部"
        case network = "线路"
        case session = "会话"
    }

    private struct Row: Identifiable {
        let id: UUID
        let date: Date
        let category: Filter
        let message: String
    }

    @StateObject private var filter = ViewState(Filter.all)

    var body: some View {
        let displayed = rows
        return VStack(alignment: .leading, spacing: 13) {
            HStack {
                Picker("记录分类", selection: $filter.value) {
                    ForEach(Filter.allCases, id: \.self) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button(action: copyRows) { Label("复制记录", systemImage: "doc.on.doc") }
                    .disabled(displayed.isEmpty)
            }
            Panel(rows: !displayed.isEmpty) {
                if displayed.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("暂无\(filter.value == .all ? "" : filter.value.rawValue)记录", systemImage: "text.alignleft")
                            .font(.headline)
                        Text("线路变化、检测以及会话启停会记录在这里。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 14)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(displayed) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(row.date, format: .dateTime.hour().minute().second())
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 67, alignment: .leading)
                                Text(row.category.rawValue)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(row.category == .session ? Color.guardAccent : .secondary)
                                    .frame(width: 32, alignment: .leading)
                                Text(row.message).font(.subheadline).textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .tableRow()
                        }
                    }
                }
            }
        }
    }

    private var rows: [Row] {
        let all = network.map { Row(id: $0.id, date: $0.time, category: .network, message: $0.message) } +
                  sessions.map { Row(id: $0.id, date: $0.date, category: .session, message: $0.message) }
        return all.filter { filter.value == .all || $0.category == filter.value }.sorted { $0.date > $1.date }
    }

    private func copyRows() {
        let text = rows.map { row in
            "\(row.date.formatted(date: .numeric, time: .standard))  \(row.category.rawValue)  \(row.message)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
