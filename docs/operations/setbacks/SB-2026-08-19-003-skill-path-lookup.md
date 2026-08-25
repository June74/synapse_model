# SB-2026-08-19-003 - Skill path lookup mismatch

- ID: SB-2026-08-19-003
- Title: Skill path lookup mismatch
- Status: closed
- First observed: 2026-08-19
- Last observed: 2026-08-25T23:53:40.1144919Z
- Phase/task: Task 9 live acceptance incident logging
- Environment: Windows PowerShell, Codex desktop
- Version/commit: Not applicable

## Symptom and impact

The first attempt to read the `scope-gate` skill used the catalog root `C:\\Users\\2006i\\.codex\\skills`, but the installed skill was under `C:\\Users\\2006i\\.agents\\skills`. The command failed before the research work began. No project data, secrets, or user artifacts were exposed or modified.

## Evidence

- `Get-ChildItem` located the skill at `C:\\Users\\2006i\\.agents\\skills\\scope-gate`.
- The corrected read completed successfully.

## Attempts and outcomes

1. Read from the catalog root path: failed with a path-not-found error.
2. Searched both local skill roots and read the located file: succeeded.

## Cause and hypotheses

- Confirmed cause: the displayed skill root alias did not match the filesystem location for this installed skill.
- Rejected hypothesis: repository permissions were not the cause; the corrected path was readable.

## Correction and prevention

- Correction: search both configured local skill roots when a listed skill path is absent.
- Prevention: verify the resolved filesystem path before retrying a skill read.
- Owner: Codex
- Next diagnostic step: none.

## Verification

The `scope-gate` and `setback-logger` instructions were read successfully from their resolved paths.

## Recurrences

### 2026-08-23 - catalog root and incident filename assumptions

- Symptom: a batch skill read assumed every listed skill lived under `C:\\Users\\2006i\\.codex\\skills`; three skills actually lived under `C:\\Users\\2006i\\.agents\\skills`. A later incident read assumed the index title was also the filename.
- Impact: two read-only commands reported path-not-found errors. No repository product files, private data, or runtime state changed.
- Confirmed cause: the commands constructed paths from labels instead of resolving the catalog root alias and the directory entry first.
- Correction: expanded each catalog alias to its configured root and opened the incident using the exact path returned by `Get-ChildItem`.
- Prevention: resolve catalog aliases and directory entries before issuing literal-path reads; do not derive filenames from display titles.
- Verification: all required skill files and this incident were subsequently read successfully from resolved paths.

### 2026-08-24 - schema filename assumption

- Symptom: an interface-inspection command requested `request.schema.json` and `response.schema.json` even though the live test harness names `request-profile.schema.json` and `router-response.schema.json`.
- Impact: two read-only schema reads reported path-not-found errors. Parallel source inspection continued; no product file or runtime state changed.
- Confirmed cause: the command shortened filenames from memory instead of using the literal paths already exposed by the test harness.
- Correction: use the exact schema paths from `router/tests/router.tests.ps1` and verify them through a directory listing before reading.
- Prevention: copy live path variables verbatim; never normalize or abbreviate repository filenames.
- Verification: the corrected literal-path reads loaded all three schema filenames and the full request and response schemas successfully.

### 2026-08-25 - setback helper location assumption

- Symptom: Task 5 attempted to run `new_setback.py` beneath the repository incident directory, but the helper is installed beneath the resolved `setback-logger` skill directory.
- Impact: one read-only helper invocation failed before creating the Task 5 incident. No product file, provider, native launcher, network request, or private data was involved.
- Confirmed cause: the command treated the skill's relative `scripts/` reference as repository-relative instead of resolving it against the skill directory.
- Correction: enumerate the resolved skill directory and invoke its exact `scripts/new_setback.py` path with the bundled Python runtime.
- Prevention: resolve relative resources against the directory containing `SKILL.md`, as required by the skill-loading contract.
- Verification: the helper's `--help` completed with exit code 0 from the resolved skill path.

### 2026-08-25 - repository instruction and incident filename assumptions

- Symptom: Task 6 first attempted to read a repository-root `AGENTS.md` that is not present in this worktree, then derived this incident filename from its index title instead of enumerating the exact path.
- Impact: two read-only commands reported path-not-found errors. No product file, provider, native launcher, network request, or private data was involved.
- Confirmed cause: the commands assumed literal paths without first resolving them from the repository tree.
- Correction: enumerate `AGENTS.md` and setback files before opening them. The only `AGENTS.md` is scoped beneath `pilot/providers/openai/` and does not govern the Task 6 files.
- Prevention: use `rg --files` before literal reads whenever the requested repository instruction or incident path has not already been verified.
- Verification: repository enumeration identified the exact scoped instruction and incident paths; Task 6 preflight continued without applying unrelated provider-scoped instructions.

### 2026-08-25 - Task 7 setback-helper and Windows path assumptions

- Symptom: Task 7 first looked for the setback helper beneath the repository incident directory, then attempted to execute the located Python file as a native Windows program. A later search passed a wildcard as part of a literal Windows path and reported an invalid filename.
- Impact: three read-only lookup or launch attempts failed before Task 7 edits. No product file, provider, native launcher, network request, result artifact, or private data was involved.
- Confirmed cause: commands constructed unverified relative or wildcard paths and did not invoke the Python helper through the repository-resolved Python runtime.
- Correction: enumerate the skill directory, read the exact helper path, resolve Python through `Resolve-RouterPythonExecutable`, and search explicit directories without a literal Windows wildcard path.
- Prevention: resolve every relative skill resource against the loaded `SKILL.md` directory, invoke `.py` helpers through the resolved Python executable, and use `rg` directory roots or `Get-ChildItem` for Windows wildcard expansion.
- Verification: the exact helper source and `--help` completed through the resolved Python runtime; the explicit incident and index searches completed without using the invalid wildcard path.

### 2026-08-25 - Task 9 setback-helper and resolver-scope recurrence

- Symptom: live-incident logging again looked for `scripts/new_setback.py` beneath the repository setback directory and called `Resolve-RouterPythonExecutable` without first loading its defining module.
- Impact: one read-only lookup command failed before incident creation. No runtime artifact, provider process, tracked product file, credential, prompt, or response was modified or exposed.
- Confirmed cause: the command repeated the repository-relative helper assumption and treated a module-scoped resolver as globally available.
- Correction: enumerated repository files, updated this recurrence, and created the bounded live incident manually because the repository contains no local helper script.
- Prevention: resolve skill-owned resources against the loaded skill directory and load a function's defining module before calling it; otherwise use the documented manual incident contract.
- Verification: the existing incident was found by exact path, the new live incident and index row were created with bounded evidence only, and no live command was repeated.
