# Subscription Model-Matrix Runner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` (recommended) or `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a project-local PowerShell runner that executes a controlled task against every enabled subscription-backed tool/model/effort candidate and records normalized JSONL results.

**Architecture:** Keep the checked-in model matrix separate from provider execution code. Pure PowerShell functions will build route IDs, validate candidates, parse provider-specific envelopes, and validate the shared response schema. A thin command runner will invoke `codex`, `claude`, or `agy`, capture stdout/stderr and exit status, normalize the result, and append one audit record per candidate.

**Tech Stack:** PowerShell 7.6, native Codex CLI, Claude Code CLI, Antigravity CLI (`agy`), JSON Schema, JSON Lines, fixture-based PowerShell tests.

---

## Scope and candidate population

The first matrix contains 63 normal candidates:

- 14 `agy` model IDs, using the effort tier encoded in Gemini model IDs and the registered default effort for the three non-Gemini entries.
- 33 native Codex model/effort combinations across seven normal models.
- 16 native Claude model/effort combinations across Opus 5, Sonnet 5, Haiku 4.5, and Fable 5.

`codex-auto-review` is represented as five disabled special-route candidates and can be included only with `-IncludeSpecialRoutes`. `inherit` is not a candidate because it is a session inheritance policy, not a model.

The runner defaults to dry-run. A full invocation requires `-RunAll`; a narrower invocation can use `-RouteId`.

### Task 1: Create failing tests for pure runner behavior

**Files:**
- Create: `pilot/tests/runner.tests.ps1`
- Create: `pilot/tests/fixtures/codex-success.jsonl`
- Create: `pilot/tests/fixtures/claude-success.json`
- Create: `pilot/tests/fixtures/agy-success.json`
- Create: `pilot/tests/fixtures/contract-type-failure.json`

- [ ] **Step 1: Write the test harness and assertions first**

Create a test script that dot-sources `pilot/lib/runner.ps1` when it exists, defines `Assert-Equal`, `Assert-True`, `Assert-Contains`, and `Assert-Throws`, and exits with code 1 on failure. The first assertions should be:

```powershell
Assert-Equal (New-RouteId -Tool 'codex' -Model 'gpt-5.6-sol' -Effort 'xhigh') 'codex__gpt_5_6_sol__xhigh'

$codex = ConvertFrom-CodexOutput (Get-Content -Raw pilot/tests/fixtures/codex-success.jsonl)
Assert-Equal $codex.status 'success'
Assert-Equal $codex.answer '4'

$claude = ConvertFrom-ClaudeOutput (Get-Content -Raw pilot/tests/fixtures/claude-success.json)
Assert-Equal $claude.answer '4'

$agy = ConvertFrom-AgyOutput (Get-Content -Raw pilot/tests/fixtures/agy-success.json)
Assert-Equal $agy.answer '4'

$invalid = Test-CanonicalResponse (Get-Content -Raw pilot/tests/fixtures/contract-type-failure.json | ConvertFrom-Json)
Assert-True (-not $invalid.valid)
```

- [ ] **Step 2: Add representative provider fixtures**

Use these fixture shapes so parsing tests exercise the real envelopes already observed:

```json
{"type":"item.completed","item":{"type":"agent_message","text":"{\"status\":\"success\",\"answer\":\"4\",\"error\":null}"}}
```

```json
{"is_error":false,"result":"{\"status\":\"success\",\"answer\":\"4\",\"error\":null}","modelUsage":{"claude-sonnet-5":{"outputTokens":10}}}
```

```json
{"status":"SUCCESS","structured_output":{"status":"success","answer":"4","error":null},"response":"4"}
```

```json
{"status":"success","answer":4,"error":null}
```

- [ ] **Step 3: Run the tests and verify the expected RED state**

Run:

```powershell
pwsh -NoProfile -File .\pilot\tests\runner.tests.ps1
```

Expected result: failure because `pilot/lib/runner.ps1` does not yet exist. Do not implement production code until this failure is observed.

- [ ] **Step 4: Commit the failing tests**

From the user's personal terminal, where the Git index is writable:

```powershell
git add pilot/tests docs/superpowers/plans/2026-08-19-subscription-model-matrix-runner.md
git commit -m "test: define subscription runner behaviors"
```

### Task 2: Implement pure matrix and parsing functions

**Files:**
- Create: `pilot/lib/runner.ps1`
- Modify: `pilot/tests/runner.tests.ps1`

- [ ] **Step 1: Implement the smallest functions needed by the failing tests**

Add these functions to `pilot/lib/runner.ps1`:

```powershell
function New-RouteId {
    param([string]$Tool, [string]$Model, [string]$Effort)
    $parts = @($Tool, $Model, $(if ($Effort) { $Effort } else { 'default' }))
    $clean = $parts | ForEach-Object { ($_ -replace '[^A-Za-z0-9]+', '_').Trim('_') }
    return ($clean -join '__').ToLowerInvariant()
}

function ConvertFrom-CodexOutput { param([string]$Text) }
function ConvertFrom-ClaudeOutput { param([string]$Text) }
function ConvertFrom-AgyOutput { param([string]$Text) }
function Test-CanonicalResponse { param([object]$Response) }
```

