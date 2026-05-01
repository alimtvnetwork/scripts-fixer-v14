<#
.SYNOPSIS
    Go installation, GOPATH resolution, PATH management, and go env configuration.

.DESCRIPTION
    Adapted from user's existing go-install.ps1. Uses shared helpers for
    Chocolatey, PATH manipulation, and dev directory resolution.
#>

# -- Bootstrap shared helpers --------------------------------------------------
$_sharedDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "shared"
$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}



function Update-SessionPathFromRegistry {
    <#
    .SYNOPSIS
        Rebuilds $env:Path from the Machine + User registry hives.
        This mirrors what Chocolatey's `refreshenv` does for PATH so a freshly
        installed tool becomes visible without opening a new terminal.
    .OUTPUTS
        [int] number of PATH entries that were not present before.
    #>
    $oldEntries = @($env:Path -split ';' | Where-Object { $_ })
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user    = [Environment]::GetEnvironmentVariable("Path", "User")
    $combined = @()
    if ($machine) { $combined += ($machine -split ';' | Where-Object { $_ }) }
    if ($user)    { $combined += ($user    -split ';' | Where-Object { $_ }) }
    # De-duplicate while preserving order
    $seen = @{}
    $deduped = foreach ($e in $combined) {
        $k = $e.TrimEnd('\').ToLowerInvariant()
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $e }
    }
    $env:Path = ($deduped -join ';')
    $added = @($deduped | Where-Object { $_ -notin $oldEntries }).Count
    return $added
}

