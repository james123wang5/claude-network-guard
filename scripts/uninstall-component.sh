#!/bin/bash
# 完整移除隔离组件（需要 root）：规则、守护进程、DNS 配置、隔离组。
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
[ "$(id -u)" = 0 ] || { echo "需要管理员权限"; exit 77; }
label=local.appnetworkguard.netd
gid="$(dscl . -read /Groups/appnetguard PrimaryGroupID 2>/dev/null | awk '{print $2}')"
if [ -n "$gid" ] && ps -ax -o gid= | awk -v g="$gid" '$1==g{found=1} END{exit !found}'; then
  echo "受保护的应用仍在运行，请先退出它再卸载"; exit 75
fi
# 守护进程收到停止信号前先撤销会话（含 DNS 还原）
printf '{"command":"release"}\n' | nc -U -w 2 /var/run/appnetworkguard/control.sock >/dev/null 2>&1
launchctl bootout "system/$label" 2>/dev/null
pkill -f /Library/PrivilegedHelperTools/AppNetworkGuard/guardrelay 2>/dev/null
for part in rules nat; do for anchor in 300.AppNetworkGuard 301.AppNetworkGuardSockets 302.AppNetworkGuardService; do pfctl -q -a "com.apple/${anchor}" -F "$part" 2>/dev/null; done; done
left=""
for anchor in 300.AppNetworkGuard 301.AppNetworkGuardSockets 302.AppNetworkGuardService; do
  [ -n "$(pfctl -a "com.apple/${anchor}" -sr 2>/dev/null)$(pfctl -a "com.apple/${anchor}" -sn 2>/dev/null)" ] && left="$left $anchor"
done
for file in /etc/resolver/*; do [ -f "$file" ] && head -1 "$file" | grep -q '^# App Network Guard' && rm -f "$file"; done
[ -f /var/db/appnetworkguard/tso.saved ] && sysctl -w net.inet.tcp.tso="$(cat /var/db/appnetworkguard/tso.saved)" >/dev/null
rmdir /etc/resolver 2>/dev/null
rm -f "/Library/LaunchDaemons/$label.plist" /var/log/appnetworkguard.log
rm -rf /Library/PrivilegedHelperTools/AppNetworkGuard /var/db/appnetworkguard /var/run/appnetworkguard
[ -n "$gid" ] && dseditgroup -o delete appnetguard
if [ -n "$left" ]; then
  echo "隔离组件的文件已移除，但这些防火墙规则没能清除：$left"
  echo "请重启电脑（重启后规则会自动消失），然后再运行一次卸载确认。"
  exit 1
fi
echo "隔离组件已移除，系统网络恢复原状"
