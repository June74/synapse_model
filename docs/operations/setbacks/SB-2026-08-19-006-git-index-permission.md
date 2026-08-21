# SB-2026-08-19-006: Git index unavailable to sandbox

- **Status:** contained
- **First observed:** 2026-08-19
- **Last observed:** 2026-08-20
- **Symptom:** A scoped `git add`/`git commit` for the design specification failed because Git could not create `C:\Users\2006i\projects\router_model\.git\index.lock` due to permission denial.
- **Confirmed:** The design file was written successfully; no commit was created and no existing files were overwritten.
- **Correction:** Leave the specification uncommitted in the shared workspace. If a commit is desired, run the Git command from the user's personal terminal where the repository permissions are available.
- **Impact:** Planning is paused at the design-review gate; implementation files have not been created.

## Recurrence: 2026-08-20

- **Phase/task:** Provider response-handling implementation, test commit.
- **Symptom:** A scoped `git add -- pilot/tests/runner.tests.ps1` and commit could not create the worktree index lock; the command returned permission denied.
- **Confirmed cause:** Git could not create `C:\Users\2006i\projects\router_model\.git\worktrees\subscription-runner\index.lock` from this sandbox. A read-only check confirmed that no stale lock file exists.
- **Impact:** The implementation commit is present; only the new test changes remain uncommitted.
- **Correction:** Preserve the test changes and leave the commit for the user's personal terminal or a separately approved Git operation.
- **Verification:** `git diff --check` passed; the full offline runner test suite passed with exit code 0 before the commit attempt.
