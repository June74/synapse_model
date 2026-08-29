# SB-20260825-184646-calibration-state-contract-intermittent: Calibration state-machine assertion intermittently fails contract validation

- **Status:** closed
- **First observed:** 2026-08-25T18:46:46.046228Z
- **Last observed:** 2026-08-25T18:52:00Z
- **Phase/task:** Task 4 quality review final verification
- **Environment:** Windows PowerShell, Codex desktop managed workspace
- **Version/commit:** `835f00f` plus uncommitted Task 4 quality-review changes

## Symptom

A direct non-overlapping functional suite run failed the state-machine assertion with the bounded result-contract code.

## Impact

Task 4 verification and commit are stopped pending focused diagnosis; no provider or private data was involved.

## Reproduction conditions

Run `pwsh -NoProfile -File calibration/tests/calibration.tests.ps1` directly with no concurrent suite. Preserve and poll the continuation handle until an explicit exit code is observed.

## Safe evidence

- The direct run emitted 42 passing assertions and one failure in the pilot run/attempt state-machine assertion.
- The failure code was the bounded `pilot_result_contract_invalid`; no raw exception or private payload was emitted.
- Security had completed separately with exit code 0 and 22 passing assertions before this run.

## Attempts and outcomes

1. An earlier occurrence followed a discarded combined-suite continuation and was not reproducible in the exact isolated state sequence.
2. A later full functional suite completed with exit code 0 and 43 passing assertions.
3. The current direct, non-overlapping full suite reproduced the state-machine failure, invalidating overlap as a sufficient explanation and triggering the explicit stop condition.
4. Safe step tracing localized the failure to validation of the copied terminal result. Ten controlled iterations reproduced the intermittent failure only after default date hydration.
5. Controlled timestamps proved that a fractional value ending in zero was shortened during `DateTime` JSON serialization and then rejected by the exact round-trip timestamp validator; a nonzero final digit retained seven places and passed.
6. An `rg` diagnostic initially used unsupported lookahead syntax; a fixed-string search immediately replaced it without changing repository state.

## Cause classification

- **Confirmed cause:** The test fixture rehydrated durable timestamp strings with default `ConvertFrom-Json`, producing `DateTime` values. A later JSON copy trimmed trailing fractional-second zeros, intermittently producing strings that do not satisfy the exact `o` timestamp contract.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** Concurrent-suite overlap is not sufficient to explain the symptom because it recurred in a direct non-overlapping run.
- **Known exclusions:** No provider, network, credential, prompt content, or live orchestration was involved.

## Correction and prevention

- **Correction:** Test JSON copies and the two state-test result reloads now use `ConvertFrom-Json -DateKind String`, matching production persistence readers.
- **Prevention:** A deterministic regression uses a timestamp ending in a fractional zero and asserts that test JSON copies preserve its string type.
- **Owner:** Codex.
- **Next diagnostic step:** None.

## Verification and related work

The deterministic regression failed before correction. Ten isolated corrected state sequences passed, followed by the functional suite at 43/43 and the security suite at 22/22, both with explicit exit code 0.

## Recurrence history

- 2026-08-25T18:46:46.046228Z: First observed.
- 2026-08-25T18:46:46.046228Z: Confirmed as a direct non-overlapping recurrence of the earlier transient state-contract symptom.
- 2026-08-25T18:52:00Z: Root cause confirmed and closed after deterministic focused and full-suite verification.
