# Confirmed live pilot path (traced forward from pilot/run_pilot.ps1):
# Matrix load: Get-Content + ConvertFrom-Json (no reusable loader function) -> Invoke-PilotRun.
# Candidate load/selection: Select-PilotCandidates -> Test-CandidateMatrix -> Test-CandidateDefinition.
# One-candidate execution: Invoke-PilotRun -> New-PilotPrompt -> New-CandidateCommand -> Invoke-NativeCandidate.
# Provider normalization: ConvertFrom-CodexOutput / ConvertFrom-ClaudeOutput / ConvertFrom-AgyOutput -> Test-CanonicalResponse.
# Result construction/persistence: New-ResultRecord -> Add-PilotResultRecord.
# Reusable runner functions: Select-PilotCandidates, Test-CandidateMatrix, Test-CandidateDefinition,
# New-PilotPrompt, New-CandidateCommand, Invoke-NativeCandidate, ConvertFrom-CodexOutput,
# ConvertFrom-ClaudeOutput, ConvertFrom-AgyOutput, Test-CanonicalResponse, New-ResultRecord,
# Add-PilotResultRecord, and Invoke-PilotRun.
# Wished-for schema result: Test-RouterSchema returns
# [pscustomobject]@{ valid = [bool]; errors = @([pscustomobject]@{ code = [string]; path = [string] }) }.
# An omitted required property uses code 'required_property_missing' and an exact JSONPath such as '$.task_type'.
# Stable policy ties use ascending ordinal composite identity: launcher|configuration_id.

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $projectRoot

$schemaModulePath = Join-Path $projectRoot 'router/lib/schema.ps1'
$profilesModulePath = Join-Path $projectRoot 'router/lib/profiles.ps1'
$requirementsModulePath = Join-Path $projectRoot 'router/lib/requirements.ps1'
$qualityModulePath = Join-Path $projectRoot 'router/lib/quality.ps1'
$pricingModulePath = Join-Path $projectRoot 'router/lib/pricing.ps1'
$policyModulePath = Join-Path $projectRoot 'router/lib/policy.ps1'
$traceModulePath = Join-Path $projectRoot 'router/lib/trace.ps1'
$requestSchemaPath = Join-Path $projectRoot 'router/schemas/request-profile.schema.json'
$profileSchemaPath = Join-Path $projectRoot 'router/schemas/model-profile.schema.json'
$responseSchemaPath = Join-Path $projectRoot 'router/schemas/router-response.schema.json'
$profilesRoot = Join-Path $projectRoot 'profiles'
$matrixPath = Join-Path $projectRoot 'pilot/model_matrix.json'
$pricingSnapshotPath = Join-Path $projectRoot 'router/data/pricing-snapshot-2026-08-22.json'
$qualitySnapshotPath = Join-Path $projectRoot 'router/data/quality-snapshot-2026-08-22.json'
$tokenEstimatesPath = Join-Path $projectRoot 'router/tests/fixtures/token-estimates.json'

$schemaBoundary = [ordered]@{
    'schema module' = $schemaModulePath
    'request schema' = $requestSchemaPath
    'model profile schema' = $profileSchemaPath
    'router response schema' = $responseSchemaPath
}
$missingBoundary = @(
    foreach ($entry in $schemaBoundary.GetEnumerator()) {
        if (-not (Test-Path -LiteralPath $entry.Value -PathType Leaf)) {
            '{0} ({1})' -f $entry.Key, [System.IO.Path]::GetRelativePath($projectRoot, $entry.Value)
        }
    }
)

if ($missingBoundary.Count -gt 0) {
    [Console]::Error.WriteLine(
        'RED: router production boundary missing: {0}' -f ($missingBoundary -join '; ')
    )
    exit 1
}

