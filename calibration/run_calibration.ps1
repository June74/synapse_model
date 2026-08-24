[CmdletBinding()]
param(
    [switch]$Run,
    [switch]$Route,
    [AllowNull()][string]$RunId,
    [string]$CalibrationSetPath = (Join-Path $PSScriptRoot 'calibration-set-v1.json'),
    [string]$RubricsRoot = (Join-Path $PSScriptRoot 'rubrics'),
    [string]$ResultsRoot = (Join-Path $PSScriptRoot 'results')
)

$ErrorActionPreference = 'Stop'

$script:CalibrationRoot = $PSScriptRoot
$script:CalibrationProjectRoot = Split-Path -Parent $PSScriptRoot
$script:CalibrationResultsRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'results'))
$script:CalibrationRouterPath = Join-Path $script:CalibrationProjectRoot 'router/run_router.ps1'

if (-not (Get-Command Invoke-RouterRun -ErrorAction SilentlyContinue)) {
    . $script:CalibrationRouterPath
}
. (Join-Path $PSScriptRoot 'lib/grading.ps1')

function Test-CalibrationProperty {
    param([AllowNull()][object]$Value, [Parameter(Mandatory)][string]$Name)
    return $null -ne $Value -and $Value.PSObject.Properties.Name -ccontains $Name
}

