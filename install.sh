#!/bin/bash
# 一键安装：构建 → 安装到 ~/Applications → 配置 → 登录启动项 → 验证
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="AutoMount"
TARGET_DIR="$HOME/Applications"
TARGET="$TARGET_DIR/$APP_NAME.app"
BIN="$TARGET/Contents/MacOS/$APP_NAME"
LABEL="io.github.siyuanxu.automount"
DOMAIN="gui/$(id -u)"
SUPPORT_DIR="$HOME/Library/Application Support/$APP_NAME"
STATUS_FILE="$SUPPORT_DIR/status.json"
CONFIG_FILE="$SUPPORT_DIR/config.json"
LOG_FILE="$HOME/Library/Logs/$APP_NAME/$APP_NAME.log"

echo "==> 0/5 环境检查"
if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "错误：未找到 swiftc，请先安装 Xcode 或 Command Line Tools"
    exit 1
fi
if [ ! -f "$DIR/Resources/Info.plist" ]; then
    echo "错误：缺少 Resources/Info.plist"
    exit 1
fi

echo "==> 1/5 构建"
"$DIR/build.sh"

echo "==> 2/5 安装到 $TARGET"
mkdir -p "$TARGET_DIR"
pkill -f "$TARGET/Contents/MacOS/$APP_NAME" 2>/dev/null || true
pkill -f "$DIR/build/$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
sleep 0.5
rm -rf "$TARGET"
ditto "$DIR/build/$APP_NAME.app" "$TARGET"
codesign --verify --strict "$TARGET" >/dev/null 2>&1 || {
    echo "错误：安装后的 App 签名校验失败"
    exit 1
}

echo "==> 3/5 初始化配置"
"$BIN" --init >/dev/null

echo "==> 4/5 安装登录启动项（首次运行如弹出“定位”授权，请点“允许”）"
"$BIN" --install-agent >/dev/null

echo "==> 5/5 等待自动检测（最多 40 秒）"
READY=0
for _ in $(seq 1 40); do
    if [ -f "$STATUS_FILE" ]; then
        AGE=$(( $(date +%s) - $(stat -f %m "$STATUS_FILE") ))
        if [ "$AGE" -lt 20 ]; then
            READY=1
            break
        fi
    fi
    sleep 1
done

echo
if [ "$READY" -eq 0 ]; then
    echo "⚠️  等待超时，没有收到 App 的状态。最近日志："
    tail -20 "$LOG_FILE" 2>/dev/null || true
    exit 1
fi

"$BIN" --status

MOUNTED=0
if [ -f "$STATUS_FILE" ] && grep -q '"mounted" *: *true' "$STATUS_FILE"; then
    MOUNTED=1
fi

echo
if [ "$MOUNTED" -eq 1 ]; then
    echo "✅ 安装完成：共享文件夹已挂载。"
else
    echo "ℹ️  App 已在运行，但当前尚未挂载。"
    echo "    请打开菜单栏「AutoMount」图标查看状态，或编辑配置：$CONFIG_FILE"
fi
if grep -q '"serverConfigured" *: *false' "$STATUS_FILE" 2>/dev/null; then
    echo "下一步：编辑配置里的 server 字段（例如 smb://server/share）。"
    echo "        App 已自动记录当前定位和 Wi-Fi 作为触发条件。"
fi
echo
echo "配置文件：$CONFIG_FILE"
echo "日志文件：$LOG_FILE"
