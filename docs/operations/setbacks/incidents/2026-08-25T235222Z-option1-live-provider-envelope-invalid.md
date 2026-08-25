# SB-20260825-235222-option1-live-provider-envelope-invalid: Option 1 live candidate returned an invalid provider envelope

- **Status:** contained
- **First observed:** 2026-08-25T23:52:22.2693656Z
- **Last observed:** 2026-08-25T23:55:02.5686300Z
- **Phase/task:** Task 9 approved live acceptance
- **Environment:** Windows PowerShell, isolated Option 1 worktree
- **Version/commit:** `98df9e955e51654c5e927229753901a585715e33`

## Symptom

The one approved live command consumed and started the Google candidate slot, then stopped with the bounded code `provider_envelope_invalid`. Both judge roles were skipped.

## Impact

The complete three-launch live path was not accepted. One nonrefundable Google launcher slot was consumed; no OpenAI or Anthropic judge slot was consumed. The command was not retried, the RunId cannot be reused, and production quality remains unchanged.

## Reproduction conditions

Run the exact approved command once from the clean approved commit with RunId `option1-live-20260825-001`.

## Safe evidence

- Terminal state: `stopped`.
- Stop reason: `provider_envelope_invalid`.
- Claims: one exact Google candidate claim.
- Launcher processes started: one Google process; zero OpenAI and zero Anthropic processes.
- Attempts: candidate `failed`; both judges `skipped`.
- No raw response artifact was written.
- Bounded scans found zero prompt-text occurrences, zero forbidden properties, and zero recognizable secret patterns.
- No `agy` process was visible after the run. The invalid envelope prevented trustworthy `process_exited` and cleanup facts from being retained, so cleanup cannot be claimed from the artifact alone.
- Provider-internal request count remains unobservable.

## Attempts and outcomes

1. Revalidated the exact commit, plan hash, manifest hash, ordered identities, clean worktree, and absent RunId directory; preflight passed.
2. Executed the approved live command once; it stopped safely after the candidate slot.
3. Inspected only bounded artifact structure, hashes, claims, terminal state, privacy fields, and visible process names; containment checks passed.
4. Did not retry, substitute a provider, resume, or create another RunId.
5. A final inspection report mislabeled the manifest hash as the execution commit. Reading `plan.json.git_commit` corrected the report and confirmed the approved execution commit exactly; no runtime artifact changed.

## Cause classification

- **Confirmed cause:** The strict pilot execution-envelope boundary rejected the normalized candidate result. The bounded artifact does not identify which envelope field was invalid.
- **Hypotheses:** A live-only mismatch exists between the Agy adapter result shape and the strict calibration execution-envelope contract.
- **Rejected hypotheses:** None; authentication, quota, response parsing, and cleanup-specific explanations are not distinguishable from the bounded artifact.
- **Known exclusions:** No retry, fallback, judge launch, production profile mutation, eligibility change, raw prompt persistence, raw provider-output persistence, or credential persistence occurred.

## Correction and prevention

- **Correction:** Contained the run at its terminal stopped state and prohibited reuse or retry of the approved RunId.
- **Prevention:** Before any new live packet, reproduce the adapter/envelope boundary offline with safe fixtures and add bounded field-level diagnostic coverage that does not persist raw provider data.
- **Owner:** Codex.
- **Next diagnostic step:** Trace the Agy live adapter result into the strict execution-envelope validator using offline fixtures; any correction requires a new reviewed commit, new RunId, revised acceptance packet, and new explicit approval.

## Verification and related work

The run directory contains only `.run.claim`, the exact candidate claim, `plan.json`, and `result.json`. Privacy scans passed, no `agy` process remained visible, tracked files were unchanged before incident logging, and all quality-promotion flags remain false.

## Recurrence history

- 2026-08-25T23:52:22.2693656Z: First live occurrence; contained without retry.
- 2026-08-25T23:55:02.5686300Z: Corrected a read-only verification label and reconfirmed the exact approved commit from the immutable plan.
