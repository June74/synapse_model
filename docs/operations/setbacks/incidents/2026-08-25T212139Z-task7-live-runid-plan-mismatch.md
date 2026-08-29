# SB-20260825-212139-task7-live-runid-plan-mismatch: Task 7 live RunId disagreed with frozen acceptance packet

- **Status:** closed
- **First observed:** 2026-08-25T21:21:39.286903Z
- **Last observed:** 2026-08-25T21:25:03.8356342Z
- **Phase/task:** Option 1 Task 7 operator documentation
- **Environment:** Windows PowerShell 7, isolated `codex/option1-calibration-pilot` worktree
- **Version/commit:** `5cf89dc`

## Symptom

The Task 7 documentation example named a different live RunId than the frozen acceptance contract and Task 9 packet.

## Impact

Copying the Task 7 example would document an unapproved live command shape. No live command, provider process, network request, or result write occurred.

## Reproduction conditions

Compare the Task 7 command in `docs/superpowers/plans/2026-08-25-option1-three-launch-calibration-pilot.md` with the plan's frozen safety boundary and Task 9 acceptance command.

## Safe evidence

- The frozen plan boundary names `option1-live-20260825-001` near the top of the plan.
- Task 7 names `option1-example-001`.
- Task 9 again names `option1-live-20260825-001` as the separately approved acceptance command.
- No command carrying `-Pilot -Run` was executed while diagnosing the mismatch.

## Attempts and outcomes

1. Searched the plan for both run IDs and confirmed the inconsistency.
2. Selected the frozen acceptance RunId because it is repeated in the safety boundary and Task 9, while the Task 7 value appears only in the mismatched example.

## Cause classification

- **Confirmed cause:** Task 7 retained a stale example RunId after the live acceptance packet was frozen under `option1-live-20260825-001`.
- **Hypotheses:** None remain.
- **Rejected hypotheses:** The executable live contract was not ambiguous; the plan's safety boundary and Task 9 agree on the exact accepted RunId.
- **Known exclusions:** No production code defect, provider invocation, credential access, result write, or quota use occurred.

## Correction and prevention

- **Correction:** Document only the accepted `option1-live-20260825-001` command.
- **Prevention:** Add a documentation contract assertion for the entire exact live command so future RunId drift fails the offline calibration suite.
- **Owner:** Codex
- **Next diagnostic step:** None unless the frozen acceptance RunId changes through a newly approved packet.

## Verification and related work

- `pwsh -NoProfile -File .\calibration\tests\calibration.tests.ps1` passed, including the exact-command documentation contract.
- The offline `-Pilot` command exited successfully with one JSON plan, `provider_calls: 0`, three ordered roles, and an unchanged `calibration/results` tree.
- The live `-Pilot -Run` command was not executed.

## Recurrence history

- 2026-08-25T21:21:39.286903Z: First observed.
- 2026-08-25T21:25:03.8356342Z: Closed after the exact-command contract and zero-write offline verification passed.
