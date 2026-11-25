import SwiftUI

/// App 内说明。和 README、BOUNDARIES.md 说的是同一件事，这里只留用的时候要知道的。
struct HelpView: View {
    var body: some View {
        PageHeading(title: "说明", subtitle: "它管什么、不管什么、遇到事情怎么办。")
        Panel(title: "管什么，不管什么") {
            VStack(alignment: .leading, spacing: 9) {
                row(true, "从 Guard 启动的 Claude Desktop，包括聊天、Code、内置浏览器、终端面板，以及它们运行的命令")
                row(false, "claude.ai 网页版、手机上的 Claude")
                row(false, "浏览器里的 Claude 插件（Claude in Chrome）")
                row(false, "从程序坞直接打开的 Claude Desktop")
                row(false, "你自己在终端或编辑器里运行的 claude")
                row(false, "Claude 打开的其他软件，例如 Safari、Xcode、模拟器：它们用自己的网络")
            }
        }
        Panel(title: "启动前先关掉") {
            VStack(alignment: .leading, spacing: 7) {
                bullet("Claude Desktop：用 ⌘Q 完全退出。")
                bullet("浏览器里打开的 claude.ai，和 Claude 插件：不关会被拦，并一直提醒。")
                bullet("终端或编辑器里的 claude。")
                bullet("系统代理（Clash 等软件里的“系统代理”开关）。整机 VPN 不用关。")
                bullet("带“DNS 代理”的公司或学校安全软件。在「系统设置 › 网络 › 过滤条件与代理」里看。")
            }
        }
        Panel(title: "终端里的 claude") {
            VStack(alignment: .leading, spacing: 7) {
                Text("平时不受保护。USB 保护时会被拦住；VPN 和热点保护时，它和其他软件一样走这条线，断线后被拦。")
                Text("想受保护，要同时满足：正在用 USB 保护，而且在 `guard-shell.sh` 打开的那个窗口里运行。这个方式还没有完整实测。")
            }
            .font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        Panel(title: "遇到事情怎么办") {
            VStack(alignment: .leading, spacing: 12) {
                item("要重新登录", "登录会跳到外部浏览器，保护中会被拦。先停止保护；用 USB 的话再关掉 Wi‑Fi，让整台 Mac 走手机；登录好，打开 Wi‑Fi，再从 Guard 启动。")
                item("线断了", "Claude 断网但不退出。接好后点“检查并恢复”，不会自动恢复。")
                item("IP 变了", "回到原来的 IP 可以直接恢复。新 IP 要重新检查、看网站、认可。")
                item("Claude 自动更新", "更新后它会自己在保护外重开，Guard 会关掉它。从这里再启动一次。")
                item("登录后某些页面打不开", "多半是它打开了外部浏览器。复制链接到 Claude 的内置浏览器里。")
                item("Guard 闪退了", "不影响。断网和拦截由后台组件和系统内核执行。没有安装组件时例外：会退出 Claude。")
            }
        }
        Panel(title: "防不住的") {
            VStack(alignment: .leading, spacing: 7) {
                bullet("线没断、对方悄悄换了 IP：约几秒到十几秒后才发现并断网。")
                bullet("写在截图、网页、文件里的 IP：Claude 读到就知道了。")
                bullet("苹果系统自己的请求，例如推送、检查证书。")
                bullet("在 Anthropic 服务器上执行的操作，例如联网搜索：本来就不经过这台 Mac。")
                bullet("它不能让账号“更安全”，也不保证 Anthropic 怎么看待某个 IP。")
            }
        }
        Text("非官方软件，与 Anthropic 无关。Claude 的名字和形象属于 Anthropic。").font(.caption).foregroundStyle(.secondary)
    }

    private func row(_ yes: Bool, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: yes ? "checkmark.circle.fill" : "minus.circle").foregroundStyle(yes ? Color.guardGreen : .secondary).frame(width: 18)
                .accessibilityLabel(yes ? "管" : "不管")
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(Color.secondary).frame(width: 4, height: 4).padding(.horizontal, 7).accessibilityHidden(true)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func item(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout.weight(.semibold))
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
