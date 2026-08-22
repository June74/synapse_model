# SB-20260822-190417-main-feature-branch-divergence: Fast-forward merge unavailable after main advanced

- **Status:** contained
- **First observed:** 2026-08-22T19:04:17.449130Z
- **Last observed:** 2026-08-22T19:04:17.449130Z
- **Phase/task:** integration
- **Environment:** Windows PowerShell local Git worktree
- **Version/commit:** main f1fe526; feature 7e6a69e

## Symptom

git merge --ff-only feature/subscription-model-matrix-runner refused because main and the feature branch have diverged

## Impact

No files or refs changed; merge is delayed until a normal merge is performed and reverified.

## Reproduction conditions

To be established.

## Safe evidence

The feature worktree was clean; main and the feature branch shared base 0e90689 but had different descendants. Do not paste private or secret values.

## Attempts and outcomes

The fast-forward-only merge exited nonzero with a divergence message; no refs or files changed.

## Cause classification

- **Confirmed cause:** main advanced to f1fe526 after the feature branch split at 0e90689.
- **Hypotheses:** The fast-forward-only merge exited nonzero with a divergence message; no refs or files changed.
- **Rejected hypotheses:** The fast-forward-only merge exited nonzero with a divergence message; no refs or files changed.
- **Known exclusions:** The fast-forward-only merge exited nonzero with a divergence message; no refs or files changed.

## Correction and prevention

- **Correction:** Use a normal non-fast-forward merge, then rerun the regression suite.
- **Prevention:** Check merge-base and branch divergence before assuming fast-forward integration.
- **Owner:** Codex and project owner.
- **Next diagnostic step:** Perform the normal merge and verify the merged tree.

## Verification and related work

A normal merge and post-merge regression run.

## Recurrence history

- 2026-08-22T19:04:17.449130Z: First observed.
