<#
.SYNOPSIS
    Standardised "Source / Temp / Target" install-path logging trio.

.DESCRIPTION
    User convention: every install/operation MUST surface three paths so we
    always know:
        Source  — where the install was launched from (script dir, repo root,
                  download URL, or installer .exe path)
        Temp    — where intermediate / cache / scratch files are written
        Target  — final install location (Program Files, %LocalAppData%,
                  PATH bin dir, etc.)

    These three lines are printed in a single coloured block right after the
    script banner (or right before a download / extract / install action) and
    a structured `installPaths` event is appended to the JSON log so it is
    grep-able after the fact.

    CODE RED tie-in: missing values ARE allowed but flagged with `(unknown)`
    in yellow. If you genuinely cannot resolve a path, prefer using
    Write-FileError for the underlying problem and pass through `(unknown)`
    rather than silently omitting the field.

.NOTES
    Helper version: 1.0.0
#>

# Dot-source logging helper if Write-Log isn't already loaded
$loggingPath = Join-Path $PSScriptRoot "logging.ps1"
$isLoggingAvailable = Test-Path $loggingPath
if ($isLoggingAvailable -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $loggingPath
}

function Write-InstallPaths {
    <#
    .SYNOPSIS
        Print the 3-path install trio (Source / Temp / Target) and record it
        as a structured event in the JSON log.

    .PARAMETER Source
        Where the install starts from (script path, repo root, download URL,
        or installer .exe). Required — pass "(unknown)" if you genuinely
        cannot resolve it.

    .PARAMETER Temp
        Scratch / cache / download dir. Required.

    .PARAMETER Target
        Final install location. Required.

    .PARAMETER Tool
        Optional friendly name of what is being installed (used for the
        block heading and the JSON event payload).

    .PARAMETER Action
        Optional verb to display in the heading (default: "Install").
        e.g. "Upgrade", "Repair", "Sync", "Extract".

    .EXAMPLE
        Write-InstallPaths `
            -Tool   "Notepad++" `
            -Source $PSCommandPath `
            -Temp   "$env:TEMP\npp-install" `
            -Target "C:\Program Files\Notepad++"
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Source,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Temp,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Target,

        [string]$Tool,

        [string]$Action = "Install"
    )

    # -- Defensive sanity checks ------------------------------------------------
    # If a caller wrote `-Target (C:\Program Files\foo)` without quotes,
    # PowerShell will fail at parse time. But there are subtler failure modes
    # we can still catch at runtime:
    #   1. The string contains an unbalanced "  -- usually means a quoting bug
    #      where the user accidentally embedded a literal quote.
    #   2. The string starts and ends with parens -- a clear sign someone
    #      passed `(C:\foo)` and the value reached us as the literal text.
    #   3. The string contains a newline -- a hint that splat / array binding
    #      collapsed multiple args into one.
    foreach ($pair in @(
        @{ Name = "Source"; Value = $Source },
        @{ Name = "Temp";   Value = $Temp   },
        @{ Name = "Target"; Value = $Target }
    )) {
        $val = "$($pair.Value)"
        if ([string]::IsNullOrEmpty($val)) { continue }

        $quoteChars = @($val.ToCharArray() | Where-Object { $_ -eq '"' })
        $hasUnbalancedQuotes = ($quoteChars.Count % 2) -ne 0
        $looksParenWrapped   = $val.StartsWith('(') -and $val.EndsWith(')')
        $hasNewline          = $val.Contains("`n") -or $val.Contains("`r")

        if ($hasUnbalancedQuotes -or $looksParenWrapped -or $hasNewline) {
            $reason = @()
            if ($hasUnbalancedQuotes) { $reason += "unbalanced quote(s)" }
            if ($looksParenWrapped)   { $reason += "looks paren-wrapped (missing quotes around the path?)" }
            if ($hasNewline)          { $reason += "contains a newline" }
            $hint = ($reason -join "; ")
            $msg  = "Suspicious -$($pair.Name) value passed to Write-InstallPaths: '$val' [$hint]. Wrap path arguments in double quotes (e.g. -$($pair.Name) ""C:\Program Files\foo"")."
            $hasWriteFileError = $null -ne (Get-Command Write-FileError -ErrorAction SilentlyContinue)
            if ($hasWriteFileError) {
                Write-FileError -FilePath $val -Operation "validate" -Reason $msg -Module "Write-InstallPaths"
            } else {
                Write-Warning $msg
            }
        }
    }

    $hasTool = -not [string]::IsNullOrWhiteSpace($Tool)
    $heading = if ($hasTool) { "$Action paths -- $Tool" } else { "$Action paths" }

    $rows = @(
        @{ Label = "Source"; Value = $Source },
        @{ Label = "Temp  "; Value = $Temp   },
        @{ Label = "Target"; Value = $Target }
    )

    Write-Host ""
    Write-Host "  [ PATH ] " -ForegroundColor Magenta -NoNewline
    Write-Host $heading -ForegroundColor White

    foreach ($row in $rows) {
        $val = $row.Value
        $isUnknown = [string]::IsNullOrWhiteSpace($val)
        $displayVal = if ($isUnknown) { "(unknown)" } else { $val }
        $valColor   = if ($isUnknown) { "Yellow" }    else { "Gray"      }

        Write-Host "          $($row.Label) : " -ForegroundColor DarkGray -NoNewline
        Write-Host $displayVal -ForegroundColor $valColor
    }
    Write-Host ""

    # Structured log event so the trio survives in JSON logs
    $hasWriteLog = $null -ne (Get-Command Write-Log -ErrorAction SilentlyContinue)
    if ($hasWriteLog) {
        $payload = "installPaths tool=$Tool action=$Action source=$Source temp=$Temp target=$Target"
        Write-Log $payload -Level "info"
    }
}

