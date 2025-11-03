#!/usr/bin/env bash
set -euo pipefail

# ===================== 用户选项 =====================
ENABLE_DURATION=0     # 启用 cmd_duration：--enable-duration
FORCE_TOML=0          # 覆盖 ~/.config/starship.toml：--force
FORCE_SHELL=""        # 强制目标壳：--shell zsh|bash|fish|...
SKIP_INSTALL=0        # 跳过安装：--no-install

# 解析参数
while [[ $# -gt 0 ]]; do
  case "$1" in
    --enable-duration) ENABLE_DURATION=1; shift;;
    --force)           FORCE_TOML=1; shift;;
    --shell)           FORCE_SHELL="$2"; shift 2;;
    --no-install)      SKIP_INSTALL=1; shift;;
    -h|--help)
      cat <<'EOF'
Usage: bash ./install_starship_unix.sh [--enable-duration] [--force] [--shell <bash|zsh|fish|...>] [--no-install]

功能：
- 自动安装 Starship（优先包管理器；失败时根据 libc 自动选择 GNU/MUSL 预编译包）
- 按当前壳写入 init（bash/zsh/fish/elvish/tcsh/nushell/xonsh/ion），并尽量立即生效
- 生成 ~/.config/starship.toml（默认不覆盖，--force 才覆盖）
- 幂等：先备份，避免重复

默认只配置“当前壳”；可用 --shell 强制指定。
EOF
      exit 0;;
    *) echo "Unknown option: $1"; exit 2;;
  esac
done

log()  { printf "[*] %s\n" "$*"; }
warn() { printf "[!] %s\n" "$*" >&2; }
bk()   { [[ -f "$1" ]] && cp -p "$1" "$1.bak-$(date +%Y%m%d-%H%M%S)" || true; }
ensure_line(){ local f="$1"; shift; local line="$*"; mkdir -p "$(dirname "$f")"; [[ -f "$f" ]]||:> "$f"; grep -Fqx "$line" "$f" 2>/dev/null || { bk "$f"; printf "%s\n" "$line" >>"$f"; log "Appended to $f"; }; }

SUDO=""
if [[ "$(id -u)" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi

# ===================== 当前壳检测（父进程壳 > 登录壳 > 运行时壳 > $SHELL） =====================
detect_current_shell() {
  # 登录壳
  local login_shell=""
  if command -v getent >/dev/null 2>&1; then
    login_shell="$(getent passwd "$(id -un)" | awk -F: '{print $NF}' | xargs basename)"
  else
    login_shell="$(awk -F: -v u="$(id -un)" '$1==u{print $NF}' /etc/passwd | xargs basename)"
  fi

  # 父进程链交互壳（避免 curl ... | bash 误判）
  local ppid name parent_shell=""
  ppid="$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')"
  while [[ -n "${ppid:-}" && "$ppid" != "1" ]]; do
    name="$(ps -p "$ppid" -o comm= 2>/dev/null | xargs basename | tr '[:upper:]' '[:lower:]' || true)"
    case "$name" in
      bash|zsh|fish|elvish|tcsh|csh|nu|nushell|xonsh|ion) parent_shell="$name"; break;;
    esac
    ppid="$(ps -o ppid= -p "$ppid" 2>/dev/null | tr -d ' ' || true)"
  done

  local run_shell env_shell
  run_shell="$(ps -p $$ -o comm= 2>/dev/null | xargs basename | tr '[:upper:]' '[:lower:]' || true)"
  env_shell="$(basename "${SHELL:-}" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"

  local s="${parent_shell:-${login_shell:-${run_shell:-$env_shell}}}"
  s="${s#-}"; s="${s,,}"
  case "$s" in csh) s="tcsh";; nushell) s="nu";; esac
  case "$s" in bash|zsh|fish|elvish|tcsh|nu|xonsh|ion) printf "%s" "$s";;
               *) printf "sh";; esac
}

