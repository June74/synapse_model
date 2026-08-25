. (Join-Path $PSScriptRoot 'profiles.ps1')

function Get-RouterPricingExactProperty {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    return $Object.PSObject.Properties |
        Where-Object { $_.Name -ceq $Name } |
        Select-Object -First 1
}

function ConvertFrom-RouterPricingIsoDate {
    param([AllowNull()][object]$Value)

    if ($Value -isnot [string]) { return $null }
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParseExact(
        $Value,
        'yyyy-MM-dd',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None,
        [ref]$parsed
    )) {
        return $null
    }
    return $parsed.Date
}

function ConvertTo-RouterPricingDecimal {
    param([AllowNull()][object]$Value)

    return ConvertTo-RouterCatalogExactDecimal -Value $Value
}

function Test-RouterPricingNonnegativeInteger {
    param([AllowNull()][object]$Value)

    $number = ConvertTo-RouterPricingDecimal -Value $Value
    if ($null -eq $number -or $number -lt 0) { return $false }
    return [decimal]::Truncate($number) -eq $number
}

function Test-RouterTokenEstimatesDocument {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()][object]$TokenEstimates)

    $topLevelFields = @('version', 'observations')
    if (-not (Test-RouterCatalogExactProperties -Value $TokenEstimates -ExpectedNames $topLevelFields) -or
        $TokenEstimates.version -isnot [string] -or
        $TokenEstimates.version -cne 'router-token-estimates/v1' -or
        $TokenEstimates.observations -isnot [Collections.IList]) {
        return [pscustomobject]@{ valid = $false; observations = @() }
    }

    $recordFields = @(
        'launcher', 'configuration_id', 'model', 'effort', 'request_profile_group',
        'estimated_input_tokens', 'estimated_visible_output_tokens',
        'estimated_reasoning_tokens', 'observed_on'
    )
    $identities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($observation in @($TokenEstimates.observations)) {
        if (-not (Test-RouterCatalogExactProperties -Value $observation -ExpectedNames $recordFields)) {
            return [pscustomobject]@{ valid = $false; observations = @() }
        }
        foreach ($identityField in @('launcher', 'configuration_id', 'model', 'effort', 'request_profile_group')) {
            $identityValue = $observation.$identityField
            if ($identityValue -isnot [string] -or [string]::IsNullOrWhiteSpace($identityValue)) {
                return [pscustomobject]@{ valid = $false; observations = @() }
            }
        }
        foreach ($tokenField in @(
            'estimated_input_tokens', 'estimated_visible_output_tokens', 'estimated_reasoning_tokens'
        )) {
            if (-not (Test-RouterPricingNonnegativeInteger -Value $observation.$tokenField)) {
                return [pscustomobject]@{ valid = $false; observations = @() }
            }
        }
        if ($null -eq (ConvertFrom-RouterPricingIsoDate -Value $observation.observed_on)) {
            return [pscustomobject]@{ valid = $false; observations = @() }
        }
        $identity = '{0}|{1}|{2}|{3}|{4}' -f
            $observation.launcher, $observation.configuration_id, $observation.model,
            $observation.effort, $observation.request_profile_group
        if (-not $identities.Add($identity)) {
            return [pscustomobject]@{ valid = $false; observations = @() }
        }
    }

    return [pscustomobject]@{ valid = $true; observations = @($TokenEstimates.observations) }
}

function Get-RouterRequestProfileGroup {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Request)

    $values = foreach ($name in @('task_type', 'domain', 'complexity', 'output_length')) {
        $property = Get-RouterPricingExactProperty -Object $Request -Name $name
        if ($null -eq $property -or $property.Value -isnot [string] -or
            [string]::IsNullOrWhiteSpace($property.Value)) {
            return $null
        }
        [string]$property.Value
    }
    return $values -join '|'
}

function New-RouterUnavailablePrice {
    param(
        [Parameter(Mandatory)][string]$CandidateIdentity,
        [AllowNull()][string]$ReasonCode,
        [AllowNull()][string]$RequestProfileGroup
    )

    return [pscustomobject][ordered]@{
        candidate_identity = $CandidateIdentity
        available = $false
        reason_code = $ReasonCode
        request_profile_group = $RequestProfileGroup
        estimated_input_tokens = $null
        estimated_visible_output_tokens = $null
        estimated_reasoning_tokens = $null
        estimated_billable_output_tokens = $null
        input_usd_per_million_tokens = $null
        output_usd_per_million_tokens = $null
        price = $null
        price_final = $false
    }
}

