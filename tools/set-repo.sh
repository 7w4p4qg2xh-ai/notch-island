#!/bin/bash
# 把源码里的仓库占位符 OWNER 换成真实 GitHub 用户名
#
# 用法：
#   ./tools/set-repo.sh yourname
#   ./tools/set-repo.sh yourname --dry-run
#
# 影响 4 处：设置页「关于」的 GitHub 与「报告 Bug」按钮、扩展菜单里的项目链接、
# issue 模板 config.yml 的安全报告链接。改完记得重新编译，否则 app 内仍是旧地址。
set -uo pipefail

if [[ $# -lt 1 ]]; then
    echo "用法：$0 <github-username> [--dry-run]" >&2
    exit 2
fi

OWNER="$1"
DRY=0
[[ "${2:-}" == "--dry-run" ]] && DRY=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

if ! [[ "$OWNER" =~ ^[A-Za-z0-9-]+$ ]]; then
    echo "用户名只能含字母、数字和连字符：$OWNER" >&2
    exit 2
fi

FILES=(
    "boringNotch/components/Notch/BoringExtrasMenu.swift"
    "boringNotch/components/Settings/Views/AboutView.swift"
    ".github/ISSUE_TEMPLATE/config.yml"
)

TOTAL=0
for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || { echo "跳过（不存在）：$f"; continue; }
    n=$(grep -c "github.com/OWNER/notch-island" "$f" || true)
    if [[ "$n" -eq 0 ]]; then
        echo "无需改动：$f"
        continue
    fi
    TOTAL=$((TOTAL + n))
    if [[ $DRY -eq 1 ]]; then
        echo "将改 $n 处：$f"
    else
        sed -i '' "s|github.com/OWNER/notch-island|github.com/${OWNER}/notch-island|g" "$f"
        echo "已改 $n 处：$f"
    fi
done

if [[ $DRY -eq 1 ]]; then
    echo "共 $TOTAL 处待改（dry-run，未写入）"
else
    echo "共 $TOTAL 处已指向 github.com/${OWNER}/notch-island"
    echo
    echo "提醒：这些是编译进 app 的字符串，改完要重新编译才生效。"
fi
