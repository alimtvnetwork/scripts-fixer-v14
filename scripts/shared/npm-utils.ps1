# --------------------------------------------------------------------------
#  Shared npm helpers
#
#  Goal: run `npm install -g <pkg>` in a way that is tolerant of:
#    * stderr noise from npm under $ErrorActionPreference = Stop
#    * the dreaded `errno -4094 / UNKNOWN: mkdir <prefix>` error that
#      happens when the configured npm global prefix lives on a drive
#      that exists but cannot accept directory creation (typical when
#      the prefix points at a removable / network / AV-blocked path
#      such as E:\dev-tool\nodejs).
#
#  When -4094 / UNKNOWN is detected we automatically reset the prefix
#  to npm's documented Windows default (%APPDATA%\npm) and retry once.
#  Every state change is logged with the exact path + reason via
#  Write-FileError so the operator can see why the fallback fired.
# --------------------------------------------------------------------------

# -- Bootstrap shared logging --------------------------------------------------
$_npmUtilsSharedDir = $PSScriptRoot
$_loggingPath = Join-Path $_npmUtilsSharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}

function Get-NpmDefaultGlobalPrefix {
    <#
    .SYNOPSIS
        npm's documented Windows default global prefix: %APPDATA%\npm.
    #>
    $appData = $env:APPDATA
    if ([string]::IsNullOrWhiteSpace($appData)) {
        $appData = Join-Path $env:USERPROFILE "AppData\Roaming"
    }
    return (Join-Path $appData "npm")
}

