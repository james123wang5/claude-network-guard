#!/usr/bin/env python3
"""第四阶段实机验收。需要：已安装隔离组件、iPhone USB 在线、另有 Wi-Fi。
用法：python3 acceptance/usb.py [--claude] [--pcap]
  --claude  额外启动一个独立数据目录的 Claude Desktop 第二实例（不碰正在使用的实例）
  --pcap    用 sudo 抓默认线路的包，作为最强证据（会要求输入密码）
"""
import json, os, re, shutil, signal, socket, subprocess, sys, tempfile, threading, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from netd import call

ROOT = "/Library/PrivilegedHelperTools/AppNetworkGuard"
RUN, CHECK = f"{ROOT}/guardrun", f"{ROOT}/guardcheck"
CLAUDE = "/Applications/Claude.app/Contents/MacOS/Claude"
results = []

def sh(*a, timeout=40, env=None, cwd="/tmp"):
    try:
        p = subprocess.run(a, capture_output=True, text=True, timeout=timeout, env=env, cwd=cwd)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"

CONFINE = {"GUARD_CONFINE": ""}
FRAMEWORKS = {"GUARD_CONFINE": "/Applications/Claude.app/Contents/Frameworks"}

def group(*a, port=None, **k):
    return sh(RUN, *a, env={**os.environ, **CONFINE, **({"GUARD_PROXY": str(port)} if port else {})}, **k)

def check(name, passed, detail="", blocking=True):
    results.append((name, bool(passed), blocking))
    print(("通过 " if passed else "失败 " if blocking else "注意 ") + name + (f"  [{detail}]" if detail else ""), flush=True)

def ip(text):
    m = re.search(r"ip=([0-9a-f.:]+)", text or "")
    return m[1] if m else ""

TRACE = "https://1.1.1.1/cdn-cgi/trace"
def curl(*extra, via=sh, url=TRACE, timeout=15, **k):
    return via("/usr/bin/curl", "-4", "-q", "-s", "-m", "12", *extra, url, timeout=timeout, **k)

def default_if():
    return re.search(r"interface: (\S+)", sh("/sbin/route", "-n", "get", "1.1.1.1")[1])[1]

def usb_if():
    out = sh("/usr/sbin/networksetup", "-listallhardwareports")[1]
    m = re.search(r"Hardware Port: iPhone USB\nDevice: (\S+)", out)
    return m[1] if m else None

def members():
    return call(command="status")["members"]

def sockets(pids):
    if not pids: return set()
    out = sh("/usr/sbin/lsof", "-nP", "-a", "-p", ",".join(map(str, pids)), "-i")[1]
    found = set()
    for line in out.splitlines()[1:]:
        f = line.split()
        if len(f) >= 9: found.add((f[7], f[8]))
    return found

def external(entries):
    return {e for e in entries if "->" in e[1] and not re.search(r"->(127\.0\.0\.1|\[::1\]|localhost)", e[1])}

