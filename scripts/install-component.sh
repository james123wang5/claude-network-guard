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
stage="$target.new"; previous="$target.old"
# 上次安装在切换目录的瞬间被打断（只剩旧版备份）：先把旧版放回原处。
if [ ! -d "$target" ] && [ -d "$previous" ]; then mv "$previous" "$target"; echo "发现上次安装被打断，已先恢复原来的组件"; fi
for name in guardnetd guardrun guardshell guardrelay guardcheck; do [ -x "$source_dir/$name" ] || { echo "缺少 ${name}"; exit 66; }; done

# 受保护会话进行中不升级，避免替换时出现空档。
gid="$(dscl . -read /Groups/appnetguard PrimaryGroupID 2>/dev/null | awk '{print $2}' || true)"
if [ -n "$gid" ] && ps -ax -o gid= | awk -v g="$gid" '$1==g{found=1} END{exit !found}'; then
  echo "Claude 仍在保护中运行，请先退出它再安装"; exit 75
fi
if [ -z "$gid" ]; then
  dseditgroup -o create -r "Claude Network Guard" appnetguard
  gid="$(dscl . -read /Groups/appnetguard PrimaryGroupID | awk '{print $2}')"
fi
[ "$gid" -ge 100 ] || { echo "隔离组编号异常"; exit 70; }

# 先把新版完整准备在旁边的目录里。这一步失败时旧组件完全没被动过，照常运行。
rm -rf "$stage"
trap 'rm -rf "$stage"' EXIT
install -d -o root -g wheel -m 755 "$stage" "$stage/shell" "$state"
for name in guardnetd guardrelay guardcheck; do install -o root -g wheel -m 755 "$source_dir/$name" "$stage/$name"; done
install -o root -g appnetguard -m 2755 "$source_dir/guardrun" "$stage/guardrun"
for name in guardnetd guardrelay guardcheck guardrun; do
  xattr -c "$stage/$name"
  codesign --force --sign - --identifier "local.appnetworkguard.$name" "$stage/$name"
done
chown root:appnetguard "$stage/guardrun"; chmod 2755 "$stage/guardrun"
for name in zsh bash; do
  install -o root -g wheel -m 755 "$source_dir/guardshell" "$stage/shell/$name"
  xattr -c "$stage/shell/$name"
  codesign --force --sign - --identifier "local.appnetworkguard.guardshell" "$stage/shell/$name"
done

# 准备好了才切换：停旧服务，整个目录换成新版，旧版留作回滚。
launchctl bootout "system/$label" 2>/dev/null || true
rm -f /var/run/appnetworkguard/control.sock
rm -rf "$previous"
if [ -d "$target" ]; then mv "$target" "$previous"; fi
mv "$stage" "$target"
trap - EXIT
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
start_daemon() {
  for attempt in 1 2 3 4 5 6 7 8; do
    launchctl bootstrap system "$plist" 2>/dev/null && break
    [ "$attempt" = 8 ] && return 1
    sleep 0.5
  done
  for attempt in $(seq 1 20); do
    printf '{"command":"status"}\n' | nc -U -w 1 /var/run/appnetworkguard/control.sock 2>/dev/null | grep -q '"state"' && return 0
    sleep 0.25
  done
  return 1
}
if start_daemon; then
  rm -rf "$previous"
  echo "隔离组件已安装（组 ${gid}）"; exit 0
fi
# 新版起不来：换回旧版并重新启动它。
launchctl bootout "system/$label" 2>/dev/null || true
rm -f /var/run/appnetworkguard/control.sock
if [ -d "$previous" ]; then
  rm -rf "$target"; mv "$previous" "$target"
  if start_daemon; then echo "新版组件没能启动，已恢复旧版组件。详情见 /var/log/appnetworkguard.log"; exit 72; fi
fi
echo "守护进程没有响应，请查看 /var/log/appnetworkguard.log，然后重新运行安装"; exit 71
