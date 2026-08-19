$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $projectRoot

$runnerPath = Join-Path $projectRoot 'pilot/lib/runner.ps1'
if (Test-Path $runnerPath) {
    . $runnerPath
}

$failures = [System.Collections.Generic.List[string]]::new()

function Assert-Equal {
    param(
        [object]$Actual,
        [object]$Expected
    )

    if ($Actual -ne $Expected) {
        throw "Expected '$Expected' but got '$Actual'."
    }
}

function Assert-True {
    param([bool]$Condition)

    if (-not $Condition) {
        throw 'Expected condition to be true.'
    }
}

function Assert-Contains {
    param(
        [string]$Haystack,
        [string]$Needle
    )

    if (-not $Haystack.Contains($Needle)) {
        throw "Expected '$Haystack' to contain '$Needle'."
    }
}

function Assert-Throws {
    param([scriptblock]$Script)

    $threw = $false
    try {
        & $Script
    } catch {
        $threw = $true
    }

    if (-not $threw) {
        throw 'Expected script to throw.'
    }
}

function Invoke-Assertion {
    param(
        [string]$Name,
        [scriptblock]$Script
    )

    try {
        & $Script
        Write-Host "PASS $Name"
    } catch {
        $failures.Add("FAIL ${Name}: $($_.Exception.Message)")
    }
}

Invoke-Assertion 'New-RouteId normalizes route components' {
    Assert-Equal (New-RouteId -Tool 'codex' -Model 'gpt-5.6-sol' -Effort 'xhigh') 'codex__gpt_5_6_sol__xhigh'
}

Invoke-Assertion 'New-RouteId replaces punctuation in each route component' {
    $routeId = New-RouteId -Tool 'co-dex' -Model 'gpt.5/6' -Effort 'x-high'
    Assert-Contains $routeId 'co_dex'
    Assert-Contains $routeId 'gpt_5_6'
    Assert-Contains $routeId 'x_high'
}

Invoke-Assertion 'New-RouteId uses a stable default effort for Claude Haiku' {
    Assert-Equal (New-RouteId -Tool 'claude' -Model 'claude-haiku-4-5') 'claude__claude_haiku_4_5__default'
}

Invoke-Assertion 'New-RouteId uses a stable default effort for any model' {
    Assert-Equal (New-RouteId -Tool 'codex' -Model 'gpt-5.6-sol') 'codex__gpt_5_6_sol__default'
}

Invoke-Assertion 'ConvertFrom-CodexOutput reads the agent message envelope' {
    $codex = ConvertFrom-CodexOutput (Get-Content -Raw pilot/tests/fixtures/codex-success.jsonl)
    Assert-Equal $codex.status 'success'
    Assert-Equal $codex.answer '4'
    Assert-Equal $codex.error $null
}

Invoke-Assertion 'ConvertFrom-ClaudeOutput reads the result envelope' {
    $claude = ConvertFrom-ClaudeOutput (Get-Content -Raw pilot/tests/fixtures/claude-success.json)
    Assert-Equal $claude.status 'success'
    Assert-Equal $claude.answer '4'
    Assert-Equal $claude.error $null
}

Invoke-Assertion 'ConvertFrom-AgyOutput reads structured output' {
    $agy = ConvertFrom-AgyOutput (Get-Content -Raw pilot/tests/fixtures/agy-success.json)
    Assert-Equal $agy.status 'success'
    Assert-Equal $agy.answer '4'
    Assert-Equal $agy.error $null
}

Invoke-Assertion 'Test-CanonicalResponse rejects a non-string answer' {
    $invalid = Test-CanonicalResponse (Get-Content -Raw pilot/tests/fixtures/contract-type-failure.json | ConvertFrom-Json)
    Assert-True (-not $invalid.valid)
}

Invoke-Assertion 'Test-CanonicalResponse rejects a missing error property' {
    $invalid = [pscustomobject]@{ status = 'success'; answer = '4' }
    Assert-True (-not (Test-CanonicalResponse $invalid).valid)
}