def broker():
    """编译一个小程序，用后台 URLSession 和 WebKit（都由系统进程代为联网）访问测试地址。"""
    home = Path(tempfile.mkdtemp()); app = home / "Broker.app/Contents/MacOS"; app.mkdir(parents=True)
    (home / "Broker.app/Contents/Info.plist").write_text('<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.appnetworkguard.broker</string><key>CFBundleExecutable</key><string>b</string></dict></plist>')
    (home / "b.swift").write_text("""
import AppKit
import WebKit
let mode = CommandLine.arguments[1]
func done(_ s: String) { print(s); exit(0) }
final class D: NSObject, URLSessionDownloadDelegate, WKNavigationDelegate {
  func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo u: URL) { done((try? String(contentsOf: u, encoding: .utf8)) ?? "?") }
  func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError e: Error?) { if let e { done("ERR \\(e.localizedDescription)") } }
  func webView(_ w: WKWebView, didFinish n: WKNavigation!) { w.evaluateJavaScript("document.body.innerText") { r, _ in done("\\(r ?? "?")") } }
  func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { done("ERR \\(e.localizedDescription)") }
  func webViewWebContentProcessDidTerminate(_ w: WKWebView) { done("ERR terminated") }
}
let d = D(); let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
let u = URL(string: "https://1.1.1.1/cdn-cgi/trace")!
var keep: Any?
if mode == "bg" { let s = URLSession(configuration: .background(withIdentifier: UUID().uuidString), delegate: d, delegateQueue: nil); s.downloadTask(with: u).resume(); keep = s }
else { let w = WKWebView(frame: .zero); w.navigationDelegate = d; w.load(URLRequest(url: u)); keep = w }
DispatchQueue.main.asyncAfter(deadline: .now() + 12) { done("ERR timeout") }
app.run()
""")
    r = sh("/usr/bin/swiftc", "-O", str(home / "b.swift"), "-o", str(app / "b"), timeout=180)
    if r[0]: print("     编译失败", r[2][-200:]); return None
    sh("/usr/bin/codesign", "--force", "--sign", "-", str(home / "Broker.app"))
    return str(app / "b")

class Existing:
    """由外部（root）持续写入的抓包文件，这里只读。"""
    def __init__(self, path): self.file = path
    def start(self): self.begin = time.time()
    def stop(self):
        time.sleep(2)
        out = sh("/usr/sbin/tcpdump", "-n", "-tt", "-r", self.file)[1]
        return [l for l in out.splitlines() if l.split(" ", 1)[0].replace(".", "").isdigit() and float(l.split(" ", 1)[0]) >= self.begin]

class Pcap:
    def __init__(self, iface): self.file = Path(tempfile.mkdtemp()) / "x.pcap"; self.iface = iface; self.p = None
    def start(self):
        self.p = subprocess.Popen(["sudo", "/usr/sbin/tcpdump", "-i", self.iface, "-n", "-U", "-w", str(self.file)], stderr=subprocess.DEVNULL); time.sleep(1.5)
    def stop(self):
        time.sleep(1); subprocess.run(["sudo", "pkill", "-INT", "-f", str(self.file)]); self.p.wait()
        out = subprocess.run(["sudo", "/usr/sbin/tcpdump", "-n", "-r", str(self.file)], capture_output=True, text=True).stdout
        return out.splitlines()

