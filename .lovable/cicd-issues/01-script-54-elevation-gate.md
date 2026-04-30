# Script 54 CI elevation gate

## Status
Watching

## Description
`test-script-54.yml` runs the folder-background context-menu repair, which
requires elevated `HKCR` writes. GitHub Windows runners are admin by default,
but local self-hosted runners may not be.

## Symptom
Workflow can pass on hosted runners but fail on self-hosted runners with
`Access to the registry key is denied`.

## Mitigation
Script 52/54 use `scripts/shared/admin-check.ps1` `Assert-Elevated` which
fails fast with a copy-paste retry hint. Workflow should call the script
directly so the elevation check runs.

## Open Question
See `.lovable/question-and-ambiguity/12-script54-ci-elevation-gate.md`.

## Do NOT
Add auto-UAC elevation in CI — keep the explicit fail + hint contract.
