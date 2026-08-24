# SB-20260824-051403-python-alias-unavailable: Python alias unavailable during storage baseline

- **Status:** closed
- **First observed:** 2026-08-24T05:14:03Z
- **Last observed:** 2026-08-24T05:14:03Z
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

The bundled interpreter completed all 52 storage tests with exit code 0 in 15.598 seconds.

## Recurrence history

- 2026-08-24T05:14:03Z: First observed and closed.
