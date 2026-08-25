# SB-20260824-160012-task8-sqlite-inspection-column: Acceptance query assumed token columns instead of price JSON

- **Status:** closed
- **First observed:** 2026-08-24T16:00:12Z
- **Last observed:** 2026-08-24T23:39:37Z
- **Phase/task:** Task 8 completed-path SQLite acceptance
- **Environment:** Windows PowerShell 7 and bundled Python, deterministic-router-v1 worktree
- **Version/commit:** `2363d19` plus uncommitted Task 8 work

## Symptom

The completed router run persisted successfully, but the follow-up inspection query failed with `no such column: estimated_input_tokens`.

## Impact

Only the disposable verification query failed. The router returned a persisted trace ID and the temporary database was removed. No provider, paid API, runtime database, prompt content, or provider output was exposed.

## Reproduction conditions

Persist a completed fake-executor Task 8 trace to a temporary SQLite database, then query token fields as direct columns of `candidate_evaluations`.

## Safe evidence

The Task 7 storage schema keeps candidate pricing metadata in `price_json`; it does not define direct token-count columns. The failed query contained no private data.

## Attempts and outcomes

1. The direct completed-path write returned `completed`, trace ID `task8-completed-trace`, exact price `0.000225`, and `price_final=true`.
2. The first inspection query assumed direct token columns and failed.
3. Schema inspection confirmed that token metadata belongs in `price_json`.
4. The corrected query decoded `price_json` and observed integral counts `[100, 20, 5, 25]` for input, visible output, reasoning, and billable output tokens.
5. During Task 10 offline acceptance, a follow-up inspection query assumed `selected_candidate`, `candidate_evaluation_count`, and derived eligibility column names. `PRAGMA table_info` confirmed the contracted names are `selected_candidate_identity`, `candidate_count`, `eligible`, `requirements_passed`, `quality_passed`, and `rejection_reason_codes_json`.

## Cause classification

- **Confirmed cause:** The acceptance query assumed a denormalized token-column layout that is not part of the Task 7 storage contract.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** The write itself did not fail, and no Task 7 schema change was required.
- **Known exclusions:** No product defect, provider call, credential, prompt content, provider output, or persistent runtime artifact was involved.

## Correction and prevention

- **Correction:** Inspect finalized token metadata by decoding the selected candidate's `price_json` field.
- **Prevention:** Read `DECISION_COLUMNS` and `CANDIDATE_COLUMNS` before writing ad hoc storage inspection queries.
- **Owner:** Codex.
- **Next diagnostic step:** None; the corrected acceptance passed.

## Verification and related work

The corrected direct acceptance stored one completed decision and one selected candidate, preserved exact final price `0.000225`, stored integral usage `[100, 20, 5, 25]`, kept normal-mode content null, removed the temporary database, and created no runtime database.

## Recurrence history

- 2026-08-24T16:00:12Z: First observed, corrected, and closed.
- 2026-08-24T23:39:37Z: Recurred in the Task 10 disposable acceptance query after the trace write succeeded. Contained to the temporary database; schema inspection identified the exact contracted columns before the query was retried.
