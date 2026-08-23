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

    # UTF-8 bytes are a deterministic conservative upper bound for tokenizer tokens.
    [long]$estimatedPromptTokens = [Text.Encoding]::UTF8.GetByteCount($PromptText)
    [long]$estimatedProjectInstructionTokens = [Text.Encoding]::UTF8.GetByteCount($ProjectInstructions)
    [decimal]$estimatedInputTokens = [decimal]$estimatedPromptTokens + $estimatedProjectInstructionTokens
    [decimal]$requiredContextTokens = $estimatedInputTokens + $OutputReserveTokens
    if ($requiredContextTokens -gt [long]::MaxValue) {
        throw 'The calculated context requirement exceeds the supported integer range.'
    }

    return [pscustomobject][ordered]@{
        estimated_prompt_tokens = $estimatedPromptTokens
        estimated_project_instruction_tokens = $estimatedProjectInstructionTokens
        estimated_input_tokens = [long]$estimatedInputTokens
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
            estimated_prompt_tokens = $context.estimated_prompt_tokens
            estimated_project_instruction_tokens = $context.estimated_project_instruction_tokens
            estimated_input_tokens = $context.estimated_input_tokens
            output_reserve_tokens = $context.output_reserve_tokens
            required_context_tokens = $context.required_context_tokens
            long_context_threshold_tokens = $LongContextThresholdTokens
            required_capabilities = $requiredCapabilities
        }
    }
}

function Test-RouterCandidateRequirements {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Candidate,
        [Parameter(Mandatory)][object]$Requirements,
        [Parameter(Mandatory)][object]$RuntimeState
    )

    $reasonCodes = [Collections.Generic.List[string]]::new()
    $unavailableCapabilities = [Collections.Generic.List[string]]::new()
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
    if (
        $RuntimeState.launcher -cne $Candidate.launcher -or
        $RuntimeState.model -cne $Candidate.model -or
        $RuntimeState.effort -cne $Candidate.effort
    ) {
        & $addReason 'runtime_identity_mismatch'
    }
    if ($RuntimeState.available -isnot [bool] -or -not $RuntimeState.available) {
        & $addReason 'launcher_unavailable'
    }
    if ($RuntimeState.authenticated -isnot [bool] -or -not $RuntimeState.authenticated) {
        & $addReason 'launcher_unauthenticated'
    }
    if ($RuntimeState.working -isnot [bool] -or -not $RuntimeState.working) {
        & $addReason 'launcher_unhealthy'
    }
    if ($RuntimeState.quota_exhausted -isnot [bool] -or $RuntimeState.quota_exhausted) {
        & $addReason 'quota_exhausted'
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
    }
}
