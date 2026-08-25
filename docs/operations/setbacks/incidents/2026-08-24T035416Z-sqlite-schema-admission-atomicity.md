# SB-20260824-035416-sqlite-schema-admission-atomicity: SQLite schema admission was not exact or atomic

- **Status:** closed
- **First observed:** 2026-08-24T03:54:16.235083Z
- **Last observed:** 2026-08-24
- **Phase/task:** Task 7 post-implementation review
- **Environment:** Windows PowerShell worktree; bundled CPython standard library SQLite
- **Version/commit:** `950d7701be0825a9bbabd0967a4d7b2971c01ea2`

## Symptom

Review probes showed that a nonempty version-0 database was advanced to version 1, malformed version-1 schemas were repaired or accepted, and schema DDL committed before the first trace write.

## Impact

Unknown or malformed project-local databases could be mutated and labeled V1, while a failed first write could leave a partial accepted schema behind.

## Reproduction conditions

A temporary version-0 database containing a legacy table, version-1 databases with a missing approved index or an extra view, and a forced first-write SQL failure reproduced the unsafe admission and transaction boundaries. Adversarial trace fixtures also reached quality or price after an earlier failed or missing stage.

## Safe evidence

`python -m unittest router.storage.test_sqlite_store` ran 29 tests after the review tests were added and failed 14 targeted assertions. The failures included acceptance of partial V0, malformed/extra V1, schema persistence after a forced first-write error, later-stage bypasses, and winner metadata mismatches. No credentials, prompt content, response content, hashes, or runtime database contents were recorded here.

## Attempts and outcomes

- Added direct temporary-database probes and adversarial trace-state fixtures before implementation; the valid exact-V1 and valid ordered-stage controls continued to pass.

## Cause classification

- **Confirmed cause:** Schema setup treated user version as sufficient admission evidence, used `IF NOT EXISTS` DDL without exact catalog validation, and committed setup separately from the first trace insert. Trace validation checked rejection stages independently instead of as one ordered state machine.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** None recorded.
- **Known exclusions:** The PowerShell bridge and provider execution path were not involved.

## Correction and prevention

- **Correction:** Product commit `44d920a` added exact V1 schema fingerprint admission, rejected nonempty V0 and malformed or unsupported schemas without mutation, made schema setup and the first trace write one transaction, and enforced the ordered candidate state machine plus selected-winner metadata equality.
- **Prevention:** Keep temporary malformed-schema and adversarial state-machine fixtures in the Task 7 Python suite.
- **Owner:** Codex and project owner.
- **Next diagnostic step:** None; retain the regression fixtures.

## Verification and related work

The bundled-Python suite passed all 29 tests. The full router PowerShell suite exited 0, including the stdin bridge. A fresh acceptance database reported `user_version=1`, an exact schema fingerprint, only the two approved tables and five approved user indexes, and the approved candidate foreign key. `git diff --check` passed and no SQLite runtime file was tracked.

## Recurrence history

- 2026-08-24T03:54:16.235083Z: First observed.
- 2026-08-24: Closed after product commit `44d920a` and final acceptance verification.
- 2026-08-24: Reopened after re-review found a V0 internal-object bypass and incomplete nested-result and status-state consistency.
- 2026-08-24: Closed after product commit `16f3d51` and final acceptance verification.

## Recurrence: Task 7 consistency re-review

- **Version/commit:** `44d920a924f4b2c64acd76141f75e48ee5c7e7b1`
- **Symptom:** A dropped AUTOINCREMENT table left `sqlite_sequence` in a version-0 database that was still admitted as fresh. Candidate nested results could contradict their pass/fail flags or rejection reasons, nonselected eligible candidates bypassed winner-only checks, and the failure-state rule rejected a valid attempted winner for `execution_failed` while allowing contradictory pre-execution metadata.
- **Impact:** Malformed traces could become immutable history, and Task 8 could not correctly persist an attempted route after launcher failure.
- **Safe evidence:** The expanded bundled-Python suite ran 42 tests and produced 34 targeted RED failures. No provider calls, credentials, raw trace payloads, hashes, or runtime database contents were recorded.
- **Confirmed cause:** Fresh-V0 admission filtered out `sqlite_%` catalog rows. Nested validators checked local types and broad nullability without reconstructing the Task 4-6 producer invariants, while top-level failure validation used one rule for four semantically different statuses.
- **Known exclusions:** The PowerShell stdin bridge remains outside the failing validation boundary and no Task 8 execution code exists.
- **Correction:** Product commit `16f3d51` requires a truly empty SQLite catalog for fresh V0 admission, reconstructs canonical requirements/quality/price results for every candidate, makes the first failed stage authoritative, and enforces status-specific winner and response/latency rules.
- **Prevention:** Retain direct internal-catalog, nonselected-eligible, canonical-reason, and all-status regression fixtures.
- **Next diagnostic step:** None; retain the regression fixtures.
- **Attempt outcome:** The first GREEN attempt ran 42 tests but stopped with 12 failures and 6 errors because the newly exercised nonselected eligible fixture encoded a price one decimal quantum above the exact estimate derived from its token and rate fields. This was a fixture inconsistency, not a writer/schema regression; correct the fixture to the producer's exact `0.0096` result before evaluating the remaining implementation.
- **Verification:** Bundled Python passed 42/42 tests. The full router PowerShell suite passed 328 assertions with zero failures. A first-write acceptance database reported `user_version=1`, the exact V1 schema fingerprint, one decision and four candidate rows, the approved foreign key, and only approved tables/indexes (plus SQLite-required autoindexes). `git diff --check` passed; zero SQLite runtime files were present, staged, or tracked.
