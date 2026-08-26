# SB-2026-08-19-006: Git index unavailable to sandbox

- **Status:** contained
- **First observed:** 2026-08-19
- **Last observed:** 2026-08-26T15:55:50.4240433Z
- **Symptom:** A scoped `git add`/`git commit` for the design specification failed because Git could not create `C:\Users\2006i\projects\router_model\.git\index.lock` due to permission denial.
- **Confirmed:** The design file was written successfully; no commit was created and no existing files were overwritten.
- **Correction:** Leave the specification uncommitted in the shared workspace. If a commit is desired, run the Git command from the user's personal terminal where the repository permissions are available.
- **Impact:** Planning is paused at the design-review gate; implementation files have not been created.

## Recurrence: 2026-08-20

- **Phase/task:** Provider response-handling implementation, test commit.
- **Symptom:** A scoped `git add -- pilot/tests/runner.tests.ps1` and commit could not create the worktree index lock; the command returned permission denied.
- **Confirmed cause:** Git could not create `C:\Users\2006i\projects\router_model\.git\worktrees\subscription-runner\index.lock` from this sandbox. A read-only check confirmed that no stale lock file exists.
- **Impact:** The implementation commit is present; only the new test changes remain uncommitted.
- **Correction:** Preserve the test changes and leave the commit for the user's personal terminal or a separately approved Git operation.
- **Verification:** `git diff --check` passed; the full offline runner test suite passed with exit code 0 before the commit attempt.

## Recurrence: 2026-08-22

- **Phase/task:** Deterministic router V1 worktree setup.
- **Symptom:** `git worktree add` could not create `refs/heads/codex/deterministic-router-v1` from the managed sandbox.
- **Confirmed cause:** The repository metadata is readable but the managed filesystem profile does not permit creating the branch reference under `.git`.
- **Impact:** No branch or worktree was created; the existing `main` checkout and its two untracked planning documents were unchanged.
- **Correction:** Retry the same bounded `git worktree add` operation with explicit repository-metadata write approval.
- **Prevention:** Treat branch, worktree, index, and commit operations as requiring approved Git-metadata access in this workspace.
- **Verification:** The approved retry created the isolated `codex/deterministic-router-v1` worktree at the intended ignored path.

## Recurrence: 2026-08-23

- **Phase/task:** Deterministic router V1 Task 3, profile-catalog commit.
- **Symptom:** The scoped Task 3 `git add` and commit could not create `.git/worktrees/deterministic-router-v1/index.lock`; Git returned permission denied.
- **Confirmed cause:** The implementation worktree is writable, but its Git index metadata resides under the parent repository `.git` directory, outside the managed write boundary.
- **Impact:** Task 3 files remain intact and tested; nothing was staged and no commit was created by the failed command.
- **Correction:** Retry only the bounded staging and commit commands with explicit Git-metadata write approval.
- **Prevention:** Continue treating index and commit operations in this worktree as requiring approved Git-metadata access.
- **Verification:** The approved retry committed Task 3 as `e3c00ea` and the recurrence record as `2b9cf3f`; `git status --short --branch` then showed a clean worktree. Pre-commit router and pilot suites both completed with exit code 0.

## Recurrence: 2026-08-23, Task 4 setback records

- **Phase/task:** Deterministic router V1 Task 4, setback documentation commit.
- **Symptom:** Scoped staging and commit could not create `.git/worktrees/deterministic-router-v1/index.lock`; Git returned permission denied.
- **Confirmed cause:** The worktree files are writable, but the worktree Git index is stored under the parent repository `.git` metadata outside the managed write boundary.
- **Impact:** The Task 4 implementation commits remain intact; only verified setback documentation is uncommitted.
- **Correction:** Retry the same bounded Git staging and commit operation through approved Git-metadata access.
- **Prevention:** Treat all worktree index and commit operations as requiring approved Git-metadata access in this repository.
- **Related verification:** Documentation passed `git diff --check`; no product code changed during the failed commit attempt.

## Recurrence: 2026-08-23, Task 4 code-quality review

- **Phase/task:** Deterministic router V1 Task 4, fixture-path setback documentation commit.
- **Symptom:** Scoped staging and commit could not create `.git/worktrees/deterministic-router-v1/index.lock`; Git returned permission denied.
- **Confirmed cause:** The worktree files are writable, but its Git index metadata remains outside the managed write boundary under the parent repository `.git` directory.
- **Impact:** The closed fixture-path incident remains intact and unstaged; no product code changed and no commit was created.
- **Correction:** Retry only the bounded documentation staging and commit commands through approved Git-metadata access.
- **Prevention:** Continue treating worktree index and commit operations as requiring approved Git-metadata access in this repository.
- **Related verification:** The corrected fixture load succeeded and the documentation passed `git diff --check` before this commit attempt.

