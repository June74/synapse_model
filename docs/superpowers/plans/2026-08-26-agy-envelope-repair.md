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

- [ ] **Step 1: Write launcher-lock schema and mismatch RED tests**

Define exact role and complete component identities. Test duplicate properties, wrong route/order, malformed hashes, missing files, changed bytes, shim-only locks, omitted Codex native entrypoints, and external override attempts. Assert mismatch returns `source_drift` before result slot claim and before candidate/judge invokers.

- [ ] **Step 2: Verify RED without executing launchers**

Use temporary fake executables and shims through injected resolution/start seams. Run the focused suites and confirm lock admission/prepared launch functions do not yet exist.

- [ ] **Step 3: Load and bind the reviewed lock**

Validate the checked-in lock with duplicate-key rejection and its schema, include both repository lock hashes in `plan.source_hashes`, and bind exact role and component order. The Codex chain includes its reviewed shim, Node host, JavaScript entrypoint, and platform-native executable; Claude includes its reviewed shim and native executable. Offline plan mode hashes only repository lock inputs and performs zero installed-launcher resolution.

- [ ] **Step 4: Prepare one immutable native launch**

Resolve the chain once, reject reparse components, verify every declared identity component from the same read handles, and hold those handles with write/delete sharing denied through the complete process lifetime. Build direct effective commands for Codex (`node.exe` plus the reviewed `codex.js`) and Claude (the reviewed native executable) so the verified shim cannot select a different branch. Pass the prepared command into `Invoke-NativeCandidate`; do not call `Resolve-RunnerNativeCommand` again.

- [ ] **Step 5: Preserve the non-refundable ordering**

The launch guard verifies the prepared identity before calling `New-CalibrationPilotSlotClaim`; the process starts only after the durable claim. Any identity mismatch stops with `source_drift`, zero slots, and zero processes.

- [ ] **Step 6: Verify matching and replacement-race GREEN cases**

Prove matching fake components preserve prepare/verify-before-claim-before-start order, that the same prepared object reaches the start seam, that a concurrent replacement attempt fails for the full fake-process lifetime, and that every handle is released afterward. Run all three PowerShell suites and commit with `fix: bind pilot launches to reviewed identities`.

### Task 4: Documentation, complete offline verification, and review

**Files:**
- Modify: `docs/operations/setbacks/incidents/2026-08-25T235222Z-option1-live-provider-envelope-invalid.md`
- Modify: `docs/operations/setbacks/INDEX.md`
- Modify: operator documentation identified by the existing Option 1 documentation tests

- [ ] **Step 1: Update the incident with correction evidence**

Keep status contained until the composed offline seam and all suites pass. Record exact test counts, launcher-lock hash, and the fact that no provider call occurred.

- [ ] **Step 2: Run all five offline suites sequentially where result roots overlap**

Run the pilot suite, router suite, SQLite unit suite, calibration functional suite, and calibration security suite. Retain every continuation handle and require explicit exit code 0.

- [ ] **Step 3: Run privacy and repository checks**

Run `git diff --check`, bounded forbidden-field scans, prompt/credential sentinel scans, and confirm no production profile or eligibility file changed.

- [ ] **Step 4: Obtain spec and code-quality reviews**

Dispatch a spec-compliance reviewer, fix every gap, then dispatch a code-quality reviewer. Repeat review after any material fix.

- [ ] **Step 5: Prepare but do not execute a new acceptance packet**

Record the new commit, manifest hash, launcher-lock hash, exact route order, proposed new RunId, and maximum three nonrefundable slots. Do not push, create a PR, merge, or execute the packet without explicit user approval.
