# SB-2026-08-19-007: Plan review command used an invalid PowerShell parameter

- **Status:** contained
- **First observed:** 2026-08-19
- **Last observed:** 2026-08-19
- **Symptom:** A self-review command attempted to combine `Sort-Object -Join`, which is not a valid PowerShell parameter combination.
- **Confirmed:** The failure affected only the review command. The implementation plan was not modified or lost.
- **Correction:** Re-run the checks with an explicit `-join` expression and continue only after the checks succeed.
