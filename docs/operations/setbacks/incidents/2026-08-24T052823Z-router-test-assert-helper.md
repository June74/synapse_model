# SB-20260824-052823-router-test-assert-helper: Task 8 pricing test used an unavailable assertion helper

- **Status:** closed
- **First observed:** 2026-08-24T05:28:23Z
- **Last observed:** 2026-08-26T15:31:27.1651876Z
- **Phase/task:** Task 3 launcher-identity specification review follow-up
- **Environment:** Windows PowerShell 7, deterministic-router-v1 worktree
- **Version/commit:** `6b11d53` plus uncommitted Task 8 work

## Symptom

The complete actual-usage pricing assertion reached `Assert-True`, but the router test harness does not define that helper.

## Impact

The full router suite exited 1 before accepting the successful pricing result. No provider, database, credential, or external service was used.

## Reproduction conditions

Run the new Task 8 pricing test in `router/tests/router.tests.ps1` with the pilot-harness-style `Assert-True` helper name.

## Safe evidence

The incomplete/invalid-usage pricing test passed; the complete-usage test failed only at command resolution for `Assert-True`.

## Attempts and outcomes

1. Added RED tests using a helper name from the pilot suite.
2. The production helper was implemented and the complete case reached its first assertion, which failed before comparing values.
3. Replaced the two unavailable helper calls with the router harness's existing `Assert-Equal`.
4. Reran the full router suite successfully; both actual-price tests passed.

## Cause classification

- **Confirmed cause:** The pilot and router PowerShell test harnesses expose different assertion helper names.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** The observed failure does not show incorrect pricing output because no value comparison ran.
- **Known exclusions:** No production exception, provider invocation, or private-data exposure occurred.

## Correction and prevention

- **Correction:** Use only assertion helpers defined in the current test file.
- **Prevention:** Inspect the target harness helper definitions before borrowing assertion syntax from a sibling suite.
- **Owner:** Codex.
- **Next diagnostic step:** None; correction verified.

## Verification and related work

The complete router suite exited 0. The complete-usage case finalized the expected exact price, and absent, incomplete, and invalid usage remained non-final.

## Recurrence history

- 2026-08-24T05:28:23Z: First observed and contained.
- 2026-08-24T05:36:00Z: Closed after full router-suite verification.
- 2026-08-26T15:31:27.1651876Z: A new pilot regression borrowed `Assert-False` from the calibration harness even though the pilot harness defines only `Assert-True` for Boolean assertions.

## Recurrence: Task 3 native control-code spoof regression

- **Symptom:** The new pilot test reached its privacy assertion but failed because `Assert-False` is not defined in `pilot/tests/runner.tests.ps1`.
- **Impact:** The pilot suite exited 1 without evaluating that final Boolean assertion. The separate RED evidence showing a native `source_drift` spoof escaped remained valid.
- **Confirmed cause:** The test borrowed a helper name from the calibration suite instead of using the pilot suite's defined `Assert-True` helper.
- **Known exclusions:** No production process, launcher, provider, network request, private payload, or credential was involved.
- **Correction:** Replace the unavailable helper with `Assert-True (-not ...)`, rerun the full pilot suite, and retain its explicit exit code.
- **Prevention:** Check the helper declarations at the top of the exact target test file before adding cross-suite assertions.
- **Owner:** Codex.
- **Next diagnostic step:** Complete the corrected pilot run and close this recurrence with its result.
- **Verification:** The corrected pilot spoof regression passed, and the full pilot suite exited 0 with only the documented privilege-dependent symbolic-link skip.
