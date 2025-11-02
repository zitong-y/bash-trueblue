#!/usr/bin/env bash
# 作用：在 ~/.bashrc 里追加一行注释 + 一行 PS1（主机名绿色、目录真蓝 24-bit），幂等。
set -euo pipefail

RC="$HOME/.bashrc"
MARK="# trueblue prompt: hostname green, dir true-blue (24-bit), interactive-only"
LINE="[[ \$- == *i* ]] && PS1='\\[\\e[32m\\]\\u@\\h \\[\\e[38;2;51;153;255m\\]\\w\\[\\e[0m\\]\\$ '"

touch "$RC"
grep -qF "$MARK" "$RC" || { echo "$MARK" >> "$RC"; echo "$LINE" >> "$RC"; }

# 仅在当前就是交互式 Bash 时立即生效
if [[ $- == *i* ]]; then
  # shellcheck disable=SC1090
  source "$RC"
fi

echo "✅ 写入完成：$LINE"
echo "✅ Bash 提示符已配置：主机名绿色、目录真蓝(24-bit)。"

