# SB-20260825-202324-task6-parallel-suite-result-lock: Parallel calibration suites contended on a run claim

- **Status:** closed
- **First observed:** 2026-08-25T20:23:24.5926183Z
- **Last observed:** 2026-08-26T05:48:14.2727492Z
- **Phase/task:** Option 1 Task 6 spec-review final verification
- **Environment:** Windows PowerShell, isolated Option 1 calibration worktree
- **Version/commit:** Task 6 spec-review fix worktree before commit

## Symptom

Two functional assertions failed because the concurrently running security suite held its synthetic `.run.claim` file open beneath the shared `calibration/results` tree.

## Impact

The parallel verification result cannot establish a green functional suite. The security suite completed successfully, and the affected test-owned root was cleaned afterward. No native process, provider, network, API, local model, live CLI, credential, production result, or user file was involved.

## Reproduction conditions

Start the complete functional and security calibration suites concurrently from the same worktree while the security suite owns a synthetic run root under `calibration/results`.

## Safe evidence

The functional suite passed its preceding assertions, then two CLI result-tree assertions reported that the security suite's opaque test run claim was in use by another process. The concurrent security suite completed all 30 assertions and removed its owned root.

## Attempts and outcomes

1. Stopped accepting the parallel run as completion evidence.
2. Polled the security suite to an explicit exit code; it passed all 30 assertions and cleaned the owned fixture.
3. Tried the documented setback helper through the managed-shell `python` alias; the already-known missing alias recurred.
4. Resolved the bundled Python runtime, then confirmed the repository does not contain the helper path named by the skill; created this safe incident manually.
5. Reran the functional and security suites sequentially; both completed with explicit exit code 0.
6. Confirmed the shared results boundary contains only its tracked placeholder.

## Cause classification

- **Confirmed cause:** The suites are not isolated for concurrent execution because both inspect or use the shared checked-in `calibration/results` boundary while one suite holds a synthetic claim handle.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** The failure did not originate in execution-envelope validation, terminal stop-code persistence, provider execution, or production routing traces.
- **Known exclusions:** No native process, provider, network, API, local model, live CLI, credential, production result, or private payload was involved.

## Correction and prevention

- **Correction:** Run the functional and security suites sequentially and require explicit exit codes from each.
- **Prevention:** Do not parallelize these two suites unless their result roots are made disjoint.
- **Owner:** Codex.
- **Next diagnostic step:** None.

## Verification and related work

The sequential functional suite passed 47/47 assertions and the sequential security suite passed 30/30 assertions. `calibration/results` contained only `.gitkeep` afterward.

## Recurrence history

- 2026-08-25T20:23:24.5926183Z: First observed and contained.
- 2026-08-25T20:26:10.4121215Z: Closed after both sequential suites exited 0 and owned fixture cleanup was verified.
- 2026-08-26T05:48:14.2727492Z: Task 2 code-quality review initially ran the functional and security suites concurrently and repeated the shared-result-root collision. The reviewer discarded that evidence, reran sequentially, and observed exit code 0 for both suites. No repository edit, launcher, provider, network request, or live calibration occurred.
