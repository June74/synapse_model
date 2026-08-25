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
$script:PilotRunTransitions = @{
    planned = @('preflight_passed', 'stopped')
    preflight_passed = @('running', 'stopped')
    running = @('completed', 'stopped', 'indeterminate')
    completed = @()
    stopped = @()
    indeterminate = @()
}
$script:PilotAttemptTransitions = @{
    planned = @('slot_reserved', 'skipped')
    slot_reserved = @('process_started', 'failed')
    process_started = @('succeeded', 'failed')
    succeeded = @()
    failed = @()
    skipped = @()
}
$script:PilotClaimFileNames = @(
    '01-google-candidate.claim',
    '02-openai-judge.claim',
    '03-anthropic-judge.claim'
)

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

function Test-CalibrationSetObject {
    param(
        [AllowNull()][object]$SetValue,
        [Parameter(Mandatory)][hashtable]$RubricEntriesByRef
    )
    $errors = [Collections.Generic.List[string]]::new()
    $set = $SetValue
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
            $entry = if ($RubricEntriesByRef.ContainsKey($rubricRef)) { $RubricEntriesByRef[$rubricRef] } else { $null }
            if ($null -eq $entry -or $entry.status -ceq 'missing') {
                $errors.Add("calibration_rubric_missing:$($prompt.id)")
            } elseif (-not $loadedRubrics.ContainsKey($rubricRef)) {
                if ($entry.status -cne 'valid' -or -not (Test-CalibrationRubric $entry.value)) {
                    $errors.Add("calibration_rubric_invalid:$rubricRef")
                } else { $loadedRubrics[$rubricRef] = $entry.value }
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

function New-CalibrationRubricEntriesFromFiles {
    param([AllowNull()][object]$SetValue, [Parameter(Mandatory)][string]$RubricsRoot)
    $entries = @{}
    if ($null -eq $SetValue -or -not (Test-CalibrationProperty $SetValue 'prompts') -or $SetValue.prompts -isnot [Collections.IList]) { return $entries }
    foreach ($prompt in @($SetValue.prompts)) {
        if ($null -eq $prompt -or -not (Test-CalibrationProperty $prompt 'grading') -or
            -not (Test-CalibrationProperty $prompt.grading 'rubric_ref') -or $prompt.grading.rubric_ref -isnot [string] -or
            $prompt.grading.rubric_ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.json$') { continue }
        $rubricRef = [string]$prompt.grading.rubric_ref
        if ($entries.ContainsKey($rubricRef)) { continue }
        $rubricPath = [IO.Path]::GetFullPath((Join-Path $RubricsRoot $rubricRef))
        if (-not (Test-CalibrationPathUnderRoot -Path $rubricPath -Root $RubricsRoot) -or -not (Test-Path -LiteralPath $rubricPath -PathType Leaf)) {
            $entries[$rubricRef] = [pscustomobject]@{ status = 'missing'; value = $null }
            continue
        }
        try {
            $value = Get-Content -Raw -LiteralPath $rubricPath | ConvertFrom-Json -Depth 100 -ErrorAction Stop
            $entries[$rubricRef] = [pscustomobject]@{ status = 'valid'; value = $value }
        } catch { $entries[$rubricRef] = [pscustomobject]@{ status = 'invalid'; value = $null } }
    }
    return $entries
}

function Import-CalibrationSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RubricsRoot
    )
    try {
        $setText = Get-Content -Raw -LiteralPath $Path -ErrorAction Stop
        $set = $setText | ConvertFrom-Json -Depth 100 -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ valid = $false; set = $null; errors = @('calibration_set_json_invalid') }
    }
    $entries = New-CalibrationRubricEntriesFromFiles -SetValue $set -RubricsRoot $RubricsRoot
    return Test-CalibrationSetObject -SetValue $set -RubricEntriesByRef $entries
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
            bytes = $bytes
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
        [string]$ModelProfileSchemaPath = (Join-Path $script:CalibrationProjectRoot 'router/schemas/model-profile.schema.json'),
        [string]$ResponseSchemaPath = (Join-Path $script:CalibrationProjectRoot 'pilot/shared/response_schema.json'),
        [AllowNull()][object]$ManifestOverride
    )

    $manifestSource = Read-CalibrationPilotJsonSnapshot -Path $PilotManifestPath
    $manifestSchemaSource = Read-CalibrationPilotJsonSnapshot -Path $PilotManifestSchemaPath
    $matrixSource = Read-CalibrationPilotJsonSnapshot -Path $MatrixPath
    $setSource = Read-CalibrationPilotJsonSnapshot -Path $CalibrationSetPath
    $modelProfileSchemaSource = Read-CalibrationPilotJsonSnapshot -Path $ModelProfileSchemaPath
    $responseSchemaSource = Read-CalibrationPilotJsonSnapshot -Path $ResponseSchemaPath
    if ($PSBoundParameters.ContainsKey('ManifestOverride')) { $manifestSource.value = $ManifestOverride }
    if ($responseSchemaSource.value -isnot [pscustomobject] -or
        @(Get-RouterSchemaStructureErrors -Schema $responseSchemaSource.value).Count -gt 0) {
        throw 'Pilot response schema is invalid.'
    }
    if ($manifestSchemaSource.value -isnot [pscustomobject] -or
        @(Get-RouterSchemaStructureErrors -Schema $manifestSchemaSource.value).Count -gt 0) {
        throw 'Pilot manifest schema is invalid.'
    }
    if ($modelProfileSchemaSource.value -isnot [pscustomobject] -or
        @(Get-RouterSchemaStructureErrors -Schema $modelProfileSchemaSource.value).Count -gt 0) {
        throw 'Pilot model profile schema is invalid.'
    }
    try {
        $manifestJson = $manifestSource.value | ConvertTo-Json -Depth 100 -Compress -ErrorAction Stop
        if (-not (Test-Json -Json $manifestJson -Schema $manifestSchemaSource.text -ErrorAction Stop)) {
            throw 'schema validation failed'
        }
    } catch { throw 'Pilot manifest schema validation failed.' }

    $set = $setSource.value
    $rubricEntries = @{}
    $rubricSources = @{}
    if ($set -is [pscustomobject] -and (Test-CalibrationProperty $set 'prompts') -and $set.prompts -is [Collections.IList]) {
        foreach ($prompt in @($set.prompts)) {
            if ($prompt -isnot [pscustomobject] -or -not (Test-CalibrationProperty $prompt 'grading') -or
                -not (Test-CalibrationProperty $prompt.grading 'rubric_ref') -or $prompt.grading.rubric_ref -isnot [string] -or
                $prompt.grading.rubric_ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.json$') { continue }
            $rubricRef = [string]$prompt.grading.rubric_ref
            if ($rubricEntries.ContainsKey($rubricRef)) { continue }
            $rubricPath = [IO.Path]::GetFullPath((Join-Path $RubricsRoot $rubricRef))
            if (-not (Test-CalibrationPathUnderRoot -Path $rubricPath -Root $RubricsRoot)) {
                $rubricEntries[$rubricRef] = [pscustomobject]@{ status = 'missing'; value = $null }
                continue
            }
            try {
                $rubricSource = Read-CalibrationPilotJsonSnapshot -Path $rubricPath
                $rubricSources[$rubricRef] = $rubricSource
                $rubricEntries[$rubricRef] = [pscustomobject]@{ status = 'valid'; value = $rubricSource.value }
            } catch {
                $rubricEntries[$rubricRef] = [pscustomobject]@{ status = 'invalid'; value = $null }
            }
        }
    }
    $setValidation = Test-CalibrationSetObject -SetValue $set -RubricEntriesByRef $rubricEntries
    if (-not $setValidation.valid) {
        throw ('Pilot calibration set validation failed: ' + (@($setValidation.errors) -join ', '))
    }
    $set = $setValidation.set

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
        try {
            $profileJson = $profile | ConvertTo-Json -Depth 100 -Compress -ErrorAction Stop
            if (-not (Test-Json -Json $profileJson -Schema $modelProfileSchemaSource.text -ErrorAction Stop)) {
                throw 'schema validation failed'
            }
        } catch { throw "Pilot profile schema validation failed: $($role.configuration_id)" }
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
        -not $setValidation.rubrics.ContainsKey($prompts[0].grading.rubric_ref)) { throw 'Pilot fixed prompt is invalid.' }
    return [pscustomobject][ordered]@{
        manifest = $manifest; calibration_set = $set; prompt = $prompts[0]; rubric = $setValidation.rubrics[$prompts[0].grading.rubric_ref]
        roles = @($resolvedRoles); hashes = [pscustomobject][ordered]@{
            manifest = $manifestSource.sha256; matrix = $matrixSource.sha256; calibration_set = $setSource.sha256
            response_schema = $responseSchemaSource.sha256; candidate_profile_file_sha256 = $profileSources[$resolvedRoles[0].configuration_id].sha256
        }
        sources = [pscustomobject][ordered]@{
            manifest = $manifestSource
            manifest_schema = $manifestSchemaSource
            matrix = $matrixSource
            calibration_set = $setSource
            model_profile_schema = $modelProfileSchemaSource
            response_schema = $responseSchemaSource
            profiles = $profileSources
            rubrics = $rubricSources
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

    return New-CalibrationPilotSourceBundle -PilotManifestPath (Join-Path $script:CalibrationRoot 'pilots/option1-three-launch-v1.json') `
        -PilotManifestSchemaPath $SchemaPath -CalibrationSetPath $CalibrationSetPath -RubricsRoot $RubricsRoot `
        -MatrixPath $MatrixPath -ProfilesRoot $ProfilesRoot -ManifestOverride $Manifest

}

function Import-CalibrationPilotManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SchemaPath,
        [Parameter(Mandatory)][string]$CalibrationSetPath,
        [Parameter(Mandatory)][string]$RubricsRoot
    )
    return New-CalibrationPilotSourceBundle -PilotManifestPath $Path -PilotManifestSchemaPath $SchemaPath `
        -CalibrationSetPath $CalibrationSetPath -RubricsRoot $RubricsRoot
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

function Copy-CalibrationJsonValue {
    param([Parameter(Mandatory)][object]$Value)
    try {
        return $Value | ConvertTo-Json -Depth 100 -Compress -ErrorAction Stop |
            ConvertFrom-Json -Depth 100 -DateKind String -ErrorAction Stop
    } catch {
        throw 'pilot_json_value_invalid'
    }
}

function Assert-CalibrationExactProperties {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string[]]$Names,
        [Parameter(Mandatory)][string]$ErrorCode
    )
    if ($null -eq $Value -or $Value -isnot [psobject]) { throw $ErrorCode }
    $actual = @($Value.PSObject.Properties.Name)
    if ($actual.Count -ne $Names.Count) { throw $ErrorCode }
    for ($index = 0; $index -lt $Names.Count; $index++) {
        if ($actual[$index] -cne $Names[$index]) { throw $ErrorCode }
    }
}

function Test-CalibrationPilotOrdinal {
    param([AllowNull()][object]$Value, [Parameter(Mandatory)][int]$Expected)
    return ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64]) -and
        [int64]$Value -eq [int64]$Expected
}

function Test-CalibrationPilotCounter {
    param([AllowNull()][object]$Value)
    return ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64]) -and
        [int64]$Value -ge 0
}

function Test-CalibrationPilotTimestamp {
    param([AllowNull()][object]$Value, [switch]$AllowNull)
    if ($null -eq $Value) { return [bool]$AllowNull }
    if ($Value -is [DateTime] -or $Value -is [DateTimeOffset]) { return $true }
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { return $false }
    $parsed = [DateTimeOffset]::MinValue
    return [DateTimeOffset]::TryParseExact(
        $Value, 'o', [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)
}

function ConvertTo-CalibrationPilotComparableResult {
    param([Parameter(Mandatory)][object]$Value)
    $copy = Copy-CalibrationJsonValue $Value
    foreach ($name in @('started_at', 'finished_at')) {
        if ($null -ne $copy.$name) {
            $copy.$name = [DateTimeOffset]::Parse([string]$copy.$name,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime().ToString('o')
        }
    }
    foreach ($attempt in $copy.attempts) {
        foreach ($name in @('slot_claimed_at', 'process_started_at', 'completed_at')) {
            if ($null -ne $attempt.$name) {
                $attempt.$name = [DateTimeOffset]::Parse([string]$attempt.$name,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime().ToString('o')
            }
        }
    }
    return $copy
}

function Assert-CalibrationPilotPlanContract {
    param([Parameter(Mandatory)][object]$Plan)
    $errorCode = 'pilot_plan_contract_invalid'
    Assert-CalibrationExactProperties -Value $Plan -Names @(
        'artifact_version', 'pilot_id', 'mode', 'selection_mode', 'prompt', 'roles', 'limits',
        'source_hashes', 'provider_calls', 'provider_side_requests', 'profile_promotion_allowed',
        'profile_mutated', 'production_eligibility_changed'
    ) -ErrorCode $errorCode
    if ($Plan.artifact_version -isnot [string] -or $Plan.artifact_version -cne 'calibration-pilot-plan/v1' -or
        $Plan.pilot_id -isnot [string] -or $Plan.pilot_id -cne 'option1-three-launch-v1' -or
        $Plan.mode -isnot [string] -or $Plan.mode -cne 'pilot-plan' -or
        $Plan.selection_mode -isnot [string] -or $Plan.selection_mode -cne 'calibration_only_exact_pin' -or
        -not (Test-CalibrationPilotCounter $Plan.provider_calls) -or [int64]$Plan.provider_calls -ne 0 -or
        $Plan.profile_promotion_allowed -isnot [bool] -or $Plan.profile_promotion_allowed -or
        $Plan.profile_mutated -isnot [bool] -or $Plan.profile_mutated -or
        $Plan.production_eligibility_changed -isnot [bool] -or $Plan.production_eligibility_changed) {
        throw $errorCode
    }
    Assert-CalibrationExactProperties -Value $Plan.prompt -Names @('id', 'version') -ErrorCode $errorCode
    if ($Plan.prompt.id -isnot [string] -or $Plan.prompt.id -cne 'extraction-low-general-v1' -or
        $Plan.prompt.version -isnot [string] -or $Plan.prompt.version -cne '1.0.0') { throw $errorCode }
    Assert-CalibrationExactProperties -Value $Plan.limits -Names @('total', 'provider_family', 'application_retries') -ErrorCode $errorCode
    Assert-CalibrationExactProperties -Value $Plan.limits.provider_family -Names @('google', 'openai', 'anthropic') -ErrorCode $errorCode
    if (-not (Test-CalibrationPilotOrdinal $Plan.limits.total 3) -or
        -not (Test-CalibrationPilotOrdinal $Plan.limits.provider_family.google 1) -or
        -not (Test-CalibrationPilotOrdinal $Plan.limits.provider_family.openai 1) -or
        -not (Test-CalibrationPilotOrdinal $Plan.limits.provider_family.anthropic 1) -or
        -not (Test-CalibrationPilotOrdinal $Plan.limits.application_retries 0)) { throw $errorCode }
    Assert-CalibrationExactProperties -Value $Plan.provider_side_requests -Names @('observable', 'count') -ErrorCode $errorCode
    if ($Plan.provider_side_requests.observable -isnot [bool] -or $Plan.provider_side_requests.observable -or
        $null -ne $Plan.provider_side_requests.count) { throw $errorCode }
    if ($Plan.roles -isnot [Collections.IList] -or $Plan.roles.Count -ne 3) { throw $errorCode }
    $expectedRoles = @(
        @('candidate', 'google', 'agy', 'agy__gemini_3_7_flash_low__low', 'gemini-3.7-flash-low__low', 'gemini-3.7-flash-low', 'low'),
        @('judge_1', 'openai', 'codex', 'codex__gpt_5_6_sol__max', 'gpt-5.6-sol__max', 'gpt-5.6-sol', 'max'),
        @('judge_2', 'anthropic', 'claude', 'claude__claude_opus_5__max', 'claude-opus-5__max', 'claude-opus-5', 'max')
    )
    for ($index = 0; $index -lt 3; $index++) {
        $role = $Plan.roles[$index]
        Assert-CalibrationExactProperties -Value $role -Names @(
            'ordinal', 'role', 'family', 'launcher', 'route_id', 'configuration_id', 'model', 'effort'
        ) -ErrorCode $errorCode
        if (-not (Test-CalibrationPilotOrdinal $role.ordinal ($index + 1))) { throw $errorCode }
        $names = @('role', 'family', 'launcher', 'route_id', 'configuration_id', 'model', 'effort')
        for ($fieldIndex = 0; $fieldIndex -lt $names.Count; $fieldIndex++) {
            $name = $names[$fieldIndex]
            if ($role.$name -isnot [string] -or $role.$name -cne $expectedRoles[$index][$fieldIndex]) { throw $errorCode }
        }
    }
    Assert-CalibrationExactProperties -Value $Plan.source_hashes -Names @(
        'manifest', 'matrix', 'candidate_profile', 'calibration_set', 'prompt_definition', 'rubric', 'response_schema'
    ) -ErrorCode $errorCode
    foreach ($property in $Plan.source_hashes.PSObject.Properties) {
        if ($property.Value -isnot [string] -or $property.Value -cnotmatch '^[0-9a-f]{64}$') { throw $errorCode }
    }
}

function Write-CalibrationCreateNewJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Value,
        [Parameter(Mandatory)][string]$AllowedRunRoot
    )
    Assert-CalibrationWriteBoundary -Path $Path -AllowedRunRoot $AllowedRunRoot
    $fullRunRoot = [IO.Path]::GetFullPath($AllowedRunRoot)
    if (-not (Test-Path -LiteralPath $fullRunRoot -PathType Container)) { throw 'pilot_run_root_missing' }
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        Assert-CalibrationWriteBoundary -Path $parent -AllowedRunRoot $fullRunRoot
        try { $null = [IO.Directory]::CreateDirectory($parent) } catch { throw 'pilot_parent_create_failed' }
    }
    Assert-CalibrationWriteBoundary -Path $Path -AllowedRunRoot $fullRunRoot
    try {
        $json = $Value | ConvertTo-Json -Depth 100 -ErrorAction Stop
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    } catch { throw 'pilot_json_value_invalid' }
    $stream = $null
    $fileCreated = $false
    $postCreateFailure = $false
    try {
        try {
            $stream = Open-CalibrationCreateNewFileStream -Path ([IO.Path]::GetFullPath($Path))
            $fileCreated = $true
        } catch {
            if (Test-CalibrationCreateNewCollisionException -Exception $_.Exception) { throw 'pilot_create_new_collision' }
            throw 'pilot_create_new_failed'
        }
        try {
            Invoke-CalibrationPilotAfterCreateNewOpenHook -Path ([IO.Path]::GetFullPath($Path))
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } catch {
            $postCreateFailure = $true
        } finally {
            if ($null -ne $stream) {
                try { $stream.Dispose() } catch { $postCreateFailure = $true }
                $stream = $null
            }
        }
    } catch {
        if ($fileCreated) {
            if ($null -ne $stream) {
                try { $stream.Dispose() } catch { }
                $stream = $null
            }
            throw 'pilot_create_new_persistence_indeterminate'
        }
        throw
    }
    if ($postCreateFailure) { throw 'pilot_create_new_persistence_indeterminate' }
}

function Test-CalibrationCreateNewCollisionException {
    param([Parameter(Mandatory)][Exception]$Exception)
    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [IO.IOException]) {
            $nativeCode = $current.HResult -band 0xffff
            return $nativeCode -eq 80 -or $nativeCode -eq 183
        }
        $current = $current.InnerException
    }
    return $false
}

function Open-CalibrationCreateNewFileStream {
    param(
        [Parameter(Mandatory)][string]$Path,
        [IO.FileAccess]$Access = [IO.FileAccess]::Write
    )
    return [IO.File]::Open($Path, [IO.FileMode]::CreateNew, $Access, [IO.FileShare]::None)
}

function Invoke-CalibrationPilotAfterCreateNewOpenHook { param([string]$Path) }
function Close-CalibrationPilotResultTempStream { param([Parameter(Mandatory)][IO.FileStream]$Stream) $Stream.Dispose() }
function Invoke-CalibrationPilotBeforeSlotClaimHook { param([object]$Context, [int]$Ordinal) }
function Invoke-CalibrationPilotAfterSlotClaimCreateHook { param([string]$Path) }
function Invoke-CalibrationPilotAfterSlotClaimHook { param([object]$Context, [int]$Ordinal) }

function Write-CalibrationPilotClaimCreateNewJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Value,
        [Parameter(Mandatory)][string]$AllowedRunRoot
    )
    Assert-CalibrationWriteBoundary -Path $Path -AllowedRunRoot $AllowedRunRoot
    $fullRunRoot = [IO.Path]::GetFullPath($AllowedRunRoot)
    if (-not (Test-Path -LiteralPath $fullRunRoot -PathType Container)) { throw 'pilot_run_root_missing' }
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'pilot_claim_parent_missing' }
    Assert-CalibrationWriteBoundary -Path $Path -AllowedRunRoot $fullRunRoot
    try {
        $json = $Value | ConvertTo-Json -Depth 100 -ErrorAction Stop
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    } catch { throw 'pilot_json_value_invalid' }

    $stream = $null
    $claimCreated = $false
    $postCreateFailure = $false
    try {
        try {
            $stream = Open-CalibrationCreateNewFileStream -Path ([IO.Path]::GetFullPath($Path))
            $claimCreated = $true
        } catch {
            if (Test-CalibrationCreateNewCollisionException -Exception $_.Exception) { throw 'pilot_create_new_collision' }
            throw 'pilot_create_new_failed'
        }

        try {
            Invoke-CalibrationPilotAfterSlotClaimCreateHook -Path ([IO.Path]::GetFullPath($Path))
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } catch {
            $postCreateFailure = $true
        } finally {
            if ($null -ne $stream) {
                try { $stream.Dispose() } catch { $postCreateFailure = $true }
                $stream = $null
            }
        }
    } catch {
        if ($claimCreated) {
            if ($null -ne $stream) {
                try { $stream.Dispose() } catch { }
                $stream = $null
            }
            throw 'pilot_claim_persistence_indeterminate'
        }
        throw
    }
    if ($postCreateFailure) { throw 'pilot_claim_persistence_indeterminate' }
}

function Remove-CalibrationOwnedResultTemp {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$AllowedRunRoot
    )
    Assert-CalibrationWriteBoundary -Path $Path -AllowedRunRoot $AllowedRunRoot
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'pilot_result_temp_cleanup_reparse'
    }
    Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
}

function Write-CalibrationAtomicResultJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Value,
        [Parameter(Mandatory)][string]$AllowedRunRoot,
        [AllowNull()][string]$TemporaryPath
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRunRoot = [IO.Path]::GetFullPath($AllowedRunRoot).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ([IO.Path]::GetFileName($fullPath) -cne 'result.json' -or
        [IO.Path]::GetDirectoryName($fullPath) -cne $fullRunRoot) { throw 'pilot_result_path_invalid' }
    Assert-CalibrationWriteBoundary -Path $fullPath -AllowedRunRoot $fullRunRoot
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        Write-CalibrationCreateNewJson -Path $fullPath -Value $Value -AllowedRunRoot $fullRunRoot
        return
    }
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 100 -ErrorAction Stop))
    } catch { throw 'pilot_json_value_invalid' }
    $tempPath = if ([string]::IsNullOrWhiteSpace($TemporaryPath)) {
        Join-Path $fullRunRoot ('.result-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    } else { [IO.Path]::GetFullPath($TemporaryPath) }
    if ([IO.Path]::GetDirectoryName($tempPath) -cne $fullRunRoot -or
        [IO.Path]::GetFileName($tempPath) -notmatch '^\.result-[0-9a-f]{32}\.tmp$') {
        throw 'pilot_result_temp_path_invalid'
    }
    Assert-CalibrationWriteBoundary -Path $tempPath -AllowedRunRoot $fullRunRoot
    $stream = $null
    $ownsTemp = $false
    $tempPersistenceFailed = $false
    $tempDisposeFailed = $false
    $tempCleanupFailed = $false
    try {
        try {
            $stream = Open-CalibrationCreateNewFileStream -Path $tempPath
            $ownsTemp = $true
        } catch {
            if (Test-CalibrationCreateNewCollisionException -Exception $_.Exception) { throw 'pilot_result_temp_collision' }
            throw 'pilot_result_temp_create_failed'
        }
        try {
            try {
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush($true)
            } catch { $tempPersistenceFailed = $true }
            finally {
                if ($null -ne $stream) {
                    try { Close-CalibrationPilotResultTempStream -Stream $stream }
                    catch {
                        $tempDisposeFailed = $true
                        try { $stream.Dispose() } catch { }
                    } finally { $stream = $null }
                }
            }
            if (-not $tempPersistenceFailed -and -not $tempDisposeFailed) {
                try {
                    Assert-CalibrationWriteBoundary -Path $fullPath -AllowedRunRoot $fullRunRoot
                    Assert-CalibrationWriteBoundary -Path $tempPath -AllowedRunRoot $fullRunRoot
                } catch { $tempPersistenceFailed = $true }
            }
        } finally {
            if (($tempPersistenceFailed -or $tempDisposeFailed) -and $ownsTemp) {
                try {
                    Remove-CalibrationOwnedResultTemp -Path $tempPath -AllowedRunRoot $fullRunRoot
                    $ownsTemp = $false
                } catch { $tempCleanupFailed = $true }
            }
        }
    } catch {
        if (-not $ownsTemp) { throw }
        $tempPersistenceFailed = $true
        try {
            if ($null -ne $stream) {
                try { $stream.Dispose() } catch { $tempDisposeFailed = $true }
                $stream = $null
            }
        } finally {
            try {
                Remove-CalibrationOwnedResultTemp -Path $tempPath -AllowedRunRoot $fullRunRoot
                $ownsTemp = $false
            } catch { $tempCleanupFailed = $true }
        }
    }
    if ($tempCleanupFailed) { throw 'pilot_result_temp_cleanup_indeterminate' }
    if ($tempPersistenceFailed -or $tempDisposeFailed) { throw 'pilot_result_temp_persistence_indeterminate' }
    $replaceFailed = $false
    $cleanupFailed = $false
    try {
        [IO.File]::Move($tempPath, $fullPath, $true)
        $ownsTemp = $false
    } catch {
        $replaceFailed = $true
    } finally {
        if ($replaceFailed -and $ownsTemp) {
            try {
                Remove-CalibrationOwnedResultTemp -Path $tempPath -AllowedRunRoot $fullRunRoot
                $ownsTemp = $false
            } catch { $cleanupFailed = $true }
        }
    }
    if ($cleanupFailed) { throw 'pilot_result_temp_cleanup_indeterminate' }
    if ($replaceFailed) { throw 'pilot_result_replace_indeterminate' }
}

function New-CalibrationPilotInitialResult {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][object]$Plan
    )
    $attempts = @(
        foreach ($role in $Plan.roles) {
            [pscustomobject][ordered]@{
                ordinal = $role.ordinal
                role = [string]$role.role
                family = [string]$role.family
                launcher = [string]$role.launcher
                route_id = [string]$role.route_id
                configuration_id = [string]$role.configuration_id
                model = [string]$role.model
                effort = [string]$role.effort
                state = 'planned'
                slot_claimed_at = $null
                process_started_at = $null
                completed_at = $null
                exit_code = $null
                transport_status = $null
                contract_status = $null
                decision = $null
            }
        }
    )
    return [pscustomobject][ordered]@{
        artifact_version = 'calibration-pilot-result/v1'
        run_id = $RunId
        pilot_id = [string]$Plan.pilot_id
        selection_mode = [string]$Plan.selection_mode
        run_state = 'planned'
        stop_reason = $null
        started_at = $null
        finished_at = $null
        source_hashes = Copy-CalibrationJsonValue $Plan.source_hashes
        limits = Copy-CalibrationJsonValue $Plan.limits
        attempts = $attempts
        slots_consumed = [pscustomobject][ordered]@{
            total = 0
            provider_family = [pscustomobject][ordered]@{ google = 0; openai = 0; anthropic = 0 }
        }
        launcher_processes_started = [pscustomobject][ordered]@{
            total = 0
            provider_family = [pscustomobject][ordered]@{ google = 0; openai = 0; anthropic = 0 }
        }
        provider_side_requests = [pscustomobject][ordered]@{ observable = $false; count = $null }
        quality = [pscustomobject][ordered]@{ external_category = 'unknown' }
        profile_promotion_allowed = $false
        profile_mutated = $false
        production_eligibility_changed = $false
    }
}

function Assert-CalibrationPilotContext {
    param([Parameter(Mandatory)][object]$Context)
    if ($null -eq $Context -or $Context.is_closed -ne $false -or $null -eq $Context.claim_stream -or
        $null -eq $Context.sync_root) { throw 'pilot_run_context_invalid' }
    $runRoot = [IO.Path]::GetFullPath([string]$Context.run_root).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (-not (Test-CalibrationPathUnderRoot -Path $runRoot -Root $script:CalibrationResultsRoot) -or
        [IO.Path]::GetFullPath([string]$Context.plan_path) -cne (Join-Path $runRoot 'plan.json') -or
        [IO.Path]::GetFullPath([string]$Context.result_path) -cne (Join-Path $runRoot 'result.json') -or
        [IO.Path]::GetFullPath([string]$Context.claim_path) -cne (Join-Path $runRoot '.run.claim') -or
        [IO.Path]::GetFullPath([string]$Context.claims_path) -cne (Join-Path $runRoot 'claims') -or
        [IO.Path]::GetFullPath([string]$Context.raw_path) -cne (Join-Path $runRoot 'raw')) {
        throw 'pilot_run_context_invalid'
    }
    Assert-CalibrationNoReparseComponents -Path $runRoot
    try {
        if ($Context.claim_stream -isnot [IO.FileStream] -or
            $Context.claim_stream.SafeFileHandle.IsClosed -or $Context.claim_stream.SafeFileHandle.IsInvalid -or
            -not $Context.claim_stream.CanWrite -or
            [IO.Path]::GetFullPath($Context.claim_stream.Name) -cne [IO.Path]::GetFullPath($Context.claim_path)) {
            throw 'pilot_run_context_invalid'
        }
        Assert-CalibrationNoReparseComponents -Path $Context.claim_path
        Assert-CalibrationNoReparseComponents -Path $Context.plan_path
        $persistedPlan = Get-Content -Raw -LiteralPath $Context.plan_path -ErrorAction Stop |
            ConvertFrom-Json -Depth 100 -DateKind String -ErrorAction Stop
        Assert-CalibrationPilotPlanContract -Plan $Context.plan
        if ((Get-CalibrationObjectSha256 -Value $persistedPlan) -cne
            (Get-CalibrationObjectSha256 -Value $Context.plan)) { throw 'pilot_run_context_invalid' }
    } catch { throw 'pilot_run_context_invalid' }
}

function Get-CalibrationPilotSyncRoot {
    param([AllowNull()][object]$Context)
    if ($null -eq $Context -or -not (Test-CalibrationProperty $Context 'sync_root') -or
        $null -eq $Context.sync_root -or $Context.sync_root.GetType() -ne [object]) {
        throw 'pilot_run_context_invalid'
    }
    return $Context.sync_root
}

function Assert-CalibrationPilotResultContract {
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][object]$Result,
        [switch]$SkipClaimCounterCheck,
        [switch]$SkipPersistedResultMatch
    )
    $errorCode = 'pilot_result_contract_invalid'
    Assert-CalibrationPilotContext -Context $Context
    Assert-CalibrationExactProperties -Value $Result -Names @(
        'artifact_version', 'run_id', 'pilot_id', 'selection_mode', 'run_state', 'stop_reason', 'started_at',
        'finished_at', 'source_hashes', 'limits', 'attempts', 'slots_consumed', 'launcher_processes_started',
        'provider_side_requests', 'quality', 'profile_promotion_allowed', 'profile_mutated',
        'production_eligibility_changed'
    ) -ErrorCode $errorCode
    if ($Result.artifact_version -isnot [string] -or $Result.artifact_version -cne 'calibration-pilot-result/v1' -or
        $Result.run_id -isnot [string] -or $Result.run_id -cne $Context.run_id -or
        $Result.pilot_id -isnot [string] -or $Result.pilot_id -cne $Context.plan.pilot_id -or
        $Result.selection_mode -isnot [string] -or $Result.selection_mode -cne $Context.plan.selection_mode -or
        $Result.run_state -isnot [string] -or -not $script:PilotRunTransitions.ContainsKey([string]$Result.run_state) -or
        $Result.stop_reason -cnotin @($null, 'pilot_stopped', 'persistence_indeterminate') -or
        -not (Test-CalibrationPilotTimestamp $Result.started_at -AllowNull) -or
        -not (Test-CalibrationPilotTimestamp $Result.finished_at -AllowNull)) { throw $errorCode }
    if ((Get-CalibrationObjectSha256 -Value $Result.source_hashes) -cne (Get-CalibrationObjectSha256 -Value $Context.plan.source_hashes) -or
        (Get-CalibrationObjectSha256 -Value $Result.limits) -cne (Get-CalibrationObjectSha256 -Value $Context.plan.limits)) { throw $errorCode }
    if ($Result.attempts -isnot [Collections.IList] -or $Result.attempts.Count -ne 3) { throw $errorCode }
    for ($index = 0; $index -lt 3; $index++) {
        $attempt = $Result.attempts[$index]
        $role = $Context.plan.roles[$index]
        Assert-CalibrationExactProperties -Value $attempt -Names @(
            'ordinal', 'role', 'family', 'launcher', 'route_id', 'configuration_id', 'model', 'effort', 'state',
            'slot_claimed_at', 'process_started_at', 'completed_at', 'exit_code', 'transport_status',
            'contract_status', 'decision'
        ) -ErrorCode $errorCode
        if (-not (Test-CalibrationPilotOrdinal $attempt.ordinal ($index + 1)) -or
            $attempt.state -isnot [string] -or -not $script:PilotAttemptTransitions.ContainsKey([string]$attempt.state)) { throw $errorCode }
        foreach ($name in @('role', 'family', 'launcher', 'route_id', 'configuration_id', 'model', 'effort')) {
            if ($attempt.$name -isnot [string] -or $attempt.$name -cne $role.$name) { throw $errorCode }
        }
        foreach ($name in @('slot_claimed_at', 'process_started_at', 'completed_at')) {
            if (-not (Test-CalibrationPilotTimestamp $attempt.$name -AllowNull)) { throw $errorCode }
        }
        if ($null -ne $attempt.exit_code -or $null -ne $attempt.transport_status -or
            $null -ne $attempt.contract_status -or $null -ne $attempt.decision) { throw $errorCode }
        switch ([string]$attempt.state) {
            'planned' {
                if ($null -ne $attempt.slot_claimed_at -or $null -ne $attempt.process_started_at -or
                    $null -ne $attempt.completed_at) { throw $errorCode }
            }
            'slot_reserved' {
                if ($null -eq $attempt.slot_claimed_at -or $null -ne $attempt.process_started_at -or
                    $null -ne $attempt.completed_at) { throw $errorCode }
            }
            'process_started' {
                if ($null -eq $attempt.slot_claimed_at -or $null -eq $attempt.process_started_at -or
                    $null -ne $attempt.completed_at) { throw $errorCode }
            }
            'succeeded' {
                if ($null -eq $attempt.slot_claimed_at -or $null -eq $attempt.process_started_at -or
                    $null -eq $attempt.completed_at) { throw $errorCode }
            }
            'failed' {
                if ($null -eq $attempt.slot_claimed_at -or $null -eq $attempt.completed_at) { throw $errorCode }
            }
            'skipped' {
                if ($null -ne $attempt.slot_claimed_at -or $null -ne $attempt.process_started_at -or
                    $null -eq $attempt.completed_at) { throw $errorCode }
            }
        }
    }
    if ($Result.run_state -cin @('planned', 'preflight_passed') -and
        @($Result.attempts | Where-Object { $_.state -cne 'planned' }).Count -gt 0) { throw $errorCode }
    if ($Result.run_state -ceq 'completed' -and
        @($Result.attempts | Where-Object { $_.state -cne 'succeeded' }).Count -gt 0) { throw $errorCode }
    $priorAttemptSucceeded = $true
    foreach ($attempt in $Result.attempts) {
        if (-not $priorAttemptSucceeded -and $attempt.state -cne 'planned') { throw $errorCode }
        $priorAttemptSucceeded = ($attempt.state -ceq 'succeeded')
    }
    foreach ($counterName in @('slots_consumed', 'launcher_processes_started')) {
        $counter = $Result.$counterName
        Assert-CalibrationExactProperties -Value $counter -Names @('total', 'provider_family') -ErrorCode $errorCode
        Assert-CalibrationExactProperties -Value $counter.provider_family -Names @('google', 'openai', 'anthropic') -ErrorCode $errorCode
        if (-not (Test-CalibrationPilotCounter $counter.total) -or
            -not (Test-CalibrationPilotCounter $counter.provider_family.google) -or
            -not (Test-CalibrationPilotCounter $counter.provider_family.openai) -or
            -not (Test-CalibrationPilotCounter $counter.provider_family.anthropic) -or
            [int64]$counter.total -ne ([int64]$counter.provider_family.google + [int64]$counter.provider_family.openai + [int64]$counter.provider_family.anthropic)) {
            throw $errorCode
        }
    }
    Assert-CalibrationExactProperties -Value $Result.provider_side_requests -Names @('observable', 'count') -ErrorCode $errorCode
    Assert-CalibrationExactProperties -Value $Result.quality -Names @('external_category') -ErrorCode $errorCode
    if ($Result.provider_side_requests.observable -isnot [bool] -or $Result.provider_side_requests.observable -or
        $null -ne $Result.provider_side_requests.count -or $Result.quality.external_category -isnot [string] -or
        $Result.quality.external_category -cne 'unknown' -or $Result.profile_promotion_allowed -isnot [bool] -or
        $Result.profile_promotion_allowed -or $Result.profile_mutated -isnot [bool] -or $Result.profile_mutated -or
        $Result.production_eligibility_changed -isnot [bool] -or $Result.production_eligibility_changed) { throw $errorCode }
    switch ([string]$Result.run_state) {
        { $_ -cin @('planned', 'preflight_passed') } {
            if ($null -ne $Result.started_at -or $null -ne $Result.finished_at -or $null -ne $Result.stop_reason) { throw $errorCode }
        }
        'running' {
            if ($null -eq $Result.started_at -or $null -ne $Result.finished_at -or $null -ne $Result.stop_reason) { throw $errorCode }
        }
        'completed' {
            if ($null -eq $Result.started_at -or $null -eq $Result.finished_at -or $null -ne $Result.stop_reason) { throw $errorCode }
        }
        'stopped' {
            if ($null -eq $Result.finished_at -or $Result.stop_reason -cne 'pilot_stopped') { throw $errorCode }
        }
        'indeterminate' {
            if ($null -eq $Result.started_at -or $null -eq $Result.finished_at -or
                $Result.stop_reason -cne 'persistence_indeterminate') { throw $errorCode }
        }
    }
    $expectedSlots = [pscustomobject]@{ total = 0; google = 0; openai = 0; anthropic = 0 }
    $expectedLaunches = [pscustomobject]@{ total = 0; google = 0; openai = 0; anthropic = 0 }
    foreach ($attempt in $Result.attempts) {
        if ($null -ne $attempt.slot_claimed_at) {
            $expectedSlots.total++
            $expectedSlots.([string]$attempt.family)++
        }
        if ($null -ne $attempt.process_started_at) {
            $expectedLaunches.total++
            $expectedLaunches.([string]$attempt.family)++
        }
    }
    if ([int64]$Result.slots_consumed.total -ne $expectedSlots.total -or
        [int64]$Result.slots_consumed.provider_family.google -ne $expectedSlots.google -or
        [int64]$Result.slots_consumed.provider_family.openai -ne $expectedSlots.openai -or
        [int64]$Result.slots_consumed.provider_family.anthropic -ne $expectedSlots.anthropic -or
        [int64]$Result.launcher_processes_started.total -ne $expectedLaunches.total -or
        [int64]$Result.launcher_processes_started.provider_family.google -ne $expectedLaunches.google -or
        [int64]$Result.launcher_processes_started.provider_family.openai -ne $expectedLaunches.openai -or
        [int64]$Result.launcher_processes_started.provider_family.anthropic -ne $expectedLaunches.anthropic) {
        throw $errorCode
    }
    if (-not $SkipClaimCounterCheck) { $null = Get-CalibrationPilotClaimCount -Context $Context -Result $Result }
    if (-not $SkipPersistedResultMatch) {
        try {
            Assert-CalibrationNoReparseComponents -Path $Context.result_path
            $persistedResult = Get-Content -Raw -LiteralPath $Context.result_path -ErrorAction Stop |
                ConvertFrom-Json -Depth 100 -DateKind String -ErrorAction Stop
            if ((Get-CalibrationObjectSha256 -Value (ConvertTo-CalibrationPilotComparableResult $persistedResult)) -cne
                (Get-CalibrationObjectSha256 -Value (ConvertTo-CalibrationPilotComparableResult $Result))) { throw $errorCode }
        } catch { throw $errorCode }
    }
}

function New-CalibrationPilotRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResultsRoot,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RunId,
        [Parameter(Mandatory)][object]$Plan
    )
    if (-not (Test-CalibrationSafeLeafName $RunId)) { throw 'pilot_run_id_invalid' }
    Assert-CalibrationPilotPlanContract -Plan $Plan
    $resolvedResultsRoot = [IO.Path]::GetFullPath($ResultsRoot).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (-not $resolvedResultsRoot.Equals($script:CalibrationResultsRoot, [StringComparison]::OrdinalIgnoreCase) -and
        -not (Test-CalibrationPathUnderRoot -Path $resolvedResultsRoot -Root $script:CalibrationResultsRoot)) {
        throw 'pilot_results_root_invalid'
    }
    Assert-CalibrationNoReparseComponents -Path $resolvedResultsRoot
    if (-not (Test-Path -LiteralPath $resolvedResultsRoot -PathType Container)) {
        try { $null = [IO.Directory]::CreateDirectory($resolvedResultsRoot) } catch { throw 'pilot_results_root_create_failed' }
    }
    Assert-CalibrationNoReparseComponents -Path $resolvedResultsRoot
    $runRoot = [IO.Path]::GetFullPath((Join-Path $resolvedResultsRoot $RunId))
    if (-not (Test-CalibrationPathUnderRoot -Path $runRoot -Root $resolvedResultsRoot) -or
        (Test-Path -LiteralPath $runRoot)) { throw 'pilot_run_collision' }
    try { $null = [IO.Directory]::CreateDirectory($runRoot) } catch { throw 'pilot_run_collision' }
    Assert-CalibrationNoReparseComponents -Path $runRoot
    $claimPath = Join-Path $runRoot '.run.claim'
    $claimStream = $null
    try {
        try {
            $claimStream = [IO.File]::Open($claimPath, [IO.FileMode]::CreateNew,
                [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $claimStream.Flush($true)
        } catch { throw 'pilot_run_claim_failed' }
        $claimsPath = Join-Path $runRoot 'claims'
        $rawPath = Join-Path $runRoot 'raw'
        foreach ($directory in @($claimsPath, $rawPath)) {
            Assert-CalibrationWriteBoundary -Path $directory -AllowedRunRoot $runRoot
            $null = [IO.Directory]::CreateDirectory($directory)
            Assert-CalibrationNoReparseComponents -Path $directory
        }
        $safePlan = Copy-CalibrationJsonValue $Plan
        $planPath = Join-Path $runRoot 'plan.json'
        Write-CalibrationCreateNewJson -Path $planPath -Value $safePlan -AllowedRunRoot $runRoot
        $result = New-CalibrationPilotInitialResult -RunId $RunId -Plan $safePlan
        $resultPath = Join-Path $runRoot 'result.json'
        Write-CalibrationAtomicResultJson -Path $resultPath -Value $result -AllowedRunRoot $runRoot
        $context = [pscustomobject][ordered]@{
            run_id = $RunId
            run_root = $runRoot
            claim_path = $claimPath
            plan_path = $planPath
            result_path = $resultPath
            claims_path = $claimsPath
            raw_path = $rawPath
            plan = $safePlan
            result = $result
            claim_stream = $claimStream
            sync_root = [object]::new()
            is_closed = $false
        }
        Assert-CalibrationPilotResultContract -Context $context -Result $result
        return $context
    } catch {
        if ($null -ne $claimStream) { $claimStream.Dispose() }
        throw
    }
}

function Close-CalibrationPilotRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Context)
    $syncRoot = Get-CalibrationPilotSyncRoot -Context $Context
    [Threading.Monitor]::Enter($syncRoot)
    try {
        if ($Context.is_closed -eq $true) { return }
        Assert-CalibrationPilotContext -Context $Context
        try { $Context.claim_stream.Dispose() } catch { throw 'pilot_run_close_failed' }
        $Context.claim_stream = $null
        $Context.is_closed = $true
    } finally { [Threading.Monitor]::Exit($syncRoot) }
}

function Get-CalibrationPilotClaimCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Context,
        [AllowNull()][object]$Result
    )
    $syncRoot = Get-CalibrationPilotSyncRoot -Context $Context
    [Threading.Monitor]::Enter($syncRoot)
    try {
        Assert-CalibrationPilotContext -Context $Context
        Assert-CalibrationNoReparseComponents -Path $Context.claims_path
        $counts = [pscustomobject][ordered]@{
            total = 0
            provider_family = [pscustomobject][ordered]@{ google = 0; openai = 0; anthropic = 0 }
        }
        $items = @(Get-ChildItem -LiteralPath $Context.claims_path -Force -ErrorAction Stop)
        foreach ($item in $items) {
            if ($item.PSIsContainer -or $script:PilotClaimFileNames -cnotcontains $item.Name -or
                ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'pilot_claim_artifact_invalid' }
        }
        for ($index = 0; $index -lt 3; $index++) {
            $path = Join-Path $Context.claims_path $script:PilotClaimFileNames[$index]
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            try { $claim = Get-Content -Raw -LiteralPath $path -ErrorAction Stop | ConvertFrom-Json -Depth 30 -DateKind String -ErrorAction Stop }
            catch { throw 'pilot_claim_artifact_invalid' }
            Assert-CalibrationExactProperties -Value $claim -Names @(
                'run_id', 'ordinal', 'role', 'family', 'launcher', 'route_id', 'configuration_id', 'model', 'effort', 'claimed_at'
            ) -ErrorCode 'pilot_claim_artifact_invalid'
            $role = $Context.plan.roles[$index]
            if ($claim.run_id -isnot [string] -or $claim.run_id -cne $Context.run_id -or
                -not (Test-CalibrationPilotOrdinal $claim.ordinal ($index + 1)) -or
                -not (Test-CalibrationPilotTimestamp $claim.claimed_at)) {
                throw 'pilot_claim_artifact_invalid'
            }
            foreach ($name in @('role', 'family', 'launcher', 'route_id', 'configuration_id', 'model', 'effort')) {
                if ($claim.$name -isnot [string] -or $claim.$name -cne $role.$name) { throw 'pilot_claim_artifact_invalid' }
            }
            $counts.total++
            $counts.provider_family.($role.family)++
        }
        $resultToVerify = if ($null -ne $Result) { $Result } else { $Context.result }
        if ($null -ne $resultToVerify -and
            ([int64]$resultToVerify.slots_consumed.total -ne $counts.total -or
            [int64]$resultToVerify.slots_consumed.provider_family.google -ne $counts.provider_family.google -or
            [int64]$resultToVerify.slots_consumed.provider_family.openai -ne $counts.provider_family.openai -or
            [int64]$resultToVerify.slots_consumed.provider_family.anthropic -ne $counts.provider_family.anthropic)) {
            throw 'pilot_claim_counter_mismatch'
        }
        return $counts
    } finally { [Threading.Monitor]::Exit($syncRoot) }
}

function Set-CalibrationPilotRunState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][string]$State
    )
    $syncRoot = Get-CalibrationPilotSyncRoot -Context $Context
    [Threading.Monitor]::Enter($syncRoot)
    try {
        Assert-CalibrationPilotContext -Context $Context
        Assert-CalibrationPilotResultContract -Context $Context -Result $Context.result
        $current = [string]$Context.result.run_state
        if (-not $script:PilotRunTransitions.ContainsKey($current) -or
            $State -isnot [string] -or $script:PilotRunTransitions[$current] -cnotcontains $State) {
            throw 'pilot_run_transition_invalid'
        }
        if ($State -ceq 'completed' -and
            @($Context.result.attempts | Where-Object { $_.state -cne 'succeeded' }).Count -gt 0) {
            throw 'pilot_run_completion_invalid'
        }
        $next = Copy-CalibrationJsonValue $Context.result
        $next.run_state = $State
        if ($State -ceq 'running') { $next.started_at = [DateTimeOffset]::UtcNow.ToString('o') }
        if ($State -cin @('completed', 'stopped', 'indeterminate')) {
            $next.finished_at = [DateTimeOffset]::UtcNow.ToString('o')
            if ($State -ceq 'stopped') { $next.stop_reason = 'pilot_stopped' }
            elseif ($State -ceq 'indeterminate') { $next.stop_reason = 'persistence_indeterminate' }
        }
        Assert-CalibrationPilotResultContract -Context $Context -Result $next -SkipPersistedResultMatch
        Write-CalibrationAtomicResultJson -Path $Context.result_path -Value $next -AllowedRunRoot $Context.run_root
        $Context.result = $next
    } finally { [Threading.Monitor]::Exit($syncRoot) }
}

function Set-CalibrationPilotAttemptState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][object]$Ordinal,
        [Parameter(Mandatory)][string]$State
    )
    if (-not ($Ordinal -is [byte] -or $Ordinal -is [int16] -or $Ordinal -is [int32] -or $Ordinal -is [int64]) -or
        [int64]$Ordinal -lt 1 -or [int64]$Ordinal -gt 3) {
        throw 'pilot_attempt_ordinal_invalid'
    }
    $syncRoot = Get-CalibrationPilotSyncRoot -Context $Context
    [Threading.Monitor]::Enter($syncRoot)
    try {
        Assert-CalibrationPilotContext -Context $Context
        Assert-CalibrationPilotResultContract -Context $Context -Result $Context.result
        if ($Context.result.run_state -cin @('completed', 'stopped', 'indeterminate')) {
            throw 'pilot_attempt_run_terminal'
        }
        if ($Context.result.run_state -cne 'running') { throw 'pilot_attempt_run_not_running' }
        $index = [int]$Ordinal - 1
        $current = [string]$Context.result.attempts[$index].state
        if (-not $script:PilotAttemptTransitions.ContainsKey($current) -or
            $State -isnot [string] -or $script:PilotAttemptTransitions[$current] -cnotcontains $State) {
            throw 'pilot_attempt_transition_invalid'
        }
        if ($State -ceq 'slot_reserved') {
            $claimPath = Join-Path $Context.claims_path $script:PilotClaimFileNames[$index]
            if (-not (Test-Path -LiteralPath $claimPath -PathType Leaf)) { throw 'pilot_attempt_transition_invalid' }
        }
        $next = Copy-CalibrationJsonValue $Context.result
        $next.attempts[$index].state = $State
        if ($State -ceq 'process_started') {
            $next.attempts[$index].process_started_at = [DateTimeOffset]::UtcNow.ToString('o')
            $family = [string]$next.attempts[$index].family
            $next.launcher_processes_started.total = [int64]$next.launcher_processes_started.total + 1
            $next.launcher_processes_started.provider_family.$family = [int64]$next.launcher_processes_started.provider_family.$family + 1
        }
        if ($State -cin @('succeeded', 'failed', 'skipped')) {
            $next.attempts[$index].completed_at = [DateTimeOffset]::UtcNow.ToString('o')
        }
        Assert-CalibrationPilotResultContract -Context $Context -Result $next -SkipPersistedResultMatch
        Write-CalibrationAtomicResultJson -Path $Context.result_path -Value $next -AllowedRunRoot $Context.run_root
        $Context.result = $next
    } finally { [Threading.Monitor]::Exit($syncRoot) }
}

function New-CalibrationPilotSlotClaim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][object]$Ordinal,
        [Parameter(Mandatory)][object]$Identity
    )
    if (-not ($Ordinal -is [byte] -or $Ordinal -is [int16] -or $Ordinal -is [int32] -or $Ordinal -is [int64]) -or
        [int64]$Ordinal -lt 1 -or [int64]$Ordinal -gt 3) { throw 'pilot_slot_ordinal_invalid' }
    $syncRoot = Get-CalibrationPilotSyncRoot -Context $Context
    [Threading.Monitor]::Enter($syncRoot)
    try {
        Assert-CalibrationPilotContext -Context $Context
        Assert-CalibrationPilotResultContract -Context $Context -Result $Context.result
        if ($Context.result.run_state -cne 'running') { throw 'pilot_slot_run_not_running' }
        $index = [int]$Ordinal - 1
        $expected = $Context.plan.roles[$index]
        Assert-CalibrationExactProperties -Value $Identity -Names @(
            'ordinal', 'role', 'family', 'launcher', 'route_id', 'configuration_id', 'model', 'effort'
        ) -ErrorCode 'pilot_slot_identity_invalid'
        if (-not (Test-CalibrationPilotOrdinal $Identity.ordinal ([int]$Ordinal))) { throw 'pilot_slot_identity_invalid' }
        foreach ($name in @('role', 'family', 'launcher', 'route_id', 'configuration_id', 'model', 'effort')) {
            if ($Identity.$name -isnot [string] -or $Identity.$name -cne $expected.$name) { throw 'pilot_slot_identity_invalid' }
        }
        $counts = Get-CalibrationPilotClaimCount -Context $Context -Result $Context.result
        $nextOrdinal = [int]$counts.total + 1
        if ([int]$Ordinal -ne $nextOrdinal) { throw 'pilot_slot_not_next' }
        if ([int64]$Context.plan.limits.application_retries -ne 0 -or
            [int64]$counts.total -ge [int64]$Context.plan.limits.total -or
            [int64]$counts.provider_family.($expected.family) -ge [int64]$Context.plan.limits.provider_family.($expected.family) -or
            $Context.result.attempts[$index].state -cne 'planned') { throw 'pilot_slot_limit_reached' }
        for ($previous = 0; $previous -lt $index; $previous++) {
            $previousPath = Join-Path $Context.claims_path $script:PilotClaimFileNames[$previous]
            if ($Context.result.attempts[$previous].state -ceq 'failed') { throw 'pilot_slot_prior_attempt_failed' }
            if (-not (Test-Path -LiteralPath $previousPath -PathType Leaf) -or
                $Context.result.attempts[$previous].state -cne 'succeeded') {
                throw 'pilot_slot_previous_incomplete'
            }
        }
        Invoke-CalibrationPilotBeforeSlotClaimHook -Context $Context -Ordinal ([int]$Ordinal)
        Assert-CalibrationPilotResultContract -Context $Context -Result $Context.result
        if ($Context.result.run_state -cne 'running') { throw 'pilot_slot_run_not_running' }
        $claimedAt = [DateTimeOffset]::UtcNow.ToString('o')
        $claimValue = [pscustomobject][ordered]@{
            run_id = $Context.run_id
            ordinal = $expected.ordinal
            role = [string]$expected.role
            family = [string]$expected.family
            launcher = [string]$expected.launcher
            route_id = [string]$expected.route_id
            configuration_id = [string]$expected.configuration_id
            model = [string]$expected.model
            effort = [string]$expected.effort
            claimed_at = $claimedAt
        }
        $claimPath = Join-Path $Context.claims_path $script:PilotClaimFileNames[$index]
        Write-CalibrationPilotClaimCreateNewJson -Path $claimPath -Value $claimValue -AllowedRunRoot $Context.run_root
        try {
            Invoke-CalibrationPilotAfterSlotClaimHook -Context $Context -Ordinal ([int]$Ordinal)
            Assert-CalibrationPilotResultContract -Context $Context -Result $Context.result -SkipClaimCounterCheck
            $next = Copy-CalibrationJsonValue $Context.result
            $next.attempts[$index].state = 'slot_reserved'
            $next.attempts[$index].slot_claimed_at = $claimedAt
            $next.slots_consumed.total = [int64]$next.slots_consumed.total + 1
            $next.slots_consumed.provider_family.($expected.family) = [int64]$next.slots_consumed.provider_family.($expected.family) + 1
            Assert-CalibrationPilotResultContract -Context $Context -Result $next -SkipClaimCounterCheck -SkipPersistedResultMatch
            Write-CalibrationAtomicResultJson -Path $Context.result_path -Value $next -AllowedRunRoot $Context.run_root
            $Context.result = $next
            $null = Get-CalibrationPilotClaimCount -Context $Context -Result $next
            return [pscustomobject][ordered]@{ claim_path = $claimPath; ordinal = $expected.ordinal; family = [string]$expected.family }
        } catch {
            throw 'pilot_claim_persistence_indeterminate'
        }
    } finally { [Threading.Monitor]::Exit($syncRoot) }
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