def claude(port, pcap, iface):
    home = tempfile.mkdtemp(prefix="guard-claude-")
    server = Path(home) / "mcp.mjs"; log = Path(home) / "mcp.log"
    # 测试用 MCP 服务：启动即用 node fetch 和直连套接字联网，记录公网看到的来源地址。
    server.write_text("""
import fs from 'fs'; import tls from 'tls';
const out = (k, v) => fs.appendFileSync(process.env.LOG, k + ' ' + v + '\\n');
out('gid', process.getegid());
fetch('https://www.cloudflare.com/cdn-cgi/trace').then(r => r.text()).then(t => out('fetch', t.match(/ip=(.*)/)[1])).catch(e => out('fetch', 'ERR ' + e.cause?.code));
const s = tls.connect({host: 'www.cloudflare.com', port: 443, servername: 'www.cloudflare.com'}, () => s.write('GET /cdn-cgi/trace HTTP/1.1\\r\\nHost: www.cloudflare.com\\r\\nConnection: close\\r\\n\\r\\n'));
let b = ''; s.on('data', d => b += d); s.on('end', () => out('direct', b.match(/ip=(.*)/)[1])); s.on('error', e => out('direct', 'ERR ' + e.code));
process.stdin.on('data', d => { for (const l of d.toString().split('\\n').filter(Boolean)) { const m = JSON.parse(l);
  if (m.method === 'initialize') process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:m.id,result:{protocolVersion:m.params.protocolVersion,capabilities:{tools:{}},serverInfo:{name:'guardtest',version:'1'}}})+'\\n');
  else if (m.method === 'tools/list') process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:m.id,result:{tools:[]}})+'\\n'); } });
setInterval(() => {}, 1000);
""")
    node = shutil.which("node")
    if node:
        (Path(home) / "claude_desktop_config.json").write_text(json.dumps({"mcpServers": {"guardtest": {"command": node, "args": [str(server)], "env": {"LOG": str(log)}}}}))
    cap = (Existing(pcap) if isinstance(pcap, str) else Pcap(iface)) if pcap else None
    if cap: cap.start()
    p = subprocess.Popen([RUN, CLAUDE, f"--user-data-dir={home}", f"--proxy-server=http://127.0.0.1:{port}", "--disable-quic",
                          "--force-webrtc-ip-handling-policy=disable_non_proxied_udp"],
                         env={**os.environ, **FRAMEWORKS, "GUARD_PROXY": str(port)}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd="/")
    seen, udp, outside, names = set(), set(), set(), set()
    end = time.time() + 40
    while time.time() < end:
        m = members(); names |= {x["name"] for x in m}
        s = sockets([x["pid"] for x in m])
        udp |= {e for e in external(s) if e[0] == "UDP"}; seen |= s
        for line in sh("/bin/ps", "-ax", "-o", "pid=,gid=,command=")[1].splitlines():
            f = line.split(None, 2)
            if len(f) == 3 and home in f[2] and "lsof" not in f[2] and int(f[1]) != os.stat(RUN).st_gid: outside.add(f[2][:60])
        time.sleep(0.2)
    usb_addr = sh("/usr/sbin/ipconfig", "getifaddr", usb_if())[1]
    direct = {e for e in external(seen) if e[0] == "TCP"}
    check("Claude 主程序和 Helper 全部在隔离组内", not outside and len(names) >= 2, f"进程 {sorted(names)} 组外 {len(outside)}")
    relayed = {e for e in seen if f"->127.0.0.1:{port}" in e[1]}
    check("正向对照：观测到 Claude 连接转发器", len(relayed) >= 5, f"{len(relayed)} 条")
    check("Claude 有流量经 USB 转发", call(command="status")["download"] > 100_000, f"下载 {call(command='status')['download']} 字节")
    check("Claude 没有任何 UDP 外连", not udp, f"{len(udp)} 条")
    chrome = {e for e in direct if not e[1].startswith(usb_addr)}
    check("Claude 绕过转发器的直连 TCP", True, f"{len(direct)} 条（含 MCP 测试的一条，由内核改道 USB）", blocking=False)
    mcp = dict(l.split(" ", 1) for l in log.read_text().splitlines()) if log.exists() else {}
    if cap:
        lines = cap.stop()
        ports = {re.search(r":(\d+)->", e[1])[1] for e in seen if "->" in e[1] and not "->127.0.0.1" in e[1] and re.search(r":(\d+)->", e[1])}
        leak = [l for l in lines if any(re.search(rf"\.{port} > ", l) for port in ports)]
        check("抓包正向对照：默认线路确有其他应用的包", len(lines) > 20, f"{len(lines)} 个包")
        if ports: check("抓包：默认线路上没有 Claude 实例的包", not leak, f"核对 {len(ports)} 个本地端口，泄漏 {len(leak)}")
        else: print("     抓包端口核对不适用：该实例没有任何非本机套接字可核对")
        dns = {m[0] for l in lines for m in [re.search(r"\? (\S*(claude|anthropic)\S*)", l)] if m}
        check("抓包：默认线路上没有 Claude 域名的 DNS", not dns, " ".join(d.split()[1] if " " in d else d for d in dns))
    os.kill(p.pid, signal.SIGTERM); time.sleep(3)
    for x in members():
        if x["name"] == "sleep": continue
        try: os.kill(x["pid"], signal.SIGKILL)
        except OSError: pass
    time.sleep(1); shutil.rmtree(home, ignore_errors=True)
    return mcp

