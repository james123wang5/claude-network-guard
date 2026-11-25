#!/bin/bash
# 完整卸载，恢复系统原状。
set -euo pipefail
cd "$(dirname "$0")"
sudo bash scripts/uninstall-component.sh
rm -rf "/Applications/Claude Network Guard.app" "/Applications/App Network Guard.app"
echo "已卸载。个人设置保留在 ~/Library/Application Support/Claude Network Guard，可自行删除。"
