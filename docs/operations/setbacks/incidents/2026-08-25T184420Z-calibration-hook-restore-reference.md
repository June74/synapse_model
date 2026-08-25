# SB-20260825-184420-calibration-hook-restore-reference: Calibration hook restoration retained a live function reference

- **Status:** closed
- **First observed:** 2026-08-25T18:44:20.845597Z
- **Last observed:** 2026-08-25T18:56:55Z
- **Phase/task:** Task 4 quality review verification
- **Environment:** Windows PowerShell, Codex desktop managed workspace
- **Version/commit:** `835f00f`

## Symptom

A security test restored a mutated hook definition and contaminated later assertions.

## Impact

The first security GREEN run was invalidated and verification paused; no provider or private data was involved.

## Reproduction conditions

Override an internal no-op hook with `Set-Item Function:` after retaining the live `FunctionInfo` object, then restore through that object's current `ScriptBlock` property.

## Safe evidence

- The initialization-fault assertion passed, but the next ten ledger assertions failed during run setup with the same bounded initialization code.
- A clean PowerShell process reproduced normal setup after changing the fixture to retain the immutable scriptblock value.

## Attempts and outcomes

1. Stored the function metadata object, replaced the hook, and restored through the metadata object; later assertions inherited the faulting hook.
2. Stored `.ScriptBlock` before replacement and restored that value directly; all 22 security assertions passed.
3. The open-seam regression repeated the live-metadata mistake; it was corrected to snapshot `.ScriptBlock` before replacement.
4. The first safe exception-chain probe attempted unsigned formatting of a negative HRESULT and failed before producing evidence; the corrected probe retained signed numeric codes and changed no repository state.

## Cause classification

- **Confirmed cause:** PowerShell's retained `FunctionInfo` reflected the replaced function definition, so reading its `ScriptBlock` during cleanup returned the faulting hook instead of the original no-op hook.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** Product initialization remained broken after the injected fault. A fresh process with immutable hook restoration passed every later initialization path.
- **Known exclusions:** No provider, network, credential, prompt content, or external artifact was involved.

## Correction and prevention

- **Correction:** Snapshot the original `.ScriptBlock` value before replacing each internal hook and restore that immutable value in `finally`.
- **Prevention:** Hook-based tests must retain scriptblock values, not live function metadata objects, and must prove later assertions run after restoration.
- **Owner:** Codex.
- **Next diagnostic step:** None.

## Verification and related work

`pwsh -NoProfile -File calibration/tests/calibration_security.tests.ps1` completed with exit code 0 and 22 passing assertions after both corrections. The functional suite then completed with exit code 0 and 43 passing assertions.

## Recurrence history

- 2026-08-25T18:44:20.845597Z: First observed.
- 2026-08-25T18:56:00Z: The same live `FunctionInfo` restoration mistake recurred in the new CreateNew open-seam regression, contaminating later initialization assertions. Verification stopped for correction and rerun.
- 2026-08-25T18:56:55Z: The immutable scriptblock restoration passed the complete security and functional suites; incident closed.
