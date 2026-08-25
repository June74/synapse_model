# SB-20260825-004903-task10-haiku-omitted-effort-preflight: Task 10 Haiku preflight treated omitted effort as literal default

- **Status:** closed
- **First observed:** 2026-08-25T00:49:03.892486Z
- **Last observed:** 2026-08-25T00:49:37.557659Z
- **Phase/task:** Task 10 authorized-live offline preflight
- **Environment:** Windows PowerShell 7, deterministic-router-v1 worktree, temporary Task 10 smoke harness
- **Version/commit:** `ea3559c` plus temporary uncommitted acceptance harness

## Symptom

Claude Haiku matrix lookup found zero candidates before any launcher call

## Impact

Only the Claude offline preflight failed; zero provider calls occurred and Agy and Codex preflights remained valid

## Reproduction conditions

Run the temporary smoke harness preflight for launcher `claude`, profile effort `default`, and model `claude-haiku-4-5` while matching matrix effort literally.

## Safe evidence

The exact matrix candidate exists once and intentionally omits the `effort` property. `New-RouteId` and result normalization convert an omitted effort to `default`; the original harness filter did not.

## Attempts and outcomes

1. Agy and Codex preflights each selected exactly one candidate with zero calls.
2. Claude preflight found zero matrix candidates and stopped before execution.
3. Matrix inspection showed the Haiku row omits effort by contract, while the profile identity stores `default`.
4. The corrected preflight selected `claude|claude-haiku-4-5__default` with one candidate and zero calls.

## Cause classification

- **Confirmed cause:** The temporary harness compared a missing matrix effort directly with the profile's normalized `default` effort instead of applying the runner's omitted-effort normalization.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** The matrix and profile were not missing; both contained one exact Haiku candidate after normalization.
- **Known exclusions:** No product defect, provider call, authentication failure, profile mutation, or external-state change occurred.

## Correction and prevention

- **Correction:** Normalize omitted or blank matrix effort to `default` before exact identity comparison.
- **Prevention:** Acceptance harnesses must use the same effort normalization as `New-RouteId` and pilot result construction.
- **Owner:** Codex.
- **Next diagnostic step:** None; all three offline preflights now select exactly one intended candidate.

## Verification and related work

The corrected Claude preflight exited 0, selected the expected composite identity, evaluated one candidate, and reported zero provider calls.

## Recurrence history

- 2026-08-25T00:49:03.892486Z: First observed.
