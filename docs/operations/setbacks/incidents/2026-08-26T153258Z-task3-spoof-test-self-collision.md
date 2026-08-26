# SB-20260826-153258-task3-spoof-test-self-collision: Control-code spoof test collided with its own RunId

- **Status:** closed
- **First observed:** 2026-08-26T15:32:58.107276Z
- **Last observed:** 2026-08-26T15:32:58.107276Z
- **Phase/task:** Task 3 launcher-identity specification review follow-up
- **Environment:** Windows PowerShell 7, isolated Option 1 worktree
- **Version/commit:** `0401d50` plus uncommitted Task 3 review fixes

## Symptom

The native control-code spoof privacy assertion matched the spoof string embedded by the test itself in RunId.

## Impact

The pilot suite exited 1 for a wrong-reason test failure; no production process, provider, network request, credential, prompt, or response was involved.

## Reproduction conditions

Use a spoof string as both the injected native exception and part of the execution RunId, then assert that serialized output does not contain the spoof string.

## Safe evidence

- The lower-case native spoof was correctly normalized after the trusted-boundary refactor.
- The serialized result still contained the spoof text only because the test placed it in `run_id`.

## Attempts and outcomes

1. Added exact lower-case, mixed-case, and claim-control native spoof cases.
2. The first post-fix run reached the privacy assertion and failed on its own RunId value.
3. Replaced spoof-derived RunIds with opaque case indexes; verification is pending.

## Cause classification

- **Confirmed cause:** The test constructed RunId from the same spoof string it later required to be absent from the serialized result.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** The failure did not show that the native exception escaped in a failure or diagnostic field; those fields were already normalized.
- **Known exclusions:** No real process, provider, network request, private payload, or credential was involved.

## Correction and prevention

- **Correction:** Use opaque per-case RunIds that do not contain the injected control strings.
- **Prevention:** Keep privacy sentinels out of expected serialized identity fields unless the test specifically validates those fields.
- **Owner:** Codex and project owner.
- **Next diagnostic step:** None.

## Verification and related work

The opaque-RunId lower-case, mixed-case, and claim-control native spoof cases passed; the full pilot suite exited 0.

## Recurrence history

- 2026-08-26T15:32:58.107276Z: First observed.