function Get-CalibrationSha256 {
    param([Parameter(Mandatory)][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    return [Convert]::ToHexString($hash).ToLowerInvariant()
}

function Test-CalibrationPathUnderRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    return $fullPath.StartsWith(($fullRoot + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)
}

function Test-CalibrationSafeLeafName {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or
        $Value -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' -or
        $Value -match '(?i)^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
        return $false
    }
    return $true
}

function Resolve-CalibrationResultPath {
    [CmdletBinding()]
    param(
        [string]$ResultsRoot = $script:CalibrationResultsRoot,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RunId,
        [ValidateSet('review.json', 'route-plan.json')][string]$ArtifactName = 'review.json'
    )

    if (-not (Test-CalibrationSafeLeafName $RunId)) {
        throw 'RunId must contain only a safe, non-path identifier.'
    }
    $resolvedRoot = [IO.Path]::GetFullPath($ResultsRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ($resolvedRoot -cne $script:CalibrationResultsRoot -and
        -not (Test-CalibrationPathUnderRoot -Path $resolvedRoot -Root $script:CalibrationResultsRoot)) {
        throw 'ResultsRoot must remain beneath calibration/results.'
    }
    $runDirectory = [IO.Path]::GetFullPath((Join-Path $resolvedRoot $RunId))
    if (-not (Test-CalibrationPathUnderRoot -Path $runDirectory -Root $resolvedRoot)) {
        throw 'Resolved calibration result escaped the configured results root.'
    }
    return Join-Path $runDirectory $ArtifactName
}

function Test-CalibrationRubric {
    param([AllowNull()][object]$Rubric)
    if ($null -eq $Rubric -or
        -not (Test-CalibrationProperty $Rubric 'id') -or
        -not (Test-CalibrationProperty $Rubric 'version') -or
        -not (Test-CalibrationProperty $Rubric 'criteria') -or
        $Rubric.id -isnot [string] -or [string]::IsNullOrWhiteSpace($Rubric.id) -or
        $Rubric.version -isnot [string] -or [string]::IsNullOrWhiteSpace($Rubric.version) -or
        $Rubric.criteria -isnot [Collections.IList] -or @($Rubric.criteria).Count -eq 0) {
        return $false
    }
    foreach ($criterion in @($Rubric.criteria)) {
        if ($criterion -isnot [string] -or [string]::IsNullOrWhiteSpace($criterion)) { return $false }
    }
    return $true
}

function Test-CalibrationDeterministicGrader {
    param([Parameter(Mandatory)][object]$Prompt)
    $taskType = [string]$Prompt.request.task_type
    $domain = [string]$Prompt.request.domain
    $needsVerifiedAnswer = $taskType -ceq 'math' -or $domain -in @('physics', 'chemistry', 'biology')
    $grader = if (Test-CalibrationProperty $Prompt.grading 'deterministic_grader') {
        $Prompt.grading.deterministic_grader
    } else { $null }

    if ($taskType -ceq 'coding') {
        return $null -ne $grader -and $grader.type -ceq 'executable_tests' -and
            (Test-CalibrationProperty $grader 'tests') -and $grader.tests -is [Collections.IList] -and
            @($grader.tests).Count -gt 0
    }
    if ($needsVerifiedAnswer) {
        return $null -ne $grader -and $grader.type -ceq 'verified_answer' -and
            (Test-CalibrationProperty $grader 'expected_answer') -and
            -not [string]::IsNullOrWhiteSpace([string]$grader.expected_answer) -and
            (Test-CalibrationProperty $grader 'required_reasoning') -and
            $grader.required_reasoning -is [Collections.IList] -and @($grader.required_reasoning).Count -gt 0
    }
    if ($taskType -ceq 'extraction') {
        return $null -ne $grader -and $grader.type -ceq 'exact_fields' -and
            (Test-CalibrationProperty $grader 'expected') -and $null -ne $grader.expected
    }
    if ($taskType -ceq 'summarization') {
        return $null -ne $grader -and $grader.type -ceq 'summary_checks' -and
            (Test-CalibrationProperty $grader 'required_facts') -and
            $grader.required_facts -is [Collections.IList] -and @($grader.required_facts).Count -gt 0 -and
            (Test-CalibrationProperty $grader 'forbidden_claims') -and
            $grader.forbidden_claims -is [Collections.IList]
    }
    return $true
}

function Import-CalibrationSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RubricsRoot
    )

    $errors = [Collections.Generic.List[string]]::new()
    try {
        $setText = Get-Content -Raw -LiteralPath $Path -ErrorAction Stop
        $set = $setText | ConvertFrom-Json -Depth 100 -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ valid = $false; set = $null; errors = @('calibration_set_json_invalid') }
    }
    if (-not (Test-CalibrationProperty $set 'version') -or $set.version -cne 'calibration-set-v1') {
        $errors.Add('calibration_set_version_invalid')
    }
    if (-not (Test-CalibrationProperty $set 'prompts') -or $set.prompts -isnot [Collections.IList]) {
        $errors.Add('calibration_prompts_invalid')
        return [pscustomobject]@{ valid = $false; set = $set; errors = @($errors) }
    }
    $prompts = @($set.prompts)
    if ($prompts.Count -ne 24) { $errors.Add('calibration_prompt_count_invalid') }

    $taskTypes = @('general', 'coding', 'math', 'reasoning', 'writing', 'summarization', 'extraction', 'research_synthesis')
    $complexities = @('low', 'medium', 'high')
    $domains = @('general', 'computer_science', 'mathematics', 'physics', 'chemistry', 'biology', 'medicine', 'engineering', 'social_science', 'humanities', 'business', 'finance', 'law')
    $categories = @('unknown', 'standard', 'strong', 'frontier')
    $seenIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $loadedRubrics = @{}

    foreach ($prompt in $prompts) {
        if ($null -eq $prompt -or
            -not (Test-CalibrationProperty $prompt 'id') -or
            -not (Test-CalibrationProperty $prompt 'version') -or
            -not (Test-CalibrationProperty $prompt 'request') -or
            -not (Test-CalibrationProperty $prompt 'grading') -or
            -not (Test-CalibrationProperty $prompt 'external_category') -or
            -not (Test-CalibrationProperty $prompt 'category_target')) {
            $errors.Add('calibration_prompt_shape_invalid')
            continue
        }
        if ($prompt.id -isnot [string] -or -not (Test-CalibrationSafeLeafName ([string]$prompt.id)) -or
            -not $seenIds.Add([string]$prompt.id)) {
            $errors.Add('calibration_prompt_id_invalid')
        }
        if ($prompt.version -isnot [string] -or [string]::IsNullOrWhiteSpace($prompt.version)) {
            $errors.Add('calibration_prompt_version_invalid')
        }
        $request = $prompt.request
        $requiredRequest = @('request_text', 'task_type', 'domain', 'complexity', 'quality_floor', 'privacy_level', 'risk_level', 'language')
        if (@($requiredRequest | Where-Object { -not (Test-CalibrationProperty $request $_) }).Count -gt 0 -or
            [string]::IsNullOrWhiteSpace([string]$request.request_text) -or
            $request.task_type -cnotin $taskTypes -or $request.domain -cnotin $domains -or
            $request.complexity -cnotin $complexities -or $request.quality_floor -cnotin @('standard', 'strong', 'frontier') -or
            $request.privacy_level -cne 'standard' -or $request.risk_level -cne 'standard' -or
            $request.language -cne 'english') {
            $errors.Add("calibration_request_invalid:$($prompt.id)")
        }
        if ([string]$request.request_text -match '(?i)\b(api[-_ ]?key|password|access[-_ ]?token|authentication code|social security number)\b') {
            $errors.Add("calibration_prompt_sensitive:$($prompt.id)")
        }
        if ($prompt.external_category -cnotin $categories -or [string]::IsNullOrWhiteSpace([string]$prompt.category_target)) {
            $errors.Add("calibration_category_invalid:$($prompt.id)")
        }
        if (-not (Test-CalibrationProperty $prompt.grading 'rubric_ref') -or
            $prompt.grading.rubric_ref -isnot [string] -or
            $prompt.grading.rubric_ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.json$') {
            $errors.Add("calibration_rubric_ref_invalid:$($prompt.id)")
        } else {
            $rubricRef = [string]$prompt.grading.rubric_ref
            $rubricPath = [IO.Path]::GetFullPath((Join-Path $RubricsRoot $rubricRef))
            if (-not (Test-CalibrationPathUnderRoot -Path $rubricPath -Root $RubricsRoot) -or
                -not (Test-Path -LiteralPath $rubricPath -PathType Leaf)) {
                $errors.Add("calibration_rubric_missing:$($prompt.id)")
            } elseif (-not $loadedRubrics.ContainsKey($rubricRef)) {
                try {
                    $rubric = Get-Content -Raw -LiteralPath $rubricPath | ConvertFrom-Json -Depth 100 -ErrorAction Stop
                    if (-not (Test-CalibrationRubric $rubric)) { throw 'invalid rubric' }
                    $loadedRubrics[$rubricRef] = $rubric
                } catch {
                    $errors.Add("calibration_rubric_invalid:$rubricRef")
                }
            }
        }
        if (-not (Test-CalibrationDeterministicGrader -Prompt $prompt)) {
            $errors.Add("calibration_grader_invalid:$($prompt.id)")
        }
    }

    foreach ($taskType in $taskTypes) {
        foreach ($complexity in $complexities) {
            if (@($prompts | Where-Object {
                $_.request.task_type -ceq $taskType -and $_.request.complexity -ceq $complexity
            }).Count -ne 1) { $errors.Add("calibration_coverage_invalid:${taskType}:$complexity") }
        }
    }
    foreach ($domain in $domains) {
        if (@($prompts | Where-Object { $_.request.domain -ceq $domain }).Count -eq 0) {
            $errors.Add("calibration_domain_missing:$domain")
        }
    }
    return [pscustomobject]@{ valid = $errors.Count -eq 0; set = $set; errors = @($errors); rubrics = $loadedRubrics }
}

