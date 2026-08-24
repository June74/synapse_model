# SB-20260824-154446-router-estimate-expectation: Task 8 estimate assertion used historical input tokens

- **Status:** closed
- **First observed:** 2026-08-24T15:44:46Z
- **Last observed:** 2026-08-24T15:54:49Z
- **Phase/task:** Task 8 router GREEN verification
- **Environment:** Windows PowerShell 7, deterministic-router-v1 worktree
- **Version/commit:** `2363d19` plus uncommitted Task 8 work

## Symptom

After the execution and normalization fixes, one integration assertion expected an estimated price of `0.00475` but the router returned `0.003849`.

## Impact

The full router suite exited 1 with one failed assertion. No provider, runtime database, credential, or external service was used.

## Reproduction conditions

Run the Task 8 incomplete-usage case with the minimal request, $1 input rate, $5 output rate, and the checked-in token observation containing 500 visible plus 250 reasoning tokens.

## Safe evidence

Task 6 replaces the historical observation's input-token count with the current complete composed-request estimate. The current request contributes 99 input tokens, and 750 billable output tokens produce `(99 * 1 + 750 * 5) / 1,000,000 = 0.003849`.

## Attempts and outcomes

1. Expected the historical observation's 1,000 input tokens in the Task 8 integration assertion.
2. Ran the complete router suite; every other Task 8 assertion passed and this comparison exposed the mismatch.
3. Traced the value to the accepted Task 6 `estimated_input_tokens` override rule.
4. Corrected the expected estimate and reran the complete router suite successfully.

## Cause classification

- **Confirmed cause:** The test expectation used the observation's historical input-token count instead of the current request estimate required by Task 6.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** The centralized pricing arithmetic and schedule resolver returned the expected value for their actual inputs.
- **Known exclusions:** No pricing production change, provider invocation, or private-data exposure occurred.

## Correction and prevention

- **Correction:** Assert the exact estimate calculated from the current request input and the selected configuration's output-token observation.
- **Prevention:** Derive integration price expectations from the documented current-input plus observed-output rule before hardcoding totals.
- **Owner:** Codex.
- **Next diagnostic step:** None; correction verified.

## Verification and related work

The complete router suite passed with 349 assertions, including both exact actual pricing and estimated-price fallback.

## Recurrence history

- 2026-08-24T15:44:46Z: First observed and contained.
- 2026-08-24T15:54:49Z: Closed after correcting the expectation and rerunning the full suite.
