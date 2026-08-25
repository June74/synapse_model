# SB-20260825-194559-task6-first-green-failure-boundaries: Task 6 first GREEN failure boundaries

- **Status:** closed
- **First observed:** 2026-08-25T19:45:59.724892Z
- **Last observed:** 2026-08-25T19:55:35.3677309Z
- **Phase/task:** Option 1 Task 6 failure/privacy hardening
- **Environment:** Windows PowerShell, isolated Option 1 calibration worktree
- **Version/commit:** Task 6 worktree before product commit

## Symptom

The first Task 6 GREEN security run reported three bounded expectation mismatches in role counters, artifact-writer invocation, and normalized stop code.

## Impact

Task 6 remained unaccepted; no native process, provider, network, API, live CLI, or production source mutation occurred.

## Reproduction conditions

Run the new injected-fake failure table with a successful candidate represented by a nullable typed string failure code, then recursively scan parsed JSON artifacts containing numeric values.

## Safe evidence

- The candidate, Judge 1, and Judge 2 confirmed-start failure cases initially stopped one role too early.
- The artifact-writer seam had zero calls because the synthetic candidate was misclassified before artifact persistence.
- The recursive artifact scan later reported call-depth overflow on JSON numeric scalar adapter properties.
- The same-run retry was correctly rejected with the existing stable `pilot_run_collision` code.

## Attempts and outcomes

1. Compared the three mismatches and found that each premature stop originated before candidate artifact persistence.
2. Inspected the fake execution factory and reproduced PowerShell converting a nullable typed string `$null` to an empty string.
3. Corrected the fake success predicate and reran; all role counters and stop codes matched.
4. Compared the recursive scanner with the parsed artifact shapes and found it descended into adapted properties on value types.
5. Made value types terminal in the test scanner and aligned the resume assertion with the existing collision code.
6. Reran both complete calibration suites after a compatibility refactor; both exited 0.

## Cause classification

- **Confirmed cause:** The test fixture used `$null -eq $FailureCode` after `[string]` parameter binding had normalized null to empty text, so synthetic successes were built as failures. The recursive scanner also treated numeric JSON value types as traversable objects, causing self-referential adapter-property descent.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** The ledger counters, artifact writer injection, safe stop-code normalization, and same-run collision guard were not the cause.
- **Known exclusions:** No native process, provider, network, API, local model, live CLI, credential, or production routing trace was involved.

## Correction and prevention

- **Correction:** Treat null and empty failure codes identically in the fake factory; stop recursive scanning at value types; assert the existing collision code.
- **Prevention:** Build fake success/failure state from an explicit Boolean predicate and make recursive test walkers define scalar terminal types before traversing properties.
- **Owner:** Codex.
- **Next diagnostic step:** None.

## Verification and related work

The functional calibration suite passed all 47 assertions and the security suite passed all 28 assertions after the corrections. The security suite proves exact failure-role counters, bounded stop codes, artifact indeterminacy, privacy sentinels, source immutability, zero routing-trace sentinel calls, and owned-fixture cleanup.

## Recurrence history

- 2026-08-25T19:45:59.724892Z: First observed.
