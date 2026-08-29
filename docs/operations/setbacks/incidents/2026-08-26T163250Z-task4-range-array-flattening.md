# SB-20260826-163250-task4-range-array-flattening: Dynamic line range flattened into the surrounding PowerShell array

- **Status:** closed
- **First observed:** 2026-08-26T16:32:50.936156Z
- **Last observed:** 2026-08-26T16:32:50.936156Z
- **Phase/task:** Task 4 final quality-review fix trace
- **Environment:** Windows PowerShell, isolated option1-calibration-pilot worktree
- **Version/commit:** 94ed7633db71c10d172ca9ca9fcdf2be83831c34

## Symptom

A read-only source inspection loop received a scalar range element and failed on subtraction because a dynamic two-item array was flattened into the outer array.

## Impact

No repository or external state changed; the call-path inspection was delayed until explicit fixed ranges were used.

## Reproduction conditions

The inspection command constructed an outer array of two-item ranges but included `$l.Count` arithmetic inline in the final nested array. PowerShell unrolled that dynamic array into the outer sequence, so the loop later received a scalar.

## Safe evidence

The failed read-only command reported that `System.Object[]` did not support the requested subtraction at the range-index expression. Separate fixed ranges read the same source successfully.

## Attempts and outcomes

1. Used one composite array containing a dynamic final range; the inspection failed before returning source text.
2. Replaced it with explicit fixed range reads; every requested source section was returned.

## Cause classification

- **Confirmed cause:** PowerShell array unrolling changed the intended two-item range into scalar outer-array elements.
- **Hypotheses:** None outstanding.
- **Rejected hypotheses:** The repository source and line contents did not cause the inspection failure.
- **Known exclusions:** No provider, launcher, network request, live calibration, or repository mutation occurred.

## Correction and prevention

- **Correction:** Used explicit fixed range reads instead of a dynamically nested range array.
- **Prevention:** Do not embed dynamically evaluated PowerShell arrays inside an outer range list without unary-comma preservation; prefer separate bounded reads.
- **Owner:** Codex and project owner.
- **Next diagnostic step:** None; closed after the requested source ranges were inspected.

## Verification and related work

The corrected reads confirmed the live ResultsRoot path from `Invoke-Calibration` into `Invoke-CalibrationPilotRun` and its current Git-before-run-creation ordering.

## Recurrence history

- 2026-08-26T16:32:50.936156Z: First observed.
