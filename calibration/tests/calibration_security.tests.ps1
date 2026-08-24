$ErrorActionPreference = 'Stop'

$script:Failures = [Collections.Generic.List[string]]::new()
$calibrationRoot = Split-Path -Parent $PSScriptRoot
$projectRoot = Split-Path -Parent $calibrationRoot
$implementationPath = Join-Path $calibrationRoot 'run_calibration.ps1'
$setPath = Join-Path $calibrationRoot 'calibration-set-v1.json'
$rubricsRoot = Join-Path $calibrationRoot 'rubrics'
$resultsRoot = Join-Path $calibrationRoot 'results'

function Assert-True {
    param([bool]$Condition, [string]$Message = 'Expected condition to be true.')
    if (-not $Condition) { throw $Message }
}

function Assert-False {
    param([bool]$Condition, [string]$Message = 'Expected condition to be false.')
    if ($Condition) { throw $Message }
}

function Assert-Equal {
    param([AllowNull()][object]$Actual, [AllowNull()][object]$Expected)
    if ($Actual -ne $Expected) { throw "Expected '$Expected' but got '$Actual'." }
}

function Invoke-Assertion {
    param([string]$Name, [scriptblock]$Test)
    try {
        & $Test
        Write-Host "PASS $Name"
    } catch {
        $script:Failures.Add("FAIL ${Name}: $($_.Exception.Message)")
    }
}

function Get-RecursiveKeysAndStrings {
    param([AllowNull()][object]$Value)
    $found = [Collections.Generic.List[string]]::new()
    function Visit-Value {
        param([AllowNull()][object]$Current)
        if ($null -eq $Current) { return }
        if ($Current -is [string]) { $found.Add([string]$Current); return }
        if ($Current -is [Collections.IDictionary]) {
            foreach ($key in $Current.Keys) {
                $found.Add([string]$key)
                Visit-Value $Current[$key]
            }
            return
        }
        if ($Current -is [Collections.IEnumerable] -and $Current -isnot [string]) {
            foreach ($item in $Current) { Visit-Value $item }
            return
        }
        foreach ($property in $Current.PSObject.Properties) {
            $found.Add([string]$property.Name)
            Visit-Value $property.Value
        }
    }
    Visit-Value $Value
    return @($found)
}

function Remove-TestPath {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
}

. $implementationPath

Invoke-Assertion 'judge payload allowlist preserves ordinary text while hiding exact identities and identity keys' {
    $prompt = [pscustomobject]@{
        id = 'identity-test-v1'
        version = '1.0.0'
        request = [pscustomobject]@{ request_text = 'Explain workflow strategy version 1.0 at price 1.' }
    }
    $rubric = [pscustomobject]@{
        id = 'identity-rubric-v1'
        version = '1.0.0'
        criteria = @('Preserve workflow strategy and version 1.0.')
        nested = [pscustomobject]@{
            model = 'gpt-5.6-sol'
            provider = 'openai'
            candidate_id = 'gpt-5.6-sol__max'
        }
    }
    $identity = [pscustomobject]@{
        model = 'gpt-5.6-sol'
        provider = 'openai'
        family = 'openai'
        tool = 'agy'
        effort = 'low'
        price = '1'
        latency = '1'
        profile_id = 'gpt-5.6-sol__max'
        candidate_id = 'gpt-5.6-sol__max'
    }
    $payload = New-CalibrationJudgePayload -Prompt $prompt -Rubric $rubric `
        -ResponseText 'A workflow strategy in version 1.0 costs price 1. Exact IDs: gpt-5.6-sol__max, gpt-5.6-sol, openai, agy, low.' `
        -IdentityMetadata $identity
    $json = $payload | ConvertTo-Json -Depth 30 -Compress
    Assert-True $json.Contains('workflow', [StringComparison]::Ordinal)
    Assert-True $json.Contains('strategy', [StringComparison]::Ordinal)
    Assert-True $json.Contains('1.0', [StringComparison]::Ordinal)
    Assert-True $json.Contains('price 1', [StringComparison]::Ordinal)
    foreach ($forbidden in @('gpt-5.6-sol__max', 'gpt-5.6-sol', 'openai')) {
        Assert-False $json.Contains($forbidden, [StringComparison]::OrdinalIgnoreCase) "Identity '$forbidden' leaked."
    }
    Assert-Equal @($payload.evaluation_guide.PSObject.Properties.Name).Count 3
    $normalizedKeys = @(Get-RecursiveKeysAndStrings $payload | ForEach-Object { ([string]$_ -replace '[^A-Za-z0-9]', '').ToLowerInvariant() })
    foreach ($key in @('model', 'provider', 'family', 'tool', 'launcher', 'effort', 'price', 'latency', 'profileid', 'candidateid', 'configurationid')) {
        Assert-False ($normalizedKeys -ccontains $key) "Identity key '$key' leaked recursively."
    }
}

