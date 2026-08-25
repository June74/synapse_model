# SB-20260823-141012-convertfrom-json-object-type: ConvertFrom-Json scalar passed PSCustomObject accelerator test

- **Status:** closed
- **First observed:** 2026-08-23
- **Last observed:** 2026-08-23
- **Phase/task:** Deterministic router V1, Task 2 final simplification verification
- **Environment:** PowerShell 7.6.4, project-local deterministic-router worktree
- **Version or commit:** Uncommitted Task 2 simplification before `2c31fba76c58a0da669d86f5a7caae948511899f`
- **Symptom:** Tightening the schema root check with `$value.GetType() -eq [pscustomobject]` made every object schema return `schema_invalid|$`, while the new Boolean-root regression passed.
- **Impact:** One normal router verification run failed broadly before commit. No production, provider, or external state was changed.
- **Reproduction conditions:** Parse `{}` and `true` with `ConvertFrom-Json`, then compare their runtime types with the `[pscustomobject]` accelerator and their concrete CLR types.
- **Safe evidence:** Parsed `{}` has concrete type `System.Management.Automation.PSCustomObject`; parsed `true` has concrete type `System.Boolean`. The accelerator resolves to `System.Management.Automation.PSObject`, so direct type equality against it rejects the real object.
- **Confirmed cause:** The PowerShell `[pscustomobject]` accelerator is not the concrete CLR type emitted for JSON objects and is unsuitable for exact runtime-type equality.
- **Hypotheses:** None open.
- **Rejected hypotheses:** The checked-in schemas and `Test-Json` were unchanged and were not responsible for the structural failures.
- **Correction:** Compare parsed schema nodes with the concrete `System.Management.Automation.PSCustomObject` type. Root and nested Boolean schemas remain rejected at their exact schema paths.
- **Prevention:** Retain Boolean root/branch regressions and use concrete CLR types when an exact parsed-JSON shape boundary is required.
- **Owner:** Implementer
- **Next diagnostic step:** None.
- **Related verification:** Normal router suite passed in 7.384 seconds; strict mode with warnings as errors passed in 7.397 seconds; pilot and static verification also passed.

## Recurrence: 2026-08-23, final Task 2 narrowing inventory

- **Phase/task:** Task 2 checked-schema keyword inventory
- **Symptom:** The first recursive inventory reported no `minimum`, `minLength`, or `minItems` occurrences even though the response schema visibly contained them.
- **Impact:** The invalid inventory result was discarded before implementation; no router file, provider, or external state was changed.
- **Confirmed cause:** The probe repeated the exact-type comparison against the `[pscustomobject]` accelerator instead of the concrete `System.Management.Automation.PSCustomObject` type.
- **Correction:** Rerun the traversal with the concrete CLR type boundary and explicit script-scoped result collection.
- **Prevention:** Reuse the incident's concrete-type rule in ad hoc schema inventories as well as production schema parsing.
- **Related verification:** The corrected inventory found every checked-in occurrence and confirmed that `minLength` and `minItems` use only value `1`; it also located response `minimum` constraints beneath the discriminator-safe top-level `oneOf`.
