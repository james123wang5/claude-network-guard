import AppKit
import GuardCore
import SwiftUI

/// 首页：一张状态卡、一个跟着步骤变的主按钮、一张表。
struct HomeView: View {
    @ObservedObject var model: GuardModel
    @ObservedObject var session: GuardSession
    @ObservedObject var isolation: IsolationModel
    @ObservedObject var surroundings: SurroundingsModel
    @Binding var hideAddresses: Bool
    let open: (Page) -> Void
    @AppStorage("introSeen") private var introSeen = false

    var body: some View {
        // 结论会随时间变化（过期、久未核对），5 秒刷新一次足够。
        TimelineView(.periodic(from: .now, by: 5)) { timeline in
            let now = timeline.date
            let stage = self.stage(now)
            VStack(alignment: .leading, spacing: 20) {
                if session.orphaned { orphan } else {
                switch stage {
                case .running: running(now)
                case .cut: cut(now)
                case .starting: StatusCard(tone: .neutral, icon: "shield", title: session.title, detail: session.detail, busy: true) {
                    Button("取消", action: session.stop).buttonStyle(HeroButtonStyle()).disabled(session.stopping)
                }
                default: idle(stage, now)
                }
                }
            }
            .animation(.easeOut(duration: 0.2), value: stage)
        }
    }

    /// 界面重开后发现后台还有一场会话。
    @ViewBuilder private var orphan: some View {
        let blocked = isolation.status?.state == .blocked
        StatusCard(tone: blocked ? .failed : .warning, icon: blocked ? "shield.slash.fill" : "shield.lefthalf.filled",
                   title: blocked ? "后台还有一场保护，Claude 已断网" : "后台还有一场保护在进行",
                   detail: "Guard 界面重开过，接不回原来的会话。Claude 仍被锁在原来的线路上，线路出问题时保持断网，不会换线。想继续用，先结束这场保护，再从 Guard 重新启动。",
                   busy: session.releasing) {
            Button("结束保护并退出 Claude", action: session.stopOrphan).primaryButton(inverted: true).disabled(session.releasing)
        }
    }

    // MARK: 走到哪一步

    func stage(_ now: Date) -> Stage {
        let check = session.lineCheck, checked = check?.usable(for: session.protectionMode, now: now) == true
        return Stage.of(.init(active: session.active, siteTesting: session.siteTesting, cut: session.lineCut, launched: session.runningApp != nil, mode: session.protectionMode,
                              claude: session.claude, claudeRunning: surroundings.claudeRunning, installed: isolation.installed, current: isolation.current,
                              checking: session.checkingNetwork, checked: checked, seen: checked && session.siteOpenedFor != nil && session.siteOpenedFor == check?.address,
                              approved: checked && session.isApproved(session.protectionMode, check?.address)))
    }

    // MARK: 启动前

    @ViewBuilder private func idle(_ stage: Stage, _ now: Date) -> some View {
        let check = session.lineCheck.flatMap { $0.mode == session.protectionMode ? $0 : nil }
        StatusCard(tone: check?.problem != nil && stage == .check ? .failed : .neutral, icon: stage == .launch ? "shield.lefthalf.filled" : "shield",
                   title: stage.title(check), detail: stage.detail(check, mode: session.protectionMode, claude: session.claude),
                   busy: stage == .checking, steps: session.protectionMode == .current ? nil : stage.step) {
            primary(stage)
        }
        LineSwitch(selection: $session.protectionMode, disabled: session.active || session.checkingNetwork)
        if !introSeen { intro }
        if check != nil, check?.problem == nil { result(stage, now) } else { preparation }
        ReminderList(items: Reminder.beforeStart(claude: session.claude, running: false, installed: true, current: true, mode: session.protectionMode, around: surroundings.now)
            .filter { $0.id != "missing" && $0.id != "untrusted" }, act: act)
        notes
    }

