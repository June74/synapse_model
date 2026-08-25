# SB-20260825-153736-parent-worktree-ignore-dubious-ownership: Parent checkout ignore verification rejected sandbox ownership

- **Status:** closed
- **First observed:** 2026-08-25T15:37:36.292408Z
- **Last observed:** 2026-08-25T15:37:36.292408Z
- **Phase/task:** Option 1 subagent execution baseline
- **Environment:** Windows PowerShell 7 under the offline sandbox identity
- **Version/commit:** `43735915e1de54d5f728f32e356d8e5fbc06bed2`

## Symptom

The parent-checkout git check-ignore command stopped with the safe-directory ownership guard before any offline suite ran.

## Impact

No tests or provider commands ran; execution paused to use a scoped trusted-directory check without changing global Git configuration.

## Reproduction conditions

From the isolated worktree, run `git -C` against the parent checkout without a command-scoped safe-directory value.

## Safe evidence

- Git stopped at its ownership safety guard before evaluating ignore rules.
- The same read-only check with a command-scoped safe-directory value returned `.gitignore:1:.worktrees/ .worktrees`.

## Attempts and outcomes

1. Parent-checkout `git check-ignore` stopped at the ownership guard; no suite ran.
2. Repeated only that read-only check with `-c safe.directory=C:/Users/2006i/projects/router_model`; it confirmed `.worktrees/` is ignored.

## Cause classification

- **Confirmed cause:** The parent checkout is owned by the user's Windows identity while the command ran as the offline sandbox identity, so Git required a scoped trust declaration.
- **Hypotheses:** None.
- **Rejected hypotheses:** `.worktrees/` was not ignored; the scoped read-only check proved the repository's first `.gitignore` rule ignores it.
- **Known exclusions:** No global Git setting changed, no test ran, no provider command ran, and no repository source changed.

## Correction and prevention

- **Correction:** Use Git's command-scoped `-c safe.directory=...` only for read-only checks against the parent checkout.
- **Prevention:** Prefer checks from the already trusted isolated worktree; when the parent path is required, avoid changing global Git configuration and scope trust to the single command.
- **Owner:** Codex and project owner.
- **Next diagnostic step:** Run the five offline baseline suites from the isolated worktree.

## Verification and related work

The corrected ignore check exited successfully and identified `.gitignore:1:.worktrees/` as the matching rule.

## Recurrence history

- 2026-08-25T15:37:36.292408Z: First observed.
