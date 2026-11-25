import Foundation
import GuardCore

/// 网络体检页给普通用户看的结论。只整理已有的检测结果；证明不了的写成“没法确认”，不当作通过。
struct HealthOverview: Equatable {
    struct Fact: Equatable, Identifiable {
        var id: String { label }
        let label: String
        let value: String
    }

    struct Tile: Equatable, Identifiable {
        var id: String { title }
        let icon: String
        let title: String
        let value: String
        let tone: StatusTone
        /// 出问题时 Guard 会做什么。
        let action: String
        /// 有内容时这一格可以点开。
        var details: [String] = []
    }

    /// “其他软件”只在有事时出现。
    static func others(_ shield: ControlStatus.Shield?, app: String, labels: [String: String]) -> Tile? {
        guard let shield else { return nil }
        let names = shield.programs.joined(separator: "、")
        let quiet = shield.verified && names.isEmpty && shield.blockedPackets == 0 && shield.uncovered.isEmpty
        if quiet { return nil }
        let value = !shield.verified ? "拦截还没验证" : !names.isEmpty ? "已拦下：\(names)"
            : shield.blockedPackets > 0 ? "已拦下 \(shield.blockedPackets) 个包" : "有 \(shield.uncovered.count) 个域名拦不到"
        var details = (shield.hits ?? []).sorted { $0.last > $1.last }.map { hit in
            let line = hit.interface.map { name in labels[name].map { "\($0)（\(name)）" } ?? (name.hasPrefix("utun") ? "VPN 或系统隧道（\(name)）" : name) } ?? "线路不明"
            let when = hit.first.formatted(date: .omitted, time: .standard) + (hit.last.timeIntervalSince(hit.first) >= 1 ? " 到 " + hit.last.formatted(date: .omitted, time: .standard) : "")
            return hit.program.map { "\($0)：想走 \(line)，已拦 · \(when)" } ?? "没认出是哪个软件：当时 Mac 默认线路是 \(line)，已拦 · \(when)"
        }
        details += shield.uncovered.map { "拦不到 \($0)（和其他网站共用地址）" }
        return Tile(icon: "square.stack.3d.up", title: "其他软件想连 \(app)", value: value, tone: .warning,
                    action: details.isEmpty ? "走别的线路连 \(app) 就拦" : "点开看是哪个软件、哪条线路", details: details)
    }

    var tone: StatusTone
    var headline: String
    var detail: String
    var facts: [Fact] = []
    var tiles: [Tile] = []
    var footnote: String?

    static let exitStale: TimeInterval = 60

    private static func region(_ code: String?) -> String {
        code.flatMap { Locale(identifier: "zh_CN").localizedString(forRegionCode: $0) } ?? "没查到"
    }

    private static func noun(_ count: Int) -> String { "有 \(count) 项要留意" }

    // MARK: USB 会话

    static func usb(app: String, status: ControlStatus?, locked: Bool, busy: String?, exit: LineExit?, proof: IsolationProof?,
                    proofAt: Date?, trafficAt: Date?, hideAddresses: Bool, now: Date, labels: [String: String] = [:]) -> Self {
        if locked || status?.state == .blocked {
            return Self(tone: .failed, headline: "\(app) 已断网",
                        detail: (status?.reason).map { IsolationModel.explain($0) + "。没有换到其他线路，确认后再恢复。" } ?? "没有换到其他线路，确认后再恢复。")
        }
        if let busy { return Self(tone: .neutral, headline: busy, detail: "检查通过后才会放行。") }
        guard let status, status.state == .armed else {
            return Self(tone: .warning, headline: "暂时读不到保护状态", detail: "防火墙规则不依赖这个窗口。持续读不到会结束会话。")
        }

        let checked = status.exitCheckedAt
        let stale = now.timeIntervalSince(checked ?? proofAt ?? now) > exitStale
        let udpFound = status.events.filter { $0.kind == "udp" && $0.date >= (proofAt ?? .distantPast) }.count
        let udpOnUSB = proof.map { !$0.quic && !$0.quicForced && !$0.udp.isEmpty && $0.udp == exit?.address } ?? false
        let udpBlocked = proof.map { !$0.quic && !$0.quicForced && $0.udp.isEmpty } ?? false

        var tiles = [
            Tile(icon: "cable.connector", title: "线路", value: "只走 USB", tone: .positive, action: "线断了就断网"),
            Tile(icon: "mappin.and.ellipse", title: "公网 IP",
                 value: stale ? "超过 1 分钟没读到" : checked == nil ? "等待第一次核对" : "和启动时一样",
                 tone: stale ? .warning : checked == nil ? .neutral : .positive, action: "变了就断网，读不到只提醒"),
            Tile(icon: "magnifyingglass", title: "网址查询（DNS）",
                 value: status.strictDNS ? "全部走 USB" : status.protectedDomains.isEmpty ? "转发器内走 USB" : "转发器和 \(app) 的域名走 USB",
                 tone: status.strictDNS ? .positive : .neutral, action: "只提醒"),
            Tile(icon: "video", title: "音视频通道（UDP）",
                 value: udpFound > 0 ? "发现并封住 \(udpFound) 次" : udpBlocked ? "已封住" : udpOnUSB ? "只走 USB" : "没法提前封",
                 tone: udpFound > 0 ? .warning : udpBlocked || udpOnUSB ? .positive : .neutral, action: "发现就封"),
            Tile(icon: "arrow.up.arrow.down", title: "\(app) 的流量",
                 value: trafficAt.map { now.timeIntervalSince($0) < 60 ? "刚才有数据往来" : "最近没有数据往来" } ?? "还没有数据往来",
                 tone: trafficAt.map { now.timeIntervalSince($0) < 60 } == true ? .positive : .neutral, action: "只显示")
        ]
        if status.shield == nil {
            tiles.append(Tile(icon: "square.stack.3d.up", title: "其他软件", value: "拦截没有启用", tone: .warning, action: "停止后重新启动"))
        } else if let tile = others(status.shield, app: app, labels: labels) { tiles.append(tile) }
        let warnings = tiles.filter { $0.tone == .warning }.count
        return Self(tone: warnings == 0 ? .positive : .warning, headline: "\(app) 正在走 iPhone USB",
                    detail: warnings == 0 ? "没有发现异常" : noun(warnings),
                    facts: [Fact(label: "公网 IP", value: exit.map { hideAddresses ? "已隐藏" : $0.address } ?? "没读到"),
                            Fact(label: "地区", value: region(exit?.country)),
                            Fact(label: "最近核对", value: checked?.formatted(date: .omitted, time: .standard) ?? "等待核对")],
                    tiles: tiles)
    }

