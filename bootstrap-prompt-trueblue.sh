#!/usr/bin/env bash
# bootstrap-prompt-trueblue.sh
# 作用：Bash 提示符 → 主机名绿色、目录真蓝(24-bit)，仅在交互式 shell 生效；幂等
set -euo pipefail
BASHRC="$HOME/.bashrc"
BEGIN="# >>> prompt-trueblue BEGIN >>>"
END="# <<< prompt-trueblue END <<<"
BLOCK='
# 主机名绿色，目录真蓝(24-bit)，仅在交互式 bash 生效
if [[ $- == *i* ]]; then
  PS1="\[\e[32m\]\u@\h \[\e[38;2;51;153;255m\]\w\[\e[0m\]\$ "
fi
'
# 删除旧块（若存在）
if [[ -f "$BASHRC" ]] && grep -qF "$BEGIN" "$BASHRC"; then
  awk -v b="$BEGIN" -v e="$END" '$0==b{skip=1;next}$0==e{skip=0;next}!skip{print}' \
    "$BASHRC" > "${BASHRC}.tmp" && mv "${BASHRC}.tmp" "$BASHRC"
fi
# 追加新块
{ echo "$BEGIN"; printf "%s\n" "$BLOCK"; echo "$END"; } >> "$BASHRC"
# 立即生效（当前为交互式 bash 时）
source "$BASHRC" || true
echo "✅ Bash 提示符已配置：主机名绿色、目录真蓝(24-bit)。"