function Invoke-RefreshEnv {
    <#
    .SYNOPSIS
        Best-effort wrapper around Chocolatey's `refreshenv` helper script.
        Returns $true if the helper ran without throwing.
    #>
    $helper = Join-Path $env:ProgramData "chocolatey\bin\RefreshEnv.cmd"
    $hasHelper = Test-Path -LiteralPath $helper
    if (-not $hasHelper) { return $false }
    try {
        # Run inside cmd.exe and re-import any env vars it set
        $envDump = & cmd.exe /c "`"$helper`" >nul 2>&1 && set"
        foreach ($line in $envDump) {
            if ($line -match '^([^=]+)=(.*)$') {
                $name  = $matches[1]
                $value = $matches[2]
                # Skip cmd-internal vars
                if ($name -in @('PROMPT','COMSPEC','CD','ERRORLEVEL','=ExitCode')) { continue }
                Set-Item -Path "Env:\$name" -Value $value -ErrorAction SilentlyContinue
            }
        }
        return $true
    } catch {
        return $false
    }
}

function Set-GoRootGopathFallback {
    <#
    .SYNOPSIS
        Last-ditch recovery: when `go version` fails but a `go.exe` was found
        on disk, derive GOROOT from its parent layout and pick a sensible
        GOPATH, then persist both for the current process AND the User scope
        so the very next `go` invocation (and future shells) work.
    .OUTPUTS
        Hashtable: Success (bool), Goroot (string), Gopath (string).
    #>
    param(
        [Parameter(Mandatory)] [string]$GoExe,
        $LogMessages
    )

    $msgs    = $LogMessages.messages
    $binDir  = Split-Path -Parent $GoExe                 # ...\Go\bin
    $goRoot  = Split-Path -Parent $binDir                # ...\Go
    $expected = Join-Path (Join-Path $goRoot "bin") "go.exe"

    $isLayoutValid = Test-Path -LiteralPath $expected
    if (-not $isLayoutValid) {
        Write-Log (($msgs.goRootInvalid -replace '\{goexe\}', $GoExe) -replace '\{goroot\}', $goRoot) -Level "warn"
        Write-FileError -FilePath $expected -Operation "validate-goroot-layout" `
            -Reason "Expected '$expected' to exist after deriving GOROOT from '$GoExe'." `
            -Module "Set-GoRootGopathFallback"
        return @{ Success = $false; Goroot = $null; Gopath = $null }
    }

    Write-Log (($msgs.goRootDerived -replace '\{goroot\}', $goRoot) -replace '\{goexe\}', $GoExe) -Level "info"

    # ---- GOROOT (process + user scope) -------------------------------------
    try {
        $env:GOROOT = $goRoot
        [Environment]::SetEnvironmentVariable("GOROOT", $goRoot, "User")
        Write-Log ($msgs.goRootSet -replace '\{goroot\}', $goRoot) -Level "success"
    } catch {
        Write-FileError -FilePath $goRoot -Operation "set-goroot" -Reason "$_" -Module "Set-GoRootGopathFallback"
        return @{ Success = $false; Goroot = $null; Gopath = $null }
    }

    # ---- GOPATH (only set if not already a valid value) --------------------
    $existingGopath = $env:GOPATH
    if ([string]::IsNullOrWhiteSpace($existingGopath)) {
        $existingGopath = [Environment]::GetEnvironmentVariable("GOPATH", "User")
    }

    $gopathSource = "existing GOPATH"
    $gopathValue  = $existingGopath
    $needsGopath  = [string]::IsNullOrWhiteSpace($gopathValue)
    if ($needsGopath) {
        if (-not [string]::IsNullOrWhiteSpace($env:DEV_DIR)) {
            $gopathValue  = Join-Path $env:DEV_DIR "go"
            $gopathSource = "DEV_DIR"
        } elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
            $gopathValue  = Join-Path $env:USERPROFILE "go"
            $gopathSource = "USERPROFILE"
        } else {
            $gopathValue  = "C:\go"
            $gopathSource = "hardcoded fallback"
        }

        try {
            $isGopathDirMissing = -not (Test-Path -LiteralPath $gopathValue)
            if ($isGopathDirMissing) {
                New-Item -Path $gopathValue -ItemType Directory -Force -Confirm:$false | Out-Null
            }
            $env:GOPATH = $gopathValue
            [Environment]::SetEnvironmentVariable("GOPATH", $gopathValue, "User")
            Write-Log (($msgs.goPathFallbackSet -replace '\{gopath\}', $gopathValue) -replace '\{source\}', $gopathSource) -Level "success"
        } catch {
            Write-FileError -FilePath $gopathValue -Operation "set-gopath-fallback" -Reason "$_" -Module "Set-GoRootGopathFallback"
            return @{ Success = $false; Goroot = $goRoot; Gopath = $null }
        }
    }

    # Make sure GOROOT\bin is in this session's PATH so `go.exe` resolves.
    $hasBinOnPath = ($env:Path -split ';' | Where-Object { $_ -and ($_.TrimEnd('\').ToLowerInvariant() -eq $binDir.TrimEnd('\').ToLowerInvariant()) }).Count -gt 0
    if (-not $hasBinOnPath) {
        $env:Path = "$binDir;$env:Path"
    }

    return @{ Success = $true; Goroot = $goRoot; Gopath = $gopathValue }
}

function Assert-GoOnPath {
    <#
    .SYNOPSIS
        Verifies that `go version` works in the current session. Recovers the
        PATH from the registry (and Chocolatey's refreshenv) if needed, and
        falls back to probing well-known install locations.
    .OUTPUTS
        Hashtable: Success (bool), Version (string), GoExe (string),
                   Report (ordered hashtable -- structured verification trail).
    #>
    param(
        $LogMessages
    )

    Write-Log $LogMessages.messages.goVerifyStart -Level "info"

    # ---- Structured report scaffold ---------------------------------------
    $report = [ordered]@{
        startedAt    = (Get-Date).ToString("o")
        host         = $env:COMPUTERNAME
        user         = $env:USERNAME
        initialPath  = $env:Path
        attempts     = New-Object System.Collections.Generic.List[object]
        pathRefreshes= New-Object System.Collections.Generic.List[object]
        finalSuccess = $false
        finalVersion = $null
        finalGoExe   = $null
        finalPath    = $null
        finishedAt   = $null
    }

    function Test-GoVersion {
        $cmd = Get-Command go.exe -ErrorAction SilentlyContinue
        if (-not $cmd) { return $null }
        try {
            $out = & $cmd.Source version 2>&1
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($out)) {
                return @{ Version = "$out".Trim(); GoExe = $cmd.Source }
            }
        } catch { }
        return $null
    }

    function Add-Attempt($name, $detail, $result) {
        $report.attempts.Add([ordered]@{
            name      = $name
            detail    = $detail
            timestamp = (Get-Date).ToString("o")
            success   = [bool]$result
            version   = if ($result) { $result.Version } else { $null }
            goExe     = if ($result) { $result.GoExe }   else { $null }
        }) | Out-Null
    }

    function Complete-Report($result) {
        $report.finalSuccess = [bool]$result
        $report.finalVersion = if ($result) { $result.Version } else { $null }
        $report.finalGoExe   = if ($result) { $result.GoExe }   else { $null }
        $report.finalPath    = $env:Path
        $report.finishedAt   = (Get-Date).ToString("o")
    }

    # Attempt 1: current session as-is
    $result = Test-GoVersion
    Add-Attempt "session-as-is" "Try Get-Command go.exe in the current session" $result
    if ($result) {
        Write-Log ($LogMessages.messages.goVerifyOk -replace '\{version\}', $result.Version) -Level "success"
        Complete-Report $result
        return @{ Success = $true; Version = $result.Version; GoExe = $result.GoExe; Report = $report }
    }

    # Attempt 2: rebuild PATH from registry (mirrors `refreshenv`)
    Write-Log $LogMessages.messages.goVerifyMissing -Level "warn"
    $beforePath = $env:Path
    $added = Update-SessionPathFromRegistry
    $report.pathRefreshes.Add([ordered]@{
        method       = "Update-SessionPathFromRegistry"
        timestamp    = (Get-Date).ToString("o")
        entriesAdded = [int]$added
        beforeLength = $beforePath.Length
        afterLength  = $env:Path.Length
    }) | Out-Null
    Write-Log ($LogMessages.messages.goVerifyRefreshed -replace '\{count\}', "$added") -Level "info"
    $result = Test-GoVersion
    Add-Attempt "registry-path-refresh" "Rebuilt PATH from Machine+User registry hives" $result
    if ($result) {
        Write-Log ($LogMessages.messages.goVerifyOk -replace '\{version\}', $result.Version) -Level "success"
        Complete-Report $result
        return @{ Success = $true; Version = $result.Version; GoExe = $result.GoExe; Report = $report }
    }

    # Attempt 3: Chocolatey's refreshenv.cmd
    Write-Log $LogMessages.messages.goVerifyRefreshenv -Level "info"
    $beforePath = $env:Path
    $refreshOk  = Invoke-RefreshEnv
    $report.pathRefreshes.Add([ordered]@{
        method       = "Invoke-RefreshEnv (chocolatey RefreshEnv.cmd)"
        timestamp    = (Get-Date).ToString("o")
        ranWithoutError = [bool]$refreshOk
        beforeLength = $beforePath.Length
        afterLength  = $env:Path.Length
    }) | Out-Null
    $result = Test-GoVersion
    Add-Attempt "chocolatey-refreshenv" "Ran Chocolatey's RefreshEnv.cmd helper" $result
    if ($result) {
        Write-Log ($LogMessages.messages.goVerifyOk -replace '\{version\}', $result.Version) -Level "success"
        Complete-Report $result
        return @{ Success = $true; Version = $result.Version; GoExe = $result.GoExe; Report = $report }
    }

    # Attempt 4: probe well-known install locations
    $candidates = @(
        "C:\Program Files\Go\bin\go.exe",
        "C:\Program Files (x86)\Go\bin\go.exe",
        (Join-Path $env:ProgramData "chocolatey\lib\golang\tools\go\bin\go.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Go\bin\go.exe")
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    Write-Log ($LogMessages.messages.goVerifyProbe -replace '\{paths\}', ($candidates -join '; ')) -Level "info"

    $probeResults = New-Object System.Collections.Generic.List[object]
    $discoveredGoExe = $null
    foreach ($candidate in $candidates) {
        $probeEntry = [ordered]@{ path = $candidate; exists = $false; prependedToPath = $false }
        if (Test-Path -LiteralPath $candidate) {
            $probeEntry.exists = $true
            if (-not $discoveredGoExe) { $discoveredGoExe = $candidate }
            $binDir = Split-Path -Parent $candidate
            Write-Log ($LogMessages.messages.goVerifyFoundAt -replace '\{path\}', $candidate) -Level "warn"
            $env:Path = "$binDir;$env:Path"
            $probeEntry.prependedToPath = $true
            $result = Test-GoVersion
            $probeEntry.versionAfter = if ($result) { $result.Version } else { $null }
            $probeResults.Add($probeEntry) | Out-Null
            if ($result) {
                Add-Attempt "probe-known-locations" "Found at $candidate; prepended $binDir to PATH" $result
                $report.probedCandidates = $probeResults
                Write-Log ($LogMessages.messages.goVerifyOk -replace '\{version\}', $result.Version) -Level "success"
                Complete-Report $result
                return @{ Success = $true; Version = $result.Version; GoExe = $result.GoExe; Report = $report }
            }
        } else {
            $probeResults.Add($probeEntry) | Out-Null
        }
    }
    $report.probedCandidates = $probeResults
    Add-Attempt "probe-known-locations" "Probed $($candidates.Count) candidate path(s); none made 'go version' run" $null

    # Attempt 5: GOROOT/GOPATH fallback
    if ($discoveredGoExe) {
        Write-Log $LogMessages.messages.goRootFallbackStart -Level "warn"
        $fb = Set-GoRootGopathFallback -GoExe $discoveredGoExe -LogMessages $LogMessages
        $report.gorootFallback = [ordered]@{
            triedAt    = (Get-Date).ToString("o")
            sourceGoExe= $discoveredGoExe
            success    = [bool]$fb.Success
            goroot     = $fb.Goroot
            gopath     = $fb.Gopath
        }
        if ($fb.Success) {
            $result = Test-GoVersion
            Add-Attempt "goroot-gopath-fallback" "Set GOROOT=$($fb.Goroot), GOPATH=$($fb.Gopath)" $result
            if ($result) {
                Write-Log $LogMessages.messages.goRootFallbackOk -Level "success"
                Write-Log ($LogMessages.messages.goVerifyOk -replace '\{version\}', $result.Version) -Level "success"
                Complete-Report $result
                return @{ Success = $true; Version = $result.Version; GoExe = $result.GoExe; Report = $report }
            }
            Write-Log $LogMessages.messages.goRootFallbackFailed -Level "error"
        } else {
            Add-Attempt "goroot-gopath-fallback" "Set-GoRootGopathFallback returned Success=false" $null
        }
    }

    # Give up
    Write-FileError -FilePath "go.exe" -Operation "resolve" -Reason $LogMessages.messages.goVerifyFinalFail -Module "Assert-GoOnPath"
    Complete-Report $null
    return @{ Success = $false; Version = $null; GoExe = $null; Report = $report }
}

function Get-ChocoGoLibPath {
    <#
    .SYNOPSIS
        Reports where Chocolatey installed a package on disk so we can log the
        exact lib/tools paths next to a verification result.
    .OUTPUTS
        Hashtable: Found (bool), LibPath (string), ToolsGoPath (string),
                   Version (string), ProbeRoot (string), Error (string).
    #>
    param(
        [Parameter(Mandatory)] [string]$PackageName,
        $LogMessages
    )

    $msgs = $LogMessages.messages
    Write-Log ($msgs.chocoLibProbeStart -replace '\{pkg\}', $PackageName) -Level "info"

    # Resolve Chocolatey root via shared helper (env -> registry -> PATH -> default)
    $hasResolver = [bool](Get-Command Resolve-ChocolateyInstallRoot -ErrorAction SilentlyContinue)
    if ($hasResolver) {
        $chocoRoot = Resolve-ChocolateyInstallRoot
        $hasChocoRoot = -not [string]::IsNullOrWhiteSpace($chocoRoot)
        if (-not $hasChocoRoot) {
            $chocoRoot = Join-Path $env:ProgramData "chocolatey"
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($env:ChocolateyInstall)) {
        $chocoRoot = $env:ChocolateyInstall
    } else {
        $chocoRoot = Join-Path $env:ProgramData "chocolatey"
    }
    $libRoot   = Join-Path $chocoRoot "lib"
    $libPath   = Join-Path $libRoot $PackageName
    $toolsRoot = Join-Path $libPath "tools"
    $toolsGo   = Join-Path $toolsRoot "go"

    # Probe existence of every link in the chain so we can ALWAYS log the
    # exact tools\go path -- even when the lib folder is missing.
    $isChocoRootPresent = Test-Path -LiteralPath $chocoRoot
    $isLibRootPresent   = Test-Path -LiteralPath $libRoot
    $isLibPathPresent   = Test-Path -LiteralPath $libPath
    $isToolsRootPresent = Test-Path -LiteralPath $toolsRoot
    $isToolsGoPresent   = Test-Path -LiteralPath $toolsGo

    Write-Log ((($msgs.chocoLibToolsParentState `
        -replace '\{chocoRoot\}',       $chocoRoot) `
        -replace '\{chocoRootExists\}', "$isChocoRootPresent" `
        -replace '\{libRoot\}',         $libRoot `
        -replace '\{libRootExists\}',   "$isLibRootPresent" `
        -replace '\{libPath\}',         $libPath `
        -replace '\{libPathExists\}',   "$isLibPathPresent" `
        -replace '\{toolsRoot\}',       $toolsRoot `
        -replace '\{toolsRootExists\}', "$isToolsRootPresent")) -Level "info"
    Write-Log (($msgs.chocoLibToolsGoExpected `
        -replace '\{toolspath\}', $toolsGo) `
        -replace '\{exists\}',    "$isToolsGoPresent") -Level "info"

    $result = @{
        Found       = $false
        LibPath     = $null
        ToolsGoPath = $toolsGo            # always populated -- caller decides what to do with it
        ToolsGoExists = $isToolsGoPresent # bool: whether that path exists on disk
        Version     = $null
        ProbeRoot   = $libRoot
        Error       = $null
    }

    try {
        if (-not $isLibPathPresent) {
            Write-Log (($msgs.chocoLibMissing -replace '\{pkg\}', $PackageName) -replace '\{root\}', $libRoot) -Level "warn"
            # Still surface the tools/go expected path explicitly even though
            # the lib folder is missing -- aids post-mortem on broken installs.
            if (-not $isToolsGoPresent) {
                Write-Log ($msgs.chocoLibToolsGoMissing -replace '\{toolspath\}', $toolsGo) -Level "warn"
                Write-FileError -FilePath $toolsGo -Operation "probe-choco-tools-go" `
                    -Reason "Expected Chocolatey tools/go folder for package '$PackageName' does not exist (parent lib folder $libPath also missing)." `
                    -Module "Get-ChocoGoLibPath"
            }
            Write-FileError -FilePath $libPath -Operation "probe-choco-lib" `
                -Reason "Chocolatey lib folder for package '$PackageName' does not exist." `
                -Module "Get-ChocoGoLibPath"
            return $result
        }

        $result.Found   = $true
        $result.LibPath = $libPath
        Write-Log (($msgs.chocoLibFound -replace '\{pkg\}', $PackageName) -replace '\{libpath\}', $libPath) -Level "success"

        # tools\go layout used by the golang chocolatey package
        if ($isToolsGoPresent) {
            Write-Log ($msgs.chocoLibToolsFound -replace '\{toolspath\}', $toolsGo) -Level "info"
        } else {
            Write-Log ($msgs.chocoLibToolsGoMissing -replace '\{toolspath\}', $toolsGo) -Level "warn"
            Write-FileError -FilePath $toolsGo -Operation "probe-choco-tools-go" `
                -Reason "Chocolatey lib folder for '$PackageName' exists at $libPath but tools/go subfolder is missing." `
                -Module "Get-ChocoGoLibPath"
        }

        # Try .nuspec first (cheap, no choco.exe spawn)
        $nuspec = Get-ChildItem -LiteralPath $libPath -Filter *.nuspec -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($nuspec) {
            try {
                [xml]$xml = Get-Content -LiteralPath $nuspec.FullName -Raw
                $ver = $xml.package.metadata.version
                if (-not [string]::IsNullOrWhiteSpace($ver)) {
                    $result.Version = "$ver".Trim()
                }
            } catch {
                Write-FileError -FilePath $nuspec.FullName -Operation "parse-nuspec" -Reason "$_" -Module "Get-ChocoGoLibPath"
            }
        }

        # Fallback to `choco list --local-only` if we still have no version
        if ([string]::IsNullOrWhiteSpace($result.Version)) {
            $chocoExe = Join-Path $chocoRoot "bin\choco.exe"
            $isChocoExePresent = Test-Path -LiteralPath $chocoExe
            if (-not $isChocoExePresent) {
                Write-Log ($msgs.chocoListExeMissing -replace '\{exe\}', $chocoExe) -Level "warn"
                Write-FileError -FilePath $chocoExe -Operation "choco-list" `
                    -Reason "Cannot run 'choco list' fallback: choco.exe missing at expected path." `
                    -Module "Get-ChocoGoLibPath"
            } else {
                Write-Log (($msgs.chocoListProbeStart -replace '\{pkg\}', $PackageName) -replace '\{exe\}', $chocoExe) -Level "info"
                try {
                    # Capture merged stdout+stderr so we can log it on failure
                    $listOut = & $chocoExe list --local-only --limit-output $PackageName 2>&1
                    $listExit = $LASTEXITCODE
                    $rawLines = @($listOut | ForEach-Object { "$_" })
                    Write-Log (($msgs.chocoListExitCode -replace '\{code\}', "$listExit") -replace '\{lines\}', "$($rawLines.Count)") -Level "info"

                    foreach ($line in $rawLines) {
                        if ($line -match "^$([regex]::Escape($PackageName))\|(.+)$") {
                            $result.Version = $matches[1].Trim()
                            break
                        }
                    }

                    # No match -> log a sanitized snippet so operators can see WHY
                    if ([string]::IsNullOrWhiteSpace($result.Version)) {
                        $rawText = ($rawLines -join [Environment]::NewLine)
                        # Reuse the shared sanitizer (drops Progress: NN%, MB-of-MB ticks, blank runs)
                        $hasSanitizer = [bool](Get-Command ConvertTo-CleanChocoOutput -ErrorAction SilentlyContinue)
                        $clean = if ($hasSanitizer) { ConvertTo-CleanChocoOutput -Text $rawText } else { $rawText.Trim() }
                        $cleanLines = @($clean -split "(`r`n|`n)" | Where-Object { $_ -and ($_ -notmatch '^(\r\n|\n)$') })

                        $isEmpty = $cleanLines.Count -eq 0
                        if ($isEmpty) {
                            Write-Log (($msgs.chocoListEmpty -replace '\{pkg\}', $PackageName) -replace '\{code\}', "$listExit") -Level "warn"
                            Write-FileError -FilePath $chocoExe -Operation "choco-list" `
                                -Reason "'choco list --local-only --limit-output $PackageName' returned no output (exit $listExit)." `
                                -Module "Get-ChocoGoLibPath"
                        } else {
                            # Head + tail snippet so the log line stays bounded but useful
                            $headN = [Math]::Min(8, $cleanLines.Count)
                            $tailN = [Math]::Min(4, [Math]::Max(0, $cleanLines.Count - $headN))
                            $headLines = $cleanLines[0..($headN - 1)]
                            $tailLines = if ($tailN -gt 0) { $cleanLines[($cleanLines.Count - $tailN)..($cleanLines.Count - 1)] } else { @() }
                            $snippetParts = @($headLines)
                            if ($cleanLines.Count -gt ($headN + $tailN)) { $snippetParts += "... ($($cleanLines.Count - $headN - $tailN) lines omitted) ..." }
                            if ($tailN -gt 0) { $snippetParts += $tailLines }
                            $snippet = ($snippetParts -join ' | ')

                            $msg = ((($msgs.chocoListNoMatch `
                                -replace '\{pkg\}',     $PackageName) `
                                -replace '\{head\}',    "$headN") `
                                -replace '\{tail\}',    "$tailN") `
                                -replace '\{snippet\}', $snippet
                            Write-Log $msg -Level "warn"
                            Write-FileError -FilePath $chocoExe -Operation "choco-list" `
                                -Reason "No '$PackageName|<version>' line in 'choco list' output (exit $listExit). Sanitized snippet: $snippet" `
                                -Module "Get-ChocoGoLibPath"
                        }
                    }
                } catch {
                    Write-FileError -FilePath $chocoExe -Operation "choco-list" -Reason "$_" -Module "Get-ChocoGoLibPath"
                }
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($result.Version)) {
            Write-Log ($msgs.chocoLibVersion -replace '\{version\}', $result.Version) -Level "info"
        }
    } catch {
        $result.Error = "$_"
        Write-Log (($msgs.chocoLibProbeError -replace '\{pkg\}', $PackageName) -replace '\{error\}', "$_") -Level "warn"
        Write-FileError -FilePath $libPath -Operation "probe-choco-lib" -Reason "$_" -Module "Get-ChocoGoLibPath"
    }

    return $result
}

