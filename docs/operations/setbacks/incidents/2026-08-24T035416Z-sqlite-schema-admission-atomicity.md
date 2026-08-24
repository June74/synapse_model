# SB-20260824-035416-sqlite-schema-admission-atomicity: SQLite schema admission was not exact or atomic

- **Status:** open
- **First observed:** 2026-08-24T03:54:16.235083Z
- **Last observed:** 2026-08-24T03:54:16.235083Z
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

- **Correction:** Pending exact schema admission, one schema-plus-write transaction, and ordered trace-state validation.
- **Prevention:** Keep temporary malformed-schema and adversarial state-machine fixtures in the Task 7 Python suite.
- **Owner:** Codex and project owner.
- **Next diagnostic step:** Implement the minimum writer changes and rerun the targeted and full acceptance suites.

## Verification and related work

Pending.

## Recurrence history

- 2026-08-24T03:54:16.235083Z: First observed.
