# SB-20260825-210716-task6-post-launch-ledger-recovery: Post-launch ledger failure escaped durable recovery

- **Status:** closed
- **First observed:** 2026-08-25T21:07:16.6369573Z
- **Last observed:** 2026-08-25T21:11:34.0598216Z
- **Phase/task:** Option 1 Task 6 final quality re-review
- **Environment:** Windows PowerShell, isolated Option 1 calibration worktree
- **Version/commit:** `00c0e6e`

## Symptom

A one-shot result-ledger write failure while recording a confirmed fake process start escaped the orchestrator instead of writing an indeterminate terminal result. The last durable result remained running with a reserved slot and no persisted start count.

## Impact

The same gap existed at candidate completion, deterministic-result persistence, judge completion, quality-outcome persistence, and the final completed transition. A failed ledger write could leave a claimed RunId without a durable terminal explanation. Only injected fakes and test-owned result roots were involved.

## Reproduction conditions

Replace the result-ledger writer with a test-only wrapper that throws exactly once when one selected post-launch transition is written, then delegates every later write to the original implementation.

## Safe evidence

The table-driven RED stopped at the first process-start transition with a bounded test sentinel. No raw prompt, response, credential, environment value, provider event, native output, or production artifact was recorded.

## Attempts and outcomes

1. Added six one-shot fault cases before production changes.
2. Confirmed the first case escaped before a terminal recovery write.
3. Added one persistence-recovery transition that preserves known claims, starts, completed attempts, deterministic results, and judge decisions while skipping only unstarted roles.
4. Added the exact all-attempts-succeeded indeterminate result representation required when quality or final-state persistence fails.
5. Wrapped all six post-launch ledger transitions and classified every post-prevalidation grader setter error as internal persistence uncertainty.
6. The expanded security suite passed all 34 assertions, followed sequentially by all 47 functional assertions.
7. Confirmed the results boundary contains only its tracked placeholder after cleanup.

## Cause classification

- **Confirmed cause:** The orchestrator assumed post-launch ledger setters could not fail and did not provide a second durable terminal write after a one-shot setter failure.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** Provider execution, retry behavior, routing traces, profile mutation, and raw-artifact writing were not the cause.
- **Known exclusions:** No public live CLI, native process, provider, network, API, paid call, local model, credential, or production result was involved.

## Correction and prevention

- **Correction:** Recover each listed setter failure through a dedicated `artifact_persistence_failed` / `indeterminate` transition that survives the one-shot fault.
- **Prevention:** Retain the six-stage fault matrix, all-succeeded indeterminate contract case, exact counter/state checks, privacy sentinel, and same-RunId collision checks.
- **Owner:** Codex.
- **Next diagnostic step:** None.

## Verification and related work

The expanded security suite passed 34/34 assertions, the functional suite passed 47/47 assertions, and the strengthened 34-assertion security rerun also exited 0. `calibration/results` contained only `.gitkeep` afterward.

## Recurrence history

- 2026-08-25T21:07:16.6369573Z: First observed and contained.
- 2026-08-25T21:11:34.0598216Z: Closed after the strengthened six-stage matrix and both complete suites passed with owned-root cleanup verified.