function Write-GoVerifyReport {
    <#
    .SYNOPSIS
        Persists the structured Assert-GoOnPath report to logs/go-verify-report.json
        next to the script. Always emits a file -- success or failure -- so
        operators have a single artifact to inspect.
    .OUTPUTS
        [string] absolute path of the JSON file, or $null on write failure.
    #>
    param(
        [Parameter(Mandatory)] $Verify,
        $ChocoLib,
        [string]$PackageName
    )

    $scriptRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $thisScriptDir = Split-Path -Parent $PSScriptRoot   # scripts/06-install-golang
    $logsDir = Join-Path $thisScriptDir "logs"
    if (-not (Test-Path -LiteralPath $logsDir)) {
        try { New-Item -Path $logsDir -ItemType Directory -Force -Confirm:$false | Out-Null }
        catch {
            Write-FileError -FilePath $logsDir -Operation "create-logs-dir" -Reason "$_" -Module "Write-GoVerifyReport"
            return $null
        }
    }

    $reportPath = Join-Path $logsDir "go-verify-report.json"

    $payload = [ordered]@{
        schema       = "scripts-fixer/go-verify-report/v1"
        generatedAt  = (Get-Date).ToString("o")
        scriptId     = "06-install-golang"
        packageName  = $PackageName
        verification = $Verify.Report
        summary      = [ordered]@{
            success      = [bool]$Verify.Success
            finalVersion = $Verify.Version
            finalGoExe   = $Verify.GoExe
            attemptCount = if ($Verify.Report -and $Verify.Report.attempts) { $Verify.Report.attempts.Count } else { 0 }
            pathRefreshes= if ($Verify.Report -and $Verify.Report.pathRefreshes) { $Verify.Report.pathRefreshes.Count } else { 0 }
        }
        chocolatey   = if ($ChocoLib) {
            [ordered]@{
                found       = [bool]$ChocoLib.Found
                libPath     = $ChocoLib.LibPath
                toolsGoPath = $ChocoLib.ToolsGoPath
                version     = $ChocoLib.Version
                probeRoot   = $ChocoLib.ProbeRoot
                error       = $ChocoLib.Error
            }
        } else { $null }
    }

    try {
        $json = $payload | ConvertTo-Json -Depth 10
        Set-Content -LiteralPath $reportPath -Value $json -Encoding UTF8
        Write-Log "Wrote Go verification report: $reportPath" -Level "success"
        return $reportPath
    } catch {
        Write-FileError -FilePath $reportPath -Operation "write-go-verify-report" -Reason "$_" -Module "Write-GoVerifyReport"
        return $null
    }
}

