# SB-20260824-015530-router-pricing-fail-open: Task 6 pricing accepted missing snapshots and free routes

- **Status:** closed
- **First observed:** 2026-08-24T01:55:30Z
- **Last observed:** 2026-08-24T02:02:31Z
- **Phase/task:** Deterministic router V1 Task 6 specification-review fix
- **Environment:** Windows PowerShell 7 in the deterministic-router-v1 worktree
- **Version/commit:** 50f1813229b354c18ae5a152f99d61fccced5517

## Symptom

Specification review found that estimated pricing synthesized an untiered schedule from profile rates when no pricing snapshot was supplied and treated a calculated zero-dollar route as comparable.

## Impact

A Gemini 3.1 request above 200,000 input tokens could use the lower profile rate instead of the required upper schedule tier, mismatched provider/profile pricing could be accepted, and a free candidate could win routing. No provider or model was called and no execution or persistent routing result was produced.

## Cause classification

- **Confirmed cause:** `Get-RouterEstimatedPrice` implemented a profile-rate fallback when `PricingSnapshot` was omitted and did not reject a calculated price less than or equal to zero.
- **Contributing test gap:** Selection tests preserved the old two-argument policy call, and the zero-rate test asserted the opposite of the V1 no-free-route invariant.
- **Known exclusions:** Requirements and quality ordering, dated/tiered snapshot matching when explicitly injected, provider execution, calibration, Task 7 storage, pushes, PRs, and merges are not involved.

## Correction and prevention

- **Correction:** Added failing regressions for omitted/null snapshots, Gemini tier exposure, provider mismatch, and zero-price selection; removed the fallback and rejected non-positive calculated prices.
- **Prevention:** Every policy test that expects a winner must inject an explicit valid pricing snapshot, and pricing regressions must include missing-snapshot and non-positive-price fail-closed cases.
- **Owner:** Codex.
- **Next diagnostic step:** None.

## Verification and related work

- Clean RED run: exit 1 with five expected failures covering omitted-snapshot Gemini pricing, omitted-snapshot provider mismatch, omitted-snapshot policy selection, zero-price availability, and zero-price selection.
- GREEN run: `pwsh -NoProfile -File .\router\tests\router.tests.ps1` exited 0 with 283 passes and 0 failures.
- `git diff --check` completed without whitespace errors; only expected Windows line-ending and sandbox global-ignore warnings were emitted.
- Product correction: `34efcb6cd0e31676524daf1153415745ce614046` (`fix: fail closed on unavailable router pricing`).

## Recurrence history

- 2026-08-24T01:55:30Z: Review-discovered Task 6 implementation mistakes recorded and contained before corrective implementation.
- 2026-08-24T02:02:31Z: Closed after the fail-closed correction, full router suite, and whitespace verification passed.
