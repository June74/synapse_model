[CmdletBinding()]
param(
    [switch]$Run,
    [switch]$Route,
    [switch]$Pilot,
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

function Assert-CalibrationNoReparseComponents {
    param([Parameter(Mandatory)][string]$Path)
    $cursor = [IO.Path]::GetFullPath($Path).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Calibration result paths cannot contain reparse points.'
            }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $cursor) { break }
        $cursor = $parent.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    }
}

function Assert-CalibrationWriteBoundary {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$AllowedRunRoot
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRunRoot = [IO.Path]::GetFullPath($AllowedRunRoot).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (-not (Test-CalibrationPathUnderRoot -Path $fullRunRoot -Root $script:CalibrationResultsRoot) -or
        -not (Test-CalibrationPathUnderRoot -Path $fullPath -Root $fullRunRoot)) {
        throw 'Calibration write path escaped its claimed run directory.'
    }
    Assert-CalibrationNoReparseComponents -Path $fullRunRoot
    Assert-CalibrationNoReparseComponents -Path $fullPath
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
    Assert-CalibrationNoReparseComponents -Path $resolvedRoot
    $runDirectory = [IO.Path]::GetFullPath((Join-Path $resolvedRoot $RunId))
    if (-not (Test-CalibrationPathUnderRoot -Path $runDirectory -Root $resolvedRoot)) {
        throw 'Resolved calibration result escaped the configured results root.'
    }
    return Join-Path $runDirectory $ArtifactName
}

