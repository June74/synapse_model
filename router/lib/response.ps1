. (Join-Path $PSScriptRoot 'pricing.ps1')

function Get-RouterUtf8Sha256 {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function New-RouterFailureResponse {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateSet(
            'invalid_request', 'unsupported_request',
            'no_eligible_configuration', 'execution_failed'
        )][string]$Status,
        [Parameter(Mandatory)][ValidateSet(
            'request_validation_failed', 'unsupported_language', 'unsupported_modality',
            'sensitive_request_unsupported', 'high_stakes_unsupported',
            'context_too_large', 'required_capability_unavailable',
            'quality_floor_not_met', 'quality_evidence_unknown',
            'all_routes_unavailable', 'launcher_execution_failed'
        )][string]$ReasonCode
    )

    return [pscustomobject][ordered]@{
        status = $Status
        reason_code = $ReasonCode
        decision_trace_id = $null
    }
}

function Get-RouterRequestFailureResponse {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ValidationErrors)

    $boundaryCodes = @(
        'unsupported_language'
        'unsupported_modality'
        'sensitive_request_unsupported'
        'high_stakes_unsupported'
    )
    foreach ($code in $boundaryCodes) {
        if (@($ValidationErrors | Where-Object { $_.code -ceq $code }).Count -gt 0) {
            return New-RouterFailureResponse -Status 'unsupported_request' -ReasonCode $code
        }
    }
    return New-RouterFailureResponse -Status 'invalid_request' `
        -ReasonCode 'request_validation_failed'
}

function Get-RouterNoEligibleReasonCode {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$CandidateEvaluations)

    [string[]]$reasons = @(
        foreach ($evaluation in $CandidateEvaluations) {
            @($evaluation.rejection_reason_codes)
        }
    )
    if ($reasons -contains 'context_window_exceeded' -or
        $reasons -contains 'output_window_exceeded') {
        return 'context_too_large'
    }
    foreach ($approved in @(
        'required_capability_unavailable',
        'quality_floor_not_met',
        'quality_evidence_unknown'
    )) {
        if ($reasons -contains $approved) { return $approved }
    }
    return 'all_routes_unavailable'
}

function Get-RouterSelectedEvaluation {
    param([Parameter(Mandatory)][object]$Decision)

    $selected = @($Decision.candidate_evaluations | Where-Object { $_.selected })
    if ($selected.Count -eq 1) { return $selected[0] }
    return $null
}

function ConvertTo-RouterNormalizedResult {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Decision,
        [Parameter(Mandatory)][object]$Request,
        [AllowNull()][object]$Execution,
        [AllowNull()][object]$PricingSnapshot,
        [AllowNull()][string]$AsOfDate
    )

    if (-not $Decision.request_validation.valid) {
        return [pscustomobject][ordered]@{
            response = Get-RouterRequestFailureResponse `
                -ValidationErrors @($Decision.request_validation.errors)
            price = $null
            latency_ms = $null
            response_hash = $null
        }
    }
    if ($null -eq $Decision.selected_candidate) {
        $reason = Get-RouterNoEligibleReasonCode `
            -CandidateEvaluations @($Decision.candidate_evaluations)
        return [pscustomobject][ordered]@{
            response = New-RouterFailureResponse -Status 'no_eligible_configuration' `
                -ReasonCode $reason
            price = $null
            latency_ms = $null
            response_hash = $null
        }
    }

    $latencyMilliseconds = if ($null -ne $Execution -and
        $Execution.PSObject.Properties.Name -ccontains 'latency_ms' -and
        $Execution.latency_ms -is [ValueType] -and [decimal]$Execution.latency_ms -ge 0) {
        [decimal]$Execution.latency_ms
    } else {
        $null
    }
    $canonicalSuccess = $null -ne $Execution -and
        [string]::IsNullOrWhiteSpace([string]$Execution.failure) -and
        $null -ne $Execution.canonical -and
        $Execution.canonical.status -is [string] -and
        $Execution.canonical.status -ceq 'success' -and
        $Execution.canonical.answer -is [string] -and
        -not [string]::IsNullOrWhiteSpace([string]$Execution.canonical.answer)
    if (-not $canonicalSuccess) {
        return [pscustomobject][ordered]@{
            response = New-RouterFailureResponse -Status 'execution_failed' `
                -ReasonCode 'launcher_execution_failed'
            price = (Get-RouterSelectedEvaluation -Decision $Decision).price
            latency_ms = $latencyMilliseconds
            response_hash = $null
        }
    }

    $selectedEvaluation = Get-RouterSelectedEvaluation -Decision $Decision
    $price = $selectedEvaluation.price
    $actualPrice = Get-RouterActualPrice -Candidate $Decision.selected_candidate `
        -Request $Request -PricingSnapshot $PricingSnapshot -Usage $Execution.usage `
        -AsOfDate $AsOfDate
    if ($actualPrice.available -and $actualPrice.price_final) { $price = $actualPrice }

    $answer = [string]$Execution.canonical.answer
    $response = [pscustomobject][ordered]@{
        status = 'completed'
        configuration_id = [string]$Decision.selected_candidate.configuration_id
        provider = [string]$Decision.selected_candidate.provider
        launcher = [string]$Decision.selected_candidate.launcher
        model = [string]$Decision.selected_candidate.model
        effort = [string]$Decision.selected_candidate.effort
        output = $answer
        quality_floor = [string]$Request.quality_floor
        effective_quality = [string]$selectedEvaluation.quality.effective_quality
        quality_bottleneck = [string]$selectedEvaluation.quality.quality_bottleneck
        price = [decimal]$price.price
        price_final = [bool]$price.price_final
        latency = if ($null -eq $latencyMilliseconds) { [decimal]0 } else {
            $latencyMilliseconds / [decimal]1000
        }
        decision_trace_id = $null
    }
    return [pscustomobject][ordered]@{
        response = $response
        price = $price
        latency_ms = if ($null -eq $latencyMilliseconds) { [decimal]0 } else { $latencyMilliseconds }
        response_hash = Get-RouterUtf8Sha256 -Text $answer
    }
}