. $schemaModulePath
$profilesAvailable = Test-Path -LiteralPath $profilesModulePath -PathType Leaf
if ($profilesAvailable) {
    . $profilesModulePath
}
$requirementsAvailable = Test-Path -LiteralPath $requirementsModulePath -PathType Leaf
if ($requirementsAvailable) {
    . $requirementsModulePath
}
$qualityAvailable = Test-Path -LiteralPath $qualityModulePath -PathType Leaf
if (-not $qualityAvailable) {
    [Console]::Error.WriteLine('RED: Task 5 quality module missing (router/lib/quality.ps1)')
    exit 1
}
. $qualityModulePath
$pricingAvailable = Test-Path -LiteralPath $pricingModulePath -PathType Leaf
if ($pricingAvailable) {
    . $pricingModulePath
}
$policyAvailable = Test-Path -LiteralPath $policyModulePath -PathType Leaf
if ($policyAvailable) {
    . $policyModulePath
}
$traceAvailable = Test-Path -LiteralPath $traceModulePath -PathType Leaf
if (-not $traceAvailable) {
    [Console]::Error.WriteLine('RED: Task 7 trace bridge missing (router/lib/trace.ps1)')
    exit 1
}
. $traceModulePath
$task4Assertions = {
Invoke-Assertion 'Task 4 requirements module is available' {
    Assert-Equal $requirementsAvailable $true
}

Invoke-Assertion 'requirements accept the English text single-turn V1 boundary with stable output shapes' {
    $result = Get-RouterRequirements -Request (New-MinimalRequest) -RequestSchemaPath $requestSchemaPath `
        -ProjectInstructions 'Follow the project conventions.' -OutputReserveTokens 512 `
        -LongContextThresholdTokens 100000

    Assert-Equal $result.valid $true
    Assert-Equal @($result.errors).Count 0
    Assert-SequenceEqual @($result.PSObject.Properties.Name) @('valid', 'errors', 'requirements')
    Assert-SequenceEqual @($result.requirements.PSObject.Properties.Name) @(
        'input_modalities'
        'output_modalities'
        'language'
        'single_turn'
        'privacy_level'
        'risk_level'
        'task_type'
        'domain'
        'complexity'
        'estimated_prompt_tokens'
        'estimated_project_instruction_tokens'
        'estimated_framing_tokens'
        'estimated_input_tokens'
        'output_reserve_tokens'
        'required_context_tokens'
        'long_context_threshold_tokens'
        'required_capabilities'
    )
    Assert-SequenceEqual @($result.requirements.input_modalities) @('text')
    Assert-SequenceEqual @($result.requirements.output_modalities) @('text')
    Assert-Equal $result.requirements.language 'english'
    Assert-Equal $result.requirements.single_turn $true
    Assert-Equal $result.requirements.privacy_level 'standard'
    Assert-Equal $result.requirements.risk_level 'standard'
    Assert-Equal $result.requirements.task_type 'coding'
    Assert-Equal $result.requirements.domain 'computer_science'
    Assert-Equal $result.requirements.complexity 'medium'
}

$requestBoundaryCases = @(
    [pscustomobject]@{
        name = 'sensitive requests'
        property = 'privacy_level'
        value = 'sensitive'
        code = 'sensitive_request_unsupported'
        path = '$.privacy_level'
    }
    [pscustomobject]@{
        name = 'high-stakes requests'
        property = 'risk_level'
        value = 'high_stakes'
        code = 'high_stakes_unsupported'
        path = '$.risk_level'
    }
)
foreach ($boundaryCase in $requestBoundaryCases) {
    Invoke-Assertion ("requirements preserve exact schema diagnostics for {0}" -f $boundaryCase.name) {
        $request = New-MinimalRequest
        $request.($boundaryCase.property) = $boundaryCase.value
        $result = Get-RouterRequirements -Request $request -RequestSchemaPath $requestSchemaPath `
            -ProjectInstructions '' -OutputReserveTokens 128 -LongContextThresholdTokens 100000

        Assert-ValidationErrorsExactly -Validation $result -ExpectedErrors @(
            [pscustomobject]@{ code = $boundaryCase.code; path = $boundaryCase.path }
        )
        Assert-Equal $result.requirements $null
    }
}

Invoke-Assertion 'context estimation uses the complete prompt project instructions and output reserve' {
    $estimate = Get-RouterContextEstimate -PromptText 'abcd' -ProjectInstructions 'ef' -OutputReserveTokens 3
    $composedPrompt = @(
        '=== Project instructions ==='
        'ef'
        '=== Request ==='
        'abcd'
    ) -join "`n`n"
    $expectedInputBytes = [Text.Encoding]::UTF8.GetByteCount($composedPrompt)
    $expectedFramingBytes = $expectedInputBytes - 6

    Assert-SequenceEqual @($estimate.PSObject.Properties.Name) @(
        'estimated_prompt_tokens'
        'estimated_project_instruction_tokens'
        'estimated_framing_tokens'
        'estimated_input_tokens'
        'output_reserve_tokens'
        'required_context_tokens'
    )
    Assert-Equal $estimate.estimated_prompt_tokens 4
    Assert-Equal $estimate.estimated_project_instruction_tokens 2
    Assert-Equal $estimate.estimated_framing_tokens $expectedFramingBytes
    Assert-Equal $estimate.estimated_input_tokens $expectedInputBytes
    Assert-Equal $estimate.output_reserve_tokens 3
    Assert-Equal $estimate.required_context_tokens ($expectedInputBytes + 3)
}

Invoke-Assertion 'context estimation counts the complete UTF-8 envelope for non-ASCII input' {
    $promptText = 'café'
    $projectInstructions = '指示'
    $estimate = Get-RouterContextEstimate -PromptText $promptText `
        -ProjectInstructions $projectInstructions -OutputReserveTokens 0
    $composedPrompt = @(
        '=== Project instructions ==='
        $projectInstructions
        '=== Request ==='
        $promptText
    ) -join "`n`n"
    $promptBytes = [Text.Encoding]::UTF8.GetByteCount($promptText)
    $instructionBytes = [Text.Encoding]::UTF8.GetByteCount($projectInstructions)
    $inputBytes = [Text.Encoding]::UTF8.GetByteCount($composedPrompt)

    Assert-Equal $estimate.estimated_prompt_tokens $promptBytes
    Assert-Equal $estimate.estimated_project_instruction_tokens $instructionBytes
    Assert-Equal $estimate.estimated_framing_tokens ($inputBytes - $promptBytes - $instructionBytes)
    Assert-Equal $estimate.estimated_input_tokens $inputBytes
    Assert-Equal $estimate.required_context_tokens $inputBytes
}

Invoke-Assertion 'context estimation accepts the Int64 boundary and rejects overflow deterministically' {
    $promptText = 'x'
    $projectInstructions = ''
    $composedPrompt = @(
        '=== Project instructions ==='
        $projectInstructions
        '=== Request ==='
        $promptText
    ) -join "`n`n"
    [long]$inputBytes = [Text.Encoding]::UTF8.GetByteCount($composedPrompt)
    [long]$exactReserve = [long]::MaxValue - $inputBytes

    $exact = Get-RouterContextEstimate -PromptText $promptText `
        -ProjectInstructions $projectInstructions -OutputReserveTokens $exactReserve
    Assert-Equal $exact.required_context_tokens ([long]::MaxValue)

    $overflowed = $false
    $overflowMessage = $null
    try {
        $null = Get-RouterContextEstimate -PromptText $promptText `
            -ProjectInstructions $projectInstructions -OutputReserveTokens ($exactReserve + 1)
    } catch {
        $overflowed = $true
        $overflowMessage = $_.Exception.Message
    }
    Assert-Equal $overflowed $true
    Assert-Equal $overflowMessage 'The calculated context requirement exceeds the supported integer range.'
}

$capabilityCases = @(
    [pscustomobject]@{ name = 'general'; task = 'general'; domain = 'general'; complexity = 'low'; threshold = 100000; expected = @('instruction_following') }
    [pscustomobject]@{ name = 'low-complexity coding'; task = 'coding'; domain = 'general'; complexity = 'low'; threshold = 100000; expected = @('instruction_following') }
    [pscustomobject]@{ name = 'medium-complexity coding'; task = 'coding'; domain = 'general'; complexity = 'medium'; threshold = 100000; expected = @('instruction_following', 'reasoning') }
    [pscustomobject]@{ name = 'high-complexity coding'; task = 'coding'; domain = 'general'; complexity = 'high'; threshold = 100000; expected = @('instruction_following', 'reasoning') }
    [pscustomobject]@{ name = 'math'; task = 'math'; domain = 'general'; complexity = 'low'; threshold = 100000; expected = @('instruction_following', 'reasoning') }
    [pscustomobject]@{ name = 'reasoning'; task = 'reasoning'; domain = 'general'; complexity = 'low'; threshold = 100000; expected = @('instruction_following', 'reasoning') }
    [pscustomobject]@{ name = 'writing'; task = 'writing'; domain = 'general'; complexity = 'low'; threshold = 100000; expected = @('instruction_following') }
    [pscustomobject]@{ name = 'extraction'; task = 'extraction'; domain = 'general'; complexity = 'low'; threshold = 100000; expected = @('instruction_following', 'structured_output') }
    [pscustomobject]@{ name = 'summarization'; task = 'summarization'; domain = 'general'; complexity = 'low'; threshold = 100000; expected = @('instruction_following', 'factual_reliability') }
    [pscustomobject]@{ name = 'research synthesis'; task = 'research_synthesis'; domain = 'general'; complexity = 'low'; threshold = 100000; expected = @('instruction_following', 'factual_reliability', 'source_grounded_synthesis') }
    [pscustomobject]@{ name = 'non-general domain'; task = 'general'; domain = 'finance'; complexity = 'low'; threshold = 100000; expected = @('instruction_following', 'factual_reliability') }
    [pscustomobject]@{ name = 'long context'; task = 'general'; domain = 'general'; complexity = 'low'; threshold = 1; expected = @('instruction_following', 'long_context') }
)
foreach ($capabilityCase in $capabilityCases) {
    Invoke-Assertion ("capability derivation covers {0}" -f $capabilityCase.name) {
        $request = New-MinimalRequest
        $request.request_text = 'Explain this.'
        $request.task_type = $capabilityCase.task
        $request.domain = $capabilityCase.domain
        $request.complexity = $capabilityCase.complexity
        $request.additional_capabilities = @()
        $result = Get-RouterRequirements -Request $request -RequestSchemaPath $requestSchemaPath `
            -ProjectInstructions '' -OutputReserveTokens 0 `
            -LongContextThresholdTokens $capabilityCase.threshold

        Assert-Equal $result.valid $true
        Assert-SequenceEqual @($result.requirements.required_capabilities) @($capabilityCase.expected)
    }
}

Invoke-Assertion 'explicit additional capabilities form a canonical de-duplicated union' {
    $request = New-MinimalRequest
    $request.task_type = 'extraction'
    $request.domain = 'general'
    $request.complexity = 'low'
    $request.additional_capabilities = @('factual_reliability', 'reasoning', 'instruction_following')
    $result = Get-RouterRequirements -Request $request -RequestSchemaPath $requestSchemaPath `
        -ProjectInstructions '' -OutputReserveTokens 0 -LongContextThresholdTokens 100000

    Assert-Equal $result.valid $true
    Assert-SequenceEqual @($result.requirements.required_capabilities) @(
        'instruction_following'
        'reasoning'
        'structured_output'
        'factual_reliability'
    )
}

$candidateFailureCases = @(
    [pscustomobject]@{ name = 'disabled profile'; code = 'candidate_disabled'; mutate = { param($candidate, $runtime, $requirements) $candidate.enabled = $false } }
    [pscustomobject]@{ name = 'unavailable profile'; code = 'candidate_unavailable'; mutate = { param($candidate, $runtime, $requirements) $candidate.availability = 'unavailable' } }
    [pscustomobject]@{ name = 'launcher identity mismatch'; code = 'runtime_identity_mismatch'; mutate = { param($candidate, $runtime, $requirements) $runtime.launcher = 'codex' } }
    [pscustomobject]@{ name = 'model identity mismatch'; code = 'runtime_identity_mismatch'; mutate = { param($candidate, $runtime, $requirements) $runtime.model = 'different-model' } }
    [pscustomobject]@{ name = 'effort identity mismatch'; code = 'runtime_identity_mismatch'; mutate = { param($candidate, $runtime, $requirements) $runtime.effort = 'high' } }
    [pscustomobject]@{ name = 'unavailable launcher'; code = 'launcher_unavailable'; mutate = { param($candidate, $runtime, $requirements) $runtime.available = $false } }
    [pscustomobject]@{ name = 'unauthenticated launcher'; code = 'launcher_unauthenticated'; mutate = { param($candidate, $runtime, $requirements) $runtime.authenticated = $false } }
    [pscustomobject]@{ name = 'unhealthy launcher'; code = 'launcher_unhealthy'; mutate = { param($candidate, $runtime, $requirements) $runtime.working = $false } }
    [pscustomobject]@{ name = 'quota-exhausted launcher'; code = 'quota_exhausted'; mutate = { param($candidate, $runtime, $requirements) $runtime.quota_exhausted = $true } }
    [pscustomobject]@{ name = 'unsupported text input'; code = 'text_input_unsupported'; mutate = { param($candidate, $runtime, $requirements) $candidate.supports.input_modalities = @('image') } }
    [pscustomobject]@{ name = 'unsupported text output'; code = 'text_output_unsupported'; mutate = { param($candidate, $runtime, $requirements) $candidate.supports.output_modalities = @('image') } }
    [pscustomobject]@{ name = 'unsupported English'; code = 'english_unsupported'; mutate = { param($candidate, $runtime, $requirements) $candidate.supports.languages = @('french') } }
    [pscustomobject]@{ name = 'unsupported single turn'; code = 'single_turn_unsupported'; mutate = { param($candidate, $runtime, $requirements) $candidate.supports.single_turn = $false } }
    [pscustomobject]@{ name = 'context window overflow'; code = 'context_window_exceeded'; mutate = { param($candidate, $runtime, $requirements) $candidate.supports.context_window_tokens = $requirements.required_context_tokens - 1 } }
    [pscustomobject]@{ name = 'output window overflow'; code = 'output_window_exceeded'; mutate = { param($candidate, $runtime, $requirements) $candidate.supports.maximum_output_tokens = $requirements.output_reserve_tokens - 1 } }
    [pscustomobject]@{ name = 'unsupported required capability'; code = 'required_capability_unavailable'; mutate = { param($candidate, $runtime, $requirements) $candidate.quality.capabilities.reasoning = 'unsupported' } }
)

$candidateRequirements = [pscustomobject]@{
    input_modalities = @('text')
    output_modalities = @('text')
    language = 'english'
    single_turn = $true
    privacy_level = 'standard'
    risk_level = 'standard'
    task_type = 'coding'
    domain = 'computer_science'
    complexity = 'medium'
    estimated_prompt_tokens = 768
    estimated_project_instruction_tokens = 128
    estimated_framing_tokens = 0
    estimated_input_tokens = 896
    output_reserve_tokens = 128
    required_context_tokens = 1024
    long_context_threshold_tokens = 100000
    required_capabilities = @('instruction_following', 'reasoning', 'factual_reliability')
}

Invoke-Assertion 'candidate context gating includes framing and honors exact and one-byte boundaries' {
    $requirementsResult = Get-RouterRequirements -Request (New-MinimalRequest) `
        -RequestSchemaPath $requestSchemaPath -ProjectInstructions 'Use project rules.' `
        -OutputReserveTokens 128 -LongContextThresholdTokens 100000
    $candidate = Copy-TestObject @(Get-MinimalProfiles)[0]
    $runtime = New-MinimalRuntimeState
    $rawFieldsOnlyWindow = $requirementsResult.requirements.estimated_prompt_tokens +
        $requirementsResult.requirements.estimated_project_instruction_tokens +
        $requirementsResult.requirements.output_reserve_tokens

    $candidate.supports.context_window_tokens = $rawFieldsOnlyWindow
    $rawOnlyEvaluation = Test-RouterCandidateRequirements -Candidate $candidate `
        -Requirements $requirementsResult.requirements -RuntimeState $runtime
    Assert-Equal $rawOnlyEvaluation.passed $false
    Assert-SequenceEqual @($rawOnlyEvaluation.reason_codes) @('context_window_exceeded')

    $candidate.supports.context_window_tokens = $requirementsResult.requirements.required_context_tokens
    $exactEvaluation = Test-RouterCandidateRequirements -Candidate $candidate `
        -Requirements $requirementsResult.requirements -RuntimeState $runtime
    Assert-Equal $exactEvaluation.passed $true

    $candidate.supports.context_window_tokens = $requirementsResult.requirements.required_context_tokens - 1
    $oneByteOverEvaluation = Test-RouterCandidateRequirements -Candidate $candidate `
        -Requirements $requirementsResult.requirements -RuntimeState $runtime
    Assert-Equal $oneByteOverEvaluation.passed $false
    Assert-SequenceEqual @($oneByteOverEvaluation.reason_codes) @('context_window_exceeded')
}

$unusablePriceCases = @(
    [pscustomobject]@{ name = 'false cost comparability'; mutate = { param($candidate) $candidate.pricing.cost_comparable = $false } }
    [pscustomobject]@{ name = 'string cost comparability'; mutate = { param($candidate) $candidate.pricing.cost_comparable = 'true' } }
    [pscustomobject]@{ name = 'missing cost comparability'; mutate = { param($candidate) $candidate.pricing.PSObject.Properties.Remove('cost_comparable') } }
    [pscustomobject]@{ name = 'null input rate'; mutate = { param($candidate) $candidate.pricing.input_usd_per_million_tokens = $null } }
    [pscustomobject]@{ name = 'missing input rate'; mutate = { param($candidate) $candidate.pricing.PSObject.Properties.Remove('input_usd_per_million_tokens') } }
    [pscustomobject]@{ name = 'string input rate'; mutate = { param($candidate) $candidate.pricing.input_usd_per_million_tokens = '1.0' } }
    [pscustomobject]@{ name = 'negative input rate'; mutate = { param($candidate) $candidate.pricing.input_usd_per_million_tokens = -0.01 } }
    [pscustomobject]@{ name = 'non-finite input rate'; mutate = { param($candidate) $candidate.pricing.input_usd_per_million_tokens = [double]::NaN } }
    [pscustomobject]@{ name = 'null output rate'; mutate = { param($candidate) $candidate.pricing.output_usd_per_million_tokens = $null } }
    [pscustomobject]@{ name = 'missing output rate'; mutate = { param($candidate) $candidate.pricing.PSObject.Properties.Remove('output_usd_per_million_tokens') } }
    [pscustomobject]@{ name = 'boolean output rate'; mutate = { param($candidate) $candidate.pricing.output_usd_per_million_tokens = $true } }
    [pscustomobject]@{ name = 'non-finite output rate'; mutate = { param($candidate) $candidate.pricing.output_usd_per_million_tokens = [double]::PositiveInfinity } }
)
foreach ($priceCase in $unusablePriceCases) {
    Invoke-Assertion ("candidate requirements reject {0}" -f $priceCase.name) {
        Set-StrictMode -Version Latest
        $candidate = Copy-TestObject @(Get-MinimalProfiles)[0]
        & $priceCase.mutate $candidate
        $evaluation = Test-RouterCandidateRequirements -Candidate $candidate `
            -Requirements $candidateRequirements -RuntimeState (New-MinimalRuntimeState)

        Assert-Equal $evaluation.passed $false
        Assert-SequenceEqual @($evaluation.reason_codes) @('price_unavailable')
    }
}

Invoke-Assertion 'candidate requirements accept finite nonnegative comparable rates' {
    $candidate = Copy-TestObject @(Get-MinimalProfiles)[0]
    $candidate.pricing.cost_comparable = $true
    $candidate.pricing.input_usd_per_million_tokens = [decimal]0
    $candidate.pricing.output_usd_per_million_tokens = [double]0
    $evaluation = Test-RouterCandidateRequirements -Candidate $candidate `
        -Requirements $candidateRequirements -RuntimeState (New-MinimalRuntimeState)

    Assert-Equal $evaluation.passed $true
    Assert-Equal @($evaluation.reason_codes).Count 0
}

Invoke-Assertion 'candidate requirements reject the checked-in non-comparable Spark profile' {
    $candidatePath = Join-Path $profilesRoot 'codex/gpt-5.3-codex-spark__medium.json'
    $candidate = Get-Content -Raw -LiteralPath $candidatePath | ConvertFrom-Json -Depth 30
    $runtime = [pscustomobject]@{
        launcher = $candidate.launcher
        model = $candidate.model
        effort = $candidate.effort
        available = $true
        authenticated = $true
        working = $true
        quota_exhausted = $false
    }
    $evaluation = Test-RouterCandidateRequirements -Candidate $candidate `
        -Requirements $candidateRequirements -RuntimeState $runtime

    Assert-Equal $evaluation.candidate_identity 'codex|gpt-5.3-codex-spark__medium'
    Assert-Equal $evaluation.passed $false
    Assert-SequenceEqual @($evaluation.reason_codes) @('price_unavailable')
}

$requiredRuntimeProperties = @(
    'launcher'
    'model'
    'effort'
    'available'
    'authenticated'
    'working'
    'quota_exhausted'
)
foreach ($propertyName in $requiredRuntimeProperties) {
    Invoke-Assertion ("candidate requirements fail closed when runtime state omits {0}" -f $propertyName) {
        Set-StrictMode -Version Latest
        $runtime = New-MinimalRuntimeState
        $runtime.PSObject.Properties.Remove($propertyName)
        $evaluation = Test-RouterCandidateRequirements -Candidate (Copy-TestObject @(Get-MinimalProfiles)[0]) `
            -Requirements $candidateRequirements -RuntimeState $runtime

        Assert-SequenceEqual @($evaluation.PSObject.Properties.Name) @(
            'candidate_identity'
            'passed'
            'reason_codes'
            'unavailable_capabilities'
            'unsupported_requirements'
        )
        Assert-Equal $evaluation.passed $false
        Assert-SequenceEqual @($evaluation.reason_codes) @('runtime_state_invalid')
        Assert-Equal @($evaluation.unavailable_capabilities).Count 0
        Assert-Equal @($evaluation.unsupported_requirements).Count 0
    }
}

$wrongRuntimeTypeCases = @(
    [pscustomobject]@{ property = 'launcher'; value = 123 }
    [pscustomobject]@{ property = 'model'; value = 123 }
    [pscustomobject]@{ property = 'effort'; value = 123 }
    [pscustomobject]@{ property = 'available'; value = 'true' }
    [pscustomobject]@{ property = 'authenticated'; value = 1 }
    [pscustomobject]@{ property = 'working'; value = 'false' }
    [pscustomobject]@{ property = 'quota_exhausted'; value = 0 }
)
foreach ($runtimeTypeCase in $wrongRuntimeTypeCases) {
    Invoke-Assertion ("candidate requirements fail closed when runtime {0} has the wrong type" -f $runtimeTypeCase.property) {
        Set-StrictMode -Version Latest
        $runtime = New-MinimalRuntimeState
        $runtime.($runtimeTypeCase.property) = $runtimeTypeCase.value
        $evaluation = Test-RouterCandidateRequirements -Candidate (Copy-TestObject @(Get-MinimalProfiles)[0]) `
            -Requirements $candidateRequirements -RuntimeState $runtime

        Assert-Equal $evaluation.passed $false
        Assert-SequenceEqual @($evaluation.reason_codes) @('runtime_state_invalid')
    }
}

Invoke-Assertion 'candidate requirements do not coerce numeric-looking runtime identity values' {
    Set-StrictMode -Version Latest
    $candidate = Copy-TestObject @(Get-MinimalProfiles)[0]
    $candidate.model = '123'
    $runtime = New-MinimalRuntimeState
    $runtime.model = 123
    $evaluation = Test-RouterCandidateRequirements -Candidate $candidate `
        -Requirements $candidateRequirements -RuntimeState $runtime

    Assert-Equal $evaluation.passed $false
    Assert-SequenceEqual @($evaluation.reason_codes) @('runtime_state_invalid')
}

foreach ($malformedRuntime in @($null, 'not-a-runtime-object')) {
    $malformedRuntimeName = if ($null -eq $malformedRuntime) { 'null' } else { 'scalar' }
    Invoke-Assertion ("candidate requirements return a stable failure for {0} runtime state" -f $malformedRuntimeName) {
        Set-StrictMode -Version Latest
        $evaluation = Test-RouterCandidateRequirements -Candidate (Copy-TestObject @(Get-MinimalProfiles)[0]) `
            -Requirements $candidateRequirements -RuntimeState $malformedRuntime

        Assert-Equal $evaluation.passed $false
        Assert-SequenceEqual @($evaluation.reason_codes) @('runtime_state_invalid')
    }
}
foreach ($candidateCase in $candidateFailureCases) {
    Invoke-Assertion ("candidate requirements reject {0}" -f $candidateCase.name) {
        $candidate = Copy-TestObject @(Get-MinimalProfiles)[0]
        $runtime = New-MinimalRuntimeState
        & $candidateCase.mutate $candidate $runtime $candidateRequirements
        $evaluation = Test-RouterCandidateRequirements -Candidate $candidate `
            -Requirements $candidateRequirements -RuntimeState $runtime

        Assert-Equal $evaluation.passed $false
        Assert-SequenceEqual @($evaluation.reason_codes) @($candidateCase.code)
        if ($candidateCase.code -ceq 'required_capability_unavailable') {
            Assert-SequenceEqual @($evaluation.unavailable_capabilities) @('reasoning')
        }
    }
}

Invoke-Assertion 'candidate requirement reasons retain canonical ordering when failures accumulate' {
    $candidate = Copy-TestObject @(Get-MinimalProfiles)[0]
    $candidate.enabled = $false
    $candidate.availability = 'unavailable'
    $candidate.supports.input_modalities = @('image')
    $candidate.supports.output_modalities = @('image')
    $candidate.supports.languages = @('french')
    $candidate.supports.single_turn = $false
    $candidate.supports.context_window_tokens = $candidateRequirements.required_context_tokens - 1
    $candidate.supports.maximum_output_tokens = $candidateRequirements.output_reserve_tokens - 1
    $candidate.pricing.cost_comparable = $false
    $candidate.quality.task_types.coding = 'unsupported'
    $candidate.quality.capabilities.reasoning = 'unsupported'
    $runtime = New-MinimalRuntimeState
    $runtime.available = $false
    $runtime.authenticated = $false
    $runtime.working = $false
    $runtime.quota_exhausted = $true

    $evaluation = Test-RouterCandidateRequirements -Candidate $candidate `
        -Requirements $candidateRequirements -RuntimeState $runtime

    Assert-SequenceEqual @($evaluation.reason_codes) @(
        'candidate_disabled'
        'candidate_unavailable'
        'launcher_unavailable'
        'launcher_unauthenticated'
        'launcher_unhealthy'
        'quota_exhausted'
        'text_input_unsupported'
        'text_output_unsupported'
        'english_unsupported'
        'single_turn_unsupported'
        'context_window_exceeded'
        'output_window_exceeded'
        'price_unavailable'
        'required_function_unsupported'
        'required_capability_unavailable'
    )
    Assert-SequenceEqual @($evaluation.unavailable_capabilities) @('reasoning')
}

$unsupportedDimensionCases = @(
    [pscustomobject]@{
        name = 'requested task type'
        profile_map = 'task_types'
        dimension = 'task_type'
        value = 'coding'
        profile_path = 'quality.task_types.coding'
    }
    [pscustomobject]@{
        name = 'requested domain'
        profile_map = 'domains'
        dimension = 'domain'
        value = 'computer_science'
        profile_path = 'quality.domains.computer_science'
    }
    [pscustomobject]@{
        name = 'requested complexity'
        profile_map = 'complexities'
        dimension = 'complexity'
        value = 'medium'
        profile_path = 'quality.complexities.medium'
    }
)
foreach ($dimensionCase in $unsupportedDimensionCases) {
    Invoke-Assertion ("candidate requirements hard-fail unsupported {0}" -f $dimensionCase.name) {
        $candidate = Copy-TestObject @(Get-MinimalProfiles)[0]
        $candidate.quality.($dimensionCase.profile_map).($dimensionCase.value) = 'unsupported'
        $evaluation = Test-RouterCandidateRequirements -Candidate $candidate `
            -Requirements $candidateRequirements -RuntimeState (New-MinimalRuntimeState)

        Assert-Equal $evaluation.passed $false
        Assert-SequenceEqual @($evaluation.reason_codes) @('required_function_unsupported')
        Assert-Equal @($evaluation.unsupported_requirements).Count 1
        Assert-SequenceEqual @($evaluation.unsupported_requirements[0].PSObject.Properties.Name) @(
            'dimension'
            'value'
            'profile_path'
        )
        Assert-Equal $evaluation.unsupported_requirements[0].dimension $dimensionCase.dimension
        Assert-Equal $evaluation.unsupported_requirements[0].value $dimensionCase.value
        Assert-Equal $evaluation.unsupported_requirements[0].profile_path $dimensionCase.profile_path
        Assert-Equal @($evaluation.unavailable_capabilities).Count 0
    }
}

foreach ($dimensionCase in $unsupportedDimensionCases) {
    Invoke-Assertion ("unknown {0} remains deferred to Task 5" -f $dimensionCase.name) {
        $candidate = Copy-TestObject @(Get-MinimalProfiles)[0]
        $candidate.quality.($dimensionCase.profile_map).($dimensionCase.value) = 'unknown'
        $evaluation = Test-RouterCandidateRequirements -Candidate $candidate `
            -Requirements $candidateRequirements -RuntimeState (New-MinimalRuntimeState)

        Assert-Equal $evaluation.passed $true
        Assert-Equal @($evaluation.reason_codes).Count 0
        Assert-Equal @($evaluation.unsupported_requirements).Count 0
    }
}

Invoke-Assertion 'unknown capability quality is deferred and is not a hard-requirement failure' {
    $candidate = Copy-TestObject @(Get-MinimalProfiles)[0]
    $candidate.quality.capabilities.reasoning = 'unknown'
    $evaluation = Test-RouterCandidateRequirements -Candidate $candidate `
        -Requirements $candidateRequirements -RuntimeState (New-MinimalRuntimeState)

    Assert-Equal $evaluation.passed $true
    Assert-Equal @($evaluation.reason_codes).Count 0
    Assert-Equal @($evaluation.unavailable_capabilities).Count 0
}

Invoke-Assertion 'a slow candidate passes because latency is absent from requirement evaluation' {
    $candidate = Copy-TestObject @(Get-MinimalProfiles)[0]
    $candidate.latency_observation.available = $true
    $candidate.latency_observation.milliseconds = 86400000
    $evaluation = Test-RouterCandidateRequirements -Candidate $candidate `
        -Requirements $candidateRequirements -RuntimeState (New-MinimalRuntimeState)

    Assert-SequenceEqual @($evaluation.PSObject.Properties.Name) @(
        'candidate_identity'
        'passed'
        'reason_codes'
        'unavailable_capabilities'
        'unsupported_requirements'
    )
    Assert-Equal $evaluation.candidate_identity 'agy|shared-model__medium'
    Assert-Equal $evaluation.passed $true
    Assert-Equal @($evaluation.reason_codes).Count 0
}
}

if ($policyAvailable) {
    . $policyModulePath
}

$failures = [System.Collections.Generic.List[string]]::new()
$requiredQualityKeys = [ordered]@{
    task_types = @('general', 'coding', 'math', 'reasoning', 'writing', 'summarization', 'extraction', 'research_synthesis')
    domains = @('general', 'computer_science', 'mathematics', 'physics', 'chemistry', 'biology', 'medicine', 'engineering', 'social_science', 'humanities', 'business', 'finance', 'law')
    complexities = @('low', 'medium', 'high')
    capabilities = @('instruction_following', 'reasoning', 'structured_output', 'factual_reliability', 'source_grounded_synthesis', 'long_context')
}
$requestEnums = [ordered]@{
    task_type = @('general', 'coding', 'math', 'reasoning', 'writing', 'summarization', 'extraction', 'research_synthesis')
    domain = @('general', 'computer_science', 'mathematics', 'physics', 'chemistry', 'biology', 'medicine', 'engineering', 'social_science', 'humanities', 'business', 'finance', 'law')
    complexity = @('low', 'medium', 'high')
    quality_floor = @('standard', 'strong', 'frontier')
    latency = @('fast', 'normal', 'relaxed')
    output_length = @('short', 'normal', 'detailed')
}
$qualityCategories = @('unsupported', 'unknown', 'standard', 'strong', 'frontier')
$responseStatuses = @('completed', 'invalid_request', 'unsupported_request', 'no_eligible_configuration', 'execution_failed')
$failureStatuses = @('invalid_request', 'unsupported_request', 'no_eligible_configuration', 'execution_failed')
$reasonCodes = @(
    'unsupported_language'
    'unsupported_modality'
    'sensitive_request_unsupported'
    'high_stakes_unsupported'
    'context_too_large'
    'required_capability_unavailable'
    'quality_floor_not_met'
    'quality_evidence_unknown'
    'all_routes_unavailable'
    'launcher_execution_failed'
)
$requiredRequestPaths = @(
    '$.request_text'
    '$.task_type'
    '$.domain'
    '$.complexity'
    '$.quality_floor'
    '$.privacy_level'
    '$.risk_level'
    '$.language'
)
$requiredProfilePaths = @(
    '$.router_policy_version'
    '$.profile_schema_version'
    '$.model_profile_version'
    '$.pricing_snapshot_date'
    '$.quality_snapshot_date'
    '$.calibration_set_version'
    '$.configuration_id'
    '$.launcher'
    '$.provider'
    '$.model'
    '$.effort'
    '$.enabled'
    '$.availability'
    '$.supports'
    '$.supports.input_modalities'
    '$.supports.output_modalities'
    '$.supports.languages'
    '$.supports.single_turn'
    '$.supports.context_window_tokens'
    '$.supports.maximum_output_tokens'
    '$.quality'
    '$.quality.task_types'
    '$.quality.domains'
    '$.quality.complexities'
    '$.quality.capabilities'
    '$.pricing'
    '$.pricing.currency'
    '$.pricing.rate_unit'
    '$.pricing.cost_comparable'
    '$.pricing.input_usd_per_million_tokens'
    '$.pricing.output_usd_per_million_tokens'
    '$.pricing.effective_from'
    '$.pricing.effective_through'
    '$.token_consumption_observations'
    '$.token_consumption_observations[0].model'
    '$.token_consumption_observations[0].effort'
    '$.token_consumption_observations[0].request_profile_group'
    '$.token_consumption_observations[0].estimated_input_tokens'
    '$.token_consumption_observations[0].estimated_visible_output_tokens'
    '$.token_consumption_observations[0].estimated_reasoning_tokens'
    '$.token_consumption_observations[0].observed_on'
    '$.latency_observation'
    '$.latency_observation.available'
    '$.latency_observation.metric'
    '$.latency_observation.milliseconds'
    '$.latency_observation.sample_count'
    '$.latency_observation.observed_on'
    '$.evidence'
    '$.evidence.provider'
    '$.evidence.provider.source_url'
    '$.evidence.provider.retrieved_on'
    '$.evidence.provider.fixture_only'
    '$.evidence.provider.capacity_exact_model_match'
    '$.evidence.provider.capacity_note'
    '$.evidence.artificial_analysis'
    '$.evidence.artificial_analysis.source_url'
    '$.evidence.artificial_analysis.retrieved_on'
    '$.evidence.artificial_analysis.exact_model_match'
    '$.evidence.artificial_analysis.exact_effort_match'
    '$.evidence.artificial_analysis.benchmark_slice'
    '$.evidence.artificial_analysis.fixture_only'
    '$.calibration'
    '$.calibration.status'
    '$.calibration.version'
)
$requiredCompletedResponsePaths = @(
    '$.status'
    '$.configuration_id'
    '$.provider'
    '$.launcher'
    '$.model'
    '$.effort'
    '$.output'
    '$.quality_floor'
    '$.effective_quality'
    '$.quality_bottleneck'
    '$.price'
    '$.price_final'
    '$.latency'
    '$.decision_trace_id'
)
$requiredFailureResponsePaths = @('$.status', '$.reason_code', '$.decision_trace_id')

function Assert-Equal {
    param(
        [AllowNull()][object]$Actual,
        [AllowNull()][object]$Expected
    )

    if ($Actual -ne $Expected) {
        throw "Expected '$Expected' but got '$Actual'."
    }
}

function Assert-False {
    param([bool]$Condition)

    if ($Condition) {
        throw 'Expected condition to be false.'
    }
}

function Assert-ValidationSuccess {
    param([Parameter(Mandatory)][object]$Validation)

    Assert-Equal $Validation.valid $true
    Assert-Equal (@($Validation.errors).Count) 0
}

function Assert-RequiredPropertyError {
    param(
        [Parameter(Mandatory)][object]$Validation,
        [Parameter(Mandatory)][string]$Path
    )

    Assert-False $Validation.valid
    $matchingErrors = @(
        $Validation.errors | Where-Object {
            $_.code -ceq 'required_property_missing' -and $_.path -ceq $Path
        }
    )
    Assert-Equal $matchingErrors.Count 1
}

function Assert-ValidationError {
    param(
        [Parameter(Mandatory)][object]$Validation,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Path
    )

    Assert-False $Validation.valid
    $matchingErrors = @(
        $Validation.errors | Where-Object {
            $_.code -ceq $Code -and $_.path -ceq $Path
        }
    )
    Assert-Equal $matchingErrors.Count 1
}

function Assert-ValidationErrorsExactly {
    param(
        [Parameter(Mandatory)][object]$Validation,
        [Parameter(Mandatory)][object[]]$ExpectedErrors
    )

    Assert-False $Validation.valid
    [string[]]$actual = @($Validation.errors | ForEach-Object { '{0}|{1}' -f $_.code, $_.path })
    [string[]]$expected = @($ExpectedErrors | ForEach-Object { '{0}|{1}' -f $_.code, $_.path })
    [Array]::Sort($actual, [System.StringComparer]::Ordinal)
    [Array]::Sort($expected, [System.StringComparer]::Ordinal)
    Assert-SequenceEqual $actual $expected
}

function Assert-SequenceEqual {
    param(
        [object[]]$Actual,
        [object[]]$Expected
    )

    Assert-Equal $Actual.Count $Expected.Count
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        Assert-Equal $Actual[$index] $Expected[$index]
    }
}

function Invoke-Assertion {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Script
    )

    try {
        & $Script
        Write-Host "PASS $Name"
    } catch {
        $failures.Add("FAIL ${Name}: $($_.Exception.Message)")
    }
}

function Copy-TestObject {
    param([Parameter(Mandatory)][object]$Value)

    return ($Value | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30)
}

function Test-TemporaryRouterSchema {
    param(
        [Parameter(Mandatory)][object]$Schema,
        [AllowNull()][object]$Value = $null
    )

    $temporarySchemaPath = Join-Path ([System.IO.Path]::GetTempPath()) (
        'router-schema-test-{0}.json' -f [guid]::NewGuid().ToString('N')
    )
    try {
        ConvertTo-Json -InputObject $Schema -Depth 100 |
            Set-Content -LiteralPath $temporarySchemaPath -Encoding utf8NoBOM
        return Test-RouterSchema -Value $Value -SchemaPath $temporarySchemaPath
    } finally {
        if (Test-Path -LiteralPath $temporarySchemaPath) {
            Remove-Item -LiteralPath $temporarySchemaPath -Force
        }
    }
}

function Remove-TestProperty {
    param(
        [Parameter(Mandatory)][object]$Value,
        [Parameter(Mandatory)][string]$Path
    )

    $segments = @($Path.Substring(2) -split '\.')
    $parent = $Value
    for ($index = 0; $index -lt ($segments.Count - 1); $index++) {
        $segment = $segments[$index]
        if ($segment -match '^(?<property>[^\[]+)\[(?<index>\d+)\]$') {
            $parent = $parent.($Matches.property)[[int]$Matches.index]
        } else {
            $parent = $parent.$segment
        }
    }

    $parent.PSObject.Properties.Remove($segments[-1])
}

function New-MinimalRequest {
    [pscustomobject]@{
        request_text = 'Explain why this algorithm fails on an empty list.'
        task_type = 'coding'
        domain = 'computer_science'
        complexity = 'medium'
        quality_floor = 'strong'
        latency = 'normal'
        privacy_level = 'standard'
        risk_level = 'standard'
        output_length = 'normal'
        language = 'english'
        additional_capabilities = @()
    }
}

function New-MinimalCompletedResponse {
    [pscustomobject]@{
        status = 'completed'
        configuration_id = 'shared-model__medium'
        provider = 'openai'
        launcher = 'codex'
        model = 'shared-model'
        effort = 'medium'
        output = 'Normalized model response'
        quality_floor = 'strong'
        effective_quality = 'strong'
        quality_bottleneck = 'task_type.coding'
        price = 0.0137
        price_final = $false
        latency = 12.4
        decision_trace_id = 'route_123'
    }
}

function New-MinimalFailureResponse {
    [pscustomobject]@{
        status = 'unsupported_request'
        reason_code = 'unsupported_language'
        decision_trace_id = 'route_123'
    }
}

function Get-MinimalProfiles {
    $fixtureRoot = Join-Path $PSScriptRoot 'fixtures/minimal-profiles'
    return @(
        Get-ChildItem -LiteralPath $fixtureRoot -File -Filter '*.json' |
            Sort-Object -Property Name |
            ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json -Depth 30 }
    )
}

function Get-MinimalPolicyProfiles {
    $profiles = @(Get-MinimalProfiles | ForEach-Object { Copy-TestObject $_ })
    $codex = @($profiles | Where-Object { $_.launcher -ceq 'codex' })[0]
    $codex.model = 'shared-model-openai'
    foreach ($observation in @($codex.token_consumption_observations)) {
        $observation.model = 'shared-model-openai'
    }
    return $profiles
}

function Get-CompositeIdentity {
    param([Parameter(Mandatory)][object]$Candidate)

    return '{0}|{1}' -f $Candidate.launcher, $Candidate.configuration_id
}

function Set-TestRelevantQuality {
    param(
        [Parameter(Mandatory)][object]$Candidate,
        [Parameter(Mandatory)][object]$Request,
        [Parameter(Mandatory)][string[]]$RequiredCapabilities,
        [Parameter(Mandatory)][string]$Category
    )

    $Candidate.quality.task_types.($Request.task_type) = $Category
    $Candidate.quality.domains.($Request.domain) = $Category
    $Candidate.quality.complexities.($Request.complexity) = $Category
    foreach ($capability in $RequiredCapabilities) {
        $Candidate.quality.capabilities.($capability) = $Category
    }
}

function Reverse-TestPropertyOrder {
    param([Parameter(Mandatory)][object]$Value)

    $reversed = [ordered]@{}
    [string[]]$names = @($Value.PSObject.Properties.Name)
    [array]::Reverse($names)
    foreach ($name in $names) {
        $reversed[$name] = $Value.$name
    }
    return [pscustomobject]$reversed
}

function New-MinimalRuntimeState {
    [pscustomobject]@{
        launcher = 'agy'
        model = 'shared-model'
        effort = 'medium'
        available = $true
        authenticated = $true
        working = $true
        quota_exhausted = $false
    }
}

function Get-TestTokenEstimates {
    return Get-Content -LiteralPath $tokenEstimatesPath -Raw | ConvertFrom-Json -Depth 30
}

function New-TestTokenObservation {
    param(
        [Parameter(Mandatory)][object]$Candidate,
        [string]$RequestProfileGroup = 'coding|computer_science|medium|normal',
        [long]$EstimatedInputTokens = 1000,
        [long]$EstimatedVisibleOutputTokens = 500,
        [long]$EstimatedReasoningTokens = 250
    )

    return [pscustomobject][ordered]@{
        launcher = $Candidate.launcher
        configuration_id = $Candidate.configuration_id
        model = $Candidate.model
        effort = $Candidate.effort
        request_profile_group = $RequestProfileGroup
        estimated_input_tokens = $EstimatedInputTokens
        estimated_visible_output_tokens = $EstimatedVisibleOutputTokens
        estimated_reasoning_tokens = $EstimatedReasoningTokens
        observed_on = '2026-08-22'
    }
}

function New-TestTokenEstimatesDocument {
    param([object[]]$Observations)

    return [pscustomobject][ordered]@{
        version = 'router-token-estimates/v1'
        observations = @($Observations)
    }
}

function Get-TestPolicyTokenEstimates {
    param([object[]]$Profiles = @(Get-MinimalPolicyProfiles))

    $observations = @(
        foreach ($profile in $Profiles) {
            New-TestTokenObservation -Candidate $profile
        }
    )
    return New-TestTokenEstimatesDocument -Observations $observations
}

function New-TestPriceRequirements {
    param([long]$EstimatedInputTokens = 1000)

    return [pscustomobject]@{
        estimated_input_tokens = $EstimatedInputTokens
    }
}

function Write-TestJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Value
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    $Value | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

function New-TestMatrix {
    param(
        [string]$Tool = 'agy',
        [string]$Provider = 'google',
        [string]$Model = 'shared-model',
        [AllowNull()][string]$Effort = 'medium'
    )

    $candidate = [ordered]@{
        route_id = 'test-route'
        tool = $Tool
        provider = $Provider
        model = $Model
        candidate_kind = 'model'
        instruction_file = 'test-instructions.md'
        enabled = $true
    }
    if ($null -ne $Effort) { $candidate.effort = $Effort }
    return [pscustomobject]@{ schema_version = 1; special_routes = @(); candidates = @([pscustomobject]$candidate) }
}

function New-TestPricingSnapshot {
    [pscustomobject]@{
        snapshot_date = '2026-08-22'
        retrieved_on = '2026-08-23'
        currency = 'USD'
        rate_unit = 'per_million_tokens'
        policy = 'test fixture'
        schedules = @(
            [pscustomobject]@{
                provider = 'google'
                model = 'shared-model'
                profile_models = @('shared-model')
                cost_comparable = $true
                source_url = 'https://fixtures.invalid/pricing/shared-model'
                retrieved_on = '2026-08-23'
                rate_periods = @(
                    [pscustomobject]@{
                        effective_from = '2026-08-22'
                        effective_through = $null
                        input_tokens_min = 0
                        input_tokens_max = $null
                        input_usd_per_million_tokens = 1.0
                        output_usd_per_million_tokens = 5.0
                    }
                )
            }
        )
    }
}

function New-TestPolicyPricingSnapshot {
    param(
        [decimal]$AgyInputRate = 1,
        [decimal]$AgyOutputRate = 5,
        [decimal]$CodexInputRate = 1,
        [decimal]$CodexOutputRate = 5
    )

    $snapshot = New-TestPricingSnapshot
    $snapshot.schedules = @(
        [pscustomobject]@{
            provider = 'google'
            model = 'shared-model-google-schedule'
            profile_models = @('shared-model')
            cost_comparable = $true
            source_url = 'https://fixtures.invalid/pricing/shared-model-google'
            retrieved_on = '2026-08-23'
            rate_periods = @([pscustomobject]@{
                effective_from = '2026-08-22'
                effective_through = $null
                input_tokens_min = 0
                input_tokens_max = $null
                input_usd_per_million_tokens = $AgyInputRate
                output_usd_per_million_tokens = $AgyOutputRate
            })
        }
        [pscustomobject]@{
            provider = 'openai'
            model = 'shared-model-openai-schedule'
            profile_models = @('shared-model-openai')
            cost_comparable = $true
            source_url = 'https://fixtures.invalid/pricing/shared-model-openai'
            retrieved_on = '2026-08-23'
            rate_periods = @([pscustomobject]@{
                effective_from = '2026-08-22'
                effective_through = $null
                input_tokens_min = 0
                input_tokens_max = $null
                input_usd_per_million_tokens = $CodexInputRate
                output_usd_per_million_tokens = $CodexOutputRate
            })
        }
    )
    return $snapshot
}

function Invoke-TestRouterPolicy {
    param(
        [Parameter(Mandatory)][object[]]$Profiles,
        [object]$Request = (New-MinimalRequest),
        [AllowNull()][object]$PricingSnapshot,
        [AllowNull()][object]$TokenEstimates,
        [AllowNull()][object[]]$RuntimeStates
    )

    $parameters = @{
        Request = $Request
        Profiles = $Profiles
        RequestSchemaPath = $requestSchemaPath
        ProjectInstructions = ''
        OutputReserveTokens = 128
        LongContextThresholdTokens = 100000
        AsOfDate = '2026-08-22'
    }
    if ($PSBoundParameters.ContainsKey('PricingSnapshot')) {
        $parameters.PricingSnapshot = $PricingSnapshot
    }
    if ($PSBoundParameters.ContainsKey('TokenEstimates')) {
        $parameters.TokenEstimates = $TokenEstimates
    }
    if ($PSBoundParameters.ContainsKey('RuntimeStates')) {
        $parameters.RuntimeStates = $RuntimeStates
    }
    return Invoke-RouterPolicy @parameters
}

function Assert-PolicyPricingSnapshotRejected {
    param(
        [Parameter(Mandatory)][object]$PricingSnapshot,
        [object[]]$Profiles = @(Get-MinimalPolicyProfiles),
        [string]$ExpectedReasonCode = 'pricing_snapshot_invalid'
    )

    $observations = @(
        foreach ($profile in $Profiles) {
            New-TestTokenObservation -Candidate $profile
        }
    )
    $decision = Invoke-TestRouterPolicy -Profiles $Profiles -PricingSnapshot $PricingSnapshot `
        -TokenEstimates (New-TestTokenEstimatesDocument -Observations $observations)

    Assert-Equal $decision.selected_candidate $null
    Assert-Equal $decision.price $null
    Assert-Equal @($decision.candidate_evaluations).Count @($Profiles).Count
    foreach ($evaluation in @($decision.candidate_evaluations)) {
        Assert-Equal $evaluation.rejection_stage 'price'
        Assert-SequenceEqual @($evaluation.rejection_reason_codes) @($ExpectedReasonCode)
    }
}

function New-TestQualitySnapshot {
    [pscustomobject]@{
        snapshot_date = '2026-08-22'
        retrieved_on = '2026-08-23'
        methodology_url = 'https://fixtures.invalid/artificial-analysis/methodology'
        policy = 'test fixture'
        records = @(
            [pscustomobject]@{
                launcher = 'agy'
                configuration_id = 'shared-model__medium'
                model = 'shared-model'
                effort = 'medium'
                source_url = 'https://fixtures.invalid/artificial-analysis/shared-model-medium'
                retrieved_on = '2026-08-22'
                exact_model_match = $true
                exact_effort_match = $true
                benchmark_slice = 'minimal-tied-policy-fixture'
                provisional_category = 'strong'
                quality_authorizations = @(
                    foreach ($mapName in $requiredQualityKeys.Keys) {
                        foreach ($qualityKey in $requiredQualityKeys[$mapName]) {
                            [pscustomobject]@{
                                path = '$.quality.{0}.{1}' -f $mapName, $qualityKey
                                benchmark_slice = 'minimal-tied-policy-fixture'
                                category = 'strong'
                                evidence_kind = 'artificial_analysis'
                                exact_model_match = $true
                                exact_effort_match = $true
                                source_url = 'https://fixtures.invalid/artificial-analysis/shared-model-medium'
                                retrieved_on = '2026-08-22'
                            }
                        }
                    }
                )
                note = 'Test-only exact evidence.'
            }
        )
    }
}

function Import-TestRouterProfileCatalog {
    param(
        [Parameter(Mandatory)][string]$ProfilesRoot,
        [Parameter(Mandatory)][string]$MatrixPath,
        [Parameter(Mandatory)][string]$ProfileSchemaPath,
        [Parameter(Mandatory)][string]$PricingSnapshotPath,
        [Parameter(Mandatory)][string]$QualitySnapshotPath
    )

    $parameters = @{
        ProfilesRoot = $ProfilesRoot
        MatrixPath = $MatrixPath
        ProfileSchemaPath = $ProfileSchemaPath
        PricingSnapshotPath = $PricingSnapshotPath
    }
    $command = Get-Command Import-RouterProfileCatalog -ErrorAction Stop
    if ($command.Parameters.ContainsKey('QualitySnapshotPath')) {
        $parameters.QualitySnapshotPath = $QualitySnapshotPath
    }
    return Import-RouterProfileCatalog @parameters
}

function Invoke-WithTemporaryCatalog {
    param([Parameter(Mandatory)][scriptblock]$Script)

    $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('router-catalog-test-{0}' -f [guid]::NewGuid().ToString('N'))
    try {
        $null = New-Item -ItemType Directory -Path (Join-Path $temporaryRoot 'profiles') -Force
        $testPricingPath = Join-Path $temporaryRoot 'pricing.json'
        Write-TestJson -Path $testPricingPath -Value (New-TestPricingSnapshot)
        $testQualityPath = Join-Path $temporaryRoot 'quality.json'
        Write-TestJson -Path $testQualityPath -Value (New-TestQualitySnapshot)
        & $Script $temporaryRoot $testPricingPath $testQualityPath
    } finally {
        if (Test-Path -LiteralPath $temporaryRoot) {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
        }
    }
}

function Assert-CatalogError {
    param(
        [Parameter(Mandatory)][object]$Catalog,
        [Parameter(Mandatory)][string]$Code
    )

    $matches = @($Catalog.errors | Where-Object { $_.code -ceq $Code })
    Assert-Equal $matches.Count 1
    if ($matches[0].PSObject.Properties.Name -notcontains 'file') { throw "Catalog error '$Code' lacks file context." }
    if ($matches[0].PSObject.Properties.Name -notcontains 'identity') { throw "Catalog error '$Code' lacks identity context." }
}

function Assert-PricingSnapshotMutationRejected {
    param(
        [Parameter(Mandatory)][scriptblock]$Mutation,
        [AllowNull()][object]$Snapshot = $null,
        [string]$ExpectedCode = 'pricing_snapshot_invalid'
    )

    Invoke-WithTemporaryCatalog {
        param($root, $testPricingPath, $testQualityPath)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        Write-TestJson -Path (Join-Path $root 'profiles/agy/shared-model__medium.json') -Value (Copy-TestObject @(Get-MinimalProfiles)[0])
        $mutatedSnapshot = if ($null -eq $Snapshot) { New-TestPricingSnapshot } else { Copy-TestObject $Snapshot }
        & $Mutation $mutatedSnapshot
        Write-TestJson -Path $testPricingPath -Value $mutatedSnapshot

        $catalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-Equal $catalog.valid $false
        Assert-CatalogError -Catalog $catalog -Code $ExpectedCode
    }
}

function Assert-QualitySnapshotMutationRejected {
    param(
        [Parameter(Mandatory)][scriptblock]$Mutation,
        [string]$ExpectedCode
    )

    Invoke-WithTemporaryCatalog {
        param($root, $testPricingPath, $testQualityPath)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        Write-TestJson -Path (Join-Path $root 'profiles/agy/shared-model__medium.json') -Value (Copy-TestObject @(Get-MinimalProfiles)[0])
        $snapshot = New-TestQualitySnapshot
        & $Mutation $snapshot
        Write-TestJson -Path $testQualityPath -Value $snapshot

        $catalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-Equal $catalog.valid $false
        Assert-CatalogError -Catalog $catalog -Code $ExpectedCode
    }
}

Invoke-Assertion 'request schema accepts every approved enum value' {
    foreach ($propertyName in $requestEnums.Keys) {
        foreach ($allowedValue in $requestEnums[$propertyName]) {
            $request = New-MinimalRequest
            $request.$propertyName = $allowedValue

            Assert-ValidationSuccess (Test-RouterSchema -Value $request -SchemaPath $requestSchemaPath)
        }
    }

    foreach ($capability in $requiredQualityKeys.capabilities) {
        $request = New-MinimalRequest
        $request.additional_capabilities = @($capability)

        Assert-ValidationSuccess (Test-RouterSchema -Value $request -SchemaPath $requestSchemaPath)
    }
}

Invoke-Assertion 'request schema rejects unsupported enum values at the exact path' {
    foreach ($propertyName in $requestEnums.Keys) {
        $request = New-MinimalRequest
        $request.$propertyName = 'not_approved'

        $validation = Test-RouterSchema -Value $request -SchemaPath $requestSchemaPath

        Assert-ValidationError -Validation $validation -Code 'enum_value_not_allowed' -Path "$.${propertyName}"
    }

    $request = New-MinimalRequest
    $request.additional_capabilities = @('tool_use')
    $validation = Test-RouterSchema -Value $request -SchemaPath $requestSchemaPath
    Assert-ValidationError -Validation $validation -Code 'enum_value_not_allowed' -Path '$.additional_capabilities[0]'
}

Invoke-Assertion 'request schema rejects every omitted required field' {
    $validRequest = New-MinimalRequest
    Assert-ValidationSuccess (Test-RouterSchema -Value $validRequest -SchemaPath $requestSchemaPath)

    foreach ($requiredPath in $requiredRequestPaths) {
        $invalidRequest = Copy-TestObject $validRequest
        Remove-TestProperty -Value $invalidRequest -Path $requiredPath

        $validation = Test-RouterSchema -Value $invalidRequest -SchemaPath $requestSchemaPath

        Assert-RequiredPropertyError -Validation $validation -Path $requiredPath
    }
}

Invoke-Assertion 'request schema permits omission of fields with V1 defaults' {
    foreach ($optionalProperty in @('latency', 'output_length', 'additional_capabilities')) {
        $request = New-MinimalRequest
        $request.PSObject.Properties.Remove($optionalProperty)

        Assert-ValidationSuccess (Test-RouterSchema -Value $request -SchemaPath $requestSchemaPath)
    }
}

Invoke-Assertion 'request schema returns approved boundary reason codes' {
    $boundaryCases = @(
        [pscustomobject]@{ property = 'language'; value = 'spanish'; code = 'unsupported_language'; path = '$.language' }
        [pscustomobject]@{ property = 'language'; value = 'English'; code = 'unsupported_language'; path = '$.language' }
        [pscustomobject]@{ property = 'privacy_level'; value = 'sensitive'; code = 'sensitive_request_unsupported'; path = '$.privacy_level' }
        [pscustomobject]@{ property = 'risk_level'; value = 'high_stakes'; code = 'high_stakes_unsupported'; path = '$.risk_level' }
        [pscustomobject]@{ property = 'modality'; value = 'text'; code = 'unsupported_modality'; path = '$.modality' }
        [pscustomobject]@{ property = 'modality'; value = 'image'; code = 'unsupported_modality'; path = '$.modality' }
        [pscustomobject]@{ property = 'input_modalities'; value = @('text'); code = 'unsupported_modality'; path = '$.input_modalities' }
        [pscustomobject]@{ property = 'input_modalities'; value = @('text', 'image'); code = 'unsupported_modality'; path = '$.input_modalities' }
    )

    foreach ($boundaryCase in $boundaryCases) {
        $request = New-MinimalRequest
        $request | Add-Member -NotePropertyName $boundaryCase.property -NotePropertyValue $boundaryCase.value -Force

        $validation = Test-RouterSchema -Value $request -SchemaPath $requestSchemaPath

        Assert-ValidationError -Validation $validation -Code $boundaryCase.code -Path $boundaryCase.path
    }
}

Invoke-Assertion 'request schema rejects unknown extra properties' {
    $request = New-MinimalRequest
    $request | Add-Member -NotePropertyName 'temperature' -NotePropertyValue 0.5

    $validation = Test-RouterSchema -Value $request -SchemaPath $requestSchemaPath

    Assert-ValidationError -Validation $validation -Code 'additional_property_not_allowed' -Path '$.temperature'
}

Invoke-Assertion 'request schema treats wrong-case required properties as missing and additional' {
    $request = New-MinimalRequest
    $request.PSObject.Properties.Remove('task_type')
    $request | Add-Member -NotePropertyName 'Task_Type' -NotePropertyValue 'coding'

    $validation = Test-RouterSchema -Value $request -SchemaPath $requestSchemaPath

    Assert-ValidationErrorsExactly -Validation $validation -ExpectedErrors @(
        [pscustomobject]@{ code = 'required_property_missing'; path = '$.task_type' }
        [pscustomobject]@{ code = 'additional_property_not_allowed'; path = '$.Task_Type' }
    )
}

Invoke-Assertion 'profile schema accepts the positive-control fixtures' {
    $validProfiles = @(Get-MinimalProfiles)
    foreach ($profile in $validProfiles) {
        $validValidation = Test-RouterSchema -Value $profile -SchemaPath $profileSchemaPath
        Assert-ValidationSuccess $validValidation
    }
}

Invoke-Assertion 'Task 3 profile catalog module is available' {
    Assert-Equal $profilesAvailable $true
    Assert-Equal ($null -ne (Get-Command Import-RouterProfileCatalog -ErrorAction SilentlyContinue)) $true
}

Invoke-Assertion 'profile schema represents unknown pricing and observations without fabricated zeroes' {
    $profile = Copy-TestObject @(Get-MinimalProfiles)[0]
    $profile.pricing.cost_comparable = $false
    $profile.pricing.input_usd_per_million_tokens = $null
    $profile.pricing.output_usd_per_million_tokens = $null
    $profile.token_consumption_observations = @()
    $profile.latency_observation.available = $false
    $profile.latency_observation.metric = $null
    $profile.latency_observation.milliseconds = $null
    $profile.latency_observation.sample_count = $null
    $profile.latency_observation.observed_on = $null

    Assert-ValidationSuccess (Test-RouterSchema -Value $profile -SchemaPath $profileSchemaPath)
}

Invoke-Assertion 'pricing snapshot preserves dated schedules and Gemini 3.1 context tiers' {
    $snapshot = Get-Content -LiteralPath $pricingSnapshotPath -Raw | ConvertFrom-Json -Depth 100
    Assert-Equal $snapshot.snapshot_date '2026-08-22'
    Assert-Equal $snapshot.currency 'USD'
    Assert-Equal $snapshot.rate_unit 'per_million_tokens'
    Assert-Equal (@($snapshot.schedules).Count -gt 0) $true
    foreach ($schedule in $snapshot.schedules) {
        Assert-Equal ([string]::IsNullOrWhiteSpace([string]$schedule.source_url)) $false
        Assert-Equal ([string]::IsNullOrWhiteSpace([string]$schedule.retrieved_on)) $false
        Assert-Equal (@($schedule.profile_models).Count -gt 0) $true
        foreach ($period in $schedule.rate_periods) {
            Assert-Equal ([string]::IsNullOrWhiteSpace([string]$period.effective_from)) $false
        }
    }

    $gemini31 = @($snapshot.schedules | Where-Object { $_.model -ceq 'gemini-3.1-pro' })
    Assert-Equal $gemini31.Count 1
    Assert-Equal @($gemini31[0].rate_periods).Count 2
    Assert-Equal $gemini31[0].rate_periods[0].input_tokens_max 200000
    Assert-Equal $gemini31[0].rate_periods[0].input_usd_per_million_tokens 2
    Assert-Equal $gemini31[0].rate_periods[1].input_tokens_min 200001
    Assert-Equal $gemini31[0].rate_periods[1].input_usd_per_million_tokens 4

    [string[]]$pricedModels = @($snapshot.schedules | ForEach-Object { $_.profile_models })
    [string[]]$uniquePricedModels = @($pricedModels | Select-Object -Unique)
    Assert-Equal $pricedModels.Count $uniquePricedModels.Count
    $profileModels = @(
        Get-ChildItem -LiteralPath $profilesRoot -Recurse -File -Filter '*.json' |
            ForEach-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 100).model } |
            Select-Object -Unique
    )
    foreach ($profileModel in $profileModels) {
        Assert-Equal ($pricedModels -ccontains $profileModel) $true
    }
}

