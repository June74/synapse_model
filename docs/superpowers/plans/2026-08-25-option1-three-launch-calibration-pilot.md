# Option 1 Three-Launch Calibration Pilot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add and offline-verify a bounded Option 1 calibration path that pins one synthetic extraction prompt to one Google candidate, grades it locally, obtains one OpenAI-family judgment and one Anthropic-family judgment, and can never start more than three application launcher processes.

**Architecture:** Extend the existing calibration entry point with an opt-in `-Pilot` branch. A strict checked-in manifest resolves exact existing matrix/profile identities, a generated immutable plan freezes source hashes and budgets, an optional guard inside `Invoke-PilotCandidate` atomically reserves each non-refundable launch slot immediately before native invocation, and a dedicated pilot result artifact records technical state separately from quality evidence. Existing dry-run, route-only, full calibration, router, provider adapters, and production quality profiles remain unchanged.

**Tech Stack:** PowerShell 7, existing JSON-schema subset in `router/lib/schema.ps1`, existing pilot runner/provider adapters, existing calibration graders and judge normalization, JSON artifacts, .NET `System.IO` atomic file primitives, Git, and the repository's five offline test suites.

---

## Fixed contracts for every task

- Work only in `C:\Users\2006i\projects\router_model\.worktrees\option1-calibration-pilot` on `codex/option1-calibration-pilot`.
- Never modify or synchronize the dirty original checkout.
- Make no provider call during Tasks 1-8. Every execution test uses injected fakes.
- Keep all production quality values `unknown`; do not edit `pilot/model_profiles/`, snapshots, or production selection policy.
- The exact ordered live identities are:
  1. `agy__gemini_3_7_flash_low__low` / `gemini-3.7-flash-low__low` / Google;
  2. `codex__gpt_5_6_sol__max` / `gpt-5.6-sol__max` / OpenAI;
  3. `claude__claude_opus_5__max` / `claude-opus-5__max` / Anthropic.
- The only selected prompt is `extraction-low-general-v1` version `1.0.0`.
- `-Pilot` is offline and writes no result directory. Only `-Pilot -Run -RunId option1-live-20260825-001` is live-capable in the prepared acceptance packet.
- A launch slot is consumed before process invocation and is never deleted, refunded, reused, or resumed.
- Application retries, fallback, substitution, and profile promotion are always zero/false.

## Task 1: Freeze and validate the exact pilot manifest

**Files:**

- Create: `calibration/pilots/option1-three-launch-v1.json`
- Create: `calibration/pilots/option1-three-launch-manifest.schema.json`
- Modify: `calibration/run_calibration.ps1:1-22, 493-505`
- Modify: `calibration/tests/calibration.tests.ps1:1-90`

- [ ] **Step 1: Add failing manifest admission tests**

Add test paths beside the existing calibration paths and add assertions that import the fixed manifest, reject an added property, reject a changed budget, and reject a changed identity:

```powershell
$pilotManifestPath = Join-Path $calibrationRoot 'pilots/option1-three-launch-v1.json'
$pilotManifestSchemaPath = Join-Path $calibrationRoot 'pilots/option1-three-launch-manifest.schema.json'

function Assert-Throws {
    param([scriptblock]$Script)
    $threw = $false
    try { & $Script } catch { $threw = $true }
    if (-not $threw) { throw 'Expected script to throw.' }
}

Invoke-Assertion 'Option 1 manifest resolves the exact prompt candidate and ordered judges' {
    $loaded = Import-CalibrationPilotManifest -Path $pilotManifestPath `
        -SchemaPath $pilotManifestSchemaPath -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot
    Assert-Equal $loaded.manifest.pilot_id 'option1-three-launch-v1'
    Assert-Equal $loaded.prompt.id 'extraction-low-general-v1'
    Assert-SequenceEqual @($loaded.roles.route_id) @(
        'agy__gemini_3_7_flash_low__low',
        'codex__gpt_5_6_sol__max',
        'claude__claude_opus_5__max'
    )
    Assert-Equal $loaded.manifest.limits.total 3
    Assert-False ([bool]$loaded.manifest.profile_promotion_allowed)
}