`ConvertFrom-CodexOutput` must parse JSONL, select the last completed agent-message item, and parse its text as JSON. `ConvertFrom-ClaudeOutput` must parse the outer object and parse its `result` string. `ConvertFrom-AgyOutput` must prefer `structured_output` and otherwise parse its `response` string. None of these functions may coerce a numeric answer into a string.

`Test-CanonicalResponse` must return an object with `valid`, `reason`, and `response`. It accepts only `status` equal to `success` or `failure`, a string `answer`, and `error` equal to null or a string.

- [ ] **Step 2: Run the tests and verify GREEN**

Run:

```powershell
pwsh -NoProfile -File .\pilot\tests\runner.tests.ps1
```

Expected result: all parser, route-ID, and schema-type tests pass.

- [ ] **Step 3: Add matrix validation tests**

Add tests for duplicate route IDs, unsupported effort values, missing model names, and disabled special routes. The validator must reject duplicate IDs and unsupported combinations before any model process starts.

- [ ] **Step 4: Run the tests again and commit**

```powershell
pwsh -NoProfile -File .\pilot\tests\runner.tests.ps1
git add pilot/lib/runner.ps1 pilot/tests
git commit -m "feat: add runner matrix and output parsers"
```

### Task 3: Create the explicit model matrix

**Files:**
- Create: `pilot/model_matrix.json`
- Modify: `pilot/providers.json`
- Modify: `pilot/tests/runner.tests.ps1`

- [ ] **Step 1: Add matrix-loading tests before the catalog**

Add assertions that the matrix contains 63 normal candidates, that every `route_id` is unique, that all 14 Antigravity IDs are present, and that Codex and Claude effort sets match the authenticated catalogs.

- [ ] **Step 2: Run the matrix tests and verify RED**

Run:

```powershell
pwsh -NoProfile -File .\pilot\tests\runner.tests.ps1
```

Expected result: failure because `pilot/model_matrix.json` does not exist.

- [ ] **Step 3: Write the matrix**

Create a JSON object with `schema_version`, `generated_from`, `special_routes`, and `candidates`. Each candidate must include:

```json
{
  "route_id": "codex__gpt_5_6_sol__xhigh",
  "tool": "codex",
  "provider": "openai",
  "model": "gpt-5.6-sol",
  "effort": "xhigh",
  "candidate_kind": "model",
  "instruction_file": "pilot/providers/openai/AGENTS.md",
  "enabled": true
}
```

Use the exact model and effort lists in the design specification. Add five `codex-auto-review` special-route records with `enabled: false` and `candidate_kind: "special_route"`.

- [ ] **Step 4: Point the provider registry at the matrix**

Add `model_matrix_path: "pilot/model_matrix.json"` to `pilot/providers.json`. Keep the existing provider authentication and launcher metadata as provider-level documentation; the matrix becomes the source of truth for candidate enumeration.

- [ ] **Step 5: Run matrix tests and commit**

```powershell
pwsh -NoProfile -File .\pilot\tests\runner.tests.ps1
git add pilot/model_matrix.json pilot/providers.json pilot/tests
git commit -m "feat: add complete subscription model matrix"
```

### Task 4: Implement provider command construction and process capture

**Files:**
- Modify: `pilot/lib/runner.ps1`
- Modify: `pilot/tests/runner.tests.ps1`

- [ ] **Step 1: Write command-construction tests**

Test exact argument arrays without starting a model process:

```powershell
$codexArgs = New-CandidateCommand -Candidate $codexCandidate -Prompt 'TASK'
Assert-Contains $codexArgs '--model'
Assert-Contains $codexArgs 'gpt-5.6-sol'
Assert-Contains $codexArgs 'model_reasoning_effort="xhigh"'

$claudeArgs = New-CandidateCommand -Candidate $claudeCandidate -Prompt 'TASK'
Assert-Contains $claudeArgs '--effort'
Assert-Contains $claudeArgs 'medium'

$agyArgs = New-CandidateCommand -Candidate $agyCandidate -Prompt 'TASK'
Assert-Contains $agyArgs '--json-schema'
Assert-Contains $agyArgs 'pilot/shared/response_schema.json'
```

- [ ] **Step 2: Run tests and verify RED**

Run:

```powershell
pwsh -NoProfile -File .\pilot\tests\runner.tests.ps1
```

Expected result: failure because `New-CandidateCommand` is not implemented.

- [ ] **Step 3: Implement provider command construction**

Use these exact launch rules:

```text
codex: codex exec --skip-git-repo-check --ephemeral --json -s read-only --model MODEL -c model_reasoning_effort="EFFORT" PROMPT
claude: claude -p --model MODEL [--effort EFFORT] --output-format json --max-turns 1 --no-session-persistence --disable-slash-commands --tools "" PROMPT
agy: agy -p PROMPT --output-format json --json-schema pilot/shared/response_schema.json --model MODEL --effort EFFORT --print-timeout 2m --disable-slash-commands
```

Omit `--effort` for `claude-haiku-4-5` and omit the Codex effort override only if the candidate has no effort. Build argument arrays instead of a single interpolated shell string.

