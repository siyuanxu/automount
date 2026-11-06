#!/bin/bash
# 重新生成 AppIcon.icns（默认 azure；可传 ocean / night）
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
THEME="${1:-azure}"
PYTHON="${PYTHON:-}"

if [ -z "$PYTHON" ]; then
    for cand in python3 /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
        if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import PIL, numpy" >/dev/null 2>&1; then
            PYTHON="$cand"
            break
        fi
    done
fi

if [ -z "$PYTHON" ]; then
    echo "错误：找不到带 Pillow + numpy 的 python3（可用 PYTHON=/path/to/python3 指定）"
    exit 1
fi

"$PYTHON" "$DIR/generate_icons.py" --out "$DIR/preview" --final "$THEME"
cp "$DIR/AppIcon.icns" "$DIR/../Resources/AppIcon.icns"
echo "已更新 ${DIR}/AppIcon.icns 与 Resources/AppIcon.icns（主题：${THEME}）"
