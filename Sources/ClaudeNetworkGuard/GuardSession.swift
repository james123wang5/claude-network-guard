import AppKit
import Foundation
import GuardCore

@MainActor
final class GuardSession: ObservableObject {
    struct Entry: Identifiable, Codable {
        let id: UUID
        let date: Date
        let message: String

        init(message: String, date: Date = Date(), id: UUID = UUID()) {
            self.id = id
            self.date = date
            self.message = message
        }
    }

    /// 还没有启动过时的标题，界面据此判断有没有“上次会话”。
    static let idleTitle = "等待开始会话"
    @Published private(set) var title = GuardSession.idleTitle
    @Published private(set) var detail = "确认线路后从这里启动 Claude。"
    @Published private(set) var active = false
    @Published private(set) var stopping = false
    @Published private(set) var entries: [Entry] = {
        let data = UserDefaults.standard.data(forKey: "nativeGuardHistory") ?? Data()
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }()
    @Published private(set) var networkReport: NativeDiagnostics.Report?
    @Published private(set) var checkingNetwork = false
    @Published private(set) var verification = VerificationProgress()
    @Published private(set) var pendingNetworkCheck = false
    @Published private(set) var exitCheck: AppProcessExitCheck.Result?
    @Published private(set) var connectionObservation: AppConnectionObservation?
    @Published private(set) var monitoringWarning: String?
    @Published private(set) var lastNetworkEvent: String?
    @Published private(set) var latencyHistory: [LatencyReading] = []
    @Published private(set) var modeEvidence: String?
    @Published private(set) var thirdPartyNote: String?
    @Published private(set) var thirdPartyUsed: String?
    @Published private(set) var openingThirdParty = false
    @Published private(set) var notificationStatus: String?
    @Published var protectionMode = NativeProtectionMode(rawValue:
        UserDefaults.standard.string(forKey: "nativeProtectionMode") ?? "") ?? .vpn {
        didSet {
            UserDefaults.standard.set(protectionMode.rawValue, forKey: "nativeProtectionMode")
            modeEvidence = nil
        }
    }

    struct LatencyReading: Identifiable {
        var id: Date { date }
        let date: Date
        let milliseconds: Int
    }

    private var monitoredRun: UUID?
    private var monitoredApp: NSRunningApplication?
    private var watchdog: SessionWatchdog?
    private var abnormalAt: ContinuousClock.Instant?
    private var processExitCheck = AppProcessExitCheck()
    private var networkEvents: NetworkEvents?
    private var eventRevision = UUID()
    private var settleUntil = Date.distantPast
    private var sleeping = false
    private var lastRecordedEvent: [NetworkEvent: Date] = [:]
    private let network = NativeNetworkMonitor()
    @Published private(set) var claude = ClaudeApp.Status.searching
    private var findingClaude = false
    var target: TargetProfile? { claude.profile }
    /// Claude 在保护外被打开（例如自动更新后重启）并被关掉的时间。
    @Published var closedOutsideAt: Date?
    private var lock: AppSessionLock?
    let isolation = IsolationModel()
    @Published private(set) var usbSession = false
    @Published private(set) var lineCut = false
    @Published private(set) var recovering = false
    @Published var proof: IsolationProof?
    @Published var proofAt: Date?
    @Published var usbExit: LineExit?
    @Published var otherExit: LineExit?
    /// 本次会话由内核按应用锁定线路（VPN / 热点模式），断线瞬间即无法联网。
    @Published private(set) var kernelLocked = false
    /// 启动前的检查、用户认可过的 IP、在哪个 IP 上打开过检测网站。
    @Published private(set) var lineCheck: LineCheck?
    @Published private(set) var approved = ApprovedLine.load()
    @Published private(set) var siteOpenedFor: String?
    @Published private(set) var probe: ServiceProbe?
    @Published private(set) var probing = false
    /// 正在 USB 里临时打开检测网站，还没有启动 Claude。
    @Published private(set) var siteTesting = false
    @Published private(set) var releasing = false
    /// USB 会话里 Claude 启动时用的转发端口，恢复时要沿用。
    var usbRelayPort: UInt16?
    private var pinContext: (baseline: NativeNetworkMonitor.Baseline, evidence: NativeProtectionPolicy.Evidence)?
    /// Guard 自己不去连 Claude：IP 没认可或刚变了的时候，一次探测就会把它交给对方。
    private var diagnostics: NativeDiagnostics { NativeDiagnostics(hosts: [], skippedHosts: ClaudeApp.hosts) }

    /// 找到并核对 Claude Desktop。会话进行中不重查，以启动时核对过的为准。
    func refreshClaude() {
        guard !active, !findingClaude else { return }
        guard let url = ClaudeApp.locate() else { claude = .missing; return }
        findingClaude = true
        Task {
            let found = await Task.detached(priority: .userInitiated) { ClaudeApp.inspect(url) }.value
            findingClaude = false
            if !active, claude != found { claude = found }
        }
    }

    var monitoringNative: Bool { monitoredRun != nil }

    @Published var requiredRegion: String = UserDefaults.standard.string(forKey: "requiredExitRegion") ?? "" {
        didSet {
            UserDefaults.standard.set(requiredRegion, forKey: "requiredExitRegion")
            networkReport = nil
            verification = VerificationProgress()
            latencyHistory = []
        }
    }

