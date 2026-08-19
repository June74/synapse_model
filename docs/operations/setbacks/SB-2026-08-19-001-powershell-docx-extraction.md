# SB-2026-08-19-001: PowerShell DOCX paragraph extraction syntax error

- First observed: 2026-08-19
- Last observed: 2026-08-19
- Status: closed
- Phase/task: Read the Abstract from the research DOCX
- Environment: Windows PowerShell in the `router_model` workspace
- Version/commit: not applicable

## Symptom and impact

A read-only PowerShell command failed with `An empty pipe element is not allowed` while collecting extracted paragraph text. The command stopped before reading or modifying the DOCX. No user data or secrets were exposed.

## Evidence

- The failure occurred at the final pipeline after a `foreach` block.
- No output from the DOCX was produced.
- The command was read-only and made no workspace changes.

## Attempts and outcomes

1. Used a `foreach` block directly before `| Select-Object -First 80`; PowerShell rejected the syntax.

## Cause

- Confirmed cause: PowerShell does not accept that block as a pipeline source in the submitted form.
- Hypothesis: collecting results in an array before selecting output will avoid the parser ambiguity.
- Rejected hypotheses: DOCX corruption and file access failure; the parser failed before file content was processed.

## Correction and prevention

Collect paragraph strings in an explicit array, then pipe the array to `Select-Object`. The corrected extraction completed successfully and returned the Abstract plus surrounding headings without modifying the DOCX.

- Owner: Codex
- Verification: corrected bounded paragraph extraction completed successfully on 2026-08-19.
