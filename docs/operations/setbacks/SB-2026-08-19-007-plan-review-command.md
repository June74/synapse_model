# SB-2026-08-19-007: Plan review command used an invalid PowerShell parameter

- **Status:** contained
- **First observed:** 2026-08-19
- **Last observed:** 2026-08-19
- **Symptom:** A self-review command attempted to combine `Sort-Object -Join`, which is not a valid PowerShell parameter combination.
- **Confirmed:** The failure affected only the review command. The implementation plan was not modified or lost.
- **Correction:** Re-run the checks with an explicit `-join` expression and continue only after the checks succeed.

## Recurrence: 2026-08-23, Task 6 source inspection

- **Phase/task:** Deterministic router V1 Task 6 pre-implementation inspection.
- **Symptom:** A read-only `Select-String` command rejected a malformed combined regular expression before searching the router test file.
- **Impact:** No repository file or external state changed; source inspection was briefly delayed.
- **Confirmed cause:** The combined pattern contained mismatched escaping and parentheses.
- **Correction:** Re-run with `-SimpleMatch` and separate literal patterns.
- **Prevention:** Use literal-pattern search for known PowerShell source tokens; reserve regular expressions for cases that require them.
- **Related verification:** The corrected search located the policy module gate, existing `Invoke-RouterPolicy` tests, and the Task 6 pending marker.
