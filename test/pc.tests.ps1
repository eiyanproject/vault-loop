# Tests for pc\new-vault.ps1 and pc\check-pc.ps1. Uses a temp folder only.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("vault-loop-test-" + [guid]::NewGuid())
$pass = 0; $fail = 0
function Check([string]$name, [bool]$cond) {
  if ($cond) { Write-Host "PASS  $name"; $script:pass++ } else { Write-Host "FAIL  $name" -ForegroundColor Red; $script:fail++ }
}
try {
  & pwsh -NoProfile -File (Join-Path $root 'pc\new-vault.ps1') -Path $tmp | Out-Null
  foreach ($f in 'Inbox','Idea','Project','Incident','Task','Learned','Systems','Templates','_agent') {
    Check "creates $f" (Test-Path (Join-Path $tmp $f))
  }
  $bytes = [System.IO.File]::ReadAllBytes((Join-Path $tmp '.stignore'))
  Check ".stignore has no BOM" (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB))
  Check ".stignore includes the shared list" ((Get-Content (Join-Path $tmp '.stignore') -Raw) -match '^#include \.stignore-shared')
  Check ".stignore-shared has LF endings" (-not ((Get-Content (Join-Path $tmp '.stignore-shared') -Raw) -match "`r"))

  Set-Content -Path (Join-Path $tmp 'Inbox\README.md') -Value 'mine'
  $out = & pwsh -NoProfile -File (Join-Path $root 'pc\new-vault.ps1') -Path $tmp
  Check "second run creates nothing" (($out -join "`n") -match 'Nothing to do')
  Check "never overwrites a file" ((Get-Content (Join-Path $tmp 'Inbox\README.md') -Raw).Trim() -eq 'mine')

  $out = & pwsh -NoProfile -File (Join-Path $root 'pc\check-pc.ps1') -Vault $tmp
  Check "check-pc sees the test vault" (($out -join "`n") -match 'OK\s+Vault')
  $out = & pwsh -NoProfile -File (Join-Path $root 'pc\check-pc.ps1') -Vault (Join-Path $tmp 'nope')
  Check "check-pc reports a missing vault" (($out -join "`n") -match 'MISSING\s+Vault')
  Check "check-pc exit code counts missing items" ($LASTEXITCODE -ge 1)
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
Write-Host "pc: $pass passed, $fail failed"
exit $fail
