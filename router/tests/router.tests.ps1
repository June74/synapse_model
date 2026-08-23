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
$policyModulePath = Join-Path $projectRoot 'router/lib/policy.ps1'
$requestSchemaPath = Join-Path $projectRoot 'router/schemas/request-profile.schema.json'
$profileSchemaPath = Join-Path $projectRoot 'router/schemas/model-profile.schema.json'
$responseSchemaPath = Join-Path $projectRoot 'router/schemas/router-response.schema.json'
$profilesRoot = Join-Path $projectRoot 'profiles'
$matrixPath = Join-Path $projectRoot 'pilot/model_matrix.json'
$pricingSnapshotPath = Join-Path $projectRoot 'router/data/pricing-snapshot-2026-08-22.json'
$qualitySnapshotPath = Join-Path $projectRoot 'router/data/quality-snapshot-2026-08-22.json'

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
$policyAvailable = Test-Path -LiteralPath $policyModulePath -PathType Leaf
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

function Get-CompositeIdentity {
    param([Parameter(Mandatory)][object]$Candidate)

    return '{0}|{1}' -f $Candidate.launcher, $Candidate.configuration_id
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

function Invoke-WithTemporaryCatalog {
    param([Parameter(Mandatory)][scriptblock]$Script)

    $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('router-catalog-test-{0}' -f [guid]::NewGuid().ToString('N'))
    try {
        $null = New-Item -ItemType Directory -Path (Join-Path $temporaryRoot 'profiles') -Force
        & $Script $temporaryRoot
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
}

Invoke-Assertion 'quality snapshot records one conservative evidence row per exact candidate' {
    $matrix = Get-Content -LiteralPath $matrixPath -Raw | ConvertFrom-Json -Depth 100
    $enabledCandidates = @($matrix.candidates | Where-Object { $_.enabled -and $_.candidate_kind -ceq 'model' })
    $snapshot = Get-Content -LiteralPath $qualitySnapshotPath -Raw | ConvertFrom-Json -Depth 100
    Assert-Equal $snapshot.snapshot_date '2026-08-22'
    Assert-Equal @($snapshot.records).Count $enabledCandidates.Count
    foreach ($record in $snapshot.records) {
        foreach ($property in @('launcher', 'configuration_id', 'model', 'effort', 'source_url', 'retrieved_on', 'exact_model_match', 'exact_effort_match', 'benchmark_slice', 'provisional_category')) {
            Assert-Equal ($record.PSObject.Properties.Name -ccontains $property) $true
        }
        Assert-Equal ($qualityCategories -ccontains $record.provisional_category) $true
        if (-not $record.exact_model_match -or -not $record.exact_effort_match -or $record.benchmark_slice -ceq 'unavailable') {
            Assert-Equal $record.provisional_category 'unknown'
        }
    }
}

Invoke-Assertion 'production catalog covers each enabled normal matrix candidate exactly once' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    $catalog = Import-RouterProfileCatalog -ProfilesRoot $profilesRoot -MatrixPath $matrixPath -ProfileSchemaPath $profileSchemaPath
    Assert-Equal $catalog.valid $true
    Assert-Equal @($catalog.errors).Count 0
    Assert-Equal @($catalog.profiles).Count 63

    [string[]]$identities = @($catalog.profiles | ForEach-Object { '{0}|{1}' -f $_.launcher, $_.configuration_id })
    [string[]]$sortedIdentities = @($identities)
    [Array]::Sort($sortedIdentities, [System.StringComparer]::Ordinal)
    Assert-SequenceEqual $identities $sortedIdentities
    Assert-Equal @($identities | Select-Object -Unique).Count 63

    foreach ($profile in $catalog.profiles) {
        Assert-Equal $profile.configuration_id ('{0}__{1}' -f $profile.model, $profile.effort)
        Assert-ValidationSuccess (Test-RouterSchema -Value $profile -SchemaPath $profileSchemaPath)
        foreach ($mapName in $requiredQualityKeys.Keys) {
            [string[]]$actualKeys = @($profile.quality.$mapName.PSObject.Properties.Name)
            [string[]]$expectedKeys = @($requiredQualityKeys[$mapName])
            [Array]::Sort($actualKeys, [System.StringComparer]::Ordinal)
            [Array]::Sort($expectedKeys, [System.StringComparer]::Ordinal)
            Assert-SequenceEqual $actualKeys $expectedKeys
        }
    }
}

Invoke-Assertion 'Spark profiles are unknown-cost and cannot be ranked as free' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    $catalog = Import-RouterProfileCatalog -ProfilesRoot $profilesRoot -MatrixPath $matrixPath -ProfileSchemaPath $profileSchemaPath
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

Invoke-Assertion 'catalog reports missing profile coverage before routing' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        $catalog = Import-RouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath
        Assert-Equal $catalog.valid $false
        Assert-CatalogError -Catalog $catalog -Code 'profile_coverage_missing'
    }
}

Invoke-Assertion 'catalog reports duplicate launcher and configuration identity' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        $profile = Copy-TestObject @(Get-MinimalProfiles)[0]
        Write-TestJson -Path (Join-Path $root 'profiles/agy/a.json') -Value $profile
        Write-TestJson -Path (Join-Path $root 'profiles/agy/b.json') -Value $profile
        $catalog = Import-RouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath
        Assert-Equal $catalog.valid $false
        Assert-CatalogError -Catalog $catalog -Code 'duplicate_profile_identity'
    }
}