function Get-CalibrationJudgePair {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('openai', 'gpt-oss', 'anthropic', 'google')][string]$CandidateFamily)
    switch ($CandidateFamily) {
        { $_ -in @('openai', 'gpt-oss') } { return @('claude-opus-5__max', 'gemini-3.7-flash-high__high') }
        'anthropic' { return @('gpt-5.6-sol__max', 'gemini-3.7-flash-high__high') }
        'google' { return @('gpt-5.6-sol__max', 'claude-opus-5__max') }
    }
}

function Get-CalibrationCandidateFamily {
    param([Parameter(Mandatory)][object]$Response)
    if ([string]$Response.model -match '(?i)^gpt-oss') { return 'gpt-oss' }
    switch ([string]$Response.provider) {
        'openai' { return 'openai' }
        'anthropic' { return 'anthropic' }
        'google' { return 'google' }
        default { throw 'Selected response has no supported calibration family.' }
    }
}

function Copy-CalibrationSanitizedValue {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string[]]$ForbiddenValues
    )
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        $text = [string]$Value
        foreach ($forbidden in $ForbiddenValues) {
            if (-not [string]::IsNullOrWhiteSpace($forbidden)) {
                $text = [regex]::Replace($text, [regex]::Escape($forbidden), '[redacted]', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            }
        }
        return $text
    }
    if ($Value -is [Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $Value.Keys) { $copy[[string]$key] = Copy-CalibrationSanitizedValue $Value[$key] $ForbiddenValues }
        return [pscustomobject]$copy
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        return @($Value | ForEach-Object { Copy-CalibrationSanitizedValue $_ $ForbiddenValues })
    }
    if ($Value -is [ValueType]) { return $Value }
    $objectCopy = [ordered]@{}
    foreach ($property in $Value.PSObject.Properties) {
        $objectCopy[$property.Name] = Copy-CalibrationSanitizedValue $property.Value $ForbiddenValues
    }
    return [pscustomobject]$objectCopy
}