    private var selectedRegion: String? { requiredRegion.isEmpty ? nil : requiredRegion }

    func allowNotifications() {
        Task {
            notificationStatus = await GuardNotifications.shared.request() ? "通知已启用"
                : "通知未授权。可在系统设置中开启 Guard 的通知。"
        }
    }

    func importWatchdogEvents() {
        let known = Set(entries.map(\.id))
        let recovered = SessionWatchdog.eventHistory().compactMap { item -> Entry? in
            guard let id = UUID(uuidString: item.id), !known.contains(id) else { return nil }
            return Entry(message: item.message, date: item.date, id: id)
        }
        guard !recovered.isEmpty else { return }
        entries = Array((entries + recovered).sorted { $0.date > $1.date }.prefix(120))
        persistEntries()
    }

    func inspectNativeNetwork() {
        guard !active || lineCut, !recovering, !checkingNetwork else { return }
        checkingNetwork = true
        Task {
            // 只有确认当前就是所选线路，才去访问 Claude 的服务；否则一次检测就会把 Wi‑Fi 的地址交给对方。
            let mode = protectionMode
            if mode == .usb {
                await isolation.refresh()
                lineCheck = await LineCheck.usb(lines: isolation.lines.map(\.interface), region: selectedRegion)
            } else {
                let report = await network.report(using: diagnostics, enrich: true, requiredRegion: selectedRegion)
                _ = publish(report)
                var check = LineCheck(mode: mode, date: report.date, address: report.exits[.v4]?.address, country: report.exits[.v4]?.country,
                                      problem: report.failure?.explanation)
                if mode != .current {
                    do { _ = try await NativeProtectionPolicy.inspect(mode) }
                    catch { check.problem = (error as? NativeProtectionPolicy.RequirementError)?.reason ?? "没法确认当前是所选线路。" }
                }
                lineCheck = check
            }
            recordEntry("检查\(mode.rawValue) · " + (lineCheck?.problem ?? "通过"))
            checkingNetwork = false
        }
    }

    // MARK: 认可 IP

    func isApproved(_ mode: NativeProtectionMode, _ address: String?) -> Bool {
        guard let address else { return false }
        return approved.contains { $0.covers(mode, address, now: Date()) }
    }

    /// 当前可以认可的 IP：检查通过，并且在这个 IP 上打开过检测网站。
    var approvable: String? {
        guard protectionMode != .current, let check = lineCheck, check.usable(for: protectionMode, now: Date()), let address = check.address,
              siteOpenedFor == address else { return nil }
        return address
    }

    func approveLine() {
        guard let address = approvable else { return }
        approved = approved.filter { $0.mode != protectionMode.rawValue } + [ApprovedLine(mode: protectionMode.rawValue, address: address, date: Date())]
        ApprovedLine.save(approved)
        recordEntry("已认可\(protectionMode.rawValue)的 IP")
    }

    func revokeLine() {
        guard !active || siteTesting else { return }
        approved.removeAll { $0.mode == protectionMode.rawValue }
        ApprovedLine.save(approved)
        recordEntry("已取消认可\(protectionMode.rawValue)的 IP")
    }

    func setSiteTesting(_ value: Bool) { siteTesting = value }
    func siteOpened(_ address: String?, line: String) {
        siteOpenedFor = address
        noteThirdParty("已打开检测网站。看完觉得可以，再点“认可这个 IP”。", line: line, verb: "打开")
    }
    func siteProblem(_ text: String) { thirdPartyNote = text }

    /// 访问 Claude 或检测网站之前再核对一次：还是所选线路，公网 IP 也还是刚才检查的那个。
    private func confirmLine(_ check: LineCheck) async -> (interface: String?, problem: String?) {
        do {
            let interface: String?
            switch check.mode {
            case .usb:
                await isolation.refresh()
                guard isolation.lines.count == 1 else { return (nil, "USB 已断开，请重新检查。") }
                interface = isolation.lines[0].interface
            case .current: interface = nil
            case .vpn, .hotspot: interface = try await NativeProtectionPolicy.inspect(check.mode).interface
            }
            guard await LineExit.read(interface: interface)?.address == check.address else { return (nil, "公网 IP 和刚才检查的不一样了，请重新检查。") }
            return (interface, nil)
        } catch { return (nil, (error as? NativeProtectionPolicy.RequirementError)?.reason ?? "没法确认当前是所选线路。") }
    }

    func probeService() {
        guard !probing, !active, !releasing, let check = lineCheck, check.usable(for: protectionMode, now: Date()), let address = check.address else { return }
        probing = true
        Task {
            let line = await confirmLine(check)
            if let problem = line.problem { thirdPartyNote = "没有连 Claude：" + problem }
            else {
                let result = await ServiceProbe.run(interface: line.interface, expected: address)
                probe = result
                recordEntry("试连 Claude · \(check.mode.rawValue) · " + result.text)
            }
            probing = false
        }
    }

