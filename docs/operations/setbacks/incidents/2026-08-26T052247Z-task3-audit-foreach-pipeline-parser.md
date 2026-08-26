# SB-20260826-052247-task3-audit-foreach-pipeline-parser: Launcher audit command used an invalid foreach pipeline

- **Status:** closed
- **First observed:** 2026-08-26T05:22:47.6016173Z
- **Last observed:** 2026-08-26T05:22:47.6016173Z
- **Phase/task:** Agy envelope repair, Task 3 read-only design audit
- **Environment:** Windows PowerShell, Codex desktop managed workspace
- **Version/commit:** `d8bebc0`

## Symptom

Two read-only metadata inspection commands produced a PowerShell parser error because a `foreach` statement was piped directly.

## Impact

The launcher audit was briefly delayed. No file or repository state changed, and no launcher, provider, network request, prompt, response, credential, or live calibration was involved.

## Reproduction conditions

Construct a PowerShell command that attempts to use a `foreach` language statement as the left-hand side of a pipeline without first materializing or grouping its output.

## Safe evidence

- The failure occurred before the intended metadata inspection completed.
- Corrected read-only commands completed and identified the full Codex shim chain.
- The audit remained read-only throughout.

## Attempts and outcomes

1. Piped a `foreach` statement directly: PowerShell rejected the command at parse time.
2. Reran the metadata inspection with valid statement structure: the inspection succeeded.

## Cause classification

- **Confirmed cause:** Invalid PowerShell grammar in the audit command.
- **Hypotheses:** None remaining.
- **Rejected hypotheses:** The failure was not caused by launcher behavior, repository data, sandbox permissions, or provider availability.
- **Known exclusions:** No executable launcher or provider command was invoked.

## Correction and prevention

- **Correction:** Rewrote the read-only inspection command so the loop output is materialized before any pipeline operation.
- **Prevention:** Use `foreach (...) { ... }` as a standalone statement, or group its output explicitly before piping.
- **Owner:** Codex.
- **Next diagnostic step:** None.

## Verification and related work

The corrected audit established that the reviewed Codex launcher identity must cover `pwsh.exe`, `codex.ps1`, `node.exe`, `codex.js`, and the platform-native `codex.exe` before Task 3 implementation.
