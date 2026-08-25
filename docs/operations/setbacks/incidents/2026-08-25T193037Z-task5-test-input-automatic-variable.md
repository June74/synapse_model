# SB-20260825-193037-task5-test-input-automatic-variable: Task 5 boundary fake captured the PowerShell input variable

- **Status:** closed
- **First observed:** 2026-08-25T19:30:37.863856Z
- **Last observed:** 2026-08-25T19:30:37.863856Z
- **Phase/task:** Option 1 Task 5 quality-review test hardening
- **Environment:** Windows PowerShell 7, isolated `codex/option1-calibration-pilot` worktree
- **Version/commit:** `b162471` plus uncommitted Task 5 quality-review test changes

## Symptom

Three injected-fake tests rejected an empty ResultsRoot while the separate default-adapter shadow test passed.

## Impact

Quality-review verification paused; no native launcher, provider, network request, credential, or private output was involved.

## Reproduction conditions

Run the functional suite after adding durable-boundary reads inside fake invokers created with `GetNewClosure()`. The outer helper names its ledger object `$input`, while PowerShell reserves `$input` inside scriptblocks for pipeline enumeration.

## Safe evidence

- All three injected-fake cases failed at the same mandatory `ResultsRoot` binding before an invocation was appended.
- The separate default-adapter shadow test passed in the same suite, isolating the fault to the closure-based fake helper.

## Attempts and outcomes

1. Compared the passing default-adapter shadow with the three failing closure fakes.
2. Traced the empty argument to `$input.results_root` inside each `GetNewClosure()` scriptblock.
3. Identified `$input` as PowerShell's automatic pipeline-input variable inside scriptblocks.
4. The first combined correction patch used a guessed scaffold timestamp and was rejected atomically; the exact index row was then read before retrying.

## Cause classification

- **Confirmed cause:** The test helper reused the PowerShell automatic variable name `$input`; inside the fake scriptblocks that automatic variable shadowed the intended captured ledger object and produced an empty results-root argument.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** The production persistence order was not the cause; the default-adapter test successfully observed all durable boundaries.
- **Known exclusions:** No production code changed and no native executable, provider, network request, credential, or private output was involved.

## Correction and prevention

- **Correction:** Rename the closure-captured test ledger object from `$input` to `$ledgerInput`.
- **Prevention:** Do not use PowerShell automatic variable names for values captured by test scriptblocks; read generated scaffold timestamps before patching their index rows.
- **Owner:** Codex and project owner.
- **Next diagnostic step:** None.

## Verification and related work

The corrected functional suite completed with exit code 0 and 47 passing assertions, including all three durable-boundary fake paths and the default-adapter shadow path.

## Recurrence history

- 2026-08-25T19:30:37.863856Z: First observed.
- 2026-08-25: Closed after renaming the captured ledger object and observing the complete 47/47 functional suite.
