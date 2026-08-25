# SB-20260824-155022-task8-trace-token-type: Finalized Task 8 trace used an incompatible token JSON type

- **Status:** closed
- **First observed:** 2026-08-24T15:50:22Z
- **Last observed:** 2026-08-24T15:54:49Z
- **Phase/task:** Task 8 trace-contract acceptance review
- **Environment:** Windows PowerShell 7 and bundled Python, deterministic-router-v1 worktree
- **Version/commit:** `2363d19` plus uncommitted Task 8 work

## Symptom

A completed Task 8 trace captured through fake storage was rejected by the Task 7 Python contract with `Expected a nonnegative integer` in the selected candidate price metadata.

## Impact

The router and storage unit suites passed independently, but the newly composed finalized trace was not yet compatible with the storage admission contract. No provider or database was invoked.

## Reproduction conditions

Run `Invoke-RouterRun` with the minimal selected candidate, fake executor, complete actual usage, and fake storage; serialize the returned trace and pass it to `router.storage.trace_contract.validate_trace` through standard input.

## Safe evidence

The Python traceback reaches `candidate_contract.validate_price` and rejects one of the selected price token fields in `nonnegative_integer`. The trace contains hashes and metadata only; normal-mode prompt and response contents are null.

## Attempts and outcomes

1. Ran pilot, router, and Python storage suites successfully.
2. Added an independent composition check by passing the generated Task 8 trace directly to the Task 7 validator.
3. Identified the exact rejection at `$.candidate_evaluations[0].price.estimated_input_tokens`; all four usage counts were PowerShell decimals serialized with a fractional JSON form.
4. Added a failing regression for integer trace token types, normalized the four counts only at the PowerShell-to-trace boundary, and reran the router suite.
5. Persisted the generated completed trace through the unchanged Task 7 bridge into a temporary SQLite database and inspected the stored decision and candidate rows.

## Cause classification

- **Confirmed cause:** `Get-RouterActualPrice` intentionally retained decimal precision, and the trace translation passed those integral decimal counts through as JSON values such as `100.0`; Task 7 correctly requires integer JSON token counts.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** Task 7 admission did not need weakening, and the pricing calculation did not need changing; only the PowerShell-to-trace representation was incompatible.
- **Known exclusions:** No provider, paid API, runtime database, credential, raw prompt, or raw provider output was used or persisted.

## Correction and prevention

- **Correction:** Preserve exact nonnegative integer token types when translating complete usage into Task 7 candidate price metadata.
- **Prevention:** Validate every Task 8 generated success and failure trace directly against the Task 7 admission contract in addition to testing storage and orchestration separately.
- **Owner:** Codex.
- **Next diagnostic step:** None; correction verified.

## Verification and related work

The router suite passed 349 assertions. A completed fake-executor run then wrote one real temporary SQLite decision with two candidate rows, one selected candidate, exact final price `0.000225`, and null normal-mode content fields. The temporary database was removed.

## Recurrence history

- 2026-08-24T15:50:22Z: First observed and contained.
- 2026-08-24T15:54:49Z: Closed after integer-boundary normalization and real temporary-SQLite acceptance.
