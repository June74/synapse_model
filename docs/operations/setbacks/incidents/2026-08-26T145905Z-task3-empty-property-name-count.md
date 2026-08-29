# SB-20260826-145905-task3-empty-property-name-count: Empty prepared environment counted as one null name

- **Status:** closed
- **First observed:** 2026-08-26T14:59:05Z
- **Last observed:** 2026-08-26T14:59:05Z
- **Phase/task:** Agy envelope repair, Task 3 launcher identity GREEN verification
- **Environment:** Windows PowerShell, isolated option1 calibration worktree
- **Version/commit:** `f9fea99` plus uncommitted Task 3 TDD changes

## Symptom

The functional suite's native-shaped Agy failure regression reached the candidate adapter but invoked its injected native seam zero times. Focused validation showed the prepared Agy identity was rejected.

## Impact

One offline functional regression failed. The candidate launch guard still claimed its fake slot, but no launcher or provider process ran.

## Reproduction conditions

Read `.PSObject.Properties.Name` from an empty `PSCustomObject` inside an array subexpression and use that count as an exact zero-property assertion.

## Safe evidence

- The prepared identity had the correct Agy ordinal, role, route, executable, and empty environment set.
- The property-name expression materialized one null element for the empty object.
- The injected native seam counter remained zero; no real launcher was executed.

## Attempts and outcomes

1. Ran the complete functional suite: one existing native Agy regression failed.
2. Reproduced prepared identity validation directly and isolated the empty-property enumeration behavior.

## Cause classification

- **Confirmed cause:** The exact environment validator counted a null property-name projection rather than enumerating actual property objects.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** Agy lock hashes, route binding, and component preparation were valid.
- **Known exclusions:** No provider, installed launcher execution, local model, network call, or live calibration ran.

## Correction and prevention

- **Correction:** Enumerate actual property objects and project their names, so an empty object yields an empty array.
- **Prevention:** Use property-object enumeration for exact empty-object checks in PowerShell.
- **Owner:** Codex.
- **Next diagnostic step:** Rerun the pilot and functional suites after correction.

## Verification and related work

The prepared-identity probe returned true after the correction. The pilot suite passed with the new exact start-info seam, and the full calibration functional suite passed including native-shaped Agy failure handling and the launcher handle-release matrix. No real process start or provider call occurred.