function Install-Go {
    <#
    .SYNOPSIS
        Installs or upgrades Go via Chocolatey.
    #>
    param(
        [PSCustomObject]$Config,
        $LogMessages
    )

    $packageName = if ($Config.chocoPackageName) { $Config.chocoPackageName } else { "golang" }
    Write-Log ($LogMessages.messages.chocoPackageName -replace '\{name\}', $packageName) -Level "info"

    $goCmd = Get-Command go.exe -ErrorAction SilentlyContinue

    $isGoMissing = -not $goCmd
    if ($isGoMissing) {
        Write-Log $LogMessages.messages.goNotInstalled -Level "info"
        try {
            $ok = Install-ChocoPackage -PackageName $packageName
            $hasFailed = -not $ok
            if ($hasFailed) { return $false }

            # Post-install: verify `go version` works in this session.
            # Refreshes PATH from registry / refreshenv / probes well-known paths.
            $verify = Assert-GoOnPath -LogMessages $LogMessages

            # Always log where Chocolatey actually put the package on disk,
            # both on success (audit trail) and on failure (debugging aid).
            $chocoLib = Get-ChocoGoLibPath -PackageName $packageName -LogMessages $LogMessages

            # Persist a structured JSON report of every attempt + final state.
            [void](Write-GoVerifyReport -Verify $verify -ChocoLib $chocoLib -PackageName $packageName)

            if (-not $verify.Success) {
                Save-InstalledError -Name "golang" -ErrorMessage "Post-install verification failed: 'go version' did not run."
                return $false
            }

            Write-Log ($LogMessages.messages.goVersion -replace '\{version\}', $verify.Version) -Level "success"
            Save-InstalledRecord -Name "golang" -Version "$($verify.Version)".Trim()
            return $true
        } catch {
            Write-Log "Go install failed: $_" -Level "error"
            Save-InstalledError -Name "golang" -ErrorMessage "$_"
            return $false
        }
    } else {
        $version = try { & go.exe version 2>&1 } catch { $null }
        $hasVersion = -not [string]::IsNullOrWhiteSpace($version)

        # Check .installed/ tracking -- skip if version matches
        if ($hasVersion) {
            $isAlreadyTracked = Test-AlreadyInstalled -Name "golang" -CurrentVersion "$version".Trim()
            if ($isAlreadyTracked) {
                Write-Log ($LogMessages.messages.goAlreadyInstalled -replace '\{version\}', $version) -Level "info"
                return $true
            }
        }

        Write-Log $LogMessages.messages.goAlreadyInstalled -Level "success"
        if ($Config.alwaysUpgradeToLatest) {
            try {
                Upgrade-ChocoPackage -PackageName $packageName | Out-Null
                # Re-verify after upgrade in case the new install moved go.exe
                [void](Update-SessionPathFromRegistry)
            } catch {
                Write-Log "Go upgrade failed: $_" -Level "error"
                Save-InstalledError -Name "golang" -ErrorMessage "$_"
            }
        }

        # Post-install/upgrade verification (also handles the "already installed
        # but PATH was lost" edge case).
        $verify = Assert-GoOnPath -LogMessages $LogMessages

        # Same audit log on the upgrade/already-present path.
        $chocoLib = Get-ChocoGoLibPath -PackageName $packageName -LogMessages $LogMessages

        # Persist a structured JSON report of every attempt + final state.
        [void](Write-GoVerifyReport -Verify $verify -ChocoLib $chocoLib -PackageName $packageName)

        if (-not $verify.Success) {
            Save-InstalledError -Name "golang" -ErrorMessage "Post-install verification failed: 'go version' did not run."
            return $false
        }

        Write-Log ($LogMessages.messages.goVersion -replace '\{version\}', $verify.Version) -Level "success"
        Save-InstalledRecord -Name "golang" -Version "$($verify.Version)".Trim()
        return $true
    }
}

