# SB-2026-08-19-006: Git index unavailable to sandbox

- **Status:** contained
- **First observed:** 2026-08-19
- **Last observed:** 2026-08-19
- **Symptom:** A scoped `git add`/`git commit` for the design specification failed because Git could not create `C:\Users\2006i\projects\router_model\.git\index.lock` due to permission denial.
- **Confirmed:** The design file was written successfully; no commit was created and no existing files were overwritten.
- **Correction:** Leave the specification uncommitted in the shared workspace. If a commit is desired, run the Git command from the user's personal terminal where the repository permissions are available.
- **Impact:** Planning is paused at the design-review gate; implementation files have not been created.
