import GuardCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var session: GuardSession
    @ObservedObject var isolation: IsolationModel
    @Binding var hideAddresses: Bool
    @StateObject private var confirmRemoval = ViewState(false)

    var body: some View {
        PageHeading(title: "设置", subtitle: session.active ? "保护进行中，部分设置要停止后才能改。" : "不确定就保持默认。")
        component
        Panel(title: "iPhone 数据线", rows: true) {
            VStack(alignment: .leading, spacing: 0) {
                option("严格 DNS", "保护期间，整台 Mac 查域名都改走 USB（只有几 KB）。关掉的话，Claude 里的小工具可能从 Wi‑Fi 查域名。开着 VPN 用公司内网域名时建议关掉。",
                       $isolation.strictDNS, disabled: session.active || isolation.lockdown)
                option("锁死模式", "最严：即使系统防火墙被别的软件清空也漏不出去。代价是不支持代理的小工具会断网，允许的内网地址也不放行。",
                       $isolation.lockdown, disabled: session.active)
            }
        }
        intranet
        Panel(title: "通用", rows: true) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("要求出口地区")
                    Spacer()
                    RegionPicker(selection: session.requiredRegion, disabled: session.active || session.checkingNetwork) { session.requiredRegion = $0 }.equatable()
                }
                .tableRow()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("异常通知")
                        if let status = session.notificationStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button("启用", action: session.allowNotifications)
                }
                .tableRow()
                option("隐藏地址", "免得 Claude 截图时看到你的 IP。", $hideAddresses, disabled: false)
            }
        }
        Panel(title: "Claude Desktop", rows: true) {
            switch session.claude {
            case .searching: Text("正在核对…").foregroundStyle(.secondary).tableRow()
            case .missing: Text("没有找到。").foregroundStyle(StatusTone.failed.color).tableRow()
            case .untrusted(let reason): Text(reason).foregroundStyle(StatusTone.failed.color).tableRow()
            case .ready(let profile):
                VStack(alignment: .leading, spacing: 0) {
                    FactRow(title: "位置", value: profile.path)
                    FactRow(title: "签名", value: "Anthropic（\(profile.identity.teamID ?? "")），已核对")
                    FactRow(title: "拦截的域名", value: ClaudeApp.hosts.joined(separator: "、"))
                }
            }
        }
    }

    private var component: some View {
        Panel(title: "隔离组件", note: "在系统内核里执行断网和拦截。只在保护时生效，平时什么都不做。") {
            HStack(spacing: 12) {
                StatusTag(title: !isolation.installed ? "没有安装" : isolation.current ? "已就绪" : "要更新", tone: isolation.ready ? .positive : .warning)
                if let message = isolation.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if isolation.ready {
                    Button("移除…") { confirmRemoval.value = true }.disabled(isolation.installing || session.active)
                } else {
                    Button(isolation.installing ? "等待授权…" : isolation.installed ? "更新" : "安装", action: isolation.install)
                        .primaryButton().disabled(isolation.installing || session.active)
                }
            }
        }
        .confirmationDialog("移除后不能用 USB 专线，VPN 和热点也没有内核断网。", isPresented: $confirmRemoval.value) {
            Button("移除组件", role: .destructive, action: isolation.uninstall)
        }
    }

    private var intranet: some View {
        Panel(title: "允许的内网地址", note: "默认连不到任何内网。公司或学校的服务器可以在这里放行，只放这个端口，而且只在它走 VPN 虚拟网卡时放。") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("例如 10.1.2.3:22，多个用逗号隔开", text: $isolation.allowedText).textFieldStyle(.roundedBorder).disabled(session.active)
                if isolation.allowed == nil {
                    Text("要写成 IP:端口，最多 \(AllowedHost.limit) 个。写得不对就不会启动。").font(.caption).foregroundStyle(StatusTone.failed.color)
                }
                Text("从那台服务器再出去的流量（比如 ssh 隧道）Guard 管不到。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func option(_ title: String, _ note: String, _ value: Binding<Bool>, disabled: Bool) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch).controlSize(.small).disabled(disabled).tableRow()
    }
}

/// 两百多个地区的菜单重建很贵，只在选择或可用状态变化时重建。
private struct RegionPicker: View, Equatable {
    let selection: String
    let disabled: Bool
    let choose: (String) -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool { a.selection == b.selection && a.disabled == b.disabled }

    private static let regions = Locale.Region.isoRegions.compactMap { region -> (String, String)? in
        let code = region.identifier
        guard code.count == 2, let title = Locale(identifier: "zh_CN").localizedString(forRegionCode: code) else { return nil }
        return (code, title)
    }.sorted { $0.1.localizedCompare($1.1) == .orderedAscending }

    var body: some View {
        Picker("要求出口地区", selection: Binding(get: { selection }, set: choose)) {
            Text("不限").tag("")
            ForEach(Self.regions, id: \.0) { code, title in Text(title).tag(code) }
        }
        .labelsHidden().fixedSize().disabled(disabled)
    }
}
