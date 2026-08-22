# SB-2026-08-19-010: Parser verification command used invalid PowerShell interpolation

- **Status:** closed
- **First observed:** 2026-08-19
- **Last observed:** 2026-08-19
- **Phase/task:** Task 5 verification
- **Environment:** PowerShell 7, project-local subscription-runner worktree
- **Symptom:** The parser-check command failed before parsing files because a double-quoted diagnostic string used `$path:` without delimiting the variable.
- **Impact:** No project files were read or changed by the failed check; verification was briefly delayed.
- **Confirmed cause:** PowerShell parsed the colon as part of the variable reference. The correction is to use `${path}:`.
- **Hypotheses rejected:** No parser defect in the runner files was observed from this failure.
- **Correction:** Rerun the parser check with `${path}` interpolation.
- **Prevention:** Delimit PowerShell variables adjacent to punctuation in verification diagnostics.
- **Owner:** Implementer
- **Related verification:** Corrected parser check to be run before commit.
