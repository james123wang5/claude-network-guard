#!/bin/bash
# 故障验收（root）：faults.sh <用户名> <输出文件>。覆盖守护进程/转发器崩溃、防火墙被关、USB 掉线，并抓包。
set -u
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
cd "$(dirname "$0")/.."; USER_NAME="${1:?}"; OUT="${2:?}"; : > "$OUT"; chmod 666 "$OUT"
log() { echo "$*" >> "$OUT"; }
R=/Library/PrivilegedHelperTools/AppNetworkGuard/guardrun
U() { sudo -u "$USER_NAME" "$@"; }
N() { U /usr/bin/python3 "$PWD/acceptance/netd.py" "$@" 2>/dev/null; }
ST() { N status | sed -E 's/.*"state": "([a-z]+)".*/\1/'; }
RE() { N status | sed -nE 's/.*"reason": "([a-z_]+)".*/\1/p'; }
IPOF() { grep -oE 'ip=[0-9.]+' | head -1 | cut -c4-; }
CONTROL() { curl -4 -q -s -m 8 https://1.1.1.1/cdn-cgi/trace | IPOF; }
USB="$(networksetup -listallhardwareports | awk '/Hardware Port: iPhone USB/{getline;print $2}')"; DEF="$(route -n get 1.1.1.1 | awk '/interface:/{print $2}')"
E_DEF="$(CONTROL)"; E_USB="$(curl -4 -q -s -m 8 --interface "if!${USB}" https://1.1.1.1/cdn-cgi/trace | IPOF)"
PASS=0; FAIL=0
ok() { if [ "$2" = 1 ]; then PASS=$((PASS+1)); log "通过 $1 ${3:-}"; else FAIL=$((FAIL+1)); log "失败 $1 ${3:-}"; fi; }
DUMP=/tmp/guard-fault.pcap; rm -f "$DUMP"; tcpdump -i "$DEF" -n -U -w "$DUMP" 2>/dev/null & TD=$!
trap 'pkill -9 -f guard-fault.pcap; ifconfig "$USB" up; N terminate >/dev/null; rm -f "$DUMP" /tmp/guard-hold.py; log "共通过 ${PASS} 失败 ${FAIL}"; log END' EXIT
log "USB ${USB} ${E_USB}  默认 ${DEF} ${E_DEF}"
cat > /tmp/guard-hold.py <<'P'
# 受保护组内的持续探针：每 0.15 秒尝试一次新连接，只连 1.0.0.2（测试专用目标），记录公网看到的来源。
import socket, ssl, sys, time
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
end = time.time() + float(sys.argv[1])
while time.time() < end:
    try:
        s = socket.create_connection(("1.0.0.2", 443), 1.5); t = ctx.wrap_socket(s, server_hostname="cloudflare-dns.com")
        t.settimeout(1.5); t.sendall(b"GET /cdn-cgi/trace HTTP/1.1\r\nHost: cloudflare-dns.com\r\nConnection: close\r\n\r\n"); d = b""
        while True:
            p = t.recv(4096)
            if not p: break
            d += p
        print([l for l in d.decode().split() if l.startswith("ip=")][0][3:], flush=True); t.close()
    except Exception as e: print("ERR", getattr(e, "errno", None), flush=True)
    time.sleep(0.15)
P
chmod 644 /tmp/guard-hold.py
hold() { U env GUARD_CONFINE= $R /usr/bin/python3 /tmp/guard-hold.py "$1" > /tmp/guard-hold.$2 2>&1 & HP=$!; sleep 2; }
result() { # 统计探针：USB / 默认 / 失败次数
  wait $HP 2>/dev/null; echo "USB=$(grep -c "^${E_USB}\$" /tmp/guard-hold.$1) 默认=$(grep -c "^${E_DEF}\$" /tmp/guard-hold.$1) 失败=$(grep -c ERR /tmp/guard-hold.$1)"; }
leak() { tcpdump -n -r "$DUMP" host 1.0.0.2 2>/dev/null | wc -l | tr -d ' '; }
arm() { N arm "$USB" claude.ai -dns > /dev/null; [ "$(ST)" = armed ]; }

arm; ok "F0 生效" $([ "$(ST)" = armed ] && echo 1 || echo 0)
L0=$(leak); hold 8 1; pkill -9 -x guardnetd; sleep 0.3; C=$(CONTROL); sleep 3; S=$(ST); X=$(RE); RESULT=$(result 1); L1=$(leak)
ok "F1 强杀守护进程：自动重启并转为断网" $([ "$S" = blocked ] && echo 1 || echo 0) "[$S/$X]"
ok "F1 期间没有走默认线路" $([ "$L1" = "$L0" ] && [ "${RESULT#*默认=0}" != "$RESULT" ] && echo 1 || echo 0) "[$RESULT en0包=$((L1-L0))]"
ok "F1 期间其他应用正常" $([ "$C" = "$E_DEF" ] && echo 1 || echo 0)
N terminate >/dev/null; arm; L0=$(leak); hold 7 2; pkill -9 -x guardrelay; sleep 2; S=$(ST); X=$(RE); RESULT=$(result 2); L1=$(leak)
ok "F2 转发器崩溃：转为断网" $([ "$S" = blocked ] && echo 1 || echo 0) "[$S/$X]"; ok "F2 没有走默认线路" $([ "$L1" = "$L0" ] && echo 1 || echo 0) "[$RESULT en0包=$((L1-L0))]"
N terminate >/dev/null; arm; L0=$(leak); hold 9 3; ifconfig "$USB" down; sleep 1; S=$(ST); X=$(RE); C=$(CONTROL); sleep 2; ifconfig "$USB" up
for i in 1 2 3 4 5 6 7 8 9 10; do [ -n "$(ipconfig getifaddr "$USB")" ] && break; sleep 1; done; sleep 1; S2=$(ST); RESULT=$(result 3); L1=$(leak)
ok "F3 USB 掉线：1 秒内转为断网" $([ "$S" = blocked ] && echo 1 || echo 0) "[$S/$X]"; ok "F3 没有走默认线路" $([ "$L1" = "$L0" ] && echo 1 || echo 0) "[$RESULT en0包=$((L1-L0))]"
ok "F3 掉线期间其他应用正常" $([ "$C" = "$E_DEF" ] && echo 1 || echo 0); ok "F3 重新连上不会自动恢复" $([ "$S2" = blocked ] && echo 1 || echo 0) "[$S2]"
N terminate >/dev/null; arm; L0=$(leak); hold 9 4; pfctl -q -a com.apple/300.AppNetworkGuard -F rules; sleep 4; S=$(ST); RESULT=$(result 4); L1=$(leak)
ok "F4 规则被其他程序清空：立即断网并报告" $([ "$S" = blocked ] && [ "$(RE)" = rules_tampered ] && pfctl -a com.apple/300.AppNetworkGuard -sr 2>/dev/null | grep -q 'block return out quick all group' && echo 1 || echo 0) "[$RESULT 空窗期en0包=$((L1-L0))]"
N terminate >/dev/null; arm; L0=$(leak); hold 9 5; pfctl -q -d; sleep 4; S=$(ST); RESULT=$(result 5); L1=$(leak)
ok "F5 防火墙被整体关闭：立即断网并报告" $([ "$S" = blocked ] && pfctl -s info 2>/dev/null | grep -q 'Status: Enabled' && echo 1 || echo 0) "[$RESULT 空窗期en0包=$((L1-L0))]"
N terminate >/dev/null
[ "${3:-}" = quick ] || U /usr/bin/python3 "$PWD/acceptance/usb.py" --claude --pcap-file "$DUMP" >> "$OUT" 2>&1
ok "F6 结束后空闲" $([ "$(ST)" = idle ] && echo 1 || echo 0); ok "F6 锚点已清空" $([ -z "$(pfctl -a com.apple/300.AppNetworkGuard -sr 2>/dev/null)" ] && echo 1 || echo 0)
