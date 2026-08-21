# SB-2026-08-19-008: Pre-creation worktree ignore check rejected absent directory

- **Status:** contained
- **First observed:** 2026-08-19
- **Last observed:** 2026-08-19
- **Symptom:** `git check-ignore -q .worktrees` returned no match because the directory did not exist yet, so the guarded worktree creation was not attempted.
- **Confirmed:** The `.gitignore` rule contains `.worktrees/`; no worktree was created and no project files were changed by the failed command.
- **Correction:** Validate the intended child path with `git check-ignore --no-index`, then create the worktree.