function New-CalibrationRunClaim {
    [CmdletBinding()]
    param(
        [string]$ResultsRoot = $script:CalibrationResultsRoot,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RunId
    )
    $artifactPath = Resolve-CalibrationResultPath -ResultsRoot $ResultsRoot -RunId $RunId
    $runDirectory = Split-Path -Parent $artifactPath
    if (Test-Path -LiteralPath $runDirectory) {
        throw "Calibration run '$RunId' already exists and will not be overwritten."
    }
    $resolvedRoot = Split-Path -Parent $runDirectory
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        Assert-CalibrationNoReparseComponents -Path $resolvedRoot
        New-Item -ItemType Directory -Path $resolvedRoot -Force -ErrorAction Stop | Out-Null
    }
    Assert-CalibrationNoReparseComponents -Path $resolvedRoot
    New-Item -ItemType Directory -Path $runDirectory -ErrorAction Stop | Out-Null
    Assert-CalibrationNoReparseComponents -Path $runDirectory
    $claimPath = Join-Path $runDirectory '.run.claim'
    try {
        $stream = [IO.File]::Open($claimPath, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch {
        throw "Calibration run '$RunId' could not acquire its atomic claim."
    }
    return [pscustomobject][ordered]@{
        run_directory = $runDirectory
        claim_path = $claimPath
        stream = $stream
    }
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

function ConvertTo-CalibrationNormalizedFieldName {
    param([AllowNull()][string]$Name)
    if ($null -eq $Name) { return '' }
    return ([regex]::Replace($Name, '[^A-Za-z0-9]', '')).ToLowerInvariant()
}

function Test-CalibrationIdentityFieldName {
    param([AllowNull()][string]$Name)
    return (ConvertTo-CalibrationNormalizedFieldName $Name) -cin @(
        'model', 'provider', 'family', 'tool', 'launcher', 'effort', 'price', 'latency',
        'profileid', 'candidateid', 'configurationid'
    )
}

function ConvertTo-CalibrationIdentitySafeText {
    param([AllowNull()][string]$Text, [AllowEmptyCollection()][string[]]$ForbiddenValues = @())
    if ($null -eq $Text) { return $null }
    $result = $Text
    $identities = @($ForbiddenValues | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and
        (($_ -match '[A-Za-z]' -and $_.Length -ge 3) -or
            ($_ -match '^\d+(?:\.\d+)?$' -and $_.Length -ge 4))
    } | Sort-Object Length -Descending -Unique)
    foreach ($identity in $identities) {
        if ($result -ceq $identity) { $result = '[identity redacted]'; continue }
        $pattern = '(?<![\p{L}\p{Nd}])' + [regex]::Escape($identity) + '(?![\p{L}\p{Nd}])'
        $result = [regex]::Replace($result, $pattern, '[identity redacted]',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    return $result
}

function Test-CalibrationSensitiveFieldName {
    param([AllowNull()][string]$Name)
    $normalized = ConvertTo-CalibrationNormalizedFieldName $Name
    if ($normalized -cin @('env', 'environment', 'environmentvariables', 'environmentdump')) { return $true }
    return $normalized -match '(?:apikey|token|secret|password|authorization|cookie|credential|authcode|authorizationcode|accesscode|verificationcode|logincode)'
}

function Test-CalibrationEnvironmentFieldName {
    param([AllowNull()][string]$Name)
    return (ConvertTo-CalibrationNormalizedFieldName $Name) -cin @(
        'env', 'environment', 'environmentvariables', 'environmentdump'
    )
}

function ConvertTo-CalibrationCredentialSafeText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return $null }
    $trimmed = $Text.Trim()
    if ($trimmed.StartsWith('{', [StringComparison]::Ordinal) -or
        $trimmed.StartsWith('[', [StringComparison]::Ordinal)) {
        try {
            $jsonValue = $trimmed | ConvertFrom-Json -Depth 100 -ErrorAction Stop
            $safeJsonValue = Copy-CalibrationCredentialSafeValue -Value $jsonValue
            return ($safeJsonValue | ConvertTo-Json -Depth 100 -Compress)
        } catch {
            # Continue with conservative text redaction when the value is not one unambiguous JSON payload.
        }
    }
    $environmentAssignments = @([regex]::Matches(
        $Text,
        '(?m)^\s*(?:\$env:)?[A-Z_][A-Z0-9_]{1,63}\s*=',
        [Text.RegularExpressions.RegexOptions]::Multiline
    ))
    if ($environmentAssignments.Count -ge 3) { return '[environment redacted]' }
    $result = $Text
    $knownEnvironmentPattern = '(?im)(?<prefix>^\s*(?:\$env:)?(?:PATH|USERPROFILE|HOMEPATH|HOME|TEMP|TMP|APPDATA|LOCALAPPDATA|USERNAME|USER|SHELL|COMSPEC|PSMODULEPATH|PATHEXT|PROGRAMFILES(?:\(X86\))?|PROGRAMDATA|WINDIR|SYSTEMROOT|SYSTEMDRIVE|JAVA_HOME|PYTHONPATH|VIRTUAL_ENV|NODE_PATH|NVM_HOME|NVM_SYMLINK|GEM_HOME|GOPATH|CARGO_HOME|RUSTUP_HOME|DOTNET_ROOT)\s*=\s*)(?<value>[^\r\n]*)'
    $result = [regex]::Replace($result, $knownEnvironmentPattern, '${prefix}[environment redacted]',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::Multiline)
    $result = [regex]::Replace($result, '(?i)(\bBearer\s+)[A-Za-z0-9._~+/=-]+', '$1[credential redacted]')
    $result = [regex]::Replace($result, '(?i)(\bBasic\s+)[A-Za-z0-9+/=_-]+', '$1[credential redacted]')
    $result = [regex]::Replace($result, '(?i)\bsk-(?:proj-|ant-)?[A-Za-z0-9_-]{8,}', '[credential redacted]')
    $result = [regex]::Replace($result, '(?i)\bAIza[0-9A-Za-z_-]{8,}', '[credential redacted]')
    $assignmentPattern = '(?im)(?<prefix>(?:["'']|\$env:)?(?:[A-Za-z0-9]+[_-])*(?:api[_-]?key|access[_-]?token|auth(?:entication|orization)?[_-]?(?:token|code)?|token|secret|password|cookie|credential|verification[_-]?code|login[_-]?code)(?:["''])?\s*[:=]\s*(?:["''])?)(?<value>[^"''\s,;}\r\n]+)'
    $result = [regex]::Replace($result, $assignmentPattern, '${prefix}[credential redacted]',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::Multiline)
    return $result
}

function Copy-CalibrationCredentialSafeValue {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return ConvertTo-CalibrationCredentialSafeText -Text ([string]$Value) }
    if ($Value -is [Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $name = [string]$key
            $copy[$name] = if (Test-CalibrationSensitiveFieldName $name) {
                if (Test-CalibrationEnvironmentFieldName $name) { '[environment redacted]' } else { '[credential redacted]' }
            } else { Copy-CalibrationCredentialSafeValue $Value[$key] }
        }
        return [pscustomobject]$copy
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        return @($Value | ForEach-Object { Copy-CalibrationCredentialSafeValue $_ })
    }
    if ($Value -is [ValueType]) { return $Value }
    $objectCopy = [ordered]@{}
    foreach ($property in $Value.PSObject.Properties) {
        $objectCopy[$property.Name] = if (Test-CalibrationSensitiveFieldName $property.Name) {
            if (Test-CalibrationEnvironmentFieldName $property.Name) { '[environment redacted]' } else { '[credential redacted]' }
        } else { Copy-CalibrationCredentialSafeValue $property.Value }
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
        $forbiddenValues = @($IdentityMetadata.PSObject.Properties |
            ForEach-Object { [string]$_.Value } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    }
    $safeInstruction = ConvertTo-CalibrationIdentitySafeText `
        -Text (ConvertTo-CalibrationCredentialSafeText ([string]$Prompt.request.request_text)) `
        -ForbiddenValues $forbiddenValues
    $safeResponse = ConvertTo-CalibrationIdentitySafeText `
        -Text (ConvertTo-CalibrationCredentialSafeText $ResponseText) `
        -ForbiddenValues $forbiddenValues
    $safeCriteria = @($Rubric.criteria | ForEach-Object {
        ConvertTo-CalibrationIdentitySafeText `
            -Text (ConvertTo-CalibrationCredentialSafeText ([string]$_)) `
            -ForbiddenValues $forbiddenValues
    })
    $payload = [pscustomobject][ordered]@{
        protocol_version = 'calibration-judge-payload/v1'
        set_version = 'calibration-set-v1'
        item_id = [string]$Prompt.id
        item_version = [string]$Prompt.version
        instruction_text = $safeInstruction
        response_text = $safeResponse
        evaluation_guide = [pscustomobject][ordered]@{
            id = [string]$Rubric.id
            version = [string]$Rubric.version
            criteria = $safeCriteria
        }
        required_result = [pscustomobject][ordered]@{
            decision = 'pass or fail'
            rationale = 'brief evidence tied to the evaluation guide'
        }
    }
    return $payload
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
    param(
        [Parameter(Mandatory)][string]$ConfigurationId,
        [string]$ProfilesRoot = (Join-Path $script:CalibrationProjectRoot 'profiles'),
        [string]$MatrixPath = (Join-Path $script:CalibrationProjectRoot 'pilot/model_matrix.json')
    )
    $profileFiles = @(Get-ChildItem -LiteralPath $ProfilesRoot -Filter '*.json' -File -Recurse |
        Where-Object { $_.BaseName -ceq $ConfigurationId })
    if ($profileFiles.Count -ne 1) { throw "Judge profile '$ConfigurationId' was not found exactly once." }
    $profileRead = Read-RouterCatalogJson -FilePath $profileFiles[0].FullName
    if (-not $profileRead.valid) { throw "Pilot profile '$ConfigurationId' JSON is invalid at $($profileRead.path)." }
    $profile = $profileRead.value
    if (-not (Test-CalibrationProperty $profile 'enabled') -or $profile.enabled -isnot [bool]) {
        throw "Pilot profile '$ConfigurationId' enabled must be a Boolean."
    }
    $matrixRead = Read-RouterCatalogJson -FilePath $MatrixPath
    if (-not $matrixRead.valid) { throw "Pilot model matrix JSON is invalid at $($matrixRead.path)." }
    $matrix = $matrixRead.value
    $candidate = Find-RouterPilotCandidate -SelectedProfile $profile -Matrix $matrix
    if ($null -eq $candidate) { throw "Judge profile '$ConfigurationId' has no exact pilot candidate." }
    if (-not (Test-CalibrationProperty $candidate 'enabled') -or $candidate.enabled -isnot [bool]) {
        throw "Pilot route selected for '$ConfigurationId' enabled must be a Boolean."
    }
    return [pscustomobject]@{ profile = $profile; candidate = $candidate }
}

function Get-CalibrationFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-CalibrationObjectSha256 {
    param([Parameter(Mandatory)][object]$Value)
    return Get-CalibrationSha256 -Text (ConvertTo-CalibrationCanonicalJson -Value $Value)
}

function ConvertTo-CalibrationCanonicalJson {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [ValueType]) {
        return ($Value | ConvertTo-Json -Compress)
    }
    if ($Value -is [Collections.IDictionary]) {
        $keys = [Collections.Generic.List[string]]::new()
        foreach ($key in $Value.Keys) { $keys.Add([string]$key) }
        $keys.Sort([StringComparer]::Ordinal)
        return '{' + (($keys | ForEach-Object {
            (ConvertTo-CalibrationCanonicalJson -Value $_) + ':' +
            (ConvertTo-CalibrationCanonicalJson -Value $Value[$_])
        }) -join ',') + '}'
    }
    if ($Value -is [Collections.IEnumerable]) {
        return '[' + ((@($Value | ForEach-Object {
            ConvertTo-CalibrationCanonicalJson -Value $_
        }) -join ',')) + ']'
    }
    $names = [Collections.Generic.List[string]]::new()
    foreach ($name in $Value.PSObject.Properties.Name) { $names.Add([string]$name) }
    $names.Sort([StringComparer]::Ordinal)
    return '{' + (($names | ForEach-Object {
        (ConvertTo-CalibrationCanonicalJson -Value $_) + ':' +
        (ConvertTo-CalibrationCanonicalJson -Value $Value.$_)
    }) -join ',') + '}'
}