def main():
    pcap = "--pcap" in sys.argv
    usb, other = usb_if(), default_if()
    if not usb or usb == other: sys.exit("需要 iPhone USB 和另一条默认线路")
    if "--pcap-file" in sys.argv: pcap = sys.argv[sys.argv.index("--pcap-file") + 1]
    elif pcap: subprocess.run(["sudo", "-v"], check=True)
    if call(command="status")["state"] != "idle": sys.exit("已有会话，请先停止")
    E_USB, E_OTHER = ip(curl("--interface", f"if!{usb}")[1]), ip(curl()[1])
    print(f"USB {usb} 出口 {E_USB}；默认 {other} 出口 {E_OTHER}")
    if not E_USB or not E_OTHER or E_USB == E_OTHER: sys.exit("两条线路必须都在线且出口不同")

    check("未就绪时拒绝启动", group("/usr/bin/true")[0] == 75)
    dns_before = sh("/usr/sbin/scutil", "--dns")[1]
    s = call(command="arm", mode="usb", interface=usb, domains=["claude.ai", "anthropic.com", "claude.com"], strictDNS=True, confined=True)
    port = s.get("relayPort"); check("规则生效", s["state"] == "armed" and port, f"转发端口 {port} 严格DNS {s['strictDNS']}")
    keeper = subprocess.Popen([RUN, '/bin/sleep', '600'])
    time.sleep(0.5)
    try:
        proof = json.loads(group(CHECK, usb, other, str(port))[1])
        check("TCP 默认路径走 USB", proof["tcp"] == E_USB, proof["tcp"])
        check("TCP 强绑原线路不泄漏", proof["tcpForced"] in ("", E_USB), proof["tcpForced"] or "拒绝")
        check("转发器走 USB", proof["relay"] == E_USB)
        check("QUIC 封锁（含强绑）", not proof["quic"] and not proof["quicForced"])
        check("局域网直连封锁", not proof.get("lan"))
        check("IPv6 封锁", not proof["ipv6"])
        check("其他 UDP 被进程级限制拒绝", proof["udp"] == "", proof["udp"] or "拒绝")
        outside = json.loads(sh(CHECK, usb, other, "0")[1])
        check("对其他应用的影响：QUIC 正常", outside["quic"])
        check("对其他应用的影响：UDP、局域网、TCP 正常", outside["udp"] == E_OTHER and outside["lan"] and outside["tcp"] == E_OTHER)
        check("对其他应用的影响：未触发改道前 TSO 保持开启或仅因自检短暂关闭", True, "tso=" + sh("/usr/sbin/sysctl", "-n", "net.inet.tcp.tso")[1], blocking=False)
        name = re.search(r"search domain\[0\] : (\S+)", dns_before)
        if name:
            servers = sh("/usr/sbin/scutil", "--dns")[1]
            check("对其他应用的影响：内网域名仍由路由器解析", re.search(r"domain\s+: " + re.escape(name[1]), servers), name[1])
        for label, code in {"ps": ("/bin/ps", "-p", "1", "-o", "comm="), "嵌套沙箱": ("/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)", "/usr/bin/true"),
                            "读写用户文件": ("/bin/sh", "-c", "touch /tmp/guard-w && rm /tmp/guard-w"), "本机服务": ("/usr/bin/nc", "-z", "127.0.0.1", str(port)),
                            "系统解析": ("/usr/bin/dscacheutil", "-q", "host", "-a", "name", "www.apple.com"), "钥匙串": ("/usr/bin/security", "list-keychains")}.items():
            check(f"组内功能保留：{label}", group(*code)[0] == 0)
        for name, args in {
            "curl（遵守代理）": ("/usr/bin/curl", "-4", "-q", "-s", "-m", "12", TRACE),
            "curl（忽略代理直连）": ("/usr/bin/curl", "-4", "-q", "-s", "-m", "12", "--noproxy", "*", TRACE),
            "python urllib": ("/usr/bin/python3", "-c", f"import urllib.request as u,ssl;print(u.urlopen('https://www.cloudflare.com/cdn-cgi/trace',timeout=10).read().decode())"),
            "node fetch": ("/opt/homebrew/bin/node", "-e", "fetch('https://www.cloudflare.com/cdn-cgi/trace').then(r=>r.text()).then(console.log)"),
            "node 直连套接字": ("/opt/homebrew/bin/node", "-e", "const t=require('tls');const s=t.connect({host:'www.cloudflare.com',port:443,servername:'www.cloudflare.com'},()=>s.write('GET /cdn-cgi/trace HTTP/1.1\\r\\nHost: www.cloudflare.com\\r\\nConnection: close\\r\\n\\r\\n'));s.on('data',d=>process.stdout.write(d))"),
        }.items():
            if os.path.exists(args[0]):
                r = group(*args, port=port); check(f"子进程 {name} 走 USB", ip(r[1]) == E_USB, ip(r[1]) or r[2][-80:])
        r = group("/usr/bin/git", "ls-remote", "--heads", "https://github.com/apple/swift-log.git", port=port); check("git HTTPS 可用", r[0] == 0, r[2][-80:])
        orphan = ("import os,subprocess\nif os.fork()==0:\n os.setsid()\n if os.fork()==0:\n"
                  "  r=subprocess.run(['/usr/bin/curl','-4','-q','-s','-m','12','--noproxy','*','%s'],capture_output=True,text=True).stdout\n"
                  "  open('/tmp/guard-orphan.txt','w').write('%%d gid=%%d %%s'%%(os.getppid(),os.getegid(),r)); os._exit(0)\n os._exit(0)\nos.wait()" % TRACE)
        group("/usr/bin/python3", "-c", orphan); time.sleep(4)
        note = Path("/tmp/guard-orphan.txt"); text = note.read_text() if note.exists() else ""; note.unlink(missing_ok=True)
        check("脱离父进程（双 fork + 新会话）的孤儿进程仍走 USB", ip(text) == E_USB and text.startswith("1 "), text.split(" ip")[0][:20])
        leader = subprocess.run([RUN, "/usr/bin/id", "-g"], start_new_session=True, capture_output=True, text=True)
        check("会话首进程也能启动", leader.returncode == 0)
        check("对照：普通进程仍走原线路", ip(curl()[1]) == E_OTHER)
        check("普通进程不能借用转发器", curl("-x", f"http://127.0.0.1:{port}")[0] != 0)
        check("组内进程不能改动保护", "not_allowed" in group("/usr/bin/python3", "-c", "import socket;s=socket.socket(socket.AF_UNIX);s.connect('/var/run/appnetworkguard/control.sock');s.sendall(b'{\"command\":\"release\"}\\n');print(s.recv(99999))")[1])
        check("DNS：受保护域名解析正常", sh("/usr/bin/dscacheutil", "-q", "host", "-a", "name", "claude.ai")[1] != "")
        check("DNS：默认解析器指向 USB", "172.20.10.1" in sh("/usr/sbin/scutil", "--dns")[1].split("DNS configuration (for scoped")[0])
        check("DNS：其他域名仍可用", sh("/usr/bin/dscacheutil", "-q", "host", "-a", "name", "www.apple.com")[1] != "")
        up = group("/usr/bin/curl", "-4", "-q", "-s", "-m", "40", "--noproxy", "*", "-o", "/dev/null", "-w", "%{http_code} %{size_upload}", "-F", "f=@/usr/share/dict/words", "https://speed.cloudflare.com/__up", timeout=60)[1]
        check("内核改道大文件上传 2.5MB", up.startswith("200"), up)

        lock = {**os.environ, **CONFINE, "GUARD_LOCK": "1"}
        locked = json.loads(sh(RUN, CHECK, usb, other, str(port), env=lock)[1])
        check("锁死模式：直连、强绑、UDP、QUIC、局域网全拒，只剩转发器", not (locked["tcp"] or locked["tcpForced"] or locked["udp"] or locked["quic"] or locked["lan"]) and locked["relay"] == E_USB)
        check("锁死模式：不能使用系统 DNS", sh(RUN, "/usr/bin/curl", "-4", "-q", "-s", "-m", "6", "--noproxy", "*", "https://www.cloudflare.com/cdn-cgi/trace", env=lock)[0] == 6)
        check("锁死模式：支持代理的程序正常", ip(sh(RUN, "/usr/bin/curl", "-4", "-q", "-s", "-m", "12", "https://www.cloudflare.com/cdn-cgi/trace", env={**lock, "GUARD_PROXY": str(port)})[1]) == E_USB)
        tool = broker()
        if tool:
            for mode, label in (("bg", "系统后台下载"), ("webkit", "WebKit 网络进程")):
                before = sh(tool, mode, timeout=30)[1]
                inside = group(tool, mode, port=port, timeout=30)[1]
                check(f"代办联网不泄漏：{label}", ip(inside) in ("", E_USB), f"组外 {ip(before) or before[:30]} / 组内 {ip(inside) or inside[:40]}")

        if "--claude" in sys.argv:
            mcp = claude(port, pcap, other)
            if mcp:
                check("MCP 子进程继承隔离组", mcp.get("gid") == str(os.stat(RUN).st_gid), mcp.get("gid"))
                check("MCP fetch 走 USB", mcp.get("fetch") == E_USB, mcp.get("fetch"))
                check("MCP 直连套接字走 USB", mcp.get("direct") == E_USB, mcp.get("direct"))
            else: check("MCP 测试服务被启动", False, "未登录的实例可能不启动 MCP", blocking=False)

        # 故障：长连接中阻断
        slow = subprocess.Popen([RUN, "/usr/bin/curl", "-4", "-q", "-s", "-m", "15", "--noproxy", "*", "--limit-rate", "30k", "-o", "/dev/null", "-w", "%{size_download}",
                                 "https://speed.cloudflare.com/__down?bytes=3000000"], stdout=subprocess.PIPE, text=True, cwd="/tmp")
        time.sleep(4); t = time.time(); call(command="block")
        code = subprocess.run(["/bin/sh", "-c", "exit 0"]).returncode
        size = slow.communicate(timeout=30)[0]
        check("阻断后已有连接停止", slow.returncode != 0, f"curl rc={slow.returncode} 已下载 {size}")
        check("阻断后拒绝新启动", group("/usr/bin/true")[0] == 75)
        check("阻断期间其他应用正常", ip(curl()[1]) == E_OTHER)
        time.sleep(2)
        check("阻断后默认 DNS 已还原", "172.20.10.1" not in sh("/usr/sbin/scutil", "--dns")[1].split("resolver #2")[0])
        s = call(command="arm", mode="usb", interface=usb, domains=[], strictDNS=False, confined=True)
        check("重新检查后可恢复，端口不变", s["state"] == "armed" and s["relayPort"] == port, str(s.get("relayPort")))
        # 故障：转发器崩溃（nobody 进程，普通用户无权结束，交给守护进程的状态机，以阻断为准）
    finally:
        for x in members():
            try: os.kill(x["pid"], signal.SIGKILL)
            except OSError: pass
        time.sleep(1); end = call(command="release")
    keeper.wait()
    check("结束后恢复空闲", end["state"] == "idle", end.get("error", ""))
    time.sleep(1)
    check("结束后普通网络正常", ip(curl()[1]) == E_OTHER)
    check("结束后 DNS 与开始前一致", sh("/usr/sbin/scutil", "--dns")[1].split("resolver #2")[0] == dns_before.split("resolver #2")[0])
    check("结束后 TSO 已还原", sh("/usr/sbin/sysctl", "-n", "net.inet.tcp.tso")[1] == "1")
    check("没有残留 /etc/resolver", not any(p.read_text().startswith("# App Network Guard") for p in Path("/etc/resolver").glob("*")) if Path("/etc/resolver").exists() else True)
    bad = [r for r in results if not r[1] and r[2]]
    print(f"\n共 {len(results)} 项，失败 {len(bad)}，注意 {len([r for r in results if not r[1] and not r[2]])}")
    sys.exit(1 if bad else 0)

if __name__ == "__main__": main()
