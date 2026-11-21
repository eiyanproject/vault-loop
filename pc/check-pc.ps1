<#
.SYNOPSIS
  Read-only check of the PC prerequisites for vault-loop Phase 0.

.DESCRIPTION
  Changes nothing. Reports each prerequisite as OK or MISSING, with what to do.
  Exit code is the number of missing items (0 = ready).

.EXAMPLE
  pwsh -File pc\check-pc.ps1 -Vault "$HOME\Vaults\Main"
#>
param(
  [string]$Vault = (Join-Path $HOME 'Vaults\Main')
)

$missing = 0
function Report([string]$name, [bool]$ok, [string]$detail, [string]$fix) {
  if ($ok) {
    Write-Host ("  OK       {0,-16} {1}" -f $name, $detail) -ForegroundColor Green
  } else {
    Write-Host ("  MISSING  {0,-16} {1}" -f $name, $fix) -ForegroundColor Yellow
    $script:missing++
  }
}
function Try-Version([string]$cmd, [string[]]$cmdArgs) {
  $c = Get-Command $cmd -ErrorAction SilentlyContinue
  if (-not $c) { return $null }
  try { return ((& $c.Source @cmdArgs 2>$null) | Select-Object -First 1) } catch { return $null }
}

Write-Host "`nvault-loop Phase 0 - PC check`n"

# Obsidian: per-user install by default, machine-wide if installed by winget --scope machine.
$obsidianPaths = @(
  (Join-Path $env:LOCALAPPDATA 'Programs\Obsidian\Obsidian.exe'),
  (Join-Path $env:ProgramFiles 'Obsidian\Obsidian.exe')
)
$obsidian = $obsidianPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
Report 'Obsidian' ([bool]$obsidian) "$obsidian" 'winget install --id Obsidian.Obsidian -e'

# Syncthing: must be running, not just installed, or the PC never receives notes.
$st = Get-Process -Name 'syncthing' -ErrorAction SilentlyContinue | Select-Object -First 1
Report 'Syncthing' ([bool]$st) 'running' 'winget install --id Syncthing.Syncthing -e, then start it at login (docs/PHASE0.md step 1)'

$v = Try-Version 'git' @('--version')
Report 'git' ([bool]$v) "$v" 'winget install --id Git.Git -e'

$v = Try-Version 'docker' @('version', '--format', '{{.Server.Version}}')
Report 'Docker Desktop' ([bool]$v) "engine $v" 'start Docker Desktop (it must be running, not only installed)'

$gh = Get-Command gh -ErrorAction SilentlyContinue
$ghOk = $false
if ($gh) { & $gh.Source auth status *> $null; $ghOk = ($LASTEXITCODE -eq 0) }
Report 'gh' $ghOk 'signed in' $(if ($gh) { 'gh auth login' } else { 'winget install --id GitHub.cli -e, then gh auth login' })

$v = Try-Version 'claude' @('--version')
Report 'Claude Code' ([bool]$v) "$v" 'install Claude Code and sign in with your subscription'

$vaultOk = (Test-Path (Join-Path $Vault 'Inbox')) -and (Test-Path (Join-Path $Vault '.stignore-shared'))
Report 'Vault' $vaultOk "$Vault" "pwsh -File pc\new-vault.ps1 -Path `"$Vault`""

Write-Host ""
if ($missing -eq 0) { Write-Host "PC is ready for Phase 0." -ForegroundColor Green }
else { Write-Host "$missing item(s) missing." -ForegroundColor Yellow }
exit $missing
