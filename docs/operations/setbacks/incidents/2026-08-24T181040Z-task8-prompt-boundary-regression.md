# SB-20260824-181040-task8-prompt-boundary-regression: Pilot prompt failure escaped the per-candidate boundary

- **Status:** closed
- **First observed:** 2026-08-24T18:10:40Z
- **Last observed:** 2026-08-24T18:14:34Z
- **Phase/task:** Task 8 selected-route execution specification follow-up
- **Environment:** Windows PowerShell 7, deterministic-router-v1 worktree
- **Version/commit:** `bcffe6e`

## Symptom

`Invoke-PilotRun` constructs each candidate prompt before entering the reusable single-candidate execution seam. If prompt construction throws, the whole run exits instead of recording one sanitized execution failure and continuing to later candidates.

## Impact

Legacy multi-candidate pilot behavior regressed during the Task 8 seam extraction. The explicit-prompt `Invoke-PilotCandidate` router seam is unaffected. No provider, API, credential, prompt, or runtime result was invoked or exposed during diagnosis.

## Reproduction conditions

Select two valid candidates in one `Invoke-PilotRun -RunAll` call and make prompt construction fail for the first candidate while allowing the second candidate to construct and execute offline.

## Safe evidence

In `pilot/lib/runner.ps1`, `New-PilotPrompt` is called directly in the `foreach` body before `Invoke-PilotCandidate`; no per-candidate catch surrounds that call.

## Attempts and outcomes

1. Confirmed the branch was clean at the accepted Task 8 commits.
2. Traced the current loop and compared it with the legacy per-candidate failure tests.
3. Ran the pilot baseline: 104 assertions passed and one privilege-only symlink test skipped.
4. The first RED harness had an invalid comma after `ConvertTo-Json -Compress`; it failed at parse time before tests ran, changed no product code, and was corrected before collecting RED evidence.
5. The corrected RED run passed 104 existing assertions and failed only because `Invoke-PilotRun` did not accept `PromptFactory`.
6. Added the optional prompt factory and restored a generic per-candidate failure record around prompt construction and seam invocation.
7. The GREEN pilot run passed 105 assertions with one privilege-only skip; router passed 349 assertions and all 53 Python storage tests passed.

## Cause classification

- **Confirmed cause:** Task 8 moved prompt construction outside the legacy per-candidate try boundary when `Invoke-PilotRun` began delegating execution to `Invoke-PilotCandidate`.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** `Invoke-PilotCandidate` does not need a prompt-construction responsibility; its explicit prompt is the required router seam.
- **Known exclusions:** No provider call, paid API, prompt content, credential, or Task 9 work is involved.

## Correction and prevention

- **Correction:** `Invoke-PilotRun` now defaults a narrowly injectable `PromptFactory` to `New-PilotPrompt`, catches prompt construction per candidate, appends a sanitized execution-failure record, and continues. `Invoke-PilotCandidate` remains an explicit-prompt seam.
- **Prevention:** Keep a two-candidate regression proving a first prompt-construction failure is appended and the second candidate still executes.
- **Owner:** Codex.
- **Next diagnostic step:** None; correction verified.

## Verification and related work

Pilot passed 105 assertions with one environment-only symbolic-link skip. The regression selected two candidates, made the first prompt factory fail, verified one sanitized failure record and JSONL row, verified the second candidate alone reached the fake invoker and succeeded, and confirmed neither prompt nor failure detail leaked. Router passed 349 assertions, Python storage passed 53 tests, both changed PowerShell files parsed with zero errors, `git diff --check` passed, and no temporary result remained.

## Recurrence history

- 2026-08-24T18:10:40Z: First observed and contained during Task 8 specification review.
- 2026-08-24T18:14:34Z: Closed after focused RED/GREEN restoration and full offline verification.
