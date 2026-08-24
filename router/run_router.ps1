[CmdletBinding()]
param([AllowNull()][string]$RequestFile)

$ErrorActionPreference = 'Stop'

$script:RouterProjectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib/policy.ps1')
. (Join-Path $PSScriptRoot 'lib/profiles.ps1')
. (Join-Path $PSScriptRoot 'lib/response.ps1')
. (Join-Path $PSScriptRoot 'lib/trace.ps1')
. (Join-Path $script:RouterProjectRoot 'pilot/lib/runner.ps1')

function New-RouterInternalResult {
    param(
        [Parameter(Mandatory)][object]$Response,
        [AllowNull()][object]$Trace,
        [AllowNull()][object]$StorageError
    )

    return [pscustomobject][ordered]@{
        response = $Response
        trace = $Trace
        storage_error = $StorageError
    }
}

function Test-RouterBoundaryOnlyValidationFailure {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ValidationErrors)

    if ($ValidationErrors.Count -eq 0) { return $false }
    $boundaryCodes = @(
        'unsupported_language'
        'unsupported_modality'
        'sensitive_request_unsupported'
        'high_stakes_unsupported'
    )
    foreach ($error in $ValidationErrors) {
        if ($error.code -notin $boundaryCodes) { return $false }
    }
    return $true
}

function ConvertTo-RouterNormalizedRequest {
    param([Parameter(Mandatory)][object]$Request)

    [object[]]$additionalCapabilities = @()
    if ($Request.PSObject.Properties.Name -ccontains 'additional_capabilities') {
        $additionalCapabilities = @($Request.additional_capabilities)
    }
    return [pscustomobject][ordered]@{
        request_text = [string]$Request.request_text
        task_type = [string]$Request.task_type
        domain = [string]$Request.domain
        complexity = [string]$Request.complexity
        quality_floor = [string]$Request.quality_floor
        latency = if ($Request.PSObject.Properties.Name -ccontains 'latency') {
            [string]$Request.latency
        } else { 'normal' }
        privacy_level = [string]$Request.privacy_level
        risk_level = [string]$Request.risk_level
        output_length = if ($Request.PSObject.Properties.Name -ccontains 'output_length') {
            [string]$Request.output_length
        } else { 'normal' }
        language = [string]$Request.language
        additional_capabilities = $additionalCapabilities
    }
}

function ConvertTo-RouterTraceRequestProfile {
    param([Parameter(Mandatory)][object]$Request)

    return [pscustomobject][ordered]@{
        task_type = [string]$Request.task_type
        domain = [string]$Request.domain
        complexity = [string]$Request.complexity
        quality_floor = [string]$Request.quality_floor
        latency = [string]$Request.latency
        privacy_level = [string]$Request.privacy_level
        risk_level = [string]$Request.risk_level
        output_length = [string]$Request.output_length
        language = [string]$Request.language
        additional_capabilities = @($Request.additional_capabilities)
    }
}

function New-RouterTokenEstimateDocument {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Profiles)

    $observations = @(
        foreach ($profile in $Profiles) {
            foreach ($observation in @($profile.token_consumption_observations)) {
                [pscustomobject][ordered]@{
                    launcher = [string]$profile.launcher
                    configuration_id = [string]$profile.configuration_id
                    model = [string]$observation.model
                    effort = [string]$observation.effort
                    request_profile_group = [string]$observation.request_profile_group
                    estimated_input_tokens = $observation.estimated_input_tokens
                    estimated_visible_output_tokens = $observation.estimated_visible_output_tokens
                    estimated_reasoning_tokens = $observation.estimated_reasoning_tokens
                    observed_on = [string]$observation.observed_on
                }
            }
        }
    )
    return [pscustomobject][ordered]@{
        version = 'router-token-estimates/v1'
        observations = $observations
    }
}

