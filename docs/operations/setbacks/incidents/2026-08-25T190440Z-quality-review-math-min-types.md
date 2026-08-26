# SB-20260825-190440-quality-review-math-min-types: Quality-review line-range helper used ambiguous Math.Min types

- **Status:** closed
- **First observed:** 2026-08-25T19:04:40.2918430Z
- **Last observed:** 2026-08-26T05:44:07.7706432Z
- **Phase/task:** Task 4 final code-quality review
- **Environment:** Windows PowerShell, Codex desktop managed workspace
- **Version/commit:** `09276d4`

## Symptom

A read-only line-range inspection loop failed with `Argument types do not match` when calling `[Math]::Min($range[1], $l.Count)`.

## Impact

One inspection command had to be repeated. No repository state, test artifact, provider process, or private data was changed.

## Reproduction conditions

Pass PowerShell values with ambiguous runtime types directly to an overloaded `[Math]::Min` method.

## Safe evidence

- The failed command was read-only.
- Explicit integer casts made overload selection deterministic.
- The final quality review completed with no Critical, Important, or Minor issues.

## Attempts and outcomes

1. Called `[Math]::Min($range[1], $l.Count)`; PowerShell could not select compatible argument types.
2. Called `[Math]::Min([int]990, [int]$l.Count)`; the read-only inspection completed.

## Cause classification

- **Confirmed cause:** Ambiguous PowerShell values were passed to an overloaded .NET method without explicit casts.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** Repository content or filesystem state caused the inspection failure.
- **Known exclusions:** No code mutation, provider call, network activity, credential, prompt, or response was involved.

## Correction and prevention

- **Correction:** Cast both `[Math]::Min` arguments to `[int]` in review helpers.
- **Prevention:** Use explicit types when calling overloaded .NET methods from PowerShell inspection commands.
- **Owner:** Codex.
- **Next diagnostic step:** None.

## Verification and related work

The corrected inspection completed, and the independent Task 4 quality review reported no issues and a ready-to-proceed assessment.

## Recurrence history

- 2026-08-25T19:04:40.2918430Z: First observed, corrected, verified, and closed.
- 2026-08-26T05:44:07.7706432Z: Task 3 refined-design review repeated the ambiguous `[Math]::Min` call during a read-only range inspection; the reviewer switched to corrected narrow reads and continued. No state changed and no launcher, provider, network, or live calibration ran.
