# SB-20260824-182757-task8-quality-boundaries: Task 8 boundary and transport quality gaps

- **Status:** closed
- **First observed:** 2026-08-24T18:27:57Z
- **Last observed:** 2026-08-24T18:44:54Z
- **Phase/task:** Task 8 selected-route execution quality follow-up
- **Environment:** Windows PowerShell 7, deterministic-router-v1 worktree
- **Version/commit:** `9154b0b`

## Symptom

Unsupported modality fields can be removed by request normalization before policy validation, and pilot candidate execution does not reject every failed native transport state before provider parsing. Startup failures, provider usage aggregates, and CLI exit classes also lack the requested explicit contracts.

## Impact

An eligible catalog could execute a text route for an unsupported modality, and an exit-zero process with timeout, cleanup, or process-exit failure metadata could be treated as parseable execution. No provider or paid API was invoked while diagnosing these gaps.

## Safe evidence

The live router path validates the raw request, then invokes policy with the normalized request that omits modality fields. The pilot seam checks exit code before parsing but does not first classify all transport state flags.

## Attempts and outcomes

1. Confirmed the live CLI, router, policy, and pilot seam paths.
2. Removed an untracked `router/storage/__pycache__` directory produced by prior local Python verification; no source or runtime database was removed.
3. Added RED coverage: pilot failed one transport-state assertion and three provider-usage assertions; router failed five assertions covering modality, transport propagation, startup safety, exit mapping, and startup CLI behavior.
4. A repository search command used an invalid PowerShell regular expression and was replaced with a bounded literal-root search; it changed no files and exposed no data.
5. The first CLI schema-path parameter name clobbered the test suite variable when dot-sourced, causing cascading schema failures. The internal parameter was renamed while preserving the public alias, and the full router suite was rerun.
6. The final stderr assertion used `Get-Content` on an empty file, which emits no object. Direct process-stream capture proved both startup paths already produced zero stderr bytes; the test now checks file length instead.
7. The managed shell's unavailable `py` alias recurred once. Verification switched to the repository-resolved bundled interpreter and completed all 53 storage tests.

## Cause classification

- **Confirmed causes:** Boundary-only validation state was not preserved through normalization; native transport state classification was narrower than result-record semantics; startup resources were not explicitly admitted before policy; provider envelopes were not supplying normalized usage; and the CLI did not map internal outcomes to process exit classes.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** The CLI was not writing whitespace to stderr. Raw capture showed a zero-byte stderr stream for both request-file and stdin startup failures; the assertion itself mishandled an empty file.
- **Known exclusions:** No provider call, calibration, Task 9 work, or canonical-answer parser redesign is authorized.

## Correction and prevention

- **Correction:** Preserve raw boundary validation for policy while tracing the normalized request; share transport-success classification between the seam and result record; validate startup schemas, catalog, matrix, snapshots, and token estimates before policy; extract exact final provider usage without changing answer parsers; and map CLI outcomes to exits 0, 2, 3, 4, and 5.
- **Prevention:** Fixture-driven regressions cover eligible-catalog modality rejection, all requested transport states, complete and incomplete Codex/Claude/Agy usage, startup failures, every exit class, zero-byte CLI stderr, one-object stdout, privacy, and artifact boundaries.
- **Owner:** Codex.
- **Next diagnostic step:** None; correction verified offline.

## Verification and related work

- Product correction commit: `a71234d` (`fix: harden Task 8 execution boundaries`).
- Pilot: 109 assertions passed; one privilege-only symbolic-link check skipped.
- Router: 354 assertions passed.
- Python storage: 53 tests passed through the bundled interpreter.
- Direct file and stdin startup probes each returned exit 5, one JSON response plus CRLF on stdout, and exactly zero stderr bytes.
- PowerShell parsing reported zero errors in all changed scripts; `git diff --check` passed; no provider, paid API, calibration, runtime database, or Task 9 path was used.

## Recurrence history

- 2026-08-24T18:27:57Z: Opened during Task 8 quality review.
- 2026-08-24T18:44:54Z: Closed after RED/GREEN correction, direct CLI byte acceptance, and full offline verification.
