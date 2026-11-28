#!/bin/bash
# 一键安装：编译 → 放进「应用程序」→ 安装隔离组件（会要求输入一次管理员密码）。
# 只需要 Xcode 命令行工具，不需要打开 Xcode，也不需要开发者账号。
set -euo pipefail
cd "$(dirname "$0")"
if ! xcode-select -p >/dev/null 2>&1; then
  echo "需要先安装命令行工具，正在弹出安装窗口。装完后再运行一次本脚本。"
  xcode-select --install || true
  exit 1
fi
[ "$(id -u)" != 0 ] || { echo "请不要用 sudo 运行本脚本"; exit 1; }
if pgrep -f "Network Guard.app/Contents/MacOS/(App|Claude)NetworkGuard" >/dev/null; then echo "请先退出 Guard（菜单栏的盾牌 → 退出）"; exit 1; fi
if ps -ax -o gid= | awk -v g="$(dscl . -read /Groups/appnetguard PrimaryGroupID 2>/dev/null | awk '{print $2}')" 'g!="" && $1==g{found=1} END{exit !found}'; then echo "Claude 还在保护中运行，请先停止并退出它"; exit 1; fi
./build-app.sh
target="/Applications/Claude Network Guard.app"
old="/Applications/App Network Guard.app"
# 先拿到管理员授权再动「应用程序」：取消授权时什么都不改。
echo "接下来安装隔离组件，请输入这台 Mac 的登录密码："
sudo -v || { echo "没有拿到授权，什么都没有改。"; exit 1; }
backup=""
if [ -d "$target" ]; then backup="$(mktemp -d)/previous.app"; ditto "$target" "$backup"; fi
# 被 Ctrl-C 或关掉终端打断时，把原来的 App 放回去（组件脚本下次运行会自行修复半途的切换）。
restore_app() {
  if [ -n "$backup" ] && [ -d "$backup" ]; then rm -rf "$target"; ditto "$backup" "$target"; echo "安装被中断，已把 Guard 恢复成原来的版本。"; fi
}
trap 'restore_app; exit 130' INT TERM HUP
rm -rf "$target"
ditto "build/Claude Network Guard.app" "$target"
if ! sudo bash "$target/Contents/Resources/install-component.sh" "$target/Contents/MacOS" "$(id -u)"; then
  # 组件脚本失败时会保留或换回旧组件；App 也换回旧版，保持前后台一致。
  if [ -n "$backup" ]; then
    rm -rf "$target"; ditto "$backup" "$target"
    echo "没有装好，已把 Guard 恢复成原来的版本。"
  else
    echo "没有装好。打开 Guard 后可在「设置」里重新安装组件。"
  fi
  exit 1
fi
trap - INT TERM HUP
if [ -n "$backup" ]; then rm -rf "$(dirname "$backup")"; fi
# 旧名字的版本用同一份设置，装好新版后移除。
# 系统按标识找图标和通知，同标识的副本只能留一份，否则通知会显示旧图标。
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for copy in "$old" "$PWD/build/Claude Network Guard.app" "$PWD/build/App Network Guard.app"; do
  "$lsregister" -u "$copy" >/dev/null 2>&1 || true
done
rm -rf "build/Claude Network Guard.app"
"$lsregister" -f "$target" || true
if [ -d "$old" ]; then
  rm -rf "$old"; echo "已移除旧版 App Network Guard，设置保留。"
  killall NotificationCenter 2>/dev/null || true  # 系统会自动重开，让通知换上新图标
fi
open "$target"
echo "安装完成。"
