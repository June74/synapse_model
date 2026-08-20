# SB-2026-08-19-009: Existing descendant-drain test was transiently timing-sensitive

- **Status:** closed
- **First observed:** 2026-08-19
- **Last observed:** 2026-08-19
- **Phase/task:** Task 5 review-fix verification
- **Environment:** PowerShell 7, project-local subscription-runner worktree
- **Symptom:** One existing `Invoke-NativeCandidate` descendant-drain assertion failed during a full suite run with a generic false-condition message.
- **Impact:** The review-fix suite run was inconclusive; no provider calls or persistent result writes were involved.
- **Confirmed cause:** The same full suite passed on the next fresh run, including all descendant-drain assertions. The evidence supports transient process timing rather than a deterministic regression from the Task 5 changes.
- **Hypotheses rejected:** Prompt redaction and cost extraction were not implicated; their dedicated tests passed.
- **Correction:** Re-ran the complete requested suite to a zero exit code.
- **Prevention:** Preserve the existing process-capture coverage and treat future recurrence as a separate timing investigation.
- **Owner:** Implementer
- **Related verification:** `pwsh -NoProfile -File .\pilot\tests\runner.tests.ps1` passed after the transient failure.
