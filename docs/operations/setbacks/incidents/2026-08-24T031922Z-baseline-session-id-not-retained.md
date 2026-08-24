# SB-20260824-031922-baseline-session-id-not-retained: Baseline test session identifier was not retained

- **Status:** closed
- **First observed:** 2026-08-24T03:19:22.527505Z
- **Last observed:** 2026-08-24T03:19:22.527505Z
- **Phase/task:** Task 7 pre-implementation baseline
- **Environment:** Windows PowerShell, Codex desktop managed workspace
- **Version/commit:** `12481f6`

## Symptom

The full router suite exceeded the initial yield window and the orchestration wrapper printed output without preserving the returned continuation session identifier.

## Impact

The partial PASS stream cannot be accepted as a completed baseline; no product files changed and the suite must be rerun to an observed exit code.

## Reproduction conditions

Run the full router PowerShell suite through an execution wrapper with a 30-second yield. The process remains active and returns a continuation session identifier.

## Safe evidence

- The initial invocation returned a partial stream of PASS lines without an observed exit code.
- The corrected invocation returned continuation session `50688`; polling that session returned exit code 0.

## Attempts and outcomes

1. Ran the suite and printed only its output field: incomplete evidence because the continuation identifier was discarded.
2. Reran while persisting the returned session identifier: the initial chunk was retained safely.
3. Polled the retained session: the remaining tests completed with exit code 0.
4. The setback scaffold initially emitted an index row with shifted columns; corrected the row against the index header before committing.

## Cause classification

- **Confirmed cause:** The orchestration wrapper selected only command output and exit code, but did not persist the session identifier returned when the command exceeded the yield window.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** The suite was not hung or failing; the retained-session rerun completed successfully.
- **Known exclusions:** No product file changed, no provider was invoked, and no private test data was emitted.

## Correction and prevention

- **Correction:** Reran the baseline with the continuation session identifier stored and polled it to completion.
- **Prevention:** For any command that may exceed the yield window, persist and report the full execution result before selecting output fields; poll until an explicit exit code is observed.
- **Owner:** Codex.
- **Next diagnostic step:** None.

## Verification and related work

`pwsh -NoProfile -File .\router\tests\router.tests.ps1` completed with exit code 0 after the corrected session-aware run.

## Recurrence history

- 2026-08-24T03:19:22.527505Z: First observed.
