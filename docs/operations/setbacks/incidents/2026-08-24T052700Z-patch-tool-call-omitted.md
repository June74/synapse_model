# SB-20260824-052700-patch-tool-call-omitted: Pricing patch text was not sent to the edit tool

- **Status:** closed
- **First observed:** 2026-08-24T05:27:00Z
- **Last observed:** 2026-08-24T05:27:00Z
- **Phase/task:** Task 8 actual-usage pricing GREEN implementation
- **Environment:** Codex desktop managed workspace
- **Version/commit:** `6b11d53` plus uncommitted Task 8 work

## Symptom

The orchestration cell constructed a patch string but completed without calling the file-edit tool.

## Impact

The pricing helper was not added by that attempt. No repository file, provider, database, credential, or external service changed.

## Reproduction conditions

Define patch text inside the orchestration wrapper without awaiting the patch tool.

## Safe evidence

The cell returned no patch result and `router/lib/pricing.ps1` remained unchanged.

## Attempts and outcomes

1. Prepared the production patch but omitted the edit-tool call; no mutation occurred.
2. Stopped before assuming the helper existed and recorded this incident.
3. Submitted the edit through the patch tool and reran the complete router suite successfully.

## Cause classification

- **Confirmed cause:** The wrapper omitted `tools.apply_patch(...)`.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** The patch was not rejected by the filesystem or parser because it was never submitted.
- **Known exclusions:** No partial product edit or private-data exposure occurred.

## Correction and prevention

- **Correction:** Submit the pricing edit explicitly through the patch tool and rerun the RED tests.
- **Prevention:** Require a patch-result object before treating any edit step as applied.
- **Owner:** Codex.
- **Next diagnostic step:** None; correction verified.

## Verification and related work

The pricing helper is present in `router/lib/pricing.ps1`, and the complete router suite exited 0 with both Task 8 actual-usage pricing tests passing.

## Recurrence history

- 2026-08-24T05:27:00Z: First observed and contained.
- 2026-08-24T05:36:00Z: Closed after patch application and full router-suite verification.
