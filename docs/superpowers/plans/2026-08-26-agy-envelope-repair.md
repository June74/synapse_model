# Agy Adapter and Calibration Envelope Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Option 1 Agy adapter, calibration envelope, diagnostics, and launcher identity boundary deterministic and offline-verifiable before another live packet.

**Architecture:** Normalize canonical responses once at the shared pilot adapter boundary, reserve `failure` for adapter/transport failures, and make the strict envelope return a bounded rejection category. Bind live launch preparation to a reviewed launcher-lock source and execute the same verified command without re-resolution.

**Tech Stack:** PowerShell 7, JSON schemas and manifests, Windows `System.Diagnostics.Process`, SHA-256, repository-native assertion suites.

---

### Task 1: Shared canonical response and provider-failure semantics

**Files:**
- Modify: `pilot/lib/runner.ps1:192-211,1559-1596`
- Test: `pilot/tests/runner.tests.ps1:712-757,1719-1743`
- Test: `calibration/tests/calibration.tests.ps1`

- [x] **Step 1: Write failing adapter tests**

Add assertions proving an Agy success and failure with input key order `answer,error,status` return `status,answer,error`; invalid value types remain invalid; and unexpected properties are not discarded.

- [x] **Step 2: Run the pilot suite and verify RED**

Run `pwsh -NoProfile -File .\pilot\tests\runner.tests.ps1`. Expected: the reordered canonical-property assertions fail against the current passthrough behavior.

- [x] **Step 3: Normalize exact canonical objects without coercion**

Change `ConvertTo-AgyCanonicalResponse` so exact three-property objects are returned as:

```powershell
[pscustomobject][ordered]@{
    status = $Response.status
    answer = $Response.answer
    error = $normalizedError
}
```

Return objects with missing or unexpected properties unchanged so `Test-CanonicalResponse` remains the rejection authority.

- [x] **Step 4: Write and verify the provider-failure RED test**

Use a fully native-shaped fake Agy result with canonical `status = failure`. Assert `failure = $null`, the bounded diagnostic remains `provider-declared failure`, the envelope is valid, its stop code is `response_contract_invalid`, process evidence is available, and no judge is called. Run the focused pilot and calibration suites and confirm the current line that copies every non-completed diagnostic into `failure` causes RED.

- [x] **Step 5: Implement minimal failure-channel separation**

Set `failure` from the record only when `record.contract_compliant` is false. A valid canonical success or canonical failure keeps `failure = $null`.

- [x] **Step 6: Run GREEN suites and commit**

Run the pilot, calibration functional, and calibration security suites. Commit only Task 1 files with `fix: align pilot canonical response semantics`.

### Task 2: Bounded envelope rejection evidence

**Files:**
- Modify: `calibration/run_calibration.ps1:39-50,1251-1357,1764-1827,1880-1940,2340-2396,2913-3031`
- Test: `calibration/tests/calibration.tests.ps1`
- Test: `calibration/tests/calibration_security.tests.ps1`

- [x] **Step 1: Write failing reason-category tests**

For each malformed-envelope branch, assert the fixed `rejection_code` category and assert valid envelopes return null. Add artifact-contract assertions for nullable `envelope_rejection_code` on every attempt.

- [x] **Step 2: Verify RED**

Run both calibration suites in dedicated session-aware calls. Expected: the new rejection property/category assertions fail because the validator currently returns only the generic stop code.

- [x] **Step 3: Implement the bounded enum**

Add `$script:CalibrationPilotEnvelopeRejectionCodes` with the nine approved values. Replace anonymous invalid returns with a helper that returns `valid`, `process_started`, `start_indeterminate`, `success`, `stop_code`, and `rejection_code`. Do not include rejected values.

- [x] **Step 4: Persist only the safe category**

Add nullable `envelope_rejection_code` to each attempt. Pass the invalid envelope to `Complete-CalibrationPilotFailure`, copy only its allowlisted rejection code, and extend the exact result-contract checks.

- [x] **Step 5: Add privacy regressions and run GREEN**

Inject prompt, canonical error, path, and credential sentinels into malformed inputs and prove none appear in the result tree. Run both calibration suites and commit with `fix: persist bounded pilot envelope diagnostics`.

### Task 3: Reviewed launcher identity and prepared launch

**Files:**
- Create: `calibration/pilots/option1-launchers-v1.json`
- Create: `calibration/pilots/option1-launchers.schema.json`
- Modify: `pilot/lib/runner.ps1:635-688,937-1060,1510-1547`
- Modify: `calibration/run_calibration.ps1` source loading, plan hashes, preflight, launch guard, and invocation seams
- Test: `pilot/tests/runner.tests.ps1`
- Test: `calibration/tests/calibration.tests.ps1`
- Test: `calibration/tests/calibration_security.tests.ps1`

- [x] **Step 1: Write launcher-lock schema and mismatch RED tests**

