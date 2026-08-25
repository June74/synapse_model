# SB-20260824-044250-sqlite-trace-quality-review: SQLite trace admission and bridge durability gaps

- **Status:** closed
- **First observed:** 2026-08-24T04:42:50Z
- **Last observed:** 2026-08-24T05:02:06Z
- **Phase/task:** Task 7 quality review
- **Environment:** Windows PowerShell; bundled CPython standard library SQLite
- **Version/commit:** `16f3d51b004cb447f4f550ffcac6af21626c071e`

## Symptom

Review found that the PowerShell bridge performs blocking pipe operations without a timeout, stored benchmark/calibration content is not bound to its supplied hashes or screened for narrow high-confidence credential forms, and the Python writer combines contract, router-derived calculations, schema, persistence, and CLI behavior in one 1,544-line file.

## Impact

A helper that blocks or fills a redirected pipe can stall the caller indefinitely. Reproducibility content can be stored under a mismatched digest, a narrow class of obvious credential material can pass admission, and duplicated quality/price calculations can drift from the live router policy.

## Reproduction conditions

Use synthetic local Python helpers that hang, fill stderr before reading a large stdin stream, or exit before stdin completes. Submit benchmark/calibration traces with mismatched SHA-256 values or synthetic high-confidence credential patterns. Submit internally coherent producer values that differ from storage's independently recomputed quality rank or token-rate price.

## Safe evidence

- The bundled Python suite expanded to 51 tests and produced 16 targeted RED failures: 2 hash, 7 credential admission, 2 duplicated calculation, and 5 decomposition/file-size failures.
- The full PowerShell suite retained 329 passing assertions and produced 5 targeted bridge RED failures because the bounded helper/timeout interface does not exist.
- No provider was invoked. No real credential, raw production trace, runtime database, or user content was recorded.

## Attempts and outcomes

1. Confirmed the live test path: `router.tests.ps1` -> `Write-RouterTrace` -> direct `sqlite_store.py` process.
2. Added bounded synthetic-helper tests before production edits; the old bridge fails at parameter admission rather than risking an unbounded test hang.
3. Added content, calculation-boundary, decomposition, and contention controls before production edits; the distinct-trace and held-lock controls already pass.
4. The first post-split GREEN attempt passed 50 of 51 Python tests; one synthetic AWS secret form ending in a non-word Base64 character bypassed an incorrect terminal word boundary in the new admission expression.
5. The first bridge GREEN attempt passed the stderr-drain, early-exit, and malformed-protocol probes but returned multiple PowerShell pipeline objects for timeout and valid large-stream paths; investigation is isolating the unintended output source before correction.
6. The first focused output-contamination diagnostic used an invalid nested PowerShell string and stopped at parser admission before creating or running a helper; it was replaced with a literal here-string invocation.

## Cause classification

- **Confirmed cause:** The bridge writes stdin and drains stdout/stderr sequentially with no deadline. Content admission validates only field names and hash syntax. The writer accumulated router calculation checks and schema/persistence responsibilities in one module.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** SQLite contention is not the source of these review failures; the new two-process and held-lock controls pass before implementation.
- **Known exclusions:** Provider execution, calibration, Task 8, and the model matrix are outside this boundary.

## Correction and prevention

- **Correction:** Product commit `0e1d98b` adds bounded concurrent process I/O and tree cleanup, exact UTF-8 content/hash binding, narrow high-confidence content admission, focused standard-library modules, an independently pinned V1 schema fixture, and a no-provider live-policy differential storage test.
- **Prevention:** Retain synthetic pipe-pressure, timeout/process-tree, content admission, module-size, direct-entrypoint, contention, and differential fixtures.
- **Owner:** Codex and project owner.
- **Next diagnostic step:** None; the incident is closed and the regression fixtures remain in the normal suites.

## Verification and related work

- Python: 52 tests passed with the bundled interpreter.
- PowerShell: 335 assertions passed, including timeout/tree cleanup, pipe-pressure, early-exit, large-stream, exact protocol, and live-policy differential storage probes.
- Disposable schema acceptance observed V1, two approved tables, five approved indexes, one foreign key, one decision, and four candidate rows.
- `git diff --check` passed; no runtime SQLite file was present, staged, or tracked; generated storage bytecode cache was removed.

## Recurrence history

- 2026-08-24T04:42:50Z: First observed during Task 7 quality review.
- 2026-08-24: A read-only inline Python schema-diff diagnostic failed before execution because nested PowerShell/Python quoting left an unclosed parenthesis. No database or product file was touched; a literal here-string retry succeeded.
- 2026-08-24: Product staging was blocked before mutation because the managed sandbox denied creation of the shared worktree `index.lock`; no file was staged. A permission-scoped Git retry succeeded.
- 2026-08-24T05:02:06Z: Closed after product commit `0e1d98b` and full acceptance.
