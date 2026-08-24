# SB-2026-08-19-003 - Skill path lookup mismatch

- ID: SB-2026-08-19-003
- Title: Skill path lookup mismatch
- Status: closed
- First observed: 2026-08-19
- Last observed: 2026-08-23
- Phase/task: Task 7 SQLite trace storage preflight
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

## Recurrences

### 2026-08-23 - catalog root and incident filename assumptions

- Symptom: a batch skill read assumed every listed skill lived under `C:\\Users\\2006i\\.codex\\skills`; three skills actually lived under `C:\\Users\\2006i\\.agents\\skills`. A later incident read assumed the index title was also the filename.
- Impact: two read-only commands reported path-not-found errors. No repository product files, private data, or runtime state changed.
- Confirmed cause: the commands constructed paths from labels instead of resolving the catalog root alias and the directory entry first.
- Correction: expanded each catalog alias to its configured root and opened the incident using the exact path returned by `Get-ChildItem`.
- Prevention: resolve catalog aliases and directory entries before issuing literal-path reads; do not derive filenames from display titles.
- Verification: all required skill files and this incident were subsequently read successfully from resolved paths.