    @ViewBuilder private func primary(_ stage: Stage) -> some View {
        switch stage {
        case .download: Button("去官网下载") { act(.download) }.primaryButton(inverted: true)
        case .component:
            Button(isolation.installing ? "等待授权…" : isolation.installed ? "更新组件" : "安装组件", action: isolation.install)
                .primaryButton(inverted: true).disabled(isolation.installing)
        case .check: Button(session.lineCheck == nil ? "检查线路" : "再检查一次", action: session.inspectNativeNetwork).primaryButton(inverted: true)
        case .quitClaude: Button("退出 Claude") { act(.quitClaude) }.primaryButton(inverted: true)
        case .site: Button("打开检测网站", action: session.openSite).primaryButton(inverted: true).disabled(session.openingThirdParty || session.releasing)
        case .siteTesting: Button("看完了", action: session.stop).primaryButton(inverted: true).disabled(session.stopping || session.runningApp == nil)
        case .approve:
            Button("认可并启动") { session.approveLine(); session.startNative() }
                .primaryButton(inverted: true).disabled(session.approvable == nil || session.releasing)
        case .launch: Button("启动 Claude", action: session.startNative).primaryButton(inverted: true).disabled(session.releasing || session.target == nil)
        case .checkedOnly: Button("重新检查", action: session.inspectNativeNetwork).primaryButton(inverted: true)
        case .checking, .starting, .running, .cut: EmptyView()
        }
    }

    /// 还没检查时，告诉用户要准备什么，能看到的直接标出来。
    private var preparation: some View {
        Panel(title: "准备好了吗", rows: true) {
            switch session.protectionMode {
            case .usb:
                StateRow(title: "iPhone 数据线", value: isolation.lines.isEmpty ? "没有识别到，解锁手机并打开个人热点" : "已连接", tone: isolation.lines.isEmpty ? .warning : .positive)
                let own = model.routes?[.v4].map { route in !isolation.lines.contains { $0.interface == route.interface } } ?? false
                StateRow(title: "Mac 自己的网络", value: model.routes == nil ? "正在读取" : own ? "有，用来对比" : "没有，请连上 Wi‑Fi", tone: model.routes == nil ? .off : own ? .positive : .warning)
            case .vpn:
                let tunnel = model.routes?[.v4]?.interface.hasPrefix("utun") == true
                StateRow(title: "全机 VPN", value: model.routes == nil ? "正在读取" : tunnel ? "已连接" : "没有看到，要用全局模式", tone: model.routes == nil ? .off : tunnel ? .positive : .warning)
            case .hotspot: StateRow(title: "iPhone 热点", value: "在 Wi‑Fi 里连上手机，检查时核对", tone: .off)
            case .current: StateRow(title: "现在的网络", value: model.path(.v4), tone: .off)
            }
            if session.protectionMode != .current {
                StateRow(title: "Claude Desktop", value: claudeState.0, tone: claudeState.1)
                StateRow(title: "隔离组件", value: !isolation.installed ? "没有安装" : isolation.current ? "已就绪" : "要更新",
                         tone: isolation.ready ? .positive : .warning) {
                    if !isolation.ready { Button(isolation.installing ? "等待授权…" : isolation.installed ? "更新" : "安装", action: isolation.install).disabled(isolation.installing) }
                }
            }
        }
    }

    private var claudeState: (String, StatusTone) {
        switch session.claude {
        case .searching: ("正在核对签名", .off)
        case .missing: ("没有找到", .failed)
        case .untrusted: ("不是 Anthropic 原版", .failed)
        case .ready: surroundings.claudeRunning ? ("正开着，启动前要退出", .warning) : ("已退出，签名已核对", .positive)
        }
    }

