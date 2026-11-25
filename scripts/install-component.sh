#!/bin/bash
# 安装隔离组件（需要 root）。用法：install-component.sh <二进制所在目录> <用户uid>
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
source_dir="${1:?缺少目录}"; owner="${2:?缺少用户 uid}"
[ "$(id -u)" = 0 ] || { echo "需要管理员权限"; exit 77; }
[[ "$owner" =~ ^[0-9]+$ ]] && [ "$owner" -ge 500 ] || { echo "用户 uid 无效"; exit 64; }
label=local.appnetworkguard.netd
target=/Library/PrivilegedHelperTools/AppNetworkGuard
state=/var/db/appnetworkguard
plist="/Library/LaunchDaemons/$label.plist"
for name in guardnetd guardrun guardshell guardrelay guardcheck; do [ -x "$source_dir/$name" ] || { echo "缺少 ${name}"; exit 66; }; done

# 受保护会话进行中不升级，避免替换时出现空档。
gid="$(dscl . -read /Groups/appnetguard PrimaryGroupID 2>/dev/null | awk '{print $2}' || true)"
if [ -n "$gid" ] && ps -ax -o gid= | awk -v g="$gid" '$1==g{found=1} END{exit !found}'; then
  echo "Claude 仍在保护中运行，请先退出它再安装"; exit 75
fi
launchctl bootout "system/$label" 2>/dev/null || true
rm -f /var/run/appnetworkguard/control.sock
if [ -z "$gid" ]; then
  dseditgroup -o create -r "Claude Network Guard" appnetguard
  gid="$(dscl . -read /Groups/appnetguard PrimaryGroupID | awk '{print $2}')"
fi
[ "$gid" -ge 100 ] || { echo "隔离组编号异常"; exit 70; }

install -d -o root -g wheel -m 755 "$target" "$state"
for name in guardnetd guardrelay guardcheck; do install -o root -g wheel -m 755 "$source_dir/$name" "$target/$name"; done
install -o root -g appnetguard -m 2755 "$source_dir/guardrun" "$target/guardrun"
for name in guardnetd guardrelay guardcheck guardrun; do
  xattr -c "$target/$name"
  codesign --force --sign - --identifier "local.appnetworkguard.$name" "$target/$name"
done
chown root:appnetguard "$target/guardrun"; chmod 2755 "$target/guardrun"
install -d -o root -g wheel -m 755 "$target/shell"
for name in zsh bash; do
  install -o root -g wheel -m 755 "$source_dir/guardshell" "$target/shell/$name"
  xattr -c "$target/shell/$name"
  codesign --force --sign - --identifier "local.appnetworkguard.guardshell" "$target/shell/$name"
done
printf '%s\n' "$owner" > "$state/owner"; chown root:wheel "$state/owner"; chmod 644 "$state/owner"

cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>$target/guardnetd</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>1</integer>
<key>AbandonProcessGroup</key><false/>
<key>StandardErrorPath</key><string>/var/log/appnetworkguard.log</string>
</dict></plist>
PLIST
chown root:wheel "$plist"; chmod 644 "$plist"
for attempt in 1 2 3 4 5 6 7 8; do
  launchctl bootstrap system "$plist" 2>/dev/null && break
  [ "$attempt" = 8 ] && { echo "守护进程未能启动"; exit 71; }
  sleep 0.5
done
for attempt in $(seq 1 20); do printf '{"command":"status"}\n' | nc -U -w 1 /var/run/appnetworkguard/control.sock 2>/dev/null | grep -q '"state"' && { echo "隔离组件已安装（组 ${gid}）"; exit 0; }; sleep 0.25; done
echo "守护进程没有响应，请查看 /var/log/appnetworkguard.log"; exit 71
