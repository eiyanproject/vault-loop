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

# --- pc\setup-plane.ps1, against test\fake-plane.py (needs python on PATH) ---
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) {
  Write-Host "SKIP  setup-plane: python not found"
} else {
  $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("vault-loop-plane-" + [guid]::NewGuid())
  New-Item -ItemType Directory -Path $dir | Out-Null
  $token = 'tk-test-' + [guid]::NewGuid().ToString('N')
  $portFile = Join-Path $dir 'port.txt'
  $srv = Start-Process -FilePath $py.Source -ArgumentList '-I', (Join-Path $root 'test\fake-plane.py'), $token `
           -RedirectStandardOutput $portFile -PassThru -WindowStyle Hidden
  try {
    for ($i = 0; $i -lt 50 -and -not ((Test-Path $portFile) -and (Get-Content $portFile -Raw)); $i++) { Start-Sleep -Milliseconds 100 }
    $base = "http://127.0.0.1:$((Get-Content $portFile -Raw).Trim())"
    $reg = Join-Path $dir 'Systems.md'
    Set-Content -Path $reg -Encoding utf8 -Value @'
# Systems

## For the loop

| System | Name | Repo | Plane project |
|---|---|---|---|
| alpha | Alpha Service | `o/alpha` | `ALP` (to create) |
| beta-two | | - (planned) | `BET` |
| nolabel | No Label | ? | ? |

Text after the table.

## Something else

| gamma | `o/gamma` | `GAM` |
'@
    $run = {
      param([switch]$Apply, [string]$Tok = $token)
      $env:PLANE_API_TOKEN = $Tok
      $a = @('-NoProfile', '-File', (Join-Path $root 'pc\setup-plane.ps1'), '-Registry', $reg, '-BaseUrl', $base, '-Workspace', 'ws')
      if ($Apply) { $a += '-Apply' }
      $o = & pwsh @a 2>&1 | Out-String
      Remove-Item Env:\PLANE_API_TOKEN
      return $o
    }
    $writes = { (Invoke-RestMethod "$base/_count").writes }

    $out = & $run
    Check "plan lists both projects to create" (([regex]::Matches($out, 'create project')).Count -eq 2)
    Check "plan reuses Plane's own Done state" ($out -notmatch 'state Done\s+create')
    Check "plan counts 20 changes" ($out -match '20 change\(s\) to make')
    Check "plan skips a row without an identifier" ($out -match 'skip\s+row without a Plane identifier')
    Check "plan ignores tables outside its section" ($out -notmatch 'GAM')
    Check "plan makes no writes" ((& $writes) -eq 0)
    Check "token is never printed" ($out -notmatch [regex]::Escape($token))

    $out = & $run -Apply
    $store = Invoke-RestMethod "$base/_dump"
    Check "apply creates exactly the two projects" ((@($store.projects | ForEach-Object identifier) -join ',') -eq 'ALP,BET')
    Check "a hyphen in a system name becomes a space" ((@($store.projects | Where-Object identifier -eq 'BET')[0].name) -eq 'beta two')
    Check "the Name column names the project" ((@($store.projects | Where-Object identifier -eq 'ALP')[0].name) -eq 'Alpha Service')
    Check "apply says when it had to change a name" ($out -match "create project 'beta two' \(Plane allows no special characters\)")
    foreach ($p in $store.projects) {
      $names = @($p.states | ForEach-Object name)
      Check "$($p.identifier) has all six loop states" (@('Proposed','Approved','Agent working','In review','Needs you','Done' | Where-Object { $names -notcontains $_ }).Count -eq 0)
      Check "$($p.identifier) has one Done" (@($names | Where-Object { $_ -eq 'Done' }).Count -eq 1)
      $defaults = @($p.states | Where-Object default)
      Check "$($p.identifier) default state is Proposed, only" ($defaults.Count -eq 1 -and $defaults[0].name -eq 'Proposed')
      Check "$($p.identifier) has the four labels" ((@($p.labels | ForEach-Object name | Sort-Object) -join ',') -eq 'change,incident,project,small')
      Check "$($p.identifier) keeps Plane's extra states" ($names -contains 'Backlog')
    }

    $before = & $writes
    $out = & $run
    Check "second plan has nothing to do" ($out -match 'Nothing to do')
    $out = & $run -Apply
    Check "second apply writes nothing" ((& $writes) -eq $before)

    # A project that already exists under another name is reported, never renamed.
    $h = @{ 'X-Api-Key' = $token }
    Invoke-RestMethod -Method Post -Uri "$base/api/v1/workspaces/ws/projects/" -Headers $h -ContentType 'application/json' -Body '{"name":"Old Name","identifier":"OLD"}' | Out-Null
    $lines = [System.Collections.Generic.List[string]](Get-Content $reg)
    $at = $lines.FindIndex([Predicate[string]]{ param($l) $l -like '| nolabel*' })
    $lines.Insert($at + 1, '| omega | Omega Tool | - | `OLD` |')
    Set-Content -Path $reg -Encoding utf8 -Value $lines
    $before = & $writes
    $out = & $run -Apply
    Check "an existing name that differs is reported" ($out -match "named 'Old Name', registry says 'Omega Tool'")
    Check "and the project is not renamed" ((@((Invoke-RestMethod "$base/_dump").projects | Where-Object identifier -eq 'OLD')[0].name) -eq 'Old Name')

    $out = & $run -Tok 'wrong-token'
    Check "a wrong token is reported" ($out -match 'refused the token \(HTTP 401\)')
  } finally {
    Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
  }
}
Write-Host "pc: $pass passed, $fail failed"
exit $fail