function Copy-CalibrationCredentialSafeValue {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return ConvertTo-RunnerCredentialRedactedText -Text ([string]$Value) }
    if ($Value -is [Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $Value.Keys) { $copy[[string]$key] = Copy-CalibrationCredentialSafeValue $Value[$key] }
        return [pscustomobject]$copy
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        return @($Value | ForEach-Object { Copy-CalibrationCredentialSafeValue $_ })
    }
    if ($Value -is [ValueType]) { return $Value }
    $objectCopy = [ordered]@{}
    foreach ($property in $Value.PSObject.Properties) {
        $objectCopy[$property.Name] = Copy-CalibrationCredentialSafeValue $property.Value
    }
    return [pscustomobject]$objectCopy
}

function New-CalibrationJudgePayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Prompt,
        [Parameter(Mandatory)][object]$Rubric,
        [Parameter(Mandatory)][string]$ResponseText,
        [AllowNull()][object]$IdentityMetadata
    )
    $forbiddenValues = @()
    if ($null -ne $IdentityMetadata) {
        $forbiddenValues = @($IdentityMetadata.PSObject.Properties | ForEach-Object { [string]$_.Value } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    }
    $payload = [pscustomobject][ordered]@{
        protocol_version = 'calibration-judge-payload/v1'
        set_version = 'calibration-set-v1'
        item_id = [string]$Prompt.id
        item_version = [string]$Prompt.version
        instruction_text = [string]$Prompt.request.request_text
        response_text = $ResponseText
        evaluation_guide = $Rubric
        required_result = [pscustomobject][ordered]@{
            decision = 'pass or fail'
            rationale = 'brief evidence tied to the evaluation guide'
        }
    }
    return Copy-CalibrationSanitizedValue -Value $payload -ForbiddenValues $forbiddenValues
}

function Get-CalibrationCategoryProposal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('unknown', 'standard', 'strong', 'frontier')][string]$ExternalCategory,
        [Parameter(Mandatory)][object[]]$JudgeDecisions,
        [AllowNull()][object]$DeterministicResult
    )
    if ($JudgeDecisions.Count -ne 2 -or @($JudgeDecisions | Where-Object { $_ -cnotin @('pass', 'fail') }).Count -gt 0) {
        throw 'Exactly two pass/fail judge decisions are required.'
    }
    $deterministicPassed = $null -eq $DeterministicResult -or
        ((Test-CalibrationProperty $DeterministicResult 'outcome') -and $DeterministicResult.outcome -ceq 'pass')
    if ($JudgeDecisions[0] -ceq 'pass' -and $JudgeDecisions[1] -ceq 'pass' -and $deterministicPassed) {
        return [pscustomobject][ordered]@{ outcome = 'retained'; proposed_category = $ExternalCategory }
    }
    return [pscustomobject][ordered]@{ outcome = 'review_required'; proposed_category = 'unknown' }
}

