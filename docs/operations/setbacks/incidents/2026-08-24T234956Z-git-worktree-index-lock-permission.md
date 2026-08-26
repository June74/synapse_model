# SB-20260824-234956-git-worktree-index-lock-permission: Sandbox denied Git worktree index lock creation

- **Status:** closed
- **First observed:** 2026-08-24T23:49:56.062250Z
- **Last observed:** 2026-08-25T23:13:19.9876258Z
- **Phase/task:** Task 10 acceptance note commit
- **Environment:** Managed Codex workspace-write sandbox, Windows PowerShell 7, linked Git worktree
- **Version/commit:** `ba8c9035a0730c1e01735081e2652c744eb3846d` before correction; verification commit `ff368ec`

## Symptom

git add and git commit failed before staging because Git could not create the worktree index lock

## Impact

Only the local documentation-log commit was delayed; Task 10 files and runtime behavior were unaffected

## Reproduction conditions

Run `git add` or `git commit` in the linked deterministic-router-v1 worktree while the sandbox permits repository files but exposes the parent repository's `.git/worktrees` metadata as read-only.

## Safe evidence

Git reported that it could not create `.git/worktrees/deterministic-router-v1/index.lock`. The same bounded add-and-commit operation succeeded when rerun with scoped elevated filesystem permission. No private values appeared in either result.

## Attempts and outcomes

1. The ordinary sandboxed `git add` and `git commit` failed before staging.
2. The exact bounded operation was rerun with scoped elevated permission and created commit `ff368ec`.

## Cause classification

- **Confirmed cause:** The managed sandbox did not grant write access to the linked worktree index under the parent repository's Git metadata directory.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** A stale lock was not the cause; Git reported inability to create the lock, and the same operation succeeded immediately with the required permission.
- **Known exclusions:** Task 10 source files, tests, provider authentication, and remote Git state were unaffected.

## Correction and prevention

- **Correction:** Reran only the intended add-and-commit operation with scoped elevated filesystem permission.
- **Prevention:** In this managed linked worktree, request scoped permission for Git index mutations instead of retrying ordinary sandbox writes.
- **Owner:** Codex.
- **Next diagnostic step:** None; the bounded commit succeeded.

## Verification and related work

Commit `ff368ec` contains only the two acceptance setback records and the setbacks index update. The command exited successfully. On recurrence, the exact product/test paths were staged with scoped elevated permission and commit `f7eaab4` was created successfully before the setback documentation was staged separately.

## Recurrence history

- 2026-08-24T23:49:56.062250Z: First observed.
- 2026-08-25T23:12:31.2745448Z: Recurred while committing the swallowed-launch-guard recovery fix in the `option1-calibration-pilot` linked worktree; the ordinary sandbox again denied creation of the exact worktree `index.lock`. Product files remained unstaged and unchanged.
- 2026-08-25T23:13:19.9876258Z: Closed after the exact bounded stage and commit operations succeeded with scoped elevated filesystem permission, producing product commit `f7eaab4`.
- 2026-08-26T16:28:21.4120579Z: Recurred while staging the final Option 1 offline-repair incident closure in the linked worktree. The ordinary sandbox denied creation of the exact worktree `index.lock` before staging. The same bounded documentation-only stage and commit operation then succeeded with scoped Git-metadata permission. No source, test, provider, launcher, network, or live calibration state was affected.
