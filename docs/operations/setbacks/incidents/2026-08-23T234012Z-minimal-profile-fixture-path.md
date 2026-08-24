# SB-20260823-234012-minimal-profile-fixture-path: Assumed minimal-profile fixture filename caused a path-not-found error

- **Status:** closed
- **First observed:** 2026-08-23T23:40:12.4218627Z
- **Last observed:** 2026-08-23T23:40:12.4218627Z
- **Phase/task:** Task 4 code-quality baseline inspection
- **Environment:** Windows PowerShell 7 in the deterministic-router-v1 worktree
- **Version/commit:** eeb511380847100dd68b1d74f5eccc0a41d83c9f

## Symptom

A read-only `Get-Content` probe returned a path-not-found error for an assumed minimal-profile fixture filename.

## Impact

The intended minimal fixture was not loaded by that probe. No repository file, secret, provider, or external system was modified or accessed.

## Reproduction conditions

Addressing the minimal profile with a filename inferred from its candidate identity reproduces the error because fixture filenames use a different separator convention.

## Safe evidence

- The failed path was under `router/tests/fixtures/minimal-profiles/`.
- Directory enumeration showed the actual fixture name is `agy-shared-model-medium.json`.

## Attempts and outcomes

1. Read an identity-derived fixture filename: failed with path not found.
2. Enumerate the bounded fixture directory: succeeded and identified the repository filename.

## Cause classification

- **Confirmed cause:** The probe assumed the profile identity's separator convention matched the fixture filename convention.
- **Hypotheses:** None.
- **Rejected hypotheses:** The fixture was not absent; bounded directory enumeration found it.
- **Known exclusions:** No sandbox, permission, parser, or repository-state failure occurred.

## Correction and prevention

- **Correction:** Use the enumerated repository filename or the existing `Get-MinimalProfiles` test helper.
- **Prevention:** Enumerate bounded fixture directories before constructing fixture paths from candidate identities.
- **Owner:** Codex.
- **Next diagnostic step:** None.

## Verification and related work

`Get-ChildItem -LiteralPath router/tests/fixtures/minimal-profiles -File -Filter '*.json'` completed and returned both checked-in fixture names.

## Recurrence history

- 2026-08-23T23:40:12.4218627Z: First observed and closed after bounded enumeration verified the correction.
- 2026-08-23, Task 6 pricing inspection: A guessed Gemini 3.1 profile filename did not exist. Bounded enumeration found `gemini-3.1-pro-high__high.json` and `gemini-3.1-pro-low__low.json`. No files or external state changed. Prevention remains to enumerate profile directories before constructing filenames from model identity assumptions.
