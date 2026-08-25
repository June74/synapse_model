# SB-20260825-195710-task6-red-fixture-cleanup: Task 6 RED fixture left owned result roots

- **Status:** closed
- **First observed:** 2026-08-25T19:57:10.373023Z
- **Last observed:** 2026-08-25T19:59:31.4342992Z
- **Phase/task:** Option 1 Task 6 self-review
- **Environment:** Windows PowerShell, isolated Option 1 calibration worktree
- **Version/commit:** Task 6 worktree before product commit

## Symptom

Three test-owned pilot-ledger-security result roots from the expected RED run remained under calibration/results after the fake invocation threw before returning its cleanup handle.

## Impact

Only synthetic test artifacts remained; no live result, provider data, credential, production source, or external system was affected.

## Reproduction conditions

Let an injected fake throw before `Invoke-SecurityPilotFailureCase` can return its result-root handle to the outer assertion cleanup.

## Safe evidence

- Exactly three directories matched the test-owned `pilot-ledger-security-<32 hex>` pattern.
- Their creation times matched the first expected Task 6 RED run.
- Each contained only synthetic pilot plan/result/claim artifacts beneath `calibration/results`.

## Attempts and outcomes

1. Enumerated and verified every exact target was beneath the resolved `calibration/results` boundary and matched the owned fixture-name pattern.
2. Removed only the three verified test-owned directories with literal PowerShell paths.
3. Added cleanup inside the helper's exception path so the root is removed before rethrowing.
4. Added a terminal security assertion that no owned fixture root remains.
5. Reran the complete security suite; all 28 assertions passed and only `.gitkeep` remained.

## Cause classification

- **Confirmed cause:** The helper cleaned successful returned executions through the outer test, but had no internal cleanup when `Invoke-Calibration` threw before the helper returned its ownership handle.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** The directories were not live results and were not created by provider execution; their names and timestamps tied them to the injected-fake RED cases.
- **Known exclusions:** No provider, network, API, local model, live CLI, credential, or user-authored result was involved.

## Correction and prevention

- **Correction:** Clean the exact owned root inside `Invoke-SecurityPilotFailureCase` before rethrowing invocation failures.
- **Prevention:** Keep the terminal no-owned-roots assertion in the security suite and validate exact absolute targets before recursive cleanup.
- **Owner:** Codex.
- **Next diagnostic step:** None.

## Verification and related work

The security suite passed all 28 assertions, including the final owned-root cleanup check. `calibration/results` contained only `.gitkeep` afterward.

## Recurrence history

- 2026-08-25T19:57:10.373023Z: First observed.
