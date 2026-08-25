# SB-20260824-154022-router-dot-source-schema-default: Normalized request collapsed an empty capability array

- **Status:** closed
- **First observed:** 2026-08-24T15:40:22Z
- **Last observed:** 2026-08-24T15:54:49Z
- **Phase/task:** Task 8 router GREEN implementation
- **Environment:** Windows PowerShell 7, deterministic-router-v1 worktree
- **Version/commit:** `2363d19` plus uncommitted Task 8 work

## Symptom

The first Task 8 GREEN run classified valid fixture requests as `invalid_request`, so all selected-route fake executor and storage counts remained zero.

## Impact

Six Task 8 assertions failed before selection or execution. No provider, database, credential, or external service was invoked.

## Reproduction conditions

Dot-source `router/run_router.ps1` from `router/tests/router.tests.ps1`, then call `Invoke-RouterRun` with the valid minimal request and injected catalog, snapshots, token estimates, executor, and storage.

## Safe evidence

The full router suite exited 1: malformed-input and CLI assertions passed, while every valid-request Task 8 assertion stopped before fake execution. An isolated valid request also returned `invalid_request/request_validation_failed` before its fake executor.

## Attempts and outcomes

1. Ran the complete router suite after creating the response and orchestration files; six valid-request assertions failed with zero fake invocations.
2. Reproduced the pre-policy rejection with an isolated valid request and injected dependencies.
3. Captured both validation calls: the original request passed at the correct rooted schema path, while the normalized request failed at `$.additional_capabilities`.
4. Preserved the empty collection in an explicitly typed array before constructing the normalized request; the complete router suite passed.

## Cause classification

- **Confirmed cause:** PowerShell unrolled the empty array returned inside the conditional expression, so normalized `additional_capabilities` became null and failed the second schema validation.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** The dot-sourced schema path was correct and the original request passed against it. Provider execution and storage were not involved because both injected call counters remained zero.
- **Known exclusions:** No raw prompt, provider output, secret, or runtime database was emitted or persisted.

## Correction and prevention

- **Correction:** Materialize `additional_capabilities` into an explicitly typed array before assigning it to the normalized request.
- **Prevention:** Preserve empty collection types across PowerShell conditional-expression boundaries and exercise the same dot-sourced invocation path used by consumers.
- **Owner:** Codex.
- **Next diagnostic step:** None; correction verified.

## Verification and related work

The complete router suite passed with 349 assertions, including valid empty-capability requests and all Task 8 execution paths.

## Recurrence history

- 2026-08-24T15:40:22Z: First observed and contained.
- 2026-08-24T15:54:49Z: Closed after root-cause correction and full router-suite verification.