function Read-CalibrationPilotJsonSnapshot {
    param([Parameter(Mandatory)][string]$Path)

    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        $document = [Text.Json.JsonDocument]::Parse($text)
        try {
            $duplicatePath = @(Find-RouterDuplicateJsonPropertyPath -Element $document.RootElement)
            if ($duplicatePath.Count -gt 0) { throw 'Duplicate JSON property names are not allowed.' }
        } finally { $document.Dispose() }
        $value = $text | ConvertFrom-Json -Depth 100 -ErrorAction Stop
        if ($null -eq $value) { throw 'JSON document is null.' }
        return [pscustomobject][ordered]@{
            path = [IO.Path]::GetFullPath($Path)
            text = $text
            value = $value
            sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        }
    } catch {
        throw "Pilot source is invalid: $Path"
    }
}

function Assert-CalibrationPilotExactValue {
    param([object]$Actual, [object]$Expected, [string]$Name)
    if ($Expected -is [string] -and ($Actual -isnot [string] -or [string]::IsNullOrWhiteSpace($Actual))) {
        throw "Pilot manifest '$Name' must be a nonblank string."
    }
    if ($Expected -is [int] -and -not (Test-RouterCatalogNonnegativeInteger $Actual)) {
        throw "Pilot manifest '$Name' must be a nonnegative integer."
    }
    if ($Expected -is [bool] -and $Actual -isnot [bool]) {
        throw "Pilot manifest '$Name' must be a Boolean."
    }
    if ($Actual -cne $Expected) { throw "Pilot manifest '$Name' differs from the approved contract." }
}

