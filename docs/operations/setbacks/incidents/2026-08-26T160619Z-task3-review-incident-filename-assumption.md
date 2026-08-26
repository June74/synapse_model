# SB-20260826-160619-task3-review-incident-filename-assumption: Quality-review recurrence lookup used a shorthand incident filename

- **Status:** closed
- **First observed:** 2026-08-26T16:06:19.432654Z
- **Last observed:** 2026-08-26T16:06:19.432654Z
- **Phase/task:** Task 3 documentation quality-review follow-up
- **Environment:** Windows PowerShell, isolated option1-calibration-pilot worktree
- **Version/commit:** 8cd4178b3911185b4b370d8dd0ec40e1b87c99af

## Symptom

A read-only Get-Content command used a shortened parallel-calibration-result-lock filename that does not exist; the canonical filename includes task6-parallel-suite-result-lock.

## Impact

No repository or external state changed; the documentation edit was briefly delayed while rg located the canonical incident file.

## Reproduction conditions

The quality-review request referred to the incident by its identifier and topic. A read command reconstructed a shorter descriptive filename instead of resolving the canonical path from `INDEX.md` or `rg --files`.

## Safe evidence

`Get-Content` reported that the shorthand path did not exist. `rg --files` immediately located `2026-08-25T202324Z-task6-parallel-suite-result-lock.md`.

## Attempts and outcomes

1. Attempted the shorthand read-only path; it failed without changing state.
2. Located the canonical filename with `rg --files` and read the intended incident successfully.

## Cause classification

- **Confirmed cause:** The lookup inferred a descriptive filename instead of resolving the repository's exact filename.
- **Hypotheses:** None outstanding.
- **Rejected hypotheses:** The requested incident was not missing; only the inferred filename was wrong.
- **Known exclusions:** No provider, launcher, network request, or live calibration ran.

## Correction and prevention

- **Correction:** Resolved the exact incident path with `rg --files` before editing.
- **Prevention:** Use the incident ID to search `INDEX.md` or `rg --files`; do not reconstruct incident filenames from descriptive shorthand.
- **Owner:** Codex and project owner.
- **Next diagnostic step:** None; closed after the canonical file was resolved.

## Verification and related work

The canonical incident was read and updated with the requested recurrence metadata. The associated INDEX row was updated from the same source metadata.

## Recurrence history

- 2026-08-26T16:06:19.432654Z: First observed.
