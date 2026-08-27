# SB-20260826-175555-adjudication-acceptance-phrase: Adjudication acceptance check used an overly specific phrase

- **Status:** closed
- **First observed:** 2026-08-26T17:55:55.3942857Z
- **Last observed:** 2026-08-27T03:23:40.9980693Z
- **Phase/task:** Calibration JSON repair documentation closure
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

## Recurrence history

- 2026-08-26T17:55:55.3942857Z: First observed when an acceptance wrapper required one invented prose substring instead of the document's equivalent wording.
- 2026-08-27T03:23:40.9980693Z: Recurred when the repair-closure probe required exact phrase `complete whitespace-trimmed response`, while the adjudication uses the semantically equivalent `complete whitespace-trimmed output`. The probe stopped before its remaining checks; no repository or live artifact changed.

## Recurrence: Calibration JSON repair documentation closure

- **Symptom:** A focused Markdown integrity probe returned exit code 1 before link validation because it compared one incidental noun literally.
- **Impact:** Documentation commit and final review paused; the already-passed offline suites, scope result, and immutable hash were unaffected.
- **Confirmed cause:** The probe again coupled acceptance to exact prose instead of stable headings, identifiers, state, and semantic markers.
- **Rejected hypothesis:** The closure did not omit the direct complete-value parsing rule; it uses equivalent approved wording with `output`.
- **Known exclusions:** No product code, provider, launcher, network, live calibration, result artifact, quality, eligibility, or routing state changed.
- **Correction:** Replace the literal sentence check with independent semantic checks for complete whitespace-trimmed parsing, direct JSON, fenced/prose rejection, closed incident state, suite evidence, and immutable hash.
- **Prevention:** Keep Markdown acceptance probes tied to stable structured facts rather than a single full prose phrase.
- **Owner:** Codex.
- **Next diagnostic step:** None after the corrected semantic probe passed.
- **Verification:** The corrected probe independently confirmed the complete-response rule, wrapper rejection, both implementation commits, all five suite counts, immutable result hash, closed date-coercion incident, and affected incident links. It exited 0, and `git diff --check` also exited 0.