Invoke-Assertion 'Test-CanonicalResponse rejects unexpected properties' {
    $invalid = [pscustomobject]@{ status = 'success'; answer = '4'; error = $null; extra = 'not allowed' }
    Assert-True (-not (Test-CanonicalResponse $invalid).valid)
}

Invoke-Assertion 'Test-CanonicalResponse rejects success with a non-null error' {
    $invalid = [pscustomobject]@{ status = 'success'; answer = '4'; error = 'unexpected error' }
    Assert-True (-not (Test-CanonicalResponse $invalid).valid)
}

Invoke-Assertion 'Test-CanonicalResponse rejects failure with a nonempty answer and null error' {
    $invalid = [pscustomobject]@{ status = 'failure'; answer = 'not empty'; error = $null }
    Assert-True (-not (Test-CanonicalResponse $invalid).valid)
}

Invoke-Assertion 'Test-CanonicalResponse rejects success with an empty answer' {
    $invalid = [pscustomobject]@{ status = 'success'; answer = ''; error = $null }
    Assert-True (-not (Test-CanonicalResponse $invalid).valid)
}

Invoke-Assertion 'Test-CandidateDefinition accepts a valid normal candidate' {
    $candidate = [pscustomobject]@{ route_id = 'codex__gpt_5_6_sol__xhigh'; tool = 'codex'; provider = 'openai'; model = 'gpt-5.6-sol'; effort = 'xhigh'; enabled = $true; candidate_kind = 'model'; instruction_file = 'pilot/providers/openai/AGENTS.md' }
    Assert-True (Test-CandidateDefinition $candidate).valid
}

Invoke-Assertion 'Test-CandidateMatrix rejects duplicate route IDs' {
    $first = [pscustomobject]@{ route_id = 'codex__gpt_5_6_sol__low'; tool = 'codex'; provider = 'openai'; model = 'gpt-5.6-sol'; effort = 'low'; enabled = $true; candidate_kind = 'model'; instruction_file = 'pilot/providers/openai/AGENTS.md' }
    $second = $first.PSObject.Copy()
    Assert-True (-not (Test-CandidateMatrix @($first, $second)).valid)
}

Invoke-Assertion 'Test-CandidateDefinition rejects unsupported effort' {
    $candidate = [pscustomobject]@{ route_id = 'codex__gpt_5_6_sol__extreme'; tool = 'codex'; provider = 'openai'; model = 'gpt-5.6-sol'; effort = 'extreme'; enabled = $true; candidate_kind = 'model'; instruction_file = 'pilot/providers/openai/AGENTS.md' }
    $result = Test-CandidateDefinition $candidate
    Assert-True (-not $result.valid)
    Assert-Contains $result.reason 'effort'
}

Invoke-Assertion 'Test-CandidateDefinition rejects missing model' {
    $candidate = [pscustomobject]@{ route_id = 'bad'; tool = 'codex'; provider = 'openai'; effort = 'low'; enabled = $true }
    $result = Test-CandidateDefinition $candidate
    Assert-True (-not $result.valid)
    Assert-Contains $result.reason 'model'
}

Invoke-Assertion 'Test-CandidateDefinition accepts disabled special route' {
    $candidate = [pscustomobject]@{ route_id = 'codex__codex_auto_review__low'; tool = 'codex'; provider = 'openai'; model = 'codex-auto-review'; effort = 'low'; enabled = $false; candidate_kind = 'special_route'; instruction_file = 'pilot/providers/openai/AGENTS.md' }
    Assert-True (Test-CandidateDefinition $candidate).valid
}

Invoke-Assertion 'Test-CandidateDefinition rejects enabled special route' {
    $candidate = [pscustomobject]@{ route_id = 'codex__codex_auto_review__low'; tool = 'codex'; provider = 'openai'; model = 'codex-auto-review'; effort = 'low'; enabled = $true; candidate_kind = 'special_route'; instruction_file = 'pilot/providers/openai/AGENTS.md' }
    $result = Test-CandidateDefinition $candidate
    Assert-True (-not $result.valid)
    Assert-Contains $result.reason 'disabled'
}