Invoke-Assertion 'Option 1 manifest rejects extra fields budgets and identity drift' {
    $source = Get-Content -Raw -LiteralPath $pilotManifestPath | ConvertFrom-Json -Depth 100
    foreach ($mutation in @('extra', 'budget', 'identity')) {
        $copy = Copy-TestObject $source
        if ($mutation -ceq 'extra') { $copy | Add-Member surprise $true }
        if ($mutation -ceq 'budget') { $copy.limits.total = 4 }
        if ($mutation -ceq 'identity') { $copy.roles[0].route_id = 'agy__wrong__low' }
        Assert-Throws {
            Test-CalibrationPilotManifestObject -Manifest $copy -SchemaPath $pilotManifestSchemaPath `
                -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot
        }
    }
}
```

- [ ] **Step 2: Run the calibration suite and observe the intended RED failure**

Run:

```powershell
pwsh -NoProfile -File .\calibration\tests\calibration.tests.ps1
```

Expected: the new assertions fail because the pilot manifest files and import functions do not exist; pre-existing assertions remain green.

- [ ] **Step 3: Add the strict checked-in manifest**

Create `calibration/pilots/option1-three-launch-v1.json` with these exact values:

```json
{
  "manifest_version": "calibration-pilot-manifest/v1",
  "pilot_id": "option1-three-launch-v1",
  "mode": "option_1_workflow_validation",
  "selection_mode": "calibration_only_exact_pin",
  "prompt": { "id": "extraction-low-general-v1", "version": "1.0.0" },
  "roles": [
    { "ordinal": 1, "role": "candidate", "family": "google", "launcher": "agy", "route_id": "agy__gemini_3_7_flash_low__low", "configuration_id": "gemini-3.7-flash-low__low", "model": "gemini-3.7-flash-low", "effort": "low" },
    { "ordinal": 2, "role": "judge_1", "family": "openai", "launcher": "codex", "route_id": "codex__gpt_5_6_sol__max", "configuration_id": "gpt-5.6-sol__max", "model": "gpt-5.6-sol", "effort": "max" },
    { "ordinal": 3, "role": "judge_2", "family": "anthropic", "launcher": "claude", "route_id": "claude__claude_opus_5__max", "configuration_id": "claude-opus-5__max", "model": "claude-opus-5", "effort": "max" }
  ],
  "deterministic_grader": "exact_fields",
  "limits": { "total": 3, "provider_family": { "google": 1, "openai": 1, "anthropic": 1 }, "application_retries": 0 },
  "raw_content_policy": "synthetic_prompt_and_credential_sanitized_outputs_only",
  "profile_promotion_allowed": false
}
```

- [ ] **Step 4: Add structural schema validation plus exact semantic validation**

The schema must set `additionalProperties: false` at every object level, require every shown field, restrict string enums, require three role objects, and require integer budget fields. Because the repository schema subset does not enforce numeric `const` reliably, add semantic checks in PowerShell:

```powershell
function Assert-CalibrationPilotExactValue {
    param([object]$Actual, [object]$Expected, [string]$Name)
    if ($Actual -cne $Expected) { throw "Pilot manifest '$Name' differs from the approved contract." }
}

function Import-CalibrationPilotManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SchemaPath,
        [Parameter(Mandatory)][string]$CalibrationSetPath,
        [Parameter(Mandatory)][string]$RubricsRoot
    )
    $manifest = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -Depth 100 -NoEnumerate
    return Test-CalibrationPilotManifestObject -Manifest $manifest -SchemaPath $SchemaPath `
        -CalibrationSetPath $CalibrationSetPath -RubricsRoot $RubricsRoot
}
```

`Test-CalibrationPilotManifestObject` must:

1. call `Test-RouterSchema` and throw the joined structural errors;
2. import and validate the complete 24-prompt calibration set before selecting the fixed prompt;
3. compare every fixed manifest scalar, ordinal, ordered role, and budget to the approved constants above;
4. resolve each route through `pilot/model_matrix.json` and `Get-CalibrationProfileAndCandidate`;
5. reject disabled candidates, `candidate_kind: special`, duplicate routes/families/configurations, and matrix/profile differences;
6. assert the prompt's grader is `exact_fields` and the candidate's cross-family pair is `openai`, then `anthropic`; and
7. return `{ manifest, calibration_set, prompt, rubric, roles }` only after every check passes.

- [ ] **Step 5: Run the focused suite and confirm green**

Run:

```powershell
pwsh -NoProfile -File .\calibration\tests\calibration.tests.ps1
```

Expected: all calibration tests pass and no provider executable is invoked.

- [ ] **Step 6: Commit Task 1**

```powershell
git add calibration/pilots calibration/run_calibration.ps1 calibration/tests/calibration.tests.ps1
git commit -m "feat: freeze option1 calibration pilot manifest"
```

## Task 2: Put the non-refundable guard at the provider-launch seam

**Files:**

- Modify: `pilot/lib/runner.ps1:1510-1545`
- Modify: `pilot/tests/runner.tests.ps1:1549-1600`

- [ ] **Step 1: Add failing launch-order, veto, and compatibility tests**

```powershell
Invoke-Assertion 'Invoke-PilotCandidate runs its launch guard immediately before native invocation' {
    $events = [Collections.Generic.List[string]]::new()
    $matrix = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'pilot/model_matrix.json') | ConvertFrom-Json
    $candidate = @($matrix.candidates | Where-Object route_id -ceq 'agy__gemini_3_7_flash_low__low')[0]
    $result = Invoke-PilotCandidate -Candidate $candidate -Prompt 'synthetic' -LaunchGuard {
        param($guardCandidate, $command)
        $events.Add("guard:$($guardCandidate.route_id)")
        Assert-Equal $command.route_id $guardCandidate.route_id
    } -NativeInvoker {
        param($command)
        $events.Add("native:$($command.route_id)")
        $canonical = [pscustomobject]@{ status = 'success'; answer = '{}'; error = $null } | ConvertTo-Json -Compress
        $outer = [pscustomobject]@{ response = $canonical } | ConvertTo-Json -Compress
        [pscustomobject]@{ exit_code = 0; stdout = $outer; stderr = ''; duration_ms = 1 }
    }
    Assert-SequenceEqual @($events) @(
        'guard:agy__gemini_3_7_flash_low__low',
        'native:agy__gemini_3_7_flash_low__low'
    )
}

Invoke-Assertion 'Invoke-PilotCandidate guard veto prevents native invocation' {
    $events = [Collections.Generic.List[string]]::new()
    $matrix = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'pilot/model_matrix.json') | ConvertFrom-Json
    $candidate = @($matrix.candidates | Where-Object route_id -ceq 'agy__gemini_3_7_flash_low__low')[0]
    $result = Invoke-PilotCandidate -Candidate $candidate -Prompt 'synthetic' `
        -LaunchGuard { throw 'launch_guard_vetoed' } `
        -NativeInvoker { $events.Add('native'); throw 'must not run' }
    Assert-Equal $events.Count 0
    Assert-Equal $result.diagnostic_note 'execution failure'
}
```

Retain the existing `Invoke-PilotCandidate executes one exact candidate...` assertion as the backward-compatibility proof without `-LaunchGuard`.

- [ ] **Step 2: Run the pilot runner suite and observe RED**

```powershell
pwsh -NoProfile -File .\pilot\tests\runner.tests.ps1
```

Expected: only the new guard assertions fail because `-LaunchGuard` is not accepted.

- [ ] **Step 3: Add the optional guard at the exact seam**

Change the function parameter list and the try block to:

```powershell
param(
    [Parameter(Mandatory)][object]$Candidate,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Prompt,
    [scriptblock]$NativeInvoker,
    [scriptblock]$LaunchGuard,
    [AllowNull()][string]$RunId,
    [ValidateRange(-1, [int]::MaxValue)][int]$TimeoutSeconds = -1
)

