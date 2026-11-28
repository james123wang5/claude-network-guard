import AppKit
import Foundation
import GuardCore

private struct USBFailure: Error { let title: String; let detail: String }

/// USB 专线会话：检查 → 内核规则生效 → 组内自检 → 启动 → 监视。
/// 断线后应用保留运行但被内核锁在本机，由用户决定恢复或停止，绝不自动换线。
extension GuardSession {
    func startUSB() {
        guard !active, !releasing, !checkingNetwork, let selection = target else { return }
        guard let acquired = AppSessionLock() else {
            setState("已有受保护会话", "请先结束另一场会话。")
            return
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: selection.identity.bundleID).isEmpty else {
            setState("Claude 已在运行", "请先按 ⌘Q 退出 Claude，再从 Guard 启动。")
            return
        }
        let run = beginUSB(acquired)
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) { try selection.checked() }.value
                let port = try await establish(selection)
                usbRelayPort = port
                guard usbRun(run), !stopping else { throw USBFailure(title: "启动已取消", detail: "没有打开 Claude。") }
                let app = try await Self.launchIsolated(selection, port: port, locked: isolation.lockdown)
                adopt(app, run: run)
                // 打开 Claude 的这段时间里用户点了取消：按停止会话处理，结束它并撤销规则。
                guard usbRun(run), !stopping else {
                    await stopNative(run, title: "启动已取消", detail: "已退出刚打开的 Claude，恢复普通模式。")
                    return
                }
                setState("USB 专线会话进行中", "\(selection.displayName) 只经 \(isolation.status?.interface ?? "USB") 联网，其他应用使用原来的网络。")
                await watchUSB(run)
            } catch {
                guard usbRun(run) else { return }
                let failure = error as? USBFailure ?? USBFailure(title: "USB 专线未启动", detail: Self.describe(error))
                finishUSB(failure.title, failure.detail)
            }
        }
    }

    /// 检查线路并让规则生效，返回转发端口。任一项不通过即抛出。
    private func establish(_ selection: TargetProfile, requireApproval: Bool = true) async throws -> UInt16 {
        await isolation.refresh()
        guard isolation.ready else { throw USBFailure(title: "隔离组件未就绪", detail: "请先在「设置」里安装或更新组件。") }
        if isolation.lockdown, !selection.canConfine {
            throw USBFailure(title: "它不支持锁死模式", detail: "它自带 App Sandbox，请在「设置」里关闭锁死模式。")
        }
        guard isolation.lines.count == 1, let line = isolation.lines.first else {
            throw USBFailure(title: "没有可用的 iPhone USB", detail: isolation.lines.isEmpty
                ? "请连接数据线、解锁手机并打开个人热点。" : "同时识别到多台 iPhone，请只保留一台。")
        }
        guard let path = NetworkCheck.route(to: "1.1.1.1")?.interface, path != line.interface else {
            throw USBFailure(title: "缺少独立的 Mac 网络", detail: "Mac 当前没有 USB 以外的网络，无法验证隔离。请保持 Wi‑Fi 或 VPN 连接。")
        }
        guard let allowed = isolation.allowed else { throw USBFailure(title: "允许的内网地址写得不对", detail: "请在「设置」里改成 10.1.2.3:22 这样的格式，或清空。") }
        setState("正在检查两条线路", "分别测量 USB 与 Mac 原线路的公网出口。")
        async let first = LineExit.read(interface: line.interface)
        async let second = LineExit.read(interface: nil)
        let (usb, other) = await (first, second)
        usbExit = usb
        otherExit = other
        guard let usb else { throw USBFailure(title: "USB 没有联网", detail: "\(line.interface) 已连接，但无法访问外网。请检查手机信号和流量。") }
        guard let other else { throw USBFailure(title: "原线路没有联网", detail: "需要另一条可用线路作对照，才能证明隔离有效。") }
        guard usb.address != other.address else {
            throw USBFailure(title: "两条线路出口相同", detail: "无法区分 USB 与原线路。若 Wi‑Fi 连的是同一台手机的热点，请换一个 Wi‑Fi。")
        }
        if !requiredRegion.isEmpty, usb.country != requiredRegion {
            throw USBFailure(title: "USB 出口地区不符", detail: "当前为 \(usb.country ?? "未知")，设定为 \(requiredRegion)。")
        }
        if requireApproval, !isApproved(.usb, usb.address) {
            throw USBFailure(title: "这个 IP 还没认可", detail: lineCut || recovering
                ? "现在的 USB 公网 IP 没有认可过。请先在「首页」检查线路、看网站、认可，再恢复。"
                : "请在「首页」检查线路，去网站看过后点“认可这个 IP”。")
        }
        let status = try await IsolationModel.command(.init(.arm, mode: .usb, interface: line.interface,
                                                            domains: selection.serviceHosts, strictDNS: isolation.strictDNS && !isolation.lockdown, confined: selection.canConfine, expectedExit: usb.address, allowed: requireApproval ? allowed.map(\.text) : [], hold: true,
                                                            relayPort: lineCut || recovering ? usbRelayPort : nil))
        guard let port = status.relayPort else {
            _ = try? await IsolationModel.command(.init(.block))
            throw USBFailure(title: "USB 转发器未就绪", detail: "请重试。")
        }
        setState("正在做隔离自检", "以受保护身份主动尝试其他线路，全部失败才会启动 Claude。")
        // 规则刚生效或刚恢复时网络可能短暂抖动，最多重试一次。
        var evidence = await IsolationModel.prove(usb: line.interface, other: path, port: port, confined: selection.canConfine, locked: isolation.lockdown)
        if evidence?.passed(usb: usb.address, other: other.address) != true {
            try? await Task.sleep(for: .seconds(1))
            evidence = await IsolationModel.prove(usb: line.interface, other: path, port: port, confined: selection.canConfine, locked: isolation.lockdown)
        }
        proof = evidence
        proofAt = Date()
        guard let evidence, evidence.passed(usb: usb.address, other: other.address) else {
            _ = try? await IsolationModel.command(.init(.block))
            let failed = evidence?.rows(usb: usb.address, other: other.address).filter { !$0.passed && $0.blocking }.map(\.id) ?? ["自检程序未完成"]
            throw USBFailure(title: "隔离自检未通过", detail: "未通过：" + failed.joined(separator: "、") + "。没有启动 Claude。")
        }
        // 让界面拿到生效后的状态，避免用旧的“已阻断”误判。
        await isolation.refresh()
        // 拦截规则要用假地址验证过真的在拦，才打开应用。
        for _ in 0..<12 where !selection.serviceHosts.isEmpty && isolation.status?.shield?.verified != true {
            try? await Task.sleep(for: .milliseconds(500))
            await isolation.refresh()
        }
        guard selection.serviceHosts.isEmpty || isolation.status?.shield?.verified == true else {
            _ = try? await IsolationModel.command(.init(.block))
            throw USBFailure(title: "服务拦截未生效", detail: "无法确认保护外的软件连不上 Claude，没有启动 Claude。")
        }
        // 全部检查通过：恢复时被暂停的 Claude 现在才继续运行。
        do { _ = try await IsolationModel.command(.init(.resume)) } catch {
            _ = try? await IsolationModel.command(.init(.block))
            throw USBFailure(title: "没能让 Claude 继续运行", detail: "已保持断网。请重试。")
        }
        return port
    }

    func recoverUSB() {
        guard usbSession, lineCut, !recovering, !stopping, let selection = target, let run = currentRun else { return }
        beginRecovery()
        Task {
            do {
                _ = try await establish(selection)
                guard usbRun(run) else { return }
                endRecovery(locked: false)
                setState("USB 专线已恢复", "重新检查和自检已通过，Claude 可以继续联网。")
            } catch {
                guard usbRun(run) else { return }
                endRecovery(locked: true)
                let failure = error as? USBFailure
                setState("Claude 仍然断网", (failure.map { $0.title + "。" + $0.detail } ?? Self.describe(error)) + " Claude 没有换到其他线路。")
            }
        }
    }

    /// 在隔离组里用空白资料的浏览器打开检测网站：走的是 USB，和之后的 Claude 同一条线路。不启动 Claude。
    func startUSBSiteTest() {
        guard !active, !releasing, !checkingNetwork, let target else { return }
        guard let check = lineCheck, check.usable(for: .usb, now: Date()) else { return siteProblem("请先点“检查线路”，通过后再打开网站。") }
        guard let url = SiteBrowser.find() else {
            return siteProblem("没有找到 Chrome、Edge、Brave 这类浏览器。可以先关掉 Wi‑Fi，让整台 Mac 走 USB，再用 Safari 打开 " + ThirdPartyCheck.name + "。")
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: target.identity.bundleID).isEmpty else {
            return siteProblem("请先按 ⌘Q 退出 \(target.displayName)，测完再从 Guard 启动。")
        }
        guard let acquired = AppSessionLock() else { return siteProblem("请先结束另一场会话。") }
        let run = beginUSB(acquired)
        setSiteTesting(true)
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("guard-site-\(UUID().uuidString)", isDirectory: true)
        Task {
            defer { try? FileManager.default.removeItem(at: profile) }
            do {
                var browser = try await Task.detached(priority: .userInitiated) { try TargetProfile.inspect(url) }.value
                guard browser.usesChromium else { throw USBFailure(title: "网站没有打开", detail: "这个浏览器不支持走 USB。") }
                browser.serviceHosts = target.serviceHosts
                let port = try await establish(browser, requireApproval: false)
                guard usbRun(run), !stopping else { throw USBFailure(title: "已取消", detail: "没有打开网站。") }
                guard usbExit?.address == check.address else { throw USBFailure(title: "网站没有打开", detail: "USB 的公网 IP 和刚才检查的不一样了，请重新检查。") }
                try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
                let app = try await Self.launchIsolated(browser, port: port, locked: isolation.lockdown, extra: SiteBrowser.arguments(profile: profile.path))
                adopt(app, run: run)
                siteOpened(usbExit?.address, line: "iPhone USB")
                setState("正在用 USB 打开检测网站", "看完回到 Guard，觉得可以就认可这个 IP，再点“看完了”。")
                while usbRun(run), !stopping, !app.isTerminated {
                    if let status = isolation.status, status.state != .armed {
                        await stopNative(run, title: "检测已中断", detail: IsolationModel.explain(status.reason ?? "状态异常") + "。")
                        return
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
                if usbRun(run), !stopping { finishUSB("检测窗口已关闭", "已恢复普通模式。") }
            } catch {
                guard usbRun(run) else { return }
                let failure = error as? USBFailure ?? USBFailure(title: "网站没有打开", detail: Self.describe(error))
                siteProblem(failure.title + "。" + failure.detail)
                finishUSB(failure.title, failure.detail)
            }
        }
    }

    private func watchUSB(_ run: UUID) async {
        var lost = 0
        while usbRun(run), !stopping {
            guard let app = runningApp else { return }
            closeUnprotectedInstances(except: app.processIdentifier)
            if app.isTerminated {
                // 应用自动更新时会由系统在隔离组外重新启动自己，这里拦下来。
                for _ in 0..<12 {
                    closeUnprotectedInstances(except: app.processIdentifier)
                    try? await Task.sleep(for: .milliseconds(500))
                    guard usbRun(run) else { return }
                }
                await finishNativeWithProcessCheck("Claude 已退出", "USB 专线会话结束，已恢复普通模式。")
                return
            }
            if let status = isolation.status {
                lost = 0
                if status.state != .armed, !lineCut, !recovering {
                    let reason = IsolationModel.explain(status.reason ?? "状态异常")
                    lockUSB()
                    let moved = status.reason == "exit_changed"
                    setState(moved ? "USB 的公网 IP 变了，Claude 已断网" : "USB 已断开，Claude 已断网", reason + "。Claude 保持打开但无法联网，不会换到 Wi‑Fi 或 VPN。" + (moved ? "确认新 IP 可以接受后" : "重新插好后") + "点「检查并恢复」。")
                    GuardNotifications.shared.report(title: "USB 专线中断", detail: reason + "。Claude 已断网，未切换到其他线路。")
                }
            } else {
                lost += 1
                // 守护进程短暂重启时内核规则仍在；持续失联说明无法继续确认，结束会话。
                if lost >= 8 {
                    await stopNative(run, title: "隔离组件失联，已停止 Claude", detail: "无法确认保护状态。")
                    return
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func closeUnprotectedInstances(except pid: pid_t) {
        guard let id = target?.identity.bundleID else { return }
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: id) where other.processIdentifier != pid && !other.isTerminated {
            other.forceTerminate()
            closedOutsideAt = Date()
            recordEntry("关闭了保护范围外启动的另一个 Claude 实例（PID \(other.processIdentifier)）。")
            GuardNotifications.shared.report(title: "已关闭未受保护的实例", detail: "Claude 在保护范围外重新启动，已将其关闭。请从 Guard 重新启动。")
        }
    }

    static func describe(_ error: Error) -> String {
        switch error as? ControlClient.Failure {
        case .refused(let code)?: IsolationModel.explain(code) + "。"
        case .unavailable?: "隔离组件没有响应。"
        case nil: error.localizedDescription
        }
    }
}