function Resolve-Gopath {
    param(
        [PSCustomObject]$GopathConfig,
        [string]$DevDirSubfolder,
        $LogMessages
    )

    $isAutoYes = $env:SCRIPTS_AUTO_YES -eq "1"

    $hasDevDir = -not [string]::IsNullOrWhiteSpace($env:DEV_DIR)
    if ($hasDevDir -and $DevDirSubfolder) {
        $derived = Join-Path $env:DEV_DIR $DevDirSubfolder
        Write-Log ($LogMessages.messages.gopathFromDevDir -replace '\{path\}', $derived) -Level "success"
        return $derived
    }

    $hasNoConfig = -not $GopathConfig
    if ($hasNoConfig) {
        $fallback = "E:\dev-tool\go"
        Write-Log ($LogMessages.messages.gopathNoConfig -replace '\{path\}', $fallback) -Level "warn"
        return $fallback
    }

    $default  = if ($GopathConfig.default)  { $GopathConfig.default }  else { "E:\dev-tool\go" }
    $override = if ($GopathConfig.override) { $GopathConfig.override } else { "" }

    $hasOverride = -not [string]::IsNullOrWhiteSpace($override)
    if ($hasOverride) {
        Write-Log ($LogMessages.messages.gopathOverride -replace '\{path\}', $override) -Level "info"
        return $override
    }

    if ($GopathConfig.mode -eq "json-only") {
        Write-Log ($LogMessages.messages.gopathJsonOnly -replace '\{path\}', $default) -Level "info"
        return $default
    }

    $hasDevDirEnv = -not [string]::IsNullOrWhiteSpace($env:DEV_DIR)
    if ($hasDevDirEnv -and $GopathConfig.mode -eq "json-or-prompt") {
        $envGopath = Join-Path $env:DEV_DIR "go"
        Write-Log ($LogMessages.messages.gopathDefault -replace '\{path\}', $envGopath) -Level "info"
        return $envGopath
    }

    if ($isAutoYes) {
        Write-Log ($LogMessages.messages.gopathDefault -replace '\{path\}', $default) -Level "info"
        return $default
    }

    $userInput = Read-Host -Prompt "Enter GOPATH (default: $default)"
    $hasUserInput = -not [string]::IsNullOrWhiteSpace($userInput)
    if ($hasUserInput) {
        Write-Log ($LogMessages.messages.gopathUserProvided -replace '\{path\}', $userInput) -Level "info"
        return $userInput
    }

    Write-Log ($LogMessages.messages.gopathDefault -replace '\{path\}', $default) -Level "info"
    return $default
}

