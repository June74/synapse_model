# SB-20260824-033023-sqlite-test-connection-not-closed: SQLite test reader left Windows file handles open

- **Status:** closed
- **First observed:** 2026-08-24T03:30:23.302123Z
- **Last observed:** 2026-08-24T03:30:23.302123Z
- **Phase/task:** Task 7 Python GREEN run
- **Environment:** Windows PowerShell, bundled Python 3.12.13
- **Version/commit:** `0942765` plus uncommitted Task 7 product work

## Symptom

Seven SQLite tests reached cleanup with WinError 32 because the shared rows helper used the sqlite3 connection context manager without explicitly closing the connection.

## Impact

Behavioral results could not be accepted and temporary test directories could not be removed during that run; no repository database or provider was used.

## Reproduction conditions

Run `python -m unittest router.storage.test_sqlite_store` after the writer creates temporary SQLite databases. Tests that call `rows()` leave a connection open until garbage collection, and Windows prevents temporary-directory deletion.

## Safe evidence

- All seven errors end in `PermissionError: [WinError 32]` while deleting the temporary `router.sqlite` file.
- The shared `rows()` helper returns from a `with sqlite3.connect(...)` block.
- The SQLite connection context manager handles transactions but does not close the connection.

## Attempts and outcomes

1. Read all error traces and confirmed the failures occur only during test cleanup.
2. Traced every affected test through the shared `rows()` helper.
3. Added an explicit `connection.close()` in a `finally` block; verification is pending.

## Cause classification

- **Confirmed cause:** The test helper incorrectly assumed the SQLite connection context manager closes the connection.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** The writer process itself is not retaining the file handle; each subprocess exits before the cleanup error.
- **Known exclusions:** No project-local runtime database, provider, credential, or external service was involved.

## Correction and prevention

- **Correction:** Explicitly close every read connection in the shared test helper.
- **Prevention:** Treat transaction scope and connection lifetime as separate concerns in SQLite tests.
- **Owner:** Codex.
- **Next diagnostic step:** None.

## Verification and related work

The corrected `python -m unittest router.storage.test_sqlite_store` run completed all 13 tests with exit code 0 and removed every temporary directory without a file-lock error.

## Recurrence history

- 2026-08-24T03:30:23.302123Z: First observed.

## Recurrence: 2026-08-24, direct writer acceptance

- **Symptom:** Same-process schema acceptance printed the correct database contents but exited with WinError 32 when deleting `acceptance.sqlite`.
- **Confirmed cause:** Production `write_trace()` also used the SQLite transaction context manager without an explicit connection close. CLI tests masked the leak because each helper subprocess exits immediately.
- **Impact:** The CLI contract remained functional, but direct library use retained a Windows file handle until garbage collection; acceptance could not pass.
- **Correction:** Added a direct-writer regression test and made `write_trace()` close its owned connection in a `finally` block.
- **Prevention:** Connection-owning functions must close their own SQLite handles even when transaction contexts are also used.
- **Verification:** The regression test and full 15-test storage suite pass. Same-process schema acceptance exits 0 and deletes its temporary database cleanly.
