#!/usr/bin/env bash
set -euo pipefail

# Starship installer/configurator (Unix/macOS/WSL)
# - 优先包管理器，失败回退官方脚本（自动同意）
# - 永远只配置“当前 shell”
# - 不覆盖已有 ~/.config/starship.toml（若存在先备份再保留；若不存在则新建）
# - 若需开启耗时显示，传参：--enable-duration

ENABLE_DURATION=0
if [[ "${1:-}" == "--enable-duration" ]]; then ENABLE_DURATION=1; fi

log()  { printf "[*] %s\n" "$*"; }
warn() { printf "[!] %s\n" "$*" >&2; }

# sudo 帮手（无 sudo 或已是 root 就为空）
SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi
fi

# -------- 只配置“当前 shell” --------
detect_current_shell() {
  local args comm envs s=""
  args="$(ps -p $$ -o args= 2>/dev/null || true)"
  [[ -r /proc/$$/comm ]] && comm="$(tr -d '[:space:]' < /proc/$$/comm)" || comm=""
  envs="${SHELL:-}"

  if [[ -n "$args" ]]; then s="${args##* }"; s="${s##*/}"
  elif [[ -n "$comm" ]]; then s="${comm##*/}"
  elif [[ -n "$envs" ]]; then s="${envs##*/}"; fi

  s="${s#-}"; s="${s,,}"
  case "$s" in
    bash|zsh|fish|elvish|tcsh|csh|nu|nushell|xonsh|ion) ;;
    dash|busybox|ash|sh|"") s="sh" ;;   # Starship 不集成 sh/dash
  esac
  printf "%s" "$s"
}

backup_once() {  # file -> file.bak-TS
  local f="$1"
  [[ -f "$f" ]] && cp -p "$f" "$f.bak-$(date +%Y%m%d-%H%M%S)" || true
}

ensure_line() {  # file line（追加前先备份）
  local file="$1"; shift; local line="$*"
  mkdir -p "$(dirname "$file")"; [[ -f "$file" ]] || touch "$file"
  grep -Fqx "$line" "$file" 2>/dev/null || {
    backup_once "$file"
    printf "%s\n" "$line" >> "$file"
    log "Appended to $file"
  }
}

write_starship_toml() {
  local dir="${XDG_CONFIG_HOME:-$HOME/.config}"
  local file="$dir/starship.toml"
  mkdir -p "$dir"
  if [[ -f "$file" ]]; then
    backup_once "$file"
    log "Config exists ($file). Backup created. Keep your existing config (no overwrite)."
    return
  fi
  cat > "$file" <<'TOML'
format = "$username in$hostname in $directory\n$character"

[username]
show_always = true
format = " [$user]($style)"
style_root = "bold red"
style_user = "bold red"

[hostname]
ssh_only = false
format = " 🌐 [$hostname]($style)"
style = "bold green"

[directory]
format = " [$path]($style)"
style = "bold blue"
truncation_length = 3
truncate_to_repo = false

[character]
success_symbol = "[›](bold green) "
error_symbol   = "[›](bold red) "
TOML

  if [[ $ENABLE_DURATION -eq 1 ]]; then
    cat >> "$file" <<'TOML'
[cmd_duration]
min_time = 2000
format = " took [$duration]($style)"
style = "bold yellow"
disabled = false
TOML
  else
    cat >> "$file" <<'TOML'
[cmd_duration]
disabled = true
TOML
  fi
  log "Wrote $file"
}

