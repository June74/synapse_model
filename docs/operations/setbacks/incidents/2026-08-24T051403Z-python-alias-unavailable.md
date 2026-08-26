# SB-20260824-051403-python-alias-unavailable: Python alias unavailable during storage baseline

- **Status:** closed
- **First observed:** 2026-08-24T05:14:03Z
- **Last observed:** 2026-08-26T15:32:58.107276Z
- **Phase/task:** Task 8 pre-implementation baseline
- **Environment:** Windows PowerShell, Codex desktop managed workspace
- **Version/commit:** `50ca437`

## Symptom

The requested `python -m unittest router.storage.test_sqlite_store` command failed before test discovery because `python` was not a recognized command in the managed shell.

## Impact

The initial storage baseline did not run. No product file, database, provider, credential, or external service was touched.

## Reproduction conditions

Invoke `python` from the Task 8 managed PowerShell environment without resolving the bundled runtime first.

## Safe evidence

- `Get-Command py, python, python3` returned no command.
- The bundled interpreter exists under the Codex primary runtime dependencies.
- The same storage suite completed through that bundled interpreter.

## Attempts and outcomes

1. Ran the requested command through the unavailable alias; PowerShell returned command-not-found.
2. Located the bundled runtime interpreter without changing PATH.
3. Ran the complete storage suite through the bundled interpreter; 52 tests completed with exit code 0.

## Cause classification

- **Confirmed cause:** The managed shell does not expose a `python`, `python3`, or `py` alias even though a bundled Python runtime is installed.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** The Python runtime and storage suite are not missing or broken.
- **Known exclusions:** No repository runtime database, live provider, secret, or network access was involved.

## Correction and prevention

- **Correction:** Use the bundled interpreter path for this environment.
- **Prevention:** Resolve the repository-approved or bundled Python executable before invoking Python verification.
- **Owner:** Codex.
- **Next diagnostic step:** None.

## Verification and related work

The bundled interpreter completed all 52 storage tests with exit code 0 in 15.598 seconds. On recurrence during Task 8 quality verification, it completed all 53 current storage tests with exit code 0 in 15.222 seconds. The 2026-08-25T22:30:48Z recurrence was closed by rerunning all 53 storage tests through the resolved bundled interpreter; they passed in 14.618 seconds with exit code 0.

## Recurrence history

- 2026-08-26T15:32:58.107276Z: The unavailable `py` alias recurred while invoking the correctly resolved setback helper. The bundled Python path from the workspace dependency inventory then ran the helper successfully; no provider, launcher, network, or live calibration path ran.
- 2026-08-26T14:53:12Z: The unavailable `python` alias recurred while attempting to invoke the setback helper during Task 3. The helper was not present at the expected repository path, so the new incident was recorded directly with the repository template contract. Work remained offline; no provider, launcher, network, or live calibration path ran.
- 2026-08-26T05:24:28.365954Z: The unavailable `python` alias recurred while locating the setback helper during Task 2. Work remained offline and contained. The bundled Python runtime was resolved through the workspace dependency inventory and successfully ran the helper; no provider, launcher, network, or live calibration path ran.
- 2026-08-25T22:30:48.1539712Z: The unavailable `python` alias recurred in the Task 8 final five-suite wrapper after the pilot and router suites passed. The wrapper continued to the calibration suites because command-not-found did not supply a failing native exit code; no provider, network, or live path ran. The storage suite remains unverified in that wrapper and must be rerun with the resolved repository-approved runtime.
- 2026-08-25T20:23:24.5926183Z: The unavailable `python` and `py` aliases recurred while starting the Task 6 parallel-suite setback helper. Work remained contained; the bundled runtime was resolved before continuing, and no product or live path ran.
- 2026-08-25T19:55:35.3677309Z: The unavailable `python` and `py` aliases recurred during Task 6 setback-helper discovery. Work remained contained, no product path or provider launcher ran, and the bundled Python 3.12 executable was resolved through the workspace dependency inventory before continuing.
- 2026-08-25 Task 5: The unavailable `python` alias recurred while requesting setback-helper usage for the first GREEN failure. Work remained contained, no provider or native launcher ran, and the bundled runtime was resolved before retrying the helper.
- 2026-08-25T18:44:00Z: The unavailable `python` and `py` aliases recurred while invoking the setback helper. The installed Python 3.12 executable was resolved explicitly and the helper completed after the required scoped execution approval.

- 2026-08-24T05:14:03Z: First observed and closed.
- 2026-08-24T18:44:54Z: The unavailable alias recurred once; the documented bundled-interpreter path completed all 53 current tests.
