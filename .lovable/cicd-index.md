# CI/CD Issues Index

> One row per known CI/CD issue. Detail files live in `.lovable/cicd-issues/`.
> Add new items only — do not delete history. Use status: Open / Watching / Resolved.

## Workflows in repo
| File | Purpose |
|------|---------|
| `.github/workflows/release.yml` | Tag-driven release pipeline |
| `.github/workflows/scan-legacy-fixer-refs.yml` | Scans for legacy `scripts-fixer` path refs |
| `.github/workflows/test-script-53.yml` | Smoke test for script 53 |
| `.github/workflows/test-script-54.yml` | Smoke test for script 54 (folder-bg context menu) |

## Issues
| # | Title | Status | File |
|---|-------|--------|------|
| 01 | Script 54 CI elevation gate | Watching | `cicd-issues/01-script-54-elevation-gate.md` |
| 02 | Legacy fixer-ref scan false positives | Watching | `cicd-issues/02-legacy-ref-scan-noise.md` |

## Rules
- One file per issue, kebab-case, numeric prefix.
- Never duplicate — update existing entry instead.
- When resolved, keep file and mark `Status: Resolved` with date + commit ref.
