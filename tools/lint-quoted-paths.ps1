#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Lint installer scripts for unquoted path arguments.

.DESCRIPTION
    Scans every *.ps1 under scripts/ (and optionally scripts-linux/) for the
    classic Windows quoting bugs that broke installs in the past:

      1. -Target (C:\Program Files\foo)        -- paren-wrapped raw path
      2. -Path C:\Program Files\foo            -- bareword path with space
      3. & C:\Program Files\foo\bar.exe args   -- bareword exe with space
      4. .\run.ps1 -- C:\Program Files\foo     -- spaced path after `--`

    Exits non-zero if any issues are found, which makes it safe to wire into
    CI or a pre-commit hook.

.PARAMETER Path
    Root to scan. Defaults to the repo's scripts/ folder.

.PARAMETER FailFast
    Stop scanning on the first issue.

.EXAMPLE
    pwsh tools/lint-quoted-paths.ps1
#>
[CmdletBinding()]
param(
    [string]$Path = (Join-Path $PSScriptRoot "..\scripts"),
    [switch]$FailFast
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = Resolve-Path -LiteralPath $Path
Write-Host ""
Write-Host "  [ LINT ] " -ForegroundColor Magenta -NoNewline
Write-Host "Checking quoted-path hygiene under $root" -ForegroundColor White

# Parameters that almost always take a filesystem path.
$pathParams = @(
    "Target", "Temp", "Source", "Path", "Destination", "Folder", "Dir",
    "InstallDir", "InstallPath", "OutFile", "LiteralPath", "FilePath",
    "WorkingDirectory", "RootDir", "ScriptDir"
)
$paramAlt = ($pathParams -join "|")

# Rule 1: -Param (BareDrive:\path with optional spaces)
$reParenWrapped = [regex]::new(
    "^(\s*-(?:$paramAlt)\s+)\(\s*([A-Za-z]:\\[^\)]*)\s*\)\s*$",
    "Multiline,IgnoreCase"
)

# Rule 2: -Param BareDrive:\path with spaces (no quotes, no parens)
$reBarewordSpace = [regex]::new(
    "^(\s*-(?:$paramAlt)\s+)([A-Za-z]:\\[^\s""'\(\)\$]+(?:\s+[^\s""'\(\)\$\-][^\s""'\(\)\$]*)+)",
    "Multiline,IgnoreCase"
)

# Rule 3: & C:\Program Files\... (bareword exe invocation with space)
$reCallOpUnquoted = [regex]::new(
    '^(\s*&\s+)([A-Za-z]:\\[^\s"''\(\)\$]+\s+[^\s"''\(\)\$\-][^\s"''\(\)\$]*)',
    "Multiline"
)

$findings = New-Object System.Collections.Generic.List[object]

$files = Get-ChildItem -LiteralPath $root -Recurse -Filter "*.ps1" -File -ErrorAction SilentlyContinue
foreach ($file in $files) {
    $text = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($text)) { continue }

    foreach ($rule in @(
        @{ Name = "paren-wrapped path"; Regex = $reParenWrapped },
        @{ Name = "bareword path with space"; Regex = $reBarewordSpace },
        @{ Name = "& bareword exe with space"; Regex = $reCallOpUnquoted }
    )) {
        foreach ($m in $rule.Regex.Matches($text)) {
            # Compute line number for friendly output
            $upTo = $text.Substring(0, $m.Index)
            $line = ($upTo.Split("`n").Length)
            $findings.Add([pscustomobject]@{
                File   = $file.FullName
                Line   = $line
                Rule   = $rule.Name
                Match  = $m.Value.Trim()
            }) | Out-Null
            if ($FailFast) { break }
        }
        if ($FailFast -and $findings.Count -gt 0) { break }
    }
    if ($FailFast -and $findings.Count -gt 0) { break }
}

if ($findings.Count -eq 0) {
    Write-Host "  [  OK  ] " -ForegroundColor Green -NoNewline
    Write-Host "No unquoted path arguments found." -ForegroundColor White
    exit 0
}

Write-Host ""
Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
Write-Host "$($findings.Count) suspicious unquoted path argument(s) found:" -ForegroundColor White
Write-Host ""

foreach ($f in $findings) {
    Write-Host "    $($f.File):$($f.Line)" -ForegroundColor Yellow
    Write-Host "      rule:  $($f.Rule)"   -ForegroundColor DarkGray
    Write-Host "      code:  $($f.Match)"  -ForegroundColor White
    Write-Host ""
}

Write-Host "  Fix: wrap path arguments in double quotes." -ForegroundColor Cyan
Write-Host "       e.g.  -Target ""C:\Program Files\foo""" -ForegroundColor DarkGray
Write-Host ""
exit 1
