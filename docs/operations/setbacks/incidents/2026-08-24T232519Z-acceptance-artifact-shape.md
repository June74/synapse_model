# SB-20260824-232519-acceptance-artifact-shape: Acceptance assertion expected response-only artifact fields

- **Status:** closed
- **First observed:** 2026-08-24T23:25:19.859408Z
- **Last observed:** 2026-08-25T23:19:52.9615185Z
- **Phase/task:** Task 9 final integrated verification
- **Environment:** Windows PowerShell 7, local deterministic-router-v1 worktree
- **Version/commit:** 3778210

## Symptom

The route-only acceptance command rejected a valid stored artifact because it required mode and status fields that are only present in the CLI response.

## Impact

Final verification paused; no provider calls, source changes, or data exposure occurred.

## Reproduction conditions

Run `calibration/run_calibration.ps1 -Route` with a bounded acceptance run ID, then require `mode` and `status` on both the command response and the stored `route-plan.json` artifact.

## Safe evidence

The command response reported route mode, 24 route entries, and zero provider calls. The stored artifact reported `calibration-route-plan/v1`, 24 route entries, and zero provider calls, but intentionally omitted response-only `mode` and `status` fields.

## Attempts and outcomes

- The first acceptance assertion required response-only fields in the stored artifact and failed after the artifact had been written.
- Inspecting the command response and stored artifact separately established their distinct contracts.
- A second bounded route-only run validated each contract at the correct boundary and removed both temporary acceptance directories.

## Cause classification

- **Confirmed cause:** The acceptance check conflated the CLI response contract with the persisted route-plan artifact contract.
- **Hypotheses:** The route-only implementation may have written a malformed artifact.
- **Rejected hypotheses:** The artifact was malformed; direct inspection confirmed its approved version, route count, and zero-call metadata.
- **Known exclusions:** No provider call, source defect, secret exposure, or artifact path escape occurred.

## Correction and prevention

- **Correction:** Validate `mode` on the CLI response and validate `artifact_version`, `provider_calls`, and route count on the persisted artifact.
- **Prevention:** Keep acceptance assertions aligned to the documented boundary being inspected instead of requiring response-only fields in stored files.
- **Owner:** Codex and project owner.
- **Next diagnostic step:** None; recurrence is closed.

## Verification and related work

Corrected acceptance run exited 0 with 24 route entries and zero provider calls in both the command response and stored artifact. Temporary acceptance artifacts were removed.

On recurrence, direct inspection of the public offline pilot plan confirmed `mode` is `pilot-plan`, `selection_mode` is `calibration_only_exact_pin`, all three roles are present, and `provider_calls` is zero. The results-tree snapshot comparison had already remained unchanged; only the verification command's guessed selection-mode value was wrong.

## Recurrence history

- 2026-08-24T23:25:19.859408Z: First observed.
- 2026-08-24T23:30:00Z: Root cause confirmed and corrected acceptance boundary passed; incident closed.
- 2026-08-25T23:19:52.9615185Z: Recurred when the final offline-pilot check guessed `option1_fixed_three_launch` instead of reading the public plan's frozen `calibration_only_exact_pin` value. No result write or product failure occurred.
