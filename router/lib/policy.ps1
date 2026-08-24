. (Join-Path $PSScriptRoot 'requirements.ps1')
. (Join-Path $PSScriptRoot 'quality.ps1')
. (Join-Path $PSScriptRoot 'pricing.ps1')

function Get-RouterPolicyIdentity {
    param([Parameter(Mandatory)][object]$Candidate)

    return '{0}|{1}' -f $Candidate.launcher, $Candidate.configuration_id
}

function Sort-RouterPolicyProfilesOrdinal {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Profiles)

    [object[]]$sorted = @($Profiles)
    [Array]::Sort($sorted, [Comparison[object]]{
        param($left, $right)
        return [string]::CompareOrdinal(
            (Get-RouterPolicyIdentity -Candidate $left),
            (Get-RouterPolicyIdentity -Candidate $right)
        )
    })
    return $sorted
}

function New-RouterPolicyEvaluation {
    param([Parameter(Mandatory)][object]$Candidate)

    return [pscustomobject][ordered]@{
        candidate_identity = Get-RouterPolicyIdentity -Candidate $Candidate
        launcher = $Candidate.launcher
        configuration_id = $Candidate.configuration_id
        provider = $Candidate.provider
        model = $Candidate.model
        effort = $Candidate.effort
        eligible = $false
        selected = $false
        rejection_stage = $null
        rejection_reason_codes = @()
        requirements = $null
        quality = $null
        price = $null
        latency_available = $false
        latency_milliseconds = $null
    }
}

function Get-RouterPolicyLatency {
    param([Parameter(Mandatory)][object]$Candidate)

    $latency = Get-RouterPricingExactProperty -Object $Candidate -Name 'latency_observation'
    if ($null -eq $latency -or $latency.Value.available -isnot [bool] -or
        -not $latency.Value.available -or $latency.Value.metric -cne 'end_to_end') {
        return [pscustomobject]@{ available = $false; milliseconds = $null }
    }
    $milliseconds = ConvertTo-RouterPricingDecimal -Value $latency.Value.milliseconds
    if ($null -eq $milliseconds -or $milliseconds -lt 0) {
        return [pscustomobject]@{ available = $false; milliseconds = $null }
    }
    return [pscustomobject]@{ available = $true; milliseconds = $milliseconds }
}

function Get-RouterPolicyRuntimeState {
    param(
        [Parameter(Mandatory)][object]$Candidate,
        [AllowNull()][object[]]$RuntimeStates,
        [Parameter(Mandatory)][bool]$UseInjectedRuntimeStates
    )

    if (-not $UseInjectedRuntimeStates) {
        return [pscustomobject][ordered]@{
            launcher = [string]$Candidate.launcher
            model = [string]$Candidate.model
            effort = [string]$Candidate.effort
            available = $true
            authenticated = $true
            working = $true
            quota_exhausted = $false
        }
    }

    $matches = @(
        foreach ($runtimeState in @($RuntimeStates)) {
            if ($null -eq $runtimeState) { continue }
            $launcher = Get-RouterPricingExactProperty -Object $runtimeState -Name 'launcher'
            $model = Get-RouterPricingExactProperty -Object $runtimeState -Name 'model'
            $effort = Get-RouterPricingExactProperty -Object $runtimeState -Name 'effort'
            if ($null -ne $launcher -and $null -ne $model -and $null -ne $effort -and
                $launcher.Value -ceq $Candidate.launcher -and
                $model.Value -ceq $Candidate.model -and
                $effort.Value -ceq $Candidate.effort) {
                $runtimeState
            }
        }
    )
    if ($matches.Count -ne 1) { return $null }
    return $matches[0]
}

