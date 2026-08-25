# SB-20260825-201131-task6-review-red-empty-failure-code: Task 6 review RED fixture rejected empty failure code

- **Status:** closed
- **First observed:** 2026-08-25T20:11:31.232106Z
- **Last observed:** 2026-08-25T20:18:09.4548683Z
- **Phase/task:** Option 1 Task 6 spec-review fixes
- **Environment:** Windows PowerShell, isolated Option 1 calibration worktree
- **Version/commit:** Task 6 spec-review fix worktree before commit

## Symptom

The malformed-envelope RED test stopped in PowerShell parameter binding because the test helper did not allow an empty failure code, before reaching the intended production boundary.

## Impact

The RED evidence was initially invalid; no native process, provider, network, API, local model, live CLI, or production artifact was touched.

## Reproduction conditions

Pass an empty string through the malformed-envelope helper as the marker for a synthetic successful execution whose transport fields are then corrupted.

## Safe evidence

PowerShell rejected the mandatory typed string before the fake execution was built. No result root survived because the helper's owned-root cleanup ran.

## Attempts and outcomes

1. Read the binding error and confirmed it occurred before `Invoke-Calibration`.
2. Added explicit empty-string admission only to the test helper's failure-code parameters.
3. Reran the security suite and observed the intended RED: malformed envelopes incorrectly completed.
4. Implemented the strict production envelope validator and reran both suites successfully.

## Cause classification

- **Confirmed cause:** Mandatory PowerShell string parameters reject empty strings unless the test seam explicitly admits them.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** Production envelope admission did not cause the binding failure because it was never reached.
- **Known exclusions:** No native process, provider, network, API, local model, live CLI, credential, or production artifact was involved.

## Correction and prevention

- **Correction:** Add `AllowEmptyString` only to the synthetic helper parameters used to construct a success envelope before mutation.
- **Prevention:** Verify RED fixtures cross test-helper binding boundaries before treating their failure as production evidence.
- **Owner:** Codex.
- **Next diagnostic step:** None.

## Verification and related work

The intended malformed-envelope RED was observed, followed by 47/47 functional and 30/30 security assertions passing after implementation.

## Recurrence history

- 2026-08-25T20:11:31.232106Z: First observed.
