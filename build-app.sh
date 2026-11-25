#!/bin/bash
# 只需要 Xcode 命令行工具（xcode-select --install），不需要打开 Xcode，也不需要开发者账号。
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
bin="$(swift build -c release --show-bin-path)"
mkdir -p build
staging="$(mktemp -d "$PWD/build/.bundle.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
bundle="$staging/Claude Network Guard.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
for name in ClaudeNetworkGuard guardnetd guardrelay guardrun guardshell guardcheck guardwatch; do
  install -m 755 "$bin/$name" "$bundle/Contents/MacOS/$name"
done
install -m 644 Info.plist "$bundle/Contents/Info.plist"
install -m 644 assets/Guard.icns "$bundle/Contents/Resources/Guard.icns"
install -m 755 scripts/install-component.sh scripts/uninstall-component.sh "$bundle/Contents/Resources/"
for name in guardnetd guardrelay guardrun guardshell guardcheck guardwatch; do
  codesign --force --sign - --identifier "local.appnetworkguard.$name" "$bundle/Contents/MacOS/$name"
done
codesign --force --sign - "$bundle"
codesign --verify --strict --deep "$bundle"
destination="${GUARD_APP_DESTINATION:-build/Claude Network Guard.app}"
rm -rf "$destination"
/usr/bin/ditto "$bundle" "$destination"
echo "已生成 $destination"