Invoke-Assertion 'pricing snapshot validates rates in every tier including Gemini upper tiers' {
    $productionSnapshot = Get-Content -LiteralPath $pricingSnapshotPath -Raw | ConvertFrom-Json -Depth 100
    Assert-PricingSnapshotMutationRejected -Snapshot $productionSnapshot -Mutation {
        param($snapshot)
        $gemini31 = @($snapshot.schedules | Where-Object { $_.model -ceq 'gemini-3.1-pro' })[0]
        $gemini31.rate_periods[1].input_usd_per_million_tokens = -0.01
    }
}

$underflowSnapshotRateCases = @(
    [pscustomobject]@{ name = 'negative double'; value = [double]-1e-100 }
    [pscustomobject]@{ name = 'positive double'; value = [double]1e-100 }
    [pscustomobject]@{ name = 'negative single'; value = [single]-1e-40 }
    [pscustomobject]@{ name = 'positive single'; value = [single]1e-40 }
)
foreach ($underflowSnapshotRateCase in $underflowSnapshotRateCases) {
    Invoke-Assertion ("pricing snapshot rejects {0} nonzero floating-point rate underflow" -f $underflowSnapshotRateCase.name) {
        $snapshot = New-TestPricingSnapshot
        $snapshot.schedules[0].rate_periods[0].input_usd_per_million_tokens = $underflowSnapshotRateCase.value

        $validation = Test-RouterPricingSnapshotObject -PricingSnapshot $snapshot

        Assert-Equal $validation.valid $false
        Assert-CatalogError -Catalog $validation -Code 'pricing_snapshot_invalid'
    }
}

Invoke-Assertion 'pricing snapshot rejects numeric fields encoded as strings' {
    Assert-PricingSnapshotMutationRejected -Mutation {
        param($snapshot)
        $snapshot.schedules[0].rate_periods[0].input_usd_per_million_tokens = '1.0'
    }
    Assert-PricingSnapshotMutationRejected -Mutation {
        param($snapshot)
        $snapshot.schedules[0].rate_periods[0].input_tokens_min = '0'
    }
}

Invoke-Assertion 'pricing snapshot requires exact ISO dates and ordered effective intervals' {
    Assert-PricingSnapshotMutationRejected -Mutation {
        param($snapshot)
        $snapshot.schedules[0].rate_periods[0].effective_from = '2026-8-22'
    }
    Assert-PricingSnapshotMutationRejected -Mutation {
        param($snapshot)
        $snapshot.schedules[0].rate_periods[0].effective_through = '2026-08-21'
    }
}

Invoke-Assertion 'pricing snapshot rejects gaps and overlaps between effective date intervals' {
    $productionSnapshot = Get-Content -LiteralPath $pricingSnapshotPath -Raw | ConvertFrom-Json -Depth 100
    Assert-PricingSnapshotMutationRejected -Snapshot $productionSnapshot -Mutation {
        param($snapshot)
        $sonnet5 = @($snapshot.schedules | Where-Object { $_.model -ceq 'claude-sonnet-5' })[0]
        $sonnet5.rate_periods[1].effective_from = '2026-09-02'
    }
    Assert-PricingSnapshotMutationRejected -Snapshot $productionSnapshot -Mutation {
        param($snapshot)
        $sonnet5 = @($snapshot.schedules | Where-Object { $_.model -ceq 'claude-sonnet-5' })[0]
        $sonnet5.rate_periods[1].effective_from = '2026-08-31'
    }
}

Invoke-Assertion 'pricing snapshot rejects an impossible successor after the maximum calendar date without throwing' {
    Assert-PricingSnapshotMutationRejected -Mutation {
        param($snapshot)
        $snapshot.snapshot_date = '9999-12-30'
        $first = $snapshot.schedules[0].rate_periods[0]
        $first.effective_from = '9999-12-30'
        $first.effective_through = '9999-12-31'
        $second = Copy-TestObject $first
        $second.effective_from = '9999-12-31'
        $second.effective_through = $null
        $snapshot.schedules[0].rate_periods = @($first, $second)
    }
}

Invoke-Assertion 'pricing snapshot rejects negative and nonintegral token bounds' {
    Assert-PricingSnapshotMutationRejected -Mutation {
        param($snapshot)
        $snapshot.schedules[0].rate_periods[0].input_tokens_min = -1
    }
    Assert-PricingSnapshotMutationRejected -Mutation {
        param($snapshot)
        $snapshot.schedules[0].rate_periods[0].input_tokens_max = 100.5
    }
}

Invoke-Assertion 'pricing snapshot rejects overlapping and gapped token partitions per effective interval' {
    Assert-PricingSnapshotMutationRejected -Mutation {
        param($snapshot)
        $first = $snapshot.schedules[0].rate_periods[0]
        $first.input_tokens_max = 200000
        $second = Copy-TestObject $first
        $second.input_tokens_min = 200000
        $second.input_tokens_max = $null
        $snapshot.schedules[0].rate_periods = @($first, $second)
    }
    Assert-PricingSnapshotMutationRejected -Mutation {
        param($snapshot)
        $first = $snapshot.schedules[0].rate_periods[0]
        $first.input_tokens_max = 200000
        $second = Copy-TestObject $first
        $second.input_tokens_min = 200002
        $second.input_tokens_max = $null
        $snapshot.schedules[0].rate_periods = @($first, $second)
    }
}

Invoke-Assertion 'direct pricing snapshot validation rejects a non-final decimal MaxValue token bound without throwing' {
    $snapshot = New-TestPricingSnapshot
    $first = $snapshot.schedules[0].rate_periods[0]
    $first.input_tokens_max = [decimal]::MaxValue
    $second = Copy-TestObject $first
    $second.input_tokens_min = [decimal]::MaxValue
    $second.input_tokens_max = $null
    $snapshot.schedules[0].rate_periods = @($first, $second)

    $validation = Test-RouterPricingSnapshotObject -PricingSnapshot $snapshot

    Assert-Equal $validation.valid $false
    Assert-CatalogError -Catalog $validation -Code 'pricing_snapshot_invalid'
}

Invoke-Assertion 'pricing snapshot requires real arrays for schedules models and periods' {
    Assert-PricingSnapshotMutationRejected -Mutation {
        param($snapshot)
        $snapshot.schedules = $snapshot.schedules[0]
    }
    Assert-PricingSnapshotMutationRejected -Mutation {
        param($snapshot)
        $snapshot.schedules[0].profile_models = 'shared-model'
    }
    Assert-PricingSnapshotMutationRejected -Mutation {
        param($snapshot)
        $snapshot.schedules[0].rate_periods = $snapshot.schedules[0].rate_periods[0]
    }
}

Invoke-Assertion 'pricing snapshot rejects duplicate profile-model mappings' {
    Assert-PricingSnapshotMutationRejected -ExpectedCode 'pricing_snapshot_duplicate_model' -Mutation {
        param($snapshot)
        $duplicate = Copy-TestObject $snapshot.schedules[0]
        $duplicate.model = 'duplicate-schedule'
        $snapshot.schedules = @($snapshot.schedules[0], $duplicate)
    }
}

Invoke-Assertion 'direct pricing snapshot validation rejects duplicate provider and canonical model schedules' {
    $snapshot = New-TestPricingSnapshot
    $duplicate = Copy-TestObject $snapshot.schedules[0]
    $duplicate.profile_models = @('disjoint-profile-model-alias')
    $snapshot.schedules = @($snapshot.schedules[0], $duplicate)

    $validation = Test-RouterPricingSnapshotObject -PricingSnapshot $snapshot

    Assert-Equal $validation.valid $false
    Assert-CatalogError -Catalog $validation -Code 'pricing_snapshot_duplicate_schedule'
}

Invoke-Assertion 'pricing snapshot requires schedule source and retrieval metadata' {
    Assert-PricingSnapshotMutationRejected -Mutation {
        param($snapshot)
        $snapshot.schedules[0].PSObject.Properties.Remove('source_url')
    }
    Assert-PricingSnapshotMutationRejected -Mutation {
        param($snapshot)
        $snapshot.schedules[0].retrieved_on = ''
    }
}

Invoke-Assertion 'pricing snapshot schedule sources must be absolute HTTP URLs' {
    Assert-PricingSnapshotMutationRejected -Mutation {
        param($snapshot)
        $snapshot.schedules[0].source_url = 'ftp://fixtures.invalid/pricing/shared-model'
    }
}

Invoke-Assertion 'pricing snapshot corroborating sources are strict HTTP URL arrays' {
    Assert-PricingSnapshotMutationRejected -Mutation {
        param($snapshot)
        $snapshot.schedules[0] | Add-Member -NotePropertyName corroborating_source_urls -NotePropertyValue 'https://fixtures.invalid/corroboration'
    }
    Assert-PricingSnapshotMutationRejected -Mutation {
        param($snapshot)
        $snapshot.schedules[0] | Add-Member -NotePropertyName corroborating_source_urls -NotePropertyValue @(
            'https://fixtures.invalid/corroboration'
            'ftp://fixtures.invalid/not-http'
        )
    }
    Assert-PricingSnapshotMutationRejected -Mutation {
        param($snapshot)
        $snapshot.schedules[0] | Add-Member -NotePropertyName source_urll -NotePropertyValue 'https://fixtures.invalid/typo'
    }
}

$exactPricingSnapshotContractCases = @(
    [pscustomobject]@{
        name = 'unknown top-level field'
        mutate = { param($snapshot) $snapshot | Add-Member -NotePropertyName snapshot_dtae -NotePropertyValue '2026-08-22' }
    }
    [pscustomobject]@{
        name = 'non-USD currency'
        mutate = { param($snapshot) $snapshot.currency = 'EUR' }
    }
    [pscustomobject]@{
        name = 'nonstandard rate unit'
        mutate = { param($snapshot) $snapshot.rate_unit = 'per_thousand_tokens' }
    }
    [pscustomobject]@{
        name = 'unknown schedule field'
        mutate = { param($snapshot) $snapshot.schedules[0] | Add-Member -NotePropertyName source_urll -NotePropertyValue 'https://fixtures.invalid/typo' }
    }
    [pscustomobject]@{
        name = 'unknown period field'
        mutate = { param($snapshot) $snapshot.schedules[0].rate_periods[0] | Add-Member -NotePropertyName input_token_min -NotePropertyValue 0 }
    }
)
foreach ($exactPricingSnapshotContractCase in $exactPricingSnapshotContractCases) {
    Invoke-Assertion ("direct pricing snapshot validation rejects {0}" -f $exactPricingSnapshotContractCase.name) {
        $snapshot = New-TestPricingSnapshot
        & $exactPricingSnapshotContractCase.mutate $snapshot

        $validation = Test-RouterPricingSnapshotObject -PricingSnapshot $snapshot

        Assert-Equal $validation.valid $false
        Assert-CatalogError -Catalog $validation -Code 'pricing_snapshot_invalid'
    }
}

Invoke-Assertion 'quality snapshot records one conservative evidence row per exact candidate' {
    $matrix = Get-Content -LiteralPath $matrixPath -Raw | ConvertFrom-Json -Depth 100
    $enabledCandidates = @($matrix.candidates | Where-Object { $_.enabled -and $_.candidate_kind -ceq 'model' })
    $snapshot = Get-Content -LiteralPath $qualitySnapshotPath -Raw | ConvertFrom-Json -Depth 100
    Assert-Equal $snapshot.snapshot_date '2026-08-22'
    Assert-Equal @($snapshot.records).Count $enabledCandidates.Count
    foreach ($record in $snapshot.records) {
        foreach ($property in @('launcher', 'configuration_id', 'model', 'effort', 'source_url', 'retrieved_on', 'exact_model_match', 'exact_effort_match', 'benchmark_slice', 'provisional_category', 'quality_authorizations')) {
            Assert-Equal ($record.PSObject.Properties.Name -ccontains $property) $true
        }
        Assert-Equal @($record.quality_authorizations).Count 0
        Assert-Equal ($qualityCategories -ccontains $record.provisional_category) $true
        if (-not $record.exact_model_match -or -not $record.exact_effort_match -or $record.benchmark_slice -ceq 'unavailable') {
            Assert-Equal $record.provisional_category 'unknown'
        }
    }
}

Invoke-Assertion 'production catalog covers each enabled normal matrix candidate exactly once' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    $catalog = Import-RouterProfileCatalog -ProfilesRoot $profilesRoot -MatrixPath $matrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $pricingSnapshotPath -QualitySnapshotPath $qualitySnapshotPath
    Assert-Equal $catalog.valid $true
    Assert-Equal @($catalog.errors).Count 0
    Assert-Equal @($catalog.profiles).Count 63

    [string[]]$identities = @($catalog.profiles | ForEach-Object { '{0}|{1}' -f $_.launcher, $_.configuration_id })
    [string[]]$sortedIdentities = @($identities)
    [Array]::Sort($sortedIdentities, [System.StringComparer]::Ordinal)
    Assert-SequenceEqual $identities $sortedIdentities
    Assert-Equal @($identities | Select-Object -Unique).Count 63

    $qualityValueCount = 0
    $nonUnknownQualityValueCount = 0
    foreach ($profile in $catalog.profiles) {
        Assert-Equal $profile.configuration_id ('{0}__{1}' -f $profile.model, $profile.effort)
        Assert-ValidationSuccess (Test-RouterSchema -Value $profile -SchemaPath $profileSchemaPath)
        foreach ($mapName in $requiredQualityKeys.Keys) {
            [string[]]$actualKeys = @($profile.quality.$mapName.PSObject.Properties.Name)
            [string[]]$expectedKeys = @($requiredQualityKeys[$mapName])
            [Array]::Sort($actualKeys, [System.StringComparer]::Ordinal)
            [Array]::Sort($expectedKeys, [System.StringComparer]::Ordinal)
            Assert-SequenceEqual $actualKeys $expectedKeys
            foreach ($qualityProperty in $profile.quality.$mapName.PSObject.Properties) {
                $qualityValueCount++
                if ($qualityProperty.Value -cne 'unknown') { $nonUnknownQualityValueCount++ }
            }
        }
    }
    Assert-Equal $qualityValueCount 1890
    Assert-Equal $nonUnknownQualityValueCount 0
}

Invoke-Assertion 'Spark profiles are unknown-cost and cannot be ranked as free' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    $catalog = Import-RouterProfileCatalog -ProfilesRoot $profilesRoot -MatrixPath $matrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $pricingSnapshotPath -QualitySnapshotPath $qualitySnapshotPath
    $sparkProfiles = @($catalog.profiles | Where-Object { $_.model -ceq 'gpt-5.3-codex-spark' })
    Assert-Equal $sparkProfiles.Count 4
    foreach ($profile in $sparkProfiles) {
        Assert-Equal $profile.pricing.cost_comparable $false
        Assert-Equal $null $profile.pricing.input_usd_per_million_tokens
        Assert-Equal $null $profile.pricing.output_usd_per_million_tokens
        Assert-Equal $profile.evidence.provider.capacity_exact_model_match $false
        Assert-Equal ([string]::IsNullOrWhiteSpace([string]$profile.evidence.provider.capacity_note)) $false
    }
}

Invoke-Assertion 'pricing snapshot keeps Spark non-comparable even when a profile claims zero rates' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root, $unusedTestPricingPath, $unusedTestQualityPath)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix -Tool 'codex' -Provider 'openai' -Model 'gpt-5.3-codex-spark' -Effort 'medium')
        $sparkProfile = Get-Content -LiteralPath (Join-Path $profilesRoot 'codex/gpt-5.3-codex-spark__medium.json') -Raw | ConvertFrom-Json -Depth 100
        $sparkProfile.pricing.cost_comparable = $true
        $sparkProfile.pricing.input_usd_per_million_tokens = 0
        $sparkProfile.pricing.output_usd_per_million_tokens = 0
        Write-TestJson -Path (Join-Path $root 'profiles/codex/gpt-5.3-codex-spark__medium.json') -Value $sparkProfile

        $catalog = Import-RouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $pricingSnapshotPath -QualitySnapshotPath $qualitySnapshotPath
        Assert-Equal $catalog.valid $false
        Assert-CatalogError -Catalog $catalog -Code 'profile_pricing_snapshot_mismatch'
    }
}

Invoke-Assertion 'non-exact unavailable benchmark evidence cannot claim measured quality' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root, $testPricingPath, $testQualityPath)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        $profile = Copy-TestObject @(Get-MinimalProfiles)[0]
        $profile.quality.task_types.coding = 'frontier'
        $profile.evidence.artificial_analysis.exact_model_match = $false
        $profile.evidence.artificial_analysis.exact_effort_match = $false
        $profile.evidence.artificial_analysis.benchmark_slice = 'unavailable'
        Write-TestJson -Path (Join-Path $root 'profiles/agy/shared-model__medium.json') -Value $profile
        $snapshot = New-TestQualitySnapshot
        $snapshot.records[0].exact_model_match = $false
        $snapshot.records[0].exact_effort_match = $false
        $snapshot.records[0].benchmark_slice = 'unavailable'
        $snapshot.records[0].provisional_category = 'unknown'
        $snapshot.records[0].quality_authorizations = @()
        Write-TestJson -Path $testQualityPath -Value $snapshot

        $catalog = Import-RouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-Equal $catalog.valid $false
        Assert-CatalogError -Catalog $catalog -Code 'profile_quality_evidence_invalid'
    }
}