    private func result(_ stage: Stage, _ now: Date) -> some View {
        let health = overview(now)
        let checked = [Stage.check, .checking].contains(stage) == false
        return Panel(title: "线路检查", rows: true) {
            ForEach(health.facts) { StateRow(title: $0.label, value: $0.value, tone: .off) }
            ForEach(health.tiles.filter { !["你的认可", "Claude 能不能用"].contains($0.title) }) { TileRow(tile: $0, showAction: false) }
            StateRow(title: "检测网站", value: session.siteOpenedFor != nil && session.siteOpenedFor == session.lineCheck?.address ? "已看过" : "还没看", tone: .off) {
                Button(stage == .site ? "打开" : "再看一次", action: session.openSite).disabled(!checked || session.openingThirdParty || session.siteTesting || session.releasing || session.active)
            }
            let probe = session.probe.flatMap { $0.address == session.lineCheck?.address ? $0 : nil }
            StateRow(title: "试连 Claude（可选）", value: probe?.text ?? "Claude 会看到这个 IP", tone: probe?.tone ?? .off) {
                Button(session.probing ? "正在试…" : "试一下", action: session.probeService).disabled(!checked || session.probing || session.active)
            }
            if session.protectionMode != .current {
                let ok = session.isApproved(session.protectionMode, session.lineCheck?.address)
                StateRow(title: "你的认可", value: ok ? "已认可，24 小时内有效，IP 一变就不算数" : "看过网站、觉得可以再认可", tone: ok ? .positive : .off) {
                    if ok, !session.active { Button("取消", action: session.revokeLine) }
                }
            }
        } trailing: {
            HStack(spacing: 12) {
                if checked, stage != .checkedOnly { Button("重新检查", action: session.inspectNativeNetwork).buttonStyle(.link).disabled(session.active) }
                eye
            }
        }
    }

    private var eye: some View {
        Button { hideAddresses.toggle() } label: { Image(systemName: hideAddresses ? "eye.slash" : "eye") }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help(hideAddresses ? "显示地址" : "隐藏地址").accessibilityLabel(hideAddresses ? "显示地址" : "隐藏地址")
    }

