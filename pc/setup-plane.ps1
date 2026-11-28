<#
.SYNOPSIS
  Creates the loop's Plane projects, states and labels from the registry table.

.DESCRIPTION
  Reads the "## For the loop" table in the inbox vault's registry note (one row
  per system: System | Repo | Plane project) and makes sure each row has a Plane
  project with the loop's six states and four labels (docs/PHASE1.md).

  Prints the plan and changes nothing unless -Apply is given. Safe to re-run: it
  only adds what is missing. It never deletes or renames a project, state or
  label; Plane's own default states are listed as "extra" and left alone.

  The API token is read from $env:PLANE_API_TOKEN, or asked for at a hidden
  prompt. It is never printed. Create it in Plane under Profile settings ->
  API tokens, and delete it afterwards if you like.

.EXAMPLE
  pwsh -File pc\setup-plane.ps1 -Registry "<vault>\Systems.md" -BaseUrl http://<plane-ip> -Workspace <slug>
  pwsh -File pc\setup-plane.ps1 -Registry "<vault>\Systems.md" -BaseUrl http://<plane-ip> -Workspace <slug> -Apply
#>
param(
  [Parameter(Mandatory)] [string]$Registry,
  [Parameter(Mandatory)] [string]$BaseUrl,
  [Parameter(Mandatory)] [string]$Workspace,
  [switch]$Apply
)
$ErrorActionPreference = 'Stop'

# The loop's states. Names matter: n8n queues a coding job on exactly "Approved".
# Plane wants every state in a group; "Proposed" becomes each project's default.
$States = @(
  @{ name = 'Proposed';      group = 'backlog';   color = '#A3A3A3'; default = $true }
  @{ name = 'Approved';      group = 'unstarted'; color = '#3F76FF' }
  @{ name = 'Agent working'; group = 'started';   color = '#F59E0B' }
  @{ name = 'In review';     group = 'started';   color = '#8B5CF6' }
  @{ name = 'Needs you';     group = 'started';   color = '#EF4444' }
  @{ name = 'Done';          group = 'completed'; color = '#16A34A' }
)
$Labels = @(
  @{ name = 'change';   color = '#3F76FF' }
  @{ name = 'project';  color = '#16A34A' }
  @{ name = 'incident'; color = '#EF4444' }
  @{ name = 'small';    color = '#A3A3A3' }
)

