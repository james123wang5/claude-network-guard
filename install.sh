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
rm -rf "$target"
ditto "build/Claude Network Guard.app" "$target"
echo "接下来安装隔离组件，请输入这台 Mac 的登录密码："
sudo bash "$target/Contents/Resources/install-component.sh" "$target/Contents/MacOS" "$(id -u)"
# 旧名字的版本用同一份设置，装好新版后移除。
if [ -d "$old" ]; then rm -rf "$old"; echo "已移除旧版 App Network Guard，设置保留。"; fi
open "$target"
echo "安装完成。"
