# SB-2026-08-19-003 - Skill path lookup mismatch

- ID: SB-2026-08-19-003
- Title: Skill path lookup mismatch
- Status: closed
- First observed: 2026-08-19
- Last observed: 2026-08-19
- Phase/task: Current-turn research response
- Environment: Windows PowerShell, Codex desktop
- Version/commit: Not applicable

## Symptom and impact

The first attempt to read the `scope-gate` skill used the catalog root `C:\\Users\\2006i\\.codex\\skills`, but the installed skill was under `C:\\Users\\2006i\\.agents\\skills`. The command failed before the research work began. No project data, secrets, or user artifacts were exposed or modified.

## Evidence

- `Get-ChildItem` located the skill at `C:\\Users\\2006i\\.agents\\skills\\scope-gate`.
- The corrected read completed successfully.

## Attempts and outcomes

1. Read from the catalog root path: failed with a path-not-found error.
2. Searched both local skill roots and read the located file: succeeded.

## Cause and hypotheses

- Confirmed cause: the displayed skill root alias did not match the filesystem location for this installed skill.
- Rejected hypothesis: repository permissions were not the cause; the corrected path was readable.

## Correction and prevention

- Correction: search both configured local skill roots when a listed skill path is absent.
- Prevention: verify the resolved filesystem path before retrying a skill read.
- Owner: Codex
- Next diagnostic step: none.

## Verification

The `scope-gate` and `setback-logger` instructions were read successfully from their resolved paths.
