# SB-20260824-012823-apply-patch-duplicate-target: Patch request repeated one target file in multiple update blocks

- **Status:** closed
- **First observed:** 2026-08-24T01:28:23.3772699Z
- **Last observed:** 2026-08-26T14:53:12Z
- **Phase/task:** Deterministic router V1 Task 6 RED-test authoring
- **Environment:** Windows PowerShell 7 in the deterministic-router-v1 worktree
- **Version/commit:** 10a2135

## Symptom

The patch tool rejected a test-first patch before applying it because the request contained multiple update operations for the same file.

## Impact

RED-test authoring was delayed. The patch was rejected atomically; no repository file, secret, provider, or external system was modified or accessed by the failed action.

## Reproduction conditions

Submitting one patch document that contains more than one `Update File` operation for the same absolute path reproduces the validation failure.

## Safe evidence

- The tool reported that multiple operations targeted `router/tests/router.tests.ps1`.
- A status check before the retry can distinguish the durable setback record from any Task 6 edits.

## Attempts and outcomes

1. Submitted three separate update blocks for the test file in one patch: rejected before application.
2. Consolidated all hunks for the test file under one update operation: applied successfully.

## Cause classification

- **Confirmed cause:** The patch request repeated the same target file across multiple update operations.
- **Hypotheses:** None.
- **Rejected hypotheses:** No patch-context mismatch occurred because validation rejected the patch structure first.
- **Known exclusions:** No partial Task 6 edit, provider call, model call, calibration run, push, PR, or merge occurred.

## Correction and prevention

- **Correction:** Submit one update operation per target file with all hunks consolidated.
- **Prevention:** Normalize patch requests by target path before calling the patch tool.
- **Owner:** Codex.
- **Next diagnostic step:** None.

## Verification and related work

The corrected consolidated patch applied successfully. `git diff --check` completed with no whitespace error; Git emitted only expected line-ending and inaccessible sandbox-user global-ignore warnings.

## Recurrence history

- 2026-08-26T14:53:12Z: Task 3 setback logging repeated `INDEX.md` in two update blocks. The patch was rejected atomically, and the corrected request consolidated both index changes into one update operation before continuing.
- 2026-08-25T19:55:35.3677309Z: Task 6 incident closure repeated `INDEX.md` in two update blocks. The patch was rejected atomically, all changes remained unapplied, and the retry consolidated both index hunks under one target operation before continuing.
- 2026-08-24T01:28:23.3772699Z: First observed and contained before any Task 6 file changed.
- 2026-08-24, Task 6 RED-test authoring: Closed after the consolidated patch applied and `git diff --check` verified the correction.