# Inside the existing try, after command construction and before either invoker:
$command = New-CandidateCommand -Candidate $Candidate -Prompt $Prompt
if ($null -ne $LaunchGuard) {
    & $LaunchGuard $Candidate $command
}
$processResult = if ($null -ne $NativeInvoker) {
    & $NativeInvoker $command
} else {
    # retain the existing timeout selection and Invoke-NativeCandidate call unchanged
}
```

Do not catch or reinterpret guard failures outside the function's existing safe `execution failure` result. Do not change any caller that omits the guard.

- [ ] **Step 4: Run the pilot runner suite and confirm green**

```powershell
pwsh -NoProfile -File .\pilot\tests\runner.tests.ps1
```

Expected: every pilot assertion passes, including the pre-existing no-guard behavior.

- [ ] **Step 5: Commit Task 2**

```powershell
git add pilot/lib/runner.ps1 pilot/tests/runner.tests.ps1
git commit -m "feat: guard pilot provider launch seam"
```

## Task 3: Build the offline `-Pilot` admission and immutable plan

**Files:**

- Modify: `calibration/run_calibration.ps1:1-10, 603-638`
- Modify: `calibration/tests/calibration.tests.ps1:90-170`

- [ ] **Step 1: Add failing zero-call, zero-write, and mode-exclusion tests**

```powershell
Invoke-Assertion 'Option 1 offline pilot returns one frozen plan with zero calls and writes' {
    $root = Join-Path $resultsRoot ('pilot-plan-test-{0}' -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    try {
        $calls = 0
        $plan = Invoke-Calibration -Pilot -ResultsRoot $root -CandidateInvoker { $script:calls++ } `
            -JudgeInvoker { $script:calls++ }
        Assert-Equal $calls 0
        Assert-Equal $plan.mode 'pilot-plan'
        Assert-Equal $plan.selection_mode 'calibration_only_exact_pin'
        Assert-Equal $plan.provider_calls 0
        Assert-Equal @($plan.roles).Count 3
        Assert-Equal @(Get-ChildItem -LiteralPath $root -Force).Count 0
    } finally { Remove-Item -LiteralPath $root -Recurse -Force }
}

Invoke-Assertion 'Option 1 rejects Route and RunId without Run before calls or writes' {
    Assert-Throws { Invoke-Calibration -Pilot -Route }
    Assert-Throws { Invoke-Calibration -Pilot -RunId 'not-live' }
}
```

- [ ] **Step 2: Run the calibration suite and observe RED**

```powershell
pwsh -NoProfile -File .\calibration\tests\calibration.tests.ps1
```

Expected: the new assertions fail because `Pilot`, manifest paths, and candidate invoker injection are absent.

- [ ] **Step 3: Add parameters and dispatch without disturbing existing modes**

Add `[switch]$Pilot` to the script-level parameter block. Add all of these to `Invoke-Calibration`; the path and invoker seams remain function-only test seams and are not public CLI selectors:

```powershell
[switch]$Pilot,
[string]$PilotManifestPath = (Join-Path $script:CalibrationRoot 'pilots/option1-three-launch-v1.json'),
[string]$PilotManifestSchemaPath = (Join-Path $script:CalibrationRoot 'pilots/option1-three-launch-manifest.schema.json'),
[scriptblock]$CandidateInvoker
```

At the script's final call site, forward only `-Pilot:$Pilot`. In the CLI error envelope, report `mode = 'pilot'` when `$Pilot` and persist no raw exception message for pilot mode.

At the beginning of `Invoke-Calibration`, reject:

```powershell
if ($Pilot -and $Route) { throw 'Pilot and Route are mutually exclusive.' }
if ($Pilot -and -not $Run -and -not [string]::IsNullOrWhiteSpace($RunId)) {
    throw 'Pilot planning does not accept RunId.'
}
```

Then dispatch `-Pilot` to a new `Invoke-CalibrationPilot` function before existing plan construction. Leave the current `Run and Route` check and every non-pilot line behaviorally intact.

- [ ] **Step 4: Generate exact hashes and return an offline-only plan**

Add byte-level and canonical-object hash helpers:

```powershell
function Get-CalibrationFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-CalibrationObjectSha256 {
    param([Parameter(Mandatory)][object]$Value)
    return Get-CalibrationSha256 -Text ($Value | ConvertTo-Json -Depth 100 -Compress)
}
```

`New-CalibrationPilotPlan` must return an ordered object containing:

```powershell
[pscustomobject][ordered]@{
    artifact_version = 'calibration-pilot-plan/v1'
    pilot_id = 'option1-three-launch-v1'
    mode = 'pilot-plan'
    selection_mode = 'calibration_only_exact_pin'
    prompt = [pscustomobject][ordered]@{ id = 'extraction-low-general-v1'; version = '1.0.0' }
    roles = @($loaded.roles | ForEach-Object {
        [pscustomobject][ordered]@{
            ordinal = [int]$_.ordinal; role = [string]$_.role; family = [string]$_.family
            launcher = [string]$_.launcher; route_id = [string]$_.route_id
            configuration_id = [string]$_.configuration_id; model = [string]$_.model; effort = [string]$_.effort
        }
    })
    limits = $loaded.manifest.limits
    source_hashes = [pscustomobject][ordered]@{
        manifest = Get-CalibrationFileSha256 $PilotManifestPath
        matrix = Get-CalibrationFileSha256 (Join-Path $script:CalibrationProjectRoot 'pilot/model_matrix.json')
        candidate_profile = Get-CalibrationObjectSha256 $loaded.roles[0].profile
        calibration_set = Get-CalibrationFileSha256 $CalibrationSetPath
        prompt_definition = Get-CalibrationObjectSha256 $loaded.prompt
        rubric = Get-CalibrationObjectSha256 $loaded.rubric
        response_schema = Get-CalibrationFileSha256 (Join-Path $script:CalibrationProjectRoot 'pilot/shared/response_schema.json')
    }
    provider_calls = 0
    provider_side_requests = [pscustomobject][ordered]@{ observable = $false; count = $null }
    profile_promotion_allowed = $false
    profile_mutated = $false
    production_eligibility_changed = $false
}
```

The offline branch returns this object and never calls `New-CalibrationRunClaim`, `Write-CalibrationJsonFile`, `CandidateInvoker`, or `JudgeInvoker`.

- [ ] **Step 5: Verify focused plan behavior**

```powershell
pwsh -NoProfile -File .\calibration\tests\calibration.tests.ps1
pwsh -NoProfile -File .\calibration\run_calibration.ps1 -Pilot
git status --short
```

Expected: tests pass; the command prints one `pilot-plan` with three ordered roles and `provider_calls: 0`; status shows no generated result directory.

- [ ] **Step 6: Commit Task 3**

```powershell
git add calibration/run_calibration.ps1 calibration/tests/calibration.tests.ps1
git commit -m "feat: add offline option1 pilot plan"
```

## Task 4: Add atomic run, slot, and result artifact primitives

**Files:**

- Modify: `calibration/run_calibration.ps1:35-145, 603-621`
- Modify: `calibration/tests/calibration.tests.ps1:170-270`
- Modify: `calibration/tests/calibration_security.tests.ps1:1-70`

- [ ] **Step 1: Add failing ledger and transition tests**

Test that one fresh run creates the exact directory layout, a duplicate run ID fails, duplicate or reordered slot claims fail, family/total limits fail, claims survive process-start failure, and terminal runs cannot transition:

```powershell
Invoke-Assertion 'Option 1 slot claims are ordered atomic and non-refundable' {
    $root = Join-Path $resultsRoot ('pilot-ledger-test-{0}' -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    try {
        $run = New-CalibrationPilotRun -ResultsRoot $root -RunId 'ledger-test-001' -Plan $script:testPilotPlan
        $one = New-CalibrationPilotSlotClaim -Run $run -Role $script:testPilotPlan.roles[0]
        Assert-True (Test-Path -LiteralPath $one.claim_path -PathType Leaf)
        Assert-Throws { New-CalibrationPilotSlotClaim -Run $run -Role $script:testPilotPlan.roles[0] }
        Assert-Throws { New-CalibrationPilotSlotClaim -Run $run -Role $script:testPilotPlan.roles[2] }
        Assert-Equal (Get-CalibrationPilotClaimCount -Run $run) 1
    } finally { Remove-Item -LiteralPath $root -Recurse -Force }
}
```

- [ ] **Step 2: Run the focused suites and observe RED**

```powershell
pwsh -NoProfile -File .\calibration\tests\calibration.tests.ps1
pwsh -NoProfile -File .\calibration\tests\calibration_security.tests.ps1
```

Expected: only new ledger/artifact assertions fail.

- [ ] **Step 3: Implement exclusive run creation and immutable plan writing**

Use `FileMode.CreateNew` for `.run.claim`, every slot claim, and `plan.json`. The write helper must keep every path under the claimed run root and flush before close:

```powershell
function Write-CalibrationCreateNewJson {
    param([string]$Path, [object]$Value, [string]$AllowedRunRoot)
    Assert-CalibrationWriteBoundary -Path $Path -AllowedRunRoot $AllowedRunRoot
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 100))
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}
```

`New-CalibrationPilotRun` must create only these bounded paths:

```text
calibration/results/ledger-test-001/.run.claim
calibration/results/ledger-test-001/plan.json
calibration/results/ledger-test-001/result.json
calibration/results/ledger-test-001/claims/
calibration/results/ledger-test-001/raw/
```

It records `planned`, then `preflight_passed`, and initializes all three attempts to `planned`.

- [ ] **Step 4: Implement result replacement and state transition rules**

Persist mutable `result.json` through a same-directory create-new temporary file followed by an atomic replace/move. Allow only:

```powershell
$script:PilotRunTransitions = @{
    planned = @('preflight_passed', 'stopped')
    preflight_passed = @('running', 'stopped')
    running = @('completed', 'stopped', 'indeterminate')
    completed = @(); stopped = @(); indeterminate = @()
}
$script:PilotAttemptTransitions = @{
    planned = @('slot_reserved', 'skipped')
    slot_reserved = @('process_started', 'failed')
    process_started = @('succeeded', 'failed')
    succeeded = @(); failed = @(); skipped = @()
}
```

Slot claims use exact names `01-google-candidate.claim`, `02-openai-judge.claim`, and `03-anthropic-judge.claim`. Before create-new, verify the expected next ordinal, current run state, exact role identity, total claim count below three, and family count below one. Never delete a claim.

- [ ] **Step 5: Run focused suites and confirm green**

```powershell
pwsh -NoProfile -File .\calibration\tests\calibration.tests.ps1
pwsh -NoProfile -File .\calibration\tests\calibration_security.tests.ps1
```

- [ ] **Step 6: Commit Task 4**

```powershell
git add calibration/run_calibration.ps1 calibration/tests/calibration.tests.ps1 calibration/tests/calibration_security.tests.ps1
git commit -m "feat: add atomic option1 launch ledger"
```

## Task 5: Orchestrate the complete fake three-launch success and quality paths

**Files:**

- Modify: `calibration/run_calibration.ps1:560-603, 622-end`
- Modify: `calibration/tests/calibration.tests.ps1:270-430`

- [ ] **Step 1: Add failing end-to-end fake execution tests**

Build fake `CandidateInvoker` and `JudgeInvoker` functions that accept the resolved candidate, prompt, and launch guard; invoke the guard; append their route ID to a list; and return normalized successful execution objects. Assert:

```powershell
Assert-SequenceEqual @($invocations) @(
    'agy__gemini_3_7_flash_low__low',
    'codex__gpt_5_6_sol__max',
    'claude__claude_opus_5__max'
)
Assert-Equal $result.run_state 'completed'
Assert-Equal $result.slots_consumed 3
Assert-Equal $result.launcher_processes_started 3
Assert-False $result.provider_side_requests.observable
Assert-Equal $result.provider_side_requests.count $null
Assert-Equal $result.quality.external_category 'unknown'
Assert-False $result.profile_promotion_allowed
Assert-False $result.profile_mutated
Assert-False $result.production_eligibility_changed
```

Add two quality-negative cases:

- candidate returns valid JSON with one wrong exact field; both judges still run;
- Judge 1 returns valid `decision: fail` and sanitized rationale; Judge 2 still runs.

Both cases must finish technically `completed` while quality fields record the failures.

- [ ] **Step 2: Run the calibration suite and observe RED**

```powershell
pwsh -NoProfile -File .\calibration\tests\calibration.tests.ps1
```

- [ ] **Step 3: Add one role executor and exact launch guard closure**

The guard closure must verify the exact expected role twice—once from the plan and once from the runtime candidate—then claim and persist `slot_reserved` before returning:

```powershell
$launchGuard = {
    param($runtimeCandidate, $command)
    Assert-CalibrationPilotRoleMatch -Expected $role -Candidate $runtimeCandidate -Command $command
    $claim = New-CalibrationPilotSlotClaim -Run $run -Role $role
    Set-CalibrationPilotAttemptState -Run $run -Ordinal $role.ordinal -State 'slot_reserved'
}.GetNewClosure()
```

The injected invoker signatures are:

```powershell
# Candidate
& $CandidateInvoker $resolved.candidate $prompt.request.request_text $launchGuard $RunId

# Judge; keep existing anonymized payload and existing default judge behavior
& $JudgeInvoker $judgeId $payload $prompt $launchGuard $RunId
```

When no fake is supplied, candidate execution calls `Invoke-PilotCandidate` directly with `-LaunchGuard`; the default judge path accepts and forwards the same guard to its existing `Invoke-PilotCandidate` call. No provider command construction is duplicated.

- [ ] **Step 4: Implement the fixed sequential flow**

`Invoke-CalibrationPilotRun` must execute in this exact order:

1. re-import/validate sources and compute plan;
2. require a safe explicit `RunId`;
3. require a clean Git worktree and capture `git rev-parse HEAD`;
4. create exclusive run and immutable `plan.json` including the commit;
5. candidate claim, process, normalization, and safe artifact persistence;
6. local `exact_fields` grader with no launch guard and no slot;
7. anonymized judge payload construction;
8. OpenAI judge claim, process, normalized decision, and persistence;
9. Anthropic judge claim, process, normalized decision, and persistence;
10. final technical state and separate quality outcome.

Do not start the next role until the prior role and `result.json` are durably persisted. Write only credential-sanitized candidate output to `raw/candidate-response.json` and normalized judge decisions to `raw/judge-responses.json`.

- [ ] **Step 5: Verify success and quality-negative paths**

```powershell
pwsh -NoProfile -File .\calibration\tests\calibration.tests.ps1
```

Expected: every fake execution makes exactly three ordered invocations; the local grader makes no launch claim; valid quality failures do not become technical failures.

- [ ] **Step 6: Commit Task 5**

```powershell
git add calibration/run_calibration.ps1 calibration/tests/calibration.tests.ps1
git commit -m "feat: orchestrate bounded option1 pilot"
```

## Task 6: Fail closed on technical, durability, and privacy uncertainty

**Files:**

- Modify: `calibration/run_calibration.ps1:329-429, pilot functions added in Tasks 3-5`
- Modify: `calibration/tests/calibration_security.tests.ps1:70-end`

- [ ] **Step 1: Add a table-driven RED security/failure suite**

Use injected fakes to cover candidate, Judge 1, and Judge 2 technical failures. For each role, assert the consumed claim count and that every later attempt is `skipped`. Cover allowlisted codes:

```powershell
$allowedStopCodes = @(
    'source_drift', 'repository_not_clean', 'authentication_failed', 'quota_failed',
    'unsupported_configuration', 'process_start_failed', 'timeout', 'cleanup_failed',
    'nonzero_exit', 'provider_envelope_invalid', 'response_contract_invalid',
    'artifact_persistence_failed', 'sensitive_output_detected', 'budget_invariant_failed',
    'manual_abort'
)
```

Also inject an artifact writer failure after a fake process reports `process_started = $true`; assert `run_state: indeterminate`, no later invoker call, and no resume with the same run ID.

Recursively scan `plan.json`, `result.json`, and raw artifacts and assert none contain test sentinels representing credentials, environment values, prompt-echo diagnostics, arguments, stderr, or exception text.

- [ ] **Step 2: Run the security suite and observe RED**

```powershell
pwsh -NoProfile -File .\calibration\tests\calibration_security.tests.ps1
```

- [ ] **Step 3: Normalize failures to safe codes and stop before later claims**

Add one allowlist conversion boundary:

```powershell
function Resolve-CalibrationPilotStopCode {
    param([AllowNull()][string]$Code)
    if ($Code -cin $script:CalibrationPilotAllowedStopCodes) { return $Code.ToLowerInvariant() }
    return 'provider_envelope_invalid'
}
```

Never persist `$_.Exception.Message`, arbitrary stdout/stderr, command arguments, environment objects, provider event streams, or prompt-bearing diagnostics. Use existing credential-safe copying only for the synthetic candidate answer and bounded normalized judge JSON.

Technical failure policy:

- before a claim: stop with zero additional slots;
- after claim but before confirmed process start: slot remains consumed and attempt is `failed`;
- after confirmed start with durable result update: stop and keep exact counters;
- after possible start when durability is uncertain: set `indeterminate`, skip all later roles, and forbid resume.

- [ ] **Step 4: Prove no production mutation or routing trace**

In the test, hash all `pilot/model_profiles/*.json`, `calibration/calibration-set-v1.json`, and relevant snapshots before/after a fake live run; assert equality. Use a temporary SQLite path or injected trace sentinel and assert no `routing_decisions` or `candidate_evaluations` write occurs.

- [ ] **Step 5: Run both calibration suites and confirm green**

```powershell
pwsh -NoProfile -File .\calibration\tests\calibration.tests.ps1
pwsh -NoProfile -File .\calibration\tests\calibration_security.tests.ps1
```

- [ ] **Step 6: Commit Task 6**

```powershell
git add calibration/run_calibration.ps1 calibration/tests/calibration_security.tests.ps1
git commit -m "test: harden option1 pilot failure boundaries"
```

## Task 7: Document the three launch paths and operator boundary

**Files:**

- Modify: `router/README.md:100-end`
- Modify: `calibration/tests/calibration.tests.ps1:end`

- [ ] **Step 1: Add a failing documentation contract test**

Read `router/README.md` and assert it contains both exact commands, all three exact route IDs, the maximum of three application launch slots, the unobservable provider-side-request caveat, no retry/fallback/resume, no profile promotion, and the separate explicit approval boundary.

- [ ] **Step 2: Run the calibration suite and observe RED**

```powershell
pwsh -NoProfile -File .\calibration\tests\calibration.tests.ps1
```

- [ ] **Step 3: Add the operator documentation**

Document these commands verbatim:

```powershell
# Offline validation and deterministic plan: zero provider launches and zero result writes
pwsh -NoProfile -File .\calibration\run_calibration.ps1 -Pilot

# Live only after explicit approval of the exact commit and identities
pwsh -NoProfile -File .\calibration\run_calibration.ps1 -Pilot -Run -RunId option1-example-001
```

Explain that the three paths are candidate execution, local deterministic grading, and two independent cross-family reviews; local grading is not a provider launch, so the successful technical path consumes three launcher slots total. Explain that launcher slots do not reveal provider-internal request/retry counts. State that stopped/indeterminate runs require a new run ID and new approval, and that results never promote production quality.

- [ ] **Step 4: Run the documentation contract and offline plan**

```powershell
pwsh -NoProfile -File .\calibration\tests\calibration.tests.ps1
pwsh -NoProfile -File .\calibration\run_calibration.ps1 -Pilot
```

- [ ] **Step 5: Commit Task 7**

```powershell
git add router/README.md calibration/tests/calibration.tests.ps1
git commit -m "docs: explain option1 three-launch pilot"
```

## Task 8: Run complete offline acceptance and review the exact diff

**Files:**

- Review: every file changed since `origin/main`
- Modify only if a verification failure proves a defect; use RED test first and a focused fix commit.

- [ ] **Step 1: Run the five authorized offline suites**

```powershell
pwsh -NoProfile -File .\pilot\tests\runner.tests.ps1
pwsh -NoProfile -File .\router\tests\router.tests.ps1
. .\router\lib\trace.ps1
$python = Resolve-RouterPythonExecutable
if ([string]::IsNullOrWhiteSpace($python)) { throw 'Python runtime not found.' }
& $python -m unittest router.storage.test_sqlite_store
pwsh -NoProfile -File .\calibration\tests\calibration.tests.ps1
pwsh -NoProfile -File .\calibration\tests\calibration_security.tests.ps1
```

Expected: all five commands exit 0. The known privilege-dependent symbolic-link assertion may report its documented skip; no provider process starts.

- [ ] **Step 2: Exercise the real offline CLI path**

```powershell
$before = @(Get-ChildItem .\calibration\results -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
$plan = pwsh -NoProfile -File .\calibration\run_calibration.ps1 -Pilot | ConvertFrom-Json -Depth 100
$after = @(Get-ChildItem .\calibration\results -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
if ($plan.provider_calls -ne 0 -or @($plan.roles).Count -ne 3) { throw 'Offline pilot plan contract failed.' }
if (Compare-Object $before $after) { throw 'Offline pilot wrote a result artifact.' }
```

- [ ] **Step 3: Inspect for placeholders, secrets, and unintended scope**

```powershell
rg -n "TODO|TBD|FIXME|PLACEHOLDER" calibration/pilots calibration/run_calibration.ps1 pilot/lib/runner.ps1 router/README.md
git diff --check origin/main...HEAD
git diff --stat origin/main...HEAD
git status --short --branch
```

Expected: placeholder scan has no hits in new implementation, `git diff --check` exits 0, changes remain inside the approved implementation/docs/setback surface, and the worktree is clean after final commits.

- [ ] **Step 4: Review policy invariants from the diff**

Confirm from `git diff origin/main...HEAD`:

- no profile quality value or production router policy changed;
- existing non-pilot modes are untouched except compatible parameter plumbing;
- no provider-specific command/parser was duplicated;
- no retry, fallback, substitution, resume, or fourth launch path exists;
- all result errors are allowlisted and bounded;
- every raw artifact is synthetic and sanitized; and
- no live result directory is committed.

- [ ] **Step 5: Commit any final verification-only correction, then rerun the affected focused suite and all five suites**

Use a descriptive commit tied to the proven defect. Do not squash or rewrite existing commits.

## Task 9: Prepare—but do not execute—the separately approved live acceptance

**Files:**

- No source modification expected.
- Runtime artifacts after approval only: `calibration/results/option1-live-20260825-001/`

- [ ] **Step 1: Stop and present the live acceptance packet to the user**

Report:

- exact clean commit from `git rev-parse HEAD`;
- manifest and plan hashes;
- the three exact ordered route/configuration identities;
- maximum three non-refundable application launch slots;
- `provider_side_requests.observable: false`;
- exact live command with one new safe run ID;
- all offline suite results; and
- stop conditions and zero retry/fallback/resume policy.

Do not run the command in this task without a new explicit approval that names this final packet.

- [ ] **Step 2: Only after that approval, run the one exact live command once**

```powershell
pwsh -NoProfile -File .\calibration\run_calibration.ps1 -Pilot -Run -RunId option1-live-20260825-001
```

Use this exact run ID only if it is the one included in the approved acceptance packet. Never repeat this command for the same run ID and never automatically launch a replacement after any failure.

- [ ] **Step 3: Inspect only the bounded acceptance evidence**

Verify claim count, exact role order, terminal state, process cleanup facts, sanitized artifacts, and non-promotion fields. Report technical and quality results separately. Do not infer provider-side request count and do not promote any quality field.
