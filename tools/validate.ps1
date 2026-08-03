<#
.SYNOPSIS
    Validate the skill package: manifests, frontmatter, and reference cross-links.

.DESCRIPTION
    Checks:
      1. .claude-plugin/plugin.json and marketplace.json parse, and the marketplace
         entry's plugin name matches plugin.json.
      2. Every skills/<dir>/SKILL.md exists, has YAML frontmatter with `name:` equal
         to its directory name and a non-empty `description:`.
      3. Every `references/<file>.md` mentioned inside a SKILL.md actually exists.
      4. Every file under references/ is mentioned by its SKILL.md (no orphans).
      5. commands/*.md and agents/*.md have frontmatter with a description.

    ASCII-only so Windows PowerShell 5.1 parses it without a BOM.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\validate.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$repoRoot = Split-Path -Parent $scriptDir

$errors   = New-Object System.Collections.ArrayList
$warnings = New-Object System.Collections.ArrayList
function Fail([string]$m) { [void]$errors.Add($m) }
function Warn([string]$m) { [void]$warnings.Add($m) }

# --- 1. manifests -------------------------------------------------------------
$pluginPath = Join-Path $repoRoot '.claude-plugin\plugin.json'
$marketPath = Join-Path $repoRoot '.claude-plugin\marketplace.json'

$plugin = $null; $market = $null
foreach ($p in @($pluginPath, $marketPath)) {
    if (-not (Test-Path $p)) { Fail "missing manifest: $p"; continue }
    try { $null = Get-Content -Raw -Encoding UTF8 $p | ConvertFrom-Json }
    catch { Fail "invalid JSON: $p -- $($_.Exception.Message)" }
}
if (Test-Path $pluginPath) { $plugin = Get-Content -Raw -Encoding UTF8 $pluginPath | ConvertFrom-Json }
if (Test-Path $marketPath) { $market = Get-Content -Raw -Encoding UTF8 $marketPath | ConvertFrom-Json }

if ($plugin -and $market) {
    if (-not $plugin.name) { Fail "plugin.json: missing 'name'" }
    if (-not $market.owner -or -not $market.owner.name) { Fail "marketplace.json: missing 'owner.name'" }
    if (-not $market.plugins -or $market.plugins.Count -eq 0) {
        Fail "marketplace.json: 'plugins' is empty"
    } else {
        $names = @($market.plugins | ForEach-Object { $_.name })
        if ($names -notcontains $plugin.name) {
            Fail "marketplace.json lists [$($names -join ', ')] but plugin.json name is '$($plugin.name)'"
        }
        foreach ($p in $market.plugins) {
            if (-not $p.source) { Fail "marketplace.json: plugin '$($p.name)' has no 'source'" }
        }
    }
}

# --- helpers ------------------------------------------------------------------
function Get-Frontmatter([string]$path) {
    $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    if ($text -notmatch '(?s)\A---\r?\n(.*?)\r?\n---\r?\n') { return $null }
    $fmText = $Matches[1]
    $fm = @{}
    foreach ($line in ($fmText -split "\r?\n")) {
        if ($line -match '^([A-Za-z0-9_-]+):\s*(.*)$') { $fm[$Matches[1]] = $Matches[2].Trim() }
    }
    return $fm
}

# --- 2 & 3 & 4. skills --------------------------------------------------------
$skillRoot = Join-Path $repoRoot 'skills'
if (-not (Test-Path $skillRoot)) { Fail "missing skills/ directory" }

$skillDirs = @(Get-ChildItem -Directory $skillRoot)
Write-Host "skills: $($skillDirs.Count)"

foreach ($d in $skillDirs) {
    $skillMd = Join-Path $d.FullName 'SKILL.md'
    if (-not (Test-Path $skillMd)) { Fail "$($d.Name): missing SKILL.md"; continue }

    $fm = Get-Frontmatter $skillMd
    if (-not $fm) { Fail "$($d.Name)/SKILL.md: missing or malformed YAML frontmatter"; continue }
    if (-not $fm.ContainsKey('name')) { Fail "$($d.Name)/SKILL.md: frontmatter has no 'name'" }
    elseif ($fm['name'] -ne $d.Name) { Fail "$($d.Name)/SKILL.md: name '$($fm['name'])' != directory name" }

    if (-not $fm.ContainsKey('description') -or -not $fm['description']) {
        Fail "$($d.Name)/SKILL.md: frontmatter has no 'description'"
    } elseif ($fm['description'].Length -gt 1024) {
        Fail "$($d.Name)/SKILL.md: description is $($fm['description'].Length) chars (limit 1024)"
    } elseif ($fm['description'].Length -lt 40) {
        Warn "$($d.Name)/SKILL.md: description is very short ($($fm['description'].Length) chars)"
    }

    $body = [System.IO.File]::ReadAllText($skillMd, [System.Text.Encoding]::UTF8)
    $mentioned = @{}
    foreach ($m in [regex]::Matches($body, '(?:references/)?([0-9]{2}-[a-z0-9-]+\.md)')) {
        $mentioned[$m.Groups[1].Value] = $true
    }

    $refDir = Join-Path $d.FullName 'references'
    $onDisk = @{}
    if (Test-Path $refDir) {
        Get-ChildItem -File $refDir -Filter *.md | ForEach-Object { $onDisk[$_.Name] = $true }
    }

    foreach ($k in $mentioned.Keys) {
        if (-not $onDisk.ContainsKey($k)) { Fail "$($d.Name)/SKILL.md references missing file: references/$k" }
    }
    foreach ($k in $onDisk.Keys) {
        if (-not $mentioned.ContainsKey($k)) { Warn "$($d.Name): references/$k is never mentioned in SKILL.md" }
    }

    Write-Host ("  {0,-24} refs={1,-3} desc={2} chars" -f $d.Name, $onDisk.Count, $fm['description'].Length)
}

# --- 5. commands & agents -----------------------------------------------------
foreach ($sub in @('commands', 'agents')) {
    $dir = Join-Path $repoRoot $sub
    if (-not (Test-Path $dir)) { Warn "missing $sub/ directory"; continue }
    $files = @(Get-ChildItem -File $dir -Filter *.md)
    Write-Host "$sub`: $($files.Count)"
    foreach ($f in $files) {
        $fm = Get-Frontmatter $f.FullName
        if (-not $fm) { Fail "$sub/$($f.Name): missing or malformed frontmatter"; continue }
        if (-not $fm.ContainsKey('description') -or -not $fm['description']) {
            Fail "$sub/$($f.Name): frontmatter has no 'description'"
        }
        if ($sub -eq 'agents') {
            if (-not $fm.ContainsKey('name')) { Fail "agents/$($f.Name): frontmatter has no 'name'" }
            elseif ($fm['name'] -ne [System.IO.Path]::GetFileNameWithoutExtension($f.Name)) {
                Warn "agents/$($f.Name): name '$($fm['name'])' != filename"
            }
        }
    }
}

# --- report -------------------------------------------------------------------
Write-Host ""
if ($warnings.Count -gt 0) {
    Write-Host "WARNINGS ($($warnings.Count)):"
    $warnings | ForEach-Object { Write-Host "  ! $_" }
    Write-Host ""
}
if ($errors.Count -gt 0) {
    Write-Host "ERRORS ($($errors.Count)):"
    $errors | ForEach-Object { Write-Host "  X $_" }
    exit 1
}
Write-Host "OK - package is valid."
