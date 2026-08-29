# SB-20260825-201548-task6-review-green-stopcode-binding: Task 6 review GREEN stop-code binding regression

- **Status:** closed
- **First observed:** 2026-08-25T20:15:48.940605Z
- **Last observed:** 2026-08-25T20:53:20.7528423Z
- **Phase/task:** Option 1 Task 6 spec-review fixes
- **Environment:** Windows PowerShell, isolated Option 1 calibration worktree
- **Version/commit:** Task 6 spec-review fix worktree before commit

## Symptom

The first review-fix GREEN security run rejected every nonterminal pilot transition with pilot_stop_code_invalid.

## Impact

Verification remained red; synthetic test roots were cleaned and no native process, provider, network, API, local model, live CLI, or production result was involved.

## Reproduction conditions

Invoke any nonterminal transition without the optional typed string `StopCode` argument after the first strict terminal-code implementation.

## Safe evidence

Thirteen security assertions failed with the same safe `pilot_stop_code_invalid` code before provider or artifact seams. Test-owned roots were removed.

## Attempts and outcomes

1. Compared the shared failure point across otherwise unrelated ledger assertions.
2. Traced it to nonterminal `StopCode` validation.
3. Confirmed omitted typed strings bind as empty text rather than remaining null.
4. Changed only the nonterminal absence check to treat null and empty as omitted; terminal transitions still require an exact approved code.
5. Reran the complete functional and security suites successfully.
6. On recurrence, compared the strict grader validator with the already-approved persisted-result contract and confirmed that a blank typed string is still a string, not malformed metadata.
7. Removed only the unapproved nonblank restriction; retained exact property, type, nested-check, and extra-property rejection.
8. Reran the expanded security and functional suites successfully.

## Cause classification

- **Confirmed cause:** PowerShell normalized the omitted optional string parameter to empty text, while the nonterminal guard tested only for null.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** Ledger persistence, result contract validation, and provider seams were not the cause.
- **Known exclusions:** No native process, provider, network, API, local model, live CLI, credential, or production result was involved.

## Correction and prevention

- **Correction:** Use `IsNullOrEmpty` only for the optional nonterminal argument; retain exact allowlist membership for stopped and indeterminate transitions. On recurrence, validate grader `reason_code` against its approved null-or-string type without adding a nonblank rule.
- **Prevention:** Test omitted, empty, legacy, and approved typed-string values at PowerShell parameter boundaries.
- **Owner:** Codex.
- **Next diagnostic step:** None.

## Verification and related work

The original functional suite passed 47/47 assertions and the security suite passed 30/30 assertions after correction. After recurrence correction and review-case expansion, the functional suite passed 47/47 and the security suite passed 33/33 with explicit exit code 0.

## Recurrence history

- 2026-08-25T20:46:38.2527074Z: Reopened when the Task 6 quality-review GREEN validator treated the grader helper's typed-string null normalization as an invalid blank reason code. No live or native path ran.
- 2026-08-25T20:53:20.7528423Z: Closed after aligning the validator with the approved type contract and observing 33/33 security plus 47/47 functional assertions.
- 2026-08-25T20:15:48.940605Z: First observed.
