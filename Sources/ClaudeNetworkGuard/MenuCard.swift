import AppKit
import GuardCore
import SwiftUI

/// 菜单栏小卡：一眼看到状态，常用操作不用开主窗口。
struct MenuCard: View {
    @ObservedObject var session: GuardSession
    @ObservedObject var isolation: IsolationModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: state.icon).font(.system(size: 22, weight: .medium)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title).font(.system(size: 15, weight: .bold))
                    Text(state.detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.86)).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(14)
            .background(Color.hero(state.tone), in: RoundedRectangle(cornerRadius: 12))
            if session.active {
                HStack(spacing: 8) {
                    if session.lineCut { Button("检查并恢复", action: session.recoverLine).primaryButton().disabled(session.recovering) }
                    Button("停止并退出 Claude", action: session.stop).disabled(session.stopping)
                }
            }
            HStack {
                Button("打开主窗口") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "dashboard")
                }
                Spacer()
                Button("退出 Guard") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            .buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 300)
        .background(Color.paper)
    }

    private var state: (tone: StatusTone, icon: String, title: String, detail: String) {
        if session.lineCut { return (.failed, "shield.slash.fill", "Claude 已断网", session.recovering ? "正在检查线路" : "没有换到别的线路") }
        if session.siteTesting { return (.neutral, "shield", "正在看检测网站", "看完回主窗口点“看完了”") }
        guard session.active else { return (.neutral, "shield", "没有启动保护", "Claude 和平时一样") }
        guard session.runningApp != nil else { return (.neutral, "shield", "正在启动", session.title) }
        let programs = isolation.status?.shield?.programs ?? []
        return programs.isEmpty ? (.positive, "checkmark.shield.fill", "Claude 受保护", session.protectionMode.sentence)
            : (.warning, "exclamationmark.shield.fill", "Claude 受保护", "拦下了 \(programs.joined(separator: "、"))")
    }
}