function Get-CalibrationProfileAndCandidate {
    param([Parameter(Mandatory)][string]$ConfigurationId)
    $profileFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:CalibrationProjectRoot 'profiles') -Filter '*.json' -File -Recurse |
        Where-Object { $_.BaseName -ceq $ConfigurationId })
    if ($profileFiles.Count -ne 1) { throw "Judge profile '$ConfigurationId' was not found exactly once." }
    $profile = Get-Content -Raw -LiteralPath $profileFiles[0].FullName | ConvertFrom-Json -Depth 100 -ErrorAction Stop
    $matrix = Get-Content -Raw -LiteralPath (Join-Path $script:CalibrationProjectRoot 'pilot/model_matrix.json') |
        ConvertFrom-Json -Depth 100 -ErrorAction Stop
    $candidate = Find-RouterPilotCandidate -SelectedProfile $profile -Matrix $matrix
    if ($null -eq $candidate) { throw "Judge profile '$ConfigurationId' has no exact pilot candidate." }
    return [pscustomobject]@{ profile = $profile; candidate = $candidate }
}

function Invoke-CalibrationDefaultRouter {
    param([Parameter(Mandatory)][object]$Request, [Parameter(Mandatory)][object]$PromptDefinition)
    return Invoke-RouterRun -Request $Request -RunMode calibration
}

function New-CalibrationRouteContext {
    $profilesRoot = Join-Path $script:CalibrationProjectRoot 'profiles'
    $matrixPath = Join-Path $script:CalibrationProjectRoot 'pilot/model_matrix.json'
    $profileSchemaPath = Join-Path $script:CalibrationProjectRoot 'router/schemas/model-profile.schema.json'
    $requestSchemaPath = Join-Path $script:CalibrationProjectRoot 'router/schemas/request-profile.schema.json'
    $pricingPath = Join-Path $script:CalibrationProjectRoot 'router/data/pricing-snapshot-2026-08-22.json'
    $qualityPath = Join-Path $script:CalibrationProjectRoot 'router/data/quality-snapshot-2026-08-22.json'
    $catalog = Import-RouterProfileCatalog -ProfilesRoot $profilesRoot -MatrixPath $matrixPath `
        -ProfileSchemaPath $profileSchemaPath -PricingSnapshotPath $pricingPath `
        -QualitySnapshotPath $qualityPath
    if (-not $catalog.valid) { throw 'Router profiles are invalid for calibration route-only mode.' }
    $pricing = Get-Content -Raw -LiteralPath $pricingPath -ErrorAction Stop |
        ConvertFrom-Json -Depth 100 -ErrorAction Stop
    return [pscustomobject][ordered]@{
        profiles = @($catalog.profiles)
        pricing_snapshot = $pricing
        token_estimates = New-RouterTokenEstimateDocument -Profiles @($catalog.profiles)
        request_schema_path = $requestSchemaPath
        as_of_date = [string]$pricing.snapshot_date
    }
}

function Invoke-CalibrationDefaultRoute {
    param(
        [Parameter(Mandatory)][object]$Request,
        [Parameter(Mandatory)][object]$PromptDefinition,
        [Parameter(Mandatory)][object]$Context
    )
    $normalized = ConvertTo-RouterNormalizedRequest -Request $Request
    $decision = Invoke-RouterPolicy -Request $normalized -Profiles @($Context.profiles) `
        -RequestSchemaPath ([string]$Context.request_schema_path) `
        -PricingSnapshot $Context.pricing_snapshot -TokenEstimates $Context.token_estimates `
        -AsOfDate ([string]$Context.as_of_date)
    if ($null -eq $decision.selected_candidate) {
        return [pscustomobject][ordered]@{ status = 'no_eligible'; selected_route = $null }
    }
    $selected = $decision.selected_candidate
    return [pscustomobject][ordered]@{
        status = 'selected'
        selected_route = [pscustomobject][ordered]@{
            configuration_id = [string]$selected.configuration_id
            provider = [string]$selected.provider
            launcher = [string]$selected.launcher
            model = [string]$selected.model
            effort = [string]$selected.effort
        }
    }
}

function Invoke-CalibrationDefaultJudge {
    param(
        [Parameter(Mandatory)][string]$JudgeProfileId,
        [Parameter(Mandatory)][object]$JudgePayload,
        [Parameter(Mandatory)][object]$PromptDefinition
    )
    $resolved = Get-CalibrationProfileAndCandidate -ConfigurationId $JudgeProfileId
    $judgePrompt = @"
Evaluate the supplied JSON object. Return only JSON with exactly two fields: decision (pass or fail) and rationale (a short string).
$($JudgePayload | ConvertTo-Json -Depth 100 -Compress)
"@
    $execution = Invoke-PilotCandidate -Candidate $resolved.candidate -Prompt $judgePrompt `
        -RunId ('calibration-judge-{0}' -f [guid]::NewGuid().ToString('N'))
    if ($null -ne $execution.failure -or $null -eq $execution.canonical -or
        $execution.canonical.status -cne 'success') {
        throw "Judge '$JudgeProfileId' execution failed."
    }
    try {
        return ([string]$execution.canonical.answer | ConvertFrom-Json -Depth 20 -ErrorAction Stop)
    } catch {
        throw "Judge '$JudgeProfileId' returned malformed review JSON."
    }
}

