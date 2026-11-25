import AppKit
import SwiftUI

@main
struct ClaudeNetworkGuardApp: App {
    @NSApplicationDelegateAdaptor(GuardAppDelegate.self) private var appDelegate
    @StateObject private var model = GuardModel()
    @StateObject private var session = GuardSession()
    @StateObject private var surroundings = SurroundingsModel()

    var body: some Scene {
        Window("Claude Network Guard", id: "dashboard") {
            Dashboard(model: model, session: session, isolation: session.isolation, surroundings: surroundings).onAppear(perform: begin)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in session.refreshClaude() }
        }
        .defaultSize(width: 1040, height: 800)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuCard(session: session, isolation: session.isolation).onAppear(perform: begin)
        } label: {
            Label("Claude Network Guard", systemImage: session.lineCut ? "shield.slash" : session.active ? "checkmark.shield.fill" : "shield")
        }
        .menuBarExtraStyle(.window)
    }

    private func begin() {
        appDelegate.session = session
        session.importWatchdogEvents()
        session.refreshClaude()
        surroundings.monitor()
        session.isolation.onEvent = { [weak session] event in
            guard ["escape", "udp", "dns", "repair", "killed", "shield", "exit"].contains(event.kind) else { return }
            session?.recordEntry(event.detail)
            if event.kind != "udp" { GuardNotifications.shared.report(title: "隔离保护", detail: event.detail) }
        }
        model.start()
        session.isolation.monitor()
    }
}

@MainActor
final class GuardAppDelegate: NSObject, NSApplicationDelegate {
    weak var session: GuardSession?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard session?.active == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Claude 会话仍由 Guard 管理"
        alert.informativeText = "请先在 Guard 停止会话，或退出 Claude，再退出 Guard。"
        alert.runModal()
        return .terminateCancel
    }
}
