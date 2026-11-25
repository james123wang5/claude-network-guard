#!/usr/bin/env python3
"""旁观一场真实的 USB 会话（例如日常使用的 Claude Desktop），出具泄漏报告。
在系统自带「终端」里运行（不要在被测应用里运行）：  python3 acceptance/watch.py [分钟数，默认 5]
会要求输入一次 sudo 密码用于抓包。运行期间请在被测应用里尽量多用各种功能。"""
import ipaddress, os, re, subprocess, sys, tempfile, time
from collections import defaultdict
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from netd import call

minutes = float(sys.argv[1]) if len(sys.argv) > 1 else 5
def sh(*a): return subprocess.run(a, capture_output=True, text=True).stdout
start = call(command="status")
if start["state"] != "armed" or start.get("mode") != "usb": sys.exit("当前没有生效中的 USB 会话，请先从 App 启动目标应用")
if os.getegid() == os.stat("/Library/PrivilegedHelperTools/AppNetworkGuard/guardrun").st_gid: sys.exit("请在系统自带「终端」里运行，不要在被测应用里运行")
default = re.search(r"interface: (\S+)", sh("/sbin/route", "-n", "get", "1.1.1.1"))[1]
subprocess.run(["sudo", "-v"], check=True)
pcap = Path(tempfile.mkdtemp()) / "d.pcap"
stop = pcap.with_name("stop")
# 只在开头授权一次：抓包程序看到停止标记、本脚本退出或超时都会自己结束，并把文件交还给当前用户。
CAPTURE = """umask 077; "$1" -i "$2" -n -U -w "$3" </dev/null >/dev/null 2>&1 & p=$!; n=0
while [ ! -e "$4" ] && kill -0 "$5" 2>/dev/null && kill -0 $p 2>/dev/null && [ $n -lt "$6" ]; do sleep 1; n=$((n+1)); done
kill -TERM $p 2>/dev/null; wait $p; chown -h "$7" "$3" """
dump = subprocess.Popen(["sudo", "-n", "/bin/sh", "-c", CAPTURE, "sh", "/usr/sbin/tcpdump", default, str(pcap), str(stop),
                         str(os.getpid()), str(int(minutes * 60) + 60), str(os.getuid())],
                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(2)
if dump.poll() is not None: sys.exit("抓包没有启动，请重新运行")
print(f"正在监视 {minutes} 分钟。请依次使用：聊天、上传文件、内置浏览器、MCP 工具、Claude Code 命令、联网搜索、设置页 …", flush=True)
ports, relay, udp, names, states = {}, 0, set(), set(), set()
known = {e["id"] for e in start["events"]}
end = time.time() + minutes * 60
while time.time() < end:
    s = call(command="status"); states.add(s["state"]); names |= {m["name"] for m in s["members"]}
    pids = [str(m["pid"]) for m in s["members"]]
    if pids:
        for line in sh("/usr/sbin/lsof", "-nP", "-a", "-p", ",".join(pids), "-i").splitlines()[1:]:
            f = line.split()
            if len(f) < 9 or "->" not in f[8]: continue
            m = re.match(r".*:(\d+)->(.*):(\d+)$", f[8])
            if not m: continue
            if m[2] in ("127.0.0.1", "[::1]"): relay += m[3] == str(s.get("relayPort"))
            else:
                ports[(f[7], m[1], m[2])] = f[0]
                if f[7] == "UDP": udp.add((f[0], f[8]))
    time.sleep(0.3)
time.sleep(1); stop.touch(); dump.wait()
lines = subprocess.run(["/usr/sbin/tcpdump", "-n", "-r", str(pcap)], capture_output=True, text=True, errors="replace").stdout.splitlines()
for item in (pcap, stop): item.unlink(missing_ok=True)
pcap.parent.rmdir()
leaks = defaultdict(int)
for (proto, port, remote), name in ports.items():
    for l in lines:
        if f".{port} > {remote}." in l: leaks[(name, proto, remote)] += 1
dns = sorted({m[1] for l in lines for m in [re.search(r"(?:A|AAAA|HTTPS)\? (\S+)", l)] if m and not m[1].endswith((".local.", ".arpa."))})
# 保护外的软件也不能从默认线路连到该应用的服务。被防火墙拦下的包到不了网卡，所以这里抓到一个就是真的漏了。
final = call(command="status")
shield = final.get("shield") or {}
nets = [ipaddress.ip_network(n) for n in shield.get("networks", [])]
outside = defaultdict(int)
for l in lines:
    m = re.search(r" IP6? (\S+) > (\S+?)[.:]? ?(?:\d*): |IP6? (\S+) > (\S+):", l)
    if not m: continue
    for host in (m[1] or m[3], m[2] or m[4]):
        for text in (host, host.rsplit(".", 1)[0]):
            try: address = ipaddress.ip_address(text)
            except ValueError: continue
            if any(address.version == n.version and address in n for n in nets): outside[str(address)] += 1
            break
events = [e for e in call(command="status")["events"] if e["id"] not in known]
print("\n===== 报告 =====")
print(f"会话状态 {sorted(states)}；受保护进程 {sorted(names)}")
print(f"正向对照：观测到连接转发器 {relay} 次（应大于 0）；默认线路 {default} 抓到 {len(lines)} 个包（应大于 0）")
print(f"绕过转发器的直连（由内核改道）：{len(ports)} 条 " + ", ".join(sorted({f'{n}→{k[2]}' for k, n in ports.items()}))[:600])
print(f"UDP 外连：{len(udp)} 条 {sorted(udp)[:8]}")
print(f"默认线路上属于受保护进程的包：{dict(leaks) or '无'}")
print(f"默认线路上的 DNS 查询（严格 DNS 打开时应为空）：{dns[:20] or '无'}")
print(f"服务拦截：{'已验证生效' if shield.get('verified') else '没有生效'}，覆盖 {len(nets)} 段地址，已拦 {shield.get('blockedPackets', 0)} 个包，来自 {shield.get('programs') or '（没有）'}，拦不到 {shield.get('uncovered') or '（没有）'}")
print(f"默认线路上与该服务往来的包（不分软件，应为空）：{dict(outside) or '无'}")
for e in events: print(f"事件 {e['kind']}: {e['detail']}")
ok = shield.get("verified") and nets and not outside and relay and lines and not leaks and not udp and states == {"armed"}
print("结论：" + ("没有发现泄漏" if ok else "存在需要查看的项目，见上"))
