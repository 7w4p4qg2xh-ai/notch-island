#!/bin/bash
# 构建 Release 版 Notch Island 并（可选）安装到 /Applications
#
# 用法：
#   ./tools/build-release.sh              # 编译 + 装到 /Applications/Notch Island.app
#   ./tools/build-release.sh --no-install # 只编译，产物留在 build/Products/Release
#
# 为什么不用 Xcode 里的 Run：本仓库没有开发者 Team，Xcode 的签名流程会直接报
# "requires a development team"。正确做法是先用 ad-hoc 身份编出来，编完再用
# 本机的 BoringNotchLocal 自签证书重签——TCC（屏幕录制/辅助功能）绑的是证书
# 而不是 cdhash，所以重编不会让你重新授权。
#
# 注意：脚本必须在你的终端里跑，Agent 沙箱里跑不了 xcodebuild。
set -uo pipefail

WS="$(cd "$(dirname "$0")/.." && pwd)"
cd "$WS" || exit 1

APP_NAME="Notch Island"
SIGN_ID="BoringNotchLocal"
INSTALL=1
DEST="/Applications/$APP_NAME.app"
OUT_DIR="$WS/build/Products/Release"
APP="$OUT_DIR/$APP_NAME.app"

for a in "$@"; do
    case "$a" in
        --no-install) INSTALL=0 ;;
        *) echo "未知参数：$a" >&2; exit 2 ;;
    esac
done

# ── 证书：没有就退回 ad-hoc，并说清楚代价 ───────────────────────────
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "=== 签名身份：$SIGN_ID ==="
else
    SIGN_ID="-"
    echo "=== 警告：找不到 $SIGN_ID 证书，回退 ad-hoc 签名 ==="
    echo "    代价：每次重编后系统都会当成新程序，屏幕录制与辅助功能要重新授权。"
fi

# ── 编译：ad-hoc 签着编，避免 Team 检查 ─────────────────────────────
echo "=== 编译（Release，约 1-3 分钟）==="
xcodebuild \
    -project boringNotch.xcodeproj \
    -target boringNotch \
    -configuration Release \
    SYMROOT="$WS/build/Products" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGNING_ALLOWED=YES \
    build 2>&1 | tail -20

rc=${PIPESTATUS[0]}
echo "=== xcodebuild rc=$rc ==="
if [[ $rc -ne 0 ]]; then
    echo "编译失败，上面是最后 20 行。完整日志可用 -quiet 之外的方式重跑。"
    exit $rc
fi

if [[ ! -d "$APP" ]]; then
    echo "找不到产物：$APP" >&2
    exit 1
fi

[[ $INSTALL -eq 0 ]] && { echo "=== 只编译完成：$APP ==="; exit 0; }

# ── 安装 ────────────────────────────────────────────────────────────
echo "=== 退出正在运行的 $APP_NAME ==="
osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null
pkill -x "$APP_NAME" 2>/dev/null
sleep 2

mkdir -p "$(dirname "$DEST")"
ditto "$APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null

# ── 重签 ────────────────────────────────────────────────────────────
# 内嵌框架原本是官方 Team ID 签的，跟主程序不匹配会启动崩溃，必须全部重签。
# 不能用 --deep：它会穿过 Sparkle 的 Versions/Current 符号链接把封条签坏
# （"nested code is modified or invalid"），必须按真实路径从内到外逐层签。
echo "=== 重签（$SIGN_ID）==="
find "$DEST" -name "*.cstemp*" -delete 2>/dev/null

find "$DEST/Contents/Frameworks" -type f -perm -111 2>/dev/null | while read -r f; do
    codesign --force --sign "$SIGN_ID" "$f" >/dev/null 2>&1
done

find "$DEST" -depth -type d \
    \( -name "*.framework" -o -name "*.xpc" -o -name "*.app" -o -name "*.bundle" -o -name "*.appex" \) \
    2>/dev/null | while read -r f; do
    codesign --force --sign "$SIGN_ID" "$f" >/dev/null 2>&1
done

codesign --force --sign "$SIGN_ID" "$DEST" 2>&1 | head -3
codesign --verify --deep --strict "$DEST"
echo "=== 签名校验 rc=$? ==="

echo
echo "=== 完成：$DEST ==="
echo "首次启动后要授权两处，否则玻璃和通知都不会工作："
echo "  系统设置 → 隐私与安全性 → 屏幕录制   → 勾选 $APP_NAME"
echo "  系统设置 → 隐私与安全性 → 辅助功能   → 勾选 $APP_NAME"
echo "授权后必须退出重开一次程序（TCC 只在重启后生效）。"
