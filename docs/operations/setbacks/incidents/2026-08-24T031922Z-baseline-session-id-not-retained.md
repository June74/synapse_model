# SB-20260824-031922-baseline-session-id-not-retained: Baseline test session identifier was not retained

- **Status:** closed
- **First observed:** 2026-08-24T03:19:22.527505Z
- **Last observed:** 2026-08-25
- **Phase/task:** Task 4 atomic ledger follow-up verification
- **Environment:** Windows PowerShell, Codex desktop managed workspace
- **Version/commit:** First observed at `12481f6`; Task 4 recurrence at `9d35707`

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
- 2026-08-24T05:14:03Z: Task 8 baseline wrapper again printed partial output without retaining the returned session identifier.

## Recurrence: Task 7 handoff serialization

- **Symptom:** A Task 7 quality-review handoff serialization did not preserve a usable continuation record, requiring the active repository and verification state to be reconstructed.
- **Impact:** Reporting and continuation were delayed; no product mutation, provider call, private payload, or credential exposure resulted.
- **Confirmed cause:** The handoff serialization boundary failed to retain the continuation state supplied to the next execution context.
- **Correction:** Re-established the exact worktree, branch, HEAD, clean baseline, live bridge path, and test counts from repository evidence before adding RED tests.
- **Prevention:** Keep continuation state concise, preserve command session identifiers explicitly, and verify repository state rather than relying on a serialized handoff alone.
- **Verification:** Baseline Python completed 42/42 and the full PowerShell suite completed with exit code 0 before Task 7 quality-review tests were added.

## Recurrence: Task 8 baseline wrapper

- **Symptom:** The first Task 8 router baseline exceeded the 30-second yield and the parallel wrapper printed only output, exit code, and elapsed time, losing the continuation session identifier.
- **Impact:** That partial PASS stream was discarded as evidence; no product file changed and no provider was invoked.
- **Confirmed cause:** The wrapper repeated the documented mistake of selecting fields before preserving the full execution result.
- **Correction:** Reran the suite in a dedicated call, retained session `73876`, and polled it to exit code 0.
- **Prevention:** Long-running test commands must run in dedicated calls that print or persist the full result object before any projection.
- **Verification:** The corrected full router baseline completed with exit code 0.

## Recurrence: Task 4 combined verification wrapper

- **Symptom:** A wrapper running both calibration suites produced no captured output after approximately 30 seconds, so it did not establish either suite's exit status.
- **Impact:** Final verification and commit were paused. A dedicated direct run then exposed one functional-suite failure; no provider was invoked and no private output was recorded.
- **Confirmed cause:** The wrapper projected only the nested command's output field and did not preserve the continuation identifier when execution crossed the yield boundary.
- **Hypotheses:** The first overlapping direct invocation may have observed interference from the still-running discarded session; there is not enough retained evidence to classify that transient assertion as a product defect.
- **Rejected hypotheses:** The empty wrapper result did not prove the suites were green or hung. The state-machine behavior was not a stable regression: its exact sequence passed in isolation and the full suite passed on a fresh, session-aware rerun.
- **Known exclusions:** No provider, network, credential, prompt text, or raw private payload was involved.
- **Correction:** Use dedicated direct suite calls, retain the full execution result, and poll any returned session identifier before accepting the outcome.
- **Prevention:** Do not combine long suites inside an output-only projection. Verification evidence must include each direct command's explicit exit code and assertion count.
- **Owner:** Codex.
- **Next diagnostic step:** None. If the state assertion recurs in a non-overlapping direct run, open a separate incident and capture its exact failing step.
- **Verification:** A dedicated functional run was polled through its continuation handle to exit 0 with 43 passing assertions. A dedicated security run exited 0 with 19 passing assertions. The exact state-machine sequence also passed in isolation.

## Recurrence: Task 5 TDD RED verification wrapper

- **Symptom:** The first Task 5 functional RED run yielded a partial PASS stream after 30 seconds, and the wrapper projected the output plus an undefined exit code without retaining the continuation identifier.
- **Impact:** The partial stream was discarded as completion evidence and Task 5 implementation paused. The new assertions had not yet produced their expected RED evidence. No provider, native launcher, network request, or private output was involved.
- **Confirmed cause:** The wrapper repeated the documented output projection before preserving the full long-running command result.
- **Hypotheses:** The functional suite was still running when the 30-second yield boundary was reached.
- **Rejected hypotheses:** The partial PASS stream does not prove either a green suite or a product failure.
- **Known exclusions:** Only offline test code was changed; no calibration run directory, provider call, credential, or raw provider response was created.
- **Correction:** Rerun the suite in a dedicated session-aware call, preserve the complete result object, and poll any returned session identifier until an explicit exit code is observed.
- **Prevention:** Use direct session-aware execution for this functional suite because its normal duration exceeds 30 seconds; never project fields before checking for a continuation identifier.
- **Owner:** Codex.
- **Next diagnostic step:** None for the wrapper recurrence; proceed with the observed Task 5 RED cycle.
- **Verification:** The corrected session-aware run was polled to exit code 1 and reported exactly the intended missing Task 5 orchestration seam plus the superseded bounded-live error expectation.
