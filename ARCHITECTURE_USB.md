# 技术方案

## 为什么换路线

0.1.0 的候选方案是 Network Extension（透明代理 + 内容过滤）。它需要付费开发者账号签发的受限权限，免费个人团队无法加载；并且扩展崩溃或被系统停用时流量会回到默认线路。0.2.0 改用系统自带的 PF 防火墙按进程组执行，规则在内核里，进程崩溃不影响规则，也不需要开发者账号。

## 组成

```
App（界面，普通权限）──Unix 套接字──► guardnetd（root，launchd 常驻）──► PF 规则、DNS、审计
      │                                      └─► guardrelay（nobody，只绑 USB 网卡的转发器）
      └─► guardrun（setgid appnetguard）──原地执行──► Claude Desktop 及其全部子进程
```

| 部件 | 职责 |
|---|---|
| `guardrun` | 确认保护已生效后，以受限组身份原地执行 Claude Desktop。组身份由子进程继承，普通进程无法退出。未生效即拒绝启动 |
| `guardnetd` | 装载/核对/撤销规则，监视线路、进程和套接字。任何不确定都转为「断网」，恢复必须由用户触发 |
| `guardrelay` | SOCKS5 + HTTP 代理，套接字绑定 USB 网卡，域名在 USB 上自行解析。只有受限组能连接 |
| `guardcheck` | 在受限组内主动尝试从其他线路联网，输出证据 |
| `guardwatch` | VPN / 热点会话的心跳守护 |

## 流量怎么走

1. **Chromium / Electron**：以 `--proxy-server=http://` 启动，全部连接和 DNS 进入转发器，QUIC 和非代理 UDP 关闭。必须用 HTTP 代理：Claude 的代码会跳过 SOCKS 条目，导致 Claude Code 等下游不走代理。
2. **进程级限制**（`guardrun` 在执行目标前调用 `sandbox_init`，子进程继承）：拒绝本机以外的 UDP 和 TCP 53（DNS 代理扩展在 PF 之前接管它）；拒绝把联网交给 nsurlsessiond 和 WebKit 网络进程。应用 `Frameworks` 里的 Helper 用 `(with no-sandbox)` 豁免，因为两层沙箱不能叠加、它们自带沙箱；`sandbox-exec`、`ps`、`top` 同样豁免。自带 App Sandbox 的应用不能套用，改为临时封锁默认线路 QUIC。
3. **命令行工具、MCP、Cowork**：设置代理环境变量；不遵守代理的 TCP 由 PF `route-to` 改道到 USB 并 NAT。Cowork 虚拟机的网络由 Claude 主进程内的 gVisor 转发（日志 `networkMode=gvisor`），因此本来就在隔离组内。
4. **兜底**：受限组除本机和 USB 外的 TCP、IPv6、局域网一律拒绝；指向本机的系统代理端口对受限组关闭。
5. **审计**（0.25 秒一次）：组外代办进程的外部连接、组内遗漏的 UDP，按单个套接字封锁，不结束进程；套接字关闭后规则消失。
6. **锁死模式**：进程级限制再拒绝本机以外的 TCP 和系统 DNS，只剩转发器。不依赖 PF。

## 实测得到的几个关键事实（macOS 27.2）

- PF 的 `group` 匹配对 TCP 可靠。对 UDP，在有内容过滤器的系统上全部归到 uid 0 / gid 0，**不能依赖**。
- `route-to` + NAT 必须用 `keep state (if-bound)` 且改道规则 `no state`。否则握手后的包会命中浮动状态，回到默认网卡发出。
- 改道连接按原网卡能力生成 TSO 大包，iPhone USB 网卡不支持，上传会降到约 47 KB/s。累计改道流量超过自检量后才关闭 `net.inet.tcp.tso`，结束还原；触发前已建立的那条连接仍会慢。
- Claude Desktop 完全遵守 `--proxy-server`：观测到的套接字只指向转发器，没有 UDP。
- 外层沙箱会让 Chromium Helper 自身沙箱失败；对 Helper 目录加 `(with no-sandbox)` 后正常。
- `DNSSD_UDS_PATH` 在系统解析库中无效，无法按进程重定向系统 DNS；沙箱可以按进程禁用它。

## 服务拦截

目的：受保护应用的服务方只能看到所选线路的地址。独立锚点 `302`，对所有程序生效：除所选网卡外，一律丢弃发往服务地址的包（不分协议）；断线时不留任何网卡例外。受保护组的改道规则在 `300` 锚点先命中，不受影响。

