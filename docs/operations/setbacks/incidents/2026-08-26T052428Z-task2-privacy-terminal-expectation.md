# SB-20260826-052428-task2-privacy-terminal-expectation: Task 2 privacy fixture expected the wrong terminal state

- **Status:** closed
- **First observed:** 2026-08-26T05:24:28.365954Z
- **Last observed:** 2026-08-26T05:32:37.2947530Z
- **Phase/task:** Agy envelope repair Task 2 RED verification
- **Environment:** Windows PowerShell 7, isolated option1-calibration-pilot worktree
- **Version/commit:** `2d791045de95094839a86c57b8617c7d88322d46` plus uncommitted Task 2 RED tests

## Symptom

The new execution-shape privacy case expected stopped, but the existing start-state rules correctly returned indeterminate after the process record was removed.

## Impact

The security RED run failed for one additional fixture-expectation reason. No production code, provider, network, credential, or live calibration path was touched.

## Reproduction conditions

Run the new malformed-input privacy integration table with the execution-shape case removing the process record while leaving `process_started = true`.

## Safe evidence

- Functional RED exited 1 with the four expected missing-diagnostics contract failures.
- Security RED exited 1 with the expected missing persisted category and one additional terminal-state mismatch.
- The mismatch reported actual `indeterminate` against expected `stopped`; no sentinel appeared in test output.

## Attempts and outcomes

1. Inspected the validator's start-state calculation. A declared start without a process record is intentionally indeterminate.
2. Changed the privacy case to expect `indeterminate` only for execution-shape removal; the other malformed cases continue to expect `stopped`.
3. The setback helper initially wrote its index fields in the wrong order for this repository's existing table. Corrected the row manually before continuing.
4. The first GREEN functional run then failed six envelope paths with `pilot_execution_envelope_result_invalid`. A focused PowerShell reproduction confirmed an omitted typed string parameter has length zero but is not null.
5. Normalize empty optional helper parameters to null before enforcing the valid-envelope invariant.
6. The first security GREEN run reached the privacy regression but its compact JSON substring assertion failed because durable result JSON includes formatting whitespace. Keep the raw sentinel scan and verify the parsed allowlisted field instead.

## Cause classification

- **Confirmed cause:** Two contained issues occurred: the privacy test assumed every malformed envelope with a reserved slot is a determinate stop, and the production result helper treated PowerShell's empty default for an omitted typed string as a populated rejection code.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** The production start-state classification did not regress; the mismatch came from the new test expectation.
- **Known exclusions:** No production code, provider launcher, network, live calibration, credential, or raw private value was involved.

## Correction and prevention

- **Correction:** Encode the expected terminal state per privacy case, normalize omitted optional helper strings to null, and verify durable categories through parsed JSON while retaining raw sentinel scans.
- **Prevention:** When envelope mutations affect process-start evidence, derive the terminal expectation from the explicit start-state contract rather than applying one shared expectation. Assert structured JSON fields independently from raw privacy scans.
- **Owner:** Codex and project owner.
- **Next diagnostic step:** None.

## Verification and related work

The complete functional calibration suite passed 54 assertions with exit code 0. The complete calibration security suite passed 40 assertions with exit code 0. Both runs were offline and used only injected fixtures; no launcher, provider, network, or live calibration path ran.

## Recurrence history

- 2026-08-26T05:24:28.365954Z: First observed.
- 2026-08-26T05:27:09.7056310Z: First GREEN run exposed the optional-string normalization issue; no live path ran.
- 2026-08-26T05:30:08.7153399Z: First security GREEN run exposed a brittle compact-JSON test assertion; production behavior and privacy remained contained.
- 2026-08-26T05:32:37.2947530Z: Functional and security GREEN suites completed with exit code 0; incident closed.