function Assert-QuotedPath {
    <#
    .SYNOPSIS
        Helper for install scripts: validates that a path-like argument is a
        single string (not split on whitespace) and warns/errors otherwise.

    .DESCRIPTION
        Use right after binding user-facing parameters to catch the classic
        mistake of `.\run.ps1 -Path C:\Program Files\foo` (where PowerShell
        binds only `C:\Program` to -Path and the rest becomes positional args).

    .PARAMETER Name
        The parameter name (for error messages), e.g. "Path".

    .PARAMETER Value
        The bound value to inspect.

    .PARAMETER Strict
        If set, throws on suspicious values instead of warning.

    .EXAMPLE
        Assert-QuotedPath -Name "Path" -Value $Path -Strict
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()][AllowNull()][string]$Value,
        [switch]$Strict
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }

    $issues = @()
    if ($Value.StartsWith('(') -and $Value.EndsWith(')')) {
        $issues += "looks paren-wrapped -- did you forget quotes?"
    }
    $quoteChars2 = @($Value.ToCharArray() | Where-Object { $_ -eq '"' })
    if (($quoteChars2.Count % 2) -ne 0) {
        $issues += "unbalanced double-quote(s)"
    }
    if ($Value.Contains("`n") -or $Value.Contains("`r")) {
        $issues += "contains a newline (multiple args collapsed into one?)"
    }

    if ($issues.Count -eq 0) { return $true }

    $hint = ($issues -join "; ")
    $example = "$Name `"C:\Program Files\foo`""
    $msg = "-$Name value '$Value' looks malformed [$hint]. Always quote paths, e.g. -$example"

    $hasWriteFileError = $null -ne (Get-Command Write-FileError -ErrorAction SilentlyContinue)
    if ($hasWriteFileError) {
        Write-FileError -FilePath $Value -Operation "validate" -Reason $msg -Module "Assert-QuotedPath"
    } else {
        Write-Warning $msg
    }

    if ($Strict) { throw $msg }
    return $false
}

function Resolve-DefaultTempDir {
    <#
    .SYNOPSIS
        Convenience: return a per-tool temp dir under $env:TEMP, creating it
        if needed.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ToolSlug
    )
    $base = $env:TEMP
    if ([string]::IsNullOrWhiteSpace($base)) { $base = [System.IO.Path]::GetTempPath() }
    $dir = Join-Path $base "scripts-fixer\$ToolSlug"
    $isPresent = Test-Path $dir
    if (-not $isPresent) {
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch { }
    }
    return $dir
}
