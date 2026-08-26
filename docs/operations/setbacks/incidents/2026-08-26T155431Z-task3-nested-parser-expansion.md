# SB-20260826-155431-task3-nested-parser-expansion: Nested PowerShell parser check lost variables to outer expansion

- **Status:** closed
- **First observed:** 2026-08-26T15:54:31.942794Z
- **Last observed:** 2026-08-26T15:54:31.942794Z
- **Phase/task:** Task 3 follow-up verification
- **Environment:** Windows PowerShell verification shell in the isolated option1-calibration-pilot worktree
- **Version/commit:** 0401d508a7eefd839fcf18f17a342ebd86344915 plus uncommitted Task 3 follow-up

## Symptom

The nested pwsh -Command parser loop reached the inner shell with foreach variable names removed and exited with a ParserError before checking files.

## Impact

No production or test state changed; final parser verification was delayed until rerun without nested shell interpolation.

## Reproduction conditions

An outer PowerShell invocation launched a second `pwsh -Command` whose script was enclosed in double quotes. The outer shell expanded the inner `$files`, `$file`, `$tokens`, and `$errors` variables before the nested process received the script.

## Safe evidence

The nested process reported `Missing variable name after foreach`; the rendered command showed `foreach ( in )`, confirming that expansion happened before parsing the intended loop.

## Attempts and outcomes

1. Ran the parser loop through a nested `pwsh -Command`; it failed before any repository file was parsed.
2. Ran the parser loop directly in the existing PowerShell process; all four changed PowerShell files parsed successfully.

## Cause classification

- **Confirmed cause:** Nested double-quoted PowerShell command text allowed the outer shell to consume variables intended for the inner shell.
- **Hypotheses:** None outstanding.
- **Rejected hypotheses:** The changed repository files did not contain parser errors.
- **Known exclusions:** No provider, launcher, network, or live calibration execution occurred.

## Correction and prevention

- **Correction:** Removed the nested shell and parsed the files directly in the current PowerShell process.
- **Prevention:** Prefer one PowerShell parse boundary; if nesting is unavoidable, use a literal script file or single-quoted command text with deliberate argument passing.
- **Owner:** Codex and project owner.
- **Next diagnostic step:** None; closed after direct parser verification.

## Verification and related work

Direct parser verification returned `PASS parse` for `pilot/lib/runner.ps1`, `pilot/tests/runner.tests.ps1`, `calibration/run_calibration.ps1`, and `calibration/tests/calibration.tests.ps1` with exit code 0.

## Recurrence history

- 2026-08-26T15:54:31.942794Z: First observed.
