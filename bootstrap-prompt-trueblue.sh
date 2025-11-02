#!/usr/bin/env bash
# 作用：在 ~/.bashrc 中追加“一行注释 + 一行 PS1”，配置“用户名/主机名为绿色、目录真蓝(24-bit)”，仅交互式 bash 生效；幂等。
set -euo pipefail

RC="$HOME/.bashrc"
MARK="# trueblue prompt: 配置用户名/主机名为绿色，目录真蓝（24-bit），仅交互式生效"
LINE="[[ \$- == *i* ]] && PS1='\\[\\e[32m\\]\\u@\\h \\[\\e[38;2;51;153;255m\\]\\w\\[\\e[0m\\]\\$ '"

touch "$RC"
if ! grep -qF "$MARK" "$RC"; then
  {
    echo "$MARK"
    echo "$LINE"
  } >> "$RC"
fi

# 无条件尝试刷新当前环境
# shellcheck disable=SC1090
source "$RC" || true

# 若当前就是交互式 Bash，再次刷新以便尽量立刻可见
if [[ $- == *i* ]]; then
  # shellcheck disable=SC1090
  source "$RC" || true
fi

echo "✅ 已写入：$RC"
echo "✅ Bash 提示符已配置：主机名绿色、目录真蓝(24-bit)。"
echo "ℹ️ 如未立即生效，在当前终端手动执行：source ~/.bashrc 或运行：exec bash"
