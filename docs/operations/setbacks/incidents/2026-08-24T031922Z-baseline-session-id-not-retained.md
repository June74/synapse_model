# SB-20260824-031922-baseline-session-id-not-retained: Baseline test session identifier was not retained

- **Status:** closed
- **First observed:** 2026-08-24T03:19:22.527505Z
- **Last observed:** 2026-08-24T04:42:50Z
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
- 2026-08-24T04:42:50Z: Project-owner-reported Task 7 handoff serialization recurrence; repository status and test state were re-established before work resumed.

## Recurrence: Task 7 handoff serialization

- **Symptom:** A Task 7 quality-review handoff serialization did not preserve a usable continuation record, requiring the active repository and verification state to be reconstructed.
- **Impact:** Reporting and continuation were delayed; no product mutation, provider call, private payload, or credential exposure resulted.
- **Confirmed cause:** The handoff serialization boundary failed to retain the continuation state supplied to the next execution context.
- **Correction:** Re-established the exact worktree, branch, HEAD, clean baseline, live bridge path, and test counts from repository evidence before adding RED tests.
- **Prevention:** Keep continuation state concise, preserve command session identifiers explicitly, and verify repository state rather than relying on a serialized handoff alone.
- **Verification:** Baseline Python completed 42/42 and the full PowerShell suite completed with exit code 0 before Task 7 quality-review tests were added.