Invoke-Assertion 'Test-CandidateDefinition rejects string enabled values' {
    $candidate = [pscustomobject]@{ route_id = 'codex__gpt_5_6_sol__low'; tool = 'codex'; provider = 'openai'; model = 'gpt-5.6-sol'; effort = 'low'; enabled = 'false'; candidate_kind = 'model' }
    Assert-True (-not (Test-CandidateDefinition $candidate).valid)
}

Invoke-Assertion 'Test-CandidateDefinition rejects numeric enabled values' {
    $candidate = [pscustomobject]@{ route_id = 'codex__gpt_5_6_sol__low'; tool = 'codex'; provider = 'openai'; model = 'gpt-5.6-sol'; effort = 'low'; enabled = 1; candidate_kind = 'model' }
    Assert-True (-not (Test-CandidateDefinition $candidate).valid)
}

Invoke-Assertion 'Test-CandidateDefinition rejects missing candidate_kind' {
    $candidate = [pscustomobject]@{ route_id = 'missing-kind'; tool = 'codex'; provider = 'openai'; model = 'gpt-5.6-sol'; effort = 'low'; enabled = $true }
    Assert-True (-not (Test-CandidateDefinition $candidate).valid)
}

Invoke-Assertion 'Test-CandidateDefinition rejects invalid candidate_kind' {
    $candidate = [pscustomobject]@{ route_id = 'codex__gpt_5_6_sol__low'; tool = 'codex'; provider = 'openai'; model = 'gpt-5.6-sol'; effort = 'low'; enabled = $true; candidate_kind = 'other' }
    Assert-True (-not (Test-CandidateDefinition $candidate).valid)
}

Invoke-Assertion 'Test-CandidateDefinition rejects unexpected properties' {
    $candidate = [pscustomobject]@{ route_id = 'codex__gpt_5_6_sol__low'; tool = 'codex'; provider = 'openai'; model = 'gpt-5.6-sol'; effort = 'low'; enabled = $true; candidate_kind = 'model'; extra = 'not allowed' }
    Assert-True (-not (Test-CandidateDefinition $candidate).valid)
}

Invoke-Assertion 'Test-CandidateDefinition rejects Claude special route' {
    $candidate = [pscustomobject]@{ route_id = 'claude__claude_sonnet_5__medium'; tool = 'claude'; provider = 'anthropic'; model = 'claude-sonnet-5'; effort = 'medium'; enabled = $false; candidate_kind = 'special_route' }
    Assert-True (-not (Test-CandidateDefinition $candidate).valid)
}

Invoke-Assertion 'Test-CandidateDefinition rejects codex-auto-review marked as model' {
    $candidate = [pscustomobject]@{ route_id = 'codex__codex_auto_review__low'; tool = 'codex'; provider = 'openai'; model = 'codex-auto-review'; effort = 'low'; enabled = $false; candidate_kind = 'model' }
    Assert-True (-not (Test-CandidateDefinition $candidate).valid)
}

Invoke-Assertion 'Test-CandidateDefinition rejects enabled codex-auto-review' {
    $candidate = [pscustomobject]@{ route_id = 'codex__codex_auto_review__low'; tool = 'codex'; provider = 'openai'; model = 'codex-auto-review'; effort = 'low'; enabled = $true; candidate_kind = 'special_route' }
    Assert-True (-not (Test-CandidateDefinition $candidate).valid)
}

Invoke-Assertion 'Test-CandidateDefinition rejects mismatched tool provider and model' {
    $candidate = [pscustomobject]@{ route_id = 'codex__gpt_5_6_sol__medium'; tool = 'claude'; provider = 'openai'; model = 'gpt-5.6-sol'; effort = 'medium'; enabled = $true; candidate_kind = 'model' }
    Assert-True (-not (Test-CandidateDefinition $candidate).valid)
}