Invoke-Assertion 'unsupported quality remains valid without exact benchmark evidence' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root, $testPricingPath, $testQualityPath)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        $profile = Copy-TestObject @(Get-MinimalProfiles)[0]
        foreach ($mapName in $requiredQualityKeys.Keys) {
            foreach ($qualityKey in $requiredQualityKeys[$mapName]) { $profile.quality.$mapName.$qualityKey = 'unknown' }
        }
        $profile.quality.capabilities.long_context = 'unsupported'
        $profile.evidence.artificial_analysis.exact_model_match = $false
        $profile.evidence.artificial_analysis.exact_effort_match = $false
        $profile.evidence.artificial_analysis.benchmark_slice = 'unavailable'
        Write-TestJson -Path (Join-Path $root 'profiles/agy/shared-model__medium.json') -Value $profile
        $snapshot = New-TestQualitySnapshot
        $snapshot.records[0].exact_model_match = $false
        $snapshot.records[0].exact_effort_match = $false
        $snapshot.records[0].benchmark_slice = 'unavailable'
        $snapshot.records[0].provisional_category = 'unknown'
        $snapshot.records[0].quality_authorizations = @(
            [pscustomobject]@{
                path = '$.quality.capabilities.long_context'
                benchmark_slice = 'provider_capability'
                category = 'unsupported'
                evidence_kind = 'provider'
                exact_model_match = $true
                exact_effort_match = $true
                source_url = 'https://fixtures.invalid/providers/google/shared-model'
                retrieved_on = '2026-08-22'
            }
        )
        Write-TestJson -Path $testQualityPath -Value $snapshot

        $catalog = Import-RouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-Equal $catalog.valid $true
        Assert-Equal @($catalog.errors).Count 0
    }
}

Invoke-Assertion 'exact relevant benchmark evidence permits measured quality categories' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root, $testPricingPath, $testQualityPath)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        $profile = Copy-TestObject @(Get-MinimalProfiles)[0]
        foreach ($mapName in $requiredQualityKeys.Keys) {
            foreach ($qualityKey in $requiredQualityKeys[$mapName]) { $profile.quality.$mapName.$qualityKey = 'unknown' }
        }
        $profile.quality.task_types.coding = 'strong'
        $profile.evidence.artificial_analysis.exact_model_match = $true
        $profile.evidence.artificial_analysis.exact_effort_match = $true
        $profile.evidence.artificial_analysis.benchmark_slice = 'coding'
        Write-TestJson -Path (Join-Path $root 'profiles/agy/shared-model__medium.json') -Value $profile
        $snapshot = New-TestQualitySnapshot
        $snapshot.records[0].benchmark_slice = 'coding'
        $snapshot.records[0].quality_authorizations = @(
            [pscustomobject]@{
                path = '$.quality.task_types.coding'
                benchmark_slice = 'coding'
                category = 'strong'
                evidence_kind = 'artificial_analysis'
                exact_model_match = $true
                exact_effort_match = $true
                source_url = 'https://fixtures.invalid/artificial-analysis/coding'
                retrieved_on = '2026-08-22'
            }
        )
        Write-TestJson -Path $testQualityPath -Value $snapshot

        $catalog = Import-RouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-Equal $catalog.valid $true
        Assert-Equal @($catalog.errors).Count 0
    }
}

Invoke-Assertion 'quality authorizations require local exactness booleans and reject unknown fields' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root, $testPricingPath, $testQualityPath)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        $profilePath = Join-Path $root 'profiles/agy/shared-model__medium.json'
        Write-TestJson -Path $profilePath -Value (Copy-TestObject @(Get-MinimalProfiles)[0])

        $missingExactness = New-TestQualitySnapshot
        $missingExactness.records[0].quality_authorizations = @($missingExactness.records[0].quality_authorizations[0])
        $missingExactness.records[0].quality_authorizations[0].PSObject.Properties.Remove('exact_model_match')
        Write-TestJson -Path $testQualityPath -Value $missingExactness
        $missingCatalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-CatalogError -Catalog $missingCatalog -Code 'quality_snapshot_authorization_invalid'

        $falseExactness = New-TestQualitySnapshot
        $falseExactness.records[0].quality_authorizations = @($falseExactness.records[0].quality_authorizations[0])
        $falseExactness.records[0].quality_authorizations[0].exact_effort_match = $false
        Write-TestJson -Path $testQualityPath -Value $falseExactness
        $falseCatalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-CatalogError -Catalog $falseCatalog -Code 'quality_snapshot_authorization_invalid'

        $wrongTypeExactness = New-TestQualitySnapshot
        $wrongTypeExactness.records[0].quality_authorizations = @($wrongTypeExactness.records[0].quality_authorizations[0])
        $wrongTypeExactness.records[0].quality_authorizations[0].exact_model_match = 'true'
        Write-TestJson -Path $testQualityPath -Value $wrongTypeExactness
        $wrongTypeCatalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-CatalogError -Catalog $wrongTypeCatalog -Code 'quality_snapshot_authorization_invalid'

        $unknownField = New-TestQualitySnapshot
        $unknownField.records[0].quality_authorizations = @($unknownField.records[0].quality_authorizations[0])
        $unknownField.records[0].quality_authorizations[0] | Add-Member -NotePropertyName exact_model_mach -NotePropertyValue $true
        Write-TestJson -Path $testQualityPath -Value $unknownField
        $unknownFieldCatalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-CatalogError -Catalog $unknownFieldCatalog -Code 'quality_snapshot_authorization_invalid'

        $providerProfile = Copy-TestObject @(Get-MinimalProfiles)[0]
        foreach ($mapName in $requiredQualityKeys.Keys) {
            foreach ($qualityKey in $requiredQualityKeys[$mapName]) { $providerProfile.quality.$mapName.$qualityKey = 'unknown' }
        }
        $providerProfile.quality.capabilities.long_context = 'unsupported'
        $providerProfile.evidence.artificial_analysis.exact_model_match = $false
        $providerProfile.evidence.artificial_analysis.exact_effort_match = $false
        $providerProfile.evidence.artificial_analysis.benchmark_slice = 'unavailable'
        Write-TestJson -Path $profilePath -Value $providerProfile
        $providerSnapshot = New-TestQualitySnapshot
        $providerSnapshot.records[0].exact_model_match = $false
        $providerSnapshot.records[0].exact_effort_match = $false
        $providerSnapshot.records[0].benchmark_slice = 'unavailable'
        $providerSnapshot.records[0].provisional_category = 'unknown'
        $providerSnapshot.records[0].quality_authorizations = @(
            [pscustomobject]@{
                path = '$.quality.capabilities.long_context'
                benchmark_slice = 'provider_capability'
                category = 'unsupported'
                evidence_kind = 'provider'
                exact_model_match = $true
                exact_effort_match = $false
                source_url = 'https://fixtures.invalid/providers/google/shared-model'
                retrieved_on = '2026-08-22'
            }
        )
        Write-TestJson -Path $testQualityPath -Value $providerSnapshot
        $providerCatalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-CatalogError -Catalog $providerCatalog -Code 'quality_snapshot_authorization_invalid'
    }
}

Invoke-Assertion 'independent quality authorizations support multiple relevant benchmark slices without path bleed' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root, $testPricingPath, $testQualityPath)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        $profilePath = Join-Path $root 'profiles/agy/shared-model__medium.json'
        $profile = Copy-TestObject @(Get-MinimalProfiles)[0]
        foreach ($mapName in $requiredQualityKeys.Keys) {
            foreach ($qualityKey in $requiredQualityKeys[$mapName]) { $profile.quality.$mapName.$qualityKey = 'unknown' }
        }
        $profile.quality.task_types.coding = 'strong'
        $profile.quality.domains.mathematics = 'frontier'
        $profile.evidence.artificial_analysis.exact_model_match = $false
        $profile.evidence.artificial_analysis.exact_effort_match = $false
        $profile.evidence.artificial_analysis.benchmark_slice = 'unavailable'
        Write-TestJson -Path $profilePath -Value $profile

        $snapshot = New-TestQualitySnapshot
        $snapshot.records[0].exact_model_match = $false
        $snapshot.records[0].exact_effort_match = $false
        $snapshot.records[0].benchmark_slice = 'unavailable'
        $snapshot.records[0].provisional_category = 'unknown'
        $snapshot.records[0].quality_authorizations = @(
            [pscustomobject]@{
                path = '$.quality.task_types.coding'
                evidence_kind = 'artificial_analysis'
                exact_model_match = $true
                exact_effort_match = $true
                source_url = 'https://fixtures.invalid/artificial-analysis/coding'
                retrieved_on = '2026-08-22'
                benchmark_slice = 'coding'
                category = 'strong'
            },
            [pscustomobject]@{
                path = '$.quality.domains.mathematics'
                evidence_kind = 'artificial_analysis'
                exact_model_match = $true
                exact_effort_match = $true
                source_url = 'https://fixtures.invalid/artificial-analysis/scientific-reasoning'
                retrieved_on = '2026-08-22'
                benchmark_slice = 'scientific_reasoning'
                category = 'frontier'
            }
        )
        Write-TestJson -Path $testQualityPath -Value $snapshot

        $catalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-Equal $catalog.valid $true
        Assert-Equal @($catalog.errors).Count 0

        $profile.quality.domains.physics = 'frontier'
        Write-TestJson -Path $profilePath -Value $profile
        $bleedCatalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-Equal $bleedCatalog.valid $false
        Assert-CatalogError -Catalog $bleedCatalog -Code 'profile_quality_snapshot_mismatch'
    }
}

Invoke-Assertion 'coding authorization cannot authorize mathematics domain quality' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root, $testPricingPath, $testQualityPath)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        $profile = Copy-TestObject @(Get-MinimalProfiles)[0]
        foreach ($mapName in $requiredQualityKeys.Keys) {
            foreach ($qualityKey in $requiredQualityKeys[$mapName]) { $profile.quality.$mapName.$qualityKey = 'unknown' }
        }
        $profile.quality.domains.mathematics = 'frontier'
        $profile.evidence.artificial_analysis.exact_model_match = $true
        $profile.evidence.artificial_analysis.exact_effort_match = $true
        $profile.evidence.artificial_analysis.benchmark_slice = 'coding'
        Write-TestJson -Path (Join-Path $root 'profiles/agy/shared-model__medium.json') -Value $profile

        $snapshot = New-TestQualitySnapshot
        $snapshot.records[0].benchmark_slice = 'coding'
        $snapshot.records[0].provisional_category = 'frontier'
        $snapshot.records[0].quality_authorizations = @(
            [pscustomobject]@{
                path = '$.quality.task_types.coding'
                benchmark_slice = 'coding'
                category = 'frontier'
                evidence_kind = 'artificial_analysis'
                exact_model_match = $true
                exact_effort_match = $true
                source_url = 'https://fixtures.invalid/artificial-analysis/coding'
                retrieved_on = '2026-08-22'
            }
        )
        Write-TestJson -Path $testQualityPath -Value $snapshot

        $catalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-Equal $catalog.valid $false
        Assert-CatalogError -Catalog $catalog -Code 'profile_quality_snapshot_mismatch'
    }
}

Invoke-Assertion 'legacy unsupported path cannot replace provider authorization' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root, $testPricingPath, $testQualityPath)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        $profile = Copy-TestObject @(Get-MinimalProfiles)[0]
        foreach ($mapName in $requiredQualityKeys.Keys) {
            foreach ($qualityKey in $requiredQualityKeys[$mapName]) { $profile.quality.$mapName.$qualityKey = 'unknown' }
        }
        $profile.quality.capabilities.long_context = 'unsupported'
        $profile.evidence.artificial_analysis.exact_model_match = $false
        $profile.evidence.artificial_analysis.exact_effort_match = $false
        $profile.evidence.artificial_analysis.benchmark_slice = 'unavailable'
        Write-TestJson -Path (Join-Path $root 'profiles/agy/shared-model__medium.json') -Value $profile

        $snapshot = New-TestQualitySnapshot
        $snapshot.records[0].exact_model_match = $false
        $snapshot.records[0].exact_effort_match = $false
        $snapshot.records[0].benchmark_slice = 'unavailable'
        $snapshot.records[0].provisional_category = 'unknown'
        $snapshot.records[0].quality_authorizations = @()
        $snapshot.records[0] | Add-Member -NotePropertyName unsupported_quality_paths -NotePropertyValue @('$.quality.capabilities.long_context')
        Write-TestJson -Path $testQualityPath -Value $snapshot

        $catalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-Equal $catalog.valid $false
        Assert-CatalogError -Catalog $catalog -Code 'quality_snapshot_record_invalid'
    }
}

Invoke-Assertion 'quality snapshot rejects invalid path-specific authorizations' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root, $testPricingPath, $testQualityPath)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        Write-TestJson -Path (Join-Path $root 'profiles/agy/shared-model__medium.json') -Value (Copy-TestObject @(Get-MinimalProfiles)[0])

        $duplicate = New-TestQualitySnapshot
        $duplicate.records[0].quality_authorizations = @(
            $duplicate.records[0].quality_authorizations[0],
            (Copy-TestObject $duplicate.records[0].quality_authorizations[0])
        )
        Write-TestJson -Path $testQualityPath -Value $duplicate
        $duplicateCatalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-CatalogError -Catalog $duplicateCatalog -Code 'duplicate_quality_authorization_path'

        $malformed = New-TestQualitySnapshot
        $malformed.records[0].quality_authorizations = @($malformed.records[0].quality_authorizations[0])
        $malformed.records[0].quality_authorizations[0].PSObject.Properties.Remove('evidence_kind')
        Write-TestJson -Path $testQualityPath -Value $malformed
        $malformedCatalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-CatalogError -Catalog $malformedCatalog -Code 'quality_snapshot_authorization_invalid'

        $missingSource = New-TestQualitySnapshot
        $missingSource.records[0].quality_authorizations = @($missingSource.records[0].quality_authorizations[0])
        $missingSource.records[0].quality_authorizations[0].PSObject.Properties.Remove('source_url')
        Write-TestJson -Path $testQualityPath -Value $missingSource
        $missingSourceCatalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-CatalogError -Catalog $missingSourceCatalog -Code 'quality_snapshot_authorization_invalid'

        $badRetrievalDate = New-TestQualitySnapshot
        $badRetrievalDate.records[0].quality_authorizations = @($badRetrievalDate.records[0].quality_authorizations[0])
        $badRetrievalDate.records[0].quality_authorizations[0].retrieved_on = '2026-8-22'
        Write-TestJson -Path $testQualityPath -Value $badRetrievalDate
        $badRetrievalCatalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-CatalogError -Catalog $badRetrievalCatalog -Code 'quality_snapshot_authorization_invalid'

        $unknownPath = New-TestQualitySnapshot
        $unknownPath.records[0].quality_authorizations[0].path = '$.quality.domains.astronomy'
        Write-TestJson -Path $testQualityPath -Value $unknownPath
        $unknownPathCatalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-CatalogError -Catalog $unknownPathCatalog -Code 'quality_snapshot_authorization_invalid'

        $categoryMismatch = New-TestQualitySnapshot
        $categoryMismatch.records[0].quality_authorizations[0].category = 'frontier'
        Write-TestJson -Path $testQualityPath -Value $categoryMismatch
        $categoryCatalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-CatalogError -Catalog $categoryCatalog -Code 'profile_quality_snapshot_mismatch'

        $sliceMismatch = New-TestQualitySnapshot
        $sliceMismatch.records[0].quality_authorizations[0].benchmark_slice = 'coding'
        Write-TestJson -Path $testQualityPath -Value $sliceMismatch
        $sliceCatalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-CatalogError -Catalog $sliceCatalog -Code 'quality_snapshot_authorization_invalid'

        $irrelevantSlice = New-TestQualitySnapshot
        $irrelevantSlice.records[0].quality_authorizations = @(
            [pscustomobject]@{
                path = '$.quality.domains.mathematics'
                benchmark_slice = 'coding'
                category = 'strong'
                evidence_kind = 'artificial_analysis'
                exact_model_match = $true
                exact_effort_match = $true
                source_url = 'https://fixtures.invalid/artificial-analysis/coding'
                retrieved_on = '2026-08-22'
            }
        )
        Write-TestJson -Path $testQualityPath -Value $irrelevantSlice
        $irrelevantSliceCatalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-CatalogError -Catalog $irrelevantSliceCatalog -Code 'quality_snapshot_authorization_invalid'

        $contradictoryEvidence = New-TestQualitySnapshot
        $contradictoryEvidence.records[0].quality_authorizations = @($contradictoryEvidence.records[0].quality_authorizations[0])
        $contradictoryEvidence.records[0].exact_model_match = $false
        $contradictoryEvidence.records[0].exact_effort_match = $false
        $contradictoryEvidence.records[0].benchmark_slice = 'unavailable'
        $contradictoryEvidence.records[0].provisional_category = 'unknown'
        Write-TestJson -Path $testQualityPath -Value $contradictoryEvidence
        $evidenceCatalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-CatalogError -Catalog $evidenceCatalog -Code 'profile_quality_snapshot_mismatch'

        $providerSliceMismatch = New-TestQualitySnapshot
        $providerSliceMismatch.records[0].quality_authorizations = @(
            [pscustomobject]@{
                path = '$.quality.capabilities.long_context'
                benchmark_slice = 'coding'
                category = 'unsupported'
                evidence_kind = 'provider'
                exact_model_match = $true
                exact_effort_match = $true
                source_url = 'https://fixtures.invalid/providers/google/shared-model'
                retrieved_on = '2026-08-22'
            }
        )
        Write-TestJson -Path $testQualityPath -Value $providerSliceMismatch
        $providerCatalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-CatalogError -Catalog $providerCatalog -Code 'quality_snapshot_authorization_invalid'
    }
}

Invoke-Assertion 'profile cannot self-certify frontier quality while the quality snapshot remains unknown' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root, $testPricingPath, $testQualityPath)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        $profile = Copy-TestObject @(Get-MinimalProfiles)[0]
        foreach ($mapName in $requiredQualityKeys.Keys) {
            foreach ($qualityKey in $requiredQualityKeys[$mapName]) { $profile.quality.$mapName.$qualityKey = 'unknown' }
        }
        $profile.quality.task_types.coding = 'frontier'
        $profile.evidence.artificial_analysis.exact_model_match = $true
        $profile.evidence.artificial_analysis.exact_effort_match = $true
        $profile.evidence.artificial_analysis.benchmark_slice = 'coding'
        Write-TestJson -Path (Join-Path $root 'profiles/agy/shared-model__medium.json') -Value $profile

        $snapshot = New-TestQualitySnapshot
        $snapshot.records[0].exact_model_match = $false
        $snapshot.records[0].exact_effort_match = $false
        $snapshot.records[0].benchmark_slice = 'unavailable'
        $snapshot.records[0].provisional_category = 'unknown'
        $snapshot.records[0].quality_authorizations = @()
        Write-TestJson -Path $testQualityPath -Value $snapshot

        $catalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-Equal $catalog.valid $false
        Assert-CatalogError -Catalog $catalog -Code 'profile_quality_snapshot_mismatch'
    }
}

Invoke-Assertion 'quality snapshot record metadata conflict invalidates the profile catalog' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root, $testPricingPath, $testQualityPath)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        Write-TestJson -Path (Join-Path $root 'profiles/agy/shared-model__medium.json') -Value (Copy-TestObject @(Get-MinimalProfiles)[0])
        $snapshot = New-TestQualitySnapshot
        $snapshot.records[0].model = 'conflicting-model'
        Write-TestJson -Path $testQualityPath -Value $snapshot

        $catalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-Equal $catalog.valid $false
        Assert-CatalogError -Catalog $catalog -Code 'profile_quality_snapshot_mismatch'
    }
}

Invoke-Assertion 'quality snapshot requires typed dated top-level provenance metadata' {
    Assert-QualitySnapshotMutationRejected -ExpectedCode 'quality_snapshot_invalid' -Mutation {
        param($snapshot)
        $snapshot.retrieved_on = 123
    }
    Assert-QualitySnapshotMutationRejected -ExpectedCode 'quality_snapshot_invalid' -Mutation {
        param($snapshot)
        $snapshot.methodology_url = $true
    }
    Assert-QualitySnapshotMutationRejected -ExpectedCode 'quality_snapshot_invalid' -Mutation {
        param($snapshot)
        $snapshot.policy = 7
    }
    Assert-QualitySnapshotMutationRejected -ExpectedCode 'quality_snapshot_invalid' -Mutation {
        param($snapshot)
        $snapshot.snapshot_date = '2026-02-30'
    }
    Assert-QualitySnapshotMutationRejected -ExpectedCode 'quality_snapshot_invalid' -Mutation {
        param($snapshot)
        $snapshot.methodology_url = 'ftp://fixtures.invalid/methodology'
    }
}

Invoke-Assertion 'quality snapshot records require strict provenance types URLs dates and fields' {
    Assert-QualitySnapshotMutationRejected -ExpectedCode 'quality_snapshot_record_invalid' -Mutation {
        param($snapshot)
        $snapshot.records[0].source_url = 123
    }
    Assert-QualitySnapshotMutationRejected -ExpectedCode 'quality_snapshot_record_invalid' -Mutation {
        param($snapshot)
        $snapshot.records[0].retrieved_on = '2026-02-30'
    }
    Assert-QualitySnapshotMutationRejected -ExpectedCode 'quality_snapshot_record_invalid' -Mutation {
        param($snapshot)
        $snapshot.records[0].launcher = $true
    }
    Assert-QualitySnapshotMutationRejected -ExpectedCode 'quality_snapshot_record_invalid' -Mutation {
        param($snapshot)
        $snapshot.records[0].source_url = 'mailto:evidence@fixtures.invalid'
    }
    Assert-QualitySnapshotMutationRejected -ExpectedCode 'quality_snapshot_record_invalid' -Mutation {
        param($snapshot)
        $snapshot.records[0] | Add-Member -NotePropertyName exact_effot_match -NotePropertyValue $true
    }
}

Invoke-Assertion 'quality authorization provenance rejects coercion and non-HTTP sources' {
    Assert-QualitySnapshotMutationRejected -ExpectedCode 'quality_snapshot_authorization_invalid' -Mutation {
        param($snapshot)
        $snapshot.records[0].quality_authorizations = @($snapshot.records[0].quality_authorizations[0])
        $snapshot.records[0].quality_authorizations[0].source_url = 123
    }
    Assert-QualitySnapshotMutationRejected -ExpectedCode 'quality_snapshot_authorization_invalid' -Mutation {
        param($snapshot)
        $snapshot.records[0].quality_authorizations = @($snapshot.records[0].quality_authorizations[0])
        $snapshot.records[0].quality_authorizations[0].retrieved_on = 123
    }
    Assert-QualitySnapshotMutationRejected -ExpectedCode 'quality_snapshot_authorization_invalid' -Mutation {
        param($snapshot)
        $snapshot.records[0].quality_authorizations = @($snapshot.records[0].quality_authorizations[0])
        $snapshot.records[0].quality_authorizations[0].source_url = 'file:///tmp/evidence.json'
    }
}

Invoke-Assertion 'quality snapshot malformed JSON returns a structured deterministic error' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root, $testPricingPath, $testQualityPath)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        Write-TestJson -Path (Join-Path $root 'profiles/agy/shared-model__medium.json') -Value (Copy-TestObject @(Get-MinimalProfiles)[0])
        Set-Content -LiteralPath $testQualityPath -Value '{bad quality json' -Encoding utf8NoBOM

        $catalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-Equal $catalog.valid $false
        Assert-CatalogError -Catalog $catalog -Code 'quality_snapshot_json_invalid'
    }
}

Invoke-Assertion 'quality snapshot rejects missing top-level fields and incomplete records' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root, $testPricingPath, $testQualityPath)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        Write-TestJson -Path (Join-Path $root 'profiles/agy/shared-model__medium.json') -Value (Copy-TestObject @(Get-MinimalProfiles)[0])

        $missingTopLevel = New-TestQualitySnapshot
        $missingTopLevel.PSObject.Properties.Remove('policy')
        Write-TestJson -Path $testQualityPath -Value $missingTopLevel
        $topLevelCatalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-CatalogError -Catalog $topLevelCatalog -Code 'quality_snapshot_invalid'

        $incompleteRecord = New-TestQualitySnapshot
        $incompleteRecord.records[0].PSObject.Properties.Remove('effort')
        Write-TestJson -Path $testQualityPath -Value $incompleteRecord
        $recordCatalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-CatalogError -Catalog $recordCatalog -Code 'quality_snapshot_record_invalid'
    }
}

Invoke-Assertion 'quality snapshot rejects scalar record and authorization collections' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root, $testPricingPath, $testQualityPath)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        Write-TestJson -Path (Join-Path $root 'profiles/agy/shared-model__medium.json') -Value (Copy-TestObject @(Get-MinimalProfiles)[0])

        $scalarRecords = New-TestQualitySnapshot
        $scalarRecords.records = $scalarRecords.records[0]
        Write-TestJson -Path $testQualityPath -Value $scalarRecords
        $recordsCatalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-CatalogError -Catalog $recordsCatalog -Code 'quality_snapshot_invalid'

        $scalarAuthorizations = New-TestQualitySnapshot
        $scalarAuthorizations.records[0].quality_authorizations = '$.quality.capabilities.long_context'
        Write-TestJson -Path $testQualityPath -Value $scalarAuthorizations
        $pathsCatalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-CatalogError -Catalog $pathsCatalog -Code 'quality_snapshot_authorization_invalid'
    }
}

Invoke-Assertion 'quality snapshot rejects duplicate composite identities' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root, $testPricingPath, $testQualityPath)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        Write-TestJson -Path (Join-Path $root 'profiles/agy/shared-model__medium.json') -Value (Copy-TestObject @(Get-MinimalProfiles)[0])
        $snapshot = New-TestQualitySnapshot
        $duplicate = Copy-TestObject $snapshot.records[0]
        $snapshot.records = @($snapshot.records[0], $duplicate)
        Write-TestJson -Path $testQualityPath -Value $snapshot

        $catalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-Equal $catalog.valid $false
        Assert-CatalogError -Catalog $catalog -Code 'duplicate_quality_snapshot_identity'
    }
}

Invoke-Assertion 'quality snapshot requires one record per enabled profile and rejects unexpected records' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root, $testPricingPath, $testQualityPath)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        Write-TestJson -Path (Join-Path $root 'profiles/agy/shared-model__medium.json') -Value (Copy-TestObject @(Get-MinimalProfiles)[0])

        $missingSnapshot = New-TestQualitySnapshot
        $missingSnapshot.records = @()
        Write-TestJson -Path $testQualityPath -Value $missingSnapshot
        $missingCatalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-CatalogError -Catalog $missingCatalog -Code 'quality_snapshot_record_missing'

        $unexpectedSnapshot = New-TestQualitySnapshot
        $unexpectedRecord = Copy-TestObject $unexpectedSnapshot.records[0]
        $unexpectedRecord.launcher = 'codex'
        $unexpectedRecord.configuration_id = 'other-model__medium'
        $unexpectedRecord.model = 'other-model'
        $unexpectedSnapshot.records = @($unexpectedSnapshot.records[0], $unexpectedRecord)
        Write-TestJson -Path $testQualityPath -Value $unexpectedSnapshot
        $unexpectedCatalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-CatalogError -Catalog $unexpectedCatalog -Code 'quality_snapshot_record_unexpected'
    }
}

Invoke-Assertion 'catalog reports missing profile coverage before routing' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root, $testPricingPath, $testQualityPath)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        $catalog = Import-RouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-Equal $catalog.valid $false
        Assert-CatalogError -Catalog $catalog -Code 'profile_coverage_missing'
    }
}

Invoke-Assertion 'catalog reports duplicate launcher and configuration identity' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root, $testPricingPath, $testQualityPath)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        $profile = Copy-TestObject @(Get-MinimalProfiles)[0]
        Write-TestJson -Path (Join-Path $root 'profiles/agy/a.json') -Value $profile
        Write-TestJson -Path (Join-Path $root 'profiles/agy/b.json') -Value $profile
        $catalog = Import-RouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-Equal $catalog.valid $false
        Assert-CatalogError -Catalog $catalog -Code 'duplicate_profile_identity'
    }
}

