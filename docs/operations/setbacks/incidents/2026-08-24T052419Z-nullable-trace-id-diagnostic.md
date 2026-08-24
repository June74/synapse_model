# SB-20260824-052419-nullable-trace-id-diagnostic: Nullable trace ID test expected a leaf diagnostic

- **Status:** closed
- **First observed:** 2026-08-24T05:24:19Z
- **Last observed:** 2026-08-24T05:24:19Z
- **Phase/task:** Task 8 router response schema GREEN verification
- **Environment:** Windows PowerShell 7, deterministic-router-v1 worktree
- **Version/commit:** `f69db27` plus uncommitted Task 8 work

## Symptom

The nullable decision-trace-ID test expected `string_too_short` at `$.decision_trace_id`, but the audited schema validator returned zero matching leaf diagnostics.

## Impact

The full router suite exited 1 after all earlier assertions passed. No provider, database, credential, or external service was used.

## Reproduction conditions

Validate a failure response whose `decision_trace_id` is an empty string against the new `oneOf` string-or-null response property.

## Safe evidence

A bounded direct validation returned `valid: false` with `schema_validation_failed` at `$`.

## Attempts and outcomes

1. Added the approved nullable `oneOf` schema and expected the string branch's minimum-length diagnostic to surface directly.
2. Reproduced the response validation in isolation and observed the validator's composite diagnostic contract.
3. Updated the test to assert rejection plus the actual composite diagnostic; the full router suite then exited 0.

## Cause classification

- **Confirmed cause:** The audited validator intentionally collapses a failed `oneOf` into a root `schema_validation_failed` diagnostic instead of exposing branch-local minimum-length diagnostics.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** The empty string is not accepted; isolated validation is correctly invalid.
- **Known exclusions:** Production schema admission remains fail-closed, and no private content was emitted.

## Correction and prevention

- **Correction:** Assert the validator's audited composite diagnostic while retaining explicit invalidity and required-property checks.
- **Prevention:** Inspect composite-schema diagnostics directly before asserting branch-local error paths.
- **Owner:** Codex.
- **Next diagnostic step:** None.

## Verification and related work

The complete router suite exited 0 after the assertion was aligned with the audited composite diagnostic contract.

## Recurrence history

- 2026-08-24T05:24:19Z: First observed and contained.