    @ViewBuilder private var notes: some View {
        if let note = session.thirdPartyNote { Text(note).font(.callout).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4) }
        if let message = isolation.message { Text(message).font(.callout).padding(.horizontal, 4) }
        if session.title != GuardSession.idleTitle, !session.active {
            Text("上次：\(session.title)。\(session.detail)").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
        if session.lineCheck != nil {
            Text("检测网站 \(ThirdPartyCheck.name) 是第三方，不代表 Anthropic，也不保证账号安全。它会看到这个 IP，也会从这条线路连 Claude。Guard 不读取网页内容。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
    }

    private var intro: some View {
        Panel {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "hand.wave").font(.system(size: 18)).foregroundStyle(Color.guardAccent).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("只保护从这里启动的 **Claude Desktop**，不管网页版和终端里的 claude。")
                    Text("只放行你认可过的 IP。断线或 IP 变了，Claude 立刻断网，不会偷偷换线。")
                    Text("不启动时什么都不做，Claude 和平时一样。")
                }
                .font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("知道了") { introSeen = true }
            }
        }
    }

    private func act(_ action: Reminder.Action) {
        switch action {
        case .component: isolation.install()
        case .quitClaude: ClaudeApp.running.forEach { $0.terminate() }
        case .download: NSWorkspace.shared.open(URL(string: "https://claude.com/download")!)
        case .help: open(.help)
        }
    }

    // MARK: 会话

    @ViewBuilder private func running(_ now: Date) -> some View {
        let health = overview(now)
        StatusCard(tone: health.tone == .off ? .neutral : health.tone, icon: health.tone == .positive ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                   title: health.tone == .positive ? "Claude 受保护" : health.headline,
                   detail: health.tone == .positive ? "\(session.protectionMode.sentence) · 没有发现异常" : health.detail, facts: health.facts) {
            Button(session.stopping ? "正在退出…" : "停止并退出 Claude", action: session.stop).buttonStyle(HeroButtonStyle()).disabled(session.stopping)
        }
        ReminderList(items: Reminder.whileRunning(shield: isolation.status?.shield, closedOutsideAt: session.closedOutsideAt,
                                                  mode: session.protectionMode, around: surroundings.now, now: now), act: act)
        if !health.tiles.isEmpty {
            Panel(title: "正在看守", rows: true) { ForEach(health.tiles) { TileRow(tile: $0, showAction: true) } } trailing: { eye }
        }
        Panel(title: "记住这三件事") {
            VStack(alignment: .leading, spacing: 9) {
                Note(icon: "safari", text: session.usbSession ? "Safari、Chrome 不在保护里。claude.ai 网页现在打不开，这是故意的。" : "点链接打开的 Safari、Chrome 不在保护里。")
                Note(icon: "person.badge.key", text: "要重新登录 Claude，先停止保护。步骤在「说明」里。")
                Note(icon: "terminal", text: "Claude 里的 Code 受保护；你自己在终端里敲的 claude 不受。")
            }
        }
        HStack(spacing: 10) {
            Button(session.usbSession ? "复制检测网址" : "再看一次检测网站", action: session.openSite).disabled(session.openingThirdParty)
            Button("查看详情") { open(.details) }
        }
        .padding(.horizontal, 4)
        if let note = session.thirdPartyNote { Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4) }
    }

    @ViewBuilder private func cut(_ now: Date) -> some View {
        let check = session.lineCheck, checked = check?.usable(for: session.protectionMode, now: now) == true
        let seen = checked && session.siteOpenedFor != nil && session.siteOpenedFor == check?.address
        let approved = checked && session.isApproved(session.protectionMode, check?.address)
        StatusCard(tone: .failed, icon: "shield.slash.fill", title: session.recovering ? "正在检查线路" : session.title, detail: session.detail, busy: session.recovering) {
            Button("停止并退出 Claude", action: session.stop).buttonStyle(HeroButtonStyle()).disabled(session.stopping)
            Button("检查并恢复", action: session.recoverLine).primaryButton(inverted: true).disabled(session.recovering || session.stopping)
        }
        Text("聊天内容都在。不会自动恢复，要你点一下。" + (session.protectionMode == .usb ? "恢复前 Wi‑Fi 也要开着。" : "")).font(.callout).padding(.horizontal, 4)
        Panel(title: "公网 IP 变了？", note: "原来的 IP 可以直接恢复。换了新 IP，先走完这三步。", rows: true) {
            StateRow(title: "1  检查新 IP", value: check?.problem ?? (checked ? "检查通过" : "Claude 仍然断网"), tone: check?.problem != nil ? .failed : checked ? .positive : .off) {
                if session.checkingNetwork { ProgressView().controlSize(.small) } else { Button("检查", action: session.inspectNativeNetwork).disabled(session.recovering) }
            }
            StateRow(title: "2  看检测网站", value: seen ? "已看过" : session.protectionMode == .usb ? "先关掉 Wi‑Fi，看完再打开" : "在默认浏览器打开", tone: seen ? .positive : .off) {
                Button("打开", action: session.openSite).disabled(!checked || session.openingThirdParty || session.recovering)
            }
            StateRow(title: "3  认可新 IP", value: approved ? "已认可，可以恢复了" : "觉得可以再点", tone: approved ? .positive : .off) {
                if !approved { Button("认可", action: session.approveLine).disabled(session.approvable == nil) }
            }
        }
        if let note = session.thirdPartyNote { Text(note).font(.callout).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4) }
    }

    // MARK: 结论

    private func overview(_ now: Date) -> HealthOverview {
        let app = "Claude"
        let labels = isolation.status?.shield?.hits?.isEmpty == false ? NetworkCheck.interfaceLabels() : [:]
        if session.usbSession, session.active, !session.siteTesting {
            let busy = session.recovering ? "正在检查线路" : isolation.status?.state == .armed ? nil : session.title
            return .usb(app: app, status: isolation.status, locked: session.lineCut && !session.recovering, busy: busy, exit: session.usbExit,
                        proof: session.proof, proofAt: session.proofAt, trafficAt: isolation.trafficAt, hideAddresses: hideAddresses, now: now, labels: labels)
        }
        let check = session.lineCheck.flatMap { $0.mode == session.protectionMode ? $0 : nil }
        let live = session.active && !session.siteTesting
        if session.protectionMode == .usb, !live {
            return .usbCheck(app: app, check: check, approved: session.isApproved(.usb, check?.address), hideAddresses: hideAddresses, now: now)
        }
        let report = session.networkReport
        return .line(app: app, mode: live ? session.protectionMode : nil, report: live || check != nil ? report : nil,
                     freshness: report.map { ReportFreshness(measuredAt: $0.date, now: now, checking: false, networkChanged: session.pendingNetworkCheck) },
                     warning: live ? session.monitoringWarning : nil, shield: isolation.status?.shield, hideAddresses: hideAddresses,
                     cut: live && session.lineCut ? (session.recovering ? "正在检查线路。" : session.detail) : nil, problem: check?.problem,
                     approved: session.isApproved(session.protectionMode, report?.exits[.v4]?.address), ipv4Only: session.kernelLocked,
                     quits: live && !session.kernelLocked, checkOnly: session.protectionMode == .current,
                     probe: session.probe.flatMap { $0.address == check?.address ? $0 : nil },
                     usbIdle: !isolation.lines.isEmpty && !isolation.lines.contains { $0.interface == report?.routes[.v4]?.interface }, labels: labels)
    }
}