Invoke-Assertion 'catalog reports malformed JSON and schema-invalid profiles structurally' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root, $testPricingPath, $testQualityPath)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        $profileDir = Join-Path $root 'profiles/agy'
        $null = New-Item -ItemType Directory -Path $profileDir -Force
        Set-Content -LiteralPath (Join-Path $profileDir 'a-malformed.json') -Value '{bad json' -Encoding utf8NoBOM
        $invalidProfile = Copy-TestObject @(Get-MinimalProfiles)[0]
        $invalidProfile.quality.task_types.PSObject.Properties.Remove('coding')
        Write-TestJson -Path (Join-Path $profileDir 'b-schema-invalid.json') -Value $invalidProfile
        $catalog = Import-RouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-Equal $catalog.valid $false
        Assert-CatalogError -Catalog $catalog -Code 'profile_json_invalid'
        Assert-CatalogError -Catalog $catalog -Code 'profile_schema_invalid'
    }
}

Invoke-Assertion 'catalog schema validation cannot be bypassed by an ambient shadow function' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root, $testPricingPath, $testQualityPath)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        $invalidProfile = Copy-TestObject @(Get-MinimalProfiles)[0]
        $invalidProfile.quality.task_types.PSObject.Properties.Remove('coding')
        Write-TestJson -Path (Join-Path $root 'profiles/agy/shared-model__medium.json') -Value $invalidProfile

        $originalSchemaCache = $script:RouterSchemaContextCache
        $schemaCacheSentinel = [pscustomobject]@{ marker = 'caller-cache-sentinel' }
        $script:RouterSchemaContextCache = $schemaCacheSentinel
        try {
            & {
                function Test-RouterSchema {
                    [pscustomobject]@{ valid = $true; errors = @(); shadow = $true }
                }

                $locationBefore = (Get-Location).Path
                $catalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
                Assert-Equal $catalog.valid $false
                Assert-CatalogError -Catalog $catalog -Code 'profile_schema_invalid'
                Assert-Equal (Get-Location).Path $locationBefore
                Assert-Equal (Test-RouterSchema).shadow $true
                Assert-Equal ([object]::ReferenceEquals($script:RouterSchemaContextCache, $schemaCacheSentinel)) $true
            }
        } finally {
            $script:RouterSchemaContextCache = $originalSchemaCache
        }
    }
}

Invoke-Assertion 'catalog module creation cannot be bypassed by ambient New-Module shadowing' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root, $testPricingPath, $testQualityPath)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        $invalidProfile = Copy-TestObject @(Get-MinimalProfiles)[0]
        $invalidProfile.quality.task_types.PSObject.Properties.Remove('coding')
        Write-TestJson -Path (Join-Path $root 'profiles/agy/shared-model__medium.json') -Value $invalidProfile

        $shadowModuleName = 'RouterSchemaShadowProbe_{0}' -f [guid]::NewGuid().ToString('N')
        $shadowModule = Microsoft.PowerShell.Core\New-Module -Name $shadowModuleName -ScriptBlock {
            function Test-RouterSchema {
                [pscustomobject]@{ valid = $true; errors = @(); shadow = $true }
            }
            Microsoft.PowerShell.Core\Export-ModuleMember -Function @() -Variable @()
        }
        $originalSchemaCache = $script:RouterSchemaContextCache
        $schemaCacheSentinel = [pscustomobject]@{ marker = 'caller-cache-sentinel' }
        $script:RouterSchemaContextCache = $schemaCacheSentinel
        try {
            & {
                function New-Module { $shadowModule }

                $locationBefore = (Get-Location).Path
                $privateModuleCountBefore = @(Get-Module -Name 'RouterSchemaValidation_*').Count
                $catalog = Import-TestRouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
                Assert-Equal $catalog.valid $false
                Assert-CatalogError -Catalog $catalog -Code 'profile_schema_invalid'
                Assert-Equal (Get-Location).Path $locationBefore
                Assert-Equal ([object]::ReferenceEquals((New-Module), $shadowModule)) $true
                Assert-Equal ([object]::ReferenceEquals($script:RouterSchemaContextCache, $schemaCacheSentinel)) $true
                Assert-Equal @(Get-Module -Name 'RouterSchemaValidation_*').Count $privateModuleCountBefore
            }
        } finally {
            $script:RouterSchemaContextCache = $originalSchemaCache
            Microsoft.PowerShell.Core\Remove-Module -ModuleInfo $shadowModule -Force -ErrorAction SilentlyContinue
        }
    }
}

Invoke-Assertion 'catalog semantically validates embedded provider and benchmark provenance' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root, $testPricingPath, $testQualityPath)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)

        $baseProfile = Copy-TestObject @(Get-MinimalProfiles)[0]
        foreach ($mapName in $requiredQualityKeys.Keys) {
            foreach ($qualityKey in $requiredQualityKeys[$mapName]) {
                $baseProfile.quality.$mapName.$qualityKey = 'unknown'
            }
        }
        $baseProfile.evidence.artificial_analysis.exact_model_match = $false
        $baseProfile.evidence.artificial_analysis.exact_effort_match = $false
        $baseProfile.evidence.artificial_analysis.benchmark_slice = 'unavailable'

        $qualitySnapshot = New-TestQualitySnapshot
        $qualitySnapshot.records[0].exact_model_match = $false
        $qualitySnapshot.records[0].exact_effort_match = $false
        $qualitySnapshot.records[0].benchmark_slice = 'unavailable'
        $qualitySnapshot.records[0].provisional_category = 'unknown'
        $qualitySnapshot.records[0].quality_authorizations = @()
        Write-TestJson -Path $testQualityPath -Value $qualitySnapshot

        $cases = @(
            [pscustomobject]@{ code = 'profile_provider_evidence_invalid'; mutation = { param($profile) $profile.evidence.provider.source_url = 'ftp://fixtures.invalid/provider' } }
            [pscustomobject]@{ code = 'profile_provider_evidence_invalid'; mutation = { param($profile) $profile.evidence.provider.retrieved_on = 'not-a-date' } }
            [pscustomobject]@{ code = 'profile_artificial_analysis_evidence_invalid'; mutation = { param($profile) $profile.evidence.artificial_analysis.source_url = 'ftp://fixtures.invalid/benchmark' } }
            [pscustomobject]@{ code = 'profile_artificial_analysis_evidence_invalid'; mutation = { param($profile) $profile.evidence.artificial_analysis.retrieved_on = 'not-a-date' } }
        )
        foreach ($case in $cases) {
            $profile = Copy-TestObject $baseProfile
            & $case.mutation $profile
            Write-TestJson -Path (Join-Path $root 'profiles/agy/shared-model__medium.json') -Value $profile
            $catalog = Import-RouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
            Assert-Equal $catalog.valid $false
            Assert-CatalogError -Catalog $catalog -Code $case.code
        }
    }
}

Invoke-Assertion 'catalog rejects duplicate JSON property names instead of silently taking the last value' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root, $testPricingPath, $testQualityPath)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        $profile = Copy-TestObject @(Get-MinimalProfiles)[0]
        $profilePath = Join-Path $root 'profiles/agy/shared-model__medium.json'
        Write-TestJson -Path $profilePath -Value $profile
        $profileText = [IO.File]::ReadAllText($profilePath)
        $profileText = $profileText.Replace('"launcher": "agy",', '"launcher": "agy",' + [Environment]::NewLine + '  "launcher": "codex",')
        [IO.File]::WriteAllText($profilePath, $profileText, [Text.UTF8Encoding]::new($false))

        $catalog = Import-RouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-Equal $catalog.valid $false
        Assert-CatalogError -Catalog $catalog -Code 'profile_json_invalid'
    }
}

Invoke-Assertion 'catalog reports candidate identity mismatch and pricing-state misuse' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root, $testPricingPath, $testQualityPath)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix -Provider 'anthropic')
        $profile = Copy-TestObject @(Get-MinimalProfiles)[0]
        $profile.pricing.cost_comparable = $false
        Write-TestJson -Path (Join-Path $root 'profiles/agy/shared-model__medium.json') -Value $profile
        $catalog = Import-RouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-Equal $catalog.valid $false
        Assert-CatalogError -Catalog $catalog -Code 'candidate_profile_mismatch'
        Assert-CatalogError -Catalog $catalog -Code 'profile_pricing_invalid'
    }
}

Invoke-Assertion 'catalog reports unavailable-latency state misuse' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root, $testPricingPath, $testQualityPath)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        $profile = Copy-TestObject @(Get-MinimalProfiles)[0]
        $profile.latency_observation.available = $false
        Write-TestJson -Path (Join-Path $root 'profiles/agy/shared-model__medium.json') -Value $profile
        $catalog = Import-RouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        Assert-Equal $catalog.valid $false
        Assert-CatalogError -Catalog $catalog -Code 'profile_latency_invalid'
    }
}

Invoke-Assertion 'catalog error ordering is deterministic by code file and identity' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root, $testPricingPath, $testQualityPath)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        $profileDir = Join-Path $root 'profiles/agy'
        $null = New-Item -ItemType Directory -Path $profileDir -Force
        Set-Content -LiteralPath (Join-Path $profileDir 'z.json') -Value '{bad z' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $profileDir 'a.json') -Value '{bad a' -Encoding utf8NoBOM
        $first = Import-RouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        $second = Import-RouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $testPricingPath -QualitySnapshotPath $testQualityPath
        [string[]]$firstErrors = @($first.errors | ForEach-Object { '{0}|{1}|{2}' -f $_.code, $_.file, $_.identity })
        [string[]]$secondErrors = @($second.errors | ForEach-Object { '{0}|{1}|{2}' -f $_.code, $_.file, $_.identity })
        Assert-SequenceEqual $firstErrors $secondErrors
        [string[]]$sortedErrors = @($firstErrors)
        [Array]::Sort($sortedErrors, [System.StringComparer]::Ordinal)
        Assert-SequenceEqual $firstErrors $sortedErrors
    }
}

Invoke-Assertion 'integer fields accept every finite integral numeric representation' {
    $integralValues = @(
        [byte]42
        [sbyte]42
        [int16]42
        [uint16]42
        [int32]42
        [uint32]42
        [int64]42
        [uint64]42
        [System.Numerics.BigInteger]42
        [single]128000.0
        [double]128000.0
        [decimal]128000.0
    )
    $validProfile = @(Get-MinimalProfiles)[0]

    foreach ($integralValue in $integralValues) {
        $profile = Copy-TestObject $validProfile
        $profile.supports.context_window_tokens = $integralValue

        Assert-ValidationSuccess (Test-RouterSchema -Value $profile -SchemaPath $profileSchemaPath)
    }
}

Invoke-Assertion 'integer fields reject fractional and boolean values' {
    $invalidIntegerValues = @(
        [double]128000.5
        [single]128000.5
        [decimal]128000.5
        $true
    )
    $validProfile = @(Get-MinimalProfiles)[0]

    foreach ($invalidValue in $invalidIntegerValues) {
        $profile = Copy-TestObject $validProfile
        $profile.supports.context_window_tokens = $invalidValue

        $validation = Test-RouterSchema -Value $profile -SchemaPath $profileSchemaPath
        Assert-ValidationError -Validation $validation -Code 'type_mismatch' -Path '$.supports.context_window_tokens'
    }
}

Invoke-Assertion 'integer fields reject non-finite native values before serialization' {
    $validProfile = @(Get-MinimalProfiles)[0]
    foreach ($invalidValue in @(
        [double]::NaN
        [double]::PositiveInfinity
        [double]::NegativeInfinity
        [single]::NaN
        [single]::PositiveInfinity
        [single]::NegativeInfinity
    )) {
        $profile = Copy-TestObject $validProfile
        $profile.supports.context_window_tokens = $invalidValue

        Assert-ValidationErrorsExactly -Validation (
            Test-RouterSchema -Value $profile -SchemaPath $profileSchemaPath
        ) -ExpectedErrors @(
            [pscustomobject]@{ code = 'value_not_json'; path = '$.supports.context_window_tokens' }
        )
    }
}

Invoke-Assertion 'number fields accept finite integer decimal and floating values' {
    $finiteNumericValues = @(
        [int64]1
        [System.Numerics.BigInteger]1
        [decimal]0.25
        [single]0.25
        [double]0.25
    )

    foreach ($numericValue in $finiteNumericValues) {
        $response = New-MinimalCompletedResponse
        $response.price = $numericValue

        Assert-ValidationSuccess (Test-RouterSchema -Value $response -SchemaPath $responseSchemaPath)
    }
}

Invoke-Assertion 'number fields reject booleans' {
    $response = New-MinimalCompletedResponse
    $response.price = $false

    $validation = Test-RouterSchema -Value $response -SchemaPath $responseSchemaPath
    Assert-ValidationError -Validation $validation -Code 'type_mismatch' -Path '$.price'
}

Invoke-Assertion 'completed response rejects tiny negative price and latency values' {
    foreach ($fieldName in @('price', 'latency')) {
        foreach ($tinyNegative in @([double]-1e-100, -[double]::Epsilon)) {
            $response = New-MinimalCompletedResponse
            $response.$fieldName = $tinyNegative

            Assert-ValidationErrorsExactly -Validation (
                Test-RouterSchema -Value $response -SchemaPath $responseSchemaPath
            ) -ExpectedErrors @(
                [pscustomobject]@{ code = 'number_below_minimum'; path = ('$.{0}' -f $fieldName) }
            )
        }
    }
}

Invoke-Assertion 'profile rates and latency milliseconds reject tiny negatives' {
    $minimumZeroFields = @(
        [pscustomobject]@{ path = '$.pricing.input_usd_per_million_tokens'; set = { param($profile, $value) $profile.pricing.input_usd_per_million_tokens = $value } }
        [pscustomobject]@{ path = '$.pricing.output_usd_per_million_tokens'; set = { param($profile, $value) $profile.pricing.output_usd_per_million_tokens = $value } }
        [pscustomobject]@{ path = '$.latency_observation.milliseconds'; set = { param($profile, $value) $profile.latency_observation.milliseconds = $value } }
    )
    $validProfile = @(Get-MinimalProfiles)[0]

    foreach ($field in $minimumZeroFields) {
        foreach ($tinyNegative in @([double]-1e-100, -[double]::Epsilon)) {
            $profile = Copy-TestObject $validProfile
            & $field.set $profile $tinyNegative
            Assert-ValidationErrorsExactly -Validation (
                Test-RouterSchema -Value $profile -SchemaPath $profileSchemaPath
            ) -ExpectedErrors @(
                [pscustomobject]@{ code = 'number_below_minimum'; path = $field.path }
            )
        }
    }
}

Invoke-Assertion 'completed response accumulates minimum and required diagnostics without duplicates' {
    $response = New-MinimalCompletedResponse
    $response.PSObject.Properties.Remove('configuration_id')
    $response.price = [double]-1e-100

    $validation = Test-RouterSchema -Value $response -SchemaPath $responseSchemaPath
    Assert-False $validation.valid
    [string[]]$actual = @($validation.errors | ForEach-Object { '{0}|{1}' -f $_.code, $_.path })
    Assert-SequenceEqual -Actual $actual -Expected @(
        'number_below_minimum|$.price'
        'required_property_missing|$.configuration_id'
    )
}

Invoke-Assertion 'profile accumulates minimum and required diagnostics without duplicates' {
    $profile = Copy-TestObject @(Get-MinimalProfiles)[0]
    $profile.PSObject.Properties.Remove('configuration_id')
    $profile.pricing.input_usd_per_million_tokens = [double]-1e-100

    $validation = Test-RouterSchema -Value $profile -SchemaPath $profileSchemaPath
    Assert-False $validation.valid
    [string[]]$actual = @($validation.errors | ForEach-Object { '{0}|{1}' -f $_.code, $_.path })
    Assert-SequenceEqual -Actual $actual -Expected @(
        'number_below_minimum|$.pricing.input_usd_per_million_tokens'
        'required_property_missing|$.configuration_id'
    )
}

Invoke-Assertion 'minimum one integer fields reject every tested value below one and accept one' {
    $minimumOneFields = @(
        [pscustomobject]@{ path = '$.supports.context_window_tokens'; set = { param($profile, $value) $profile.supports.context_window_tokens = $value } }
        [pscustomobject]@{ path = '$.supports.maximum_output_tokens'; set = { param($profile, $value) $profile.supports.maximum_output_tokens = $value } }
        [pscustomobject]@{ path = '$.latency_observation.sample_count'; set = { param($profile, $value) $profile.latency_observation.sample_count = $value } }
    )
    $validProfile = @(Get-MinimalProfiles)[0]

    foreach ($field in $minimumOneFields) {
        foreach ($belowMinimum in @([int]0, [int]-1)) {
            $profile = Copy-TestObject $validProfile
            & $field.set $profile $belowMinimum
            Assert-ValidationErrorsExactly -Validation (
                Test-RouterSchema -Value $profile -SchemaPath $profileSchemaPath
            ) -ExpectedErrors @(
                [pscustomobject]@{ code = 'number_below_minimum'; path = $field.path }
            )
        }

        foreach ($fractionalBelowMinimum in @([decimal]0.5, [double]-1e-100)) {
            $profile = Copy-TestObject $validProfile
            & $field.set $profile $fractionalBelowMinimum
            Assert-ValidationErrorsExactly -Validation (
                Test-RouterSchema -Value $profile -SchemaPath $profileSchemaPath
            ) -ExpectedErrors @(
                [pscustomobject]@{ code = 'number_below_minimum'; path = $field.path }
                [pscustomobject]@{ code = 'type_mismatch'; path = $field.path }
            )
        }

        $profile = Copy-TestObject $validProfile
        & $field.set $profile ([int]1)
        Assert-ValidationSuccess (Test-RouterSchema -Value $profile -SchemaPath $profileSchemaPath)
    }
}

Invoke-Assertion 'number fields reject non-finite native values before serialization' {
    foreach ($invalidValue in @(
        [double]::NaN
        [double]::PositiveInfinity
        [double]::NegativeInfinity
        [single]::NaN
        [single]::PositiveInfinity
        [single]::NegativeInfinity
    )) {
        $response = New-MinimalCompletedResponse
        $response.price = $invalidValue

        Assert-ValidationErrorsExactly -Validation (
            Test-RouterSchema -Value $response -SchemaPath $responseSchemaPath
        ) -ExpectedErrors @(
            [pscustomobject]@{ code = 'value_not_json'; path = '$.price' }
        )
    }
}

Invoke-Assertion 'profile schema rejects every omitted required field' {
    $validProfile = @(Get-MinimalProfiles)[0]

    foreach ($requiredPath in $requiredProfilePaths) {
        $invalidProfile = Copy-TestObject $validProfile
        Remove-TestProperty -Value $invalidProfile -Path $requiredPath

        $validation = Test-RouterSchema -Value $invalidProfile -SchemaPath $profileSchemaPath

        Assert-RequiredPropertyError -Validation $validation -Path $requiredPath
    }
}

Invoke-Assertion 'profile schema rejects every omitted required quality key' {
    $validProfiles = @(Get-MinimalProfiles)
    $validProfile = $validProfiles[0]

    foreach ($mapName in $requiredQualityKeys.Keys) {
        $actualKeys = @($validProfile.quality.$mapName.PSObject.Properties.Name | Sort-Object)
        $expectedKeys = @($requiredQualityKeys[$mapName] | Sort-Object)
        Assert-SequenceEqual $actualKeys $expectedKeys

        foreach ($qualityKey in $requiredQualityKeys[$mapName]) {
            $invalidProfile = Copy-TestObject $validProfile
            $invalidProfile.quality.$mapName.PSObject.Properties.Remove($qualityKey)

            $validation = Test-RouterSchema -Value $invalidProfile -SchemaPath $profileSchemaPath

            Assert-RequiredPropertyError -Validation $validation -Path "$.quality.$mapName.$qualityKey"
        }
    }
}

Invoke-Assertion 'profile schema accepts every explicit quality category at every quality key' {
    $validProfile = @(Get-MinimalProfiles)[0]
    foreach ($mapName in $requiredQualityKeys.Keys) {
        foreach ($qualityKey in $requiredQualityKeys[$mapName]) {
            foreach ($qualityCategory in $qualityCategories) {
                $profile = Copy-TestObject $validProfile
                $profile.quality.$mapName.$qualityKey = $qualityCategory

                Assert-ValidationSuccess (Test-RouterSchema -Value $profile -SchemaPath $profileSchemaPath)
            }
        }
    }
}

Invoke-Assertion 'profile schema rejects an unapproved category at every quality key' {
    $validProfile = @(Get-MinimalProfiles)[0]
    foreach ($mapName in $requiredQualityKeys.Keys) {
        foreach ($qualityKey in $requiredQualityKeys[$mapName]) {
            $invalidProfile = Copy-TestObject $validProfile
            $invalidProfile.quality.$mapName.$qualityKey = 'unrated'
            $validation = Test-RouterSchema -Value $invalidProfile -SchemaPath $profileSchemaPath
            Assert-ValidationError -Validation $validation -Code 'enum_value_not_allowed' -Path "$.quality.$mapName.$qualityKey"
        }
    }
}

Invoke-Assertion 'response schema accepts every approved status' {
    $completed = New-MinimalCompletedResponse
    Assert-ValidationSuccess (Test-RouterSchema -Value $completed -SchemaPath $responseSchemaPath)

    foreach ($failureStatus in $failureStatuses) {
        $failure = New-MinimalFailureResponse
        $failure.status = $failureStatus

        Assert-ValidationSuccess (Test-RouterSchema -Value $failure -SchemaPath $responseSchemaPath)
    }

    $observedStatuses = @('completed') + $failureStatuses
    Assert-SequenceEqual $observedStatuses $responseStatuses
}

Invoke-Assertion 'response schema rejects an unsupported status' {
    $response = New-MinimalFailureResponse
    $response.status = 'partial'

    $validation = Test-RouterSchema -Value $response -SchemaPath $responseSchemaPath

    Assert-ValidationError -Validation $validation -Code 'enum_value_not_allowed' -Path '$.status'
}

Invoke-Assertion 'response schema returns structured errors for unsupported status under strict mode' {
    & {
        Set-StrictMode -Version Latest
        $response = New-MinimalFailureResponse
        $response.status = 'partial'

        $validation = Test-RouterSchema -Value $response -SchemaPath $responseSchemaPath

        Assert-ValidationError -Validation $validation -Code 'enum_value_not_allowed' -Path '$.status'
    }
}

Invoke-Assertion 'response schema treats a wrong-case discriminator as missing and additional' {
    $response = New-MinimalCompletedResponse
    $response.PSObject.Properties.Remove('status')
    $response | Add-Member -NotePropertyName 'Status' -NotePropertyValue 'completed'

    $validation = Test-RouterSchema -Value $response -SchemaPath $responseSchemaPath

    Assert-ValidationErrorsExactly -Validation $validation -ExpectedErrors @(
        [pscustomobject]@{ code = 'required_property_missing'; path = '$.status' }
        [pscustomobject]@{ code = 'additional_property_not_allowed'; path = '$.Status' }
    )
}

Invoke-Assertion 'response schema accepts every approved reason code and rejects other values' {
    foreach ($reasonCode in $reasonCodes) {
        $response = New-MinimalFailureResponse
        $response.reason_code = $reasonCode

        Assert-ValidationSuccess (Test-RouterSchema -Value $response -SchemaPath $responseSchemaPath)
    }

    $response = New-MinimalFailureResponse
    $response.reason_code = 'unknown_failure'
    $validation = Test-RouterSchema -Value $response -SchemaPath $responseSchemaPath
    Assert-ValidationError -Validation $validation -Code 'enum_value_not_allowed' -Path '$.reason_code'
}

Invoke-Assertion 'response schema rejects every omitted completed-response field' {
    foreach ($requiredPath in $requiredCompletedResponsePaths) {
        $response = New-MinimalCompletedResponse
        Remove-TestProperty -Value $response -Path $requiredPath

        $validation = Test-RouterSchema -Value $response -SchemaPath $responseSchemaPath

        Assert-RequiredPropertyError -Validation $validation -Path $requiredPath
    }
}

Invoke-Assertion 'response schema attributes a malformed completed response to the completed branch' {
    $response = [pscustomobject]@{ status = 'completed' }

    $validation = Test-RouterSchema -Value $response -SchemaPath $responseSchemaPath

    Assert-RequiredPropertyError -Validation $validation -Path '$.configuration_id'
    Assert-Equal @($validation.errors | Where-Object { $_.path -ceq '$.reason_code' }).Count 0
    Assert-Equal @($validation.errors | Where-Object { $_.path -ceq '$.status' }).Count 0
}

Invoke-Assertion 'response schema rejects every omitted failure-response field' {
    foreach ($requiredPath in $requiredFailureResponsePaths) {
        $response = New-MinimalFailureResponse
        Remove-TestProperty -Value $response -Path $requiredPath

        $validation = Test-RouterSchema -Value $response -SchemaPath $responseSchemaPath

        Assert-RequiredPropertyError -Validation $validation -Path $requiredPath
    }
}

Invoke-Assertion 'response schema keeps success and failure shapes distinct' {
    $completedWithReason = New-MinimalCompletedResponse
    $completedWithReason | Add-Member -NotePropertyName 'reason_code' -NotePropertyValue 'launcher_execution_failed'
    $validation = Test-RouterSchema -Value $completedWithReason -SchemaPath $responseSchemaPath
    Assert-ValidationError -Validation $validation -Code 'additional_property_not_allowed' -Path '$.reason_code'

    $failureWithOutput = New-MinimalFailureResponse
    $failureWithOutput | Add-Member -NotePropertyName 'output' -NotePropertyValue 'partial output'
    $validation = Test-RouterSchema -Value $failureWithOutput -SchemaPath $responseSchemaPath
    Assert-ValidationError -Validation $validation -Code 'additional_property_not_allowed' -Path '$.output'
}

Invoke-Assertion 'schema loading failures are structured instead of thrown' {
    $missingSchemaPath = Join-Path $PSScriptRoot 'fixtures/does-not-exist.schema.json'

    $validation = Test-RouterSchema -Value (New-MinimalRequest) -SchemaPath $missingSchemaPath

    Assert-ValidationError -Validation $validation -Code 'schema_not_found' -Path '$'
}

Invoke-Assertion 'malformed schema paths return structured errors instead of throwing' {
    $malformedSchemaPath = 'invalid{0}schema.json' -f [char]0

    Assert-ValidationErrorsExactly -Validation (
        Test-RouterSchema -Value (New-MinimalRequest) -SchemaPath $malformedSchemaPath
    ) -ExpectedErrors @(
        [pscustomobject]@{ code = 'schema_invalid'; path = '$' }
    )
}

Invoke-Assertion 'unchanged schema context is reused and modification stamps invalidate it' {
    $schemaPath = Join-Path ([IO.Path]::GetTempPath()) ('router-schema-cache-{0}.json' -f [guid]::NewGuid().ToString('N'))
    try {
        [pscustomobject]@{ type = 'string' } | ConvertTo-Json -Compress |
            Set-Content -LiteralPath $schemaPath -Encoding utf8NoBOM
        Assert-ValidationSuccess (Test-RouterSchema -Value 'cached' -SchemaPath $schemaPath)

        $lock = [IO.File]::Open($schemaPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            Assert-ValidationSuccess (Test-RouterSchema -Value 'cached' -SchemaPath $schemaPath)
        } finally {
            $lock.Dispose()
        }

        [pscustomobject]@{ type = 'number' } | ConvertTo-Json -Compress |
            Set-Content -LiteralPath $schemaPath -Encoding utf8NoBOM
        [IO.File]::SetLastWriteTimeUtc($schemaPath, [datetime]::UtcNow.AddSeconds(1))
        Assert-ValidationError -Validation (Test-RouterSchema -Value 'cached' -SchemaPath $schemaPath) -Code 'type_mismatch' -Path '$'
        Assert-ValidationSuccess (Test-RouterSchema -Value 1 -SchemaPath $schemaPath)
    } finally {
        if (Test-Path -LiteralPath $schemaPath) { Remove-Item -LiteralPath $schemaPath -Force }
    }
}

