# SB-20260825-235222-option1-live-provider-envelope-invalid: Option 1 live candidate returned an invalid provider envelope

- **Status:** contained
- **First observed:** 2026-08-25T23:52:22.2693656Z
- **Last observed:** 2026-08-26T05:00:45.1845601Z
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
6. Composed the real Agy adapter with a fully native-shaped offline success fixture and the strict calibration validator. The ordered success fixture passed, proving the normal process and usage telemetry shapes are compatible.
7. Reproduced two adapter/envelope contract mismatches without a provider call: a successful canonical response with reordered keys is accepted by the adapter but rejected by the envelope; a provider-declared canonical failure is accepted by the adapter, which also emits failure metadata that the envelope rejects as contradictory.
8. Reproduced ordinary parse failure and nonzero exit with complete native telemetry. Both produced valid execution envelopes and retained process evidence, unlike the live result.
9. Inspected the installed launcher without executing it. `agy.exe` was replaced during the live run window, and the prior binary remains beside it with an `.old` suffix; the two binaries have different sizes and SHA-256 hashes.

## Cause classification

- **Confirmed cause:** The Agy adapter and strict calibration envelope implement inconsistent canonical-response contracts. Offline reproduction proves that the adapter accepts at least two shapes the envelope rejects: reordered canonical keys, and provider-declared failure accompanied by the adapter's normalized failure metadata. The bounded live artifact intentionally does not retain enough canonical detail to distinguish which of those two variants occurred.
- **Confirmed contributing condition:** The installed Agy launcher was replaced during the live run window. The current binary was written at `2026-08-25T23:52:18.6808422Z`; the run began at `2026-08-25T23:52:12.9023258Z` and recorded process start at `2026-08-25T23:52:21.7927377Z`. The current and retained prior binaries have different sizes and hashes, so the live launcher identity was not stable across the acceptance boundary.
- **Hypotheses:** The exact live trigger was either canonical property reordering or provider-declared failure metadata. Launcher replacement may have changed serialization or failure behavior relative to the repository fixture, but binary metadata alone does not prove which behavior changed.
- **Rejected hypotheses:** An ordinary parse failure or normal nonzero-exit path cannot explain the missing bounded process evidence under the current code: offline reproductions classify those as valid envelopes and preserve process telemetry. The fully native-shaped ordered Agy success fixture also passes, rejecting a general incompatibility in normal process or usage telemetry.
- **Known exclusions:** No retry, fallback, judge launch, production profile mutation, eligibility change, raw prompt persistence, raw provider-output persistence, or credential persistence occurred.

## Correction and prevention

- **Correction:** Contained the run at its terminal stopped state and prohibited reuse or retry of the approved RunId.
- **Prevention:** Before any new live packet, define one canonical response contract shared by the adapter and envelope, cover property-order and provider-declared-failure cases in the composed offline seam, and pin or preflight the launcher binary identity. Add bounded rejection-reason diagnostics that record only a safe field/category code, never raw provider data.
- **Owner:** Codex.
- **Next diagnostic step:** Choose and implement the shared canonical-response semantics, then verify the composed Agy-adapter-to-envelope seam offline. Any correction still requires a new reviewed commit, new RunId, revised acceptance packet, and new explicit approval before another provider call.

## Verification and related work

The run directory contains only `.run.claim`, the exact candidate claim, `plan.json`, and `result.json`. Privacy scans passed, no `agy` process remained visible, tracked files were unchanged before incident logging, and all quality-promotion flags remain false.

## Recurrence history

- 2026-08-25T23:52:22.2693656Z: First live occurrence; contained without retry.
- 2026-08-25T23:55:02.5686300Z: Corrected a read-only verification label and reconfirmed the exact approved commit from the immutable plan.
- 2026-08-26T00:04:04.9658578Z: Offline composition tests confirmed the adapter/envelope contract inconsistency and rejected ordinary parse/nonzero-exit explanations; read-only launcher metadata confirmed replacement during the live run window.
- 2026-08-26T04:55:07.0323082Z: Follow-up spec review found that the repaired exact-three gate and validator still used PowerShell's case-insensitive membership operators, allowing `Status`, `Answer`, or `Error` variants to satisfy the canonical shape. Focused RED returned exit code 1 at the validator assertion, while the adapter preservation assertion unexpectedly passed because the shared sequence helper also compares strings case-insensitively. The test issue was contained by requiring ordinal property-name comparisons in this regression before production changes. A subsequent bounded incident search included one unsupported wildcard path argument; it changed no files and printed no sensitive values. No launcher, provider, network, live calibration, or consumed RunId was used.
- 2026-08-26T05:00:45.1845601Z: The corrected RED failed only the adapter preservation and validator rejection assertions. Case-sensitive exact-property membership then made all three offline suites GREEN: pilot 120 assertions with one privilege-only skip, calibration functional 52 assertions, and calibration security 39 assertions, all at exit code 0. Exact lowercase reordered names remain accepted, while `Status`, `Answer`, and `Error` variants remain unnormalized and are rejected. The incident remains contained pending the broader repair tasks and a separately authorized future acceptance packet.