function Read-Registry([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { throw "registry not found: $path" }
  $lines = Get-Content -LiteralPath $path -Encoding utf8
  $start = [array]::FindIndex($lines, [Predicate[string]]{ param($l) $l -match '^##\s+For the loop\s*$' })
  if ($start -lt 0) { throw "no '## For the loop' section in $path" }
  $rows = @()
  $seenHeader = $false
  for ($i = $start + 1; $i -lt $lines.Count; $i++) {
    $l = $lines[$i].Trim()
    if ($l -match '^##\s') { break }
    if (-not $l.StartsWith('|')) {
      if ($seenHeader -and $l -ne '') { break }   # first text after the table ends it
      continue
    }
    if (-not $seenHeader) { $seenHeader = $true; continue }   # header row
    if ($l -match '^\|[\s:|-]+\|$') { continue }              # separator row
    $cells = $l.Trim('|').Split('|') | ForEach-Object { $_.Trim() }
    $system = ($cells[0] -replace '`', '').Trim()
    $m = [regex]::Match($cells[2], '`([A-Za-z0-9]{1,12})`')
    if (-not $system -or -not $m.Success) {
      Write-Host "  skip  row without a Plane identifier: $l"
      continue
    }
    $rows += [pscustomobject]@{ System = $system; Identifier = $m.Groups[1].Value.ToUpper() }
  }
  if (-not $rows.Count) { throw "the '## For the loop' table in $path has no rows with a Plane identifier" }
  return $rows
}

$token = $env:PLANE_API_TOKEN
if (-not $token) {
  $sec = Read-Host -AsSecureString 'Plane API token (input hidden)'
  $token = [System.Net.NetworkCredential]::new('', $sec).Password
}
if (-not $token) { throw 'no API token: set PLANE_API_TOKEN or type it at the prompt' }

$api = $BaseUrl.TrimEnd('/') + "/api/v1/workspaces/$Workspace"
$headers = @{ 'X-Api-Key' = $token; 'Accept' = 'application/json' }

function Invoke-Plane([string]$method, [string]$path, $body = $null) {
  $p = @{ Method = $method; Uri = "$api$path"; Headers = $headers; SkipHttpErrorCheck = $true; StatusCodeVariable = 'code' }
  if ($null -ne $body) { $p.Body = ($body | ConvertTo-Json -Depth 5); $p.ContentType = 'application/json' }
  $r = Invoke-RestMethod @p
  if ($code -eq 401 -or $code -eq 403) { throw "Plane refused the token (HTTP $code) for $method $path" }
  if ($code -ge 400) {
    $detail = if ($r -is [string]) { $r } else { $r | ConvertTo-Json -Compress -Depth 5 }
    throw "Plane answered HTTP $code for $method ${path}: $detail"
  }
  return $r
}

function Get-All([string]$path) {
  $all = @(); $cursor = $null
  do {
    $q = '?per_page=1000' + ($(if ($cursor) { "&cursor=$cursor" } else { '' }))
    $r = Invoke-Plane GET "$path$q"
    if ($r.PSObject.Properties.Name -contains 'results') { $all += @($r.results) } else { $all += @($r) }
    $more = ($r.PSObject.Properties.Name -contains 'next_page_results') -and $r.next_page_results
    $cursor = if ($more) { $r.next_cursor } else { $null }
  } while ($cursor)
  return $all
}

$rows = Read-Registry $Registry
Write-Host ("Plane {0}  workspace {1}  {2}" -f $BaseUrl, $Workspace, $(if ($Apply) { 'APPLY' } else { 'plan only' }))
Write-Host ("Registry: {0} system(s)" -f $rows.Count)

$projects = Get-All '/projects/'
$changes = 0

foreach ($row in $rows) {
  $proj = $projects | Where-Object { $_.identifier -eq $row.Identifier } | Select-Object -First 1
  Write-Host ""
  if ($proj) {
    Write-Host ("{0,-6} {1}: project exists" -f $row.Identifier, $row.System)
  } else {
    $changes++
    Write-Host ("{0,-6} {1}: create project" -f $row.Identifier, $row.System)
    if ($Apply) {
      $proj = Invoke-Plane POST '/projects/' @{ name = $row.System; identifier = $row.Identifier }
    }
  }

  # A project that does not exist yet (plan mode) has Plane's defaults once created,
  # which include "Done" (completed). Show the plan against those.
  $existingStates = if ($proj) { @(Get-All "/projects/$($proj.id)/states/") } else {
    @([pscustomobject]@{ name = 'Done'; group = 'completed'; default = $false })
  }
  foreach ($s in $States) {
    $have = $existingStates | Where-Object { $_.name -ieq $s.name } | Select-Object -First 1
    if ($have) {
      $note = if ($have.group -ne $s.group) { "  (group is '$($have.group)', expected '$($s.group)' - left as is)" } else { '' }
      if ($s.default -and -not $have.default) {
        $changes++
        Write-Host ("         state {0,-14} make default{1}" -f $s.name, $note)
        if ($Apply) { Invoke-Plane PATCH "/projects/$($proj.id)/states/$($have.id)/" @{ default = $true } | Out-Null }
      } else {
        Write-Host ("         state {0,-14} ok{1}" -f $s.name, $note)
      }
    } else {
      $changes++
      Write-Host ("         state {0,-14} create ({1}{2})" -f $s.name, $s.group, $(if ($s.default) { ', default' } else { '' }))
      if ($Apply) {
        $body = @{ name = $s.name; group = $s.group; color = $s.color }
        if ($s.default) { $body.default = $true }
        Invoke-Plane POST "/projects/$($proj.id)/states/" $body | Out-Null
      }
    }
  }
  $ours = $States | ForEach-Object { $_.name }
  foreach ($x in $existingStates | Where-Object { $ours -notcontains $_.name }) {
    if ($proj) { Write-Host ("         state {0,-14} extra (Plane default), left alone" -f $x.name) }
  }

  $existingLabels = if ($proj) { @(Get-All "/projects/$($proj.id)/labels/") } else { @() }
  foreach ($lab in $Labels) {
    if ($existingLabels | Where-Object { $_.name -ieq $lab.name }) {
      Write-Host ("         label {0,-14} ok" -f $lab.name)
    } else {
      $changes++
      Write-Host ("         label {0,-14} create" -f $lab.name)
      if ($Apply) { Invoke-Plane POST "/projects/$($proj.id)/labels/" @{ name = $lab.name; color = $lab.color } | Out-Null }
    }
  }
}

Write-Host ""
if ($changes -eq 0) {
  Write-Host 'Nothing to do: every system has its project, states and labels.'
} elseif ($Apply) {
  Write-Host "Done: $changes change(s) made. Run again without -Apply to check."
} else {
  Write-Host "$changes change(s) to make. Re-run with -Apply to make them."
}