## Recurrence: 2026-08-23, Task 6 inspection records

- **Phase/task:** Deterministic router V1 Task 6 pre-implementation setback documentation.
- **Symptom:** Scoped staging and commit could not create `.git/worktrees/deterministic-router-v1/index.lock`; Git returned permission denied.
- **Confirmed cause:** Worktree Git metadata remains outside the managed write boundary under the parent repository `.git` directory.
- **Impact:** The safe documentation edits remain intact; no product code or external state changed.
- **Correction:** Retry only the bounded documentation staging and commit through approved Git-metadata access.
- **Prevention:** Continue treating main-agent worktree index and commit operations as requiring approved Git-metadata access.
- **Related verification:** Corrected source and profile inspections completed successfully before the commit retry.

## Recurrence: 2026-08-24, Task 6 implementation commits

- **Phase/task:** Deterministic router V1 Task 6, documentation and feature commits.
- **Symptom:** Scoped documentation staging could not create `.git/worktrees/deterministic-router-v1/index.lock`; Git returned permission denied.
- **Confirmed cause:** Worktree Git metadata remains outside the managed write boundary under the parent repository `.git` directory.
- **Impact:** No file was staged and no commit was created. The Task 6 implementation, tests, fixture, and setback records remain intact in the worktree.
- **Correction:** Retry only the bounded documentation and Task 6 staging/commit commands through approved Git-metadata access.
- **Prevention:** Continue treating worktree index and commit operations as requiring approved Git-metadata access.
- **Related verification:** The corrected patch structure passed `git diff --check`; the latest full router suite passed before the staging attempt. A fresh final suite remains required after the last conservative pricing guard.

## Recurrence: 2026-08-24, Task 7 preflight documentation

- **Phase/task:** Deterministic router V1 Task 7, preflight setback documentation commit.
- **Symptom:** Scoped staging and commit could not create `.git/worktrees/deterministic-router-v1/index.lock`; Git returned permission denied.
- **Confirmed cause:** The worktree is writable, but its Git index metadata remains under the parent repository `.git` directory outside the managed write boundary.
- **Impact:** No file was staged and no commit was created. The verified documentation edits remain intact; Task 7 product files have not been changed.
- **Correction:** Retry only the bounded documentation staging and commit through approved Git-metadata access.
- **Prevention:** Treat all Task 7 staging and commit operations as requiring approved Git-metadata access.
- **Related verification:** The documentation passed `git diff --check` before the failed staging attempt.

## Recurrence: 2026-08-24, Task 7 review-fix documentation

- **Phase/task:** Deterministic router V1 Task 7 review fixes, durability setback record commit.
- **Symptom:** Scoped staging and commit could not create `.git/worktrees/deterministic-router-v1/index.lock`; Git returned permission denied.
- **Confirmed cause:** The worktree remains writable while its shared Git metadata is outside the managed write boundary.
- **Impact:** No file was staged and no commit was created. The RED tests and documentation edits remain intact; implementation has not started.
- **Correction:** Retry only the bounded documentation staging and commit through approved Git-metadata access.
- **Prevention:** Continue treating this worktree's staging and commit operations as requiring approved Git-metadata access.
- **Related verification:** The 29-test RED run produced 14 targeted failures before this staging attempt.

## Recurrence: 2026-08-24, Task 9 review fixes

- **Phase/task:** Deterministic router V1 Task 9 calibration review fixes, final commit.
- **Symptom:** Scoped staging of the three calibration implementation/test files could not create `.git/worktrees/deterministic-router-v1/index.lock`; Git returned permission denied.
- **Confirmed cause:** The worktree remains writable while its shared Git index metadata is outside the managed write boundary.
- **Impact:** No file was staged and no commit was created by the failed command; the verified calibration changes remain intact.
- **Correction:** Retry only the bounded staging and commit operations through approved Git-metadata access.
- **Prevention:** Continue treating this worktree's staging and commit operations as requiring approved Git-metadata access.
- **Related verification:** Calibration, pilot runner, and router offline suites all exited 0 before the staging attempt; `git diff --check` also passed.

