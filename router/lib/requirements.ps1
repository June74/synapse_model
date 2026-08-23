. (Join-Path $PSScriptRoot 'schema.ps1')

function Get-RouterContextEstimate {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$PromptText,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ProjectInstructions,
        [Parameter(Mandatory)][long]$OutputReserveTokens
    )

    if ($OutputReserveTokens -lt 0) {
        throw 'OutputReserveTokens must be nonnegative.'
    }

    $composedPrompt = @(
        '=== Project instructions ==='
        $ProjectInstructions
        '=== Request ==='
        $PromptText
    ) -join "`n`n"

    # V1 uses UTF-8 bytes as a deterministic conservative byte-as-token estimate for
    # the fully composed prompt envelope. This is not an exact provider tokenizer result.
    [long]$estimatedPromptTokens = [Text.Encoding]::UTF8.GetByteCount($PromptText)
    [long]$estimatedProjectInstructionTokens = [Text.Encoding]::UTF8.GetByteCount($ProjectInstructions)
    [long]$estimatedInputTokens = [Text.Encoding]::UTF8.GetByteCount($composedPrompt)
    [long]$estimatedFramingTokens = $estimatedInputTokens - $estimatedPromptTokens -
        $estimatedProjectInstructionTokens
    [decimal]$requiredContextTokens = $estimatedInputTokens + $OutputReserveTokens
    if ($requiredContextTokens -gt [long]::MaxValue) {
        throw 'The calculated context requirement exceeds the supported integer range.'
    }

    return [pscustomobject][ordered]@{
        estimated_prompt_tokens = $estimatedPromptTokens
        estimated_project_instruction_tokens = $estimatedProjectInstructionTokens
        estimated_framing_tokens = $estimatedFramingTokens
        estimated_input_tokens = $estimatedInputTokens
        output_reserve_tokens = $OutputReserveTokens
        required_context_tokens = [long]$requiredContextTokens
    }
}

function Get-RouterRequiredCapabilities {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][object]$Request,
        [Parameter(Mandatory)][long]$RequiredContextTokens,
        [Parameter(Mandatory)][long]$LongContextThresholdTokens
    )

    if ($RequiredContextTokens -lt 0) {
        throw 'RequiredContextTokens must be nonnegative.'
    }
    if ($LongContextThresholdTokens -lt 1) {
        throw 'LongContextThresholdTokens must be positive.'
    }

    $required = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $null = $required.Add('instruction_following')

    if ($Request.task_type -ceq 'math' -or $Request.task_type -ceq 'reasoning') {
        $null = $required.Add('reasoning')
    }
    if ($Request.task_type -ceq 'coding' -and $Request.complexity -cin @('medium', 'high')) {
        $null = $required.Add('reasoning')
    }
    if ($Request.task_type -ceq 'extraction') {
        $null = $required.Add('structured_output')
    }
    if ($Request.task_type -ceq 'summarization') {
        $null = $required.Add('factual_reliability')
    }
    if ($Request.task_type -ceq 'research_synthesis') {
        $null = $required.Add('factual_reliability')
        $null = $required.Add('source_grounded_synthesis')
    }
    if ($Request.domain -cne 'general') {
        $null = $required.Add('factual_reliability')
    }
    if ($RequiredContextTokens -gt $LongContextThresholdTokens) {
        $null = $required.Add('long_context')
    }

    $additionalCapabilitiesProperty = $Request.PSObject.Properties |
        Where-Object { $_.Name -ceq 'additional_capabilities' } |
        Select-Object -First 1
    if ($null -ne $additionalCapabilitiesProperty) {
        foreach ($capability in @($additionalCapabilitiesProperty.Value)) {
            $null = $required.Add([string]$capability)
        }
    }

    $canonicalOrder = @(
        'instruction_following'
        'reasoning'
        'structured_output'
        'factual_reliability'
        'source_grounded_synthesis'
        'long_context'
    )
    return @($canonicalOrder | Where-Object { $required.Contains($_) })
}