Invoke-Assertion 'Test-CandidateDefinition rejects ultra effort for gpt-5.6-luna' {
    $candidate = [pscustomobject]@{ route_id = 'codex__gpt_5_6_luna__ultra'; tool = 'codex'; provider = 'openai'; model = 'gpt-5.6-luna'; effort = 'ultra'; enabled = $true; candidate_kind = 'model' }
    Assert-True (-not (Test-CandidateDefinition $candidate).valid)
}

Invoke-Assertion 'Test-CandidateDefinition rejects a mismatched route ID' {
    $candidate = [pscustomobject]@{ route_id = 'codex__gpt_5_6_sol__low'; tool = 'codex'; provider = 'openai'; model = 'gpt-5.6-sol'; effort = 'high'; enabled = $true; candidate_kind = 'model' }
    Assert-True (-not (Test-CandidateDefinition $candidate).valid)
}

Invoke-Assertion 'Test-CandidateDefinition accepts instruction_file' {
    $candidate = [pscustomobject]@{ route_id = 'claude__claude_sonnet_5__medium'; tool = 'claude'; provider = 'anthropic'; model = 'claude-sonnet-5'; effort = 'medium'; enabled = $true; candidate_kind = 'model'; instruction_file = 'pilot/providers/anthropic/CLAUDE.md' }
    Assert-True (Test-CandidateDefinition $candidate).valid
}

Invoke-Assertion 'Test-CandidateDefinition rejects missing instruction_file' {
    $candidate = [pscustomobject]@{ route_id = 'codex__gpt_5_6_sol__medium'; tool = 'codex'; provider = 'openai'; model = 'gpt-5.6-sol'; effort = 'medium'; enabled = $true; candidate_kind = 'model' }
    Assert-True (-not (Test-CandidateDefinition $candidate).valid)
}

Invoke-Assertion 'Test-CandidateDefinition rejects nonexistent instruction_file' {
    $candidate = [pscustomobject]@{ route_id = 'codex__gpt_5_6_sol__medium'; tool = 'codex'; provider = 'openai'; model = 'gpt-5.6-sol'; effort = 'medium'; enabled = $true; candidate_kind = 'model'; instruction_file = 'pilot/providers/openai/missing-wrapper.md' }
    Assert-True (-not (Test-CandidateDefinition $candidate).valid)
}

Invoke-Assertion 'Test-CandidateDefinition accepts an existing wrapper instruction_file' {
    $candidate = [pscustomobject]@{ route_id = 'codex__gpt_5_6_sol__medium'; tool = 'codex'; provider = 'openai'; model = 'gpt-5.6-sol'; effort = 'medium'; enabled = $true; candidate_kind = 'model'; instruction_file = 'pilot/providers/openai/AGENTS.md' }
    Assert-True (Test-CandidateDefinition $candidate).valid
}

Invoke-Assertion 'Test-CandidateDefinition rejects a non-string route_id' {
    $candidate = [pscustomobject]@{ route_id = @('codex__gpt_5_6_sol__medium', 'extra'); tool = 'codex'; provider = 'openai'; model = 'gpt-5.6-sol'; effort = 'medium'; enabled = $true; candidate_kind = 'model'; instruction_file = 'pilot/providers/openai/AGENTS.md' }
    Assert-True (-not (Test-CandidateDefinition $candidate).valid)
}

Invoke-Assertion 'Resolve-RunnerInstructionFile accepts an existing wrapper file' {
    $resolved = Resolve-RunnerInstructionFile 'pilot/providers/openai/AGENTS.md'
    Assert-True ($null -ne $resolved -and -not $resolved.PSIsContainer)
}

Invoke-Assertion 'Resolve-RunnerInstructionFile rejects an external parent reparse target' {
    $externalTarget = [System.IO.Path]::GetFullPath((Join-Path $projectRoot '..\external-instruction-target'))
    Assert-True (-not (Test-RunnerResolvedTargetInsideRepository $externalTarget))
}