// MARK: - 步骤

/// 现在该做什么。主按钮只跟着它变，所以单独写成纯函数来测。
enum Stage: Equatable {
    case download, component, check, checking, quitClaude, site, siteTesting, approve, launch, checkedOnly, starting, running, cut

    struct Facts {
        var active = false, siteTesting = false, cut = false, launched = false
        var mode = NativeProtectionMode.usb
        var claude = ClaudeApp.Status.searching
        var claudeRunning = false, installed = true, current = true
        var checking = false, checked = false, seen = false, approved = false
    }

    static func of(_ f: Facts) -> Stage {
        if f.siteTesting { return .siteTesting }
        if f.active { return f.cut ? .cut : f.launched ? .running : .starting }
        if f.checking { return .checking }
        if f.mode == .current { return !f.checked ? .check : f.seen ? .checkedOnly : .site }
        switch f.claude {
        case .missing, .untrusted: return .download
        case .searching, .ready: break
        }
        // 组件没装、版本不配套或暂时没响应，三种保护都不能启动：没有内核锁线就不算保护。
        if !f.installed || !f.current { return .component }
        if !f.checked { return .check }
        if f.approved { return f.claudeRunning ? .quitClaude : .launch }
        // 从 USB 打开检测网站时 Claude 必须已经退出。
        if !f.seen { return f.mode == .usb && f.claudeRunning ? .quitClaude : .site }
        return f.claudeRunning ? .quitClaude : .approve
    }

    /// 进度条上的第几步，从 0 开始。
    var step: Int {
        switch self {
        case .download, .component, .check, .checking: 0
        case .site, .siteTesting: 1
        case .approve: 2
        case .quitClaude, .launch, .checkedOnly, .starting, .running, .cut: 3
        }
    }

    func title(_ check: LineCheck?) -> String {
        switch self {
        case .download: "没有可用的 Claude Desktop"
        case .component: "先装好隔离组件"
        case .check: check?.problem != nil ? "这条线路现在不能用" : "还没启动保护"
        case .checking: "正在检查线路"
        case .quitClaude: "先退出 Claude"
        case .site: "检查通过"
        case .siteTesting: "正在看检测网站"
        case .approve: "认可这个 IP？"
        case .launch: "可以启动了"
        case .checkedOnly: "检查完了"
        case .starting, .running, .cut: ""
        }
    }

