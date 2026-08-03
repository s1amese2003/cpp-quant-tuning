<#
.SYNOPSIS
    Install cpp-quant-tuning skills into agent tools (Windows / PowerShell).

.DESCRIPTION
    Targets:
      codex        Codex CLI        -> $env:CODEX_HOME or ~/.codex  (skills + prompts + AGENTS.md)
      cursor       Cursor/Windsurf/Cline -> prints project-level instructions
      claude-user  Claude Code user skills -> ~/.claude/skills
      generic      Copy skills/ to an arbitrary directory (-Dest required)

    Claude Code's recommended install is via marketplace; see README. This script is
    for the other tools.

    NOTE: ASCII-only so Windows PowerShell 5.1 can parse it without a BOM.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\install.ps1 -Target codex
    pwsh -File tools/install.ps1 -Target generic -Dest C:\proj\.agent\skills
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('codex', 'cursor', 'claude-user', 'generic')]
    [string]$Target,

    [string]$Dest
)

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$repoRoot = Split-Path -Parent $scriptDir

function Copy-Skills([string]$destRoot) {
    if (-not (Test-Path $destRoot)) { New-Item -ItemType Directory -Force -Path $destRoot | Out-Null }
    Get-ChildItem -Directory (Join-Path $repoRoot 'skills') | ForEach-Object {
        $to = Join-Path $destRoot $_.Name
        if (Test-Path $to) { Remove-Item -Recurse -Force $to }
        Copy-Item -Recurse -Force $_.FullName $to
        Write-Host "  -> skills/$($_.Name) => $to"
    }
}

switch ($Target) {

    'codex' {
        $codexHome = $env:CODEX_HOME
        if (-not $codexHome) { $codexHome = Join-Path $HOME '.codex' }
        Write-Host "Installing into Codex: $codexHome"

        Copy-Skills (Join-Path $codexHome 'skills')

        $prompts = Join-Path $codexHome 'prompts'
        if (-not (Test-Path $prompts)) { New-Item -ItemType Directory -Force -Path $prompts | Out-Null }
        Get-ChildItem (Join-Path $repoRoot 'commands') -Filter *.md | ForEach-Object {
            Copy-Item -Force $_.FullName (Join-Path $prompts $_.Name)
            Write-Host "  -> commands/$($_.Name) => $prompts"
        }

        $globalAgents = Join-Path $codexHome 'AGENTS.md'
        $mark = '<!-- cpp-quant-tuning -->'
        $existing = ''
        if (Test-Path $globalAgents) { $existing = Get-Content -Raw -Encoding UTF8 $globalAgents }

        if ($existing -like "*$mark*") {
            Write-Host "  -> reference already present in $globalAgents"
        } else {
            $playbook = Join-Path $codexHome 'skills\quant-dev-playbook\SKILL.md'
            $block = @"

$mark
## Quant development skills

For any quantitative trading / low-latency / market-data / order / strategy task,
first read: ``$playbook``
then follow its routing table. Full guide: $repoRoot\AGENTS.md
"@
            Add-Content -Path $globalAgents -Value $block -Encoding UTF8
            Write-Host "  -> appended reference to $globalAgents"
        }

        Write-Host ""
        Write-Host "Done. Try /quant-review in Codex, or just ask it to optimize a hot path."
    }

    'cursor' {
        Write-Host "Cursor / Windsurf / Cline read AGENTS.md - this repo's AGENTS.md is the entry point."
        Write-Host ""
        Write-Host "  A. As a submodule (recommended):"
        Write-Host "     git submodule add <repo-url> .agent/cpp-quant-tuning"
        Write-Host "     then add to your project's AGENTS.md / .cursorrules:"
        Write-Host "       For quant tasks, first read .agent/cpp-quant-tuning/skills/quant-dev-playbook/SKILL.md"
        Write-Host ""
        Write-Host "  B. Plain copy:"
        Write-Host "     tools\install.ps1 -Target generic -Dest C:\proj\.agent\skills"
    }

    'claude-user' {
        $dest = $env:CLAUDE_CONFIG_DIR
        if (-not $dest) { $dest = Join-Path $HOME '.claude' }
        $dest = Join-Path $dest 'skills'
        Write-Host "Installing user-level Claude Code skills into: $dest"
        Write-Host "(marketplace install is recommended instead - see README; this path omits commands/agents)"
        Copy-Skills $dest
    }

    'generic' {
        if (-not $Dest) { throw "-Dest is required for -Target generic" }
        Write-Host "Copying skills into: $Dest"
        Copy-Skills $Dest
    }
}
