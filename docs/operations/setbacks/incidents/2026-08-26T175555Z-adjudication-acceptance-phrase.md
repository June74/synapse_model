# SB-20260826-175555-adjudication-acceptance-phrase: Adjudication acceptance check used an overly specific phrase

- **Status:** closed
- **First observed:** 2026-08-26T17:55:55.3942857Z
- **Last observed:** 2026-08-26T17:55:55.3942857Z
- **Phase/task:** Offline JSON-rubric adjudication deliverable acceptance
- **Environment:** Windows PowerShell, isolated option1-calibration-pilot worktree
- **Version/commit:** `1725b4b`

## Symptom and impact

The first acceptance wrapper searched for the exact substring `low/general live prompt`, while the correct incident text says `low/general Option 1 live prompt`. The wrapper rejected the document before completing its remaining checks. No document defect, source mutation, live-artifact mutation, provider call, launcher, or network request occurred.

## Cause classification

- **Confirmed cause:** The wrapper coupled acceptance to one invented prose phrase instead of checking the incident's structured status and the actual unaffected-scope statement independently.
- **Rejected hypothesis:** The incident did not omit the required scope statement; direct inspection showed the correct, more specific wording.
- **Known exclusions:** Product code, calibration results, quality state, and external systems were unaffected.

## Correction and prevention

- **Correction:** Check `Status: contained`, the exact selected prompt identifier, and the explicit statement that the completed Option 1 live run was unaffected as separate semantic markers.
- **Prevention:** Acceptance checks for Markdown reports should validate stable headings, identifiers, and metadata rather than incidental prose fragments.
- **Owner:** Codex.
- **Next diagnostic step:** None after the corrected acceptance check passes.
- **Verification:** The corrected check must confirm the adjudication report, contained incident, clean worktree after commit, and unchanged immutable result hash.
