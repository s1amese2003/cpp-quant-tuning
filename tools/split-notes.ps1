<#
.SYNOPSIS
    Split trading-system-notes-Chinese.md into per-topic reference files under skills/*/references/.

.DESCRIPTION
    The split is driven by tools/section-map.json:
      outer key = an H2 heading of the source notes
      inner key = 1-based ordinal of an H3 subsection inside that H2
      value     = output path relative to skills/

    Output files are verbatim copies of the source subsection; only the
    "### N. Title" line is demoted to "# Title" and a provenance header is added.
    Re-run this script to resync after the upstream notes change.

    NOTE: this file is intentionally ASCII-only so that Windows PowerShell 5.1
    (which parses BOM-less scripts as ANSI) can run it. All CJK text lives in
    section-map.json, which is read explicitly as UTF-8.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\split-notes.ps1
    pwsh -File tools/split-notes.ps1
#>
[CmdletBinding()]
param(
    [string]$Source,
    [string]$MapFile,
    [string]$OutRoot
)

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$repoRoot = Split-Path -Parent $scriptDir

if (-not $Source)  { $Source  = Join-Path $repoRoot 'trading-system-notes-Chinese.md' }
if (-not $MapFile) { $MapFile = Join-Path $scriptDir 'section-map.json' }
if (-not $OutRoot) { $OutRoot = Join-Path $repoRoot 'skills' }

$Source  = (Resolve-Path $Source).Path
$MapFile = (Resolve-Path $MapFile).Path
$OutRoot = [System.IO.Path]::GetFullPath($OutRoot)

Write-Host "source : $Source"
Write-Host "map    : $MapFile"
Write-Host "outRoot: $OutRoot"

$lines = [System.IO.File]::ReadAllLines($Source, [System.Text.Encoding]::UTF8)
$map   = Get-Content -Raw -Encoding UTF8 $MapFile | ConvertFrom-Json

$headerTemplate = $map.'_header' -join "`n"
if (-not $headerTemplate) { throw "section-map.json is missing the _header template." }

# ---- Index every H3 subsection as (part, ordinal) -> [start, end) -------------
$sections = New-Object System.Collections.ArrayList
$currentPart = $null
$ordinal = 0

for ($i = 0; $i -lt $lines.Length; $i++) {
    $line = $lines[$i]
    if ($line -match '^##\s+(.+?)\s*$') {
        $currentPart = $Matches[1]
        $ordinal = 0
        continue
    }
    if ($line -match '^###\s+(.+?)\s*$') {
        if (-not $currentPart) { continue }
        $ordinal++
        [void]$sections.Add([pscustomobject]@{
            Part    = $currentPart
            Ordinal = $ordinal
            Title   = $Matches[1]
            Start   = $i
            End     = $lines.Length
        })
    }
}

for ($k = 0; $k -lt $sections.Count - 1; $k++) {
    $sections[$k].End = $sections[$k + 1].Start
}
# The last subsection of each part ends at the next H2.
foreach ($s in $sections) {
    for ($j = $s.Start + 1; $j -lt $s.End; $j++) {
        if ($lines[$j] -match '^##\s+') { $s.End = $j; break }
    }
}

Write-Host "found $($sections.Count) H3 subsections"

# ---- Emit ---------------------------------------------------------------------
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$written = 0
$missing = New-Object System.Collections.ArrayList

foreach ($partProp in $map.PSObject.Properties) {
    if ($partProp.Name -like '_*') { continue }
    $partName = $partProp.Name

    foreach ($entry in $partProp.Value.PSObject.Properties) {
        if ($entry.Name -like '_*') { continue }
        $ord  = [int]$entry.Name
        $dest = $entry.Value

        $sec = $sections | Where-Object { $_.Part -eq $partName -and $_.Ordinal -eq $ord } | Select-Object -First 1
        if (-not $sec) {
            [void]$missing.Add("$partName #$ord -> $dest")
            continue
        }

        # "1. **Foo**" -> "Foo".  \p{P} covers both "." and the ideographic comma U+3001.
        $title = $sec.Title -replace '^\s*\d+\p{P}?\s*', '' -replace '\*\*', ''

        $header = $headerTemplate.
            Replace('{PART}',    $partName).
            Replace('{HEADING}', $sec.Title).
            Replace('{TITLE}',   $title)

        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine($header)
        [void]$sb.AppendLine()

        for ($j = $sec.Start + 1; $j -lt $sec.End; $j++) {
            [void]$sb.AppendLine($lines[$j])
        }

        $full = Join-Path $OutRoot $dest
        $dir  = Split-Path -Parent $full
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        [System.IO.File]::WriteAllText($full, $sb.ToString(), $utf8NoBom)
        $written++
    }
}

Write-Host "wrote $written reference files"

if ($missing.Count -gt 0) {
    Write-Warning "mapped subsections not found in source:"
    $missing | ForEach-Object { Write-Warning "  $_" }
}

# ---- Report subsections not claimed by any skill ------------------------------
$mapped = @{}
foreach ($partProp in $map.PSObject.Properties) {
    if ($partProp.Name -like '_*') { continue }
    foreach ($entry in $partProp.Value.PSObject.Properties) {
        if ($entry.Name -like '_*') { continue }
        $mapped["$($partProp.Name)#$($entry.Name)"] = $true
    }
}
$orphans = $sections | Where-Object { -not $mapped.ContainsKey("$($_.Part)#$($_.Ordinal)") }
if ($orphans) {
    Write-Warning "subsections not claimed by any skill:"
    $orphans | ForEach-Object { Write-Warning "  $($_.Part) #$($_.Ordinal) $($_.Title)" }
} else {
    Write-Host "all subsections are claimed by a skill"
}
