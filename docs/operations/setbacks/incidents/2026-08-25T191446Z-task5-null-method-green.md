# SB-20260825-191446-task5-null-method-green: Task 5 fake execution hit a null method call

- **Status:** closed
- **First observed:** 2026-08-25T19:14:46.056444Z
- **Last observed:** 2026-08-25T19:14:46.056444Z
- **Phase/task:** Option 1 Task 5 first GREEN verification
- **Environment:** Windows PowerShell 7, isolated `codex/option1-calibration-pilot` worktree
- **Version/commit:** `13105b3` plus uncommitted Task 5 RED/GREEN changes

## Symptom

All three fake orchestration assertions stopped with a null-valued method call before recording an invocation.

## Impact

Task 5 GREEN verification paused; no native launcher, provider, network request, credential, or private provider output was involved.

## Reproduction conditions

Run the functional calibration suite with the three new fake-only Task 5 assertions. Each fake invoker was created with `GetNewClosure()` and attempted to append through a script-scoped list.

## Safe evidence

- The same exception reproduced in all three Task 5 assertions.
- The captured stack located the failing method call at `calibration/tests/calibration.tests.ps1:193`, before the fake candidate returned.
- The caller stack showed the failure entered through the injected candidate seam; the accepted launch guard had already created only the disposable test claim under its owned result root.

## Attempts and outcomes

1. Reran with a session-aware wrapper and confirmed the failure was deterministic across all three new cases.
2. Temporarily added safe stack-location reporting to the assertion harness, then restored the original compact failure output.
3. Traced line 193 to the fake closure's call to `$script:PilotTask5Invocations.Add(...)`.
4. Replaced dynamic-module script scope with closure-captured local mutable objects for invocation and grader counts.

## Cause classification

- **Confirmed cause:** PowerShell `GetNewClosure()` creates a dynamic module with its own script scope. The fake invoker therefore saw an uninitialized script-scoped list even though the outer test script initialized a variable with the same name.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** The production orchestrator and accepted launch guard were not the source of the null method; the stack terminated at the test fake's list append.
- **Known exclusions:** No native executable, provider, network request, credential, raw provider response, or non-test result directory was involved.

## Correction and prevention

- **Correction:** Capture the local list and mutable counter object directly in each fake closure, and return their values with the test result.
- **Prevention:** Do not combine `GetNewClosure()` with `$script:` state when tests need to share mutable evidence with the caller.
- **Owner:** Codex and project owner.
- **Next diagnostic step:** None.

## Verification and related work

The session-aware functional suite completed with exit code 0. All three Task 5 fake paths passed along with every pre-existing functional assertion; no native or provider process was invoked.

## Recurrence history

- 2026-08-25T19:14:46.056444Z: First observed.
- 2026-08-25: Closed after the closure-state correction and complete functional GREEN run.