Invoke-Assertion 'Test-CandidateDefinition rejects arrays in every scalar field' {
    $base = [pscustomobject]@{ route_id = 'codex__gpt_5_6_sol__medium'; tool = 'codex'; provider = 'openai'; model = 'gpt-5.6-sol'; effort = 'medium'; enabled = $true; candidate_kind = 'model'; instruction_file = 'pilot/providers/openai/AGENTS.md' }
    foreach ($field in @('route_id', 'tool', 'provider', 'model', 'effort', 'candidate_kind', 'instruction_file')) {
        $candidate = $base.PSObject.Copy()
        $candidate.$field = @('not-scalar', 'extra')
        Assert-True (-not (Test-CandidateDefinition $candidate).valid)
    }
}

Invoke-Assertion 'Resolve-RunnerInstructionFile rejects a real external directory junction parent' {
    $token = [guid]::NewGuid().ToString('N')
    $outsideDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "runner-outside-$token"
    $junctionPath = Join-Path $projectRoot "pilot/tests/.runner-junction-$token"
    $outsideCreated = $false
    $junctionCreated = $false
    try {
        New-Item -ItemType Directory -Path $outsideDirectory -Force -ErrorAction Stop | Out-Null
        $outsideCreated = $true
        Set-Content -LiteralPath (Join-Path $outsideDirectory 'wrapper.md') -Value 'outside' -NoNewline -ErrorAction Stop
        if (Test-Path -LiteralPath $junctionPath) { throw "Refusing to use pre-existing test path '$junctionPath'." }
        try {
            New-Item -ItemType Junction -Path $junctionPath -Target $outsideDirectory -ErrorAction Stop | Out-Null
        } catch {
            Write-Host "SKIP real parent junction regression: $($_.Exception.Message)"
            Assert-True (-not (Test-RunnerResolvedTargetInsideRepository $outsideDirectory))
            return
        }
        $junctionCreated = $true
        $candidatePath = "pilot/tests/.runner-junction-$token/wrapper.md"
        Assert-Equal (Resolve-RunnerInstructionFile $candidatePath) $null
    } finally {
        if ($junctionCreated -and (Test-Path -LiteralPath $junctionPath)) {
            Remove-Item -LiteralPath $junctionPath -Force -ErrorAction SilentlyContinue
        }
        if ($outsideCreated -and (Test-Path -LiteralPath $outsideDirectory)) {
            Remove-Item -LiteralPath $outsideDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Invoke-Assertion 'Resolve-RunnerInstructionFile rejects a real external final-file symbolic link' {
    $token = [guid]::NewGuid().ToString('N')
    $outsideDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "runner-outside-$token"
    $outsideFile = Join-Path $outsideDirectory 'outside-wrapper.md'
    $linkPath = Join-Path $projectRoot "pilot/tests/.runner-file-link-$token.md"
    $outsideCreated = $false
    $linkCreated = $false
    try {
        New-Item -ItemType Directory -Path $outsideDirectory -Force -ErrorAction Stop | Out-Null
        $outsideCreated = $true
        Set-Content -LiteralPath $outsideFile -Value 'outside' -NoNewline -ErrorAction Stop
        if (Test-Path -LiteralPath $linkPath) { throw "Refusing to use pre-existing test path '$linkPath'." }
        try {
            New-Item -ItemType SymbolicLink -Path $linkPath -Target $outsideFile -ErrorAction Stop | Out-Null
        } catch {
            Write-Host "SKIP real final-file symbolic-link regression: $($_.Exception.Message)"
            Assert-True (-not (Test-RunnerResolvedTargetInsideRepository $outsideFile))
            return
        }
        $linkCreated = $true
        $relativeLink = "pilot/tests/.runner-file-link-$token.md"
        Assert-Equal (Resolve-RunnerInstructionFile $relativeLink) $null
    } finally {
        if ($linkCreated -and (Test-Path -LiteralPath $linkPath)) {
            Remove-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue
        }
        if ($outsideCreated -and (Test-Path -LiteralPath $outsideDirectory)) {
            Remove-Item -LiteralPath $outsideDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    exit 1
}

exit 0
