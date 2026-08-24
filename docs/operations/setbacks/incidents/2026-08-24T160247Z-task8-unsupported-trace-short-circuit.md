# SB-20260824-160247-task8-unsupported-trace-short-circuit: Unsupported boundary request bypassed trace persistence

- **Status:** closed
- **First observed:** 2026-08-24T16:02:47Z
- **Last observed:** 2026-08-24T16:08:25Z
- **Phase/task:** Task 8 final contract review
- **Environment:** Windows PowerShell 7, deterministic-router-v1 worktree
- **Version/commit:** `2363d19` plus uncommitted Task 8 work

## Symptom

A structurally valid request with an unsupported language returned `unsupported_request` before invoking trace storage, leaving `decision_trace_id` null.

## Impact

The public failure response was schema-conforming and no provider ran, but the confirmed Task 8 contract requires structurally valid unsupported decisions to be traced when storage succeeds.

## Reproduction conditions

Call `Invoke-RouterRun` with every required request field present, set `language` to an unsupported value, and inject fake executor and storage invokers.

## Safe evidence

`Invoke-RouterRun` returns immediately whenever request schema validation is not valid. The custom request validator reports supported-boundary failures such as `unsupported_language` through that same validation result, so the early return treats them like malformed structure.

## Attempts and outcomes

1. Final requirement review compared the confirmed trace rule with the unsupported-request test.
2. The existing test expected zero storage calls and a null trace ID, exposing the incorrect contract assumption.
3. A PowerShell regression failed with 348 passing assertions and the expected missing trace ID.
4. A Python regression failed at the exact unsupported language, privacy, and risk request-profile fields.
5. Boundary-only validation now continues to policy and storage, while the Task 7 contract permits a nonstandard boundary value only when the trace status and matching approved reason require it.
6. Full router, pilot, Python storage, CLI, and real temporary-SQLite verification passed.

## Cause classification

- **Confirmed cause:** The request-validation short circuit does not distinguish boundary-only unsupported diagnostics from structural validation errors.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** Response normalization is not the source; it already maps the approved unsupported reason correctly.
- **Known exclusions:** Malformed requests must still bypass storage, and no provider, API, credential, prompt content, or runtime database is involved.

## Correction and prevention

- **Correction:** Boundary-only validation continues through policy and trace storage; malformed structure still returns before storage. Task 7 admits unsupported boundary values only under the matching `unsupported_request` reason.
- **Prevention:** Keep an assertion that unsupported valid requests execute zero providers but persist exactly one trace and return the persisted trace ID.
- **Owner:** Codex.
- **Next diagnostic step:** None; correction verified.

## Verification and related work

The router suite passed 349 assertions, pilot passed 104 with one privilege-only symlink skip, and all 53 Python storage tests passed. A real temporary-SQLite run persisted one `unsupported_request` / `unsupported_language` decision with language `french`, zero provider executions, null normal-mode content, and a returned persisted trace ID. The temporary database was removed.

## Recurrence history

- 2026-08-24T16:02:47Z: First observed and contained during final Task 8 review.
- 2026-08-24T16:08:25Z: Closed after RED/GREEN coverage and real temporary-SQLite acceptance.
