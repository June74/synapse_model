# SB-2026-08-19-010: Parser verification command used invalid PowerShell interpolation

- **Status:** closed
- **First observed:** 2026-08-19
- **Last observed:** 2026-08-25
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

## Recurrence: 2026-08-23, Task 3 quality-snapshot follow-up

- **Phase/task:** Second specification-review follow-up parser verification
- **Symptom:** The combined parser probe emitted `InvalidOperation` before parsing because `[ref]` was applied to error variables that had not been initialized.
- **Impact:** The parser result was not trustworthy; no project files were changed by the failed probe and implementation work was briefly delayed.
- **Confirmed cause:** PowerShell requires a variable to exist before it can be passed by reference.
- **Correction:** Initialize token and error variables to `$null` before calling `Parser.ParseFile`, and judge success only after the call completes without command errors.
- **Prevention:** Parser verification snippets must initialize every `[ref]` target explicitly.
- **Related verification:** Corrected parser probe completed for both the loader and router test file with zero parse errors.

## Recurrence: 2026-08-23, Task 3 counted verification

- **Phase/task:** Post-commit router-suite evidence count
- **Symptom:** The counting wrapper exited 1 even though the router suite exited 0 and emitted 112 PASS lines.
- **Impact:** No product code or test outcome changed; the wrapper briefly misreported four failures.
- **Confirmed cause:** The wrapper searched for `FAIL` anywhere in a line, so passing test names containing the word `failure` were false positives.
- **Correction:** Count only lines beginning with `FAIL ` or `Write-Error:` and preserve the suite's own exit code separately.
- **Prevention:** Verification summaries must anchor status-token matches at the beginning of each output line.
- **Related verification:** Corrected counted run reported exit 0, 112 passes, zero failures, and one planned Task 6 pending marker.

## Recurrence: 2026-08-23, Task 4 unsupported-dimension reproduction

- **Phase/task:** Task 4 specification-fix RED reproduction
- **Symptom:** The reproduction command failed with `An empty pipe element is not allowed` at a direct `foreach`-to-`ConvertTo-Json` pipeline.
- **Impact:** The first reproduction did not run; no project file or external state changed, and verification was briefly delayed.
- **Confirmed cause:** A standalone PowerShell `foreach` statement was piped directly instead of collecting its output first.
- **Correction:** Assign the loop output to `$results`, then pipe `$results` to `ConvertTo-Json`.
- **Prevention:** Collect statement output before piping it in bounded PowerShell verification snippets.
- **Related verification:** The corrected reproduction ran and exposed all three unsupported-dimension pass defects, after which the full corrected router suite passed 177 assertions with exit 0.

## Recurrence: 2026-08-24, Task 8 unsupported-trace GREEN verification

- **Phase/task:** Task 8 final contract correction
- **Symptom:** A result-counting wrapper failed at parse time because a pipeline expression was embedded directly in a hashtable property without a complete grouped expression.
- **Impact:** The router suite did not start in that invocation; no project state changed and no provider or external service ran.
- **Confirmed cause:** The ad hoc wrapper combined output filtering and object construction with mismatched statement delimiters.
- **Correction:** Compute each count in a separate statement, then emit the compact summary after the suite exits.
- **Prevention:** Keep verification wrappers linear and preserve the child suite exit code independently of summary formatting.
- **Related verification:** The corrected plain suite command is required before the Task 8 product commit.

## Recurrence: 2026-08-25, Task 10 authorized-live preflight

- **Phase/task:** Read-only candidate/profile validation before the three authorized launcher calls
- **Symptom:** The preflight failed at parse time with `An empty pipe element is not allowed` because a direct `foreach` statement was piped to `ConvertTo-Json`.
- **Impact:** The preflight did not run; zero launchers or providers were called and no project or external state changed.
- **Confirmed cause:** The bounded reporting command repeated the known direct-statement-to-pipeline PowerShell error.
- **Correction:** Collect the `foreach` output in `$results`, then serialize the completed collection.
- **Prevention:** Use an explicit result variable for every multi-item PowerShell preflight before piping to formatting or JSON conversion.
- **Related verification:** The corrected candidate/profile preflight must pass before any authorized live call begins.