# ===================== 版本比较 / libc 检测 =====================
ver_ge(){  # ver_ge <v1> <v2> : v1 >= v2 ?
  local IFS=.; local -a A=(${1//[!0-9.]/}); local -a B=(${2//[!0-9.]/}); local i
  for ((i=0; i<${#A[@]} || i<${#B[@]}; i++)); do
    local a=${A[i]:-0}; local b=${B[i]:-0}
    ((a>b)) && return 0
    ((a<b)) && return 1
  done
  return 0
}

detect_libc() {
  # 回传两变量：LIBC_NAME, LIBC_VER
  LIBC_NAME="unknown"; LIBC_VER=""
  if command -v ldd >/dev/null 2>&1; then
    local out; out="$(ldd --version 2>&1 || true)"
    if grep -qi 'musl' <<<"$out"; then
      LIBC_NAME="musl"
      LIBC_VER="$(grep -oE 'musl[^0-9]*([0-9]+(\.[0-9]+)*)' <<<"$out" | grep -oE '[0-9]+(\.[0-9]+)*' | head -1 || true)"
      return 0
    fi
    if grep -qi 'glibc\|gnu libc\|gnu c library' <<<"$out"; then
      LIBC_NAME="glibc"
      # Debian 风格可能有两处数字，取最后一个
      LIBC_VER="$(grep -oE '([0-9]+(\.[0-9]+)+)' <<<"$out" | tail -1 || true)"
      return 0
    fi
  fi
  return 0
}

need_musl_due_to_glibc() {
  # 条件1：glibc 且版本 < 2.18
  detect_libc
  if [[ "$LIBC_NAME" == "glibc" ]]; then
    [[ -n "$LIBC_VER" ]] && ! ver_ge "$LIBC_VER" "2.18" && return 0
  fi
  # 条件2：系统不是 glibc（musl/unknown），直接用 musl 更稳
  if [[ "$LIBC_NAME" != "glibc" ]]; then
    return 0
  fi
  # 条件3：已有 starship 但运行时报 glibc 符号错误
  if command -v starship >/dev/null 2>&1; then
    if ! starship --version >/dev/null 2>&1; then
      starship --version 2>&1 | grep -q 'GLIBC_2\.18' && return 0
    fi
  fi
  return 1
}

choose_prebuilt_pkg() {
  # 根据架构 + libc 决定下载的包名，echo 返回
  local arch uname_m pkg
  uname_m="$(uname -m)"
  case "$uname_m" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) warn "Unsupported arch: $uname_m"; return 1 ;;
  esac

  if need_musl_due_to_glibc; then
    pkg="starship-${arch}-unknown-linux-musl.tar.gz"
  else
    pkg="starship-${arch}-unknown-linux-gnu.tar.gz"
  fi
  echo "$pkg"
}

# ===================== 安装 Starship =====================
install_starship_pkg() {
  command -v starship >/dev/null 2>&1 && return 0
  if command -v apt-get >/dev/null 2>&1; then
    log "Installing via apt-get..."
    $SUDO apt-get update -y || true
    $SUDO apt-get install -y starship && return 0 || true
    # Debian backports（有些版本仓库没打包）
    if [[ -r /etc/os-release ]]; then
      . /etc/os-release
      if [[ "${ID:-}" = "debian" || "${ID_LIKE:-}" =~ debian ]]; then
        local codename="${VERSION_CODENAME:-bookworm}"
        echo "deb http://deb.debian.org/debian ${codename}-backports main" | $SUDO tee /etc/apt/sources.list.d/backports.list >/dev/null
        $SUDO apt-get update -y
        $SUDO apt-get -t "${codename}-backports" install -y starship && return 0 || true
      fi
    fi
  fi
  if command -v apt >/dev/null 2>&1; then
    log "Installing via apt..."
    $SUDO apt update -y || true
    $SUDO apt install -y starship && return 0 || true
  fi
  if command -v dnf  >/dev/null 2>&1; then log "Installing via dnf...";  $SUDO dnf  install -y starship && return 0 || true; fi
  if command -v yum  >/dev/null 2>&1; then log "Installing via yum...";  $SUDO yum  install -y starship && return 0 || true; fi
  if command -v zypper>/dev/null 2>&1; then log "Installing via zypper...";$SUDO zypper --non-interactive install starship && return 0 || true; fi
  if command -v pacman>/dev/null 2>&1; then log "Installing via pacman...";$SUDO pacman -Sy --noconfirm starship && return 0 || true; fi
  if command -v apk   >/dev/null 2>&1; then log "Installing via apk...";   $SUDO apk add --no-cache starship && return 0 || true; fi
  if command -v brew  >/dev/null 2>&1; then log "Installing via Homebrew..."; brew list starship >/dev/null 2>&1 || brew install starship; command -v starship >/dev/null 2>&1 && return 0 || true; fi
  return 1
}

install_starship_auto_fallback() {
  command -v starship >/dev/null 2>&1 && return 0
  local pkg url=/tmp/starship.tgz
  pkg="$(choose_prebuilt_pkg)" || { warn "failed to choose prebuilt pkg"; return 1; }
  log "Installing via prebuilt fallback (pkg: $pkg)..."
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 5 --connect-timeout 10 --max-time 300 -o "$url" \
      "https://github.com/starship/starship/releases/latest/download/$pkg"
  else
    wget -O "$url" "https://github.com/starship/starship/releases/latest/download/$pkg"
  fi
  $SUDO tar -xzf "$url" -C /usr/local/bin starship
  $SUDO chmod +x /usr/local/bin/starship
}

# ===================== 写 starship.toml（不覆盖） =====================
write_starship_toml() {
  local dir="${XDG_CONFIG_HOME:-$HOME/.config}"; local file="$dir/starship.toml"
  mkdir -p "$dir"
  if [[ -f "$file" && "$FORCE_TOML" -eq 0 ]]; then
    bk "$file"; log "Config exists ($file). Backup created. Keep your existing config (no overwrite)."; return 0
  fi
  [[ -f "$file" ]] && bk "$file"
  cat >"$file" <<'TOML'
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

[cmd_duration]
disabled = true
TOML
  if [[ "$ENABLE_DURATION" -eq 1 ]]; then
    cat >>"$file" <<'TOML'
[cmd_duration]
min_time = 2000
format = " took [$duration]($style)"
style = "bold yellow"
disabled = false
TOML
  fi
  log "Wrote $file"
}

# ===================== 针对每种壳写入 rc + 立即生效 =====================
ensure_login_reads_rc_bash(){ local t="$HOME/.bash_profile"; [[ -f "$HOME/.profile" ]] && t="$HOME/.profile"; ensure_line "$t" '[ -n "$BASH_VERSION" ] && [ -f ~/.bashrc ] && . ~/.bashrc'; }
ensure_login_reads_rc_zsh(){ ensure_line "$HOME/.zprofile" '[ -f ~/.zshrc ] && . ~/.zshrc'; }

run_for_bash(){ ensure_line "$HOME/.bashrc" 'eval "$(starship init bash)"'; ensure_login_reads_rc_bash; log "Reloading bash: source ~/.bashrc"; . "$HOME/.bashrc" 2>/dev/null || true; }
run_for_zsh(){  ensure_line "$HOME/.zshrc"  'eval "$(starship init zsh)"' ; ensure_login_reads_rc_zsh ; log "Reloading zsh : source ~/.zshrc" ; . "$HOME/.zshrc"  2>/dev/null || true; }
run_for_fish(){ ensure_line "$HOME/.config/fish/config.fish" 'starship init fish | source'; log "Reloading fish: exec fish -l"; exec fish -l; }
run_for_elvish(){ ensure_line "$HOME/.elvish/rc.elv" 'eval (starship init elvish)'; }
run_for_tcsh(){   ensure_line "$HOME/.tcshrc"        'eval `starship init tcsh`'; }
run_for_nu(){     mkdir -p "$HOME/.cache/starship"; starship init nu > "$HOME/.cache/starship/init.nu"; ensure_line "$HOME/.config/nushell/config.nu" 'source ~/.cache/starship/init.nu'; }
run_for_xonsh(){  ensure_line "$HOME/.xonshrc" '$STARSHIP_INIT = !("starship init xonsh")'; ensure_line "$HOME/.xonshrc" 'execx($STARSHIP_INIT)'; ensure_line "$HOME/.xonshrc" 'del $STARSHIP_INIT'; }
run_for_ion(){    ensure_line "$HOME/.config/ion/initrc" 'eval $(starship init ion)'; }

# ===================== 主流程 =====================
main() {
  local cur="${FORCE_SHELL:-$(detect_current_shell)}"
  log "Detected current shell: ${cur}${FORCE_SHELL:+ (forced)}"

  if [[ "$SKIP_INSTALL" -eq 0 ]]; then
    if install_starship_pkg; then
      log "Starship installed via package manager."
    else
      install_starship_auto_fallback || warn "Install fallback failed. Ensure network or install manually."
    fi
  else
    log "Skip install as requested."
  fi

  # 若已有 starship 但是 glibc 错误，自动换 MUSL（保险起见）
  if command -v starship >/dev/null 2>&1; then
    if ! starship --version >/dev/null 2>&1; then
      if starship --version 2>&1 | grep -q 'GLIBC_2\.18'; then
        warn "Detected GLIBC_2.18 error; switching to MUSL build..."
        # 覆盖安装 MUSL 版本
        choose_prebuilt_pkg >/dev/null
        # 强制 MUSL
        local arch uname_m url=/tmp/starship.tgz
        uname_m="$(uname -m)"
        case "$uname_m" in x86_64|amd64) arch="x86_64";; aarch64|arm64) arch="aarch64";; *) arch="x86_64";; esac
        local pkg="starship-${arch}-unknown-linux-musl.tar.gz"
        if command -v curl >/dev/null 2>&1; then
          curl -fL --retry 5 --connect-timeout 10 --max-time 300 -o "$url" \
            "https://github.com/starship/starship/releases/latest/download/$pkg"
        else
          wget -O "$url" "https://github.com/starship/starship/releases/latest/download/$pkg"
        fi
        $SUDO tar -xzf "$url" -C /usr/local/bin starship
        $SUDO chmod +x /usr/local/bin/starship
      fi
    fi
  fi

  write_starship_toml

  case "$cur" in
    bash)  run_for_bash  ;;
    zsh)   run_for_zsh   ;;
    fish)  run_for_fish  ;;
    elvish)run_for_elvish;;
    tcsh)  run_for_tcsh  ;;
    nu)    run_for_nu    ;;
    xonsh) run_for_xonsh ;;
    ion)   run_for_ion   ;;
    sh)    warn "This shell (sh/dash) is not supported by Starship. Skipped."; exit 1;;
    *)     warn "Unknown shell: $cur"; exit 1;;
  esac

  echo "✅ Done (shell: $cur)"
}
main