- 地址来源：服务方自有地址段（Claude 为 `160.79.104.0/23`、`2607:6bc0::/48`）＋所填域名及常见子域名每分钟解析，只增不减。共享 CDN 段不拦并在界面列出。
- 验证：向文档专用地址 `192.0.2.1` 发包，计数增加才算生效，不接触真实服务。未验证不启动应用。
- 识别：计数增加后扫描组外套接字，尽力给出程序名。
- 用 `drop` 而不是 `return`：连接停留在等待状态，便于认出程序，也避免插件立刻重试。
- USB 公网地址：守护进程每 5 秒绑定 USB 读取一次，与启动时不同且复读仍不同即断网（`exit_changed`）。
- Guard 自己的检测：只有确认当前就是所选线路才访问服务域名；此前手动检测会从默认线路访问。
- 终端面板：它由豁免沙箱的 Helper 派生，继承不到进程级限制。`guardrun` 把 `SHELL` 指向 `guardshell`（名为 zsh / bash），由它补上限制再执行真正的 shell。

## DNS

系统 DNS 由 mDNSResponder 统一代办，无法按应用归属。三层处理：转发器自行在 USB 上解析；服务域名写入 `/etc/resolver` 指向 USB；「严格 DNS」用补充解析器让全机默认解析走 USB，路由器下发的内网域名仍由原 DNS 解析。三者都在会话结束时删除。断线时严格 DNS 立即撤销以免影响其他应用，服务域名的配置保留到会话结束。关闭严格 DNS 时，未列出的域名若由程序自行走系统解析，查询会经原线路（只有域名，没有内容）。

## 已知边界

- 与 VPN 并行：隔离与拦截规则都写成"除 USB 网卡以外"，不写死 en0，因此 utun 同样覆盖；与一款真实整机 VPN 并行实测过，其他 VPN 没测。
- 受限组可以连接本机任意端口，只封系统代理登记的本机端口。未登记为系统代理的本机代理（含 PAC 指定的）若被组内程序主动使用，流量会从代理的线路出去。
- 系统代理若是远程地址，组内遵守系统代理的原生程序会经 USB 连到它，服务方看到的是代理地址。
- 透明代理类网络扩展可在套接字层接管转发器与组内连接，PF 看不到。
- 不覆盖系统服务代办的请求：外部浏览器、推送、证书吊销检查（trustd）、ICMP。
- Chromium 网络 Helper 不在进程级限制内，其 UDP 靠启动参数关闭、审计复核。
- 具有 root 权限的软件可以清空防火墙：约 0.3–1 秒内发现并断网通知，空窗里不遵守代理的程序可能漏出 1–3 个请求；走转发器的流量和锁死模式不受影响。
- 受限组内执行 `sudo` 会被拒绝（否则可脱离隔离组）。
- 仅使用 IPv4。

## 目录与系统里的位置

`Sources/GuardCore` 约定、规则、线路识别、进程审计；`guardnetd` / `guardrelay` / `guardrun` / `guardcheck` / `guardwatch` 见架构文档；`Sources/ClaudeNetworkGuard` 界面，其中 `USBSession.swift` 是 USB 流程，`Isolation.swift` 是与守护进程的接口。`scripts` 为组件安装与卸载，`acceptance` 为实机验收。

系统里的位置：`/Library/PrivilegedHelperTools/AppNetworkGuard`、`/Library/LaunchDaemons/local.appnetworkguard.netd.plist`、`/var/db/appnetworkguard`、日志 `/var/log/appnetworkguard.log`、隔离组 `appnetguard`、PF 锚点 `com.apple/300.AppNetworkGuard`。

内部标识沿用旧名（Bundle ID `local.appnetworkguard.main`、隔离组、PF 锚点），免得升级时残留。图标由 `scripts/make-icon.swift` 生成。界面出图：`GUARD_SNAPSHOT=目录 swift test --filter SnapshotTests`。

## 参考

[VPNOnly](https://vpnonly.app) 的按组匹配与 disclaim 启动思路（MIT 部分）、[XNU 源码](https://github.com/apple-oss-distributions/xnu) 的 `pf.c` 与 `necp.c`、mitmproxy 的 macOS PF 用法。代码为独立实现。NECP 私有接口需要 Apple 平台签名，未使用。