Invoke-Assertion 'Task9-local sanitizer redacts credential values text probes and environment containers recursively' {
    $probe = [pscustomobject]@{
        OPENAI_API_KEY = 'openai-secret-value'
        nested = [pscustomobject]@{
            AnthropicToken = 'anthropic-secret-value'
            google_api_key = 'google-secret-value'
            password = 'password-secret-value'
            safe = 'workflow strategy version 1.0'
        }
        environment = [pscustomobject]@{ PATH = 'private-path'; USERPROFILE = 'private-profile' }
        text = @'
{"OPENAI_API_KEY":"json-openai-secret"}
$env:ANTHROPIC_API_KEY = 'powershell-anthropic-secret'
GOOGLE_API_KEY=env-google-secret
Authorization: Bearer bearer-secret-value
Authorization: Basic basic-secret-value
token: generic-token-secret
sk-proj-providersecret123
sk-ant-providersecret456
AIzaGoogleProviderSecret789
'@
    }
    $safe = Copy-CalibrationCredentialSafeValue -Value $probe
    $json = $safe | ConvertTo-Json -Depth 30 -Compress
    foreach ($secret in @(
        'openai-secret-value', 'anthropic-secret-value', 'google-secret-value',
        'password-secret-value', 'private-path', 'private-profile', 'json-openai-secret',
        'powershell-anthropic-secret', 'env-google-secret', 'bearer-secret-value',
        'basic-secret-value', 'generic-token-secret', 'providersecret123',
        'providersecret456', 'GoogleProviderSecret789'
    )) {
        Assert-False $json.Contains($secret, [StringComparison]::Ordinal) "Secret probe '$secret' was persisted."
    }
    Assert-True $json.Contains('workflow strategy version 1.0', [StringComparison]::Ordinal)
    Assert-True $json.Contains('[credential redacted]', [StringComparison]::Ordinal)
    Assert-Equal $safe.OPENAI_API_KEY '[credential redacted]'
    Assert-Equal $safe.environment '[environment redacted]'

    $environmentDump = "PATH=C:\private-bin`nUSERPROFILE=C:\private-user`nTEMP=C:\private-temp"
    Assert-Equal (ConvertTo-CalibrationCredentialSafeText $environmentDump) '[environment redacted]'
}