function ConvertTo-CalibrationJudgeDecision {
    param([Parameter(Mandatory)][object]$Value, [Parameter(Mandatory)][string]$JudgeProfileId)
    $propertyNames = @($Value.PSObject.Properties.Name)
    if ($propertyNames.Count -ne 2 -or
        $propertyNames -cnotcontains 'decision' -or $propertyNames -cnotcontains 'rationale' -or
        -not (Test-CalibrationProperty $Value 'decision') -or
        $Value.decision -cnotin @('pass', 'fail') -or
        -not (Test-CalibrationProperty $Value 'rationale') -or
        [string]::IsNullOrWhiteSpace([string]$Value.rationale)) {
        throw "Judge '$JudgeProfileId' returned an invalid decision."
    }
    return [pscustomobject][ordered]@{
        judge_profile_id = $JudgeProfileId
        decision = [string]$Value.decision
        rationale = ConvertTo-RunnerCredentialRedactedText -Text ([string]$Value.rationale)
    }
}

function Write-CalibrationJsonFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$Value)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $Value | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

function New-CalibrationRunId {
    return 'cal-{0}-{1}' -f [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ'), [guid]::NewGuid().ToString('N').Substring(0, 8)
}

function Invoke-Calibration {
    [CmdletBinding()]
    param(
        [switch]$Run,
        [switch]$Route,
        [AllowNull()][string]$RunId,
        [string]$CalibrationSetPath = (Join-Path $script:CalibrationRoot 'calibration-set-v1.json'),
        [string]$RubricsRoot = (Join-Path $script:CalibrationRoot 'rubrics'),
        [string]$ResultsRoot = $script:CalibrationResultsRoot,
        [scriptblock]$RouteInvoker,
        [scriptblock]$RouterInvoker,
        [scriptblock]$JudgeInvoker,
        [scriptblock]$PythonExecutor,
        [AllowNull()][string]$PythonExecutable,
        [ValidateRange(100, 10000)][int]$PythonTimeoutMilliseconds = 2000
    )

    if ($Run -and $Route) { throw 'Run and Route are mutually exclusive.' }
    $loaded = Import-CalibrationSet -Path $CalibrationSetPath -RubricsRoot $RubricsRoot
    if (-not $loaded.valid) {
        throw ('Calibration inputs are invalid: {0}' -f (@($loaded.errors) -join ', '))
    }
    $plan = @(
        foreach ($prompt in @($loaded.set.prompts)) {
            [pscustomobject][ordered]@{
                item_id = [string]$prompt.id
                item_version = [string]$prompt.version
                task_type = [string]$prompt.request.task_type
                domain = [string]$prompt.request.domain
                complexity = [string]$prompt.request.complexity
                operation = 'route_execute_then_two_cross_family_reviews'
            }
        }
    )
    $planIdentity = Get-CalibrationSha256 -Text ($plan | ConvertTo-Json -Depth 20 -Compress)
    if (-not $Run -and -not $Route) {
        return [pscustomobject][ordered]@{
            mode = 'dry-run'
            calibration_set_version = [string]$loaded.set.version
            plan_id = $planIdentity
            provider_calls = 0
            plan = $plan
        }
    }

    if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = New-CalibrationRunId }
    $artifactName = if ($Route) { 'route-plan.json' } else { 'review.json' }
    $artifactPath = Resolve-CalibrationResultPath -ResultsRoot $ResultsRoot -RunId $RunId -ArtifactName $artifactName
    $runDirectory = Split-Path -Parent $artifactPath
    if (Test-Path -LiteralPath $runDirectory) {
        throw "Calibration run '$RunId' already exists and will not be overwritten."
    }
    if ($Route) {
        if ($null -eq $RouteInvoker) {
            $routeContext = New-CalibrationRouteContext
            $RouteInvoker = {
                param($Request, $PromptDefinition)
                Invoke-CalibrationDefaultRoute -Request $Request -PromptDefinition $PromptDefinition -Context $routeContext
            }.GetNewClosure()
        }
        $routes = @(
            foreach ($prompt in @($loaded.set.prompts)) {
                $routeResult = & $RouteInvoker $prompt.request $prompt
                if ($null -eq $routeResult -or -not (Test-CalibrationProperty $routeResult 'status') -or
                    $routeResult.status -cnotin @('selected', 'no_eligible') -or
                    ($routeResult.status -ceq 'selected' -and (-not (Test-CalibrationProperty $routeResult 'selected_route') -or
                        $null -eq $routeResult.selected_route))) {
                    throw "Calibration route-only selection failed for '$($prompt.id)'."
                }
                [pscustomobject][ordered]@{
                    item_id = [string]$prompt.id
                    item_version = [string]$prompt.version
                    task_type = [string]$prompt.request.task_type
                    domain = [string]$prompt.request.domain
                    complexity = [string]$prompt.request.complexity
                    status = [string]$routeResult.status
                    selected_route = $routeResult.selected_route
                }
            }
        )
        $artifact = [pscustomobject][ordered]@{
            artifact_version = 'calibration-route-plan/v1'
            calibration_set_version = [string]$loaded.set.version
            run_id = $RunId
            provider_calls = 0
            routes = $routes
        }
        Write-CalibrationJsonFile -Path $artifactPath -Value $artifact
        return [pscustomobject][ordered]@{
            mode = 'route'
            calibration_set_version = [string]$loaded.set.version
            run_id = $RunId
            artifact_path = $artifactPath
            provider_calls = 0
            routes = $routes
        }
    }

    $rawDirectory = Join-Path $runDirectory 'raw'
    if ($null -eq $RouterInvoker) { $RouterInvoker = ${function:Invoke-CalibrationDefaultRouter} }
    if ($null -eq $JudgeInvoker) { $JudgeInvoker = ${function:Invoke-CalibrationDefaultJudge} }
    $reviews = [Collections.Generic.List[object]]::new()

    foreach ($prompt in @($loaded.set.prompts)) {
        $routerResult = & $RouterInvoker $prompt.request $prompt
        if ($null -eq $routerResult -or -not (Test-CalibrationProperty $routerResult 'response') -or
            $null -eq $routerResult.response -or $routerResult.response.status -cne 'completed') {
            throw "Calibration route failed for '$($prompt.id)'."
        }
        $response = $routerResult.response
        $family = Get-CalibrationCandidateFamily -Response $response
        $judgeIds = @(Get-CalibrationJudgePair -CandidateFamily $family)
        $rubric = $loaded.rubrics[[string]$prompt.grading.rubric_ref]
        $identity = [pscustomobject]@{
            model = [string]$response.model
            provider = [string]$response.provider
            family = $family
            tool = [string]$response.launcher
            effort = [string]$response.effort
            price = [string]$response.price
            latency = [string]$response.latency
            profile_id = [string]$response.configuration_id
            candidate_id = [string]$response.configuration_id
        }
        $responseText = ConvertTo-RunnerCredentialRedactedText -Text ([string]$response.output)
        $payload = New-CalibrationJudgePayload -Prompt $prompt -Rubric $rubric `
            -ResponseText $responseText -IdentityMetadata $identity
        $deterministicResult = if (Test-CalibrationProperty $prompt.grading 'deterministic_grader') {
            Invoke-CalibrationDeterministicGrader -Prompt $prompt -ResponseText $responseText `
                -PythonExecutor $PythonExecutor -PythonExecutable $PythonExecutable `
                -PythonTimeoutMilliseconds $PythonTimeoutMilliseconds
        } else { $null }
        $rawJudgeOutputs = [Collections.Generic.List[object]]::new()
        $decisions = @(
            foreach ($judgeId in $judgeIds) {
                $rawDecision = & $JudgeInvoker $judgeId $payload $prompt
                $rawJudgeOutputs.Add([pscustomobject][ordered]@{
                    judge_profile_id = $judgeId
                    raw_output = Copy-CalibrationCredentialSafeValue $rawDecision
                })
                ConvertTo-CalibrationJudgeDecision -Value $rawDecision -JudgeProfileId $judgeId
            }
        )
        $externalCategory = if ((Test-CalibrationProperty $response 'effective_quality') -and
            $response.effective_quality -cin @('unknown', 'standard', 'strong', 'frontier')) {
            [string]$response.effective_quality
        } else { [string]$prompt.external_category }
        $proposal = Get-CalibrationCategoryProposal -ExternalCategory $externalCategory `
            -JudgeDecisions @($decisions.decision) -DeterministicResult $deterministicResult

        $safeItem = [string]$prompt.id
        $candidateOutputPath = Join-Path $rawDirectory ("$safeItem-response.json")
        $judgeOutputPath = Join-Path $rawDirectory ("$safeItem-reviews.json")
        Write-CalibrationJsonFile -Path $candidateOutputPath -Value ([pscustomobject]@{
            item_id = $safeItem; raw_candidate_output = $responseText
        })
        Write-CalibrationJsonFile -Path $judgeOutputPath -Value ([pscustomobject]@{
            item_id = $safeItem
            anonymized_payload = $payload
            raw_judge_outputs = @($rawJudgeOutputs)
            normalized_decisions = $decisions
        })

        $reviews.Add([pscustomobject][ordered]@{
            item_id = $safeItem
            category_target = [string]$prompt.category_target
            external_category = $externalCategory
            outcome = [string]$proposal.outcome
            proposed_category = [string]$proposal.proposed_category
            selected_configuration_id = [string]$response.configuration_id
            deterministic_result = $deterministicResult
            judge_decisions = $decisions
            raw_response_file = [IO.Path]::GetRelativePath($runDirectory, $candidateOutputPath)
            raw_review_file = [IO.Path]::GetRelativePath($runDirectory, $judgeOutputPath)
        })
    }

    $artifact = [pscustomobject][ordered]@{
        artifact_version = 'calibration-review-artifact/v1'
        calibration_set_version = [string]$loaded.set.version
        run_id = $RunId
        policy = 'retain only when every applicable deterministic grader and both judges pass; otherwise propose unknown; never rewrite profiles'
        reviews = @($reviews)
    }
    Write-CalibrationJsonFile -Path $artifactPath -Value $artifact
    return [pscustomobject][ordered]@{
        mode = 'run'
        calibration_set_version = [string]$loaded.set.version
        run_id = $RunId
        artifact_path = $artifactPath
        reviews = @($reviews)
    }
}

if ($MyInvocation.InvocationName -cne '.') {
    try {
        $result = Invoke-Calibration -Run:$Run -Route:$Route -RunId $RunId -CalibrationSetPath $CalibrationSetPath `
            -RubricsRoot $RubricsRoot -ResultsRoot $ResultsRoot
        [Console]::Out.WriteLine(($result | ConvertTo-Json -Depth 100 -Compress))
        exit 0
    } catch {
        [Console]::Out.WriteLine(([pscustomobject][ordered]@{
            mode = if ($Run) { 'run' } elseif ($Route) { 'route' } else { 'dry-run' }
            error = 'calibration_failed'
            message = $_.Exception.Message
        } | ConvertTo-Json -Compress))
        exit 1
    }
}