function New-CalibrationPilotSourceBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PilotManifestPath,
        [Parameter(Mandatory)][string]$PilotManifestSchemaPath,
        [Parameter(Mandatory)][string]$CalibrationSetPath,
        [Parameter(Mandatory)][string]$RubricsRoot,
        [string]$MatrixPath = (Join-Path $script:CalibrationProjectRoot 'pilot/model_matrix.json'),
        [string]$ProfilesRoot = (Join-Path $script:CalibrationProjectRoot 'profiles'),
        [string]$ResponseSchemaPath = (Join-Path $script:CalibrationProjectRoot 'pilot/shared/response_schema.json')
    )

    $manifestSource = Read-CalibrationPilotJsonSnapshot -Path $PilotManifestPath
    $manifestSchemaSource = Read-CalibrationPilotJsonSnapshot -Path $PilotManifestSchemaPath
    $matrixSource = Read-CalibrationPilotJsonSnapshot -Path $MatrixPath
    $setSource = Read-CalibrationPilotJsonSnapshot -Path $CalibrationSetPath
    $responseSchemaSource = Read-CalibrationPilotJsonSnapshot -Path $ResponseSchemaPath
    if ($responseSchemaSource.value -isnot [pscustomobject] -or
        @(Get-RouterSchemaStructureErrors -Schema $responseSchemaSource.value).Count -gt 0) {
        throw 'Pilot response schema is invalid.'
    }
    if ($manifestSchemaSource.value -isnot [pscustomobject] -or
        @(Get-RouterSchemaStructureErrors -Schema $manifestSchemaSource.value).Count -gt 0) {
        throw 'Pilot manifest schema is invalid.'
    }
    try {
        $manifestJson = $manifestSource.value | ConvertTo-Json -Depth 100 -Compress -ErrorAction Stop
        if (-not (Test-Json -Json $manifestJson -Schema $manifestSchemaSource.text -ErrorAction Stop)) {
            throw 'schema validation failed'
        }
    } catch { throw 'Pilot manifest schema validation failed.' }

    $set = $setSource.value
    if ($set -isnot [pscustomobject] -or $set.version -isnot [string] -or $set.version -cne 'calibration-set-v1' -or
        $set.prompts -isnot [Collections.IList] -or @($set.prompts).Count -ne 24) {
        throw 'Pilot calibration set validation failed.'
    }
    $rubricSources = @{}
    $seenPromptIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $taskTypes = @('general', 'coding', 'math', 'reasoning', 'writing', 'summarization', 'extraction', 'research_synthesis')
    $complexities = @('low', 'medium', 'high')
    $domains = @('general', 'computer_science', 'mathematics', 'physics', 'chemistry', 'biology', 'medicine', 'engineering', 'social_science', 'humanities', 'business', 'finance', 'law')
    $categories = @('unknown', 'standard', 'strong', 'frontier')
    foreach ($prompt in @($set.prompts)) {
        if ($prompt -isnot [pscustomobject] -or $prompt.id -isnot [string] -or
            -not (Test-CalibrationSafeLeafName $prompt.id) -or -not $seenPromptIds.Add($prompt.id) -or
            $prompt.version -isnot [string] -or [string]::IsNullOrWhiteSpace($prompt.version) -or
            $prompt.request -isnot [pscustomobject] -or $prompt.grading -isnot [pscustomobject]) {
            throw 'Pilot calibration set validation failed.'
        }
        $request = $prompt.request
        $requiredRequest = @('request_text', 'task_type', 'domain', 'complexity', 'quality_floor', 'privacy_level', 'risk_level', 'language')
        if (@($requiredRequest | Where-Object { -not (Test-CalibrationProperty $request $_) }).Count -gt 0 -or
            $request.request_text -isnot [string] -or [string]::IsNullOrWhiteSpace($request.request_text) -or
            $request.task_type -isnot [string] -or $request.task_type -cnotin $taskTypes -or
            $request.domain -isnot [string] -or $request.domain -cnotin $domains -or
            $request.complexity -isnot [string] -or $request.complexity -cnotin $complexities -or
            $request.quality_floor -isnot [string] -or $request.quality_floor -cnotin @('standard', 'strong', 'frontier') -or
            $request.privacy_level -isnot [string] -or $request.privacy_level -cne 'standard' -or
            $request.risk_level -isnot [string] -or $request.risk_level -cne 'standard' -or
            $request.language -isnot [string] -or $request.language -cne 'english' -or
            $prompt.external_category -isnot [string] -or $prompt.external_category -cnotin $categories -or
            $prompt.category_target -isnot [string] -or [string]::IsNullOrWhiteSpace($prompt.category_target) -or
            -not (Test-CalibrationDeterministicGrader -Prompt $prompt)) {
            throw 'Pilot calibration set validation failed.'
        }
        if ($request.request_text -match '(?i)\b(api[-_ ]?key|password|access[-_ ]?token|authentication code|social security number)\b') {
            throw "Pilot calibration set validation failed: calibration_prompt_sensitive:$($prompt.id)"
        }
        if (-not (Test-CalibrationProperty $prompt.grading 'rubric_ref') -or
            $prompt.grading.rubric_ref -isnot [string] -or
            $prompt.grading.rubric_ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.json$') {
            throw "Pilot calibration set validation failed: calibration_rubric_ref_invalid:$($prompt.id)"
        }
        $rubricPath = [IO.Path]::GetFullPath((Join-Path $RubricsRoot $prompt.grading.rubric_ref))
        if (-not (Test-CalibrationPathUnderRoot -Path $rubricPath -Root $RubricsRoot)) {
            throw 'Pilot calibration set validation failed.'
        }
        if (-not $rubricSources.ContainsKey($prompt.grading.rubric_ref)) {
            $rubricSources[$prompt.grading.rubric_ref] = Read-CalibrationPilotJsonSnapshot -Path $rubricPath
        }
    }
    foreach ($rubricSource in $rubricSources.Values) {
        if (-not (Test-CalibrationRubric $rubricSource.value)) { throw 'Pilot calibration set validation failed.' }
    }
    foreach ($taskType in $taskTypes) {
        foreach ($complexity in $complexities) {
            if (@($set.prompts | Where-Object { $_.request.task_type -ceq $taskType -and $_.request.complexity -ceq $complexity }).Count -ne 1) {
                throw 'Pilot calibration set validation failed.'
            }
        }
    }
    foreach ($domain in $domains) {
        if (@($set.prompts | Where-Object { $_.request.domain -ceq $domain }).Count -eq 0) {
            throw 'Pilot calibration set validation failed.'
        }
    }

    $manifest = $manifestSource.value
    $approvedRoles = @(
        [pscustomobject][ordered]@{ ordinal = 1; role = 'candidate'; family = 'google'; launcher = 'agy'; route_id = 'agy__gemini_3_7_flash_low__low'; configuration_id = 'gemini-3.7-flash-low__low'; model = 'gemini-3.7-flash-low'; effort = 'low' }
        [pscustomobject][ordered]@{ ordinal = 2; role = 'judge_1'; family = 'openai'; launcher = 'codex'; route_id = 'codex__gpt_5_6_sol__max'; configuration_id = 'gpt-5.6-sol__max'; model = 'gpt-5.6-sol'; effort = 'max' }
        [pscustomobject][ordered]@{ ordinal = 3; role = 'judge_2'; family = 'anthropic'; launcher = 'claude'; route_id = 'claude__claude_opus_5__max'; configuration_id = 'claude-opus-5__max'; model = 'claude-opus-5'; effort = 'max' }
    )
    foreach ($pair in @(
        @('manifest_version', 'calibration-pilot-manifest/v1'), @('pilot_id', 'option1-three-launch-v1'),
        @('mode', 'option_1_workflow_validation'), @('selection_mode', 'calibration_only_exact_pin'),
        @('deterministic_grader', 'exact_fields'), @('raw_content_policy', 'synthetic_prompt_and_credential_sanitized_outputs_only'),
        @('profile_promotion_allowed', $false)
    )) { Assert-CalibrationPilotExactValue -Actual $manifest.($pair[0]) -Expected $pair[1] -Name $pair[0] }
    Assert-CalibrationPilotExactValue -Actual $manifest.prompt.id -Expected 'extraction-low-general-v1' -Name 'prompt.id'
    Assert-CalibrationPilotExactValue -Actual $manifest.prompt.version -Expected '1.0.0' -Name 'prompt.version'
    Assert-CalibrationPilotExactValue -Actual $manifest.limits.total -Expected 3 -Name 'limits.total'
    foreach ($family in @('google', 'openai', 'anthropic')) {
        Assert-CalibrationPilotExactValue -Actual $manifest.limits.provider_family.$family -Expected 1 -Name "limits.provider_family.$family"
    }
    if (-not (Test-RouterCatalogNonnegativeInteger $manifest.limits.application_retries) -or $manifest.limits.application_retries -cne 0) {
        throw "Pilot manifest 'limits.application_retries' differs from the approved contract."
    }
    if ($manifest.roles -isnot [Collections.IList] -or @($manifest.roles).Count -ne 3 -or
        $matrixSource.value -isnot [pscustomobject] -or $matrixSource.value.candidates -isnot [Collections.IList]) {
        throw 'Pilot manifest source shape is invalid.'
    }

    $profileSources = @{}
    $resolvedRoles = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $approvedRoles.Count; $index++) {
        $role = $manifest.roles[$index]
        $approved = $approvedRoles[$index]
        foreach ($name in @('ordinal', 'role', 'family', 'launcher', 'route_id', 'configuration_id', 'model', 'effort')) {
            Assert-CalibrationPilotExactValue -Actual $role.$name -Expected $approved.$name -Name "roles[$index].$name"
        }
        $candidates = @($matrixSource.value.candidates | Where-Object {
            $_ -is [pscustomobject] -and $_.route_id -is [string] -and $_.route_id -ceq $role.route_id
        })
        if ($candidates.Count -ne 1) { throw "Pilot route '$($role.route_id)' was not found exactly once in the model matrix." }
        $candidate = $candidates[0]
        if (-not (Test-CandidateDefinition $candidate).valid) { throw "Pilot route '$($role.route_id)' is invalid." }
        foreach ($name in @('route_id', 'model', 'effort', 'candidate_kind')) {
            $expected = if ($name -ceq 'candidate_kind') { 'model' } else { $role.$name }
            Assert-CalibrationPilotExactValue -Actual $candidate.$name -Expected $expected -Name "matrix.$name"
        }
        Assert-CalibrationPilotExactValue -Actual $candidate.tool -Expected $role.launcher -Name 'matrix.tool'
        Assert-CalibrationPilotExactValue -Actual $candidate.provider -Expected $role.family -Name 'matrix.provider'
        Assert-CalibrationPilotExactValue -Actual $candidate.enabled -Expected $true -Name 'matrix.enabled'

        $profileFiles = @(Get-ChildItem -LiteralPath $ProfilesRoot -Filter '*.json' -File -Recurse | Where-Object { $_.BaseName -ceq $role.configuration_id })
        if ($profileFiles.Count -ne 1) { throw "Pilot profile '$($role.configuration_id)' was not found exactly once." }
        $profileSource = Read-CalibrationPilotJsonSnapshot -Path $profileFiles[0].FullName
        $profileSources[$role.configuration_id] = $profileSource
        $profile = $profileSource.value
        foreach ($name in @('configuration_id', 'launcher', 'model', 'effort')) {
            Assert-CalibrationPilotExactValue -Actual $profile.$name -Expected $role.$name -Name "profile.$name"
        }
        Assert-CalibrationPilotExactValue -Actual $profile.provider -Expected $role.family -Name 'profile.provider'
        Assert-CalibrationPilotExactValue -Actual $profile.enabled -Expected $true -Name 'profile.enabled'
        $resolvedRoles.Add([pscustomobject][ordered]@{
            ordinal = $role.ordinal; role = $role.role; family = $role.family; launcher = $role.launcher
            route_id = $role.route_id; configuration_id = $role.configuration_id; model = $role.model; effort = $role.effort
            profile = $profile; candidate = $candidate
        }) | Out-Null
    }
    $prompts = @($set.prompts | Where-Object { $_.id -ceq $manifest.prompt.id -and $_.version -ceq $manifest.prompt.version })
    if ($prompts.Count -ne 1 -or $prompts[0].grading.deterministic_grader.type -cne 'exact_fields' -or
        -not $rubricSources.ContainsKey($prompts[0].grading.rubric_ref)) { throw 'Pilot fixed prompt is invalid.' }
    return [pscustomobject][ordered]@{
        manifest = $manifest; calibration_set = $set; prompt = $prompts[0]; rubric = $rubricSources[$prompts[0].grading.rubric_ref].value
        roles = @($resolvedRoles); hashes = [pscustomobject][ordered]@{
            manifest = $manifestSource.sha256; matrix = $matrixSource.sha256; calibration_set = $setSource.sha256
            response_schema = $responseSchemaSource.sha256; candidate_profile = $profileSources[$resolvedRoles[0].configuration_id].sha256
        }
    }
}