Invoke-Assertion 'returned schema context and local parse cannot poison the cache' {
    try {
        $context = Get-RouterSchemaContext $responseSchemaPath
        $localSchema = $context.schema_text | ConvertFrom-Json -Depth 100
        $localSchema.oneOf[0].properties.price.minimum = -1

        $context.schema_text = '{"type":"object"}'
        $cachedSchemaProperty = Get-RouterExactProperty $context 'schema'
        if ($null -ne $cachedSchemaProperty) {
            $cachedSchemaProperty.Value.oneOf[0].properties.price.minimum = -1
        }

        $response = New-MinimalCompletedResponse
        $response.price = [double]-1e-100
        Assert-ValidationErrorsExactly -Validation (
            Test-RouterSchema -Value $response -SchemaPath $responseSchemaPath
        ) -ExpectedErrors @(
            [pscustomobject]@{ code = 'number_below_minimum'; path = '$.price' }
        )
    } finally {
        $script:RouterSchemaContextCache.Clear()
    }
}

$draft202012 = 'https://json-schema.org/draft/2020-12/schema'
$malformedSchemaCases = @(
    [pscustomobject]@{ name = 'boolean root schema'; schema = $true; path = '$' }
    [pscustomobject]@{ name = 'empty oneOf'; schema = [pscustomobject]@{ oneOf = @() }; path = '$.oneOf' }
    [pscustomobject]@{ name = 'empty anyOf'; schema = [pscustomobject]@{ anyOf = @() }; path = '$.anyOf' }
    [pscustomobject]@{ name = 'non-object oneOf branch'; schema = [pscustomobject]@{ oneOf = @('invalid') }; path = '$.oneOf[0]' }
    [pscustomobject]@{ name = 'boolean oneOf branch'; schema = [pscustomobject]@{ oneOf = @($true) }; path = '$.oneOf[0]' }
    [pscustomobject]@{ name = 'unknown pattern keyword'; schema = [pscustomobject]@{ pattern = '^safe$' }; path = '$.pattern' }
    [pscustomobject]@{ name = 'unknown allOf keyword'; schema = [pscustomobject]@{ allOf = @([pscustomobject]@{ type = 'string' }) }; path = '$.allOf' }
    [pscustomobject]@{ name = 'unknown maxLength keyword'; schema = [pscustomobject]@{ maxLength = 10 }; path = '$.maxLength' }
    [pscustomobject]@{ name = 'unsupported type name'; schema = [pscustomobject]@{ type = 'date' }; path = '$.type' }
    [pscustomobject]@{ name = 'duplicate type-array entry'; schema = [pscustomobject]@{ '$schema' = $draft202012; type = @('string', 'string') }; path = '$.type[1]' }
    [pscustomobject]@{ name = 'required is not an array'; schema = [pscustomobject]@{ required = 'name' }; path = '$.required' }
    [pscustomobject]@{ name = 'required contains a non-string entry'; schema = [pscustomobject]@{ '$schema' = $draft202012; required = @(1) }; path = '$.required[0]' }
    [pscustomobject]@{ name = 'required contains a duplicate exact name'; schema = [pscustomobject]@{ '$schema' = $draft202012; required = @('name', 'name') }; path = '$.required[1]' }
    [pscustomobject]@{ name = 'enum is not an array'; schema = [pscustomobject]@{ enum = 'value' }; path = '$.enum' }
    [pscustomobject]@{ name = 'properties is not an object'; schema = [pscustomobject]@{ properties = 'invalid' }; path = '$.properties' }
    [pscustomobject]@{ name = 'minimum is not numeric'; schema = [pscustomobject]@{ minimum = 'zero' }; path = '$.minimum' }
    [pscustomobject]@{ name = 'minimum is boolean'; schema = [pscustomobject]@{ minimum = $true }; path = '$.minimum' }
    [pscustomobject]@{ name = 'minimum is outside the audited zero-or-one form'; schema = [pscustomobject]@{ minimum = 2 }; path = '$.minimum' }
    [pscustomobject]@{ name = 'minLength is negative'; schema = [pscustomobject]@{ minLength = -1 }; path = '$.minLength' }
    [pscustomobject]@{ name = 'minItems is fractional'; schema = [pscustomobject]@{ minItems = 1.5 }; path = '$.minItems' }
    [pscustomobject]@{ name = 'uniqueItems is not boolean'; schema = [pscustomobject]@{ uniqueItems = 'true' }; path = '$.uniqueItems' }
    [pscustomobject]@{ name = 'additionalProperties is not boolean'; schema = [pscustomobject]@{ additionalProperties = 0 }; path = '$.additionalProperties' }
    [pscustomobject]@{ name = 'items is not a schema object'; schema = [pscustomobject]@{ items = 'invalid' }; path = '$.items' }
    [pscustomobject]@{ name = 'not is not a schema object'; schema = [pscustomobject]@{ not = @() }; path = '$.not' }
)

foreach ($malformedSchemaCase in $malformedSchemaCases) {
    Invoke-Assertion "schema rejects $($malformedSchemaCase.name) without throwing" {
        $validation = Test-TemporaryRouterSchema -Schema $malformedSchemaCase.schema -Value ([pscustomobject]@{})

        Assert-ValidationErrorsExactly -Validation $validation -ExpectedErrors @(
            [pscustomobject]@{ code = 'schema_invalid'; path = $malformedSchemaCase.path }
        )
    }
}

Invoke-Assertion 'draft 2020-12 permits an empty required array' {
    $schema = [pscustomobject]@{ '$schema' = $draft202012; required = @() }
    Assert-ValidationSuccess (Test-TemporaryRouterSchema -Schema $schema -Value ([pscustomobject]@{}))
}

Invoke-Assertion 'draft 2020-12 does not require enum values to be structurally unique' {
    $schema = [pscustomobject]@{ '$schema' = $draft202012; enum = @('allowed', 'allowed') }
    Assert-ValidationSuccess (Test-TemporaryRouterSchema -Schema $schema -Value 'allowed')
}

Invoke-Assertion 'direct type string const and string enum forms remain supported' {
    $unionSchema = [pscustomobject]@{ type = @('string', 'null') }
    Assert-ValidationSuccess (Test-TemporaryRouterSchema -Schema $unionSchema -Value 'value')
    Assert-ValidationSuccess (Test-TemporaryRouterSchema -Schema $unionSchema -Value $null)
    Assert-ValidationErrorsExactly -Validation (
        Test-TemporaryRouterSchema -Schema $unionSchema -Value 1
    ) -ExpectedErrors @(
        [pscustomobject]@{ code = 'type_mismatch'; path = '$' }
    )

    Assert-ValidationSuccess (Test-TemporaryRouterSchema -Schema ([pscustomobject]@{ const = 'allowed' }) -Value 'allowed')
    Assert-ValidationSuccess (Test-TemporaryRouterSchema -Schema ([pscustomobject]@{ const = $true }) -Value $true)
    Assert-ValidationSuccess (Test-TemporaryRouterSchema -Schema ([pscustomobject]@{ enum = @('allowed') }) -Value 'allowed')
}

$unsupportedAuditedFormCases = @(
    [pscustomobject]@{ name = 'numeric const'; schema = [pscustomobject]@{ const = 0 }; path = '$.const' }
    [pscustomobject]@{ name = 'composite const'; schema = [pscustomobject]@{ const = [pscustomobject]@{ value = 'blocked' } }; path = '$.const' }
    [pscustomobject]@{ name = 'numeric enum'; schema = [pscustomobject]@{ enum = @(0) }; path = '$.enum[0]' }
    [pscustomobject]@{ name = 'boolean enum'; schema = [pscustomobject]@{ enum = @($true) }; path = '$.enum[0]' }
    [pscustomobject]@{ name = 'composite enum'; schema = [pscustomobject]@{ enum = @([pscustomobject]@{ value = 'blocked' }) }; path = '$.enum[0]' }
    [pscustomobject]@{ name = 'numeric default'; schema = [pscustomobject]@{ default = 1 }; path = '$.default' }
    [pscustomobject]@{ name = 'schema-valued additionalProperties'; schema = [pscustomobject]@{ additionalProperties = [pscustomobject]@{ type = 'string' } }; path = '$.additionalProperties' }
    [pscustomobject]@{ name = 'false uniqueItems'; schema = [pscustomobject]@{ type = 'array'; items = [pscustomobject]@{ type = 'string' }; uniqueItems = $false }; path = '$.uniqueItems' }
    [pscustomobject]@{ name = 'numeric uniqueItems'; schema = [pscustomobject]@{ type = 'array'; items = [pscustomobject]@{ type = 'number' }; uniqueItems = $true }; path = '$.uniqueItems' }
    [pscustomobject]@{ name = 'nested uniqueItems'; schema = [pscustomobject]@{ type = 'array'; items = [pscustomobject]@{ type = 'array' }; uniqueItems = $true }; path = '$.uniqueItems' }
    [pscustomobject]@{ name = 'numeric const inside oneOf'; schema = [pscustomobject]@{ oneOf = @([pscustomobject]@{ const = 0 }, [pscustomobject]@{ type = 'string' }) }; path = '$.oneOf[0].const' }
    [pscustomobject]@{ name = 'numeric enum inside not'; schema = [pscustomobject]@{ not = [pscustomobject]@{ enum = @(0) } }; path = '$.not.enum[0]' }
    [pscustomobject]@{ name = 'unknown keyword inside anyOf'; schema = [pscustomobject]@{ anyOf = @([pscustomobject]@{ maxLength = 1 }) }; path = '$.anyOf[0].maxLength' }
    [pscustomobject]@{ name = 'minimum inside scalar oneOf'; schema = [pscustomobject]@{ oneOf = @([pscustomobject]@{ type = 'number'; minimum = 0 }, [pscustomobject]@{ type = 'string' }) }; path = '$.oneOf[0].minimum'; value = [double]-1e-100 }
    [pscustomobject]@{ name = 'minimum inside anyOf'; schema = [pscustomobject]@{ anyOf = @([pscustomobject]@{ type = 'number'; minimum = 0 }, [pscustomobject]@{ type = 'string' }) }; path = '$.anyOf[0].minimum'; value = [double]-1e-100 }
    [pscustomobject]@{ name = 'minimum inside not'; schema = [pscustomobject]@{ not = [pscustomobject]@{ type = 'number'; minimum = 0 } }; path = '$.not.minimum'; value = [double]-1e-100 }
)

foreach ($unsupportedAuditedFormCase in $unsupportedAuditedFormCases) {
    Invoke-Assertion "schema rejects unaudited $($unsupportedAuditedFormCase.name) form" {
        $candidateValue = if ($null -ne (Get-RouterExactProperty $unsupportedAuditedFormCase 'value')) {
            $unsupportedAuditedFormCase.value
        } else {
            [pscustomobject]@{}
        }
        Assert-ValidationErrorsExactly -Validation (
            Test-TemporaryRouterSchema -Schema $unsupportedAuditedFormCase.schema -Value $candidateValue
        ) -ExpectedErrors @(
            [pscustomobject]@{ code = 'schema_invalid'; path = $unsupportedAuditedFormCase.path }
        )
    }
}

Invoke-Assertion 'direct string and numeric limits return complete errors' {
    Assert-ValidationSuccess (
        Test-TemporaryRouterSchema -Schema ([pscustomobject]@{ type = 'string'; minLength = 1 }) -Value 'a'
    )
    Assert-ValidationErrorsExactly -Validation (
        Test-TemporaryRouterSchema -Schema ([pscustomobject]@{ type = 'string'; minLength = 1 }) -Value ''
    ) -ExpectedErrors @(
        [pscustomobject]@{ code = 'schema_validation_failed'; path = '$' }
    )
    Assert-ValidationErrorsExactly -Validation (
        Test-TemporaryRouterSchema -Schema ([pscustomobject]@{ type = 'number'; minimum = 1 }) -Value ([decimal]0.5)
    ) -ExpectedErrors @(
        [pscustomobject]@{ code = 'number_below_minimum'; path = '$' }
    )

}

Invoke-Assertion 'unaudited minLength and minItems values fail structurally without narrowing' {
    $tenToTheFiftieth = [Numerics.BigInteger]::Pow([Numerics.BigInteger]10, 50)
    foreach ($limitCase in @(
        [pscustomobject]@{ keyword = 'minLength'; value = [int64]2147483648; candidate = '' }
        [pscustomobject]@{ keyword = 'minLength'; value = $tenToTheFiftieth; candidate = '' }
        [pscustomobject]@{ keyword = 'minItems'; value = [int64]2147483648; candidate = @() }
        [pscustomobject]@{ keyword = 'minItems'; value = $tenToTheFiftieth; candidate = @() }
    )) {
        $schema = [pscustomobject]@{ type = if ($limitCase.keyword -ceq 'minLength') { 'string' } else { 'array' } }
        $schema | Add-Member -NotePropertyName $limitCase.keyword -NotePropertyValue $limitCase.value
        Assert-ValidationErrorsExactly -Validation (
            Test-TemporaryRouterSchema -Schema $schema -Value $limitCase.candidate
        ) -ExpectedErrors @(
            [pscustomobject]@{ code = 'schema_invalid'; path = ('$.{0}' -f $limitCase.keyword) }
        )
    }
}

Invoke-Assertion 'direct array keywords enforce limits and item types' {
    $arraySchema = [pscustomobject]@{
        type = 'array'
        minItems = 1
        items = [pscustomobject]@{ type = 'integer' }
    }

    Assert-ValidationErrorsExactly -Validation (
        Test-TemporaryRouterSchema -Schema $arraySchema -Value @()
    ) -ExpectedErrors @(
        [pscustomobject]@{ code = 'schema_validation_failed'; path = '$' }
    )
    Assert-ValidationErrorsExactly -Validation (
        Test-TemporaryRouterSchema -Schema $arraySchema -Value @(1, 'not-an-integer')
    ) -ExpectedErrors @(
        [pscustomobject]@{ code = 'type_mismatch'; path = '$[1]' }
    )

    $stringUniqueSchema = [pscustomobject]@{
        type = 'array'
        items = [pscustomobject]@{ type = 'string' }
        uniqueItems = $true
    }
    Assert-ValidationErrorsExactly -Validation (
        Test-TemporaryRouterSchema -Schema $stringUniqueSchema -Value @('duplicate', 'duplicate')
    ) -ExpectedErrors @(
        [pscustomobject]@{ code = 'schema_validation_failed'; path = '$' }
    )
}

Invoke-Assertion 'direct object not and oneOf keywords return complete errors' {
    $objectSchema = [pscustomobject]@{
        type = 'object'
        required = @('name')
        properties = [pscustomobject]@{ name = [pscustomobject]@{ type = 'string' } }
        additionalProperties = $false
    }
    $objectValue = [pscustomobject]@{ Name = 'wrong case'; extra = 1 }
    Assert-ValidationErrorsExactly -Validation (
        Test-TemporaryRouterSchema -Schema $objectSchema -Value $objectValue
    ) -ExpectedErrors @(
        [pscustomobject]@{ code = 'required_property_missing'; path = '$.name' }
        [pscustomobject]@{ code = 'additional_property_not_allowed'; path = '$.Name' }
        [pscustomobject]@{ code = 'additional_property_not_allowed'; path = '$.extra' }
    )

    Assert-ValidationErrorsExactly -Validation (
        Test-TemporaryRouterSchema -Schema ([pscustomobject]@{ not = [pscustomobject]@{ type = 'string' } }) -Value 'blocked'
    ) -ExpectedErrors @(
        [pscustomobject]@{ code = 'schema_validation_failed'; path = '$' }
    )
    Assert-ValidationErrorsExactly -Validation (
        Test-TemporaryRouterSchema -Schema ([pscustomobject]@{
            oneOf = @(
                [pscustomobject]@{ type = 'number' }
                [pscustomobject]@{ type = 'integer' }
            )
        }) -Value 1
    ) -ExpectedErrors @(
        [pscustomobject]@{ code = 'schema_validation_failed'; path = '$' }
    )
}

Invoke-Assertion 'not custom code is emitted only when its subschema independently matches' {
    $schema = [pscustomobject]@{
        type = 'string'
        minLength = 1
        not = [pscustomobject]@{ const = 'blocked' }
        'x-error-code' = 'unsupported_modality'
    }

    Assert-ValidationErrorsExactly -Validation (
        Test-TemporaryRouterSchema -Schema $schema -Value ''
    ) -ExpectedErrors @(
        [pscustomobject]@{ code = 'schema_validation_failed'; path = '$' }
    )
    Assert-ValidationErrorsExactly -Validation (
        Test-TemporaryRouterSchema -Schema $schema -Value 'blocked'
    ) -ExpectedErrors @(
        [pscustomobject]@{ code = 'unsupported_modality'; path = '$' }
    )
}

Invoke-Assertion 'candidate cycles return exact value_not_json paths' {
    $objectCycle = [pscustomobject]@{}
    Add-Member -InputObject $objectCycle -NotePropertyName 'self' -NotePropertyValue $objectCycle
    $objectSchema = [pscustomobject]@{
        type = 'object'
        properties = [pscustomobject]@{ self = [pscustomobject]@{ type = 'object' } }
        additionalProperties = $false
    }
    Assert-ValidationErrorsExactly -Validation (
        Test-TemporaryRouterSchema -Schema $objectSchema -Value $objectCycle
    ) -ExpectedErrors @(
        [pscustomobject]@{ code = 'value_not_json'; path = '$.self' }
    )

    $arrayCycle = [Collections.ArrayList]::new()
    $null = $arrayCycle.Add($arrayCycle)
    $arraySchema = [pscustomobject]@{ type = 'array'; items = [pscustomobject]@{ type = 'array' } }
    Assert-ValidationErrorsExactly -Validation (
        Test-TemporaryRouterSchema -Schema $arraySchema -Value $arrayCycle
    ) -ExpectedErrors @(
        [pscustomobject]@{ code = 'value_not_json'; path = '$[0]' }
    )
}

Invoke-Assertion 'shared acyclic candidate references remain valid JSON-domain values' {
    $shared = [pscustomobject]@{ name = 'shared' }
    $schema = [pscustomobject]@{
        type = 'object'
        required = @('left', 'right')
        properties = [pscustomobject]@{
            left = [pscustomobject]@{
                type = 'object'
                required = @('name')
                properties = [pscustomobject]@{ name = [pscustomobject]@{ type = 'string' } }
                additionalProperties = $false
            }
            right = [pscustomobject]@{
                type = 'object'
                required = @('name')
                properties = [pscustomobject]@{ name = [pscustomobject]@{ type = 'string' } }
                additionalProperties = $false
            }
        }
        additionalProperties = $false
    }
    $candidate = [pscustomobject]@{ left = $shared; right = $shared }
    Assert-ValidationSuccess (Test-TemporaryRouterSchema -Schema $schema -Value $candidate)
}

Invoke-Assertion 'Equals-always-true CLR candidate is rejected without invoking Equals' {
    if ($null -eq ('RouterSchemaAlwaysEqualProbe' -as [type])) {
        Add-Type -TypeDefinition @'
using System;

public sealed class RouterSchemaAlwaysEqualProbe
{
    public static int EqualsCalls { get; private set; }

    public override bool Equals(object value)
    {
        EqualsCalls++;
        return true;
    }

    public override int GetHashCode() => 0;
}

public sealed class RouterSchemaThrowingEqualsProbe
{
    public static int EqualsCalls { get; private set; }

    public override bool Equals(object value)
    {
        EqualsCalls++;
        throw new InvalidOperationException("test equality failure");
    }

    public override int GetHashCode() => 0;
}
'@
    }

    $validation = Test-TemporaryRouterSchema -Schema ([pscustomobject]@{ enum = @('allowed') }) -Value (
        [RouterSchemaAlwaysEqualProbe]::new()
    )
    Assert-ValidationErrorsExactly -Validation $validation -ExpectedErrors @(
        [pscustomobject]@{ code = 'value_not_json'; path = '$' }
    )
    Assert-Equal ([RouterSchemaAlwaysEqualProbe].GetProperty('EqualsCalls').GetValue($null)) 0
}

Invoke-Assertion 'Equals-throwing CLR candidate is rejected without invoking Equals' {
    if ($null -eq ('RouterSchemaThrowingEqualsProbe' -as [type])) {
        throw 'Equals probe types were not initialized by the preceding assertion.'
    }

    $validation = Test-TemporaryRouterSchema -Schema ([pscustomobject]@{ const = 'allowed' }) -Value (
        [RouterSchemaThrowingEqualsProbe]::new()
    )
    Assert-ValidationErrorsExactly -Validation $validation -ExpectedErrors @(
        [pscustomobject]@{ code = 'value_not_json'; path = '$' }
    )
    Assert-Equal ([RouterSchemaThrowingEqualsProbe].GetProperty('EqualsCalls').GetValue($null)) 0
}

& $task4Assertions

$qualityCapabilities = @('instruction_following', 'reasoning', 'factual_reliability')

Invoke-Assertion 'Task 5 quality evaluator returns a stable auditable output shape' {
    $request = New-MinimalRequest
    $candidate = Copy-TestObject @(Get-MinimalProfiles)[0]
    Set-TestRelevantQuality -Candidate $candidate -Request $request `
        -RequiredCapabilities $qualityCapabilities -Category 'strong'

    $evaluation = Test-RouterCandidateQuality -Candidate $candidate -Request $request `
        -RequiredCapabilities $qualityCapabilities

    Assert-SequenceEqual @($evaluation.PSObject.Properties.Name) @(
        'candidate_identity'
        'passed'
        'reason_code'
        'effective_quality'
        'quality_bottleneck'
        'relevant_categories'
    )
    Assert-Equal $evaluation.candidate_identity 'agy|shared-model__medium'
    Assert-Equal $evaluation.passed $true
    Assert-Equal $evaluation.reason_code $null
    Assert-Equal $evaluation.effective_quality 'strong'
    Assert-Equal $evaluation.quality_bottleneck 'task_type.coding'
    Assert-SequenceEqual @($evaluation.relevant_categories | ForEach-Object { $_.key }) @(
        'task_type.coding'
        'domain.computer_science'
        'complexity.medium'
        'instruction_following'
        'reasoning'
        'factual_reliability'
    )
    Assert-SequenceEqual @($evaluation.relevant_categories | ForEach-Object { $_.category }) @(
        'strong'
        'strong'
        'strong'
        'strong'
        'strong'
        'strong'
    )
    foreach ($entry in @($evaluation.relevant_categories)) {
        Assert-SequenceEqual @($entry.PSObject.Properties.Name) @('key', 'category')
    }
}

$qualityFloorCases = @(
    [pscustomobject]@{ floor = 'standard'; category = 'standard'; passed = $true }
    [pscustomobject]@{ floor = 'standard'; category = 'strong'; passed = $true }
    [pscustomobject]@{ floor = 'standard'; category = 'frontier'; passed = $true }
    [pscustomobject]@{ floor = 'strong'; category = 'standard'; passed = $false }
    [pscustomobject]@{ floor = 'strong'; category = 'strong'; passed = $true }
    [pscustomobject]@{ floor = 'strong'; category = 'frontier'; passed = $true }
    [pscustomobject]@{ floor = 'frontier'; category = 'standard'; passed = $false }
    [pscustomobject]@{ floor = 'frontier'; category = 'strong'; passed = $false }
    [pscustomobject]@{ floor = 'frontier'; category = 'frontier'; passed = $true }
)
foreach ($qualityFloorCase in $qualityFloorCases) {
    Invoke-Assertion ("quality floor {0} evaluates category {1} by standard less than strong less than frontier" -f `
        $qualityFloorCase.floor, $qualityFloorCase.category) {
        $request = New-MinimalRequest
        $request.quality_floor = $qualityFloorCase.floor
        $candidate = Copy-TestObject @(Get-MinimalProfiles)[0]
        Set-TestRelevantQuality -Candidate $candidate -Request $request `
            -RequiredCapabilities $qualityCapabilities -Category $qualityFloorCase.category

        $evaluation = Test-RouterCandidateQuality -Candidate $candidate -Request $request `
            -RequiredCapabilities $qualityCapabilities

        Assert-Equal $evaluation.passed $qualityFloorCase.passed
        Assert-Equal $evaluation.effective_quality $qualityFloorCase.category
        Assert-Equal $evaluation.quality_bottleneck 'task_type.coding'
        $expectedReason = if ($qualityFloorCase.passed) { $null } else { 'quality_floor_not_met' }
        Assert-Equal $evaluation.reason_code $expectedReason
    }
}

$qualityBottleneckCases = @(
    [pscustomobject]@{
        name = 'task type'
        key = 'task_type.coding'
        mutate = { param($candidate, $request) $candidate.quality.task_types.($request.task_type) = 'standard' }
    }
    [pscustomobject]@{
        name = 'domain'
        key = 'domain.computer_science'
        mutate = { param($candidate, $request) $candidate.quality.domains.($request.domain) = 'standard' }
    }
    [pscustomobject]@{
        name = 'complexity'
        key = 'complexity.medium'
        mutate = { param($candidate, $request) $candidate.quality.complexities.($request.complexity) = 'standard' }
    }
    [pscustomobject]@{
        name = 'capability'
        key = 'reasoning'
        mutate = { param($candidate, $request) $candidate.quality.capabilities.reasoning = 'standard' }
    }
)
foreach ($qualityBottleneckCase in $qualityBottleneckCases) {
    Invoke-Assertion ("quality reports the exact {0} bottleneck key" -f $qualityBottleneckCase.name) {
        $request = New-MinimalRequest
        $request.quality_floor = 'standard'
        $candidate = Copy-TestObject @(Get-MinimalProfiles)[0]
        Set-TestRelevantQuality -Candidate $candidate -Request $request `
            -RequiredCapabilities $qualityCapabilities -Category 'frontier'
        & $qualityBottleneckCase.mutate $candidate $request

        $evaluation = Test-RouterCandidateQuality -Candidate $candidate -Request $request `
            -RequiredCapabilities $qualityCapabilities

        Assert-Equal $evaluation.passed $true
        Assert-Equal $evaluation.effective_quality 'standard'
        Assert-Equal $evaluation.quality_bottleneck $qualityBottleneckCase.key
    }
}

Invoke-Assertion 'quality tie order ignores profile property order and follows task domain complexity' {
    $request = New-MinimalRequest
    $request.quality_floor = 'standard'
    $candidate = Copy-TestObject @(Get-MinimalProfiles)[0]
    Set-TestRelevantQuality -Candidate $candidate -Request $request `
        -RequiredCapabilities $qualityCapabilities -Category 'standard'
    $candidate.quality.task_types = Reverse-TestPropertyOrder $candidate.quality.task_types
    $candidate.quality.domains = Reverse-TestPropertyOrder $candidate.quality.domains
    $candidate.quality.complexities = Reverse-TestPropertyOrder $candidate.quality.complexities
    $candidate.quality.capabilities = Reverse-TestPropertyOrder $candidate.quality.capabilities

    $evaluation = Test-RouterCandidateQuality -Candidate $candidate -Request $request `
        -RequiredCapabilities $qualityCapabilities

    Assert-Equal $evaluation.quality_bottleneck 'task_type.coding'
}

Invoke-Assertion 'quality capability ties follow canonical incoming capability order' {
    $request = New-MinimalRequest
    $request.quality_floor = 'standard'
    $incomingCapabilities = @('reasoning', 'instruction_following')
    $candidate = Copy-TestObject @(Get-MinimalProfiles)[0]
    Set-TestRelevantQuality -Candidate $candidate -Request $request `
        -RequiredCapabilities $incomingCapabilities -Category 'standard'
    $candidate.quality.task_types.coding = 'frontier'
    $candidate.quality.domains.computer_science = 'frontier'
    $candidate.quality.complexities.medium = 'frontier'
    $candidate.quality.capabilities = Reverse-TestPropertyOrder $candidate.quality.capabilities

    $evaluation = Test-RouterCandidateQuality -Candidate $candidate -Request $request `
        -RequiredCapabilities $incomingCapabilities

    Assert-SequenceEqual @($evaluation.relevant_categories | ForEach-Object { $_.key }) @(
        'task_type.coding'
        'domain.computer_science'
        'complexity.medium'
        'reasoning'
        'instruction_following'
    )
    Assert-Equal $evaluation.quality_bottleneck 'reasoning'
}

$qualityEvidenceDimensionCases = @(
    [pscustomobject]@{
        name = 'task type'
        key = 'task_type.coding'
        mutate = { param($candidate, $category) $candidate.quality.task_types.coding = $category }
    }
    [pscustomobject]@{
        name = 'domain'
        key = 'domain.computer_science'
        mutate = { param($candidate, $category) $candidate.quality.domains.computer_science = $category }
    }
    [pscustomobject]@{
        name = 'complexity'
        key = 'complexity.medium'
        mutate = { param($candidate, $category) $candidate.quality.complexities.medium = $category }
    }
    [pscustomobject]@{
        name = 'capability'
        key = 'reasoning'
        mutate = { param($candidate, $category) $candidate.quality.capabilities.reasoning = $category }
    }
)
$qualityFailureStates = @(
    [pscustomobject]@{ category = 'unknown'; reason = 'quality_evidence_unknown' }
    [pscustomobject]@{ category = 'unsupported'; reason = 'required_capability_unavailable' }
)
foreach ($qualityFailureState in $qualityFailureStates) {
    foreach ($qualityEvidenceDimensionCase in $qualityEvidenceDimensionCases) {
        Invoke-Assertion ("quality rejects {0} relevant evidence in the {1} family" -f `
            $qualityFailureState.category, $qualityEvidenceDimensionCase.name) {
            $request = New-MinimalRequest
            $request.quality_floor = 'standard'
            $candidate = Copy-TestObject @(Get-MinimalProfiles)[0]
            Set-TestRelevantQuality -Candidate $candidate -Request $request `
                -RequiredCapabilities $qualityCapabilities -Category 'strong'
            & $qualityEvidenceDimensionCase.mutate $candidate $qualityFailureState.category

            $evaluation = Test-RouterCandidateQuality -Candidate $candidate -Request $request `
                -RequiredCapabilities $qualityCapabilities

            Assert-Equal $evaluation.passed $false
            Assert-Equal $evaluation.reason_code $qualityFailureState.reason
            Assert-Equal $evaluation.effective_quality $null
            Assert-Equal $evaluation.quality_bottleneck $qualityEvidenceDimensionCase.key
        }
    }
}

