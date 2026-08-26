# Agy Adapter and Calibration Envelope Repair Design

## Purpose

Repair the contained Option 1 live failure without making another provider call. The repair must make the pilot adapter and calibration validator share one canonical-response contract, retain bounded rejection evidence, and bind future live execution to reviewed launcher identities.

## Confirmed live path

`run_calibration.ps1 -Pilot -Run` calls `Invoke-CalibrationPilotRun`, which invokes `Invoke-PilotCandidate`, parses provider output, and passes the normalized execution to `Test-CalibrationPilotExecutionEnvelope`. The contained live run stopped at this final boundary before either judge launched.

## Canonical response contract

Every provider adapter returns exactly three canonical properties in this order: `status`, `answer`, `error`. JSON member order is not semantically meaningful, so a response containing exactly those three properties is re-materialized in that order before validation.

Normalization must preserve the original value types. It must not cast an invalid status, answer, or error into a string, and it must not discard unexpected properties. Agy's existing empty-string success error compatibility remains: an exact three-property success with `error = ""` becomes `error = null`.

## Provider-declared failure contract

A schema-valid canonical response with `status = failure` is a provider-declared response, not an adapter or transport failure. `Invoke-PilotCandidate` therefore returns:

- the canonical failure unchanged except for safe ordering;
- `failure = null`;
- `diagnostic_note = provider-declared failure`;
- valid process and usage evidence.

Calibration accepts the execution envelope as structurally valid, stops with `response_contract_invalid`, persists bounded process evidence, and launches no later roles. The `failure` field remains reserved for transport, parsing, adapter-contract, or execution failures.

## Bounded envelope diagnostics

Every invalid envelope returns one rejection code from this fixed allowlist:

- `execution_shape`
- `start_state`
- `failure_metadata`
- `process_shape`
- `process_values`
- `usage`
- `canonical_shape`
- `canonical_values`
- `semantic_conflict`

Each attempt artifact adds nullable `envelope_rejection_code`. It is populated only when the envelope itself is invalid. It never contains raw values, exception text, prompts, answers, errors, paths, or credentials. Existing public stop codes remain unchanged.

## Launcher identity lock

Future live execution must be bound to a reviewed `calibration/pilots/option1-launchers-v1.json` file. Its SHA-256 is included in the immutable pilot plan's source hashes. Each role lists exact, ordered component identities and marks each component as either provenance or the executable passed to `Process.Start`. Agy has one executed native component. Codex records its reviewed shim, JavaScript entrypoint, platform-package manifest, and platform-native executable; only the native executable is run. Claude records its reviewed shim and native executable; only the native executable is run. The checked-in lock contains deterministic locator kinds, anchors, relative paths, and hashes, never user-specific absolute paths, parent traversal, environment expansion, or wildcards.

The offline `-Pilot` plan validates the lock's schema and source hash but never resolves or starts installed launchers. `-Pilot -Run` prepares and verifies all three role identities in one preflight before the first slot claim or invoker call. A mismatch or unverifiable component in any role stops with `source_drift`, zero total slot claims, and zero provider calls.

The installed shim source is verified as provenance, but the prepared Codex and Claude commands invoke their reviewed native executables directly. This removes both the shim's alternate adjacent-Node branch and the JavaScript entrypoint's dynamic package resolution. Codex direct execution reproduces the wrapper's managed-package environment for the reviewed npm layout; the runner already owns timeout and process-tree cleanup instead of relying on the JavaScript signal-forwarding parent. Every component is opened read-only without write/delete sharing before hashing, reparse components are rejected, and all preflight handles stay open until the run reaches a terminal result. Later provider arguments are bound to the already verified role identity without filesystem re-resolution. The exact prepared native command is executed once. No `--version`, updater, model, or provider command is run as part of identity checking.

## Test and safety requirements

All repair work is test-first and offline. Required regressions cover reordered success, reordered provider failure, invalid type preservation, unexpected-property rejection, provider-failure evidence, every bounded rejection category, launcher mismatch before claim, matching prepared-launch ordering, and privacy scans.

The five existing offline suites must pass before a new acceptance packet is prepared. The consumed RunId `option1-live-20260825-001` is never reused. A new live command requires a new reviewed commit, new RunId, new immutable hashes, and separate explicit approval.
