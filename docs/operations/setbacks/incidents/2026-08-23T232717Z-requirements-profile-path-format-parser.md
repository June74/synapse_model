# SB-20260823-232717-requirements-profile-path-format-parser: Requirements profile-path format expression caused a parser error

- **Status:** closed
- **First observed:** 2026-08-23T23:27:17.790811Z
- **Last observed:** 2026-08-23T23:27:17.790811Z
- **Phase/task:** Task 4 specification-fix implementation
- **Environment:** PowerShell 7, deterministic-router-v1 worktree
- **Version/commit:** Fixed in `a7ab9fac722f12504f6458a2bd0a2665d7aef077`

## Symptom

PowerShell reported an unexpected comma token in the profile_path format expression.

## Impact

The first GREEN run did not start; no provider calls or external state changes occurred, and final verification was delayed.

## Reproduction conditions

The first implementation of Task 4's unsupported-dimension detail constructed `profile_path` with an unparenthesized multi-argument `-f` format expression inside an ordered object.

## Safe evidence

PowerShell reported `Unexpected token ',' in expression or statement` at the `profile_path` format expression. The failure occurred before the router suite could execute.

## Attempts and outcomes

- First GREEN run: parse failure; no assertions ran.
- Parenthesized the complete format expression; parsing succeeded.
- Full router suite then completed with 177 PASS and exit 0.

## Cause classification

- **Confirmed cause:** The multi-argument `-f` expression was not grouped inside the ordered-object property expression.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** The router requirement algorithm was not the cause; execution had not reached it.
- **Known exclusions:** No provider call, credential access, or external state change occurred.

## Correction and prevention

- **Correction:** Changed the value to `('quality.{0}.{1}' -f $dimension.profile_map, $dimension.value)`.
- **Prevention:** Parenthesize multi-argument PowerShell format expressions when used as object-property values, and require parser/test verification before commit.
- **Owner:** Codex implementer.
- **Next diagnostic step:** None; correction is verified.

## Verification and related work

PowerShell parsed the corrected file, the complete router suite passed 177 assertions with exit 0, and the acceptance smoke emitted the three expected profile paths.

## Recurrence history

- 2026-08-23T23:27:17.790811Z: First observed.
