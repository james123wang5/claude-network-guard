#!/usr/bin/env python3
"""验收服务拦截：在系统自带「终端」里运行（不要在受保护的应用里）。需要一场生效中的会话。
  python3 acceptance/shield.py
先只用文档专用的假地址确认规则有效，确认后才去连真实服务；前一步不过就不碰真实服务。不需要密码。"""
import os, socket, subprocess, sys, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from netd import call

if os.getegid() == os.stat("/Library/PrivilegedHelperTools/AppNetworkGuard/guardrun").st_gid: sys.exit("请在系统自带「终端」里运行，不要在被测应用里运行")
s = call(command="status")
if s["state"] != "armed" or not s.get("shield"): sys.exit("没有生效中的会话，或没有填服务域名")
failed = 0
def check(name, ok, detail=""):
    global failed
    failed += not ok
    print(("✅ " if ok else "❌ ") + name + (f"（{detail}）" if detail else ""), flush=True)
def curl(*a): return subprocess.run(["/usr/bin/curl", "-q", "--noproxy", "*", "-sS", "-o", "/dev/null", "-m", "8", "-w", "%{http_code}", *a], capture_output=True, text=True).stdout

check("守护进程已用假地址验证规则", s["shield"]["verified"], f"{len(s['shield']['networks'])} 段地址")
if failed: sys.exit("规则没有生效，不去连真实服务，到此为止。")
check("其他网站照常能打开", curl("https://www.apple.com/") not in ("", "000"))
before = s["shield"]["blockedPackets"]
for host in (s.get("protectedDomains") or ["claude.ai", "claude.com", "anthropic.com", "claudeusercontent.com"]):
    code = curl(f"https://{host}/")
    check(f"保护外连不上 {host}", code in ("", "000"), f"返回 {code or '无'}")
for family, name in ((socket.AF_INET, "IPv4"), (socket.AF_INET6, "IPv6")):
    for kind, label in ((socket.SOCK_STREAM, "TCP"), (socket.SOCK_DGRAM, "UDP")):
        host = next((n.split("/")[0] for n in s["shield"]["networks"] if (":" in n) == (family == socket.AF_INET6)), None)
        if not host: continue
        target = {"160.79.104.0": "160.79.104.10", "2607:6bc0::": "2607:6bc0::10"}.get(host, host)
        with socket.socket(family, kind) as c:
            c.settimeout(4)
            try:
                c.connect((target, 443))
                if kind == socket.SOCK_DGRAM: c.send(b"x"); reached = False
                else: reached = True
            except OSError: reached = False
        if kind == socket.SOCK_STREAM: check(f"直接连地址（{name} {label}）被拦", not reached)
time.sleep(3)
after = call(command="status")["shield"]
check("Guard 记录到了这些尝试", after["blockedPackets"] > before, f"拦下 {after['blockedPackets'] - before} 个包，认出 {after['programs'] or '无'}")
print("提示：Guard 界面会因此变黄，这是正常的。" + ("全部通过。" if not failed else f"{failed} 项没通过。"))
sys.exit(bool(failed))
