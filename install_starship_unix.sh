#!/usr/bin/env bash
set -euo pipefail

# Starship unified installer/configurator (Unix/macOS/WSL)
# Defaults: only configure CURRENT shell; official installer only.

CURRENT_ONLY=1
ENABLE_DURATION=0
FORCE=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --current) CURRENT_ONLY=1 ;;
    --all) CURRENT_ONLY=0 ;;
    --enable-duration) ENABLE_DURATION=1 ;;
    --force) FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      cat <<'EOF'
Usage: ./install_starship_unix.sh [--current|--all] [--enable-duration] [--force] [--dry-run]

- --current (default): configure only the CURRENT shell.
- --all: configure all supported shells found on this system.
- --enable-duration: enable 'took Xs' when command >2s.
- --force: overwrite ~/.config/starship.toml (backup kept).
- --dry-run: print actions only.
EOF
      exit 0 ;;
    *) echo "Unknown option: $1" ; exit 2 ;;
  esac
  shift
done

ts() { date +"%Y%m%d-%H%M%S" ; }
log() { printf "[*] %s\n" "$*" ; }
warn() { printf "[!] %s\n" "$*" >&2 ; }
backup() { [[ -f "$1" ]] && cp -p "$1" "$1.bak-$(ts)" || true ; }
ensure_line() { # file line
  local f="$1"; shift; local line="$*"
  mkdir -p "$(dirname "$f")"; [[ -f "$f" ]] || touch "$f"
  if ! grep -Fqx "$line" "$f" 2>/dev/null; then
    backup "$f"
    [[ $DRY_RUN -eq 1 ]] && { log "(dry-run) append to $f: $line"; return 0; }
    printf "%s\n" "$line" >> "$f"
    log "Appended to $f"
  else
    log "Already present: $f"
  fi
}

detect_current_shell() {
  # 1) full args of current process
  local args
  args="$(ps -p $$ -o args= 2>/dev/null || true)"
  # 2) /proc/$$/comm (Linux/WSL)
  local comm=""
  [[ -r /proc/$$/comm ]] && comm="$(tr -d '[:space:]' < /proc/$$/comm)"
  # 3) $SHELL
  local envs="${SHELL:-}"
  local s=""
  if [[ -n "$args" ]]; then
    s="${args##* }"; s="${s##*/}"
  elif [[ -n "$comm" ]]; then
    s="${comm##*/}"
  elif [[ -n "$envs" ]]; then
    s="${envs##*/}"
  fi
  s="${s#-}"; s="${s,,}"
  case "$s" in
    bash|zsh|fish|elvish|tcsh|csh|nu|nushell|xonsh|ion) ;;
    dash|busybox|ash|sh|"") s="sh" ;;  # not supported for config
  esac
  printf "%s" "$s"
}

install_starship() {
  if command -v starship >/dev/null 2>&1; then log "Starship already installed."; return; fi
  log "Installing Starship via official script..."
  if [[ $DRY_RUN -eq 1 ]]; then log "(dry-run) curl -fsSL https://starship.rs/install.sh | sh"; return; fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://starship.rs/install.sh | sh
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- https://starship.rs/install.sh | sh
  else
    warn "No curl/wget, cannot auto-install Starship."
  fi
}

write_starship_toml() {
  local dir="${XDG_CONFIG_HOME:-$HOME/.config}"
  local file="$dir/starship.toml"
  mkdir -p "$dir"
  if [[ -f "$file" && $FORCE -eq 0 ]]; then log "Config exists ($file). Use --force to overwrite."; return; fi
  [[ -f "$file" ]] && backup "$file"
  if [[ $DRY_RUN -eq 1 ]]; then log "(dry-run) write $file"; return; fi
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

configure_shell() {
  local sh="$1"
  case "$sh" in
    bash)   ensure_line "$HOME/.bashrc" 'eval "$(starship init bash)"' ;;
    zsh)    ensure_line "$HOME/.zshrc"  'eval "$(starship init zsh)"'  ;;
    fish)   ensure_line "$HOME/.config/fish/config.fish" 'starship init fish | source' ;;
    elvish) ensure_line "$HOME/.elvish/rc.elv" 'eval (starship init elvish)' ;;
    tcsh|csh) ensure_line "$HOME/.tcshrc" 'eval `starship init tcsh`' ;;
    nu|nushell) mkdir -p "$HOME/.cache/starship"; starship init nu > "$HOME/.cache/starship/init.nu"; ensure_line "$HOME/.config/nushell/config.nu" 'source ~/.cache/starship/init.nu' ;;
    xonsh)  ensure_line "$HOME/.xonshrc" '$STARSHIP_INIT = !("starship init xonsh")'; ensure_line "$HOME/.xonshrc" 'execx($STARSHIP_INIT)'; ensure_line "$HOME/.xonshrc" 'del $STARSHIP_INIT' ;;
    ion)    ensure_line "$HOME/.config/ion/initrc" 'eval $(starship init ion)' ;;
    sh)     warn "Current shell looks like POSIX sh/dash; Starship does not integrate here. Skipped." ;;
    *)      warn "Unsupported shell: $sh" ;;
  esac
}

main() {
  install_starship
  write_starship_toml

  local targets=()
  if [[ $CURRENT_ONLY -eq 1 ]]; then
    local cur; cur="$(detect_current_shell)"
    [[ -z "$cur" ]] && { warn "Could not detect current shell."; exit 1; }
    targets+=("$cur")
  else
    for s in bash zsh fish elvish tcsh nu xonsh ion; do
      command -v "$s" >/dev/null 2>&1 && targets+=("$s")
    done
  fi

  log "Configuring shell(s): ${targets[*]}"
  for s in "${targets[@]}"; do configure_shell "$s"; done

  log "Done. Open a new terminal or source your rc file."
}
main
