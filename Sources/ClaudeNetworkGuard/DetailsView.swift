import GuardCore
import SwiftUI

/// 给想看证据的人：自检、会话、流量、技术明细。
struct DetailsView: View {
    @ObservedObject var session: GuardSession
    @ObservedObject var isolation: IsolationModel
    @Binding var hideAddresses: Bool
    @StateObject private var showTechnical = ViewState(false)

    var body: some View {
        HStack(alignment: .top) {
            PageHeading(title: "详情", subtitle: "保护生效的证据。看不懂也没关系，首页的结论就是从这里来的。")
            Spacer()
            Button { hideAddresses.toggle() } label: { Label(hideAddresses ? "显示地址" : "隐藏地址", systemImage: hideAddresses ? "eye" : "eye.slash") }
                .help("默认隐藏，免得 Claude 截图时看到")
        }
        if let status = isolation.status, status.state != .idle { live(status) }
        else { Panel { Text("现在没有受保护的会话。启动后，这里会显示自检结果、受保护的进程和流量。").foregroundStyle(.secondary) } }
        if session.proof != nil { evidence }
        line
        if let status = isolation.status { traffic(status) }
        Panel {
            DisclosureGroup(isExpanded: $showTechnical.value) {
                technical.padding(.top, 10)
            } label: { Text("技术明细").font(.headline) }
        }
    }

    private func live(_ status: ControlStatus) -> some View {
        Panel(title: "当前会话", rows: true) {
            VStack(alignment: .leading, spacing: 0) {
                if let reason = status.reason { Text(IsolationModel.explain(reason)).foregroundStyle(StatusTone.failed.color).tableRow() }
                FactRow(title: "状态", value: status.state == .armed ? "保护生效中" : "已断网")
                FactRow(title: "受保护进程", value: "\(status.members.count) 个")
                let names = Dictionary(grouping: status.members, by: \.name).map { $0.value.count > 1 ? "\($0.key) ×\($0.value.count)" : $0.key }.sorted()
                if !names.isEmpty { Text(names.joined(separator: "、")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.bottom, 10) }
                if status.mode == .usb {
                    FactRow(title: "域名查询（DNS）", value: status.strictDNS ? "全机走 USB" : status.protectedDomains.isEmpty ? "仅转发器内走 USB" : "转发器和 \(status.protectedDomains.count) 个域名走 USB")
                    FactRow(title: "不看代理、由内核改道的流量", value: bytes(status.redirected))
                    FactRow(title: "对其他软件的影响", value: impact(status))
                }
                FactRow(title: "公网 IP 核对", value: status.exitCheckedAt.map { "和认可的一致 · " + $0.formatted(date: .omitted, time: .standard) } ?? "等待核对")
                if let open = status.allowed, !open.isEmpty { FactRow(title: "放行的内网地址", value: open.joined(separator: "、")) }
                if let shield = status.shield {
                    FactRow(title: "拦住保护外的软件连 Claude", value: shield.verified ? "已验证生效" : "还没验证")
                    if shield.blockedPackets > 0 { FactRow(title: "已拦下", value: "\(shield.blockedPackets) 个包" + (shield.programs.isEmpty ? "，没认出是哪个软件" : "：" + shield.programs.joined(separator: "、"))) }
                    if !shield.uncovered.isEmpty { FactRow(title: "拦不到（和别的网站共用地址）", value: shield.uncovered.joined(separator: "、")) }
                }
            }
        }
    }

    private var evidence: some View {
        Panel(title: "隔离自检", note: session.proofAt.map { "启动前以 Claude 的身份主动尝试从别的线路出去，全部失败才会打开。" + $0.formatted(date: .omitted, time: .standard) }, rows: true) {
            if let proof = session.proof, let usb = session.usbExit, let other = session.otherExit {
                ForEach(proof.rows(usb: usb.address, other: other.address)) { item in
                    StateRow(title: item.id, value: hideAddresses && item.detail.contains(where: \.isNumber) ? (item.passed ? "出口正确（地址已隐藏）" : "出口不对（地址已隐藏）") : item.detail,
                             tone: item.passed ? .positive : item.blocking ? .failed : .warning)
                }
            }
        }
    }