## Recurrence: 2026-08-24, Task 9 final acceptance record

- **Phase/task:** Deterministic router V1 Task 9, final acceptance setback documentation commit.
- **Symptom:** Scoped staging and commit of the acceptance incident could not create `.git/worktrees/deterministic-router-v1/index.lock`; Git returned permission denied.
- **Confirmed cause:** The worktree remains writable while its shared Git index metadata is outside the managed write boundary.
- **Impact:** No file was staged and no commit was created. Product code and verified acceptance results are unchanged.
- **Correction:** Retry only the bounded documentation staging and commit through approved Git-metadata access.
- **Prevention:** Continue treating this worktree's staging and commit operations as requiring approved Git-metadata access.
- **Related verification:** Corrected route-only acceptance exited 0 with 24 routes and zero provider calls; both temporary acceptance directories were removed.

## Recurrence: 2026-08-25, Option 1 implementation plan

- **Phase/task:** Option 1 three-launch calibration pilot implementation planning commit.
- **Symptom:** Scoped staging of the verified plan and setback records could not create `.git/worktrees/option1-calibration-pilot/index.lock`; Git returned permission denied.
- **Confirmed cause:** The isolated worktree is writable, while its Git index metadata is stored under the parent repository `.git` directory outside the managed write boundary.
- **Impact:** No file was staged and no commit was created. The verified plan and closed setback records remain intact; no implementation or provider execution occurred.
- **Correction:** Retry only the bounded staging and planning commit with approved Git-metadata access.
- **Prevention:** Treat this worktree's staging and commit operations as requiring approved Git-metadata access.
- **Related verification:** The plan contract check reported 9 tasks and 48 checkbox steps; the narrowed marker scan and `git diff --check` passed before staging.

## Recurrence: 2026-08-25, Option 1 Task 5 commits

- **Phase/task:** Option 1 three-launch calibration pilot Task 5, setback and feature commits.
- **Symptom:** Scoped staging could not create `.git/worktrees/option1-calibration-pilot/index.lock`; Git returned permission denied.
- **Confirmed cause:** The isolated worktree files are writable, while its Git index metadata remains under the parent repository `.git` directory outside the managed write boundary.
- **Impact:** No file was staged and no commit was created by the failed command. The verified Task 5 code, tests, and closed setback records remain intact; no provider or native launcher ran.
- **Correction:** Retry only the bounded documentation and product staging/commit commands through approved Git-metadata access.
- **Prevention:** Continue treating this worktree's staging and commit operations as requiring approved Git-metadata access.
- **Related verification:** The functional suite completed with every assertion passing, the adjacent security suite completed with 22/22 passing assertions, and `git diff --check` passed before staging.

## Recurrence: 2026-08-25, Option 1 Task 6 commits

- **Phase/task:** Option 1 three-launch calibration pilot Task 6, setback and product commits.
- **Symptom:** Scoped staging could not create `.git/worktrees/option1-calibration-pilot/index.lock`; Git returned permission denied.
- **Confirmed cause:** The isolated worktree files are writable, while its Git index metadata remains under the parent repository `.git` directory outside the managed write boundary.
- **Impact:** No file was staged and no commit was created by the failed command. The verified Task 6 implementation, tests, and closed setback records remain intact; no provider, native launcher, network, API, local model, or live CLI ran.
- **Correction:** Retry only the bounded documentation and product staging/commit commands through approved Git-metadata access.
- **Prevention:** Continue treating this worktree's staging and commit operations as requiring approved Git-metadata access.
- **Related verification:** The functional suite passed 47/47 assertions, the security suite passed 28/28 assertions, `git diff --check` passed, and `calibration/results` contained only `.gitkeep` before staging.

## Recurrence: 2026-08-25, Option 1 Task 7 commits

- **Phase/task:** Option 1 three-launch calibration pilot Task 7, operator documentation and setback commits.
- **Symptom:** Scoped staging could not create `.git/worktrees/option1-calibration-pilot/index.lock`; Git returned permission denied.
- **Confirmed cause:** The isolated worktree files are writable, while its Git index metadata remains under the parent repository `.git` directory outside the managed write boundary.
- **Impact:** No file was staged and no commit was created by the failed command. The verified README, documentation contract, and closed setback records remain intact; no provider, native launcher, network, API, local model, or live CLI ran.
- **Correction:** Retry only the bounded documentation and product staging/commit commands through approved Git-metadata access.
- **Prevention:** Continue treating this worktree's staging and commit operations as requiring approved Git-metadata access.
- **Related verification:** The functional calibration suite passed, the offline `-Pilot` plan reported zero provider calls and three roles, `calibration/results` remained unchanged, and `git diff --check` passed before staging.