function Initialize-Gopath {
    param(
        [Parameter(Mandatory)]
        [string]$GopathValue,
        $LogMessages
    )

    $gopathFull = [System.IO.Path]::GetFullPath($GopathValue)
    Write-Log ($LogMessages.messages.gopathResolved -replace '\{path\}', $gopathFull) -Level "info"

    $isDirMissing = -not (Test-Path $gopathFull)
    if ($isDirMissing) {
        Write-Log ($LogMessages.messages.gopathCreating -replace '\{path\}', $gopathFull) -Level "info"
        New-Item -Path $gopathFull -ItemType Directory -Force -Confirm:$false | Out-Null
        Write-Log $LogMessages.messages.gopathCreated -Level "success"
    }

    try {
        Write-Log ($LogMessages.messages.gopathSettingEnv -replace '\{path\}', $gopathFull) -Level "info"
        [Environment]::SetEnvironmentVariable("GOPATH", $gopathFull, "User")
        $env:GOPATH = $gopathFull
        Write-Log $LogMessages.messages.gopathSet -Level "success"
    } catch {
        Write-Log ($LogMessages.messages.gopathSetFailed -replace '\{error\}', $_) -Level "error"
        return $null
    }

    return $gopathFull
}

function Update-GoPath {
    param(
        [PSCustomObject]$PathConfig,
        [string]$GopathFull,
        $LogMessages
    )

    $isPathUpdateDisabled = -not $PathConfig.updateUserPath
    if ($isPathUpdateDisabled) {
        Write-Log $LogMessages.messages.pathUpdateDisabled -Level "info"
        return $true
    }

    $goBin = Join-Path $GopathFull "bin"

    $isBinMissing = -not (Test-Path $goBin)
    if ($isBinMissing) {
        Write-Log ($LogMessages.messages.goBinCreating -replace '\{path\}', $goBin) -Level "info"
        New-Item -Path $goBin -ItemType Directory -Force -Confirm:$false | Out-Null
    }

    if ($PathConfig.ensureGoBinInPath) {
        return (Add-ToUserPath -Directory $goBin)
    }

    return $true
}

function Set-GoEnvSetting {
    param(
        [Parameter(Mandatory)]
        [string]$Key,
        [Parameter(Mandatory)]
        [string]$Value,
        $LogMessages
    )

    Write-Log ($LogMessages.messages.goEnvRunning -replace '\{key\}', $Key -replace '\{value\}', $Value) -Level "info"
    try {
        & go.exe env -w "$Key=$Value" 2>&1 | ForEach-Object {
            if ($_ -and $_.ToString().Trim().Length -gt 0) { Write-Log $_ -Level "info" }
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Log ($LogMessages.messages.goEnvFailed -replace '\{key\}', $Key -replace '\{code\}', $LASTEXITCODE) -Level "warn"
            return $false
        }
        Write-Log ($LogMessages.messages.goEnvSet -replace '\{key\}', $Key) -Level "success"
        return $true
    } catch {
        Write-Log ($LogMessages.messages.goEnvSetFailed -replace '\{key\}', $Key -replace '\{error\}', $_) -Level "error"
        return $false
    }
}