function Invoke-RouterPolicy {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Request,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Profiles,
        [string]$RequestSchemaPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas/request-profile.schema.json'),
        [AllowEmptyString()][string]$ProjectInstructions = '',
        [long]$OutputReserveTokens = 512,
        [long]$LongContextThresholdTokens = 100000,
        [AllowNull()][object]$PricingSnapshot,
        [AllowNull()][object]$TokenEstimates,
        [AllowNull()][string]$AsOfDate,
        [AllowNull()][object[]]$RuntimeStates
    )

    $useInjectedPricing = $PSBoundParameters.ContainsKey('PricingSnapshot')
    $useInjectedTokenEstimates = $PSBoundParameters.ContainsKey('TokenEstimates')
    $useInjectedRuntimeStates = $PSBoundParameters.ContainsKey('RuntimeStates')
    $sortedProfiles = @(Sort-RouterPolicyProfilesOrdinal -Profiles $Profiles)
    $records = [Collections.Generic.List[object]]::new()

    $requirementsResult = Get-RouterRequirements -Request $Request `
        -RequestSchemaPath $RequestSchemaPath -ProjectInstructions $ProjectInstructions `
        -OutputReserveTokens $OutputReserveTokens `
        -LongContextThresholdTokens $LongContextThresholdTokens
    $requestValidation = [pscustomobject][ordered]@{
        valid = $requirementsResult.valid
        errors = @($requirementsResult.errors)
    }

    if (-not $requirementsResult.valid) {
        foreach ($candidate in $sortedProfiles) {
            $evaluation = New-RouterPolicyEvaluation -Candidate $candidate
            $evaluation.rejection_stage = 'request_validation'
            $evaluation.rejection_reason_codes = @('request_validation_failed')
            $records.Add([pscustomobject]@{ candidate = $candidate; evaluation = $evaluation })
        }
        return [pscustomobject][ordered]@{
            request_validation = $requestValidation
            requirements = $null
            selected_candidate = $null
            price = $null
            price_final = $false
            candidate_evaluations = @($records | ForEach-Object { $_.evaluation })
        }
    }

    foreach ($candidate in $sortedProfiles) {
        $evaluation = New-RouterPolicyEvaluation -Candidate $candidate
        $runtimeState = Get-RouterPolicyRuntimeState -Candidate $candidate `
            -RuntimeStates $RuntimeStates -UseInjectedRuntimeStates $useInjectedRuntimeStates
        $requirementEvaluation = Test-RouterCandidateRequirements -Candidate $candidate `
            -Requirements $requirementsResult.requirements -RuntimeState $runtimeState
        $evaluation.requirements = $requirementEvaluation
        if (-not $requirementEvaluation.passed) {
            $evaluation.rejection_stage = 'requirements'
            $evaluation.rejection_reason_codes = @($requirementEvaluation.reason_codes)
            $records.Add([pscustomobject]@{ candidate = $candidate; evaluation = $evaluation })
            continue
        }

        $qualityEvaluation = Test-RouterCandidateQuality -Candidate $candidate -Request $Request `
            -RequiredCapabilities @($requirementsResult.requirements.required_capabilities)
        $evaluation.quality = $qualityEvaluation
        if (-not $qualityEvaluation.passed) {
            $evaluation.rejection_stage = 'quality'
            $evaluation.rejection_reason_codes = @($qualityEvaluation.reason_code)
            $records.Add([pscustomobject]@{ candidate = $candidate; evaluation = $evaluation })
            continue
        }

        $priceParameters = @{
            Candidate = $candidate
            Request = $Request
            Requirements = $requirementsResult.requirements
            AsOfDate = $AsOfDate
        }
        if ($useInjectedPricing) { $priceParameters.PricingSnapshot = $PricingSnapshot }
        if ($useInjectedTokenEstimates) { $priceParameters.TokenEstimates = $TokenEstimates }
        $priceEvaluation = Get-RouterEstimatedPrice @priceParameters
        $evaluation.price = $priceEvaluation
        if (-not $priceEvaluation.available) {
            $evaluation.rejection_stage = 'price'
            $evaluation.rejection_reason_codes = @($priceEvaluation.reason_code)
            $records.Add([pscustomobject]@{ candidate = $candidate; evaluation = $evaluation })
            continue
        }

        $latency = Get-RouterPolicyLatency -Candidate $candidate
        $evaluation.latency_available = $latency.available
        $evaluation.latency_milliseconds = $latency.milliseconds
        $evaluation.eligible = $true
        $records.Add([pscustomobject]@{ candidate = $candidate; evaluation = $evaluation })
    }

    [object[]]$eligibleRecords = @($records | Where-Object { $_.evaluation.eligible })
    [string]$latencyMode = $Request.latency
    [Array]::Sort($eligibleRecords, [Comparison[object]]{
        param($left, $right)

        [decimal]$leftPrice = $left.evaluation.price.price
        [decimal]$rightPrice = $right.evaluation.price.price
        $priceComparison = [decimal]::Compare($leftPrice, $rightPrice)
        if ($priceComparison -ne 0) { return $priceComparison }

        if ($latencyMode -cne 'relaxed') {
            if ($left.evaluation.latency_available -and -not $right.evaluation.latency_available) {
                return -1
            }
            if (-not $left.evaluation.latency_available -and $right.evaluation.latency_available) {
                return 1
            }
            if ($left.evaluation.latency_available -and $right.evaluation.latency_available) {
                [decimal]$leftLatency = $left.evaluation.latency_milliseconds
                [decimal]$rightLatency = $right.evaluation.latency_milliseconds
                $latencyComparison = [decimal]::Compare($leftLatency, $rightLatency)
                if ($latencyComparison -ne 0) { return $latencyComparison }
            }
        }

        return [string]::CompareOrdinal(
            [string]$left.evaluation.candidate_identity,
            [string]$right.evaluation.candidate_identity
        )
    })

    $selectedCandidate = $null
    $selectedPrice = $null
    if ($eligibleRecords.Count -gt 0) {
        $winner = $eligibleRecords[0]
        $winner.evaluation.selected = $true
        $selectedCandidate = $winner.candidate
        $selectedPrice = $winner.evaluation.price.price
    }

    return [pscustomobject][ordered]@{
        request_validation = $requestValidation
        requirements = $requirementsResult.requirements
        selected_candidate = $selectedCandidate
        price = $selectedPrice
        price_final = $false
        candidate_evaluations = @($records | ForEach-Object { $_.evaluation })
    }
}
