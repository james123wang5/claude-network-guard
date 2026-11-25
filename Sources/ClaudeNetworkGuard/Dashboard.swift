import SwiftUI

enum Page: String, CaseIterable {
    case home = "首页", details = "详情", activity = "记录", settings = "设置", help = "说明"

    var icon: String {
        switch self {
        case .home: "shield"
        case .details: "list.bullet.rectangle"
        case .activity: "clock"
        case .settings: "gearshape"
        case .help: "questionmark.circle"
        }
    }
}

struct Dashboard: View {
    @ObservedObject var model: GuardModel
    @ObservedObject var session: GuardSession
    @ObservedObject var isolation: IsolationModel
    @ObservedObject var surroundings: SurroundingsModel
    @StateObject private var page: ViewState<Page>
    /// 默认隐藏：受保护的 Claude 可能会截到这个窗口。
    @AppStorage("maskNetworkAddresses") private var hideAddresses = true

    init(model: GuardModel, session: GuardSession, isolation: IsolationModel, surroundings: SurroundingsModel, page: Page = .home) {
        self.model = model
        self.session = session
        self.isolation = isolation
        self.surroundings = surroundings
        _page = StateObject(wrappedValue: ViewState(page))
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) { content }
                    .padding(.horizontal, 28).padding(.top, 34).padding(.bottom, 30)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
            }
            .id(page.value)
        }
        .background(Color.paper)
        .tint(Color.guardAccent)
        .frame(minWidth: 840, minHeight: 600)
    }

    @ViewBuilder private var content: some View {
        switch page.value {
        case .home: HomeView(model: model, session: session, isolation: isolation, surroundings: surroundings, hideAddresses: $hideAddresses) { page.value = $0 }
        case .details: DetailsView(session: session, isolation: isolation, hideAddresses: $hideAddresses)
        case .activity:
            PageHeading(title: "记录", subtitle: "线路变化、检查结果、启动和停止。不记录公网 IP。")
            ActivityPanel(network: model.events, sessions: session.entries)
        case .settings: SettingsView(session: session, isolation: isolation, hideAddresses: $hideAddresses)
        case .help: HelpView()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                GuardMark().frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Claude").font(.system(size: 14, weight: .semibold))
                    Text("Network Guard").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .accessibilityElement(children: .combine)
            VStack(spacing: 2) {
                ForEach(Page.allCases, id: \.self) { item in
                    let chosen = page.value == item
                    Button { page.value = item } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.icon).frame(width: 18)
                            Text(item.rawValue)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 13, weight: chosen ? .semibold : .regular))
                        .foregroundStyle(chosen ? Color.guardAccent : .primary)
                        .padding(.horizontal, 10).frame(height: 34)
                        .background { if chosen { RoundedRectangle(cornerRadius: 8).fill(Color.guardAccent.opacity(0.13)) } }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Circle().fill(status.1.color).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text(status.0).font(.callout.weight(.medium))
                }
                Text("Mac 默认线路：\(model.path(.v4))").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("非官方软件，与 Anthropic 无关" + version).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)
        }
        .padding(.horizontal, 12).padding(.top, 40).padding(.bottom, 16)
        .frame(width: 184)
        .background(Color.rail)
    }

    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map { " · v\($0)" } ?? ""
    }

    private var status: (String, StatusTone) {
        if session.lineCut { return ("已断网", .failed) }
        if session.siteTesting { return ("正在看检测网站", .neutral) }
        guard session.active else { return ("未启动保护", .off) }
        return session.runningApp == nil ? ("正在启动", .neutral) : ("保护中", .positive)
    }
}