    // MARK: 启动前的 USB 检查

    static func usbCheck(app: String, check: LineCheck?, approved: Bool, hideAddresses: Bool, now: Date) -> Self {
        guard let check, check.mode == .usb else {
            return Self(tone: .off, headline: "还没检查 USB", detail: "不用打开 \(app)，也不用关 Wi‑Fi。检查只从 USB 发出，不连 \(app)。")
        }
        let facts = [Fact(label: "USB 公网 IP", value: check.address.map { hideAddresses ? "已隐藏" : $0 } ?? "没读到"), Fact(label: "地区", value: region(check.country)),
                     Fact(label: "检查时间", value: check.date.formatted(date: .omitted, time: .standard))]
        if let problem = check.problem { return Self(tone: .failed, headline: "USB 没有通过检查", detail: problem, facts: facts) }
        if now.timeIntervalSince(check.date) >= LineCheck.lifetime {
            return Self(tone: .off, headline: "USB 的检查结果过期了", detail: "请重新检查。", facts: facts)
        }
        return Self(tone: approved ? .positive : .warning, headline: approved ? "USB 可以用" : "USB 检查通过，还没认可",
                    detail: approved ? "你认可过这个 IP，可以启动。" : "去网站看过，再认可这个 IP。没认可不会放行。", facts: facts,
                    tiles: [Tile(icon: "cable.connector", title: "线路", value: "iPhone USB 已连接", tone: .positive, action: "启动后断了就断网"),
                            Tile(icon: "mappin.and.ellipse", title: "公网 IP", value: "几个来源一致", tone: .positive, action: "启动后变了就断网"),
                            Tile(icon: "hand.thumbsup", title: "你的认可", value: approved ? "已认可这个 IP" : "还没认可", tone: approved ? .positive : .warning, action: "没认可不放行")])
    }

    // MARK: 整机线路（VPN / 热点会话，或没有会话时的手动检查）

