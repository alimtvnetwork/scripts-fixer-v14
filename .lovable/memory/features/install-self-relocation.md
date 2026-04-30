# Install Self-Relocation Flow

> Files: `install.ps1`, `install.sh`. Confirms behaviour explained to user.

## Goal
Whether the user runs the installer from inside `scripts-fixer/`, beside it,
or from any clean directory, the bootstrapper must end up with a fresh clone
at a stable target path and execute `run.ps1 -d` from there.

## Detection cases (`[LOCATE]`)
| Case | Trigger | Action |
|------|---------|--------|
| `cwd-is-target` | CWD basename == `scripts-fixer` | `cd ..`, then wipe + clone into `<parent>/scripts-fixer` |
| `cwd-has-sibling` | `./scripts-fixer/` exists in CWD | wipe + clone into `<CWD>/scripts-fixer` |
| `cwd-safe` | Writable, non-system path | clone into `<CWD>/scripts-fixer` |
| `fallback-userprofile` | CWD is protected (System32, Program Files, /) | clone into `$HOME/scripts-fixer` |

## Fresh-clone guarantee (v0.35.0)
Always wipe and `git clone` — never `git pull`. Eliminates merge conflicts and
stale untracked files.

## Temp staging fallback
If `Remove-Item -Recurse -Force` / `rm -rf` fails (file lock, permission):
1. Clone into `%TEMP%\scripts-fixer-bootstrap-<timestamp>` (or `/tmp/...`).
2. Copy contents to target path.
3. Clean up temp.
Tagged `[TEMP]` and `[COPY]` in logs.

## Tag stream
`[LOCATE]` → `[CD]` → `[CLEAN]` → `[GIT]` (or `[TEMP]` + `[COPY]`) → `[RUN]`.

## CODE RED
Every removal/clone failure logs the exact path and the failure reason, with
recovery hint ("close terminal" / "sudo rm -rf <path>").