function Test-NpmGlobalPrefixWritable {
    <#
    .SYNOPSIS
        Probes the supplied prefix path: drive exists, dir createable,
        write-probe succeeds. Returns @{ Ok=bool; Reason=string }.
        Logs CODE RED Write-FileError on failure.
    #>
    param(
        [Parameter(Mandatory)] [string]$PrefixPath
    )
    $result = @{ Ok = $false; Reason = $null }
    try {
        $root = [System.IO.Path]::GetPathRoot($PrefixPath)
        if (-not [string]::IsNullOrWhiteSpace($root) -and -not (Test-Path -LiteralPath $root)) {
            $result.Reason = "Drive '$root' is not mounted in this session."
            Write-FileError -FilePath $PrefixPath -Operation "probe-prefix-drive" `
                -Reason $result.Reason -Module "Test-NpmGlobalPrefixWritable"
            return $result
        }
    } catch {
        $result.Reason = "Could not parse drive root: $_"
        Write-FileError -FilePath $PrefixPath -Operation "probe-prefix-drive" `
            -Reason $result.Reason -Module "Test-NpmGlobalPrefixWritable"
        return $result
    }

    if (-not (Test-Path -LiteralPath $PrefixPath)) {
        try {
            New-Item -Path $PrefixPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
        } catch {
            $result.Reason = "Cannot create directory: $_"
            Write-FileError -FilePath $PrefixPath -Operation "create-prefix-dir" `
                -Reason $result.Reason -Module "Test-NpmGlobalPrefixWritable"
            return $result
        }
    }

    $probe = Join-Path $PrefixPath (".scripts-fixer-probe-{0}.tmp" -f ([guid]::NewGuid().ToString("N")))
    try {
        Set-Content -LiteralPath $probe -Value "probe" -Encoding ASCII -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        $result.Ok = $true
        return $result
    } catch {
        $result.Reason = "Write probe failed: $_ -- usually antivirus, file-system filter, or wrong owner."
        Write-FileError -FilePath $probe -Operation "probe-prefix-write" `
            -Reason $result.Reason -Module "Test-NpmGlobalPrefixWritable"
        return $result
    }
}

function Invoke-NpmGlobalInstall {
    <#
    .SYNOPSIS
        Run `npm install -g <PackageSpec>`, tolerating npm stderr noise
        and auto-recovering from errno -4094 (UNKNOWN mkdir) by resetting
        the prefix to npm default and retrying once.

    .OUTPUTS
        Hashtable: Success (bool), ExitCode (int), Output (string[]),
                   PrefixUsed (string), Recovered (bool), Error (string).
    #>
    param(
        [Parameter(Mandatory)] [string]$PackageSpec,
        [int]$TimeoutSec = 600
    )

    $result = @{
        Success    = $false
        ExitCode   = -1
        Output     = @()
        PrefixUsed = $null
        Recovered  = $false
        Error      = $null
    }

    $npmCmd = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if (-not $npmCmd) { $npmCmd = Get-Command npm -ErrorAction SilentlyContinue }
    if (-not $npmCmd) {
        $result.Error = "npm executable not found on PATH."
        Write-FileError -FilePath "npm" -Operation "resolve-npm" -Reason $result.Error -Module "Invoke-NpmGlobalInstall"
        return $result
    }
    $npmExe = $npmCmd.Source

    $currentPrefix = & $npmExe config get prefix 2>$null
    $result.PrefixUsed = "$currentPrefix".Trim()

    # First attempt -- via cmd.exe so 2>&1 merges streams cleanly.
    $cmdLine = "`"$npmExe`" install -g $PackageSpec 2>&1"
    Write-Log "Running: npm install -g $PackageSpec (prefix: $($result.PrefixUsed))" -Level "info"
    $output = & cmd.exe /c $cmdLine
    $exit   = $LASTEXITCODE
    $lines  = @($output | ForEach-Object { "$_" })
    $result.Output   = $lines
    $result.ExitCode = $exit

    if ($exit -eq 0) {
        $result.Success = $true
        return $result
    }

    # Detect the "errno -4094 / UNKNOWN: mkdir <prefix>" signature
    $joined  = ($lines -join "`n")
    $isPrefixError = ($joined -match 'errno\s+-?4094') -or `
                     ($joined -match 'UNKNOWN:\s+unknown error,\s*mkdir') -or `
                     ($joined -match 'EPERM.*mkdir') -or `
                     ($joined -match 'EACCES.*mkdir')

    if (-not $isPrefixError) {
        $tail = if ($lines.Count -gt 0) { ($lines | Select-Object -Last 6) -join " | " } else { "(no output)" }
        $result.Error = "npm install -g $PackageSpec failed with exit code $exit. Last output: $tail"
        return $result
    }

    # Recovery path: switch to npm default prefix and retry once.
    $fallback = Get-NpmDefaultGlobalPrefix
    Write-Log ("Detected npm prefix mkdir failure (errno -4094 / UNKNOWN) for prefix '{0}'. Falling back to npm default: {1}" -f $result.PrefixUsed, $fallback) -Level "warn"
    Write-FileError -FilePath $result.PrefixUsed -Operation "npm-mkdir-prefix" `
        -Reason "npm could not create the global prefix directory. Switching prefix to '$fallback' and retrying once." `
        -Module "Invoke-NpmGlobalInstall"

    $probe = Test-NpmGlobalPrefixWritable -PrefixPath $fallback
    if (-not $probe.Ok) {
        $result.Error = "Fallback prefix '$fallback' is also unwritable: $($probe.Reason)"
        return $result
    }

    & $npmExe config set prefix $fallback | Out-Null
    $newPrefix = & $npmExe config get prefix 2>$null
    Write-Log "npm prefix is now: $newPrefix" -Level "info"

    $output2 = & cmd.exe /c $cmdLine
    $exit2   = $LASTEXITCODE
    $lines2  = @($output2 | ForEach-Object { "$_" })
    $result.Output   = $lines + @("--- retry with prefix=$newPrefix ---") + $lines2
    $result.ExitCode = $exit2
    $result.PrefixUsed = "$newPrefix".Trim()
    $result.Recovered  = ($exit2 -eq 0)

    if ($exit2 -eq 0) {
        $result.Success = $true
        Write-Log ("Recovery succeeded: '{0}' installed under fallback prefix '{1}'." -f $PackageSpec, $newPrefix) -Level "success"
        return $result
    }

    $tail2 = if ($lines2.Count -gt 0) { ($lines2 | Select-Object -Last 6) -join " | " } else { "(no output)" }
    $result.Error = "npm install -g $PackageSpec failed (after fallback to '$newPrefix') with exit code $exit2. Last output: $tail2"
    return $result
}