Invoke-Assertion 'judge rationale must be a non-empty string before conversion' {
    foreach ($badRationale in @(7, $true, [pscustomobject]@{ text = 'looks valid' }, @('valid-looking'))) {
        $threw = $false
        try {
            ConvertTo-CalibrationJudgeDecision -Value ([pscustomobject]@{ decision = 'pass'; rationale = $badRationale }) `
                -JudgeProfileId 'claude-opus-5__max' | Out-Null
        } catch { $threw = $true }
        Assert-True $threw 'A non-string rationale was accepted.'
    }
}

Invoke-Assertion 'verified-answer grader fails closed on explicit negation of otherwise matching evidence' {
    $prompt = @((Import-CalibrationSet -Path $setPath -RubricsRoot $rubricsRoot).set.prompts |
        Where-Object { $_.id -ceq 'math-low-mathematics-v1' })[0]
    $result = Invoke-CalibrationDeterministicGrader -Prompt $prompt `
        -ResponseText 'It is not true that x = 5. The stated method says subtract 5 and divide by 3.'
    Assert-Equal $result.outcome 'fail'
    Assert-True @($result.checks | Where-Object { $_.detail -ceq 'negated' }).Count
}

Invoke-Assertion 'default executable grading never launches local Python and dangerous programs require an approved executor' {
    $prompt = @((Import-CalibrationSet -Path $setPath -RubricsRoot $rubricsRoot).set.prompts |
        Where-Object { $_.id -ceq 'coding-low-computer-science-v1' })[0]
    $programs = @(
        "def sum_even(values):`n    return list(range(10**12))",
        "def sum_even(values):`n    return [0] * 1000000000000",
        "def sum_even(values):`n    return 2 ** 1000000000",
        "def sum_even(values):`n    return 1 << 1000000000",
        "def sum_even(values):`n    return sum_even(values)",
        "def sum_even(values):`n    while True:`n        pass"
    )
    $started = [Diagnostics.Stopwatch]::StartNew()
    foreach ($program in $programs) {
        $result = Invoke-CalibrationDeterministicGrader -Prompt $prompt -ResponseText $program `
            -PythonExecutable 'definitely-missing-and-must-not-be-resolved'
        Assert-Equal $result.outcome 'review_required'
        Assert-Equal $result.reason_code 'sandbox_unavailable'
    }
    $started.Stop()
    Assert-True ($started.ElapsedMilliseconds -lt 2000) 'Unsafe programs were not rejected promptly.'
}

Invoke-Assertion 'an atomic run claim rejects collisions before artifact writes' {
    $runId = 'claim-test-{0}' -f [guid]::NewGuid().ToString('N')
    $runDirectory = Join-Path $resultsRoot $runId
    $claim = $null
    try {
        $claim = New-CalibrationRunClaim -ResultsRoot $resultsRoot -RunId $runId
        Assert-True (Test-Path -LiteralPath $claim.claim_path -PathType Leaf)
        $threw = $false
        try { New-CalibrationRunClaim -ResultsRoot $resultsRoot -RunId $runId | Out-Null } catch { $threw = $true }
        Assert-True $threw 'A colliding run acquired the same claim.'
        Assert-False (Test-Path -LiteralPath (Join-Path $runDirectory 'review.json'))
    } finally {
        if ($null -ne $claim -and $null -ne $claim.stream) { $claim.stream.Dispose() }
        Remove-TestPath -Path $runDirectory
    }
}

Invoke-Assertion 'result path resolution and writes reject junction ancestors and descendants' {
    $junctionName = 'junction-test-{0}' -f [guid]::NewGuid().ToString('N')
    $junctionPath = Join-Path $resultsRoot $junctionName
    $outside = Join-Path ([IO.Path]::GetTempPath()) ('router-calibration-outside-{0}' -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $outside | Out-Null
    $junctionCreated = $false
    try {
        try {
            New-Item -ItemType Junction -Path $junctionPath -Target $outside -ErrorAction Stop | Out-Null
            $junctionCreated = $true
        } catch {
            Write-Host 'SKIP junction regression: privilege or filesystem support unavailable.'
            return
        }
        $threw = $false
        try { Resolve-CalibrationResultPath -ResultsRoot $junctionPath -RunId 'safe-run' | Out-Null } catch { $threw = $true }
        Assert-True $threw 'A reparse-point ResultsRoot was accepted.'

        $safeRun = 'write-boundary-{0}' -f [guid]::NewGuid().ToString('N')
        $safeRunDirectory = Join-Path $resultsRoot $safeRun
        New-Item -ItemType Directory -Path $safeRunDirectory | Out-Null
        $rawJunction = Join-Path $safeRunDirectory 'raw'
        New-Item -ItemType Junction -Path $rawJunction -Target $outside -ErrorAction Stop | Out-Null
        $outsideProbe = Join-Path $outside 'escape.json'
        $writeThrew = $false
        try {
            Write-CalibrationJsonFile -Path (Join-Path $rawJunction 'escape.json') `
                -Value ([pscustomobject]@{ safe = $true }) -AllowedRunRoot $safeRunDirectory
        } catch { $writeThrew = $true }
        Assert-True $writeThrew 'A write through a junction was accepted.'
        Assert-False (Test-Path -LiteralPath $outsideProbe)
        Remove-TestPath -Path $safeRunDirectory
    } finally {
        if ($junctionCreated -and (Test-Path -LiteralPath $junctionPath)) { Remove-Item -LiteralPath $junctionPath -Force }
        Remove-TestPath -Path $outside
    }
}

Invoke-Assertion 'per-item failures continue and final manifest explains candidate grader and both judge failures' {
    $runId = 'isolation-test-{0}' -f [guid]::NewGuid().ToString('N')
    $runDirectory = Join-Path $resultsRoot $runId
    try {
        $script:RouterCalls = 0
        $script:JudgeCalls = 0
        $script:GraderCalls = 0
        $script:LastPromptSeen = $false
        $router = {
            param($Request, $PromptDefinition)
            $script:RouterCalls++
            if ($PromptDefinition.id -ceq 'research-high-general-v1') { $script:LastPromptSeen = $true }
            if ($PromptDefinition.id -ceq 'general-low-biology-v1') {
                throw 'candidate failure OPENAI_API_KEY=candidate-secret-must-not-persist'
            }
            $answer = if ($PromptDefinition.id -ceq 'math-low-mathematics-v1') {
                'x = 5 subtract 5 divide by 3 OPENAI_API_KEY=grading-secret-must-stay-raw'
            } else { "answer-$($PromptDefinition.id)" }
            [pscustomobject]@{
                response = [pscustomobject]@{
                    status = 'completed'; configuration_id = 'gpt-5.6-sol__max'; provider = 'openai'
                    launcher = 'codex'; model = 'gpt-5.6-sol'; effort = 'max'; output = $answer
                    price = 1.25; latency = 12
                }
                trace = [pscustomobject]@{ effective_quality = 'strong' }
            }
        }
        $grader = {
            param($PromptDefinition, $ResponseText, $PythonExecutor, $PythonExecutable, $TimeoutMilliseconds)
            $script:GraderCalls++
            if ($PromptDefinition.id -ceq 'coding-low-computer-science-v1') {
                throw 'grader failure TOKEN=grader-secret-must-not-persist'
            }
            if ($PromptDefinition.id -ceq 'math-low-mathematics-v1') {
                Assert-True $ResponseText.Contains('grading-secret-must-stay-raw', [StringComparison]::Ordinal) `
                    'The grader received sanitized text instead of the original candidate response.'
                return [pscustomobject]@{ type = 'verified_answer'; outcome = 'fail'; reason_code = 'deterministic_check_failed'; checks = @() }
            }
            return [pscustomobject]@{ type = 'test'; outcome = 'pass'; reason_code = $null; checks = @() }
        }
        $judge = {
            param($JudgeProfileId, $JudgePayload, $PromptDefinition)
            $script:JudgeCalls++
            if ($PromptDefinition.id -ceq 'coding-medium-engineering-v1' -and
                $JudgeProfileId -ceq 'claude-opus-5__max') {
                throw 'first judge failure AUTHORIZATION=judge-one-secret'
            }
            if ($PromptDefinition.id -ceq 'coding-high-computer-science-v1' -and
                $JudgeProfileId -ceq 'gemini-3.7-flash-high__high') {
                throw 'second judge failure COOKIE=judge-two-secret'
            }
            [pscustomobject]@{ decision = 'pass'; rationale = 'rubric evidence is present' }
        }

        $result = Invoke-Calibration -Run -RunId $runId -ResultsRoot $resultsRoot `
            -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot `
            -RouterInvoker $router -GraderInvoker $grader -JudgeInvoker $judge
        Assert-Equal @($result.reviews).Count 24
        Assert-Equal $script:RouterCalls 24
        Assert-True $script:LastPromptSeen 'A later item did not run after earlier failures.'
        Assert-Equal $script:JudgeCalls 46
        $artifact = Get-Content -Raw -LiteralPath $result.artifact_path | ConvertFrom-Json -Depth 100
        Assert-Equal $artifact.summary.total 24
        Assert-Equal ($artifact.summary.completed + $artifact.summary.failed + $artifact.summary.review_required) 24
        Assert-Equal $artifact.summary.failed 4
        Assert-Equal $artifact.fatal_error $null
        foreach ($case in @(
            @('general-low-biology-v1', 'candidate_execution_failed'),
            @('coding-low-computer-science-v1', 'grader_execution_failed'),
            @('coding-medium-engineering-v1', 'judge_execution_failed'),
            @('coding-high-computer-science-v1', 'judge_execution_failed')
        )) {
            $review = @($artifact.reviews | Where-Object { $_.item_id -ceq $case[0] })[0]
            Assert-Equal $review.item_status 'failed'
            Assert-True (@($review.error_codes) -ccontains $case[1])
            Assert-True (Test-Path -LiteralPath (Join-Path $runDirectory $review.raw_response_file) -PathType Leaf)
            Assert-True (Test-Path -LiteralPath (Join-Path $runDirectory $review.raw_review_file) -PathType Leaf)
        }
        $firstJudgeReview = @($artifact.reviews | Where-Object { $_.item_id -ceq 'coding-medium-engineering-v1' })[0]
        $rawJudgeArtifact = Get-Content -Raw -LiteralPath (Join-Path $runDirectory $firstJudgeReview.raw_review_file) |
            ConvertFrom-Json -Depth 100
        Assert-Equal @($rawJudgeArtifact.raw_judge_outputs).Count 2
        $persisted = @(Get-ChildItem -LiteralPath $runDirectory -File -Recurse |
            ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName }) -join "`n"
        foreach ($secret in @('candidate-secret-must-not-persist', 'grader-secret-must-not-persist',
            'grading-secret-must-stay-raw', 'judge-one-secret', 'judge-two-secret')) {
            Assert-False $persisted.Contains($secret, [StringComparison]::Ordinal) "Failure output leaked '$secret'."
        }
    } finally {
        Remove-TestPath -Path $runDirectory
    }
}

if ($script:Failures.Count -gt 0) {
    $script:Failures | ForEach-Object { Write-Host $_ }
    exit 1
}

Write-Host 'All calibration security tests passed.'