## Recurrence: 2026-08-25, Option 1 Task 8 acceptance setback commit

- **Phase/task:** Option 1 three-launch calibration pilot Task 8, mandatory setback recurrence commit.
- **Symptom:** Scoped staging and commit of the two acceptance setback records could not create `.git/worktrees/option1-calibration-pilot/index.lock`; Git returned permission denied.
- **Confirmed cause:** The isolated worktree files are writable, while its Git index metadata remains under the parent repository `.git` directory outside the managed write boundary.
- **Impact:** No file was staged and no commit was created by the failed command. The verified offline suites, CLI evidence, and safe recurrence records remain intact; no provider, native launcher, network, API, local model, or live CLI ran.
- **Correction:** Retry only the bounded three-file documentation staging and commit through approved Git-metadata access.
- **Prevention:** Continue treating this worktree's staging and commit operations as requiring approved Git-metadata access.
- **Related verification:** All five offline suites exited 0, the real offline `-Pilot` command emitted one JSON object with zero provider calls and no result-tree change, and both the branch diff and uncommitted documentation passed `git diff --check` before staging.

## Recurrence: 2026-08-26, Agy envelope repair Task 2

- **Phase/task:** Agy envelope repair Task 2 bounded diagnostics commit.
- **Symptom:** Scoped staging could not create `.git/worktrees/option1-calibration-pilot/index.lock`; Git returned permission denied.
- **Confirmed cause:** The isolated worktree files are writable, while its shared Git index metadata remains under the parent repository `.git` directory outside the managed write boundary.
- **Impact:** No file was staged and no commit was created by the failed command. The verified Task 2 implementation, tests, and closed setback records remain intact; no provider, launcher, network, or live calibration path ran.
- **Correction:** Retry only the bounded selective staging and commit through approved Git-metadata access.
- **Prevention:** Continue treating this worktree's staging and commit operations as requiring approved Git-metadata access.
- **Related verification:** The functional calibration suite passed 54/54 assertions, the security suite passed 40/40 assertions, the production script parsed without error, and `git diff --check` passed before staging.
- **Selective-staging note:** Interactive hunk editing was unavailable because the managed terminal had no editor, and an attempted stdin patch could not signal end-of-file through the pseudo-terminal. Both attempts were aborted without changing the index. An exact one-row patch file was then applied directly to the index, and the temporary patch file was removed.

## Recurrence: 2026-08-26, launcher identity design refinement

- **Phase/task:** Agy envelope repair Task 3 design refinement and audit setback commit.
- **Symptom:** Scoped staging could not create `.git/worktrees/option1-calibration-pilot/index.lock`; Git returned permission denied.
- **Confirmed cause:** The worktree files are writable, while Git metadata remains outside the managed write boundary under the parent repository `.git` directory.
- **Impact:** No file was staged and no commit was created by the failed command. The design, plan, and closed audit-setback files remain intact; no launcher, provider, network request, or live calibration ran.
- **Correction:** Retry only the bounded documentation staging and commit through approved Git-metadata access.
- **Prevention:** Continue treating this worktree's index and commit operations as requiring approved Git-metadata access.
- **Related verification:** The scoped documentation diff passed `git diff --check` before the failed staging attempt.

## Recurrence: 2026-08-26, Task 3 launcher identity follow-up

- **Phase/task:** Task 3 launcher identity control-boundary and Windows handle-race follow-up commit.
- **Symptom:** Scoped staging could not create `.git/worktrees/option1-calibration-pilot/index.lock`; Git returned permission denied.
- **Confirmed cause:** The worktree files are writable, while its Git index metadata remains under the parent repository `.git` directory outside the managed write boundary.
- **Impact:** No file was staged and no commit was created by the failed command. The verified production changes, tests, and closed setback records remain intact; no provider, native launcher, network, API, local model, or live calibration ran.
- **Correction:** Retry only the explicit scoped staging and commit commands through approved Git-metadata access.
- **Prevention:** Continue treating this worktree's staging and commit operations as requiring approved Git-metadata access.
- **Related verification:** Pilot, calibration functional, and calibration security suites all exited 0 sequentially; the offline `-Pilot` plan reported zero provider calls; parser checks and `git diff --check` passed before staging.