    func openSite() {
        guard !openingThirdParty, !siteTesting, !recovering else { return }
        if usbSession, !lineCut {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ThirdPartyCheck.url.absoluteString, forType: .string)
            noteThirdParty("已复制。请粘贴到 Claude 的内置浏览器，不要用 Safari 或 Chrome。", line: "iPhone USB", verb: "复制")
            return
        }
        if protectionMode == .usb, !active { startUSBSiteTest(); return }
        let check: LineCheck
        if active, !lineCut {
            // 会话进行中只是再看一眼，守护进程已经在核对 IP。
            check = LineCheck(mode: protectionMode, date: Date(), address: networkReport?.exits[.v4]?.address)
        } else if let current = lineCheck, current.usable(for: protectionMode, now: Date()) { check = current }
        else { thirdPartyNote = "请先点“检查线路”，通过后再打开网站。"; return }
        openingThirdParty = true
        let cut = lineCut
        Task {
            defer { openingThirdParty = false }
            if check.mode == .usb {
                // 应用断网期间用普通浏览器看，所以整台 Mac 都得走 USB。
                let usb = Set(isolation.lines.map(\.interface))
                let whole = await Task.detached { ThirdPartyCheck.wholeMacOnUSB(routes: NetworkCheck.systemRoutes(), usb: usb) && !NativeProtectionPolicy.hasSystemProxy() }.value
                guard whole else { thirdPartyNote = "没有打开：请先关掉 Wi‑Fi，让整台 Mac 走 USB；看完认可后再打开 Wi‑Fi，然后恢复。"; return }
            }
            let line = await confirmLine(check)
            if let problem = line.problem { thirdPartyNote = "没有打开：" + problem; return }
            if cut {
                guard let interface = line.interface, lineCut,
                      (try? await IsolationModel.command(.init(.permit, interface: interface))) != nil else {
                    thirdPartyNote = "没有打开：没能为这条线路放开检测网站。"
                    return
                }
            }
            if NSWorkspace.shared.open(ThirdPartyCheck.url) { siteOpened(check.address, line: check.mode.rawValue) }
            else { thirdPartyNote = "没能打开浏览器。" }
        }
    }

    private func noteThirdParty(_ note: String, line: String, verb: String) {
        thirdPartyNote = note
        thirdPartyUsed = "\(verb)于 \(Date().formatted(date: .omitted, time: .standard)) · 线路 \(line)"
        recordEntry("\(verb)第三方检测 \(ThirdPartyCheck.name) · 线路 \(line)")
    }

    @discardableResult
    private func publish(_ report: NativeDiagnostics.Report) -> Bool {
        let expired = verification.record(report, now: .now)
        networkReport = report
        pendingNetworkCheck = false
        let oldest = report.date.addingTimeInterval(-60)
        latencyHistory.removeAll { $0.date < oldest }
        if let milliseconds = report.latency {
            latencyHistory.append(LatencyReading(date: report.date, milliseconds: milliseconds))
        }
        return expired
    }

    func startNative() {
        guard protectionMode != .current else { return }
        if protectionMode == .usb { startUSB(); return }
        guard !active, !releasing, !checkingNetwork, let selection = target else { return }
        guard !isolation.installed || isolation.current else {
            setState("隔离组件需要更新", "请先在「设置」里更新组件，否则断网不可靠。")
            return
        }
        guard let acquired = AppSessionLock() else {
            setState("已有受保护会话", "请先结束本项目的另一场会话。")
            return
        }
        let bundleID = selection.identity.bundleID
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
            setState("Claude 已在运行", "请先按 ⌘Q 退出 Claude，再从 Guard 启动。")
            return
        }

        lock = acquired
        let run = UUID()
        let mode = protectionMode
        modeEvidence = nil
        abnormalAt = nil
        kernelLocked = false
        monitoredRun = run
        active = true
        verification = VerificationProgress()
        pendingNetworkCheck = false
        exitCheck = nil
        processExitCheck = AppProcessExitCheck()
        monitoringWarning = nil
        lastNetworkEvent = nil
        sleeping = false
        settleUntil = .distantPast
        lastRecordedEvent = [:]
        networkEvents = NetworkEvents { [weak self] event in self?.networkChanged(event) }
        let startRevision = eventRevision
        setState("正在检查当前网络", "通过检查后，Guard 才会启动本次 Claude 会话。")
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) { try selection.checked() }.value
                latencyHistory = []
                let initialMode = try await NativeProtectionPolicy.inspect(mode)
                guard !stopping else {
                    finishNative("启动已取消", "没有打开 Claude。")
                    return
                }
                let report = await network.report(using: diagnostics, enrich: true, requiredRegion: selectedRegion)
                guard startRevision == eventRevision else {
                    var changed = report
                    changed.change = .routeChanged
                    publish(changed)
                    throw NativeNetworkMonitor.Failure.routeChanged
                }
                publish(report)
                if let failure = report.failure { throw failure }
                guard monitoredRun == run else { return }
                guard isApproved(mode, report.exits[.v4]?.address) else {
                    finishNative("这个 IP 还没认可", "没有打开 Claude。请在「首页」检查线路，去网站看过后点“认可这个 IP”。")
                    return
                }
                let baseline = NativeNetworkMonitor.Baseline(routes: report.routes, exits: report.exits, ipv4Only: isolation.ready)
                let serviceTargets = await NativeProtectionPolicy.serviceTargets(selection.serviceHosts)
                guard selection.serviceHosts.isEmpty || !serviceTargets.isEmpty else {
                    throw NativeProtectionPolicy.RequirementError(reason: "没有取得可复核的 Claude 服务地址。")
                }
                let evidence = try await NativeProtectionPolicy.inspect(mode, extraTargets: serviceTargets,
                    dnsTargets: NativeProtectionPolicy.defaultDNSTargets())
                guard await network.routes() == baseline.routes, startRevision == eventRevision,
                      evidence.matches(initialMode) else { throw NativeNetworkMonitor.Failure.routeChanged }
                modeEvidence = evidence.summary + " · DNS 服务器路由 \(evidence.dnsRoutes) 项"
                guard !stopping else {
                    finishNative("启动已取消", "没有打开 Claude。")
                    return
                }
                _ = try await Task.detached(priority: .userInitiated) { try selection.checked() }.value
                guard !stopping, startRevision == eventRevision else {
                    finishNative("启动已取消", "启动前会话或网络状态已变化。")
                    return
                }
                guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
                    finishNative("Claude 已在运行", "请先按 ⌘Q 退出 Claude，再从 Guard 启动。")
                    return
                }

                let requestedAt = Date()
                // 组件不可用（没装、版本不配套或暂时没响应）时不降级成只监测：拒绝启动。
                await isolation.refresh()
                guard isolation.ready else {
                    finishNative("隔离组件不可用", "没有打开 Claude。保护需要后台组件正常运行，请在「设置」里安装或更新组件后再试。")
                    return
                }
                kernelLocked = true
                try await lockPin(selection, interface: evidence.interface, address: report.exits[.v4]?.address)
                guard !stopping else {
                    _ = try? await IsolationModel.command(.init(.block))
                    finishNative("启动已取消", "没有打开 Claude。")
                    return
                }
                let app = try await Self.launchIsolated(selection, port: nil)
                guard let process = AppProcessExitCheck.Identity.read(app.processIdentifier),
                      app.bundleIdentifier == bundleID,
                      app.executableURL?.resolvingSymlinksInPath().path == selection.identity.executable,
                      process.startedAt >= requestedAt.addingTimeInterval(-1) else {
                    finishNative("无法确认会话归属", "保留现有进程。请退出 Claude 后重试。")
                    return
                }
                monitoredApp = app
                if stopping {
                    await stopNative(run, title: "会话已停止", detail: "已退出从 Guard 启动的 Claude。")
                } else if app.isTerminated {
                    await finishNativeWithProcessCheck("Claude 已退出", "本次网络监测已结束。")
                } else {
                    if kernelLocked {
                        // 线路和 IP 由后台守护进程与内核看守，界面退出也不影响，因此不用心跳。
                        setState("Claude 会话监测中", "正在监测\(mode.rawValue)。断线、换线或 IP 变化时立即断网，Claude 保持打开。")
                        await superviseLocked(run, baseline: baseline, evidence: evidence, requiredRegion: report.requiredRegion)
                        return
                    }
                    let keeper = await SessionWatchdog.start(pid: app.processIdentifier, executable: selection.identity.executable)
                    guard monitoredRun == run else { keeper?.close(); return }
                    watchdog = keeper
                    if stopping { return }
                    guard keeper != nil else {
                        await stopWithReason(run, reason: "独立守护进程未就绪。")
                        return
                    }
                    setState("Claude 会话监测中", "正在监测\(mode.rawValue)。没有隔离组件，发现异常后会退出 Claude。")
                    await watchNative(run, baseline: baseline, evidence: evidence, requiredRegion: report.requiredRegion)
                }
            } catch {
                guard monitoredRun == run else { return }
                if stopping {
                    finishNative("启动已取消", "没有打开 Claude。")
                } else {
                    if let locked = error as? PinFailure {
                        finishNative("锁线没有通过", locked.reason + "没有打开 Claude。")
                        return
                    }
                    let failure = error as? NativeNetworkMonitor.Failure
                    if case ControlClient.Failure.refused(let code)? = error as? ControlClient.Failure {
                        finishNative("内核锁定未生效", IsolationModel.explain(code) + "，没有启动 Claude。")
                        return
                    }
                    if let rejected = error as? NativeProtectionPolicy.RequirementError {
                        modeEvidence = rejected.reason
                        finishNative("所选线路检查未通过", rejected.reason)
                    } else {
                        finishNative(failure == nil ? "Claude 启动失败" : "网络检查未通过",
                                     failure?.explanation ?? error.localizedDescription)
                    }
                }
            }
        }
    }

    static func launchIsolated(_ target: TargetProfile, port: UInt16?, locked: Bool = false, extra: [String] = []) async throws -> NSRunningApplication {
        let pid = try await Task.detached { try IsolationModel.launch(target, port: port, locked: locked, extra: extra) }.value
        for _ in 0..<100 {
            if let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier == target.identity.bundleID {
                app.activate(options: [])
                return app
            }
            if kill(pid, 0) != 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        kill(pid, SIGKILL)
        throw NSError(domain: "Guard", code: 1, userInfo: [NSLocalizedDescriptionKey: "Claude 没有以受保护身份启动。"])
    }

    private func watchNative(_ run: UUID, baseline: NativeNetworkMonitor.Baseline,
                             evidence: NativeProtectionPolicy.Evidence, requiredRegion: String?) async {
        let healthTask = Task { await refreshReport(run, baseline: baseline, evidence: evidence, region: requiredRegion) }
        let heartbeat = Task { if !kernelLocked { await sendHeartbeat(run) } }
        let socketTask = Task { await refreshConnections(run) }
        defer {
            if !stopping { healthTask.cancel() }
            socketTask.cancel()
            heartbeat.cancel()
        }

        var silent = 0
        while monitoredRun == run && !stopping && !lineCut {
            if monitoredApp?.isTerminated == true {
                await finishNativeWithProcessCheck("Claude 已退出", "本次网络监测已结束。")
                return
            }
            if kernelLocked {
                if let status = isolation.status {
                    silent = 0
                    if status.state != .armed {
                        await cutLine(run, reason: IsolationModel.explain(status.reason ?? "状态异常") + "。")
                        return
                    }
                } else {
                    silent += 1
                    if silent >= 8 {
                        await stopNative(run, title: "隔离组件失联，已停止 Claude", detail: "无法确认保护状态。")
                        return
                    }
                }
            }
            if sleeping || Date() < settleUntil {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            let currentRoutes = await network.routes()
            guard monitoredRun == run && !stopping else { return }
            if sleeping || Date() < settleUntil { continue }
            if !baseline.sameRoutes(currentRoutes) {
                await stopWithReason(run, reason: "所选\(evidence.mode.rawValue)的公网路由已变化。", failure: .routeChanged)
                return
            }
            do {
                let current = try await NativeProtectionPolicy.inspect(evidence.mode)
                guard monitoredRun == run && !stopping && !sleeping && Date() >= settleUntil else { continue }
                if !current.matches(evidence) {
                    await stopWithReason(run, reason: "已离开启动时核对的\(evidence.mode.rawValue)。", failure: .routeChanged)
                    return
                }
            } catch {
                guard monitoredRun == run && !stopping && !sleeping && Date() >= settleUntil else { continue }
                let issue = (error as? NativeProtectionPolicy.RequirementError)?.reason ?? "无法核对所选线路。"
                await stopWithReason(run, reason: issue, failure: .routeChanged)
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func networkChanged(_ event: NetworkEvent) {
        guard monitoredRun != nil, !stopping else { return }
        let now = Date()
        eventRevision = UUID()
        pendingNetworkCheck = true
        if event == .sleep { sleeping = true }
        if event == .wake {
            sleeping = false
            settleUntil = now.addingTimeInterval(2)
        }
        lastNetworkEvent = event.rawValue
        if now.timeIntervalSince(lastRecordedEvent[event] ?? .distantPast) >= 3 {
            lastRecordedEvent[event] = now
            recordEntry(event.rawValue)
        }
    }

    private func refreshReport(_ run: UUID, baseline: NativeNetworkMonitor.Baseline,
                               evidence: NativeProtectionPolicy.Evidence, region: String?) async {
        let clock = ContinuousClock()
        var due = clock.now.advanced(by: .seconds(12))
        var checkedEvent = eventRevision
        var consecutiveUnreachable = 0
        while !Task.isCancelled && monitoredRun == run && !stopping && !lineCut {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard monitoredRun == run && !stopping else { return }
            guard !sleeping && Date() >= settleUntil, checkedEvent != eventRevision || clock.now >= due else { continue }
            let sampledEvent = eventRevision
            var report = await network.report(using: diagnostics, enrich: false, requiredRegion: region)
            guard !Task.isCancelled && monitoredRun == run && !stopping else { return }
            guard !sleeping else { continue }
            if sampledEvent != eventRevision {
                report.change = .sampleInterrupted
                if publish(report) {
                    await stopForNetworkFailure(run, .exitProofExpired)
                    return
                }
                pendingNetworkCheck = true
                updateWarning(NativeNetworkMonitor.Failure.sampleInterrupted.explanation)
                continue
            }
            let targets = await NativeProtectionPolicy.serviceTargets(diagnostics.hosts)
            guard !Task.isCancelled && monitoredRun == run && !stopping else { return }
            guard sampledEvent == eventRevision && !sleeping else { continue }
            do {
                let current = try await NativeProtectionPolicy.inspect(evidence.mode, extraTargets: targets,
                    dnsTargets: NativeProtectionPolicy.defaultDNSTargets())
                guard !Task.isCancelled && monitoredRun == run && !stopping else { return }
                guard sampledEvent == eventRevision && !sleeping else { continue }
                if !current.matches(evidence) {
                    await stopWithReason(run, reason: "已离开启动时核对的\(evidence.mode.rawValue)。", failure: .routeChanged)
                    return
                }
                modeEvidence = current.summary + " · DNS 服务器路由 \(current.dnsRoutes) 项"
            } catch {
                guard !Task.isCancelled && monitoredRun == run && !stopping else { return }
                guard sampledEvent == eventRevision && !sleeping else { continue }
                let issue = (error as? NativeProtectionPolicy.RequirementError)?.reason ?? "无法核对所选线路。"
                await stopWithReason(run, reason: issue, failure: .routeChanged)
                return
            }
            checkedEvent = sampledEvent
            due = clock.now.advanced(by: .seconds(12))
            for (family, exit) in report.exits where exit.country == nil && !exit.disagrees {
                if let original = baseline.exits[family], original.address == exit.address {
                    report.exits[family]?.country = original.country
                }
            }
            if report.failure == nil || report.failure == .dnsUnavailable || report.failure == .serviceUnavailable {
                report.change = baseline.change(routes: report.routes, exits: report.exits)
            }
            if baseline.change(routes: report.routes, exits: report.exits) == nil,
               !report.exits.values.contains(where: \.disagrees) {
                report.owner = networkReport?.owner
            }
            let expired = publish(report)
            if expired {
                await stopForNetworkFailure(run, .exitProofExpired)
                return
            }
            switch report.followUp {
            case .healthy:
                updateWarning(nil)
                consecutiveUnreachable = 0
            case .warn(let failure):
                let reason = failure == .unavailable && (report.independentReachable == true || !report.services.isEmpty)
                    ? "公网出口检测源未能给出完整结果，但其他 HTTPS 目标有响应。"
                    : failure.explanation
                updateWarning(reason + " Claude 会话继续，等待复查。")
                consecutiveUnreachable = 0
            case .reconsiderDisconnect:
                consecutiveUnreachable += 1
                if consecutiveUnreachable >= 2 {
                    await stopForNetworkFailure(run, .internetUnavailable)
                    return
                }
                updateWarning("多个站点未响应，正在确认是否断网。")
                due = clock.now.advanced(by: .seconds(2))
            case .stop(let failure):
                await stopForNetworkFailure(run, failure)
                return
            }
        }
    }

    private func updateWarning(_ warning: String?) {
        guard monitoringWarning != warning else { return }
        monitoringWarning = warning
        recordEntry(warning ?? "网络复查恢复正常。")
    }

    private func refreshConnections(_ run: UUID) async {
        while !Task.isCancelled, monitoredRun == run, !stopping, let app = monitoredApp, !app.isTerminated, let target {
            let observation = await AppConnectionObservation.sample(pid: app.processIdentifier,
                                                                        bundlePath: target.path)
            guard !Task.isCancelled && monitoredRun == run && !stopping else { return }
            connectionObservation = observation
            if let observation {
                processExitCheck.remember(observation.identities, unavailable: observation.unidentified)
            }
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
        }
    }

    func sendHeartbeat(_ run: UUID) async {
        while !Task.isCancelled && monitoredRun == run {
            if watchdog?.beat() != true && !stopping {
                if monitoredApp?.isTerminated == true { return }
                await stopWithReason(run, reason: "独立守护进程失去响应。")
                return
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    private func stopForNetworkFailure(_ run: UUID, _ failure: NativeNetworkMonitor.Failure) async {
        await stopWithReason(run, reason: failure.explanation, failure: failure)
    }

    private func stopWithReason(_ run: UUID, reason: String, failure: NativeNetworkMonitor.Failure? = nil) async {
        guard monitoredRun == run && !stopping else { return }
        if kernelLocked {
            await cutLine(run, reason: reason)
            return
        }
        abnormalAt = .now
        if let failure, var report = networkReport {
            report.change = failure
            networkReport = report
        }
        modeEvidence = reason
        await stopNative(run, title: "监测异常，已停止 Claude", detail: reason + " 请重新检查后再启动。")
    }

    // MARK: VPN / 热点：断网不退出

    private struct PinFailure: Error { let reason: String }

    /// 锁线、确认锁住的就是认可的 IP、确认拦截生效。任一项不成立就先断网再报错。
    private func lockPin(_ selection: TargetProfile, interface: String, address: String?) async throws {
        guard let address, isApproved(protectionMode, address) else { throw PinFailure(reason: "这个 IP 还没认可。") }
        guard let allowed = isolation.allowed else { throw PinFailure(reason: "允许的内网地址写得不对，请在「设置」里修改。") }
        _ = try await IsolationModel.command(.init(.arm, mode: .pin, interface: interface, domains: selection.serviceHosts,
                                                   confined: selection.canConfine, expectedExit: address, allowed: allowed.map(\.text), hold: true))
        guard await LineExit.read(interface: interface)?.address == address else {
            _ = try? await IsolationModel.command(.init(.block))
            throw PinFailure(reason: "锁线后读到的公网 IP 和认可的不一样。")
        }
        await isolation.refresh()
        for _ in 0..<12 where !selection.serviceHosts.isEmpty && isolation.status?.shield?.verified != true {
            try? await Task.sleep(for: .milliseconds(500))
            await isolation.refresh()
        }
        guard isolation.status?.state == .armed, selection.serviceHosts.isEmpty || isolation.status?.shield?.verified == true else {
            _ = try? await IsolationModel.command(.init(.block))
            throw PinFailure(reason: "没能确认拦截已经生效。")
        }
        // 全部检查通过：恢复时被暂停的 Claude 现在才继续运行。
        do { _ = try await IsolationModel.command(.init(.resume)) } catch {
            _ = try? await IsolationModel.command(.init(.block))
            throw PinFailure(reason: "没能让 Claude 继续运行，已保持断网。")
        }
    }

    private func superviseLocked(_ run: UUID, baseline: NativeNetworkMonitor.Baseline,
                                 evidence: NativeProtectionPolicy.Evidence, requiredRegion: String?) async {
        pinContext = (baseline, evidence)
        while monitoredRun == run, !stopping, let context = pinContext {
            await watchNative(run, baseline: context.baseline, evidence: context.evidence, requiredRegion: requiredRegion)
            while monitoredRun == run, !stopping, lineCut {
                if monitoredApp?.isTerminated == true {
                    await finishNativeWithProcessCheck("Claude 已退出", "本次会话已结束。")
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func cutLine(_ run: UUID, reason: String) async {
        guard monitoredRun == run, !stopping, !lineCut else { return }
        lineCut = true
        pendingNetworkCheck = false
        modeEvidence = reason
        // 由守护进程在内核里断网；万一断不了，就退回到退出应用。
        let blocked = try? await IsolationModel.command(.init(.block))
        guard monitoredRun == run, !stopping else { return }
        guard blocked?.state == .blocked else {
            lineCut = false
            await stopNative(run, title: "没能断网，已停止 Claude", detail: reason)
            return
        }
        await isolation.refresh()
        setState("Claude 已断网", reason + " Claude 保持打开但无法联网，不会换到其他线路。")
        GuardNotifications.shared.report(title: "\(protectionMode.rawValue)异常，Claude 已断网", detail: reason + " 没有切换到其他线路。")
    }

    func recoverLine() {
        if usbSession { recoverUSB(); return }
        guard kernelLocked, lineCut, !recovering, !stopping, let run = monitoredRun, let selection = target else { return }
        let mode = protectionMode
        recovering = true
        Task {
            do {
                let first = try await NativeProtectionPolicy.inspect(mode)
                var report = await network.report(using: diagnostics, enrich: false, requiredRegion: selectedRegion)
                guard monitoredRun == run, !stopping else { return }
                // IP 没变时沿用之前查到的运营商。
                if report.exits[.v4]?.address == networkReport?.exits[.v4]?.address { report.owner = networkReport?.owner }
                publish(report)
                if let failure = report.failure { throw PinFailure(reason: failure.explanation) }
                guard isApproved(mode, report.exits[.v4]?.address) else {
                    throw PinFailure(reason: "现在的公网 IP 没有认可过。请先在「首页」检查线路、看网站、认可，再恢复。")
                }
                let evidence = try await NativeProtectionPolicy.inspect(mode, dnsTargets: NativeProtectionPolicy.defaultDNSTargets())
                guard evidence.matches(first), await network.routes() == report.routes else { throw PinFailure(reason: "检查期间线路又变了。") }
                guard monitoredRun == run, !stopping else { return }
                try await lockPin(selection, interface: evidence.interface, address: report.exits[.v4]?.address)
                guard monitoredRun == run, !stopping else {
                    _ = try? await IsolationModel.command(.init(.block))
                    return
                }
                pinContext = (NativeNetworkMonitor.Baseline(routes: report.routes, exits: report.exits, ipv4Only: true), evidence)
                recovering = false
                lineCut = false
                setState("线路已恢复", "重新检查已通过，Claude 可以继续联网。")
            } catch {
                guard monitoredRun == run else { return }
                recovering = false
                let reason = (error as? PinFailure)?.reason ?? (error as? NativeProtectionPolicy.RequirementError)?.reason ?? error.localizedDescription
                if !stopping { setState("Claude 仍然断网", reason + " Claude 没有换到其他线路。") }
            }
        }
    }

    func stopNative(_ run: UUID, title: String, detail: String) async {
        guard monitoredRun == run, let app = monitoredApp else { return }
        stopping = true
        setState("正在停止 Claude", detail)
        if !app.isTerminated {
            processExitCheck.captureChildren(of: app.processIdentifier)
            app.terminate()
            // 内核已锁定线路时不存在泄漏风险，多给应用一些保存时间。
            for _ in 0..<(kernelLocked || usbSession ? 80 : 12) where !app.isTerminated { try? await Task.sleep(for: .milliseconds(100)) }
        }
        if !app.isTerminated {
            app.forceTerminate()
            for _ in 0..<12 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(100)) }
        }
        if app.isTerminated {
            await finishNativeWithProcessCheck(title, detail)
        } else {
            stopping = false
            setState("Claude 尚未退出", "请立即按 ⌘Q 退出 Claude，或再点一次「停止并退出 Claude」。")
            if abnormalAt != nil {
                GuardNotifications.shared.report(title: "未确认 Claude 退出",
                    detail: detail + " 请立即退出 Claude。辅助进程尚未复核。")
            }
            Task {
                while monitoredRun == run && !stopping && !app.isTerminated {
                    try? await Task.sleep(for: .seconds(1))
                }
                if monitoredRun == run && !stopping && app.isTerminated {
                    await finishNativeWithProcessCheck(title, detail)
                }
            }
        }
    }

    func finishNativeWithProcessCheck(_ title: String, _ detail: String) async {
        stopping = true
        let mainExitedAt = ContinuousClock.now
        var result = processExitCheck.status()
        for _ in 0..<8 {
            if result.remaining.isEmpty && result.unconfirmed.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(150))
            result = processExitCheck.status()
        }
        exitCheck = result
        var notes = ([detail, result.summary] + result.notes).joined(separator: " ")
        if let detected = abnormalAt {
            let duration = detected.duration(to: mainExitedAt).components
            let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            notes += " 从检测到异常至确认主程序退出约 " + String(format: "%.1f", seconds) + " 秒。"
            GuardNotifications.shared.report(title: result.sessionTitle ?? title, detail: notes)
        }
        finishNative(result.sessionTitle ?? title, notes)
    }

    private func finishNative(_ title: String, _ detail: String) {
        watchdog?.close()
        watchdog = nil
        lock = nil
        abnormalAt = nil
        if kernelLocked || usbSession {
            // 结束遗留在隔离组里的子进程并撤销全部规则，恢复普通模式。
            // 没清理完之前不允许再启动，否则新会话会被这次清理一起撤销。
            releasing = true
            Task {
                var problem: String?
                do { _ = try await IsolationModel.command(.init(.terminate)) } catch { problem = Self.describe(error).trimmingCharacters(in: CharacterSet(charactersIn: "。")) }
                await isolation.refresh()
                if problem == nil, let state = isolation.status?.state, state != .idle { problem = "规则仍然存在" }
                releasing = false
                // 清理没完成要如实告诉用户，不能显示成已恢复普通模式。
                if let problem {
                    setState("保护规则没有撤销干净", "\(problem)。Claude 可能仍处于断网状态。请再点一次停止，或在「设置」里更新组件；仍不行就重启电脑。", includeDetailInLog: true)
                    GuardNotifications.shared.report(title: "保护规则没有撤销干净", detail: problem)
                }
            }
        }
        kernelLocked = false
        usbSession = false
        siteTesting = false
        pinContext = nil
        lineCut = false
        recovering = false
        monitoredApp = nil
        monitoredRun = nil
        connectionObservation = nil
        networkEvents = nil
        pendingNetworkCheck = false
        monitoringWarning = nil
        active = false
        stopping = false
        setState(title, detail, includeDetailInLog: true)
    }

    func stop() {
        guard active, !stopping else { return }
        stopping = true
        if let run = monitoredRun {
            if monitoredApp != nil {
                Task { await stopNative(run, title: "会话已停止", detail: "已退出从 Guard 启动的 Claude。") }
            } else {
                setState("正在取消启动", "正在结束本次启动流程。")
            }
            return
        }
    }

    func setState(_ title: String, _ detail: String, includeDetailInLog: Bool = false) {
        self.title = title
        self.detail = detail
        recordEntry(includeDetailInLog ? title + " · " + detail : title)
    }

    // MARK: USB 会话状态

    var currentRun: UUID? { monitoredRun }
    var runningApp: NSRunningApplication? { monitoredApp }
    func usbRun(_ run: UUID) -> Bool { usbSession && monitoredRun == run }

    func beginUSB(_ acquired: AppSessionLock) -> UUID {
        let run = UUID()
        lock = acquired
        monitoredRun = run
        active = true
        usbSession = true
        lineCut = false
        recovering = false
        proof = nil
        exitCheck = nil
        modeEvidence = nil
        abnormalAt = nil
        kernelLocked = false
        processExitCheck = AppProcessExitCheck()
        networkEvents = NetworkEvents { [weak self] event in self?.networkChanged(event) }
        setState("正在准备 USB 专线", "检查组件和线路。")
        return run
    }

    func adopt(_ app: NSRunningApplication, run: UUID) {
        // 保护由守护进程和内核执行，界面退出不影响它，因此 USB 会话不使用心跳守护。
        monitoredApp = app
        Task { await refreshConnections(run) }
    }

    /// Guard 界面重开过，后台还留着上一场会话（Claude 仍被锁住）：界面接不回它，只能如实显示并让用户结束。
    var orphaned: Bool { !active && !releasing && (isolation.status.map { $0.state != .idle } ?? false) }

    func stopOrphan() {
        guard orphaned else { return }
        releasing = true
        setState("正在结束后台保护", "正在退出受保护的 Claude 并撤销规则。")
        Task {
            var problem: String?
            do { _ = try await IsolationModel.command(.init(.terminate)) } catch { problem = Self.describe(error).trimmingCharacters(in: CharacterSet(charactersIn: "。")) }
            await isolation.refresh()
            if problem == nil, let state = isolation.status?.state, state != .idle { problem = "规则仍然存在" }
            releasing = false
            if let problem {
                setState("保护规则没有撤销干净", "\(problem)。请再试一次，或在「设置」里更新组件；仍不行就重启电脑。", includeDetailInLog: true)
            } else {
                setState("已结束后台保护", "已退出受保护的 Claude，恢复普通模式。")
            }
        }
    }

    func lockUSB() { lineCut = true }
    func beginRecovery() { recovering = true }
    func endRecovery(locked: Bool) { recovering = false; lineCut = locked }
    func finishUSB(_ title: String, _ detail: String) { finishNative(title, detail) }

    func recordEntry(_ message: String) {
        entries.insert(Entry(message: message), at: 0)
        if entries.count > 120 { entries.removeLast(entries.count - 120) }
        persistEntries()
    }

    private func persistEntries() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: "nativeGuardHistory")
        }
    }

    #if DEBUG
    /// 只给界面截图用：摆出某种状态，不碰网络和组件。
    func preview(claude: ClaudeApp.Status? = nil, mode: NativeProtectionMode? = nil, check: LineCheck? = nil, seen: Bool = false, approved isApproved: Bool = false,
                 running app: NSRunningApplication? = nil, usb: Bool = false, cut: Bool = false, title: String? = nil, detail: String? = nil,
                 proof: IsolationProof? = nil, exit: LineExit? = nil) {
        if let claude { self.claude = claude }
        if let mode { protectionMode = mode }
        lineCheck = check
        siteOpenedFor = seen ? check?.address : nil
        approved = isApproved ? [ApprovedLine(mode: protectionMode.rawValue, address: check?.address ?? "", date: Date())] : []
        monitoredApp = app
        active = app != nil
        usbSession = usb
        lineCut = cut
        if let title { self.title = title }
        if let detail { self.detail = detail }
        self.proof = proof
        proofAt = proof == nil ? nil : Date()
        usbExit = exit
        otherExit = exit == nil ? nil : LineExit(address: "203.0.113.8", country: "SG")
    }
    #endif
}
