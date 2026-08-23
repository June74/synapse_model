# SB-2026-08-19-010: Parser verification command used invalid PowerShell interpolation

- **Status:** closed
- **First observed:** 2026-08-19
- **Last observed:** 2026-08-23
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

## Recurrence: 2026-08-23

- **Phase/task:** Task 2 final strict-mode verification
- **Symptom:** A nested `pwsh -Command` invocation failed before tests started because backslashes were used as if they escaped PowerShell variables inside a double-quoted argument.
- **Impact:** No tests ran and no project file was changed by the failed command; final verification was briefly delayed.
- **Confirmed cause:** The outer PowerShell expanded the inner variables because backslash is not PowerShell's escape character.
- **Correction:** Pass the inner command as a single-quoted literal script block.
- **Prevention:** Use a literal script block for nested PowerShell verification commands that contain variables.
- **Related verification:** Corrected strict-mode router command completed with all assertions passing in 22.997 seconds.

## Recurrence: 2026-08-23, Task 2 minimum verification

- **Phase/task:** Task 2 audited minimum-guard verification
- **Symptom:** The first direct `Test-Json` probe failed at parse time because an ungrouped `foreach` statement was piped to `Format-Table`.
- **Impact:** The probe did not run and no project file was changed; verification was briefly delayed.
- **Confirmed cause:** The command treated a statement as a pipeline element without first collecting or grouping its output.
- **Correction:** Collect the `foreach` results in an explicit list, then pass the completed list to formatting.
- **Prevention:** Build bounded verification results explicitly before piping them to display commands.
- **Related verification:** The corrected probe showed that `Test-Json` accepts both `-1e-100` and negative `Double.Epsilon` against `minimum: 0`; the router wrapper rejects the same value with `number_below_minimum` at the exact candidate path.
