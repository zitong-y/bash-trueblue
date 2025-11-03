#!/usr/bin/env bash
set -euo pipefail

# ========== 配置区（可按需替换每个分支里的命令） ==========
# 下面以“给不同壳追加 Starship 初始化语句”为例做 payload。
# 你可以把每个 run_for_* 函数里的命令换成你自己的动作。

log()  { printf "[*] %s\n" "$*"; }
warn() { printf "[!] %s\n" "$*" >&2; }

backup_once(){ [[ -f "$1" ]] && cp -p "$1" "$1.bak-$(date +%Y%m%d-%H%M%S)" || true; }
ensure_line(){  # ensure_line <file> <exact line>
  local f="$1"; shift; local line="$*"
  mkdir -p "$(dirname "$f")"; [[ -f "$f" ]] || touch "$f"
  if ! grep -Fqx "$line" "$f" 2>/dev/null; then
    backup_once "$f"
    printf "%s\n" "$line" >> "$f"
    log "Appended to $f"
  else
    log "Already present: $f"
  fi
}

# 让登录 shell 同样读取 rc（避免 login shell 不读 .bashrc/.zshrc）
ensure_login_reads_rc_bash(){
  local t="$HOME/.bash_profile"; [[ -f "$HOME/.profile" ]] && t="$HOME/.profile"
  ensure_line "$t" '[ -n "$BASH_VERSION" ] && [ -f ~/.bashrc ] && . ~/.bashrc'
}
ensure_login_reads_rc_zsh(){
  # 大多默认会读 ~/.zshrc，这里兜底让 ~/.zprofile source 一下
  ensure_line "$HOME/.zprofile" '[ -f ~/.zshrc ] && . ~/.zshrc'
}

# ---- 每种壳要做的事（示例：写入 starship init） ----
run_for_bash(){
  ensure_line "$HOME/.bashrc" 'eval "$(starship init bash)"'
  ensure_login_reads_rc_bash
  # 你也可以在这加别的命令，比如导出环境变量、alias 等
  log "Reloading bash: source ~/.bashrc"
  . "$HOME/.bashrc" 2>/dev/null || true
}

run_for_zsh(){
  ensure_line "$HOME/.zshrc" 'eval "$(starship init zsh)"'
  ensure_login_reads_rc_zsh
  log "Reloading zsh : source ~/.zshrc"
  . "$HOME/.zshrc" 2>/dev/null || true
}

run_for_fish(){
  ensure_line "$HOME/.config/fish/config.fish" 'starship init fish | source'
  log "Reloading fish: exec fish -l"
  exec fish -l
}

run_for_elvish(){ ensure_line "$HOME/.elvish/rc.elv" 'eval (starship init elvish)' ; }
run_for_tcsh(){   ensure_line "$HOME/.tcshrc"        'eval `starship init tcsh`' ; }
run_for_nu(){     # Nushell：先生成 init 脚本再在 config.nu 里 source
  mkdir -p "$HOME/.cache/starship"
  starship init nu > "$HOME/.cache/starship/init.nu"
  ensure_line "$HOME/.config/nushell/config.nu" 'source ~/.cache/starship/init.nu'
}
run_for_xonsh(){
  ensure_line "$HOME/.xonshrc" '$STARSHIP_INIT = !("starship init xonsh")'
  ensure_line "$HOME/.xonshrc" 'execx($STARSHIP_INIT)'
  ensure_line "$HOME/.xonshrc" 'del $STARSHIP_INIT'
}
run_for_ion(){    ensure_line "$HOME/.config/ion/initrc" 'eval $(starship init ion)' ; }

# ========== 壳检测：父进程交互壳 > 登录壳 > 运行时壳 > $SHELL ==========
FORCE_SHELL="${FORCE_SHELL:-${STARSHIP_FORCE_SHELL:-}}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --shell) FORCE_SHELL="$2"; shift 2;;
    -h|--help)
      cat <<'EOF'
Usage: bash ./shell_router.sh [--shell bash|zsh|fish|elvish|tcsh|nu|xonsh|ion]

作用：这个脚本总是用 bash 执行，但会自动检测你本来在用的交互壳，
然后调用相应分支（示例是为不同壳写入 starship init）。
可用 --shell 或环境变量 FORCE_SHELL 覆盖自动检测。
EOF
      exit 0;;
    *) echo "Unknown option: $1"; exit 2;;
  esac
done

detect_current_shell() {
  # ① 登录壳（/etc/passwd）
  local login_shell=""
  if command -v getent >/dev/null 2>&1; then
    login_shell="$(getent passwd "$(id -un)" | awk -F: '{print $NF}' | xargs basename)"
  else
    login_shell="$(awk -F: -v u="$(id -un)" '$1==u{print $NF}' /etc/passwd | xargs basename)"
  fi

  # ② 父进程链上的交互壳（避免 curl … | bash 误判）
  local ppid name shell_in_ppid=""
  ppid="$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')"
  while [[ -n "$ppid" && "$ppid" != "1" ]]; do
    name="$(ps -p "$ppid" -o comm= 2>/dev/null | xargs basename | tr '[:upper:]' '[:lower:]')"
    case "$name" in
      bash|zsh|fish|elvish|tcsh|csh|nu|nushell|xonsh|ion)
        shell_in_ppid="$name"; break;;
    esac
    ppid="$(ps -o ppid= -p "$ppid" 2>/dev/null | tr -d ' ')"
  done

  # ③ 运行时壳 & 环境
  local run_shell env_shell
  run_shell="$(ps -p $$ -o comm= 2>/dev/null | xargs basename | tr '[:upper:]' '[:lower:]')"
  env_shell="$(basename "${SHELL:-}" 2>/dev/null | tr '[:upper:]' '[:lower:]')"

  local s="${shell_in_ppid:-${login_shell:-${run_shell:-$env_shell}}}"
  s="${s#-}"; s="${s,,}"
  case "$s" in
    csh)  s="tcsh" ;;
    nushell) s="nu" ;;
  esac
  case "$s" in
    bash|zsh|fish|elvish|tcsh|nu|xonsh|ion) printf "%s" "$s" ;;
    *) printf "sh" ;;  # 不支持的壳
  esac
}

main() {
  local cur="${FORCE_SHELL:-$(detect_current_shell)}"
  log "Detected current shell: ${cur}${FORCE_SHELL:+ (forced)}"

  case "$cur" in
    bash)  run_for_bash  ;;
    zsh)   run_for_zsh   ;;
    fish)  run_for_fish  ;;
    elvish)run_for_elvish;;
    tcsh)  run_for_tcsh  ;;
    nu)    run_for_nu    ;;
    xonsh) run_for_xonsh ;;
    ion)   run_for_ion   ;;
    sh)    warn "This shell (sh/dash) is not supported by Starship. Skipped." ;;
    *)     warn "Unknown shell: $cur" ;;
  esac

  echo "✅ Done (shell: $cur)"
}
main