function Get-RouterRequirements {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Request,
        [Parameter(Mandatory)][string]$RequestSchemaPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ProjectInstructions,
        [Parameter(Mandatory)][long]$OutputReserveTokens,
        [Parameter(Mandatory)][long]$LongContextThresholdTokens
    )

    $validation = Test-RouterSchema -Value $Request -SchemaPath $RequestSchemaPath
    if (-not $validation.valid) {
        return [pscustomobject][ordered]@{
            valid = $false
            errors = @($validation.errors)
            requirements = $null
        }
    }

    $context = Get-RouterContextEstimate -PromptText $Request.request_text `
        -ProjectInstructions $ProjectInstructions -OutputReserveTokens $OutputReserveTokens
    $requiredCapabilities = @(Get-RouterRequiredCapabilities -Request $Request `
        -RequiredContextTokens $context.required_context_tokens `
        -LongContextThresholdTokens $LongContextThresholdTokens)

    return [pscustomobject][ordered]@{
        valid = $true
        errors = @()
        requirements = [pscustomobject][ordered]@{
            input_modalities = @('text')
            output_modalities = @('text')
            language = 'english'
            single_turn = $true
            privacy_level = 'standard'
            risk_level = 'standard'
            task_type = $Request.task_type
            domain = $Request.domain
            complexity = $Request.complexity
            estimated_prompt_tokens = $context.estimated_prompt_tokens
            estimated_project_instruction_tokens = $context.estimated_project_instruction_tokens
            estimated_framing_tokens = $context.estimated_framing_tokens
            estimated_input_tokens = $context.estimated_input_tokens
            output_reserve_tokens = $context.output_reserve_tokens
            required_context_tokens = $context.required_context_tokens
            long_context_threshold_tokens = $LongContextThresholdTokens
            required_capabilities = $requiredCapabilities
        }
    }
}

function Test-RouterRequirementNonnegativeNumber {
    param([AllowNull()][object]$Value)

    if (-not (Test-RouterJsonNumber -Value $Value)) { return $false }
    return $Value -ge 0
}

function Test-RouterCandidatePriceAvailability {
    param([Parameter(Mandatory)][object]$Candidate)

    $pricingProperty = Get-RouterExactProperty -Object $Candidate -Name 'pricing'
    if ($null -eq $pricingProperty) { return $false }

    $costComparableProperty = Get-RouterExactProperty -Object $pricingProperty.Value -Name 'cost_comparable'
    $inputRateProperty = Get-RouterExactProperty -Object $pricingProperty.Value -Name 'input_usd_per_million_tokens'
    $outputRateProperty = Get-RouterExactProperty -Object $pricingProperty.Value -Name 'output_usd_per_million_tokens'
    if (
        $null -eq $costComparableProperty -or
        $costComparableProperty.Value -isnot [bool] -or
        -not $costComparableProperty.Value -or
        $null -eq $inputRateProperty -or
        -not (Test-RouterRequirementNonnegativeNumber -Value $inputRateProperty.Value) -or
        $null -eq $outputRateProperty -or
        -not (Test-RouterRequirementNonnegativeNumber -Value $outputRateProperty.Value)
    ) {
        return $false
    }

    return $true
}

function Test-RouterCandidateRequirements {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Candidate,
        [Parameter(Mandatory)][object]$Requirements,
        [Parameter(Mandatory)][AllowNull()][object]$RuntimeState
    )

    $reasonCodes = [Collections.Generic.List[string]]::new()
    $unavailableCapabilities = [Collections.Generic.List[string]]::new()
    $unsupportedRequirements = [Collections.Generic.List[object]]::new()
    $addReason = {
        param([Parameter(Mandatory)][string]$Code)
        if (-not $reasonCodes.Contains($Code)) {
            $reasonCodes.Add($Code)
        }
    }

    if ($Candidate.enabled -isnot [bool] -or -not $Candidate.enabled) {
        & $addReason 'candidate_disabled'
    }
    if ($Candidate.availability -cne 'available') {
        & $addReason 'candidate_unavailable'
    }
    $runtimeValues = @{}
    $runtimeStateValid = $RuntimeState -is [pscustomobject]
    if ($runtimeStateValid) {
        foreach ($runtimePropertyRequirement in @(
            [pscustomobject]@{ name = 'launcher'; type = 'string' }
            [pscustomobject]@{ name = 'model'; type = 'string' }
            [pscustomobject]@{ name = 'effort'; type = 'string' }
            [pscustomobject]@{ name = 'available'; type = 'boolean' }
            [pscustomobject]@{ name = 'authenticated'; type = 'boolean' }
            [pscustomobject]@{ name = 'working'; type = 'boolean' }
            [pscustomobject]@{ name = 'quota_exhausted'; type = 'boolean' }
        )) {
            $runtimeProperty = Get-RouterExactProperty -Object $RuntimeState `
                -Name $runtimePropertyRequirement.name
            if (
                $null -eq $runtimeProperty -or
                ($runtimePropertyRequirement.type -ceq 'string' -and $runtimeProperty.Value -isnot [string]) -or
                ($runtimePropertyRequirement.type -ceq 'boolean' -and $runtimeProperty.Value -isnot [bool])
            ) {
                $runtimeStateValid = $false
                break
            }
            $runtimeValues[$runtimePropertyRequirement.name] = $runtimeProperty.Value
        }
    }

    if (-not $runtimeStateValid) {
        & $addReason 'runtime_state_invalid'
    } else {
        if (
            -not [string]::Equals($runtimeValues['launcher'], $Candidate.launcher, [StringComparison]::Ordinal) -or
            -not [string]::Equals($runtimeValues['model'], $Candidate.model, [StringComparison]::Ordinal) -or
            -not [string]::Equals($runtimeValues['effort'], $Candidate.effort, [StringComparison]::Ordinal)
        ) {
            & $addReason 'runtime_identity_mismatch'
        }
        if (-not $runtimeValues['available']) {
            & $addReason 'launcher_unavailable'
        }
        if (-not $runtimeValues['authenticated']) {
            & $addReason 'launcher_unauthenticated'
        }
        if (-not $runtimeValues['working']) {
            & $addReason 'launcher_unhealthy'
        }
        if ($runtimeValues['quota_exhausted']) {
            & $addReason 'quota_exhausted'
        }
    }
    if (@($Candidate.supports.input_modalities) -cnotcontains 'text') {
        & $addReason 'text_input_unsupported'
    }
    if (@($Candidate.supports.output_modalities) -cnotcontains 'text') {
        & $addReason 'text_output_unsupported'
    }
    if (@($Candidate.supports.languages) -cnotcontains 'english') {
        & $addReason 'english_unsupported'
    }
    if ($Candidate.supports.single_turn -isnot [bool] -or -not $Candidate.supports.single_turn) {
        & $addReason 'single_turn_unsupported'
    }
    if ($Requirements.required_context_tokens -gt $Candidate.supports.context_window_tokens) {
        & $addReason 'context_window_exceeded'
    }
    if ($Requirements.output_reserve_tokens -gt $Candidate.supports.maximum_output_tokens) {
        & $addReason 'output_window_exceeded'
    }
    if (-not (Test-RouterCandidatePriceAvailability -Candidate $Candidate)) {
        & $addReason 'price_unavailable'
    }

    foreach ($dimension in @(
        [pscustomobject]@{ name = 'task_type'; profile_map = 'task_types'; value = $Requirements.task_type }
        [pscustomobject]@{ name = 'domain'; profile_map = 'domains'; value = $Requirements.domain }
        [pscustomobject]@{ name = 'complexity'; profile_map = 'complexities'; value = $Requirements.complexity }
    )) {
        $property = $Candidate.quality.($dimension.profile_map).PSObject.Properties |
            Where-Object { $_.Name -ceq $dimension.value } |
            Select-Object -First 1
        if ($null -ne $property -and $property.Value -ceq 'unsupported') {
            $unsupportedRequirements.Add([pscustomobject][ordered]@{
                dimension = $dimension.name
                value = $dimension.value
                profile_path = ('quality.{0}.{1}' -f $dimension.profile_map, $dimension.value)
            })
        }
    }
    if ($unsupportedRequirements.Count -gt 0) {
        & $addReason 'required_function_unsupported'
    }

    foreach ($capability in @($Requirements.required_capabilities)) {
        $property = $Candidate.quality.capabilities.PSObject.Properties |
            Where-Object { $_.Name -ceq $capability } |
            Select-Object -First 1
        if ($null -eq $property -or $property.Value -ceq 'unsupported') {
            $unavailableCapabilities.Add([string]$capability)
        }
    }
    if ($unavailableCapabilities.Count -gt 0) {
        & $addReason 'required_capability_unavailable'
    }

    return [pscustomobject][ordered]@{
        candidate_identity = '{0}|{1}' -f $Candidate.launcher, $Candidate.configuration_id
        passed = $reasonCodes.Count -eq 0
        reason_codes = @($reasonCodes)
        unavailable_capabilities = @($unavailableCapabilities)
        unsupported_requirements = @($unsupportedRequirements)
    }
}
