#!/bin/bash
# 在已生效的 USB 会话里开一个受保护的终端，之后在里面运行的程序（例如 claude 命令）都只走 USB。
set -euo pipefail
runner=/Library/PrivilegedHelperTools/AppNetworkGuard/guardrun
[ -x "$runner" ] || { echo "还没安装隔离组件"; exit 1; }
status="$(printf '{"command":"status"}\n' | nc -U -w 3 /var/run/appnetworkguard/control.sock || true)"
case "$status" in
  *'"state":"armed"'*) ;;
  *) echo "当前没有生效的 USB 会话。请先在 Claude Network Guard 里用 USB 启动 Claude。"; exit 1 ;;
esac
port="$(printf '%s' "$status" | sed -nE 's/.*"relayPort":([0-9]+).*/\1/p')"
[ -n "$port" ] || { echo "当前不是 USB 模式"; exit 1; }
echo "以下终端里的程序只走 USB；输入 exit 退出。"
GUARD_PROXY="$port" GUARD_CONFINE="" exec "$runner" /bin/zsh -i