Invoke-Assertion 'catalog reports malformed JSON and schema-invalid profiles structurally' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        $profileDir = Join-Path $root 'profiles/agy'
        $null = New-Item -ItemType Directory -Path $profileDir -Force
        Set-Content -LiteralPath (Join-Path $profileDir 'a-malformed.json') -Value '{bad json' -Encoding utf8NoBOM
        $invalidProfile = Copy-TestObject @(Get-MinimalProfiles)[0]
        $invalidProfile.quality.task_types.PSObject.Properties.Remove('coding')
        Write-TestJson -Path (Join-Path $profileDir 'b-schema-invalid.json') -Value $invalidProfile
        $catalog = Import-RouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath
        Assert-Equal $catalog.valid $false
        Assert-CatalogError -Catalog $catalog -Code 'profile_json_invalid'
        Assert-CatalogError -Catalog $catalog -Code 'profile_schema_invalid'
    }
}

Invoke-Assertion 'catalog rejects duplicate JSON property names instead of silently taking the last value' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        $profile = Copy-TestObject @(Get-MinimalProfiles)[0]
        $profilePath = Join-Path $root 'profiles/agy/shared-model__medium.json'
        Write-TestJson -Path $profilePath -Value $profile
        $profileText = [IO.File]::ReadAllText($profilePath)
        $profileText = $profileText.Replace('"launcher": "agy",', '"launcher": "agy",' + [Environment]::NewLine + '  "launcher": "codex",')
        [IO.File]::WriteAllText($profilePath, $profileText, [Text.UTF8Encoding]::new($false))

        $catalog = Import-RouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath
        Assert-Equal $catalog.valid $false
        Assert-CatalogError -Catalog $catalog -Code 'profile_json_invalid'
    }
}

Invoke-Assertion 'catalog reports candidate identity mismatch and pricing-state misuse' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix -Provider 'anthropic')
        $profile = Copy-TestObject @(Get-MinimalProfiles)[0]
        $profile.pricing.cost_comparable = $false
        Write-TestJson -Path (Join-Path $root 'profiles/agy/shared-model__medium.json') -Value $profile
        $catalog = Import-RouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath
        Assert-Equal $catalog.valid $false
        Assert-CatalogError -Catalog $catalog -Code 'candidate_profile_mismatch'
        Assert-CatalogError -Catalog $catalog -Code 'profile_pricing_invalid'
    }
}

Invoke-Assertion 'catalog reports unavailable-latency state misuse' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        $profile = Copy-TestObject @(Get-MinimalProfiles)[0]
        $profile.latency_observation.available = $false
        Write-TestJson -Path (Join-Path $root 'profiles/agy/shared-model__medium.json') -Value $profile
        $catalog = Import-RouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath
        Assert-Equal $catalog.valid $false
        Assert-CatalogError -Catalog $catalog -Code 'profile_latency_invalid'
    }
}

Invoke-Assertion 'catalog error ordering is deterministic by code file and identity' {
    if (-not $profilesAvailable) { throw 'Import-RouterProfileCatalog is unavailable.' }
    Invoke-WithTemporaryCatalog {
        param($root)
        $testMatrixPath = Join-Path $root 'matrix.json'
        Write-TestJson -Path $testMatrixPath -Value (New-TestMatrix)
        $profileDir = Join-Path $root 'profiles/agy'
        $null = New-Item -ItemType Directory -Path $profileDir -Force
        Set-Content -LiteralPath (Join-Path $profileDir 'z.json') -Value '{bad z' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $profileDir 'a.json') -Value '{bad a' -Encoding utf8NoBOM
        $first = Import-RouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath
        $second = Import-RouterProfileCatalog -ProfilesRoot (Join-Path $root 'profiles') -MatrixPath $testMatrixPath -ProfileSchemaPath $profileSchemaPath
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

if ($policyAvailable) {
    Invoke-Assertion 'stable identity is ascending ordinal launcher|configuration_id' {
        $agyIdentity = 'agy|shared-model__medium'
        $codexIdentity = 'codex|shared-model__medium'

        Assert-Equal ([string]::CompareOrdinal($agyIdentity, $codexIdentity) -lt 0) $true
    }

    Invoke-Assertion 'policy preserves exact composite identity' {
        $decision = Invoke-RouterPolicy -Request (New-MinimalRequest) -Profiles (Get-MinimalProfiles)
        $identities = @(
            $decision.candidate_evaluations |
                ForEach-Object { Get-CompositeIdentity $_ }
        )

        Assert-Equal $identities.Count 2
        Assert-Equal (@($identities | Where-Object { $_ -ceq 'agy|shared-model__medium' }).Count) 1
        Assert-Equal (@($identities | Where-Object { $_ -ceq 'codex|shared-model__medium' }).Count) 1
    }

    Invoke-Assertion 'policy selects exactly one candidate' {
        $decision = Invoke-RouterPolicy -Request (New-MinimalRequest) -Profiles (Get-MinimalProfiles)

        Assert-Equal (@($decision.selected_candidate).Count) 1
        Assert-Equal (Get-CompositeIdentity $decision.selected_candidate) 'agy|shared-model__medium'
    }

    Invoke-Assertion 'policy selection is invariant to forward and reverse tied input order' {
        $forwardProfiles = @(Get-MinimalProfiles)
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
                    $decision = Invoke-RouterPolicy -Request (New-MinimalRequest) -Profiles $inputOrder.profiles
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
} else {
    Write-Host 'PENDING policy tests: router/lib/policy.ps1 is planned for Task 6.'
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    exit 1
}

exit 0