function Get-RouterEstimatedPrice {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Candidate,
        [Parameter(Mandatory)][object]$Request,
        [Parameter(Mandatory)][object]$Requirements,
        [AllowNull()][object]$PricingSnapshot,
        [AllowNull()][object]$TokenEstimates,
        [AllowNull()][string]$AsOfDate
    )

    $useInjectedPricingSnapshot = $PSBoundParameters.ContainsKey('PricingSnapshot')
    $candidateIdentity = '{0}|{1}' -f $Candidate.launcher, $Candidate.configuration_id
    $requestProfileGroup = Get-RouterRequestProfileGroup -Request $Request
    if ($null -eq $requestProfileGroup) {
        return New-RouterUnavailablePrice -CandidateIdentity $candidateIdentity `
            -ReasonCode 'request_profile_group_invalid' -RequestProfileGroup $null
    }
    if (-not $useInjectedPricingSnapshot -or $null -eq $PricingSnapshot) {
        return New-RouterUnavailablePrice -CandidateIdentity $candidateIdentity `
            -ReasonCode 'pricing_snapshot_unavailable' -RequestProfileGroup $requestProfileGroup
    }
    $snapshotValidation = Test-RouterPricingSnapshotObject -PricingSnapshot $PricingSnapshot
    if (-not $snapshotValidation.valid) {
        return New-RouterUnavailablePrice -CandidateIdentity $candidateIdentity `
            -ReasonCode 'pricing_snapshot_invalid' -RequestProfileGroup $requestProfileGroup
    }
    if (-not (Test-RouterProfilePricingSnapshotMatch -Profile $Candidate `
        -PricingSnapshot $PricingSnapshot `
        -PricingByProfileModel $snapshotValidation.pricing_by_profile_model)) {
        return New-RouterUnavailablePrice -CandidateIdentity $candidateIdentity `
            -ReasonCode 'pricing_snapshot_mismatch' -RequestProfileGroup $requestProfileGroup
    }

    $effectiveAsOfDate = $AsOfDate
    if ([string]::IsNullOrWhiteSpace($effectiveAsOfDate)) {
        $effectiveAsOfDate = [string]$PricingSnapshot.snapshot_date
    }
    $asOf = ConvertFrom-RouterPricingIsoDate -Value $effectiveAsOfDate
    if ($null -eq $asOf) {
        return New-RouterUnavailablePrice -CandidateIdentity $candidateIdentity `
            -ReasonCode 'pricing_date_invalid' -RequestProfileGroup $requestProfileGroup
    }

    if (-not $PSBoundParameters.ContainsKey('TokenEstimates') -or $null -eq $TokenEstimates) {
        return New-RouterUnavailablePrice -CandidateIdentity $candidateIdentity `
            -ReasonCode 'token_estimate_unavailable' -RequestProfileGroup $requestProfileGroup
    }
    $tokenEstimateValidation = Test-RouterTokenEstimatesDocument -TokenEstimates $TokenEstimates
    if (-not $tokenEstimateValidation.valid) {
        return New-RouterUnavailablePrice -CandidateIdentity $candidateIdentity `
            -ReasonCode 'token_estimate_invalid' -RequestProfileGroup $requestProfileGroup
    }
    $observationSource = @($tokenEstimateValidation.observations)
    $matchingObservations = @(
        foreach ($observation in $observationSource) {
            if ($observation.launcher -ceq $Candidate.launcher -and
                $observation.configuration_id -ceq $Candidate.configuration_id -and
                $observation.model -ceq $Candidate.model -and
                $observation.effort -ceq $Candidate.effort -and
                $observation.request_profile_group -ceq $requestProfileGroup) {
                $observation
            }
        }
    )
    if ($matchingObservations.Count -ne 1) {
        return New-RouterUnavailablePrice -CandidateIdentity $candidateIdentity `
            -ReasonCode 'token_estimate_unavailable' -RequestProfileGroup $requestProfileGroup
    }
    $observation = $matchingObservations[0]

    $currentInputProperty = Get-RouterPricingExactProperty -Object $Requirements -Name 'estimated_input_tokens'
    $estimatedInputTokens = if ($null -ne $currentInputProperty) {
        if (Test-RouterPricingNonnegativeInteger -Value $currentInputProperty.Value) {
            [decimal]$currentInputProperty.Value
        } else {
            $null
        }
    } elseif (Test-RouterPricingNonnegativeInteger -Value $observation.estimated_input_tokens) {
        [decimal]$observation.estimated_input_tokens
    } else {
        $null
    }
    if ($null -eq $estimatedInputTokens -or
        -not (Test-RouterPricingNonnegativeInteger -Value $observation.estimated_visible_output_tokens) -or
        -not (Test-RouterPricingNonnegativeInteger -Value $observation.estimated_reasoning_tokens)) {
        return New-RouterUnavailablePrice -CandidateIdentity $candidateIdentity `
            -ReasonCode 'token_estimate_invalid' -RequestProfileGroup $requestProfileGroup
    }
    [decimal]$estimatedVisibleOutputTokens = $observation.estimated_visible_output_tokens
    [decimal]$estimatedReasoningTokens = $observation.estimated_reasoning_tokens
    try {
        [decimal]$estimatedBillableOutputTokens = $estimatedVisibleOutputTokens + $estimatedReasoningTokens
    } catch {
        return New-RouterUnavailablePrice -CandidateIdentity $candidateIdentity `
            -ReasonCode 'token_estimate_invalid' -RequestProfileGroup $requestProfileGroup
    }

    $matchingSchedules = @($snapshotValidation.pricing_by_profile_model[[string]$Candidate.model])
    if ($matchingSchedules.Count -ne 1 -or
        $matchingSchedules[0].cost_comparable -isnot [bool] -or
        -not $matchingSchedules[0].cost_comparable) {
        return New-RouterUnavailablePrice -CandidateIdentity $candidateIdentity `
            -ReasonCode 'pricing_schedule_unavailable' -RequestProfileGroup $requestProfileGroup
    }

    $matchingPeriods = @(
        foreach ($period in @($matchingSchedules[0].rate_periods)) {
            if ($null -eq $period -or
                -not (Test-RouterPricingNonnegativeInteger -Value $period.input_tokens_min)) {
                continue
            }
            $from = ConvertFrom-RouterPricingIsoDate -Value $period.effective_from
            $through = if ($null -eq $period.effective_through) {
                $null
            } else {
                ConvertFrom-RouterPricingIsoDate -Value $period.effective_through
            }
            if ($null -eq $from -or ($null -ne $period.effective_through -and $null -eq $through)) {
                continue
            }
            $inputMin = [decimal]$period.input_tokens_min
            $inputMaxValid = $null -eq $period.input_tokens_max -or
                (Test-RouterPricingNonnegativeInteger -Value $period.input_tokens_max)
            if (-not $inputMaxValid) { continue }
            $withinDate = $asOf -ge $from -and ($null -eq $through -or $asOf -le $through)
            $withinTokens = $estimatedInputTokens -ge $inputMin -and
                ($null -eq $period.input_tokens_max -or
                    $estimatedInputTokens -le [decimal]$period.input_tokens_max)
            if ($withinDate -and $withinTokens) { $period }
        }
    )
    if ($matchingPeriods.Count -ne 1) {
        return New-RouterUnavailablePrice -CandidateIdentity $candidateIdentity `
            -ReasonCode 'pricing_period_unavailable' -RequestProfileGroup $requestProfileGroup
    }
    $period = $matchingPeriods[0]
    $inputRate = ConvertTo-RouterPricingDecimal -Value $period.input_usd_per_million_tokens
    $outputRate = ConvertTo-RouterPricingDecimal -Value $period.output_usd_per_million_tokens
    if ($null -eq $inputRate -or $inputRate -lt 0 -or $null -eq $outputRate -or $outputRate -lt 0) {
        return New-RouterUnavailablePrice -CandidateIdentity $candidateIdentity `
            -ReasonCode 'pricing_rate_unavailable' -RequestProfileGroup $requestProfileGroup
    }

    try {
        [decimal]$price = (
            ($estimatedInputTokens * $inputRate) +
            ($estimatedBillableOutputTokens * $outputRate)
        ) / [decimal]1000000
    } catch {
        return New-RouterUnavailablePrice -CandidateIdentity $candidateIdentity `
            -ReasonCode 'price_calculation_unavailable' -RequestProfileGroup $requestProfileGroup
    }
    if ($price -le 0) {
        return New-RouterUnavailablePrice -CandidateIdentity $candidateIdentity `
            -ReasonCode 'free_route_disallowed' -RequestProfileGroup $requestProfileGroup
    }

    return [pscustomobject][ordered]@{
        candidate_identity = $candidateIdentity
        available = $true
        reason_code = $null
        request_profile_group = $requestProfileGroup
        estimated_input_tokens = $estimatedInputTokens
        estimated_visible_output_tokens = $estimatedVisibleOutputTokens
        estimated_reasoning_tokens = $estimatedReasoningTokens
        estimated_billable_output_tokens = $estimatedBillableOutputTokens
        input_usd_per_million_tokens = $inputRate
        output_usd_per_million_tokens = $outputRate
        price = $price
        price_final = $false
    }
}

function Get-RouterActualPrice {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Candidate,
        [Parameter(Mandatory)][object]$Request,
        [AllowNull()][object]$PricingSnapshot,
        [AllowNull()][object]$Usage,
        [AllowNull()][string]$AsOfDate
    )

    $candidateIdentity = '{0}|{1}' -f $Candidate.launcher, $Candidate.configuration_id
    $requestProfileGroup = Get-RouterRequestProfileGroup -Request $Request
    $unavailable = {
        param([string]$ReasonCode)
        New-RouterUnavailablePrice -CandidateIdentity $candidateIdentity `
            -ReasonCode $ReasonCode -RequestProfileGroup $requestProfileGroup
    }
    if ($null -eq $Usage -or -not (Test-RouterCatalogExactProperties -Value $Usage `
        -ExpectedNames @('actual_input_tokens', 'visible_output_tokens', 'reasoning_tokens', 'complete'))) {
        return & $unavailable 'actual_usage_invalid'
    }
    if ($Usage.complete -isnot [bool] -or -not $Usage.complete) {
        return & $unavailable 'actual_usage_incomplete'
    }
    foreach ($name in @('actual_input_tokens', 'visible_output_tokens', 'reasoning_tokens')) {
        if (-not (Test-RouterPricingNonnegativeInteger -Value $Usage.$name)) {
            return & $unavailable 'actual_usage_invalid'
        }
    }

    $actualTokenDocument = [pscustomobject][ordered]@{
        version = 'router-token-estimates/v1'
        observations = @(
            [pscustomobject][ordered]@{
                launcher = [string]$Candidate.launcher
                configuration_id = [string]$Candidate.configuration_id
                model = [string]$Candidate.model
                effort = [string]$Candidate.effort
                request_profile_group = $requestProfileGroup
                estimated_input_tokens = [decimal]$Usage.actual_input_tokens
                estimated_visible_output_tokens = [decimal]$Usage.visible_output_tokens
                estimated_reasoning_tokens = [decimal]$Usage.reasoning_tokens
                observed_on = if ([string]::IsNullOrWhiteSpace($AsOfDate)) {
                    [string]$PricingSnapshot.snapshot_date
                } else {
                    $AsOfDate
                }
            }
        )
    }
    $calculated = Get-RouterEstimatedPrice -Candidate $Candidate -Request $Request `
        -Requirements ([pscustomobject]@{}) -PricingSnapshot $PricingSnapshot `
        -TokenEstimates $actualTokenDocument -AsOfDate $AsOfDate
    if (-not $calculated.available) { return $calculated }

    return [pscustomobject][ordered]@{
        candidate_identity = $candidateIdentity
        available = $true
        reason_code = $null
        request_profile_group = $requestProfileGroup
        actual_input_tokens = [decimal]$Usage.actual_input_tokens
        visible_output_tokens = [decimal]$Usage.visible_output_tokens
        reasoning_tokens = [decimal]$Usage.reasoning_tokens
        billable_output_tokens = [decimal]$Usage.visible_output_tokens + [decimal]$Usage.reasoning_tokens
        input_usd_per_million_tokens = $calculated.input_usd_per_million_tokens
        output_usd_per_million_tokens = $calculated.output_usd_per_million_tokens
        price = $calculated.price
        price_final = $true
    }
}

function ConvertTo-RouterResponsePrice {
    [CmdletBinding()]
    [OutputType([decimal])]
    param(
        [Parameter(Mandatory)][decimal]$Price,
        [ValidateRange(0, 28)][int]$DecimalPlaces = 4
    )

    return [decimal]::Round($Price, $DecimalPlaces, [MidpointRounding]::AwayFromZero)
}
