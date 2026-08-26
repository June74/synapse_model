# SB-20260826-153352-task3-multifile-patch-context: Multi-file setback patch used a stale index context

- **Status:** closed
- **First observed:** 2026-08-26T15:33:52.882389Z
- **Last observed:** 2026-08-26T15:33:52.882389Z
- **Phase/task:** Task 3 launcher-identity specification review follow-up
- **Environment:** Windows PowerShell 7, isolated Option 1 worktree
- **Version/commit:** `0401d50` plus uncommitted Task 3 review fixes

## Symptom

A multi-file apply_patch request was rejected atomically because one INDEX.md context did not match.

## Impact

Setback documentation was delayed; the rejected patch changed no file and no product process or provider ran.

## Reproduction conditions

Submit one patch spanning multiple setback files and an index hunk whose expected row does not match the current file exactly.

## Safe evidence

The patch tool reported an index-context verification failure and applied none of the requested file changes.

## Attempts and outcomes

1. Submitted one large multi-file setback update; it was rejected atomically.
2. Re-read the exact current index rows.
3. Applied one target file per patch and then updated the consolidated index separately.

## Cause classification

- **Confirmed cause:** The large patch depended on a stale exact index context, making the entire multi-file update fragile.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** No partial write occurred; all target files retained their pre-patch contents.
- **Known exclusions:** No production code, provider, launcher, network request, credential, prompt, or response was affected.

## Correction and prevention

- **Correction:** Re-read the index and split the retry into one-file patches before one exact index patch.
- **Prevention:** Keep setback content updates per-file and update index rows only after all incident files have their final metadata.
- **Owner:** Codex and project owner.
- **Next diagnostic step:** None.

## Verification and related work

The split incident-file patches applied successfully; the exact index rows were re-read before the final index update.

## Recurrence history

- 2026-08-26T15:33:52.882389Z: First observed.
