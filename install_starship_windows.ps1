param(
  [switch]$EnableDuration = $false
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Log($m) { Write-Host "[*] $m" }
function Backup-File($Path) { if (Test-Path $Path) { Copy-Item $Path "$Path.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')" -Force } }

Write-Log "Detected current shell: PowerShell"

# 1) 安装（优先 winget，失败回退官方脚本；全程自动同意）
if (-not (Get-Command starship -ErrorAction SilentlyContinue)) {
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    Write-Log "Installing Starship via winget..."
    try {
      winget install --id Starship.Starship -e --silent `
        --accept-package-agreements --accept-source-agreements
    } catch {
      Write-Log "winget failed, fallback to official script..."
    }
  }

  if (-not (Get-Command starship -ErrorAction SilentlyContinue)) {
    Write-Log "Installing Starship via official script (auto-yes)..."
    try {
      iwr -useb https://starship.rs/install.ps1 | iex
    } catch {
      Write-Log "Official script failed: $($_.Exception.Message)"
    }
  }
} else {
  Write-Log "Starship already installed."
}

# 2) 写入 ~/.config/starship.toml（若存在则先备份再保留原配置；不存在则新建）
$cfgDir = Join-Path $HOME ".config"
$cfg = Join-Path $cfgDir "starship.toml"
if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null }

if (Test-Path $cfg) {
  Backup-File $cfg
  Write-Log "Config exists ($cfg). Backup created. Keep your existing config (no overwrite)."
} else {
  $content = @'
format = "$username in$hostname in $directory
$character"

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
'@
  if ($EnableDuration) {
    $content += @'
[cmd_duration]
min_time = 2000
format = " took [$duration]($style)"
style = "bold yellow"
disabled = false
'@
  } else {
    $content += @'
[cmd_duration]
disabled = true
'@
  }
  Set-Content -Path $cfg -Encoding UTF8 -Value $content
  Write-Log "Wrote $cfg"
}

# 3) 仅配置当前 PowerShell（追加前先备份；已存在则跳过）
$init = 'Invoke-Expression (&starship init powershell)'
$profilePath = $PROFILE
$profileDir  = Split-Path -Parent $profilePath
if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Force -Path $profileDir | Out-Null }
if (-not (Test-Path $profilePath)) { New-Item -ItemType File -Force -Path $profilePath | Out-Null }

$raw = Get-Content -Path $profilePath -Raw -ErrorAction SilentlyContinue
if ($raw -notmatch [regex]::Escape($init)) {
  Backup-File $profilePath
  Add-Content -Path $profilePath -Value "`n$init`n"
  Write-Log "Configured PowerShell profile."
} else {
  Write-Log "PowerShell already configured."
}

Write-Log "✅ 配置完成（shell: PowerShell）"
# 自动刷新当前会话
. $PROFILE
Write-Log "Environment reloaded. If you don't see the prompt, open a new terminal."
