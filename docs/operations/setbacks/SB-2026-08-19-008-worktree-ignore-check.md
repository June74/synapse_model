# SB-2026-08-19-008: Pre-creation worktree ignore check rejected absent directory

- **Status:** contained
- **First observed:** 2026-08-19
- **Last observed:** 2026-08-23
- **Symptom:** `git check-ignore -q .worktrees` returned no match because the directory did not exist yet, so the guarded worktree creation was not attempted.
- **Confirmed:** The `.gitignore` rule contains `.worktrees/`; no worktree was created and no project files were changed by the failed command.
- **Correction:** Validate the intended child path with `git check-ignore --no-index`, then create the worktree.

## Recurrence: 2026-08-23

- **Phase/task:** Task 2 final verification discovery
- **Symptom:** A read-only `Select-String` discovery command included an optional root `README.md` path that did not exist and emitted a non-terminating path error after listing the pilot test files.
- **Impact:** No project file changed and no test ran from the affected command; verification continued using the confirmed test path.
- **Confirmed cause:** The command supplied a path without first checking that it existed.
- **Correction:** Run the pilot suite directly from `pilot/tests/runner.tests.ps1`.
- **Prevention:** Resolve optional discovery paths with `Test-Path` or enumerate existing files before passing them to path-strict commands.
- **Related verification:** Pilot suite completed with all runnable assertions passing; one administrator-only symbolic-link regression remained skipped by design.