    private var line: some View {
        Panel(title: "iPhone USB", rows: true) {
            VStack(alignment: .leading, spacing: 0) {
                if isolation.lines.isEmpty { Text("没有识别到。插好数据线、解锁手机、信任此电脑，并打开个人热点。").foregroundStyle(.secondary).tableRow() }
                ForEach(isolation.lines, id: \.interface) { item in
                    FactRow(title: item.interface, value: hideAddresses ? "已连接" : "\(item.address) · 网关 \(item.gateway)")
                }
                if let usb = session.usbExit { FactRow(title: "USB 公网出口", value: exit(usb, hidden: hideAddresses)) }
                if let other = session.otherExit { FactRow(title: "Mac 原线路出口", value: exit(other, hidden: hideAddresses)) }
            }
        }
    }

    private func traffic(_ status: ControlStatus) -> some View {
        let recent = status.days.suffix(30)
        return Panel(title: "USB 流量", note: "只统计经转发器的部分，以运营商账单为准。", rows: true) {
            VStack(alignment: .leading, spacing: 0) {
                if status.mode == .usb { FactRow(title: "本次会话", value: volume(status.upload, status.download)) }
                FactRow(title: "最近 30 天", value: volume(recent.reduce(0) { $0 + $1.upload }, recent.reduce(0) { $0 + $1.download }))
                if !recent.isEmpty {
                    DisclosureGroup("每天") { ForEach(Array(recent.reversed())) { FactRow(title: $0.day, value: volume($0.upload, $0.download)) } }.tableRow()
                }
            }
        }
    }

    private var technical: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let evidence = session.modeEvidence { Text("所选线路 · " + evidence).font(.callout) }
            if let event = session.lastNetworkEvent { Text("最近的系统事件 · \(event)").font(.callout) }
            if let warning = session.monitoringWarning { Label(warning, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(StatusTone.warning.color) }
            if let last = session.verification.lastSuccess { FactRow(title: "最近一次完整核验", value: last.formatted(date: .omitted, time: .standard)) }
            if let last = session.verification.lastVerifiedExit { FactRow(title: "最近一次出口核验", value: last.formatted(date: .omitted, time: .standard)) }
            if let result = session.exitCheck {
                Text(result.sessionTitle ?? "退出核对").font(.callout.weight(.semibold))
                Text(result.summary).font(.caption).foregroundStyle(result.hasOutstanding ? StatusTone.warning.color : .secondary)
                ForEach(result.notes, id: \.self) { Text($0).font(.caption.monospacedDigit()).textSelection(.enabled) }
            }
            if let observation = session.connectionObservation {
                Text("Claude 的连接 · " + observation.date.formatted(date: .omitted, time: .standard)).font(.callout.weight(.semibold))
                ForEach(observation.processes) { row in
                    FactRow(title: "\(row.role) · PID \(row.id)",
                            value: row.connections.map { "\($0) 条 · " + (row.interfaces.isEmpty ? "没看到网卡" : row.interfaces.sorted().joined(separator: " / ")) } ?? "没看到")
                }
            }
            if session.protectionMode != .usb, let report = session.networkReport {
                Text("线路检查明细 · " + report.date.formatted(date: .omitted, time: .standard)).font(.callout.weight(.semibold)).padding(.top, 4)
                if let failure = report.failure { Text(failure.explanation).font(.callout).foregroundStyle(StatusTone.failed.color) }
                ForEach(report.rows(hideAddresses: hideAddresses)) { row in checkRow(row) }
            }
            Text("这里是系统报告的路径。DNS 报文实际走哪条线、系统代 Claude 发的请求，软件里看不到。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func checkRow(_ row: NativeDiagnostics.Row) -> some View {
        let status: (String, StatusTone) = switch row.verdict {
        case .passed: ("通过", .positive)
        case .warning: ("提醒", .warning)
        case .failed: ("失败", .failed)
        case .unknown: ("没验证", .off)
        }
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.callout)
                Text(row.evidence).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            StatusTag(title: status.0, tone: status.1)
        }
        .accessibilityElement(children: .combine)
    }

    private func impact(_ status: ControlStatus) -> String {
        let items = [status.strictDNS ? "域名查询经 USB" : nil, status.quicFallback ? "QUIC 回落" : nil,
                     status.offloadDisabled ? "网卡分段卸载暂关" : nil].compactMap { $0 }
        return items.isEmpty ? "无" : items.joined(separator: "、")
    }

    private func exit(_ value: LineExit, hidden: Bool) -> String {
        (hidden ? "已隐藏" : value.address) + (value.country.map { " · " + (Locale(identifier: "zh_CN").localizedString(forRegionCode: $0) ?? $0) } ?? "")
    }

    private func volume(_ up: UInt64, _ down: UInt64) -> String { "上传 \(bytes(up)) · 下载 \(bytes(down))" }
    private func bytes(_ value: UInt64) -> String { value == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .decimal) }
}