function Test-CalibrationPilotManifestObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][string]$SchemaPath,
        [Parameter(Mandatory)][string]$CalibrationSetPath,
        [Parameter(Mandatory)][string]$RubricsRoot,
        [string]$MatrixPath = (Join-Path $script:CalibrationProjectRoot 'pilot/model_matrix.json'),
        [string]$ProfilesRoot = (Join-Path $script:CalibrationProjectRoot 'profiles')
    )

    $schemaValidation = Test-RouterSchema -Value $Manifest -SchemaPath $SchemaPath
    if (-not $schemaValidation.valid) {
        $errors = @($schemaValidation.errors | ForEach-Object { '{0}:{1}' -f $_.code, $_.path })
        throw ('Pilot manifest schema validation failed: ' + ($errors -join ', '))
    }

    $loadedCalibrationSet = Import-CalibrationSet -Path $CalibrationSetPath -RubricsRoot $RubricsRoot
    if (-not $loadedCalibrationSet.valid) {
        throw ('Pilot calibration set validation failed: ' + (@($loadedCalibrationSet.errors) -join ', '))
    }

    $approvedManifest = [pscustomobject][ordered]@{
        manifest_version = 'calibration-pilot-manifest/v1'
        pilot_id = 'option1-three-launch-v1'
        mode = 'option_1_workflow_validation'
        selection_mode = 'calibration_only_exact_pin'
        prompt_id = 'extraction-low-general-v1'
        prompt_version = '1.0.0'
        deterministic_grader = 'exact_fields'
        raw_content_policy = 'synthetic_prompt_and_credential_sanitized_outputs_only'
        profile_promotion_allowed = $false
        total = 3
        google = 1
        openai = 1
        anthropic = 1
        application_retries = 0
        roles = @(
            [pscustomobject][ordered]@{ ordinal = 1; role = 'candidate'; family = 'google'; launcher = 'agy'; route_id = 'agy__gemini_3_7_flash_low__low'; configuration_id = 'gemini-3.7-flash-low__low'; model = 'gemini-3.7-flash-low'; effort = 'low' }
            [pscustomobject][ordered]@{ ordinal = 2; role = 'judge_1'; family = 'openai'; launcher = 'codex'; route_id = 'codex__gpt_5_6_sol__max'; configuration_id = 'gpt-5.6-sol__max'; model = 'gpt-5.6-sol'; effort = 'max' }
            [pscustomobject][ordered]@{ ordinal = 3; role = 'judge_2'; family = 'anthropic'; launcher = 'claude'; route_id = 'claude__claude_opus_5__max'; configuration_id = 'claude-opus-5__max'; model = 'claude-opus-5'; effort = 'max' }
        )
    }

    foreach ($name in @('manifest_version', 'pilot_id', 'mode', 'selection_mode', 'deterministic_grader', 'raw_content_policy', 'profile_promotion_allowed')) {
        Assert-CalibrationPilotExactValue -Actual $Manifest.$name -Expected $approvedManifest.$name -Name $name
    }
    Assert-CalibrationPilotExactValue -Actual $Manifest.prompt.id -Expected $approvedManifest.prompt_id -Name 'prompt.id'
    Assert-CalibrationPilotExactValue -Actual $Manifest.prompt.version -Expected $approvedManifest.prompt_version -Name 'prompt.version'
    foreach ($name in @('total', 'application_retries')) {
        Assert-CalibrationPilotExactValue -Actual $Manifest.limits.$name -Expected $approvedManifest.$name -Name "limits.$name"
    }
    foreach ($family in @('google', 'openai', 'anthropic')) {
        Assert-CalibrationPilotExactValue -Actual $Manifest.limits.provider_family.$family -Expected $approvedManifest.$family -Name "limits.provider_family.$family"
    }

    $manifestRoles = @($Manifest.roles)
    if ($manifestRoles.Count -ne 3) { throw "Pilot manifest 'roles' must contain exactly three entries." }
    $promptMatches = @($loadedCalibrationSet.set.prompts | Where-Object {
        $_.id -ceq $approvedManifest.prompt_id -and $_.version -ceq $approvedManifest.prompt_version
    })
    if ($promptMatches.Count -ne 1) { throw 'Pilot manifest fixed prompt was not found exactly once in the validated calibration set.' }
    $prompt = $promptMatches[0]
    if ($prompt.grading.deterministic_grader.type -cne $approvedManifest.deterministic_grader) {
        throw 'Pilot manifest fixed prompt does not use the approved exact_fields grader.'
    }
    $rubricRef = [string]$prompt.grading.rubric_ref
    if (-not $loadedCalibrationSet.rubrics.ContainsKey($rubricRef)) {
        throw 'Pilot manifest fixed prompt rubric was not loaded from the validated calibration set.'
    }

    $matrixRead = Read-RouterCatalogJson -FilePath $MatrixPath
    if (-not $matrixRead.valid) { throw "Pilot model matrix JSON is invalid at $($matrixRead.path)." }
    $matrix = $matrixRead.value
    $seenRoutes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $seenFamilies = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $seenConfigurations = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $resolvedRoles = [Collections.Generic.List[object]]::new()

    for ($index = 0; $index -lt $approvedManifest.roles.Count; $index++) {
        $role = $manifestRoles[$index]
        $approvedRole = $approvedManifest.roles[$index]
        foreach ($name in @('ordinal', 'role', 'family', 'launcher', 'route_id', 'configuration_id', 'model', 'effort')) {
            Assert-CalibrationPilotExactValue -Actual $role.$name -Expected $approvedRole.$name -Name "roles[$index].$name"
        }
        if (-not $seenRoutes.Add([string]$role.route_id)) { throw 'Pilot manifest contains duplicate route IDs.' }
        if (-not $seenFamilies.Add([string]$role.family)) { throw 'Pilot manifest contains duplicate provider families.' }
        if (-not $seenConfigurations.Add([string]$role.configuration_id)) { throw 'Pilot manifest contains duplicate configuration IDs.' }

        $matrixMatches = @($matrix.candidates | Where-Object { $_.route_id -ceq $role.route_id })
        if ($matrixMatches.Count -ne 1) { throw "Pilot route '$($role.route_id)' was not found exactly once in the model matrix." }
        $matrixCandidate = $matrixMatches[0]
        if (-not (Test-CalibrationProperty $matrixCandidate 'enabled') -or $matrixCandidate.enabled -isnot [bool]) {
            throw "Pilot route '$($role.route_id)' enabled must be a Boolean."
        }
        if ($matrixCandidate.enabled -ne $true) { throw "Pilot route '$($role.route_id)' is disabled." }
        if ($matrixCandidate.candidate_kind -cne 'model') { throw "Pilot route '$($role.route_id)' is not a model candidate." }
        foreach ($field in @('route_id', 'model', 'effort')) {
            Assert-CalibrationPilotExactValue -Actual $matrixCandidate.$field -Expected $role.$field -Name "matrix.$field"
        }
        Assert-CalibrationPilotExactValue -Actual $matrixCandidate.tool -Expected $role.launcher -Name 'matrix.tool'
        Assert-CalibrationPilotExactValue -Actual $matrixCandidate.provider -Expected $role.family -Name 'matrix.provider'

        $resolved = Get-CalibrationProfileAndCandidate -ConfigurationId $role.configuration_id `
            -ProfilesRoot $ProfilesRoot -MatrixPath $MatrixPath
        if (-not (Test-CalibrationProperty $resolved.profile 'enabled') -or $resolved.profile.enabled -isnot [bool]) {
            throw "Pilot profile '$($role.configuration_id)' enabled must be a Boolean."
        }
        if ($matrixCandidate.enabled -ne $resolved.profile.enabled) {
            throw "Pilot route '$($role.route_id)' matrix and profile enabled values disagree."
        }
        if ($resolved.profile.enabled -ne $true) { throw "Pilot profile '$($role.configuration_id)' is disabled." }
        foreach ($field in @('configuration_id', 'launcher', 'model', 'effort')) {
            Assert-CalibrationPilotExactValue -Actual $resolved.profile.$field -Expected $role.$field -Name "profile.$field"
        }
        Assert-CalibrationPilotExactValue -Actual $resolved.profile.provider -Expected $role.family -Name 'profile.provider'
        foreach ($field in @('route_id', 'tool', 'provider', 'model', 'effort', 'candidate_kind', 'enabled')) {
            Assert-CalibrationPilotExactValue -Actual $resolved.candidate.$field -Expected $matrixCandidate.$field -Name "resolved_candidate.$field"
        }
        $resolvedRoles.Add([pscustomobject][ordered]@{
            ordinal = $role.ordinal
            role = $role.role
            family = $role.family
            launcher = $role.launcher
            route_id = $role.route_id
            configuration_id = $role.configuration_id
            model = $role.model
            effort = $role.effort
            profile = $resolved.profile
            candidate = $resolved.candidate
        })
    }

    if ($resolvedRoles[0].family -cne 'google' -or
        $resolvedRoles[1].family -cne 'openai' -or
        $resolvedRoles[2].family -cne 'anthropic') {
        throw 'Pilot manifest must use the approved Google candidate with OpenAI then Anthropic cross-family judges.'
    }

    return [pscustomobject][ordered]@{
        manifest = $Manifest
        calibration_set = $loadedCalibrationSet.set
        prompt = $prompt
        rubric = $loadedCalibrationSet.rubrics[$rubricRef]
        roles = @($resolvedRoles)
    }
}

function Import-CalibrationPilotManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SchemaPath,
        [Parameter(Mandatory)][string]$CalibrationSetPath,
        [Parameter(Mandatory)][string]$RubricsRoot
    )
    $manifestRead = Read-RouterCatalogJson -FilePath $Path
    if (-not $manifestRead.valid) { throw "Pilot manifest JSON is invalid at $($manifestRead.path)." }
    $manifest = $manifestRead.value
    return Test-CalibrationPilotManifestObject -Manifest $manifest -SchemaPath $SchemaPath -CalibrationSetPath $CalibrationSetPath -RubricsRoot $RubricsRoot
}

function New-CalibrationPilotPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$SourceBundle
    )

    $roles = @(
        foreach ($loadedRole in @($SourceBundle.roles)) {
            [pscustomobject][ordered]@{
                ordinal = $loadedRole.ordinal
                role = $loadedRole.role
                family = $loadedRole.family
                launcher = $loadedRole.launcher
                route_id = $loadedRole.route_id
                configuration_id = $loadedRole.configuration_id
                model = $loadedRole.model
                effort = $loadedRole.effort
            }
        }
    )
    $limits = [pscustomobject][ordered]@{
        total = $SourceBundle.manifest.limits.total
        provider_family = [pscustomobject][ordered]@{
            google = $SourceBundle.manifest.limits.provider_family.google
            openai = $SourceBundle.manifest.limits.provider_family.openai
            anthropic = $SourceBundle.manifest.limits.provider_family.anthropic
        }
        application_retries = $SourceBundle.manifest.limits.application_retries
    }
    return [pscustomobject][ordered]@{
        artifact_version = 'calibration-pilot-plan/v1'
        pilot_id = [string]$SourceBundle.manifest.pilot_id
        mode = 'pilot-plan'
        selection_mode = [string]$SourceBundle.manifest.selection_mode
        prompt = [pscustomobject][ordered]@{
            id = [string]$SourceBundle.prompt.id
            version = [string]$SourceBundle.prompt.version
        }
        roles = $roles
        limits = $limits
        source_hashes = [pscustomobject][ordered]@{
            manifest = $SourceBundle.hashes.manifest
            matrix = $SourceBundle.hashes.matrix
            candidate_profile = Get-CalibrationObjectSha256 -Value $SourceBundle.roles[0].profile
            calibration_set = $SourceBundle.hashes.calibration_set
            prompt_definition = Get-CalibrationObjectSha256 -Value $SourceBundle.prompt
            rubric = Get-CalibrationObjectSha256 -Value $SourceBundle.rubric
            response_schema = $SourceBundle.hashes.response_schema
        }
        provider_calls = 0
        provider_side_requests = [pscustomobject][ordered]@{
            observable = $false
            count = $null
        }
        profile_promotion_allowed = $false
        profile_mutated = $false
        production_eligibility_changed = $false
    }
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
        $Value.rationale -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$Value.rationale)) {
        throw "Judge '$JudgeProfileId' returned an invalid decision."
    }
    return [pscustomobject][ordered]@{
        judge_profile_id = $JudgeProfileId
        decision = [string]$Value.decision
        rationale = ConvertTo-CalibrationCredentialSafeText -Text ([string]$Value.rationale)
    }
}

function Write-CalibrationJsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Value,
        [Parameter(Mandatory)][string]$AllowedRunRoot
    )
    Assert-CalibrationWriteBoundary -Path $Path -AllowedRunRoot $AllowedRunRoot
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Assert-CalibrationWriteBoundary -Path $Path -AllowedRunRoot $AllowedRunRoot
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
        [switch]$Pilot,
        [AllowNull()][string]$RunId,
        [string]$CalibrationSetPath = (Join-Path $script:CalibrationRoot 'calibration-set-v1.json'),
        [string]$RubricsRoot = (Join-Path $script:CalibrationRoot 'rubrics'),
        [string]$ResultsRoot = $script:CalibrationResultsRoot,
        [string]$PilotManifestPath = (Join-Path $script:CalibrationRoot 'pilots/option1-three-launch-v1.json'),
        [string]$PilotManifestSchemaPath = (Join-Path $script:CalibrationRoot 'pilots/option1-three-launch-manifest.schema.json'),
        [scriptblock]$CandidateInvoker,
        [scriptblock]$RouteInvoker,
        [scriptblock]$RouterInvoker,
        [scriptblock]$GraderInvoker,
        [scriptblock]$JudgeInvoker,
        [scriptblock]$PythonExecutor,
        [AllowNull()][string]$PythonExecutable,
        [ValidateRange(100, 10000)][int]$PythonTimeoutMilliseconds = 2000
    )

    if ($Run -and $Route) { throw 'Run and Route are mutually exclusive.' }
    if ($Pilot -and $Route) { throw 'Pilot and Route are mutually exclusive.' }
    if ($Pilot -and -not $Run -and -not [string]::IsNullOrWhiteSpace($RunId)) {
        throw 'Pilot RunId requires Run.'
    }
    if ($Pilot) {
        if ($Run) { throw 'pilot_live_not_implemented' }
        $sourceBundle = New-CalibrationPilotSourceBundle -PilotManifestPath $PilotManifestPath `
            -PilotManifestSchemaPath $PilotManifestSchemaPath -CalibrationSetPath $CalibrationSetPath -RubricsRoot $RubricsRoot
        return New-CalibrationPilotPlan -SourceBundle $sourceBundle
    }
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
    $claim = New-CalibrationRunClaim -ResultsRoot $ResultsRoot -RunId $RunId
    $runDirectory = [string]$claim.run_directory
    $reviews = [Collections.Generic.List[object]]::new()
    $routes = [Collections.Generic.List[object]]::new()
    try {
    if ($Route) {
        if ($null -eq $RouteInvoker) {
            $routeContext = New-CalibrationRouteContext
            $RouteInvoker = {
                param($Request, $PromptDefinition)
                Invoke-CalibrationDefaultRoute -Request $Request -PromptDefinition $PromptDefinition -Context $routeContext
            }.GetNewClosure()
        }
        foreach ($prompt in @($loaded.set.prompts)) {
            $routeResult = & $RouteInvoker $prompt.request $prompt
            if ($null -eq $routeResult -or -not (Test-CalibrationProperty $routeResult 'status') -or
                $routeResult.status -cnotin @('selected', 'no_eligible') -or
                ($routeResult.status -ceq 'selected' -and (-not (Test-CalibrationProperty $routeResult 'selected_route') -or
                    $null -eq $routeResult.selected_route))) {
                throw "Calibration route-only selection failed for '$($prompt.id)'."
            }
            $routes.Add([pscustomobject][ordered]@{
                item_id = [string]$prompt.id
                item_version = [string]$prompt.version
                task_type = [string]$prompt.request.task_type
                domain = [string]$prompt.request.domain
                complexity = [string]$prompt.request.complexity
                status = [string]$routeResult.status
                selected_route = $routeResult.selected_route
            }) | Out-Null
        }
        $artifact = [pscustomobject][ordered]@{
            artifact_version = 'calibration-route-plan/v1'
            calibration_set_version = [string]$loaded.set.version
            run_id = $RunId
            provider_calls = 0
            routes = @($routes)
        }
        Write-CalibrationJsonFile -Path $artifactPath -Value $artifact -AllowedRunRoot $runDirectory
        return [pscustomobject][ordered]@{
            mode = 'route'
            calibration_set_version = [string]$loaded.set.version
            run_id = $RunId
            artifact_path = $artifactPath
            provider_calls = 0
            routes = @($routes)
        }
    }

    $rawDirectory = Join-Path $runDirectory 'raw'
    if ($null -eq $RouterInvoker) { $RouterInvoker = ${function:Invoke-CalibrationDefaultRouter} }
    if ($null -eq $GraderInvoker) { $GraderInvoker = ${function:Invoke-CalibrationDeterministicGrader} }
    if ($null -eq $JudgeInvoker) { $JudgeInvoker = ${function:Invoke-CalibrationDefaultJudge} }

    foreach ($prompt in @($loaded.set.prompts)) {
        $safeItem = [string]$prompt.id
        $candidateOutputPath = Join-Path $rawDirectory ("$safeItem-response.json")
        $judgeOutputPath = Join-Path $rawDirectory ("$safeItem-reviews.json")
        $errorCodes = [Collections.Generic.List[string]]::new()
        $rawJudgeOutputs = [Collections.Generic.List[object]]::new()
        $decisions = [Collections.Generic.List[object]]::new()
        $response = $null
        $rawResponseText = $null
        $payload = $null
        $deterministicResult = $null
        $externalCategory = [string]$prompt.external_category
        $selectedConfigurationId = $null

        try {
            $routerResult = & $RouterInvoker $prompt.request $prompt
            if ($null -eq $routerResult -or -not (Test-CalibrationProperty $routerResult 'response') -or
                $null -eq $routerResult.response -or $routerResult.response.status -cne 'completed') {
                throw 'candidate result invalid'
            }
            $response = $routerResult.response
            $rawResponseText = [string]$response.output
            $selectedConfigurationId = [string]$response.configuration_id
            if ((Test-CalibrationProperty $response 'effective_quality') -and
                $response.effective_quality -cin @('unknown', 'standard', 'strong', 'frontier')) {
                $externalCategory = [string]$response.effective_quality
            }
            Write-CalibrationJsonFile -Path $candidateOutputPath -AllowedRunRoot $runDirectory -Value ([pscustomobject][ordered]@{
                item_id = $safeItem
                status = 'completed'
                raw_candidate_output = ConvertTo-CalibrationCredentialSafeText -Text $rawResponseText
                error_code = $null
            })
        } catch {
            $errorCodes.Add('candidate_execution_failed')
            Write-CalibrationJsonFile -Path $candidateOutputPath -AllowedRunRoot $runDirectory -Value ([pscustomobject][ordered]@{
                item_id = $safeItem
                status = 'failed'
                raw_candidate_output = if ($null -eq $rawResponseText) { $null } else { ConvertTo-CalibrationCredentialSafeText $rawResponseText }
                error_code = 'candidate_execution_failed'
            })
        }

        if ($null -ne $response) {
            try {
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
                $payload = New-CalibrationJudgePayload -Prompt $prompt -Rubric $rubric `
                    -ResponseText $rawResponseText -IdentityMetadata $identity
            } catch {
                $errorCodes.Add('judge_payload_failed')
                $judgeIds = @()
            }

            if (Test-CalibrationProperty $prompt.grading 'deterministic_grader') {
                try {
                    $deterministicResult = & $GraderInvoker $prompt $rawResponseText $PythonExecutor `
                        $PythonExecutable $PythonTimeoutMilliseconds
                    if ($null -eq $deterministicResult -or
                        -not (Test-CalibrationProperty $deterministicResult 'outcome') -or
                        $deterministicResult.outcome -cnotin @('pass', 'fail', 'review_required')) {
                        throw 'grader result invalid'
                    }
                } catch {
                    $errorCodes.Add('grader_execution_failed')
                    $deterministicResult = [pscustomobject][ordered]@{
                        type = [string]$prompt.grading.deterministic_grader.type
                        outcome = 'review_required'
                        reason_code = 'grader_execution_failed'
                        checks = @()
                    }
                }
            }

            foreach ($judgeId in @($judgeIds)) {
                $rawDecision = $null
                $rawRecord = $null
                try {
                    $rawDecision = & $JudgeInvoker $judgeId $payload $prompt
                    $rawRecord = [pscustomobject][ordered]@{
                        judge_profile_id = $judgeId
                        status = 'completed'
                        raw_output = Copy-CalibrationCredentialSafeValue $rawDecision
                        error_code = $null
                    }
                    $rawJudgeOutputs.Add($rawRecord)
                    Write-CalibrationJsonFile -Path $judgeOutputPath -AllowedRunRoot $runDirectory -Value ([pscustomobject][ordered]@{
                        item_id = $safeItem
                        anonymized_payload = $payload
                        raw_judge_outputs = @($rawJudgeOutputs)
                        normalized_decisions = @($decisions)
                    })
                    $decisions.Add((ConvertTo-CalibrationJudgeDecision -Value $rawDecision -JudgeProfileId $judgeId))
                } catch {
                    if ($null -eq $rawRecord) {
                        $rawRecord = [pscustomobject][ordered]@{
                            judge_profile_id = $judgeId
                            status = 'failed'
                            raw_output = if ($null -eq $rawDecision) { $null } else { Copy-CalibrationCredentialSafeValue $rawDecision }
                            error_code = 'judge_execution_failed'
                        }
                        $rawJudgeOutputs.Add($rawRecord)
                    } else {
                        $rawRecord.status = 'failed'
                        $rawRecord.error_code = 'judge_execution_failed'
                    }
                    if (-not $errorCodes.Contains('judge_execution_failed')) { $errorCodes.Add('judge_execution_failed') }
                } finally {
                    Write-CalibrationJsonFile -Path $judgeOutputPath -AllowedRunRoot $runDirectory -Value ([pscustomobject][ordered]@{
                        item_id = $safeItem
                        anonymized_payload = $payload
                        raw_judge_outputs = @($rawJudgeOutputs)
                        normalized_decisions = @($decisions)
                    })
                }
            }
        }

        if (-not (Test-Path -LiteralPath $judgeOutputPath -PathType Leaf)) {
            Write-CalibrationJsonFile -Path $judgeOutputPath -AllowedRunRoot $runDirectory -Value ([pscustomobject][ordered]@{
                item_id = $safeItem
                anonymized_payload = $payload
                raw_judge_outputs = @($rawJudgeOutputs)
                normalized_decisions = @($decisions)
            })
        }

        $proposal = if ($errorCodes.Count -eq 0 -and $decisions.Count -eq 2) {
            Get-CalibrationCategoryProposal -ExternalCategory $externalCategory `
                -JudgeDecisions @($decisions.decision) -DeterministicResult $deterministicResult
        } else {
            [pscustomobject][ordered]@{ outcome = 'review_required'; proposed_category = 'unknown' }
        }
        $itemStatus = if ($errorCodes.Count -gt 0) { 'failed' } elseif ($proposal.outcome -ceq 'review_required') {
            'review_required'
        } else { 'completed' }
        $reviews.Add([pscustomobject][ordered]@{
            item_id = $safeItem
            item_status = $itemStatus
            error_codes = @($errorCodes)
            category_target = [string]$prompt.category_target
            external_category = $externalCategory
            outcome = [string]$proposal.outcome
            proposed_category = [string]$proposal.proposed_category
            selected_configuration_id = $selectedConfigurationId
            deterministic_result = $deterministicResult
            judge_decisions = @($decisions)
            raw_response_file = [IO.Path]::GetRelativePath($runDirectory, $candidateOutputPath)
            raw_review_file = [IO.Path]::GetRelativePath($runDirectory, $judgeOutputPath)
        })
    }

    $summary = [pscustomobject][ordered]@{
        total = $reviews.Count
        completed = @($reviews | Where-Object { $_.item_status -ceq 'completed' }).Count
        failed = @($reviews | Where-Object { $_.item_status -ceq 'failed' }).Count
        review_required = @($reviews | Where-Object { $_.item_status -ceq 'review_required' }).Count
    }
    $artifact = [pscustomobject][ordered]@{
        artifact_version = 'calibration-review-artifact/v1'
        calibration_set_version = [string]$loaded.set.version
        run_id = $RunId
        policy = 'retain only when every applicable deterministic grader and both judges pass; otherwise propose unknown; never rewrite profiles'
        summary = $summary
        fatal_error = $null
        reviews = @($reviews)
    }
    Write-CalibrationJsonFile -Path $artifactPath -Value $artifact -AllowedRunRoot $runDirectory
    return [pscustomobject][ordered]@{
        mode = 'run'
        calibration_set_version = [string]$loaded.set.version
        run_id = $RunId
        artifact_path = $artifactPath
        summary = $summary
        reviews = @($reviews)
    }
    } catch {
        if ($Route) {
            $routeFailureArtifact = [pscustomobject][ordered]@{
                artifact_version = 'calibration-route-plan/v1'
                calibration_set_version = [string]$loaded.set.version
                run_id = $RunId
                mode = 'route'
                status = 'failed'
                error = [pscustomobject][ordered]@{ code = 'calibration_route_failed' }
                provider_calls = 0
                completed_count = $routes.Count
                routes = @($routes)
            }
            $safeRouteFailureArtifact = Copy-CalibrationCredentialSafeValue -Value $routeFailureArtifact
            Write-CalibrationJsonFile -Path $artifactPath -Value $safeRouteFailureArtifact -AllowedRunRoot $runDirectory
        } elseif ($Run) {
            $fatalArtifact = [pscustomobject][ordered]@{
                artifact_version = 'calibration-review-artifact/v1'
                calibration_set_version = [string]$loaded.set.version
                run_id = $RunId
                policy = 'retain only when every applicable deterministic grader and both judges pass; otherwise propose unknown; never rewrite profiles'
                summary = [pscustomobject][ordered]@{
                    total = $reviews.Count
                    completed = @($reviews | Where-Object { $_.item_status -ceq 'completed' }).Count
                    failed = @($reviews | Where-Object { $_.item_status -ceq 'failed' }).Count
                    review_required = @($reviews | Where-Object { $_.item_status -ceq 'review_required' }).Count
                }
                fatal_error = [pscustomobject][ordered]@{ code = 'calibration_run_failed' }
                reviews = @($reviews)
            }
            try { Write-CalibrationJsonFile -Path $artifactPath -Value $fatalArtifact -AllowedRunRoot $runDirectory } catch { }
        }
        throw
    } finally {
        if ($null -ne $claim -and $null -ne $claim.stream) { $claim.stream.Dispose() }
    }
}

if ($MyInvocation.InvocationName -cne '.') {
    try {
        $result = Invoke-Calibration -Run:$Run -Route:$Route -Pilot:$Pilot -RunId $RunId -CalibrationSetPath $CalibrationSetPath `
            -RubricsRoot $RubricsRoot -ResultsRoot $ResultsRoot
        [Console]::Out.WriteLine(($result | ConvertTo-Json -Depth 100 -Compress))
        exit 0
    } catch {
        $failure = if ($Pilot) {
            [pscustomobject][ordered]@{
                mode = 'pilot'
                error = 'pilot_failed'
                message = 'pilot_admission_failed'
                code = 'pilot_admission_failed'
            }
        } else {
            [pscustomobject][ordered]@{
                mode = if ($Run) { 'run' } elseif ($Route) { 'route' } else { 'dry-run' }
                error = 'calibration_failed'
                message = $_.Exception.Message
            }
        }
        [Console]::Out.WriteLine(($failure | ConvertTo-Json -Compress))
        exit 1
    }
}