    func detail(_ check: LineCheck?, mode: NativeProtectionMode, claude: ClaudeApp.Status) -> String {
        switch self {
        case .download: if case .untrusted(let reason) = claude { reason + "请从官网重新安装。" } else { "先装到「应用程序」里。网页版和终端里的 claude 不归这里管。" }
        case .component: "装一次就行，要输一次 Mac 密码。平时什么都不做。"
        case .check: check?.problem ?? (mode == .current ? "看看现在的网络，不做保护。" : "先检查 \(mode.title) 这条线路，不会连 Claude。")
        case .checking: "比对几个来源的公网 IP，不会连 Claude。"
        case .quitClaude: "它正开着。要从这里打开才受保护，只关窗口不算退出。"
        case .site: mode == .usb ? "去网站看看这个 IP。会用一个空白浏览器窗口从 USB 打开。" : "去网站看看这个 IP，绿了几项由你看。"
        case .siteTesting: "看完回来点“看完了”，浏览器窗口会关掉。"
        case .approve: "网站结果你满意，而且网站显示的 Claude 出口 IP 和这里一样，再点。"
        case .launch: "这个 IP 你认可过。启动时会再核对一次，不一样就不打开。"
        case .checkedOnly: "这里不做保护。满意就从程序坞正常打开 Claude。"
        case .starting, .running, .cut: ""
        }
    }
}

// MARK: - 部件

/// 整页最重要的一块：现在怎样、下一步点哪里。
struct StatusCard<Action: View>: View {
    let tone: StatusTone
    let icon: String
    let title: String
    let detail: String
    var busy = false
    var steps: Int?
    var facts: [HealthOverview.Fact] = []
    @ViewBuilder var action: Action

    private static var names: [String] { ["检查", "看网站", "认可", "启动"] }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 18) {
                ZStack {
                    Circle().fill(.white.opacity(0.14))
                    if busy { ProgressView().controlSize(.small).colorScheme(.dark) }
                    else { Image(systemName: icon).font(.system(size: 25, weight: .medium)) }
                }
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 22, weight: .bold)).accessibilityAddTraits(.isHeader)
                    Text(detail).font(.system(size: 13)).foregroundStyle(.white.opacity(0.86)).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                HStack(spacing: 9) { action }
            }
            if let steps {
                HStack(spacing: 8) {
                    ForEach(0..<Self.names.count, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 6) {
                            Capsule().fill(.white.opacity(index < steps ? 0.95 : index == steps ? 0.6 : 0.2)).frame(height: 3)
                            Text(Self.names[index]).font(.system(size: 11, weight: index == steps ? .semibold : .regular))
                                .foregroundStyle(.white.opacity(index <= steps ? 1 : 0.72))
                        }
                        .accessibilityLabel("\(Self.names[index])，\(index < steps ? "已完成" : index == steps ? "现在这一步" : "还没到")")
                    }
                }
            }
            if !facts.isEmpty {
                HStack(alignment: .top, spacing: 34) {
                    ForEach(facts) { fact in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fact.label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.76))
                            Text(fact.value).font(.system(size: 14, weight: .semibold)).monospacedDigit().textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.hero(tone), in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
    }
}

/// 线路切换条。
private struct LineSwitch: View {
    @Binding var selection: NativeProtectionMode
    let disabled: Bool

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 3) {
                ForEach(NativeProtectionMode.choices) { mode in
                    let chosen = selection == mode
                    Button { selection = mode } label: {
                        Label(mode.title, systemImage: mode.icon)
                            .font(.system(size: 13, weight: chosen ? .semibold : .regular))
                            .foregroundStyle(chosen ? Color.guardAccent : .secondary)
                            .padding(.horizontal, 13).frame(height: 32)
                            .background { if chosen { RoundedRectangle(cornerRadius: 8).fill(Color.panel).shadow(color: .black.opacity(0.10), radius: 2, y: 1) } }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Color.rail, in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(Color.hairline) }
            Spacer(minLength: 8)
            Text(selection.summary).font(.callout).foregroundStyle(.secondary)
        }
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
    }
}

extension NativeProtectionMode {
    static let choices: [Self] = [.vpn, .hotspot, .usb, .current]

    var title: String {
        switch self {
        case .vpn: "VPN"
        case .hotspot: "iPhone 热点"
        case .usb: "iPhone 数据线"
        case .current: "只检查"
        }
    }

