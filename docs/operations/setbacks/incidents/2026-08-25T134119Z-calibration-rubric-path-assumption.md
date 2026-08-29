# SB-20260825-134119-calibration-rubric-path-assumption: Calibration rubric path assumed incorrectly during planning

- **Status:** closed
- **First observed:** 2026-08-25T13:41:19.481246Z
- **Last observed:** 2026-08-25T13:41:19.481246Z
- **Phase/task:** Option 1 implementation planning
- **Environment:** Windows PowerShell 7, isolated `codex/option1-calibration-pilot` worktree
- **Version/commit:** `8692461`

## Symptom

A read-only inspection requested calibration/rubric-v1.json, which is not a repository file; the helper invocation also found that python is not on PATH.

## Impact

No runtime or user data changed; planning paused briefly to correct the path and use the configured Python runtime.

## Reproduction conditions

Run a read-only source inventory with a guessed singular rubric path, then invoke the setback helper with the bare `python` command.

## Safe evidence

- `rg --files calibration/rubrics` lists `calibration/rubrics/extraction-v1.json`.
- `Resolve-RouterPythonExecutable` returns the bundled Python executable.
- `git status --short` showed only this incident and its index update after the helper ran.

## Attempts and outcomes

1. Read `calibration/rubric-v1.json`: failed because that guessed path does not exist.
2. Ran the helper with `python`: failed because `python` is not on `PATH` in this shell.
3. Resolved the repository-configured Python executable and reran the helper successfully.
4. Enumerated `calibration/rubrics/` and confirmed the selected prompt uses `extraction-v1.json`.

## Cause classification

- **Confirmed cause:** The inspection used a guessed singular rubric filename instead of enumerating the repository's `calibration/rubrics/` directory; the shell also requires the configured bundled Python path instead of the bare `python` command.
- **Hypotheses:** None.
- **Rejected hypotheses:** The rubric was missing from the repository; enumeration proved the required extraction rubric exists under `calibration/rubrics/`.
- **Known exclusions:** No provider command ran, no runtime source changed, and no user data was exposed.

## Correction and prevention

- **Correction:** Use `calibration/rubrics/extraction-v1.json` and the executable returned by `Resolve-RouterPythonExecutable`.
- **Prevention:** Enumerate repository files with `rg --files` before naming a source path, and resolve Python through the repository helper in this environment.
- **Owner:** Codex and project owner.
- **Next diagnostic step:** None; the failed read boundary and helper execution were both rechecked successfully.

## Verification and related work

- Verified the actual extraction rubric path with `rg --files calibration/rubrics`.
- Verified the bundled interpreter by running the helper's `--help` and creating this incident successfully.

## Recurrence history

- 2026-08-25T13:41:19.481246Z: First observed.