Implement `Invoke-NativeCandidate` with `System.Diagnostics.ProcessStartInfo`, redirecting stdout and stderr separately, capturing exit code and elapsed milliseconds, and never exposing environment variables in results.

- [ ] **Step 4: Run tests and commit**

```powershell
pwsh -NoProfile -File .\pilot\tests\runner.tests.ps1
git add pilot/lib/runner.ps1 pilot/tests
git commit -m "feat: add subscription CLI command adapters"
```

### Task 5: Implement dry-run, execution, normalization, and JSONL output

**Files:**
- Create: `pilot/run_pilot.ps1`
- Modify: `pilot/lib/runner.ps1`
- Modify: `pilot/tests/runner.tests.ps1`

- [ ] **Step 1: Write dry-run and result-record tests**

Test that default execution prints candidates without invoking a process, `-RunAll` selects enabled candidates, `-RouteId` selects exactly one candidate, and a result record contains the required fields:

```powershell
$record = New-ResultRecord -Candidate $candidate -ProcessResult $processResult -Canonical $canonical
Assert-Equal $record.route_id $candidate.route_id
Assert-True ($null -ne $record.transport_success)
Assert-True ($null -ne $record.contract_compliant)
Assert-True ($record.PSObject.Properties.Name -contains 'duration_ms')
```

- [ ] **Step 2: Run tests and verify RED**

```powershell
pwsh -NoProfile -File .\pilot\tests\runner.tests.ps1
```

Expected result: failure because the CLI entry point and result writer are not implemented.

- [ ] **Step 3: Implement the entry point**

`pilot/run_pilot.ps1` must expose:

```powershell
param(
    [switch]$RunAll,
    [switch]$IncludeSpecialRoutes,
    [string]$RouteId,
    [string]$ResultsPath = 'pilot/results/test-run.jsonl'
)
```

Behavior:

- Without `-RunAll` or `-RouteId`, print a table of candidate IDs and exit 0.
- With `-RouteId`, run only that candidate.
- With `-RunAll`, run all enabled normal candidates.
- With `-IncludeSpecialRoutes`, include enabled special routes if explicitly selected.
- Append one JSON object per candidate to the results file.
- Continue after an individual candidate failure.

The prompt builder must include the shared experiment contract, the provider wrapper, and the task file. It must not include credentials, the full model matrix, or unrelated project files.

- [ ] **Step 4: Run the tests and verify GREEN**

```powershell
pwsh -NoProfile -File .\pilot\tests\runner.tests.ps1
```

Expected result: all unit and fixture tests pass.

- [ ] **Step 5: Verify dry-run behavior**

```powershell
pwsh -NoProfile -File .\pilot\run_pilot.ps1
```

Expected result: a candidate summary containing 63 enabled normal candidates and no new model calls.

- [ ] **Step 6: Commit the runner**

```powershell
git add pilot/run_pilot.ps1 pilot/lib/runner.ps1 pilot/tests
git commit -m "feat: add subscription model matrix runner"
```

### Task 6: Run live verification through authenticated subscriptions

**Files:**
- Modify: `pilot/results/test-run.jsonl`
- Modify: `pilot/tests/runner.tests.ps1` only if a live issue exposes a missing deterministic case

- [ ] **Step 1: Run one candidate per native tool**

```powershell
pwsh -NoProfile -File .\pilot\run_pilot.ps1 -RouteId codex__gpt-5_6-sol__medium
pwsh -NoProfile -File .\pilot\run_pilot.ps1 -RouteId claude__claude-sonnet-5__medium
pwsh -NoProfile -File .\pilot\run_pilot.ps1 -RouteId agy__gemini-3_7-flash-medium__medium
```

Expected result: three new JSONL records, with transport status visible separately from contract compliance.

- [ ] **Step 2: Inspect the records**

```powershell
Get-Content .\pilot\results\test-run.jsonl | ForEach-Object { $_ | ConvertFrom-Json } |
    Select-Object route_id,transport_success,contract_compliant,status,answer,error,duration_ms
```

Confirm that provider-specific envelopes were removed from the canonical fields and that any type mismatch remains visible as contract failure.

- [ ] **Step 3: Run the full normal matrix only after the targeted checks pass**

```powershell
pwsh -NoProfile -File .\pilot\run_pilot.ps1 -RunAll
```

Expected result: one record per enabled candidate, with the run continuing when an individual model is unavailable or rate-limited.

- [ ] **Step 4: Verify final artifacts**

```powershell
$rows = Get-Content .\pilot\results\test-run.jsonl | ForEach-Object { $_ | ConvertFrom-Json }
"records=$($rows.Count)"
"unique_routes=$(($rows.route_id | Sort-Object -Unique).Count)"
"transport_failures=$(($rows | Where-Object { -not $_.transport_success }).Count)"
"contract_failures=$(($rows | Where-Object { -not $_.contract_compliant }).Count)"
```

The final report must distinguish model-access failures from response-contract failures. It must not claim that a subscription is free of API billing merely because a native CLI was used; any CLI-reported cost metadata is recorded as observed metadata only.