    static func line(app: String, mode: NativeProtectionMode?, report: NativeDiagnostics.Report?, freshness: ReportFreshness?,
                     warning: String?, shield: ControlStatus.Shield?, hideAddresses: Bool,
                     cut: String? = nil, problem: String? = nil, approved: Bool = false, ipv4Only: Bool = false, quits: Bool = false, checkOnly: Bool = false, probe: ServiceProbe? = nil, usbIdle: Bool = false, labels: [String: String] = [:]) -> Self {
        if let cut { return Self(tone: .failed, headline: "\(app) 已断网", detail: cut + " 没有换到其他线路，确认后再恢复。") }
        guard let report, let freshness else {
            return Self(tone: .off, headline: mode == nil ? "还没检查" : "正在检查", detail: "不用打开 \(app)。检查不会连 \(app)。")
        }
        let exits = report.exits
        let main = exits[.v4] ?? exits[.v6]
        let exitsAgree = !exits.isEmpty && !exits.values.contains(where: \.disagrees) && exits.count == report.routes.count
        let changed = report.change == .routeChanged || report.change == .exitChanged
        let names = Set(report.routes.values.map { $0.interface }).sorted().joined(separator: "、")
        let live = mode != nil

        var tiles = [
            Tile(icon: "point.topleft.down.to.point.bottomright.curvepath", title: "线路",
                 value: report.routes.isEmpty ? "没有可用网络" : report.stablePaths && !changed ? "稳定" : "检查时发生变化",
                 tone: report.routes.isEmpty || !report.stablePaths || report.change == .routeChanged ? .failed : .positive,
                 action: checkOnly ? "只检查" : live ? (quits ? "变了就退出 Claude" : "变了就断网") : "启动保护后才监控"),
            Tile(icon: "mappin.and.ellipse", title: "公网 IP",
                 value: exits.isEmpty ? "没读到" : exits.values.contains(where: \.disagrees) ? "几个来源说法不一" : report.change == .exitChanged ? "和启动时不一样"
                    : !exitsAgree ? "只读到一部分" : live ? "和启动时一样" : "几个来源一致",
                 tone: report.change == .exitChanged ? .failed : exitsAgree ? .positive : .warning,
                 action: checkOnly ? "只检查" : live ? (quits ? "变了就退出 Claude" : "变了就断网") : "启动保护后才监控"),
            Tile(icon: "magnifyingglass", title: "网址查询（DNS）",
                 value: report.resolverEvidence == .different ? "设置不一致" : report.resolverEvidence == .matching ? "设置一致，实际走哪条没法确认" : "没法确认",
                 tone: report.resolverEvidence == .different ? .warning : .neutral, action: "只提醒"),
            Tile(icon: "6.circle", title: "IPv6",
                 value: report.routes[.v6] == nil ? "没有使用" : report.routes[.v6]?.interface == report.routes[.v4]?.interface ? "和 IPv4 同一条线路" : "和 IPv4 不是同一条线路",
                 tone: report.routes[.v6] == nil || report.routes[.v6]?.interface == report.routes[.v4]?.interface ? .positive : .warning,
                 action: live && ipv4Only ? "\(app) 只放行 IPv4" : "只提醒"),
            checkOnly ? Tile(icon: "cloud", title: "\(app) 能不能用", value: probe?.text ?? "还没试", tone: probe?.tone ?? .neutral, action: "点下面的“试一下”才会连")
                : Tile(icon: "hand.thumbsup", title: "你的认可", value: approved ? "已认可这个 IP" : "还没认可", tone: approved ? .positive : .warning, action: "没认可不放行")
        ]
        if !report.serviceHosts.isEmpty {
            let bad = report.serviceHosts.filter { (report.services[$0]?.verdict ?? .failed) == .failed }.count
            tiles.append(Tile(icon: "cloud", title: "\(app) 服务", value: bad == 0 ? "能连上" + (report.latency.map { " · \($0) ms" } ?? "") : "有 \(bad) 个连不上",
                              tone: bad == 0 ? .positive : .warning, action: "只提醒"))
        }
        if live, let tile = others(shield, app: app, labels: labels) { tiles.append(tile) }

        var result = Self(tone: .positive, headline: live ? "\(app) 正在走 \(mode!.rawValue)" : "这条线路检查通过", detail: "没有发现异常",
                          facts: [Fact(label: "公网 IP", value: main.map { hideAddresses ? "已隐藏" : $0.address } ?? "没读到"),
                                  Fact(label: "地区", value: region(main?.country)),
                                  Fact(label: "网络运营商", value: report.owner?.name ?? report.owner?.asn ?? "没查到")], tiles: tiles)
        let warnings = tiles.filter { $0.tone == .warning || $0.tone == .failed }.count
        if let problem, !live {
            (result.tone, result.headline, result.detail) = (.failed, "现在不能用这条线路", problem)
        } else if freshness == .waiting {
            (result.tone, result.detail) = (.warning, "网络有变化，正在复查")
        } else if freshness == .expired {
            (result.tone, result.detail) = (.off, "这是 \(report.date.formatted(date: .omitted, time: .standard)) 的结果，已过期，请重新检查")
            if report.failure != nil { result.headline = live ? result.headline : "上次检查没有通过" } else if !live { result.headline = "上次检查通过" }
        } else if let failure = report.failure, !live || warning == nil {
            (result.tone, result.detail) = (.failed, failure.explanation)
            if !live { result.headline = "这条线路没有通过检查" }
        } else if let warning {
            (result.tone, result.detail) = (.warning, warning)
        } else if warnings > 0 {
            (result.tone, result.detail) = (.warning, noun(warnings))
        }
        if !live {
            result.footnote = "这是 Mac 当前线路（\(names.isEmpty ? "无" : names)）的结果，保护没有开启，不会自动监控和断网。"
                + (usbIdle ? "iPhone USB 也连着，但这台 Mac 默认没有走它。" : "")
                + (probe == nil ? "检查没有连 \(app)。" : "")
        }
        return result
    }
}

/// 推荐用户自测的第三方网站。Guard 只负责打开或复制，不读取结果，结果也不参与断网判断。
enum ThirdPartyCheck {
    static let name = "ip.net.coffee"
    static let url = URL(string: "https://ip.net.coffee/claude/")!

    /// 应用断网期间用普通浏览器看网站时：整台 Mac 的默认线路都得是 iPhone USB。
    static func wholeMacOnUSB(routes: [IPFamily: Route], usb: Set<String>) -> Bool {
        routes[.v4] != nil && routes.values.allSatisfy { usb.contains($0.interface) }
    }
}
