# Chocolatey Runner Hardening

> Versions: v0.238.0 → v0.242.0. File: `scripts/shared/choco-utils.ps1`.

## Problem
Chocolatey writes carriage-return progress lines and frequently exits non-zero
even when an install/upgrade succeeded ("already installed", "is the latest
version available", npm warn on stderr). This caused false `[ FAIL ]` rows and
polluted `*-error.json` logs.

## Layered Fix
1. **Log filter** — `scripts/shared/logging.ps1` strips `Progress: ... \r`
   chunks before writing to console + JSON error log.
2. **`ConvertFrom-ChocoOutput`** — structured parser; flags
   `IsNoOpAlreadyLatest`, `IsNoOpAlreadyInstalled`, `HasRealError`.
3. **`Test-ChocoSuccessMarker`** — recognises textual success phrases
   (`"The install of X was successful"`, `"is the latest version available"`,
   `"already installed"`).
4. **`Invoke-ChocoProcess`** — treats `choco list` as read-only; for
   install/upgrade, success when ANY of: exit-code 0, no-op flag set,
   success marker found AND parser shows no real error.
5. **`Install-ChocoPackage` safety net (v0.242.0)** — even if the runner
   returns `Success=$false`, promote to success when textual marker present
   and parser reports no real error. Logs:
   `"Promoting to success: textual success marker found (exit code N ignored)."`

## Yarn / npm fix (v0.241.0)
File: `scripts/03-install-nodejs/helpers/nodejs.ps1`.
`npm install -g yarn` was being executed under `$ErrorActionPreference = Stop`,
so npm's stderr "warn" lines crashed the script with `UNKNOWN`. Now invoked via
`cmd.exe /c "`"$npmExe`" install -g yarn 2>&1"` with explicit `$LASTEXITCODE`
check and post-install `Get-Command yarn` verification.

## Why this matters (CODE RED)
Every install error row must reflect a real failure. False positives erode
trust in the [ DONE ] / [ FAIL ] summary and the `*-error.json` artifacts.

## Do NOT
- Re-introduce a "non-zero exit code = failure" shortcut for Chocolatey.
- Run npm/yarn directly under `$ErrorActionPreference = Stop` without
  `cmd.exe /c` wrapping.
- Write raw choco output to logs without passing through the CR/progress
  filter in `logging.ps1`.
