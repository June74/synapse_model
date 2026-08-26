# SB-20260826-145312-task3-launcher-source-map-omission: Launcher source path map omitted two admitted inputs

- **Status:** closed
- **First observed:** 2026-08-26T14:53:12Z
- **Last observed:** 2026-08-26T14:53:12Z
- **Phase/task:** Agy envelope repair, Task 3 launcher identity implementation
- **Environment:** Windows PowerShell, isolated option1 calibration worktree
- **Version/commit:** `f9fea99` plus uncommitted Task 3 TDD changes

## Symptom

The first offline `-Pilot` dry-run after adding launcher lock parameters returned the bounded admission failure envelope. A diagnostic invocation showed that canonical-source validation attempted `GetFullPath` on an empty value.

## Impact

The offline plan did not render. No launcher, provider, network request, credential, prompt, response, or live calibration operation ran.

## Reproduction conditions

Add approved launcher lock and schema entries to the canonical-path table without adding the corresponding values to the actual-path table, then invoke offline pilot planning.

## Safe evidence

- The failure occurred in `Assert-CalibrationPilotCanonicalSourcePaths` before source import or launcher resolution.
- The approved table contained six entries while the actual table contained only the original four.
- No provider or launcher process was started.

## Attempts and outcomes

1. Ran the offline pilot plan: admission failed safely.
2. Dot-sourced the implementation and captured the bounded stack location: the empty actual-path entry was confirmed.

## Cause classification

- **Confirmed cause:** The Task 3 patch added `LauncherLockPath` and `LauncherLockSchemaPath` only to the approved-path map, not the actual-path map iterated by the same function.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** The launcher lock schema, checked-in hashes, installed launchers, and provider availability were not reached.
- **Known exclusions:** No paid API, model provider, installed launcher execution, local model, or live calibration ran.

## Correction and prevention

- **Correction:** Add both launcher inputs to the actual-path map and rerun the offline plan.
- **Prevention:** Keep approved and actual canonical-source maps symmetric and cover every new entry with an offline zero-resolver regression.
- **Owner:** Codex.
- **Next diagnostic step:** Rerun `pwsh -NoProfile -File .\calibration\run_calibration.ps1 -Pilot` and close this incident only after exit code 0.

## Verification and related work

After both actual-path entries were added, canonical validation advanced to launcher-lock schema admission. This independently verifies the source-map correction. A separate schema-vocabulary setback then blocked the overall dry-run and is tracked independently.
