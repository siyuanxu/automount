#!/bin/bash
# 卸载：停止登录启动项、退出 App、移除 App（可选用 --purge 删除配置和日志）
set -euo pipefail

APP_NAME="AutoMount"
TARGET="$HOME/Applications/$APP_NAME.app"
BIN="$TARGET/Contents/MacOS/$APP_NAME"
LABEL="io.github.siyuanxu.automount"
DOMAIN="gui/$(id -u)"
SUPPORT_DIR="$HOME/Library/Application Support/$APP_NAME"
LOG_DIR="$HOME/Library/Logs/$APP_NAME"

echo "==> 停止 App"
pkill -f "$BIN" 2>/dev/null || true

echo "==> 移除桌面入口"
if [ -x "$BIN" ]; then
    "$BIN" --remove-desktop-alias >/dev/null 2>&1 || true
fi

echo "==> 移除登录启动项"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> 移除 App"
rm -rf "$TARGET"

if [ "${1:-}" = "--purge" ]; then
    echo "==> 删除配置和日志"
    rm -rf "$SUPPORT_DIR" "$LOG_DIR"
fi

echo
echo "✅ 已卸载。"
echo "提示：如果共享文件夹仍挂载在 /Volumes 下，可在 Finder 中手动推出。"
