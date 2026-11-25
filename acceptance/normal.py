#!/usr/bin/env python3
"""第一阶段验收：没启动保护时，Guard 不应在系统和目标应用里留下任何影响。
在普通方式打开的应用里运行（例如 Claude Code 的 Bash）：  python3 acceptance/normal.py
只读检查，不需要密码，不查公网 IP，不连目标应用的服务。"""
import os, re, socket, subprocess, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from netd import call

failed = 0
def check(name, ok, detail=""):
    global failed
    failed += not ok
    print(("✅ " if ok else "❌ ") + name + (f"（{detail}）" if detail else ""), flush=True)
def sh(*a, **k): return subprocess.run(a, capture_output=True, text=True, errors="replace", **k).stdout

s = call(command="status")
check("守护进程空闲、没有受保护进程", s["state"] == "idle" and not s["members"], f"{s['state']}，{len(s['members'])} 个")
left = sorted({Path(l).name for l in sh("/bin/ps", "-axo", "comm=").splitlines() if re.search(r"/(guardrelay|guardrun|guardshell|guardwatch)$", l)})
check("没有残留的 Guard 辅助进程", not left, "、".join(left))
gid = os.stat("/Library/PrivilegedHelperTools/AppNetworkGuard/guardrun").st_gid
check("当前进程不在隔离组", gid not in (os.getegid(), *os.getgroups()))
inside = [l.split(None, 1)[1] for l in sh("/bin/ps", "-axo", "gid=,comm=").splitlines() if l.split()[0] == str(gid)]
check("整台电脑没有隔离组的进程", not inside, f"{len(inside)} 个")
proxy = sorted(k for k, v in os.environ.items() if re.search(r"^GUARD_|_proxy$|NODE_USE_ENV_PROXY", k, re.I) and k.lower() != "no_proxy" and v)
check("环境变量里没有 Guard 的代理", not proxy, "、".join(proxy))
check("终端没有换成受限外壳", "AppNetworkGuard" not in os.environ.get("SHELL", ""))
mine = []
for f in Path("/etc/resolver").glob("*"):
    try: mine += [f.name] if "AppNetworkGuard" in f.read_text().replace(" ", "") else []
    except OSError: pass
check("没有残留的域名解析配置", not mine, "、".join(mine))
keys = re.findall(r"State:\S*AppNetworkGuard\S*", sh("/usr/sbin/scutil", input="list State:/Network/Service/AppNetworkGuard.*\n"))
check("没有残留的严格 DNS", not keys)
tso = sh("/usr/sbin/sysctl", "-n", "net.inet.tcp.tso").strip()
check("网卡加速选项已还原", tso == "1", f"tso={tso}")
try:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as c: c.connect(("192.0.2.1", 9)); c.send(b"x")
    udp = True
except OSError as e: udp, why = False, e.strerror
check("UDP 不受限", udp, "" if udp else why)
code = sh("/usr/bin/curl", "-q", "--noproxy", "*", "-sS", "-o", "/dev/null", "-m", "8", "-w", "%{http_code}", "https://www.apple.com/")
check("不经代理能正常上网", code == "200", code)
print("结论：" + ("没有残留" if not failed else f"{failed} 项需要查看"))
sys.exit(bool(failed))