Define exactly three ordered manifest-bound roles and exact component IDs, kinds, provenance/executed purposes, locators, and hashes. Reject duplicate or extra properties, wrong role/component order or case, malformed hashes, absolute or parent-traversing paths, environment expansion, wildcards, missing files, changed bytes, shim-only locks, omitted Codex package/native components, and external override attempts. Assert drift in any role returns `source_drift` before every slot claim and invoker.

- [x] **Step 2: Verify RED without executing launchers**

Use temporary fake executables and shims through injected resolution/start seams. Run the focused suites and confirm lock admission/prepared launch functions do not yet exist.

- [x] **Step 3: Load and bind the reviewed lock**

Validate the checked-in lock with duplicate-key rejection and its schema, include both repository lock hashes in `plan.source_hashes`, and bind exact role and component order. Codex records the reviewed shim, JavaScript entrypoint, platform-package manifest, and platform-native executable; Claude records its reviewed shim and native executable. Only the declared native component is executable. Offline plan mode hashes only repository lock inputs and performs zero installed-launcher resolution.

Reviewed repository byte hashes: launcher lock `aaeb23cdc7c55617f563359e2d7ab184157c9f551bb02a41bc201fc1f608b419`; launcher schema `cc6f5248724dd53fa50babcf3c77d67c53adbb6a7f180c28cf7f98186af2df20`.

- [x] **Step 4: Prepare immutable launcher identities**

Before the first claim, prepare all three identities, reject reparse components, verify every declared component from the same read handles, and hold those handles with write/delete sharing denied until the run is terminal. Build direct native commands for Codex and Claude so neither shim nor JavaScript can choose another branch. Reproduce Codex's reviewed npm managed-package environment. The launch guard returns the role's prepared identity after the durable claim; `Invoke-PilotCandidate` binds the already-built provider arguments and passes that exact prepared command into `Invoke-NativeCandidate`. The prepared path never calls `Resolve-RunnerNativeCommand`.

- [x] **Step 5: Preserve the non-refundable ordering**

All three identities are verified before the first guard can run. Each launch guard binds the exact prepared role identity, then calls `New-CalibrationPilotSlotClaim`; the process starts only after the durable claim. Any identity mismatch stops with `source_drift`, zero total slots, and zero processes.

- [x] **Step 6: Verify matching and replacement-race GREEN cases**

Prove matching fake components preserve all-role-prepare/verify-before-first-claim-before-start order; later-role drift yields zero total claims and invokers; the start seam receives the exact locked native Codex executable and prepared object; alternate package injection cannot affect the direct path; concurrent replacement fails after preflight, after claim, and through process completion; and every handle is released after success, source drift, claim failure, start failure, timeout, and invoker failure. Run all three PowerShell suites and commit with `fix: bind pilot launches to reviewed identities`.

### Task 4: Documentation, complete offline verification, and review

**Files:**
- Modify: `calibration/run_calibration.ps1`
- Modify: `router/README.md`
- Test: `calibration/tests/calibration.tests.ps1`
- Test: `calibration/tests/calibration_security.tests.ps1`
- Modify: `docs/operations/setbacks/incidents/2026-08-25T235222Z-option1-live-provider-envelope-invalid.md`
- Modify: `docs/operations/setbacks/INDEX.md`
- Modify: `docs/superpowers/plans/2026-08-26-agy-envelope-repair.md`

- [x] **Step 1: Freeze a fresh unapproved RunId and reject the consumed ID before side effects**

Change the executable live gate, active Option 1 operator command and text, exact documentation contract, and simulated-live functional and security fixtures to proposed RunId `option1-live-20260826-002`. Preserve historical specifications, plans, and incidents that record consumed RunId `option1-live-20260825-001`. Add an offline fake-only regression proving the consumed ID is rejected before Git preflight, launcher resolution or preparation, run/claim directory creation, candidate or judge invokers, artifact writers, or any result-tree write. The proposed ID is not approval to execute it.

- [x] **Step 2: Update the incident with correction evidence**

Keep status contained until the composed offline seam and all suites pass. Record exact test counts, launcher-lock hash, and the fact that no provider call occurred.

- [x] **Step 3: Run all five offline suites sequentially where result roots overlap**

Run the pilot suite, router suite, SQLite unit suite, calibration functional suite, and calibration security suite. Retain every continuation handle and require explicit exit code 0.

- [x] **Step 4: Run privacy and repository checks**

Run `git diff --check`, bounded forbidden-field scans, prompt/credential sentinel scans, and confirm no production profile or eligibility file changed.

- [x] **Step 5: Obtain spec and code-quality reviews**

Dispatch a spec-compliance reviewer, fix every gap, then dispatch a code-quality reviewer. Repeat review after any material fix.

- [x] **Step 6: Prepare but do not execute a new acceptance packet**

Record the new commit, manifest hash, launcher-lock hash, exact route order, proposed new RunId `option1-live-20260826-002`, and maximum three nonrefundable slots. Do not push, create a PR, merge, or execute the packet without explicit user approval.