function Find-RouterPilotCandidate {
    param(
        [Parameter(Mandatory)][object]$SelectedProfile,
        [Parameter(Mandatory)][object]$Matrix
    )

    $matches = @(
        @($Matrix.candidates) | Where-Object {
            $effort = if ($_.PSObject.Properties.Name -ccontains 'effort') {
                [string]$_.effort
            } else { 'default' }
            $_.enabled -and $_.candidate_kind -ceq 'model' -and
            $_.tool -ceq $SelectedProfile.launcher -and
            $_.provider -ceq $SelectedProfile.provider -and
            $_.model -ceq $SelectedProfile.model -and
            $effort -ceq $SelectedProfile.effort
        }
    )
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function ConvertTo-RouterTraceInteger {
    param([Parameter(Mandatory)][object]$Value)

    $text = ([decimal]$Value).ToString('0', [Globalization.CultureInfo]::InvariantCulture)
    $integer = [Numerics.BigInteger]::Parse($text, [Globalization.CultureInfo]::InvariantCulture)
    if ($integer -le [long]::MaxValue) { return [long]$integer }
    return $integer
}

function ConvertTo-RouterTracePrice {
    param([Parameter(Mandatory)][object]$Price)

    $actual = $Price.PSObject.Properties.Name -ccontains 'actual_input_tokens'
    $inputTokens = if ($actual) { $Price.actual_input_tokens } else { $Price.estimated_input_tokens }
    $visibleTokens = if ($actual) { $Price.visible_output_tokens } else { $Price.estimated_visible_output_tokens }
    $reasoningTokens = if ($actual) { $Price.reasoning_tokens } else { $Price.estimated_reasoning_tokens }
    $billableTokens = if ($actual) { $Price.billable_output_tokens } else { $Price.estimated_billable_output_tokens }
    return [pscustomobject][ordered]@{
        candidate_identity = [string]$Price.candidate_identity
        available = [bool]$Price.available
        reason_code = $Price.reason_code
        request_profile_group = [string]$Price.request_profile_group
        estimated_input_tokens = ConvertTo-RouterTraceInteger -Value $inputTokens
        estimated_visible_output_tokens = ConvertTo-RouterTraceInteger -Value $visibleTokens
        estimated_reasoning_tokens = ConvertTo-RouterTraceInteger -Value $reasoningTokens
        estimated_billable_output_tokens = ConvertTo-RouterTraceInteger -Value $billableTokens
        input_usd_per_million_tokens = $Price.input_usd_per_million_tokens
        output_usd_per_million_tokens = $Price.output_usd_per_million_tokens
        price = $Price.price
        price_final = [bool]$Price.price_final
    }
}

function Copy-RouterEvaluationForTrace {
    param([Parameter(Mandatory)][object]$Evaluation)

    return [pscustomobject][ordered]@{
        candidate_identity = [string]$Evaluation.candidate_identity
        launcher = [string]$Evaluation.launcher
        configuration_id = [string]$Evaluation.configuration_id
        provider = [string]$Evaluation.provider
        model = [string]$Evaluation.model
        effort = [string]$Evaluation.effort
        eligible = [bool]$Evaluation.eligible
        selected = [bool]$Evaluation.selected
        rejection_stage = $Evaluation.rejection_stage
        rejection_reason_codes = @($Evaluation.rejection_reason_codes)
        requirements = $Evaluation.requirements
        quality = $Evaluation.quality
        price = $Evaluation.price
        latency_available = [bool]$Evaluation.latency_available
        latency_milliseconds = $Evaluation.latency_milliseconds
    }
}

function ConvertTo-RouterInvariantText {
    param([Parameter(Mandatory)][object]$Value)

    return [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
}

function New-RouterDecisionTrace {
    param(
        [Parameter(Mandatory)][string]$TraceId,
        [Parameter(Mandatory)][string]$CreatedAt,
        [Parameter(Mandatory)][ValidateSet('normal', 'benchmark', 'calibration')][string]$RunMode,
        [Parameter(Mandatory)][object]$Request,
        [Parameter(Mandatory)][object]$Decision,
        [Parameter(Mandatory)][object]$Normalized,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Profiles,
        [Parameter(Mandatory)][object]$PricingSnapshot,
        [Parameter(Mandatory)][object]$QualitySnapshot
    )

    $response = $Normalized.response
    $winnerStatus = $response.status -cin @('completed', 'execution_failed')
    $selectedIdentity = if ($winnerStatus) {
        '{0}|{1}' -f $Decision.selected_candidate.launcher, $Decision.selected_candidate.configuration_id
    } else { $null }
    $evaluations = @(
        foreach ($evaluation in @($Decision.candidate_evaluations)) {
            Copy-RouterEvaluationForTrace -Evaluation $evaluation
        }
    )
    if ($winnerStatus) {
        $selectedEvaluation = @($evaluations | Where-Object { $_.selected })[0]
        $selectedEvaluation.price = ConvertTo-RouterTracePrice -Price $Normalized.price
        if ($null -ne $Normalized.latency_ms) {
            $selectedEvaluation.latency_available = $true
            $selectedEvaluation.latency_milliseconds = $Normalized.latency_ms
        }
    }

    $versionProfile = if ($null -ne $Decision.selected_candidate) {
        $Decision.selected_candidate
    } elseif ($Profiles.Count -gt 0) { $Profiles[0] } else { $null }
    $price = if ($winnerStatus) { ConvertTo-RouterInvariantText $Normalized.price.price } else { $null }
    $responseContent = if ($response.status -ceq 'completed') { [string]$response.output } else { $null }
    return [pscustomobject][ordered]@{
        trace_id = $TraceId
        created_at = $CreatedAt
        run_mode = $RunMode
        request_profile = ConvertTo-RouterTraceRequestProfile -Request $Request
        selected_candidate = $selectedIdentity
        output_status = [string]$response.status
        reason_code = if ($response.status -ceq 'completed') { $null } else { [string]$response.reason_code }
        effective_quality = if ($winnerStatus) { [string]$selectedEvaluation.quality.effective_quality } else { $null }
        quality_bottleneck = if ($winnerStatus) { [string]$selectedEvaluation.quality.quality_bottleneck } else { $null }
        price = $price
        price_final = if ($winnerStatus) { [bool]$Normalized.price.price_final } else { $false }
        latency_ms = if ($winnerStatus) { $Normalized.latency_ms } else { $null }
        router_policy_version = if ($null -ne $versionProfile) { [string]$versionProfile.router_policy_version } else { 'deterministic-router-policy/v1' }
        profile_schema_version = if ($null -ne $versionProfile) { [string]$versionProfile.profile_schema_version } else { 'router-model-profile/v1' }
        model_profile_version = if ($null -ne $versionProfile) { [string]$versionProfile.model_profile_version } else { 'unavailable' }
        pricing_snapshot_date = [string]$PricingSnapshot.snapshot_date
        quality_snapshot_date = [string]$QualitySnapshot.snapshot_date
        calibration_set_version = if ($null -ne $versionProfile) { [string]$versionProfile.calibration_set_version } else { 'unavailable' }
        prompt_hash = Get-RouterUtf8Sha256 -Text ([string]$Request.request_text)
        response_hash = $Normalized.response_hash
        prompt_content = if ($RunMode -ceq 'normal') { $null } else { [string]$Request.request_text }
        response_content = if ($RunMode -ceq 'normal') { $null } else { $responseContent }
        candidate_evaluations = $evaluations
    }
}

function Invoke-RouterRun {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][object]$Request,
        [AllowNull()][string]$RequestJson,
        [AllowNull()][object]$Catalog,
        [AllowNull()][object]$Matrix,
        [AllowNull()][object]$PricingSnapshot,
        [AllowNull()][object]$QualitySnapshot,
        [AllowNull()][object]$TokenEstimates,
        [AllowNull()][object[]]$RuntimeStates,
        [AllowNull()][string]$AsOfDate,
        [AllowEmptyString()][string]$ProjectInstructions = '',
        [long]$OutputReserveTokens = 512,
        [long]$LongContextThresholdTokens = 100000,
        [ValidateSet('normal', 'benchmark', 'calibration')][string]$RunMode = 'normal',
        [scriptblock]$Executor,
        [scriptblock]$StorageInvoker,
        [scriptblock]$Clock = { [DateTimeOffset]::UtcNow.ToString('o') },
        [scriptblock]$IdGenerator = { 'route_{0}' -f [guid]::NewGuid().ToString('N') },
        [string]$ProfilesRoot = (Join-Path $script:RouterProjectRoot 'profiles'),
        [string]$MatrixPath = (Join-Path $script:RouterProjectRoot 'pilot/model_matrix.json'),
        [string]$ProfileSchemaPath = (Join-Path $PSScriptRoot 'schemas/model-profile.schema.json'),
        [string]$RequestSchemaPath = (Join-Path $PSScriptRoot 'schemas/request-profile.schema.json'),
        [string]$PricingSnapshotPath = (Join-Path $PSScriptRoot 'data/pricing-snapshot-2026-08-22.json'),
        [string]$QualitySnapshotPath = (Join-Path $PSScriptRoot 'data/quality-snapshot-2026-08-22.json'),
        [string]$DatabasePath = (Join-Path $script:RouterProjectRoot 'data/router.sqlite'),
        [AllowNull()][string]$PythonExecutable
    )

    $requestWasBound = $PSBoundParameters.ContainsKey('Request')
    $jsonWasBound = $PSBoundParameters.ContainsKey('RequestJson')
    if (($requestWasBound -and $jsonWasBound) -or (-not $requestWasBound -and -not $jsonWasBound)) {
        return New-RouterInternalResult `
            -Response (New-RouterFailureResponse -Status 'invalid_request' -ReasonCode 'request_validation_failed') `
            -Trace $null -StorageError $null
    }
    if ($jsonWasBound) {
        try {
            $Request = ConvertFrom-Json -InputObject $RequestJson -Depth 100 -NoEnumerate -ErrorAction Stop
        } catch {
            return New-RouterInternalResult `
                -Response (New-RouterFailureResponse -Status 'invalid_request' -ReasonCode 'request_validation_failed') `
                -Trace $null -StorageError $null
        }
    }

    $requestValidation = Test-RouterSchema -Value $Request -SchemaPath $RequestSchemaPath
    $boundaryOnlyFailure = -not $requestValidation.valid -and
        (Test-RouterBoundaryOnlyValidationFailure -ValidationErrors @($requestValidation.errors))
    if (-not $requestValidation.valid -and -not $boundaryOnlyFailure) {
        return New-RouterInternalResult `
            -Response (Get-RouterRequestFailureResponse -ValidationErrors @($requestValidation.errors)) `
            -Trace $null -StorageError $null
    }
    $normalizedRequest = ConvertTo-RouterNormalizedRequest -Request $Request

    if (-not $PSBoundParameters.ContainsKey('Matrix')) {
        $Matrix = Get-Content -Raw -LiteralPath $MatrixPath | ConvertFrom-Json -Depth 100
    }
    if (-not $PSBoundParameters.ContainsKey('PricingSnapshot')) {
        $PricingSnapshot = Get-Content -Raw -LiteralPath $PricingSnapshotPath | ConvertFrom-Json -Depth 100
    }
    if (-not $PSBoundParameters.ContainsKey('QualitySnapshot')) {
        $QualitySnapshot = Get-Content -Raw -LiteralPath $QualitySnapshotPath | ConvertFrom-Json -Depth 100
    }
    if (-not $PSBoundParameters.ContainsKey('Catalog')) {
        $Catalog = Import-RouterProfileCatalog -ProfilesRoot $ProfilesRoot -MatrixPath $MatrixPath `
            -ProfileSchemaPath $ProfileSchemaPath -PricingSnapshotPath $PricingSnapshotPath `
            -QualitySnapshotPath $QualitySnapshotPath
    }
    $profiles = if ($null -ne $Catalog -and $Catalog.valid) { @($Catalog.profiles) } else { @() }
    if (-not $PSBoundParameters.ContainsKey('TokenEstimates')) {
        $TokenEstimates = New-RouterTokenEstimateDocument -Profiles $profiles
    }
    if ([string]::IsNullOrWhiteSpace($AsOfDate)) { $AsOfDate = [string]$PricingSnapshot.snapshot_date }

    $policyParameters = @{
        Request = $normalizedRequest
        Profiles = $profiles
        RequestSchemaPath = $RequestSchemaPath
        ProjectInstructions = $ProjectInstructions
        OutputReserveTokens = $OutputReserveTokens
        LongContextThresholdTokens = $LongContextThresholdTokens
        PricingSnapshot = $PricingSnapshot
        TokenEstimates = $TokenEstimates
        AsOfDate = $AsOfDate
    }
    if ($PSBoundParameters.ContainsKey('RuntimeStates')) { $policyParameters.RuntimeStates = $RuntimeStates }
    $decision = Invoke-RouterPolicy @policyParameters

    $traceId = [string](& $IdGenerator)
    $execution = $null
    if ($null -ne $decision.selected_candidate) {
        $pilotCandidate = Find-RouterPilotCandidate -SelectedProfile $decision.selected_candidate -Matrix $Matrix
        if ($null -ne $pilotCandidate) {
            try {
                if ($null -ne $Executor) {
                    $execution = & $Executor $pilotCandidate ([string]$normalizedRequest.request_text) $traceId
                } else {
                    $execution = Invoke-PilotCandidate -Candidate $pilotCandidate `
                        -Prompt ([string]$normalizedRequest.request_text) -RunId $traceId
                }
            } catch {
                $execution = [pscustomobject]@{
                    canonical = $null
                    failure = 'execution failure'
                    latency_ms = $null
                    usage = $null
                }
            }
        } else {
            $execution = [pscustomobject]@{
                canonical = $null
                failure = 'execution failure'
                latency_ms = $null
                usage = $null
            }
        }
    }
    $normalized = ConvertTo-RouterNormalizedResult -Decision $decision -Request $normalizedRequest `
        -Execution $execution -PricingSnapshot $PricingSnapshot -AsOfDate $AsOfDate

    $trace = New-RouterDecisionTrace -TraceId $traceId -CreatedAt ([string](& $Clock)) `
        -RunMode $RunMode -Request $normalizedRequest -Decision $decision -Normalized $normalized `
        -Profiles $profiles -PricingSnapshot $PricingSnapshot -QualitySnapshot $QualitySnapshot
    try {
        $storageResult = if ($null -ne $StorageInvoker) {
            & $StorageInvoker $trace
        } else {
            Write-RouterTrace -Trace $trace -DatabasePath $DatabasePath `
                -PythonExecutable $PythonExecutable
        }
    } catch {
        $storageResult = [pscustomobject]@{
            ok = $false
            error = [pscustomobject]@{
                code = 'storage_process_error'
                detail = 'storage_invocation_failed'
                path = '$'
                message = 'Trace storage failed safely.'
            }
        }
    }
    $storageSucceeded = $null -ne $storageResult -and $storageResult.ok -is [bool] -and
        $storageResult.ok -and $storageResult.trace_id -is [string] -and
        $storageResult.trace_id -ceq $traceId
    if ($storageSucceeded) {
        $normalized.response.decision_trace_id = $traceId
        return New-RouterInternalResult -Response $normalized.response -Trace $trace -StorageError $null
    }
    $storageError = if ($null -ne $storageResult -and
        $storageResult.PSObject.Properties.Name -ccontains 'error') {
        $storageResult.error
    } else {
        [pscustomobject]@{
            code = 'storage_protocol_error'
            detail = 'storage_result_invalid'
            path = '$'
            message = 'Trace storage returned an invalid result.'
        }
    }
    return New-RouterInternalResult -Response $normalized.response -Trace $null `
        -StorageError $storageError
}

function Invoke-RouterCli {
    param([AllowNull()][string]$InputFile)

    $stdinJson = if ([Console]::IsInputRedirected) { [Console]::In.ReadToEnd() } else { '' }
    $hasFile = -not [string]::IsNullOrWhiteSpace($InputFile)
    $hasStdin = -not [string]::IsNullOrWhiteSpace($stdinJson)
    if (($hasFile -and $hasStdin) -or (-not $hasFile -and -not $hasStdin)) {
        return New-RouterInternalResult `
            -Response (New-RouterFailureResponse -Status 'invalid_request' -ReasonCode 'request_validation_failed') `
            -Trace $null -StorageError $null
    }
    if ($hasFile) {
        try {
            $requestJson = Get-Content -Raw -LiteralPath $InputFile -ErrorAction Stop
        } catch {
            return New-RouterInternalResult `
                -Response (New-RouterFailureResponse -Status 'invalid_request' -ReasonCode 'request_validation_failed') `
                -Trace $null -StorageError $null
        }
    } else {
        $requestJson = $stdinJson
    }
    return Invoke-RouterRun -RequestJson $requestJson
}

if ($MyInvocation.InvocationName -cne '.') {
    $cliResult = Invoke-RouterCli -InputFile $RequestFile
    [Console]::Out.WriteLine(($cliResult.response | ConvertTo-Json -Depth 100 -Compress))
}
