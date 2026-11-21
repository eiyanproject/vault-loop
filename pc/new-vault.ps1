<#
.SYNOPSIS
  Create the vault-loop folder skeleton for an Obsidian vault.

.DESCRIPTION
  Creates only what is missing. Never overwrites or deletes a file, so it is
  safe to run on an existing vault. Prints what it created.

  .stignore is NOT synced by Syncthing, so each device needs its own. The one
  written here contains a single line that pulls in .stignore-shared, which IS
  synced. On the phone and CT 107, set the folder's ignore patterns to the same
  single line: #include .stignore-shared

.EXAMPLE
  pwsh -File pc\new-vault.ps1 -Path "$HOME\Vaults\Main"
#>
param(
  [Parameter(Mandatory = $true)][string]$Path
)

$folders = @('Inbox', 'Idea', 'Project', 'Incident', 'Task', 'Learned', 'Systems', 'Templates', '_agent')

$files = [ordered]@{
  '.stignore-shared' = @'
// vault-loop: synced ignore list. Each device's .stignore contains only:
//   #include .stignore-shared
// Per-device Obsidian state; syncing it causes conflict files on every switch.
.obsidian/workspace.json
.obsidian/workspace-mobile.json
.obsidian/cache
// Obsidian's local trash; Syncthing's own versioning on CT 107 covers recovery.
.trash
'@
  '.stignore' = "#include .stignore-shared`n"
  '_agent\README.md' = @'
# _agent

Written by the automation, never by hand: run log, note-to-ticket index, job
state. Editing files here from two devices at once makes Syncthing conflicts.
'@
  'Inbox\README.md' = @'
# Inbox

New notes go here. Nothing is processed until its frontmatter says
`status: ready` (from Phase 2 on).
'@
}

$created = @()
if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path | Out-Null; $created += $Path }

foreach ($f in $folders) {
  $p = Join-Path $Path $f
  if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p | Out-Null; $created += $p }
}
foreach ($name in $files.Keys) {
  $p = Join-Path $Path $name
  if (-not (Test-Path $p)) {
    # UTF-8 without BOM: Syncthing's ignore parser reads a BOM as part of the first pattern.
    [System.IO.File]::WriteAllText($p, ($files[$name] -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
    $created += $p
  }
}

if ($created.Count -eq 0) { Write-Host "Nothing to do: $Path already has the full skeleton." }
else { Write-Host "Created:"; $created | ForEach-Object { Write-Host "  $_" } }