function Configure-GoEnv {
    param(
        [PSCustomObject]$GoEnvConfig,
        [string]$GopathFull,
        $LogMessages
    )

    $isAutoYes = $env:SCRIPTS_AUTO_YES -eq "1"

    $hasNoConfig = -not $GoEnvConfig -or -not $GoEnvConfig.settings
    if ($hasNoConfig) {
        Write-Log $LogMessages.messages.goEnvNoConfig -Level "info"
        return $true
    }

    $settings = $GoEnvConfig.settings
    $relativeToGopath = $GoEnvConfig.relativeToGopath
    $isAllOk = $true

    foreach ($key in $settings.PSObject.Properties.Name) {
        $entry = $settings.$key

        $isEntryDisabled = -not $entry.enabled
        if ($isEntryDisabled) {
            Write-Log ($LogMessages.messages.goEnvDisabled -replace '\{key\}', $key) -Level "info"
            continue
        }

        $finalValue = $null

        $hasRelativePath = $relativeToGopath -and ($entry.PSObject.Properties.Name -contains "relativePath")
        if ($hasRelativePath) {
            $rel = $entry.relativePath
            $isRelEmpty = [string]::IsNullOrWhiteSpace($rel)
            if ($isRelEmpty) {
                Write-Log ($LogMessages.messages.goEnvEmptyRelPath -replace '\{key\}', $key) -Level "warn"
                continue
            }

            $absolutePath = Join-Path $GopathFull $rel
            $isDirMissing = -not (Test-Path $absolutePath)
            if ($isDirMissing) {
                Write-Log ($LogMessages.messages.goEnvCreatingDir -replace '\{key\}', $key -replace '\{path\}', $absolutePath) -Level "info"
                New-Item -Path $absolutePath -ItemType Directory -Force -Confirm:$false | Out-Null
            }
            $finalValue = $absolutePath
        } elseif ($entry.PSObject.Properties.Name -contains "value") {
            $finalValue = $entry.value
        }

        $hasOrchestratorEnv = -not [string]::IsNullOrWhiteSpace($env:SCRIPTS_ROOT_RUN)
        $shouldPrompt = $GoEnvConfig.applyMode -eq "json-or-prompt" -and $entry.promptOnFirstRun -and -not $hasOrchestratorEnv -and -not $isAutoYes
        if ($shouldPrompt) {
            $userInput = Read-Host -Prompt "Enter value for $key (default: $finalValue)"
            $hasUserInput = -not [string]::IsNullOrWhiteSpace($userInput)
            if ($hasUserInput) {
                $finalValue = $userInput
                Write-Log ($LogMessages.messages.goEnvUserProvided -replace '\{key\}', $key -replace '\{value\}', $finalValue) -Level "info"
            }
        }

        $hasValue = -not [string]::IsNullOrWhiteSpace($finalValue)
        if ($hasValue) {
            $ok = Set-GoEnvSetting -Key $key -Value $finalValue -LogMessages $LogMessages
            $hasFailed = -not $ok
            if ($hasFailed) { $isAllOk = $false }
        } else {
            Write-Log ($LogMessages.messages.goEnvNoValue -replace '\{key\}', $key) -Level "warn"
        }
    }

    return $isAllOk
}

function Test-GoVetAvailability {
    param(
        $LogMessages
    )

    $msgs = $LogMessages.messages
    $tempVetDir = Join-Path ([System.IO.Path]::GetTempPath()) ("scripts-fixer-go-vet-" + [guid]::NewGuid().ToString("N"))
    $mainFilePath = Join-Path $tempVetDir "main.go"
    $isLocationPushed = $false

    try {
        Write-Log ($msgs.goVetTempModule -replace '\{path\}', $tempVetDir) -Level "info"

        try {
            New-Item -Path $tempVetDir -ItemType Directory -Force -Confirm:$false | Out-Null
            Set-Content -Path $mainFilePath -Value "package main`n`nfunc main() {}`n" -Encoding UTF8
        } catch {
            $createError = $_
            Write-FileError -FilePath $mainFilePath -Operation "write" -Reason "Failed to create temporary go vet module: $createError" -Module "Test-GoVetAvailability"
            return $false
        }

        Push-Location $tempVetDir
        $isLocationPushed = $true

        $modOutput = & go.exe mod init scripts-fixer-vet-check 2>&1
        $modExitCode = $LASTEXITCODE
        foreach ($line in $modOutput) {
            if ($line -and $line.ToString().Trim().Length -gt 0) { Write-Log $line -Level "info" }
        }

        $hasModInitFailed = $modExitCode -ne 0
        if ($hasModInitFailed) {
            Write-Log ($msgs.goVetFailed -replace '\{error\}', "go mod init failed in $tempVetDir (exit code $modExitCode)") -Level "warn"
            return $false
        }

        $vetOutput = & go.exe vet ./... 2>&1
        $vetExitCode = $LASTEXITCODE
        foreach ($line in $vetOutput) {
            if ($line -and $line.ToString().Trim().Length -gt 0) { Write-Log $line -Level "info" }
        }

        $hasVetFailed = $vetExitCode -ne 0
        if ($hasVetFailed) {
            Write-Log ($msgs.goVetFailed -replace '\{error\}', "go vet ./... failed in $tempVetDir (exit code $vetExitCode)") -Level "warn"
            return $false
        }

        Write-Log $msgs.goVetAvailable -Level "success"
        return $true
    } catch {
        Write-Log ($msgs.goVetFailed -replace '\{error\}', $_) -Level "warn"
        return $false
    } finally {
        if ($isLocationPushed) { Pop-Location }

        if (Test-Path $tempVetDir) {
            try {
                Remove-Item -Path $tempVetDir -Recurse -Force -Confirm:$false
            } catch {
                $cleanupError = $_
                try {
                    Write-FileError -FilePath $tempVetDir -Operation "write" -Reason "Failed to remove temporary go vet module: $cleanupError" -Module "Test-GoVetAvailability"
                } catch {
                    Write-Log ("[CODE RED] File error during write: {0} -- Reason: Failed to remove temporary go vet module: {1} [Module: Test-GoVetAvailability]" -f $tempVetDir, $cleanupError) -Level "warn"
                }
            }
        }
    }
}

