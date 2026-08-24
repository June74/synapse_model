# SB-20260824-015530-router-pricing-fail-open: Task 6 pricing accepted missing snapshots and free routes

- **Status:** closed
- **First observed:** 2026-08-24T01:55:30Z
- **Last observed:** 2026-08-24T02:38:57Z
- **Phase/task:** Deterministic router V1 Task 6 specification-review fix
- **Environment:** Windows PowerShell 7 in the deterministic-router-v1 worktree
- **Version/commit:** 50f1813229b354c18ae5a152f99d61fccced5517

## Symptom

Specification review found that estimated pricing synthesized an untiered schedule from profile rates when no pricing snapshot was supplied and treated a calculated zero-dollar route as comparable.

## Impact

A Gemini 3.1 request above 200,000 input tokens could use the lower profile rate instead of the required upper schedule tier, mismatched provider/profile pricing could be accepted, and a free candidate could win routing. No provider or model was called and no execution or persistent routing result was produced.

## Cause classification

- **Confirmed cause:** `Get-RouterEstimatedPrice` implemented a profile-rate fallback when `PricingSnapshot` was omitted and did not reject a calculated price less than or equal to zero.
- **Recurrence cause:** Runtime pricing checked only for a schedule list and independently reimplemented partial schedule/profile matching instead of calling the catalog's complete validation rules.
- **Adversarial recurrence cause:** The shared validator incremented a maximum token bound while checking contiguity and keyed duplicate schedules only by profile-model aliases, leaving decimal overflow and disjoint-alias provider/model duplicates fail-open.
- **Contributing test gap:** Selection tests preserved the old two-argument policy call, and the zero-rate test asserted the opposite of the V1 no-free-route invariant.
- **Known exclusions:** Requirements and quality ordering, dated/tiered snapshot matching when explicitly injected, provider execution, calibration, Task 7 storage, pushes, PRs, and merges are not involved.

## Correction and prevention

- **Correction:** Added failing regressions for omitted/null snapshots, Gemini tier exposure, provider mismatch, and zero-price selection; removed the fallback and rejected non-positive calculated prices.
- **Recurrence correction:** Extracted pure object-level snapshot and profile-pricing validators from catalog import, reused them in both catalog and runtime pricing, and required global snapshot validity before any candidate can calculate price.
- **Adversarial recurrence correction:** Required decimal-representable numeric values, replaced increment-based token contiguity with an overflow-safe difference check that rejects a non-final decimal `MaxValue`, and added an ordinal provider/canonical-model schedule identity set without removing profile-alias duplicate checks.
- **Prevention:** Every policy test that expects a winner must inject an explicit valid pricing snapshot, and pricing regressions must include missing-snapshot and non-positive-price fail-closed cases.
- **Recurrence prevention:** Policy tests now cover incomplete metadata, malformed schedules, token/date gaps and overlaps, duplicate mappings/periods, and exact profile-rate mismatch using provider-distinct model mappings.
- **Adversarial recurrence prevention:** Direct-validator and policy tests now cover both a non-final decimal `MaxValue` partition and duplicate provider/canonical-model schedules with disjoint aliases.
- **Owner:** Codex.
- **Next diagnostic step:** None.

## Verification and related work

- Clean RED run: exit 1 with five expected failures covering omitted-snapshot Gemini pricing, omitted-snapshot provider mismatch, omitted-snapshot policy selection, zero-price availability, and zero-price selection.
- GREEN run: `pwsh -NoProfile -File .\router\tests\router.tests.ps1` exited 0 with 283 passes and 0 failures.
- `git diff --check` completed without whitespace errors; only expected Windows line-ending and sandbox global-ignore warnings were emitted.
- Product correction: `34efcb6cd0e31676524daf1153415745ce614046` (`fix: fail closed on unavailable router pricing`).
- Recurrence RED run: exit 1 with 283 passes and 13 expected fail-open failures.
- Recurrence GREEN run: `pwsh -NoProfile -File .\router\tests\router.tests.ps1` exited 0 with 296 passes and 0 failures.
- Standalone pricing import loaded `Get-RouterEstimatedPrice` and both shared validation helpers successfully.
- Recurrence product correction: `1b6941298cf7b2a299578244fc36968e151f755b` (`fix: validate injected router pricing snapshots`).
- Adversarial RED run: exit 1 with 296 passes and four expected failures: direct and policy overflow exceptions plus direct and policy duplicate provider/model fail-open behavior.
- Adversarial GREEN run: `pwsh -NoProfile -File .\router\tests\router.tests.ps1` exited 0 with 300 passes and 0 failures.
- Adversarial product correction: `98a3f11d70f54c41b3b90a8cb4f3ba1facec9918` (`fix: harden router pricing snapshot validation`).

## Recurrence history

- 2026-08-24T01:55:30Z: Review-discovered Task 6 implementation mistakes recorded and contained before corrective implementation.
- 2026-08-24T02:02:31Z: Closed after the fail-closed correction, full router suite, and whitespace verification passed.
- 2026-08-24T02:18:15Z: Reopened after re-review showed runtime pricing still bypassed complete snapshot/profile validation. The first GREEN attempt then exposed an invalid test fixture: two provider schedules reused one profile-model mapping, which the shared validator correctly rejected as a duplicate. The malformed-snapshot regressions passed, while 13 ordinary policy assertions had no selected candidate. No provider/model call, Task 7 work, persistent routing result, push, PR, or merge occurred. The next step is to give the two test providers distinct profile-model identities and rerun the full suite.
- During that correction, one consolidated test-helper patch was rejected before application because its context assumed a different function order. No repository file was partially changed; the retry uses smaller exact hunks.
- The second GREEN attempt reached 295 passes and one failure because the date-gap fixture used August 24 after an interval ending August 23, which is contiguous coverage. This rejected the test hypothesis rather than the validator; the corrected gap begins August 25.
- 2026-08-24T02:24:06Z: Closed after the centralized validator passed the standalone import, all 296 router assertions, and `git diff --check`.
- 2026-08-24T02:35:09Z: Reopened after final adversarial review found two fail-closed gaps in the centralized validator: a non-final token range ending at decimal `MaxValue` can overflow during contiguity checking, and schedules with the same ordinal provider/canonical-model identity can evade duplicate detection by using disjoint profile-model aliases. No provider/model call, Task 7 work, persistent routing result, push, PR, or merge occurred. The findings are contained pending direct-validator and policy-level RED regressions plus the minimum shared-validator correction.
- The first product commit attempt was blocked before staging because the sandbox could not create the shared worktree Git `index.lock`. No staging or file state changed. The legacy Git-index setback index row has no linked incident file; a guessed incident-path lookup also failed without changing repository state. The authorized commit will be retried with the required shared-Git-metadata permission.
- 2026-08-24T02:38:57Z: Closed after all 300 router assertions and whitespace verification passed, the centralized validator correction was committed, and the existing profile-model alias duplicate regression remained green.