Invoke-Assertion 'quality failure precedence is unsupported then unknown then below floor' {
    $request = New-MinimalRequest
    $request.quality_floor = 'frontier'
    $candidate = Copy-TestObject @(Get-MinimalProfiles)[0]
    Set-TestRelevantQuality -Candidate $candidate -Request $request `
        -RequiredCapabilities $qualityCapabilities -Category 'strong'
    $candidate.quality.task_types.coding = 'standard'
    $candidate.quality.domains.computer_science = 'unknown'
    $candidate.quality.capabilities.reasoning = 'unsupported'

    $unsupported = Test-RouterCandidateQuality -Candidate $candidate -Request $request `
        -RequiredCapabilities $qualityCapabilities
    Assert-Equal $unsupported.reason_code 'required_capability_unavailable'
    Assert-Equal $unsupported.quality_bottleneck 'reasoning'
    Assert-Equal $unsupported.effective_quality $null

    $candidate.quality.capabilities.reasoning = 'strong'
    $unknown = Test-RouterCandidateQuality -Candidate $candidate -Request $request `
        -RequiredCapabilities $qualityCapabilities
    Assert-Equal $unknown.reason_code 'quality_evidence_unknown'
    Assert-Equal $unknown.quality_bottleneck 'domain.computer_science'
    Assert-Equal $unknown.effective_quality $null

    $candidate.quality.domains.computer_science = 'strong'
    $belowFloor = Test-RouterCandidateQuality -Candidate $candidate -Request $request `
        -RequiredCapabilities $qualityCapabilities
    Assert-Equal $belowFloor.reason_code 'quality_floor_not_met'
    Assert-Equal $belowFloor.effective_quality 'standard'
    Assert-Equal $belowFloor.quality_bottleneck 'task_type.coding'
}

Invoke-Assertion 'quality ignores lower unknown and unsupported values in every irrelevant profile map' {
    $request = New-MinimalRequest
    $request.quality_floor = 'frontier'
    $candidate = Copy-TestObject @(Get-MinimalProfiles)[0]
    Set-TestRelevantQuality -Candidate $candidate -Request $request `
        -RequiredCapabilities $qualityCapabilities -Category 'frontier'
    $candidate.quality.task_types.general = 'standard'
    $candidate.quality.domains.finance = 'unknown'
    $candidate.quality.complexities.low = 'unsupported'
    $candidate.quality.capabilities.structured_output = 'standard'
    $candidate.quality.capabilities.source_grounded_synthesis = 'unknown'
    $candidate.quality.capabilities.long_context = 'unsupported'

    $evaluation = Test-RouterCandidateQuality -Candidate $candidate -Request $request `
        -RequiredCapabilities $qualityCapabilities

    Assert-Equal $evaluation.passed $true
    Assert-Equal $evaluation.reason_code $null
    Assert-Equal $evaluation.effective_quality 'frontier'
    Assert-Equal $evaluation.quality_bottleneck 'task_type.coding'
    Assert-SequenceEqual @($evaluation.relevant_categories | ForEach-Object { $_.key }) @(
        'task_type.coding'
        'domain.computer_science'
        'complexity.medium'
        'instruction_following'
        'reasoning'
        'factual_reliability'
    )
}

Invoke-Assertion 'quality evaluates one complete profile without price latency provider or availability factors' {
    $request = New-MinimalRequest
    $request.quality_floor = 'strong'
    $candidate = Copy-TestObject @(Get-MinimalProfiles)[0]
    Set-TestRelevantQuality -Candidate $candidate -Request $request `
        -RequiredCapabilities $qualityCapabilities -Category 'strong'
    $candidate.enabled = $false
    $candidate.availability = 'unavailable'
    $candidate.provider = 'irrelevant-provider'
    $candidate.model = 'irrelevant-model'
    $candidate.effort = 'irrelevant-effort'
    $candidate.pricing.cost_comparable = $false
    $candidate.pricing.input_usd_per_million_tokens = $null
    $candidate.pricing.output_usd_per_million_tokens = $null
    $candidate.latency_observation.available = $false
    $candidate.latency_observation.milliseconds = $null

    $evaluation = Test-RouterCandidateQuality -Candidate $candidate -Request $request `
        -RequiredCapabilities $qualityCapabilities

    Assert-Equal $evaluation.candidate_identity 'agy|shared-model__medium'
    Assert-Equal $evaluation.passed $true
    Assert-Equal $evaluation.effective_quality 'strong'
}

Invoke-Assertion 'Task 6 token fixture uses exact profile model effort and request-profile-group identities' {
    $fixture = Get-TestTokenEstimates

    Assert-Equal $fixture.version 'router-token-estimates/v1'
    Assert-Equal @($fixture.observations).Count 2
    Assert-SequenceEqual @($fixture.observations | ForEach-Object { $_.request_profile_group }) @(
        'coding|computer_science|medium|normal'
        'coding|computer_science|medium|normal'
    )
    Assert-SequenceEqual @($fixture.observations | ForEach-Object {
        '{0}|{1}|{2}|{3}' -f $_.launcher, $_.configuration_id, $_.model, $_.effort
    }) @(
        'agy|shared-model__medium|shared-model|medium'
        'codex|shared-model__medium|shared-model|medium'
    )
}

Invoke-Assertion 'token estimate document validator enforces the exact versioned document and record contract' {
    $fixture = Get-TestTokenEstimates
    Assert-Equal (Test-RouterTokenEstimatesDocument -TokenEstimates $fixture).valid $true

    $invalidDocuments = [Collections.Generic.List[object]]::new()
    $bareObservations = @($fixture.observations)
    $invalidDocuments.Add($bareObservations)
    $wrongVersion = Copy-TestObject $fixture
    $wrongVersion.version = 'router-token-estimates/v0'
    $invalidDocuments.Add($wrongVersion)
    $missingVersion = Copy-TestObject $fixture
    $missingVersion.PSObject.Properties.Remove('version')
    $invalidDocuments.Add($missingVersion)
    $unknownTopLevel = Copy-TestObject $fixture
    $unknownTopLevel | Add-Member -NotePropertyName typo -NotePropertyValue $true
    $invalidDocuments.Add($unknownTopLevel)
    $scalarObservations = Copy-TestObject $fixture
    $scalarObservations.observations = $scalarObservations.observations[0]
    $invalidDocuments.Add($scalarObservations)
    foreach ($recordProperty in @(
        'launcher', 'configuration_id', 'model', 'effort', 'request_profile_group',
        'estimated_input_tokens', 'estimated_visible_output_tokens',
        'estimated_reasoning_tokens', 'observed_on'
    )) {
        $missingRecordProperty = Copy-TestObject $fixture
        $missingRecordProperty.observations[0].PSObject.Properties.Remove($recordProperty)
        $invalidDocuments.Add($missingRecordProperty)
    }
    $unknownRecordProperty = Copy-TestObject $fixture
    $unknownRecordProperty.observations[0] | Add-Member -NotePropertyName typo -NotePropertyValue $true
    $invalidDocuments.Add($unknownRecordProperty)
    foreach ($identityProperty in @('launcher', 'configuration_id', 'model', 'effort', 'request_profile_group')) {
        $blankIdentity = Copy-TestObject $fixture
        $blankIdentity.observations[0].$identityProperty = ''
        $invalidDocuments.Add($blankIdentity)
    }
    foreach ($tokenProperty in @('estimated_input_tokens', 'estimated_visible_output_tokens', 'estimated_reasoning_tokens')) {
        foreach ($invalidTokenValue in @(-1, 1.5, [double]1e-100)) {
            $invalidTokenDocument = Copy-TestObject $fixture
            $invalidTokenDocument.observations[0].$tokenProperty = $invalidTokenValue
            $invalidDocuments.Add($invalidTokenDocument)
        }
    }
    $invalidDate = Copy-TestObject $fixture
    $invalidDate.observations[0].observed_on = '2026-8-22'
    $invalidDocuments.Add($invalidDate)
    $duplicate = Copy-TestObject $fixture
    $duplicate.observations = @($duplicate.observations + (Copy-TestObject $duplicate.observations[0]))
    $invalidDocuments.Add($duplicate)

    foreach ($invalidDocument in $invalidDocuments) {
        Assert-Equal (Test-RouterTokenEstimatesDocument -TokenEstimates $invalidDocument).valid $false
    }
}

Invoke-Assertion 'price consumes the complete versioned token estimate document' {
    $candidate = Copy-TestObject @(Get-MinimalProfiles)[0]
    $estimate = Get-RouterEstimatedPrice -Candidate $candidate -Request (New-MinimalRequest) `
        -Requirements (New-TestPriceRequirements) -PricingSnapshot (New-TestPricingSnapshot) `
        -TokenEstimates (Get-TestTokenEstimates) -AsOfDate '2026-08-22'

    Assert-Equal $estimate.available $true
}

Invoke-Assertion 'price rejects a legacy bare token observation array' {
    $candidate = Copy-TestObject @(Get-MinimalProfiles)[0]
    $estimate = Get-RouterEstimatedPrice -Candidate $candidate -Request (New-MinimalRequest) `
        -Requirements (New-TestPriceRequirements) -PricingSnapshot (New-TestPricingSnapshot) `
        -TokenEstimates @((New-TestTokenObservation -Candidate $candidate)) -AsOfDate '2026-08-22'

    Assert-Equal $estimate.available $false
    Assert-Equal $estimate.reason_code 'token_estimate_invalid'
}

Invoke-Assertion 'malformed unmatched token records invalidate the complete document before matching' {
    $candidate = Copy-TestObject @(Get-MinimalProfiles)[0]
    $document = Get-TestTokenEstimates
    $document.observations[1].observed_on = 'invalid-date'
    $estimate = Get-RouterEstimatedPrice -Candidate $candidate -Request (New-MinimalRequest) `
        -Requirements (New-TestPriceRequirements) -PricingSnapshot (New-TestPricingSnapshot) `
        -TokenEstimates $document -AsOfDate '2026-08-22'

    Assert-Equal $estimate.available $false
    Assert-Equal $estimate.reason_code 'token_estimate_invalid'
}

Invoke-Assertion 'Task 6 pricing module is available' {
    Assert-Equal $pricingAvailable $true
}

Invoke-Assertion 'price uses current request input and separate visible plus reasoning output estimates' {
    $candidate = Copy-TestObject @(Get-MinimalProfiles)[0]
    $request = New-MinimalRequest
    $fixture = Get-TestTokenEstimates
    $snapshot = New-TestPricingSnapshot
    $estimate = Get-RouterEstimatedPrice -Candidate $candidate -Request $request `
        -Requirements (New-TestPriceRequirements -EstimatedInputTokens 2000) `
        -PricingSnapshot $snapshot -TokenEstimates $fixture -AsOfDate '2026-08-22'

    Assert-Equal $estimate.available $true
    Assert-Equal $estimate.request_profile_group 'coding|computer_science|medium|normal'
    Assert-Equal $estimate.estimated_input_tokens 2000
    Assert-Equal $estimate.estimated_visible_output_tokens 500
    Assert-Equal $estimate.estimated_reasoning_tokens 250
    Assert-Equal $estimate.estimated_billable_output_tokens 750
    Assert-Equal $estimate.input_usd_per_million_tokens ([decimal]1)
    Assert-Equal $estimate.output_usd_per_million_tokens ([decimal]5)
    Assert-Equal $estimate.price ([decimal]0.00575)
    Assert-Equal $estimate.price_final $false
}

$promotionBoundaryCases = @(
    [pscustomobject]@{ date = '2026-08-21'; available = $false; input_rate = $null; output_rate = $null }
    [pscustomobject]@{ date = '2026-08-22'; available = $true; input_rate = [decimal]2; output_rate = [decimal]10 }
    [pscustomobject]@{ date = '2026-08-31'; available = $true; input_rate = [decimal]2; output_rate = [decimal]10 }
    [pscustomobject]@{ date = '2026-09-01'; available = $true; input_rate = [decimal]3; output_rate = [decimal]15 }
)
foreach ($promotionBoundaryCase in $promotionBoundaryCases) {
    Invoke-Assertion ("dated promotional pricing treats {0} as an inclusive schedule boundary" -f $promotionBoundaryCase.date) {
        $candidate = Get-Content -LiteralPath (Join-Path $profilesRoot 'claude/claude-sonnet-5__medium.json') `
            -Raw | ConvertFrom-Json -Depth 30
        $observation = New-TestTokenObservation -Candidate $candidate
        $snapshot = Get-Content -LiteralPath $pricingSnapshotPath -Raw | ConvertFrom-Json -Depth 30
        $estimate = Get-RouterEstimatedPrice -Candidate $candidate -Request (New-MinimalRequest) `
            -Requirements (New-TestPriceRequirements) -PricingSnapshot $snapshot `
            -TokenEstimates (New-TestTokenEstimatesDocument -Observations @($observation)) -AsOfDate $promotionBoundaryCase.date

        Assert-Equal $estimate.available $promotionBoundaryCase.available
        Assert-Equal $estimate.input_usd_per_million_tokens $promotionBoundaryCase.input_rate
        Assert-Equal $estimate.output_usd_per_million_tokens $promotionBoundaryCase.output_rate
    }
}

$geminiTierCases = @(
    [pscustomobject]@{ input_tokens = 200000; input_rate = [decimal]2; output_rate = [decimal]12 }
    [pscustomobject]@{ input_tokens = 200001; input_rate = [decimal]4; output_rate = [decimal]18 }
)
foreach ($geminiTierCase in $geminiTierCases) {
    Invoke-Assertion ("Gemini 3.1 pricing applies the exact $($geminiTierCase.input_tokens)-token tier") {
        $candidate = Get-Content -LiteralPath (Join-Path $profilesRoot 'agy/gemini-3.1-pro-high__high.json') `
            -Raw | ConvertFrom-Json -Depth 30
        $observation = New-TestTokenObservation -Candidate $candidate
        $snapshot = Get-Content -LiteralPath $pricingSnapshotPath -Raw | ConvertFrom-Json -Depth 30
        $estimate = Get-RouterEstimatedPrice -Candidate $candidate -Request (New-MinimalRequest) `
            -Requirements (New-TestPriceRequirements -EstimatedInputTokens $geminiTierCase.input_tokens) `
            -PricingSnapshot $snapshot -TokenEstimates (New-TestTokenEstimatesDocument -Observations @($observation)) -AsOfDate '2026-08-22'

        Assert-Equal $estimate.available $true
        Assert-Equal $estimate.input_usd_per_million_tokens $geminiTierCase.input_rate
        Assert-Equal $estimate.output_usd_per_million_tokens $geminiTierCase.output_rate
    }
}

Invoke-Assertion 'omitting the pricing snapshot fails closed for a Gemini request above 200K input tokens' {
    $candidate = Get-Content -LiteralPath (Join-Path $profilesRoot 'agy/gemini-3.1-pro-high__high.json') `
        -Raw | ConvertFrom-Json -Depth 30
    $observation = New-TestTokenObservation -Candidate $candidate
    $estimate = Get-RouterEstimatedPrice -Candidate $candidate -Request (New-MinimalRequest) `
        -Requirements (New-TestPriceRequirements -EstimatedInputTokens 200001) `
        -TokenEstimates (New-TestTokenEstimatesDocument -Observations @($observation)) -AsOfDate '2026-08-22'

    Assert-Equal $estimate.available $false
    Assert-Equal $estimate.reason_code 'pricing_snapshot_unavailable'
    Assert-Equal $estimate.price $null
}

Invoke-Assertion 'omitting the pricing snapshot cannot accept a provider and profile pricing mismatch' {
    $candidate = Copy-TestObject @(Get-MinimalProfiles)[0]
    $candidate.provider = 'openai'
    $observation = New-TestTokenObservation -Candidate $candidate
    $estimate = Get-RouterEstimatedPrice -Candidate $candidate -Request (New-MinimalRequest) `
        -Requirements (New-TestPriceRequirements) -TokenEstimates (New-TestTokenEstimatesDocument -Observations @($observation)) `
        -AsOfDate '2026-08-22'

    Assert-Equal $estimate.available $false
    Assert-Equal $estimate.reason_code 'pricing_snapshot_unavailable'
    Assert-Equal $estimate.price $null
}

Invoke-Assertion 'a resulting zero price is unavailable because V1 has no free routes' {
    $candidate = Copy-TestObject @(Get-MinimalProfiles)[0]
    $snapshot = New-TestPricingSnapshot
    $snapshot.schedules[0].rate_periods[0].input_usd_per_million_tokens = 0
    $snapshot.schedules[0].rate_periods[0].output_usd_per_million_tokens = 0
    $candidate.pricing.input_usd_per_million_tokens = 0
    $candidate.pricing.output_usd_per_million_tokens = 0
    $estimate = Get-RouterEstimatedPrice -Candidate $candidate -Request (New-MinimalRequest) `
        -Requirements (New-TestPriceRequirements) -PricingSnapshot $snapshot `
        -TokenEstimates (Get-TestTokenEstimates) -AsOfDate '2026-08-22'

    Assert-Equal $estimate.available $false
    Assert-Equal $estimate.reason_code 'free_route_disallowed'
    Assert-Equal $estimate.price $null
    Assert-Equal $estimate.price_final $false
}

$underflowTokenCases = @(
    [pscustomobject]@{ name = 'input'; property = 'estimated_input_tokens'; source = 'requirements' }
    [pscustomobject]@{ name = 'visible output'; property = 'estimated_visible_output_tokens'; source = 'observation' }
    [pscustomobject]@{ name = 'reasoning'; property = 'estimated_reasoning_tokens'; source = 'observation' }
)
foreach ($underflowTokenCase in $underflowTokenCases) {
    foreach ($underflowTokenValue in @([double]-1e-100, [double]1e-100)) {
        $underflowTokenSign = if ($underflowTokenValue -lt 0) { 'negative' } else { 'positive' }
        Invoke-Assertion ("price rejects {0} nonzero floating-point underflow in {1} tokens" -f $underflowTokenSign, $underflowTokenCase.name) {
            $candidate = Copy-TestObject @(Get-MinimalProfiles)[0]
            $requirements = New-TestPriceRequirements
            $observation = New-TestTokenObservation -Candidate $candidate
            if ($underflowTokenCase.source -ceq 'requirements') {
                $requirements.estimated_input_tokens = $underflowTokenValue
            } else {
                $observation.($underflowTokenCase.property) = $underflowTokenValue
            }
            $estimate = Get-RouterEstimatedPrice -Candidate $candidate -Request (New-MinimalRequest) `
                -Requirements $requirements -PricingSnapshot (New-TestPricingSnapshot) `
                -TokenEstimates (New-TestTokenEstimatesDocument -Observations @($observation)) -AsOfDate '2026-08-22'

            Assert-Equal $estimate.available $false
            Assert-Equal $estimate.reason_code 'token_estimate_invalid'
            Assert-Equal $estimate.price $null
        }
    }
}

Invoke-Assertion 'an explicitly injected null pricing snapshot is unavailable instead of using profile rates' {
    $candidate = Copy-TestObject @(Get-MinimalProfiles)[0]
    $estimate = Get-RouterEstimatedPrice -Candidate $candidate -Request (New-MinimalRequest) `
        -Requirements (New-TestPriceRequirements) -PricingSnapshot $null `
        -TokenEstimates (Get-TestTokenEstimates) -AsOfDate '2026-08-22'

    Assert-Equal $estimate.available $false
    Assert-Equal $estimate.reason_code 'pricing_snapshot_unavailable'
    Assert-Equal $estimate.price $null
    Assert-Equal $estimate.price_final $false
}

$unavailablePriceCases = @(
    [pscustomobject]@{
        name = 'non-comparable schedule'
        mutate = { param($candidate, $snapshot, $observations) $snapshot.schedules[0].cost_comparable = $false }
    }
    [pscustomobject]@{
        name = 'missing exact provider mapping'
        mutate = { param($candidate, $snapshot, $observations) $candidate.provider = 'openai' }
    }
    [pscustomobject]@{
        name = 'mismatched pricing snapshot version'
        mutate = { param($candidate, $snapshot, $observations) $candidate.pricing_snapshot_date = '2026-08-21' }
    }
    [pscustomobject]@{
        name = 'coerced numeric injected identity'
        mutate = {
            param($candidate, $snapshot, $observations)
            $candidate.launcher = '1'
            $observations[0].launcher = 1
        }
    }
    [pscustomobject]@{
        name = 'missing exact observation'
        mutate = { param($candidate, $snapshot, $observations) $observations.Clear() }
    }
    [pscustomobject]@{
        name = 'duplicate exact observations'
        mutate = { param($candidate, $snapshot, $observations) $observations.Add((Copy-TestObject $observations[0])) }
    }
)
foreach ($unavailablePriceCase in $unavailablePriceCases) {
    Invoke-Assertion ("price is unavailable for {0} rather than treated as zero" -f $unavailablePriceCase.name) {
        $candidate = Copy-TestObject @(Get-MinimalProfiles)[0]
        $snapshot = New-TestPricingSnapshot
        $observations = [Collections.Generic.List[object]]::new()
        foreach ($observation in @((Get-TestTokenEstimates).observations | Where-Object { $_.launcher -ceq 'agy' })) {
            $observations.Add((Copy-TestObject $observation))
        }
        & $unavailablePriceCase.mutate $candidate $snapshot $observations
        $estimate = Get-RouterEstimatedPrice -Candidate $candidate -Request (New-MinimalRequest) `
            -Requirements (New-TestPriceRequirements) -PricingSnapshot $snapshot `
            -TokenEstimates (New-TestTokenEstimatesDocument -Observations @($observations)) -AsOfDate '2026-08-22'

        Assert-Equal $estimate.available $false
        Assert-Equal $estimate.price $null
        Assert-Equal $estimate.price_final $false
    }
}

Invoke-Assertion 'pricing retains full decimal precision for large integer token counts' {
    $candidate = Copy-TestObject @(Get-MinimalProfiles)[0]
    $snapshot = New-TestPricingSnapshot
    $snapshot.schedules[0].rate_periods[0].input_usd_per_million_tokens = [decimal]0.123456789
    $snapshot.schedules[0].rate_periods[0].output_usd_per_million_tokens = [decimal]9.876543211
    $candidate.pricing.input_usd_per_million_tokens = [decimal]0.123456789
    $candidate.pricing.output_usd_per_million_tokens = [decimal]9.876543211
    $observation = New-TestTokenObservation -Candidate $candidate `
        -EstimatedVisibleOutputTokens 4000000000 -EstimatedReasoningTokens 3000000000
    $requirements = New-TestPriceRequirements -EstimatedInputTokens 8000000000
    $estimate = Get-RouterEstimatedPrice -Candidate $candidate -Request (New-MinimalRequest) `
        -Requirements $requirements -PricingSnapshot $snapshot `
        -TokenEstimates (New-TestTokenEstimatesDocument -Observations @($observation)) -AsOfDate '2026-08-22'
    [decimal]$expected = (
        ([decimal]8000000000 * [decimal]0.123456789) +
        ([decimal]7000000000 * [decimal]9.876543211)
    ) / [decimal]1000000

    Assert-Equal $estimate.available $true
    Assert-Equal $estimate.price $expected
    Assert-Equal ($estimate.price -is [decimal]) $true
}

Invoke-Assertion 'response-boundary rounding is explicit and does not replace raw price precision' {
    [decimal]$raw = 0.0000499999
    $rounded = ConvertTo-RouterResponsePrice -Price $raw -DecimalPlaces 4

    Assert-Equal $rounded ([decimal]0.0000)
    Assert-Equal $raw ([decimal]0.0000499999)
}

Invoke-Assertion 'Task 6 policy module is available' {
    Assert-Equal $policyAvailable $true
}

Invoke-Assertion 'request validation rejects every candidate before requirements' {
    $request = New-MinimalRequest
    $request.PSObject.Properties.Remove('request_text')
    $decision = Invoke-TestRouterPolicy -Request $request -Profiles @(Get-MinimalPolicyProfiles)

    Assert-Equal $decision.request_validation.valid $false
    Assert-Equal $decision.selected_candidate $null
    Assert-Equal @($decision.candidate_evaluations).Count 2
    foreach ($evaluation in @($decision.candidate_evaluations)) {
        Assert-Equal $evaluation.rejection_stage 'request_validation'
        Assert-Equal $evaluation.requirements $null
        Assert-Equal $evaluation.quality $null
        Assert-Equal $evaluation.price $null
    }
}

Invoke-Assertion 'requirements rejection skips quality and price evaluation' {
    $candidate = Copy-TestObject @(Get-MinimalPolicyProfiles)[0]
    $candidate.enabled = $false
    $candidate.quality.task_types.coding = 'unknown'
    $decision = Invoke-TestRouterPolicy -Profiles @($candidate) `
        -TokenEstimates (New-TestTokenEstimatesDocument -Observations @())
    $evaluation = @($decision.candidate_evaluations)[0]

    Assert-Equal $decision.selected_candidate $null
    Assert-Equal $evaluation.requirements.passed $false
    Assert-SequenceEqual @($evaluation.requirements.reason_codes) @('candidate_disabled')
    Assert-Equal $evaluation.quality $null
    Assert-Equal $evaluation.price $null
    Assert-Equal $evaluation.rejection_stage 'requirements'
}

Invoke-Assertion 'quality rejection skips price evaluation' {
    $candidate = Copy-TestObject @(Get-MinimalPolicyProfiles)[0]
    $candidate.quality.task_types.coding = 'unknown'
    $decision = Invoke-TestRouterPolicy -Profiles @($candidate) `
        -TokenEstimates (New-TestTokenEstimatesDocument -Observations @())
    $evaluation = @($decision.candidate_evaluations)[0]

    Assert-Equal $decision.selected_candidate $null
    Assert-Equal $evaluation.requirements.passed $true
    Assert-Equal $evaluation.quality.passed $false
    Assert-Equal $evaluation.quality.reason_code 'quality_evidence_unknown'
    Assert-Equal $evaluation.price $null
    Assert-Equal $evaluation.rejection_stage 'quality'
}

