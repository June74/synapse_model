# SB-20260822-190757-merged-main-legacy-result-deletion: Merged main lost required legacy pilot result fixture

- **Status:** closed
- **First observed:** 2026-08-22T19:07:57.829750Z
- **Last observed:** 2026-08-22T19:07:57.829750Z
- **Phase/task:** post-merge-verification
- **Environment:** Windows PowerShell local Git worktree after merge commit 690faeb
- **Version/commit:** merge 690faeb; restoration from main parent f1fe526

## Symptom

The merged main regression suite could not find pilot/results/test-run.jsonl during the public dry-run test

## Impact

The merge commit is present locally but main must not be pushed until the legacy file is restored and the full suite passes.

## Reproduction conditions

To be established.

## Safe evidence

The merged tree lacked the legacy file; the pre-merge main commit contained it. No secrets or provider output were involved.

## Attempts and outcomes

Restored pilot/results/test-run.jsonl from f1fe526; the full merged-main regression suite then exited 0.

## Cause classification

- **Confirmed cause:** The feature branch had the legacy result file only as a local ignored artifact, while the merge applied its tracked deletion to main.
- **Hypotheses:** Restored pilot/results/test-run.jsonl from f1fe526; the full merged-main regression suite then exited 0.
- **Rejected hypotheses:** Restored pilot/results/test-run.jsonl from f1fe526; the full merged-main regression suite then exited 0.
- **Known exclusions:** Restored pilot/results/test-run.jsonl from f1fe526; the full merged-main regression suite then exited 0.

## Correction and prevention

- **Correction:** Restored the legacy result file from the pre-merge main commit.
- **Prevention:** Keep the legacy result fixture tracked until the public dry-run test no longer requires it.
- **Owner:** Codex and project owner.
- **Next diagnostic step:** None; the regression boundary is covered by the public dry-run test.

## Verification and related work

Merged-main regression suite exited 0.

## Recurrence history

- 2026-08-22T19:07:57.829750Z: First observed.
