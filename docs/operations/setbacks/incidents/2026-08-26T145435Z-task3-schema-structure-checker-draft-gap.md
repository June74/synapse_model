# SB-20260826-145435-task3-schema-structure-checker-draft-gap: Router schema checker rejected valid launcher schema keywords

- **Status:** closed
- **First observed:** 2026-08-26T14:54:35Z
- **Last observed:** 2026-08-26T14:54:35Z
- **Phase/task:** Agy envelope repair, Task 3 launcher identity implementation
- **Environment:** Windows PowerShell, isolated option1 calibration worktree
- **Version/commit:** `f9fea99` plus uncommitted Task 3 TDD changes

## Symptom

After correcting the launcher source-path map, the offline pilot still stopped with `pilot_launcher_lock_invalid`. Focused diagnostics showed that PowerShell `Test-Json` accepted the lock against the schema, while the router's narrower structural checker rejected `$defs`, `prefixItems`, `items: false`, and array cardinality keywords.

## Impact

Launcher-lock admission remained fail closed and the offline plan did not render. No launcher, provider, network request, credential, or live calibration operation ran.

## Reproduction conditions

Pass the draft 2020-12 launcher schema with exact positional array constraints to `Get-RouterSchemaStructureErrors`.

## Safe evidence

- `Test-Json` returned true for the checked-in lock and schema.
- The structural checker returned only schema-keyword errors for the draft features used by the exact lock schema.
- No installed launcher resolution or execution was reached.

## Attempts and outcomes

1. Corrected the canonical source map: validation advanced into launcher-lock admission.
2. Compared both schema validators: the general JSON Schema validator accepted the documents, while the router-specific structure checker rejected unsupported vocabulary.

## Cause classification

- **Confirmed cause:** `Get-RouterSchemaStructureErrors` implements the router schema subset and is not a general draft 2020-12 schema validator.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** The checked-in launcher lock does satisfy the JSON Schema used by `Test-Json`.
- **Known exclusions:** No provider, launcher process, local model, network call, or live calibration ran.

## Correction and prevention

- **Correction:** For the launcher-lock schema, require a parsed object plus strict duplicate-key rejection and `Test-Json` validation; retain manual exact manifest/component binding.
- **Prevention:** Do not apply router-domain schema-subset validation to general repository artifact schemas without first confirming vocabulary support.
- **Owner:** Codex.
- **Next diagnostic step:** Rerun the offline pilot plan after the validator correction.

## Verification and related work

After the router-specific structural check was removed from this general artifact boundary, admission advanced past `Test-Json` into manual component binding. After the independent tuple-shape correction, the exact offline pilot plan completed with exit code 0.