install_via_pkg() {
  command -v starship >/dev/null 2>&1 && return 0

  if command -v apt-get >/dev/null 2>&1; then
    log "Installing via apt-get..."
    $SUDO apt-get update -y && $SUDO apt-get install -y starship && return 0 || true
  fi
  if command -v apt >/dev/null 2>&1; then
    log "Installing via apt..."
    $SUDO apt update -y && $SUDO apt install -y starship && return 0 || true
  fi
  if command -v dnf >/dev/null 2>&1; then
    log "Installing via dnf..."
    $SUDO dnf install -y starship && return 0 || true
  fi
  if command -v yum >/dev/null 2>&1; then
    log "Installing via yum..."
    $SUDO yum install -y starship && return 0 || true
  fi
  if command -v zypper >/dev/null 2>&1; then
    log "Installing via zypper..."
    $SUDO zypper --non-interactive install starship && return 0 || true
  fi
  if command -v pacman >/dev/null 2>&1; then
    log "Installing via pacman..."
    $SUDO pacman -Sy --noconfirm starship && return 0 || true
  fi
  if command -v apk >/dev/null 2>&1; then
    log "Installing via apk..."
    $SUDO apk add --no-cache starship && return 0 || true
  fi
  if command -v brew >/dev/null 2>&1; then
    log "Installing via Homebrew..."
    brew list starship >/dev/null 2>&1 || brew install starship
    command -v starship >/dev/null 2>&1 && return 0 || true
  fi
  return 1
}

install_via_official() {
  command -v starship >/dev/null 2>&1 && return 0
  log "Installing via official script (auto-yes)..."
  if command -v curl >/dev/null 2>&1; then
    { curl -fsSL https://starship.rs/install.sh | $SUDO sh -s -- -y; } || \
    { yes | $SUDO sh -c "$(curl -fsSL https://starship.rs/install.sh)"; }
  elif command -v wget >/dev/null 2>&1; then
    { wget -qO- https://starship.rs/install.sh | $SUDO sh -s -- -y; } || \
    { yes | $SUDO sh -c "$(wget -qO- https://starship.rs/install.sh)"; }
  else
    warn "No curl/wget found; cannot download official script."; return 1
  fi
}

configure_shell() {
  local sh="$1"
  case "$sh" in
    bash)   ensure_line "$HOME/.bashrc" 'eval "$(starship init bash)"' ;;
    zsh)    ensure_line "$HOME/.zshrc"  'eval "$(starship init zsh)"'  ;;
    fish)   ensure_line "$HOME/.config/fish/config.fish" 'starship init fish | source' ;;
    elvish) ensure_line "$HOME/.elvish/rc.elv" 'eval (starship init elvish)' ;;
    tcsh|csh) ensure_line "$HOME/.tcshrc" 'eval `starship init tcsh`' ;;
    nu|nushell)
      mkdir -p "$HOME/.cache/starship"
      starship init nu > "$HOME/.cache/starship/init.nu"
      ensure_line "$HOME/.config/nushell/config.nu" 'source ~/.cache/starship/init.nu'
      ;;
    xonsh)
      ensure_line "$HOME/.xonshrc" '$STARSHIP_INIT = !("starship init xonsh")'
      ensure_line "$HOME/.xonshrc" 'execx($STARSHIP_INIT)'
      ensure_line "$HOME/.xonshrc" 'del $STARSHIP_INIT'
      ;;
    ion)    ensure_line "$HOME/.config/ion/initrc" 'eval $(starship init ion)' ;;
    sh)     warn "Current shell looks like POSIX sh/dash; Starship does not integrate here. Skipped." ;;
    *)      warn "Unsupported shell: $sh" ;;
  esac
}

auto_refresh() {
  local sh="$1"
  case "$sh" in
    bash|zsh|fish)
      log "Reloading $sh environment (exec $sh -l)..."
      exec "$sh" -l
      ;;
    *)
      log "Please start a new $sh session to apply changes."
      ;;
  esac
}

main() {
  local cur; cur="$(detect_current_shell)"
  log "Detected current shell: ${cur:-unknown}"

  # 1) 安装（优先包管理器）
  if install_via_pkg; then
    log "Starship installed via package manager."
  else
    install_via_official || warn "Official install failed; please check network or permissions."
  fi

  # 2) 写入配置（不覆盖已有；存在则先备份再保留原配置）
  write_starship_toml

  # 3) 只配置“当前 shell”
  if [[ -z "$cur" || "$cur" == "sh" ]]; then
    warn "Unsupported or undetected shell. Manual setup may be required."
    exit 1
  fi
  configure_shell "$cur"

  echo "✅ 配置完成（shell: $cur）"
  auto_refresh "$cur"
}
main
