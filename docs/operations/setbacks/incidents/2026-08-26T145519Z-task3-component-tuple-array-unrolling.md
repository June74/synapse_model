# SB-20260826-145519-task3-component-tuple-array-unrolling: Component contract tuple was flattened by PowerShell

- **Status:** closed
- **First observed:** 2026-08-26T14:55:19Z
- **Last observed:** 2026-08-26T14:55:19Z
- **Phase/task:** Agy envelope repair, Task 3 launcher identity implementation
- **Environment:** Windows PowerShell, isolated option1 calibration worktree
- **Version/commit:** `f9fea99` plus uncommitted Task 3 TDD changes

## Symptom

After schema validation advanced successfully, launcher-lock admission still returned `pilot_launcher_lock_invalid` for the checked-in lock.

## Impact

The offline plan remained fail closed. No launcher resolution, launcher process, provider, network request, or live calibration ran.

## Reproduction conditions

Represent one expected component tuple as a nested PowerShell array without a non-enumerated wrapper, then treat the flattened strings as one positional tuple.

## Safe evidence

- General schema validation accepted the lock.
- A focused PowerShell expression showed the one-component role materialized as a four-element string array rather than an array containing one tuple.
- The failure occurred during manual exact component binding.

## Attempts and outcomes

1. Removed the incompatible router-specific schema vocabulary check: admission advanced to manual binding.
2. Reproduced PowerShell's nested-array unrolling in isolation and confirmed the expected-component table shape was wrong.

## Cause classification

- **Confirmed cause:** PowerShell enumerated the nested expected component tuple, corrupting the role-level expected-component count.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** Checked-in lock ordering and JSON Schema validation are not the cause.
- **Known exclusions:** No executable launcher, provider call, local model, credential, or live calibration was involved.

## Correction and prevention

- **Correction:** Represent expected components as explicit objects rather than positional nested arrays.
- **Prevention:** Avoid nested positional tuple arrays for exact security contracts in PowerShell; use named objects and assert their counts.
- **Owner:** Codex.
- **Next diagnostic step:** Rerun offline pilot admission after conversion.

## Verification and related work

The expected-component table now uses named objects. The exact offline command `pwsh -NoProfile -File .\calibration\run_calibration.ps1 -Pilot` completed with exit code 0 and emitted both launcher source hashes without resolving or executing a launcher.