    var icon: String {
        switch self {
        case .vpn: "lock.shield"
        case .hotspot: "personalhotspot"
        case .usb: "cable.connector"
        case .current: "stethoscope"
        }
    }

    var summary: String {
        switch self {
        case .vpn: "整台 Mac 都走 VPN"
        case .hotspot: "整台 Mac 连手机热点"
        case .usb: "只有 Claude 走手机"
        case .current: "不做保护"
        }
    }

    var sentence: String {
        switch self {
        case .vpn: "只走这条 VPN"
        case .hotspot: "只走 iPhone 热点"
        case .usb: "只走 iPhone 数据线"
        case .current: "没有保护"
        }
    }
}

/// 表里的一行：名称、值、可选的状态点和按钮。
struct StateRow<Action: View>: View {
    let title: String
    let value: String
    let tone: StatusTone
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            if tone != .off { Image(systemName: tone.icon).foregroundStyle(tone.color).accessibilityHidden(true) }
            Text(value).foregroundStyle(tone == .warning || tone == .failed ? tone.color : .primary)
                .monospacedDigit().multilineTextAlignment(.trailing).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            action.controlSize(.small)
        }
        .tableRow()
    }
}

extension StateRow where Action == EmptyView {
    init(title: String, value: String, tone: StatusTone) { self.init(title: title, value: value, tone: tone) { EmptyView() } }
}

/// 检查项的一行，有详情的可以点开。
private struct TileRow: View {
    let tile: HealthOverview.Tile
    let showAction: Bool
    @StateObject private var open = ViewState(false)

    var body: some View {
        if tile.details.isEmpty { content } else {
            Button { open.value.toggle() } label: { content }
                .buttonStyle(.plain)
                .accessibilityHint("点开看详情")
                .popover(isPresented: $open.value, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tile.title).font(.headline)
                        ForEach(tile.details, id: \.self) { Text($0).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                    }
                    .padding(16).frame(width: 380, alignment: .leading)
                }
        }
    }

    private var content: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                // 启动前上面已有一行公网 IP，这里说的是几个来源对不对得上。
                Text(!showAction && tile.title == "公网 IP" ? "IP 多来源核对" : tile.title).foregroundStyle(showAction ? .primary : .secondary)
                if showAction { Text(tile.action).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 16)
            Image(systemName: tile.tone.icon).foregroundStyle(tile.tone.color).accessibilityHidden(true)
            Text(tile.value).foregroundStyle(tile.tone == .warning || tile.tone == .failed ? tile.tone.color : .primary).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
            if !tile.details.isEmpty { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
        }
        .tableRow()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct Note: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Color.guardAccent).frame(width: 18).accessibilityHidden(true)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 提醒默认一行，点开才看详细和怎么办。
private struct ReminderList: View {
    let items: [Reminder]
    let act: (Reminder.Action) -> Void

    var body: some View {
        if !items.isEmpty {
            Panel(title: "要留意", rows: true) { ForEach(items) { ReminderRow(item: $0, act: act) } }
        }
    }
}

private struct ReminderRow: View {
    let item: Reminder
    let act: (Reminder.Action) -> Void
    @StateObject private var open = ViewState(false)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open.value.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: item.tone.icon).foregroundStyle(item.tone.color).frame(width: 18).accessibilityHidden(true)
                    Text(item.title)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary).rotationEffect(.degrees(open.value ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(open.value ? "收起" : "展开怎么办")
            if open.value {
                HStack(alignment: .top, spacing: 12) {
                    Text(item.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if let action = item.action { Button(label(action)) { act(action) }.controlSize(.small) }
                }
                .padding(.leading, 28)
            }
        }
        .tableRow()
    }

    private func label(_ action: Reminder.Action) -> String {
        switch action {
        case .component: "安装或更新"
        case .quitClaude: "退出 Claude"
        case .download: "去官网下载"
        case .help: "怎么办"
        }
    }
}