Invoke-Assertion 'cheaper frontier beats more expensive strong after both pass the quality floor' {
    $profiles = @(Get-MinimalPolicyProfiles)
    $agy = @($profiles | Where-Object { $_.launcher -ceq 'agy' })[0]
    $codex = @($profiles | Where-Object { $_.launcher -ceq 'codex' })[0]
    Set-TestRelevantQuality -Candidate $agy -Request (New-MinimalRequest) `
        -RequiredCapabilities $qualityCapabilities -Category 'strong'
    Set-TestRelevantQuality -Candidate $codex -Request (New-MinimalRequest) `
        -RequiredCapabilities $qualityCapabilities -Category 'frontier'
    $snapshot = New-TestPolicyPricingSnapshot -AgyInputRate 10 -AgyOutputRate 50 `
        -CodexInputRate 1 -CodexOutputRate 5
    $agy.pricing.input_usd_per_million_tokens = 10
    $agy.pricing.output_usd_per_million_tokens = 50
    $decision = Invoke-TestRouterPolicy -Profiles $profiles -PricingSnapshot $snapshot `
        -TokenEstimates (Get-TestPolicyTokenEstimates -Profiles $profiles)

    Assert-Equal (Get-CompositeIdentity $decision.selected_candidate) 'codex|shared-model__medium'
}

Invoke-Assertion 'model and effort form one jointly ranked candidate' {
    $base = Copy-TestObject @(Get-MinimalPolicyProfiles)[0]
    $low = Copy-TestObject $base
    $low.configuration_id = 'shared-model__low'
    $low.effort = 'low'
    $high = Copy-TestObject $base
    $high.configuration_id = 'shared-model__high'
    $high.effort = 'high'
    $observations = @(
        (New-TestTokenObservation -Candidate $low -EstimatedVisibleOutputTokens 2000 -EstimatedReasoningTokens 2000)
        (New-TestTokenObservation -Candidate $high -EstimatedVisibleOutputTokens 100 -EstimatedReasoningTokens 100)
    )
    $decision = Invoke-TestRouterPolicy -Profiles @($low, $high) `
        -PricingSnapshot (New-TestPricingSnapshot) `
        -TokenEstimates (New-TestTokenEstimatesDocument -Observations $observations)

    Assert-Equal (Get-CompositeIdentity $decision.selected_candidate) 'agy|shared-model__high'
    Assert-Equal @($decision.candidate_evaluations | Where-Object { $_.selected }).Count 1
}

Invoke-Assertion 'price strictly outranks latency' {
    $profiles = @(Get-MinimalPolicyProfiles)
    $agy = @($profiles | Where-Object { $_.launcher -ceq 'agy' })[0]
    $codex = @($profiles | Where-Object { $_.launcher -ceq 'codex' })[0]
    $agy.latency_observation.milliseconds = 9000
    $codex.latency_observation.milliseconds = 1
    $snapshot = New-TestPolicyPricingSnapshot -AgyInputRate 1 -AgyOutputRate 5 `
        -CodexInputRate 2 -CodexOutputRate 10
    $codex.pricing.input_usd_per_million_tokens = 2
    $codex.pricing.output_usd_per_million_tokens = 10
    $decision = Invoke-TestRouterPolicy -Profiles $profiles -PricingSnapshot $snapshot `
        -TokenEstimates (Get-TestPolicyTokenEstimates -Profiles $profiles)

    Assert-Equal (Get-CompositeIdentity $decision.selected_candidate) 'agy|shared-model__medium'
}

foreach ($latencyMode in @('fast', 'normal')) {
    Invoke-Assertion ("lower available latency breaks an equal-price tie for $latencyMode requests") {
        $request = New-MinimalRequest
        $request.latency = $latencyMode
        $profiles = @(Get-MinimalPolicyProfiles)
        @($profiles | Where-Object { $_.launcher -ceq 'agy' })[0].latency_observation.milliseconds = 1000
        @($profiles | Where-Object { $_.launcher -ceq 'codex' })[0].latency_observation.milliseconds = 100
        $decision = Invoke-TestRouterPolicy -Request $request -Profiles $profiles `
            -PricingSnapshot (New-TestPolicyPricingSnapshot) `
            -TokenEstimates (Get-TestPolicyTokenEstimates -Profiles $profiles)

        Assert-Equal (Get-CompositeIdentity $decision.selected_candidate) 'codex|shared-model__medium'
    }
}

Invoke-Assertion 'available latency sorts before unavailable latency on an equal-price normal request' {
    $profiles = @(Get-MinimalPolicyProfiles)
    $agy = @($profiles | Where-Object { $_.launcher -ceq 'agy' })[0]
    $agy.latency_observation.available = $false
    $agy.latency_observation.metric = $null
    $agy.latency_observation.milliseconds = $null
    $agy.latency_observation.sample_count = $null
    $agy.latency_observation.observed_on = $null
    $decision = Invoke-TestRouterPolicy -Profiles $profiles `
        -PricingSnapshot (New-TestPolicyPricingSnapshot) `
        -TokenEstimates (Get-TestPolicyTokenEstimates -Profiles $profiles)

    Assert-Equal (Get-CompositeIdentity $decision.selected_candidate) 'codex|shared-model__medium'
}

Invoke-Assertion 'only measured end-to-end latency can break an equal-price tie' {
    $profiles = @(Get-MinimalPolicyProfiles)
    $agy = @($profiles | Where-Object { $_.launcher -ceq 'agy' })[0]
    $codex = @($profiles | Where-Object { $_.launcher -ceq 'codex' })[0]
    $agy.latency_observation.milliseconds = 1000
    $codex.latency_observation.metric = 'provider_only'
    $codex.latency_observation.milliseconds = 1
    $decision = Invoke-TestRouterPolicy -Profiles $profiles `
        -PricingSnapshot (New-TestPolicyPricingSnapshot) `
        -TokenEstimates (Get-TestPolicyTokenEstimates -Profiles $profiles)

    Assert-Equal (Get-CompositeIdentity $decision.selected_candidate) 'agy|shared-model__medium'
}

Invoke-Assertion 'relaxed latency skips measurements and proceeds to stable identity' {
    $request = New-MinimalRequest
    $request.latency = 'relaxed'
    $profiles = @(Get-MinimalPolicyProfiles)
    @($profiles | Where-Object { $_.launcher -ceq 'agy' })[0].latency_observation.milliseconds = 9000
    @($profiles | Where-Object { $_.launcher -ceq 'codex' })[0].latency_observation.milliseconds = 1
    $decision = Invoke-TestRouterPolicy -Request $request -Profiles $profiles `
        -PricingSnapshot (New-TestPolicyPricingSnapshot) `
        -TokenEstimates (Get-TestPolicyTokenEstimates -Profiles $profiles)

    Assert-Equal (Get-CompositeIdentity $decision.selected_candidate) 'agy|shared-model__medium'
}

Invoke-Assertion 'raw decimal price selects the winner even when response-boundary values round equally' {
    $profiles = @(Get-MinimalPolicyProfiles)
    $snapshot = New-TestPolicyPricingSnapshot -AgyInputRate ([decimal]0.10001) -AgyOutputRate 0 `
        -CodexInputRate ([decimal]0.10002) -CodexOutputRate 0
    $agy = @($profiles | Where-Object { $_.launcher -ceq 'agy' })[0]
    $codex = @($profiles | Where-Object { $_.launcher -ceq 'codex' })[0]
    $agy.pricing.input_usd_per_million_tokens = [decimal]0.10001
    $agy.pricing.output_usd_per_million_tokens = 0
    $codex.pricing.input_usd_per_million_tokens = [decimal]0.10002
    $codex.pricing.output_usd_per_million_tokens = 0
    $decision = Invoke-TestRouterPolicy -Profiles $profiles -PricingSnapshot $snapshot `
        -TokenEstimates (Get-TestPolicyTokenEstimates -Profiles $profiles)
    $prices = @($decision.candidate_evaluations | ForEach-Object { $_.price.price })

    Assert-Equal (Get-CompositeIdentity $decision.selected_candidate) 'agy|shared-model__medium'
    Assert-Equal ($prices[0] -ne $prices[1]) $true
    Assert-Equal (ConvertTo-RouterResponsePrice $prices[0] -DecimalPlaces 4) `
        (ConvertTo-RouterResponsePrice $prices[1] -DecimalPlaces 4)
}

Invoke-Assertion 'a zero-price candidate is unavailable and cannot win policy selection' {
    $profiles = @(Get-MinimalPolicyProfiles)
    $snapshot = New-TestPolicyPricingSnapshot -AgyInputRate 0 -AgyOutputRate 0 `
        -CodexInputRate 1 -CodexOutputRate 5
    $agy = @($profiles | Where-Object { $_.launcher -ceq 'agy' })[0]
    $agy.pricing.input_usd_per_million_tokens = 0
    $agy.pricing.output_usd_per_million_tokens = 0
    $decision = Invoke-TestRouterPolicy -Profiles $profiles -PricingSnapshot $snapshot `
        -TokenEstimates (Get-TestPolicyTokenEstimates -Profiles $profiles)
    $agyEvaluation = @($decision.candidate_evaluations | Where-Object { $_.launcher -ceq 'agy' })[0]

    Assert-Equal (Get-CompositeIdentity $decision.selected_candidate) 'codex|shared-model__medium'
    Assert-Equal $agyEvaluation.rejection_stage 'price'
    Assert-SequenceEqual @($agyEvaluation.rejection_reason_codes) @('free_route_disallowed')
}

Invoke-Assertion 'policy fails closed with no winner when the pricing snapshot is omitted' {
    $profiles = @(Get-MinimalPolicyProfiles)
    $decision = Invoke-TestRouterPolicy -Profiles $profiles `
        -TokenEstimates (Get-TestPolicyTokenEstimates -Profiles $profiles)

    Assert-Equal $decision.selected_candidate $null
    Assert-Equal $decision.price $null
    Assert-Equal @($decision.candidate_evaluations).Count 2
    foreach ($evaluation in @($decision.candidate_evaluations)) {
        Assert-Equal $evaluation.rejection_stage 'price'
        Assert-SequenceEqual @($evaluation.rejection_reason_codes) @('pricing_snapshot_unavailable')
    }
}

Invoke-Assertion 'policy fails closed with no winner when the pricing snapshot is explicitly null' {
    $profiles = @(Get-MinimalPolicyProfiles)
    $decision = Invoke-TestRouterPolicy -Profiles $profiles -PricingSnapshot $null `
        -TokenEstimates (Get-TestPolicyTokenEstimates -Profiles $profiles)

    Assert-Equal $decision.selected_candidate $null
    Assert-Equal $decision.price $null
    foreach ($evaluation in @($decision.candidate_evaluations)) {
        Assert-Equal $evaluation.rejection_stage 'price'
        Assert-SequenceEqual @($evaluation.rejection_reason_codes) @('pricing_snapshot_unavailable')
    }
}

$incompletePolicySnapshotCases = @(
    [pscustomobject]@{ name = 'missing top-level policy metadata'; property = 'policy' }
    [pscustomobject]@{ name = 'missing top-level retrieval metadata'; property = 'retrieved_on' }
)
foreach ($incompletePolicySnapshotCase in $incompletePolicySnapshotCases) {
    Invoke-Assertion ("policy rejects {0} before ranking" -f $incompletePolicySnapshotCase.name) {
        $snapshot = New-TestPolicyPricingSnapshot
        $snapshot.PSObject.Properties.Remove($incompletePolicySnapshotCase.property)

        Assert-PolicyPricingSnapshotRejected -PricingSnapshot $snapshot
    }
}

Invoke-Assertion 'policy rejects scalar rate periods before ranking' {
    $snapshot = New-TestPolicyPricingSnapshot
    $snapshot.schedules[0].rate_periods = $snapshot.schedules[0].rate_periods[0]

    Assert-PolicyPricingSnapshotRejected -PricingSnapshot $snapshot
}

$missingPolicyScheduleFieldCases = @('source_url', 'model', 'retrieved_on')
foreach ($missingPolicyScheduleField in $missingPolicyScheduleFieldCases) {
    Invoke-Assertion ("policy rejects a schedule missing {0} before ranking" -f $missingPolicyScheduleField) {
        $snapshot = New-TestPolicyPricingSnapshot
        $snapshot.schedules[0].PSObject.Properties.Remove($missingPolicyScheduleField)

        Assert-PolicyPricingSnapshotRejected -PricingSnapshot $snapshot
    }
}

foreach ($exactPricingSnapshotContractCase in $exactPricingSnapshotContractCases) {
    Invoke-Assertion ("policy rejects pricing snapshot {0} before ranking" -f $exactPricingSnapshotContractCase.name) {
        $snapshot = New-TestPolicyPricingSnapshot
        & $exactPricingSnapshotContractCase.mutate $snapshot

        Assert-PolicyPricingSnapshotRejected -PricingSnapshot $snapshot
    }
}

$invalidPolicyPartitionCases = @(
    [pscustomobject]@{ name = 'token partition gap'; kind = 'token'; successor = 102 }
    [pscustomobject]@{ name = 'token partition overlap'; kind = 'token'; successor = 100 }
    [pscustomobject]@{ name = 'effective-date gap'; kind = 'date'; successor = '2026-08-25' }
    [pscustomobject]@{ name = 'effective-date overlap'; kind = 'date'; successor = '2026-08-23' }
)
foreach ($invalidPolicyPartitionCase in $invalidPolicyPartitionCases) {
    Invoke-Assertion ("policy rejects a pricing schedule with a {0}" -f $invalidPolicyPartitionCase.name) {
        $snapshot = New-TestPolicyPricingSnapshot
        $first = $snapshot.schedules[0].rate_periods[0]
        $second = Copy-TestObject $first
        if ($invalidPolicyPartitionCase.kind -ceq 'token') {
            $first.input_tokens_max = 100
            $second.input_tokens_min = $invalidPolicyPartitionCase.successor
            $second.input_tokens_max = $null
        } else {
            $first.effective_through = '2026-08-23'
            $second.effective_from = $invalidPolicyPartitionCase.successor
            $second.effective_through = $null
        }
        $snapshot.schedules[0].rate_periods = @($first, $second)

        Assert-PolicyPricingSnapshotRejected -PricingSnapshot $snapshot
    }
}

Invoke-Assertion 'policy rejects a non-final decimal MaxValue token bound without throwing' {
    $snapshot = New-TestPolicyPricingSnapshot
    $first = $snapshot.schedules[0].rate_periods[0]
    $first.input_tokens_max = [decimal]::MaxValue
    $second = Copy-TestObject $first
    $second.input_tokens_min = [decimal]::MaxValue
    $second.input_tokens_max = $null
    $snapshot.schedules[0].rate_periods = @($first, $second)

    Assert-PolicyPricingSnapshotRejected -PricingSnapshot $snapshot
}

Invoke-Assertion 'policy rejects duplicate applicable schedules before ranking' {
    $snapshot = New-TestPolicyPricingSnapshot
    $duplicate = Copy-TestObject $snapshot.schedules[0]
    $duplicate.model = 'duplicate-google-schedule'
    $snapshot.schedules = @($snapshot.schedules + $duplicate)

    Assert-PolicyPricingSnapshotRejected -PricingSnapshot $snapshot
}

Invoke-Assertion 'policy rejects duplicate provider and canonical model schedules with disjoint aliases' {
    $snapshot = New-TestPolicyPricingSnapshot
    $duplicate = Copy-TestObject $snapshot.schedules[0]
    $duplicate.profile_models = @('disjoint-profile-model-alias')
    $snapshot.schedules = @($snapshot.schedules + $duplicate)

    Assert-PolicyPricingSnapshotRejected -PricingSnapshot $snapshot
}

Invoke-Assertion 'policy rejects duplicate applicable pricing periods before ranking' {
    $snapshot = New-TestPolicyPricingSnapshot
    $duplicate = Copy-TestObject $snapshot.schedules[0].rate_periods[0]
    $snapshot.schedules[0].rate_periods = @($snapshot.schedules[0].rate_periods[0], $duplicate)

    Assert-PolicyPricingSnapshotRejected -PricingSnapshot $snapshot
}

Invoke-Assertion 'policy rejects profile rates that do not match the applicable snapshot period' {
    $candidate = Copy-TestObject @(Get-MinimalProfiles)[0]
    $candidate.pricing.input_usd_per_million_tokens = 99
    $candidate.pricing.output_usd_per_million_tokens = 99

    Assert-PolicyPricingSnapshotRejected -PricingSnapshot (New-TestPricingSnapshot) `
        -Profiles @($candidate) -ExpectedReasonCode 'pricing_snapshot_mismatch'
}

Invoke-Assertion 'all failed candidates receive deterministic evaluations and no candidate is selected' {
    $profiles = @(Get-MinimalProfiles | ForEach-Object { Copy-TestObject $_ })
    foreach ($profile in $profiles) {
        $profile.enabled = $false
        $profile.availability = 'unavailable'
    }
    $decision = Invoke-TestRouterPolicy -Profiles $profiles

    Assert-Equal $decision.selected_candidate $null
    Assert-Equal @($decision.candidate_evaluations).Count 2
    Assert-SequenceEqual @($decision.candidate_evaluations | ForEach-Object { $_.candidate_identity }) @(
        'agy|shared-model__medium'
        'codex|shared-model__medium'
    )
    foreach ($evaluation in @($decision.candidate_evaluations)) {
        Assert-SequenceEqual @($evaluation.rejection_reason_codes) @('candidate_disabled', 'candidate_unavailable')
    }
}

Invoke-Assertion 'duplicate explicit runtime states fail conservatively without arbitrary matching' {
    $profiles = @(Get-MinimalPolicyProfiles)
    $agyRuntime = New-MinimalRuntimeState
    $codexRuntime = [pscustomobject]@{
        launcher = 'codex'; model = 'shared-model-openai'; effort = 'medium'; available = $true
        authenticated = $true; working = $true; quota_exhausted = $false
    }
    $decision = Invoke-TestRouterPolicy -Profiles $profiles -RuntimeStates @(
        $agyRuntime
        (Copy-TestObject $agyRuntime)
        $codexRuntime
    ) -PricingSnapshot (New-TestPolicyPricingSnapshot) `
        -TokenEstimates (Get-TestPolicyTokenEstimates -Profiles $profiles)
    $agyEvaluation = @($decision.candidate_evaluations | Where-Object { $_.launcher -ceq 'agy' })[0]

    Assert-Equal $agyEvaluation.rejection_stage 'requirements'
    Assert-SequenceEqual @($agyEvaluation.rejection_reason_codes) @('runtime_state_invalid')
    Assert-Equal (Get-CompositeIdentity $decision.selected_candidate) 'codex|shared-model__medium'
}

Invoke-Assertion 'stable identity sorting is ordinal under a non-default culture' {
    $base = Copy-TestObject @(Get-MinimalProfiles)[0]
    $ascii = Copy-TestObject $base
    $ascii.launcher = 'I'
    $unicode = Copy-TestObject $base
    $unicode.launcher = 'ı'
    $observations = @(
        (New-TestTokenObservation -Candidate $ascii)
        (New-TestTokenObservation -Candidate $unicode)
    )
    $request = New-MinimalRequest
    $request.latency = 'relaxed'
    $originalCulture = [Globalization.CultureInfo]::CurrentCulture
    try {
        [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('tr-TR')
        $decision = Invoke-TestRouterPolicy -Request $request -Profiles @($unicode, $ascii) `
            -PricingSnapshot (New-TestPolicyPricingSnapshot) `
            -TokenEstimates (New-TestTokenEstimatesDocument -Observations $observations)
    } finally {
        [Globalization.CultureInfo]::CurrentCulture = $originalCulture
    }

    Assert-Equal (Get-CompositeIdentity $decision.selected_candidate) 'I|shared-model__medium'
}

Invoke-Assertion 'stable identity is ascending ordinal launcher|configuration_id' {
        $agyIdentity = 'agy|shared-model__medium'
        $codexIdentity = 'codex|shared-model__medium'

        Assert-Equal ([string]::CompareOrdinal($agyIdentity, $codexIdentity) -lt 0) $true
    }

Invoke-Assertion 'policy preserves exact composite identity' {
        $profiles = @(Get-MinimalPolicyProfiles)
        $decision = Invoke-TestRouterPolicy -Profiles $profiles `
            -PricingSnapshot (New-TestPolicyPricingSnapshot) `
            -TokenEstimates (Get-TestPolicyTokenEstimates -Profiles $profiles)
        $identities = @(
            $decision.candidate_evaluations |
                ForEach-Object { Get-CompositeIdentity $_ }
        )

        Assert-Equal $identities.Count 2
        Assert-Equal (@($identities | Where-Object { $_ -ceq 'agy|shared-model__medium' }).Count) 1
        Assert-Equal (@($identities | Where-Object { $_ -ceq 'codex|shared-model__medium' }).Count) 1
    }

Invoke-Assertion 'policy selects exactly one candidate' {
        $profiles = @(Get-MinimalPolicyProfiles)
        $decision = Invoke-TestRouterPolicy -Profiles $profiles `
            -PricingSnapshot (New-TestPolicyPricingSnapshot) `
            -TokenEstimates (Get-TestPolicyTokenEstimates -Profiles $profiles)

        Assert-Equal (@($decision.selected_candidate).Count) 1
        Assert-Equal (Get-CompositeIdentity $decision.selected_candidate) 'agy|shared-model__medium'
    }

Invoke-Assertion 'policy selection is invariant to forward and reverse tied input order' {
        $forwardProfiles = @(Get-MinimalPolicyProfiles)
        $reverseProfiles = [object[]]$forwardProfiles.Clone()
        [array]::Reverse($reverseProfiles)
        Assert-SequenceEqual @($forwardProfiles | ForEach-Object { Get-CompositeIdentity $_ }) @(
            'agy|shared-model__medium'
            'codex|shared-model__medium'
        )
        Assert-SequenceEqual @($reverseProfiles | ForEach-Object { Get-CompositeIdentity $_ }) @(
            'codex|shared-model__medium'
            'agy|shared-model__medium'
        )
        $inputOrders = @(
            [pscustomobject]@{ name = 'forward'; profiles = $forwardProfiles }
            [pscustomobject]@{ name = 'reverse'; profiles = $reverseProfiles }
        )
        $selectedIdentities = @(
            foreach ($inputOrder in $inputOrders) {
                1..25 | ForEach-Object {
                    $decision = Invoke-TestRouterPolicy -Profiles $inputOrder.profiles `
                        -PricingSnapshot (New-TestPolicyPricingSnapshot) `
                        -TokenEstimates (Get-TestPolicyTokenEstimates -Profiles $inputOrder.profiles)
                    $selectedIdentity = Get-CompositeIdentity $decision.selected_candidate
                    if ($selectedIdentity -cne 'agy|shared-model__medium') {
                        throw "The $($inputOrder.name) tied input selected '$selectedIdentity'."
                    }
                    $selectedIdentity
                }
            }
        )

        Assert-Equal (@($selectedIdentities | Select-Object -Unique).Count) 1
        Assert-Equal $selectedIdentities[0] 'agy|shared-model__medium'
    }

function New-Task7TraceFixture {
    param([string]$TraceId = 'powershell-trace-0001')

    $identity = 'codex|gpt-test__medium'
    return [pscustomobject][ordered]@{
        trace_id = $TraceId
        created_at = '2026-08-24T03:45:00Z'
        run_mode = 'normal'
        request_profile = [pscustomobject][ordered]@{
            task_type = 'coding'
            domain = 'computer_science'
            complexity = 'medium'
            quality_floor = 'strong'
            latency = 'normal'
            privacy_level = 'standard'
            risk_level = 'standard'
            output_length = 'normal'
            language = 'english'
            additional_capabilities = @('reasoning')
        }
        selected_candidate = $identity
        output_status = 'completed'
        reason_code = $null
        effective_quality = 'strong'
        quality_bottleneck = 'task_type.coding'
        price = '0.0100000000000000000000000001'
        price_final = $true
        latency_ms = '10.5'
        router_policy_version = 'policy-v1'
        profile_schema_version = 'router-model-profile/v1'
        model_profile_version = 'catalog-2026-08-24'
        pricing_snapshot_date = '2026-08-22'
        quality_snapshot_date = '2026-08-22'
        calibration_set_version = 'calibration-set-v1'
        prompt_hash = ('A' * 64)
        response_hash = ('B' * 64)
        prompt_content = $null
        response_content = $null
        candidate_evaluations = @(
            [pscustomobject][ordered]@{
                candidate_identity = $identity
                launcher = 'codex'
                configuration_id = 'gpt-test__medium'
                provider = 'openai'
                model = 'gpt-test'
                effort = 'medium'
                eligible = $true
                selected = $true
                rejection_stage = $null
                rejection_reason_codes = @()
                requirements = [pscustomobject][ordered]@{
                    candidate_identity = $identity
                    passed = $true
                    reason_codes = @()
                    unavailable_capabilities = @()
                    unsupported_requirements = @()
                }
                quality = [pscustomobject][ordered]@{
                    candidate_identity = $identity
                    passed = $true
                    reason_code = $null
                    effective_quality = 'strong'
                    quality_bottleneck = 'task_type.coding'
                    relevant_categories = @(
                        [pscustomobject][ordered]@{
                            key = 'task_type.coding'
                            category = 'strong'
                        }
                    )
                }
                price = [pscustomobject][ordered]@{
                    candidate_identity = $identity
                    available = $true
                    reason_code = $null
                    request_profile_group = 'coding|computer_science|medium|normal'
                    estimated_input_tokens = 100
                    estimated_visible_output_tokens = 50
                    estimated_reasoning_tokens = 25
                    estimated_billable_output_tokens = 75
                    input_usd_per_million_tokens = '1.25'
                    output_usd_per_million_tokens = '10.00'
                    price = '0.000875'
                    price_final = $false
                }
                latency_available = $true
                latency_milliseconds = '10.5'
            }
        )
    }
}

Invoke-Assertion 'Task 7 trace bridge stores one complete trace through standard input' {
    $python = 'C:\Users\2006i\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('router-trace-' + [guid]::NewGuid().ToString('N'))
    $databasePath = Join-Path $tempRoot 'router.sqlite'
    try {
        $result = Write-RouterTrace -Trace (New-Task7TraceFixture) -DatabasePath $databasePath `
            -PythonExecutable $python

        Assert-Equal $result.ok $true
        Assert-Equal $result.trace_id 'powershell-trace-0001'
        Assert-Equal $result.candidate_evaluations_inserted 1
        Assert-Equal (Test-Path -LiteralPath $databasePath -PathType Leaf) $true
    } finally {
        if (Test-Path -LiteralPath $tempRoot) {
            [IO.Directory]::Delete($tempRoot, $true)
        }
    }
}

Invoke-Assertion 'Task 7 trace bridge surfaces writer validation as a structured object' {
    $python = 'C:\Users\2006i\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('router-trace-' + [guid]::NewGuid().ToString('N'))
    $databasePath = Join-Path $tempRoot 'router.sqlite'
    try {
        $trace = New-Task7TraceFixture -TraceId 'invalid-normal-content'
        $trace.prompt_content = 'normal mode must reject this content'
        $result = Write-RouterTrace -Trace $trace -DatabasePath $databasePath `
            -PythonExecutable $python

        Assert-Equal $result.ok $false
        Assert-Equal $result.error.code 'invalid_trace'
        Assert-Equal $result.error.path '$.prompt_content'
        Assert-Equal (Test-Path -LiteralPath $databasePath) $false
    } finally {
        if (Test-Path -LiteralPath $tempRoot) {
            [IO.Directory]::Delete($tempRoot, $true)
        }
    }
}

Invoke-Assertion 'Task 7 trace bridge returns a structured Python availability error' {
    $missingPython = Join-Path ([IO.Path]::GetTempPath()) ('missing-python-' + [guid]::NewGuid().ToString('N') + '.exe')
    $result = Write-RouterTrace -Trace (New-Task7TraceFixture) `
        -DatabasePath (Join-Path ([IO.Path]::GetTempPath()) 'unused-router.sqlite') `
        -PythonExecutable $missingPython

    Assert-Equal $result.ok $false
    Assert-Equal $result.error.code 'python_unavailable'
}

Invoke-Assertion 'Task 7 trace bridge keeps trace JSON off the native command line' {
    $source = Get-Content -LiteralPath $traceModulePath -Raw

    Assert-Equal ($source -match 'RedirectStandardInput\s*=\s*\$true') $true
    Assert-Equal ($source -match 'StandardInput\.Write') $true
    Assert-Equal ($source -match 'ArgumentList\.Add\(\$traceJson') $false
    Assert-Equal ($source -match '(?i)\s-command\s') $false
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    exit 1
}

exit 0
