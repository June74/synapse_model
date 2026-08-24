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

    if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string]) { return $null }
    if ($Value -is [double] -and ([double]::IsNaN($Value) -or [double]::IsInfinity($Value))) {
        return $null
    }
    if ($Value -is [single] -and ([single]::IsNaN($Value) -or [single]::IsInfinity($Value))) {
        return $null
    }
    try {
        return [decimal]$Value
    } catch {
        return $null
    }
}

function Test-RouterPricingNonnegativeInteger {
    param([AllowNull()][object]$Value)

    $number = ConvertTo-RouterPricingDecimal -Value $Value
    if ($null -eq $number -or $number -lt 0) { return $false }
    return [decimal]::Truncate($number) -eq $number
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
        [AllowNull()][object[]]$TokenEstimates,
        [AllowNull()][string]$AsOfDate
    )

    $useInjectedPricingSnapshot = $PSBoundParameters.ContainsKey('PricingSnapshot')
    $candidateIdentity = '{0}|{1}' -f $Candidate.launcher, $Candidate.configuration_id
    $requestProfileGroup = Get-RouterRequestProfileGroup -Request $Request
    if ($null -eq $requestProfileGroup) {
        return New-RouterUnavailablePrice -CandidateIdentity $candidateIdentity `
            -ReasonCode 'request_profile_group_invalid' -RequestProfileGroup $null
    }

    $effectiveAsOfDate = $AsOfDate
    if ([string]::IsNullOrWhiteSpace($effectiveAsOfDate)) {
        $effectiveAsOfDate = if ($null -ne $PricingSnapshot) {
            [string]$PricingSnapshot.snapshot_date
        } else {
            [string]$Candidate.pricing_snapshot_date
        }
    }
    $asOf = ConvertFrom-RouterPricingIsoDate -Value $effectiveAsOfDate
    if ($null -eq $asOf) {
        return New-RouterUnavailablePrice -CandidateIdentity $candidateIdentity `
            -ReasonCode 'pricing_date_invalid' -RequestProfileGroup $requestProfileGroup
    }

    $useInjectedEstimates = $PSBoundParameters.ContainsKey('TokenEstimates')
    $observationSource = if ($useInjectedEstimates) {
        @($TokenEstimates)
    } else {
        @($Candidate.token_consumption_observations)
    }
    $matchingObservations = @(
        foreach ($observation in $observationSource) {
            if ($null -eq $observation) { continue }
            if ($useInjectedEstimates) {
                $launcher = Get-RouterPricingExactProperty -Object $observation -Name 'launcher'
                $configurationId = Get-RouterPricingExactProperty -Object $observation -Name 'configuration_id'
                if ($null -eq $launcher -or $null -eq $configurationId -or
                    $launcher.Value -isnot [string] -or
                    $configurationId.Value -isnot [string] -or
                    $launcher.Value -cne $Candidate.launcher -or
                    $configurationId.Value -cne $Candidate.configuration_id) {
                    continue
                }
            }
            $model = Get-RouterPricingExactProperty -Object $observation -Name 'model'
            $effort = Get-RouterPricingExactProperty -Object $observation -Name 'effort'
            $group = Get-RouterPricingExactProperty -Object $observation -Name 'request_profile_group'
            if ($null -ne $model -and $null -ne $effort -and $null -ne $group -and
                $model.Value -is [string] -and $effort.Value -is [string] -and
                $group.Value -is [string] -and
                $model.Value -ceq $Candidate.model -and
                $effort.Value -ceq $Candidate.effort -and
                $group.Value -ceq $requestProfileGroup) {
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
    $estimatedInputTokens = if ($null -ne $currentInputProperty -and
        (Test-RouterPricingNonnegativeInteger -Value $currentInputProperty.Value)) {
        [decimal]$currentInputProperty.Value
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

    $matchingSchedules = @()
    if ($useInjectedPricingSnapshot) {
        if ($null -eq $PricingSnapshot -or $PricingSnapshot.schedules -isnot [Collections.IList]) {
            return New-RouterUnavailablePrice -CandidateIdentity $candidateIdentity `
                -ReasonCode 'pricing_snapshot_unavailable' -RequestProfileGroup $requestProfileGroup
        }
        $candidatePricing = Get-RouterPricingExactProperty -Object $Candidate -Name 'pricing'
        if ($null -eq $candidatePricing -or
            $Candidate.pricing_snapshot_date -cne $PricingSnapshot.snapshot_date -or
            $candidatePricing.Value.currency -cne $PricingSnapshot.currency -or
            $candidatePricing.Value.rate_unit -cne $PricingSnapshot.rate_unit) {
            return New-RouterUnavailablePrice -CandidateIdentity $candidateIdentity `
                -ReasonCode 'pricing_snapshot_mismatch' -RequestProfileGroup $requestProfileGroup
        }
        $matchingSchedules = @(
            foreach ($schedule in @($PricingSnapshot.schedules)) {
                if ($null -eq $schedule -or $schedule.provider -cne $Candidate.provider -or
                    $schedule.profile_models -isnot [Collections.IList]) {
                    continue
                }
                if (@($schedule.profile_models | Where-Object { $_ -ceq $Candidate.model }).Count -eq 1) {
                    $schedule
                }
            }
        )
    } else {
        $pricing = Get-RouterPricingExactProperty -Object $Candidate -Name 'pricing'
        if ($null -ne $pricing) {
            $matchingSchedules = @([pscustomobject]@{
                provider = $Candidate.provider
                profile_models = @($Candidate.model)
                cost_comparable = $pricing.Value.cost_comparable
                rate_periods = @([pscustomobject]@{
                    effective_from = $pricing.Value.effective_from
                    effective_through = $pricing.Value.effective_through
                    input_tokens_min = 0
                    input_tokens_max = $null
                    input_usd_per_million_tokens = $pricing.Value.input_usd_per_million_tokens
                    output_usd_per_million_tokens = $pricing.Value.output_usd_per_million_tokens
                })
            })
        }
    }
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

function ConvertTo-RouterResponsePrice {
    [CmdletBinding()]
    [OutputType([decimal])]
    param(
        [Parameter(Mandatory)][decimal]$Price,
        [ValidateRange(0, 28)][int]$DecimalPlaces = 4
    )

    return [decimal]::Round($Price, $DecimalPlaces, [MidpointRounding]::AwayFromZero)
}