function Install-GoTools {
    <#
    .SYNOPSIS
        Installs Go linting/analysis tools: golangci-lint (via go install) and verifies go vet.
    #>
    param(
        [PSCustomObject]$ToolsConfig,
        $LogMessages
    )

    $msgs = $LogMessages.messages
    $isAllOk = $true

    # -- go vet (built-in) -- verify it works ----------------------------
    Write-Log $msgs.goVetChecking -Level "info"
    $isGoVetAvailable = Test-GoVetAvailability -LogMessages $LogMessages
    if ($isGoVetAvailable -eq $false) {
        $isAllOk = $false
    }

    # -- golangci-lint ---------------------------------------------------
    $hasLintConfig = $null -ne $ToolsConfig -and $ToolsConfig.golangciLint.enabled
    if ($hasLintConfig) {
        $lintCmd = Get-Command "golangci-lint" -ErrorAction SilentlyContinue
        $isLintInstalled = $null -ne $lintCmd

        if ($isLintInstalled) {
            $lintVersion = & golangci-lint version --format short 2>&1
            $isAlreadyTracked = Test-AlreadyInstalled -Name "golangci-lint" -CurrentVersion "$lintVersion".Trim()
            if ($isAlreadyTracked) {
                Write-Log ($msgs.golangciLintAlready -replace '\{version\}', $lintVersion) -Level "success"
                return $isAllOk
            }
        }

        $installPkg = $ToolsConfig.golangciLint.installPackage
        Write-Log ($msgs.golangciLintInstalling -replace '\{package\}', $installPkg) -Level "info"

        try {
            & go.exe install $installPkg 2>&1 | ForEach-Object {
                if ($_ -and $_.ToString().Trim().Length -gt 0) { Write-Log $_ -Level "info" }
            }

            # Refresh PATH so golangci-lint is found
            $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")

            $lintCmd = Get-Command "golangci-lint" -ErrorAction SilentlyContinue
            $isLintMissing = -not $lintCmd
            if ($isLintMissing) {
                Write-FileError -FilePath "golangci-lint" -Operation "resolve" -Reason "golangci-lint not found in PATH after go install" -Module "Install-GoTools"
                Write-Log $msgs.golangciLintNotInPath -Level "warn"
                $isAllOk = $false
            } else {
                $lintVersion = & golangci-lint version --format short 2>&1
                Write-Log ($msgs.golangciLintSuccess -replace '\{version\}', $lintVersion) -Level "success"
                Save-InstalledRecord -Name "golangci-lint" -Version "$lintVersion".Trim() -Method "go-install"
            }
        } catch {
            # Capture original error FIRST so a downstream logging failure
            # (e.g. older Write-FileError without "install" in its ValidateSet)
            # cannot mask the real reason `go install` failed.
            $originalError = $_
            try {
                # Use "resolve" instead of "install" because older shared
                # logging helpers only allow the original CODE RED operation set.
                # This keeps the exact package path + failure reason visible
                # without letting the logger become the primary crash.
                Write-FileError -FilePath $installPkg -Operation "resolve" -Reason "go install failed: $originalError" -Module "Install-GoTools"
            } catch {
                # Fallback: never let CODE RED logging hide the real go install error.
                Write-Log ("[CODE RED] go install failed for: {0} -- Reason: {1} [Module: Install-GoTools]" -f $installPkg, $originalError) -Level "error"
                Write-Log ("Write-FileError fallback used for: {0} -- Reason: {1}" -f $installPkg, $_) -Level "warn"
            }
            Write-Log ($msgs.golangciLintFailed -replace '\{error\}', $originalError) -Level "error"
            Save-InstalledError -Name "golangci-lint" -ErrorMessage "$originalError"
            $isAllOk = $false
        }
    } else {
        Write-Log $msgs.golangciLintDisabled -Level "info"
    }

    return $isAllOk
}

function Invoke-GoSetup {
    param(
        [PSCustomObject]$Config,
        [string]$ScriptDir,
        [string]$Command,
        $LogMessages
    )

    $isAllOk = $true

    $isNotConfigureOnly = $Command -ne "configure"
    if ($isNotConfigureOnly) {
        $ok = Install-Go -Config $Config -LogMessages $LogMessages
        $hasFailed = -not $ok
        if ($hasFailed) {
            Write-Log $LogMessages.messages.goInstallFailed -Level "error"
            return $false
        }
    }

    $isNotInstallOnly = $Command -ne "install"
    if ($isNotInstallOnly) {
        $gopathValue = Resolve-Gopath -GopathConfig $Config.gopath -DevDirSubfolder $Config.devDirSubfolder -LogMessages $LogMessages
        $gopathFull = Initialize-Gopath -GopathValue $gopathValue -LogMessages $LogMessages

        $isGopathFailed = -not $gopathFull
        if ($isGopathFailed) {
            Write-Log $LogMessages.messages.gopathInitFailed -Level "error"
            return $false
        }

        $ok = Update-GoPath -PathConfig $Config.path -GopathFull $gopathFull -LogMessages $LogMessages
        $hasFailed = -not $ok
        if ($hasFailed) { $isAllOk = $false }

        $ok = Configure-GoEnv -GoEnvConfig $Config.goEnv -GopathFull $gopathFull -LogMessages $LogMessages
        $hasFailed = -not $ok
        if ($hasFailed) { $isAllOk = $false }

        # -- Install Go tools (golangci-lint, go vet check) ----------------
        $ok = Install-GoTools -ToolsConfig $Config.tools -LogMessages $LogMessages
        $hasFailed = -not $ok
        if ($hasFailed) { $isAllOk = $false }

        Save-ResolvedData -ScriptFolder "06-install-golang" -Data @{
            golang = @{
                gopath     = $gopathFull
                version    = "$(& go.exe version 2>&1)".Trim()
                resolvedAt = (Get-Date -Format "o")
                resolvedBy = $env:USERNAME
            }
        }
    }

    return $isAllOk
}

function Uninstall-Go {
    <#
    .SYNOPSIS
        Full Go uninstall: choco uninstall, remove GOPATH/GOROOT env vars,
        remove from PATH, clean dev dir subfolder, purge tracking.
    #>
    param(
        $Config,
        $LogMessages,
        [string]$DevDir
    )

    $packageName = $Config.chocoPackageName

    # 1. Uninstall via Chocolatey
    Write-Log ($LogMessages.messages.uninstalling -replace '\{name\}', "Go") -Level "info"
    $isUninstalled = Uninstall-ChocoPackage -PackageName $packageName
    if ($isUninstalled) {
        Write-Log ($LogMessages.messages.uninstallSuccess -replace '\{name\}', "Go") -Level "success"
    } else {
        Write-Log ($LogMessages.messages.uninstallFailed -replace '\{name\}', "Go") -Level "error"
    }

    # 2. Remove GOPATH environment variable
    $currentGopath = [System.Environment]::GetEnvironmentVariable("GOPATH", "User")
    $hasGopath = -not [string]::IsNullOrWhiteSpace($currentGopath)
    if ($hasGopath) {
        Write-Log "Removing GOPATH env var: $currentGopath" -Level "info"
        [System.Environment]::SetEnvironmentVariable("GOPATH", $null, "User")
        $env:GOPATH = $null

        # Remove GOPATH/bin from PATH
        $goBin = Join-Path $currentGopath "bin"
        Remove-FromUserPath -Directory $goBin
    }

    # 3. Clean dev directory subfolder
    $devDirSub = if ($DevDir) { Join-Path $DevDir $Config.devDirSubfolder } else { $Config.gopath.default }
    $hasValidPath = -not [string]::IsNullOrWhiteSpace($devDirSub)
    if ($hasValidPath -and (Test-Path $devDirSub)) {
        Write-Log "Removing dev directory subfolder: $devDirSub" -Level "info"
        Remove-Item -Path $devDirSub -Recurse -Force
        Write-Log "Dev directory subfolder removed: $devDirSub" -Level "success"
    }

    # 4. Remove tracking records
    Remove-InstalledRecord -Name "golang"
    Remove-ResolvedData -ScriptFolder "06-install-golang"

    Write-Log $LogMessages.messages.uninstallComplete -Level "success"
}
