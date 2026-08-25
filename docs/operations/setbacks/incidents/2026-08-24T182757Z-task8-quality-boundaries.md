# SB-20260824-182757-task8-quality-boundaries: Task 8 boundary and transport quality gaps

- **Status:** closed
- **First observed:** 2026-08-24T18:27:57Z
- **Last observed:** 2026-08-25T23:21:16.5260211Z
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
8. Final review found that the first usage fixtures used synthetic visible and hidden token fields. Focused RED produced four pilot failures and one router final-price failure before the provider adapters were corrected.

## Cause classification

- **Confirmed causes:** Boundary-only validation state was not preserved through normalization; native transport state classification was narrower than result-record semantics; startup resources were not explicitly admitted before policy; the first provider-usage fixtures modeled synthetic fields instead of the documented billed-output aggregates; and the CLI did not map internal outcomes to process exit classes.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** The CLI was not writing whitespace to stderr. Raw capture showed a zero-byte stderr stream for both request-file and stdin startup failures; the assertion itself mishandled an empty file.
- **Known exclusions:** No provider call, calibration, Task 9 work, or canonical-answer parser redesign is authorized.

## Correction and prevention

- **Correction:** Preserve raw boundary validation for policy while tracing the normalized request; share transport-success classification between the seam and result record; validate startup schemas, catalog, matrix, snapshots, and token estimates before policy; derive visible output from documented Codex and Agy billed-output aggregates while leaving Claude input/output-only usage incomplete; and map CLI outcomes to exits 0, 2, 3, 4, and 5.
- **Prevention:** Fixture-driven regressions cover eligible-catalog modality rejection, all requested transport states, realistic complete and malformed Codex/Agy envelopes, Claude input/output-only incompleteness, startup failures, every exit class, zero-byte CLI stderr, one-object stdout, privacy, and artifact boundaries.
- **Owner:** Codex.
- **Next diagnostic step:** None; correction verified offline.

## Verification and related work

- Product correction commit: `a71234d` (`fix: harden Task 8 execution boundaries`).
- Pilot: 109 assertions passed; one privilege-only symbolic-link check skipped.
- Router: 354 assertions passed.
- Python storage: 53 tests passed through the bundled interpreter.
- Direct file and stdin startup probes each returned exit 5, one JSON response plus CRLF on stdout, and exactly zero stderr bytes.
- PowerShell parsing reported zero errors in all changed scripts; `git diff --check` passed; no provider, paid API, calibration, runtime database, or Task 9 path was used.
- Final provider-accounting correction commit: `cb5cb50` (`fix: correct Task 8 provider usage accounting`).
- Final verification: 111 pilot assertions passed with one privilege-only symbolic-link check skipped; 355 router assertions passed, including Task 6 pricing and the provider-derived final-price regression; and all 53 Python storage tests passed.
- Realistic fixtures and focused cases now cover valid subtraction, missing hidden usage, negative, fractional, boolean, string, hidden-greater-than-output values, and Claude input/output-only incompleteness.

## Recurrence history

- 2026-08-24T18:27:57Z: Opened during Task 8 quality review.
- 2026-08-24T18:44:54Z: Closed after RED/GREEN correction, direct CLI byte acceptance, and full offline verification.
- 2026-08-24T18:54:32Z: Reopened after final review found that synthetic usage fixtures modeled visible and hidden output as independent provider fields instead of deriving visible output from the documented billed-output aggregate.
- 2026-08-24T22:23:29Z: Closed after realistic native-envelope RED/GREEN coverage, exact billed-output subtraction, full offline verification, and focused product commit `cb5cb50`.
- 2026-08-25T21:56:21Z: During Option 1 Task 8 offline acceptance at commit `5301a254`, the resolved Python 3.12 storage suite recreated the untracked `router/storage/__pycache__` directory. The cause was confirmed as normal import bytecode generation: the bytecode environment override was unset, the six entries were untracked `.pyc` files timestamped during the 53-test run, and the suite imports the storage modules. The exact resolved cache directory was verified inside the isolated worktree, contained no tracked or non-bytecode entries, and was removed. A clean `git status --short --branch` verified containment. No source, database, provider, credential, or live-calibration state was affected.
- 2026-08-25T21:57:06Z: The Option 1 Task 8 read-only secret-pattern scan command failed at PowerShell parse time because a single-quoted regular-expression literal incorrectly used backslash-style quote escaping. This recurred from attempt 4 above, changed no files, performed no scan, and printed no secret values. The retry used PowerShell-native quoting and separated the patterns into bounded scans.
- 2026-08-25T21:57:40Z: A later read-only function-index query passed a double-quoted pattern containing `$script:` to `rg`; PowerShell expanded it before invocation and `rg` rejected the resulting malformed expression. Other independent read-only queries in the same script completed, no files changed, and no sensitive values were printed. Remaining review queries were changed to fixed-string or single-purpose literal patterns with no PowerShell interpolation tokens.
- 2026-08-25T22:35:37.4042720Z: The resolved 53-test storage rerun recreated the same six untracked `.pyc` files under the isolated worktree's `router/storage/__pycache__`. The exact cache path was verified beneath the worktree and contained only generated bytecode, then was removed. A clean status check verified containment; no source, database, provider, credential, or live path was affected.
- 2026-08-25T23:21:16.5260211Z: The final five-suite gate's resolved 53-test storage run recreated the same six untracked `.pyc` files in the exact isolated-worktree cache directory. Inspection again found only the six expected Python 3.12 bytecode files; no tracked source or database file was present. The bounded cache directory was removed before final status verification.
