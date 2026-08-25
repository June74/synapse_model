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

function Assert-Throws {
    param([scriptblock]$Script, [AllowNull()][string]$ExpectedMessageFragment)
    $threw = $false
    $exception = $null
    try { & $Script } catch { $threw = $true; $exception = $_.Exception }
    if (-not $threw) { throw 'Expected script to throw.' }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedMessageFragment) -and
        $exception.Message.IndexOf($ExpectedMessageFragment, [StringComparison]::Ordinal) -lt 0) {
        throw "Expected error containing '$ExpectedMessageFragment' but got '$($exception.Message)'."
    }
    return $exception
}

function New-SecurityPilotLedgerInput {
    $leaf = 'pilot-ledger-security-{0}' -f [guid]::NewGuid().ToString('N')
    return [pscustomobject]@{
        results_root = Join-Path (Join-Path $calibrationRoot 'results') $leaf
        plan = Invoke-Calibration -Pilot -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot
    }
}

function Remove-SecurityPilotLedgerRoot {
    param([Parameter(Mandatory)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $boundary = [IO.Path]::GetFullPath((Join-Path $calibrationRoot 'results')).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    Assert-True ($fullPath.StartsWith(($boundary + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) `
        'Refusing to clean outside calibration/results.'
    Assert-True ([IO.Path]::GetFileName($fullPath) -match '^pilot-ledger-security-[0-9a-f]{32}$') `
        'Refusing to clean a root not owned by this security test.'
    if (Test-Path -LiteralPath $fullPath) { Remove-Item -LiteralPath $fullPath -Recurse -Force }
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

    $exactEnvironmentObject = '{"environment":{"PATH":"C:\\private-bin","USERPROFILE":"C:\\private-user"}}' |
        ConvertFrom-Json
    $safeEnvironmentObject = Copy-CalibrationCredentialSafeValue -Value $exactEnvironmentObject
    $safeEnvironmentJson = $safeEnvironmentObject | ConvertTo-Json -Depth 10 -Compress
    Assert-False $safeEnvironmentJson.Contains('C:\private-bin', [StringComparison]::Ordinal)
    Assert-False $safeEnvironmentJson.Contains('C:\private-user', [StringComparison]::Ordinal)

    $twoLineEnvironment = "Path=C:\private-bin`nUSERPROFILE=C:\private-user"
    $safeTwoLineEnvironment = ConvertTo-CalibrationCredentialSafeText $twoLineEnvironment
    Assert-False $safeTwoLineEnvironment.Contains('C:\private-bin', [StringComparison]::Ordinal)
    Assert-False $safeTwoLineEnvironment.Contains('C:\private-user', [StringComparison]::Ordinal)
    Assert-True (ConvertTo-CalibrationCredentialSafeText 'The PATH through this explanation remains ordinary prose.').Contains(
        'ordinary prose', [StringComparison]::Ordinal)
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

Invoke-Assertion 'pilot run plan and claim artifacts use create-new semantics and result replacement is isolated' {
    $caseData = New-SecurityPilotLedgerInput
    $context = $null
    try {
        $context = New-CalibrationPilotRun -ResultsRoot $caseData.results_root -RunId 'ledger-security-001' -Plan $caseData.plan
        $planHash = (Get-FileHash -LiteralPath $context.plan_path -Algorithm SHA256).Hash
        $resultHash = (Get-FileHash -LiteralPath $context.result_path -Algorithm SHA256).Hash

        $null = Assert-Throws {
            New-CalibrationPilotRun -ResultsRoot $caseData.results_root -RunId 'ledger-security-001' -Plan $caseData.plan | Out-Null
        } 'pilot_run_collision'
        $null = Assert-Throws {
            Write-CalibrationCreateNewJson -Path $context.plan_path -Value ([pscustomobject]@{ changed = $true }) `
                -AllowedRunRoot $context.run_root
        } 'pilot_create_new_collision'
        Assert-Equal (Get-FileHash -LiteralPath $context.plan_path -Algorithm SHA256).Hash $planHash

        Set-CalibrationPilotRunState -Context $context -State 'preflight_passed'
        Assert-False ((Get-FileHash -LiteralPath $context.result_path -Algorithm SHA256).Hash -ceq $resultHash)
        Assert-Equal (Get-FileHash -LiteralPath $context.plan_path -Algorithm SHA256).Hash $planHash
        Assert-Equal (Get-Item -LiteralPath $context.claim_path -Force).Length 0

        $tempPath = Join-Path $context.run_root ('.result-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($tempPath, 'owned collision probe', [Text.UTF8Encoding]::new($false))
        $before = (Get-FileHash -LiteralPath $context.result_path -Algorithm SHA256).Hash
        $null = Assert-Throws {
            Write-CalibrationAtomicResultJson -Path $context.result_path -Value $context.result `
                -AllowedRunRoot $context.run_root -TemporaryPath $tempPath
        } 'pilot_result_temp_collision'
        Assert-Equal (Get-FileHash -LiteralPath $context.result_path -Algorithm SHA256).Hash $before
        Assert-Equal (Get-Content -Raw -LiteralPath $tempPath) 'owned collision probe'
        Remove-Item -LiteralPath $tempPath -Force
    } finally {
        if ($null -ne $context) { Close-CalibrationPilotRun -Context $context }
        Remove-SecurityPilotLedgerRoot -Path $caseData.results_root
    }
}

Invoke-Assertion 'pilot run accepts the calibration results boundary as its explicit root' {
    $plan = Invoke-Calibration -Pilot -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot
    $runId = 'ledger-default-{0}' -f [guid]::NewGuid().ToString('N')
    $runRoot = Join-Path $resultsRoot $runId
    $context = $null
    try {
        $context = New-CalibrationPilotRun -ResultsRoot $resultsRoot -RunId $runId -Plan $plan
        Assert-Equal $context.run_root ([IO.Path]::GetFullPath($runRoot))
    } finally {
        if ($null -ne $context) { Close-CalibrationPilotRun -Context $context }
        $fullRunRoot = [IO.Path]::GetFullPath($runRoot)
        $fullBoundary = [IO.Path]::GetFullPath($resultsRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
        Assert-True ($fullRunRoot.StartsWith(($fullBoundary + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase))
        Assert-True ([IO.Path]::GetFileName($fullRunRoot) -match '^ledger-default-[0-9a-f]{32}$')
        if (Test-Path -LiteralPath $fullRunRoot) { Remove-Item -LiteralPath $fullRunRoot -Recurse -Force }
    }
}

Invoke-Assertion 'pilot context detects immutable plan drift before any result replacement' {
    $caseData = New-SecurityPilotLedgerInput
    $context = $null
    try {
        $badPlan = $caseData.plan | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
        $badPlan.source_hashes | Add-Member -NotePropertyName raw_source -NotePropertyValue ('a' * 64)
        $null = Assert-Throws {
            New-CalibrationPilotRun -ResultsRoot $caseData.results_root -RunId 'ledger-security-bad-plan' -Plan $badPlan | Out-Null
        } 'pilot_plan_contract_invalid'
        Assert-False (Test-Path -LiteralPath $caseData.results_root)

        $context = New-CalibrationPilotRun -ResultsRoot $caseData.results_root -RunId 'ledger-security-005' -Plan $caseData.plan
        $before = (Get-FileHash -LiteralPath $context.result_path -Algorithm SHA256).Hash
        $context.plan.roles[0].family = 'openai'
        $null = Assert-Throws {
            Set-CalibrationPilotRunState -Context $context -State 'preflight_passed'
        } 'pilot_run_context_invalid'
        Assert-Equal (Get-FileHash -LiteralPath $context.result_path -Algorithm SHA256).Hash $before
    } finally {
        if ($null -ne $context) { Close-CalibrationPilotRun -Context $context }
        Remove-SecurityPilotLedgerRoot -Path $caseData.results_root
    }
}

Invoke-Assertion 'pilot context rejects a released run lock and stale persisted result' {
    $caseData = New-SecurityPilotLedgerInput
    $context = $null
    try {
        $context = New-CalibrationPilotRun -ResultsRoot $caseData.results_root -RunId 'ledger-security-006' -Plan $caseData.plan
        $context.claim_stream.Dispose()
        $null = Assert-Throws {
            Set-CalibrationPilotRunState -Context $context -State 'preflight_passed'
        } 'pilot_run_context_invalid'
        Close-CalibrationPilotRun -Context $context
        $context = $null

        $context = New-CalibrationPilotRun -ResultsRoot $caseData.results_root -RunId 'ledger-security-007' -Plan $caseData.plan
        $persisted = Get-Content -Raw -LiteralPath $context.result_path | ConvertFrom-Json -Depth 100
        $persisted.run_state = 'stopped'
        $persisted.stop_reason = 'pilot_stopped'
        $persisted.finished_at = [DateTimeOffset]::UtcNow.ToString('o')
        $persisted | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $context.result_path -Encoding utf8NoBOM
        $before = (Get-FileHash -LiteralPath $context.result_path -Algorithm SHA256).Hash
        $null = Assert-Throws {
            Set-CalibrationPilotRunState -Context $context -State 'preflight_passed'
        } 'pilot_result_contract_invalid'
        Assert-Equal (Get-FileHash -LiteralPath $context.result_path -Algorithm SHA256).Hash $before
    } finally {
        if ($null -ne $context) { Close-CalibrationPilotRun -Context $context }
        Remove-SecurityPilotLedgerRoot -Path $caseData.results_root
    }
}

Invoke-Assertion 'pilot ledger rejects unsafe roots run ids writes and counter drift' {
    $caseData = New-SecurityPilotLedgerInput
    $context = $null
    try {
        foreach ($unsafeRunId in @('../escape', '..', 'C:\absolute', 'bad/name', 'bad\name')) {
            $null = Assert-Throws {
                New-CalibrationPilotRun -ResultsRoot $caseData.results_root -RunId $unsafeRunId -Plan $caseData.plan | Out-Null
            } 'pilot_run_id_invalid'
        }
        $outsideRoot = Join-Path ([IO.Path]::GetTempPath()) ('pilot-ledger-outside-{0}' -f [guid]::NewGuid().ToString('N'))
        $null = Assert-Throws {
            New-CalibrationPilotRun -ResultsRoot $outsideRoot -RunId 'ledger-security-outside' -Plan $caseData.plan | Out-Null
        } 'pilot_results_root_invalid'
        Assert-False (Test-Path -LiteralPath $outsideRoot)

        $context = New-CalibrationPilotRun -ResultsRoot $caseData.results_root -RunId 'ledger-security-002' -Plan $caseData.plan
        $outsideFile = Join-Path ([IO.Path]::GetTempPath()) ('pilot-ledger-outside-{0}.json' -f [guid]::NewGuid().ToString('N'))
        $null = Assert-Throws {
            Write-CalibrationCreateNewJson -Path $outsideFile -Value ([pscustomobject]@{ safe = $true }) `
                -AllowedRunRoot $context.run_root
        } 'Calibration write path escaped'
        Assert-False (Test-Path -LiteralPath $outsideFile)

        Set-CalibrationPilotRunState -Context $context -State 'preflight_passed'
        Set-CalibrationPilotRunState -Context $context -State 'running'
        $claim = New-CalibrationPilotSlotClaim -Context $context -Ordinal 1 -Identity $caseData.plan.roles[0]
        $context.result.slots_consumed.total = 0
        $before = (Get-FileHash -LiteralPath $context.result_path -Algorithm SHA256).Hash
        $null = Assert-Throws { Get-CalibrationPilotClaimCount -Context $context | Out-Null } 'pilot_claim_counter_mismatch'
        Assert-Equal (Get-FileHash -LiteralPath $context.result_path -Algorithm SHA256).Hash $before
        Assert-True (Test-Path -LiteralPath $claim.claim_path -PathType Leaf)
    } finally {
        if ($null -ne $context) { Close-CalibrationPilotRun -Context $context }
        Remove-SecurityPilotLedgerRoot -Path $caseData.results_root
    }
}

Invoke-Assertion 'pilot claim persists before an indeterminate result update and is never refunded' {
    $caseData = New-SecurityPilotLedgerInput
    $context = $null
    $originalWriter = $null
    try {
        $context = New-CalibrationPilotRun -ResultsRoot $caseData.results_root -RunId 'ledger-security-004' -Plan $caseData.plan
        Set-CalibrationPilotRunState -Context $context -State 'preflight_passed'
        Set-CalibrationPilotRunState -Context $context -State 'running'
        $originalWriter = (Get-Command -Name Write-CalibrationAtomicResultJson -CommandType Function -ErrorAction Stop).ScriptBlock
        Set-Item -Path Function:\Write-CalibrationAtomicResultJson -Value { throw 'forced result persistence failure' }
        $null = Assert-Throws {
            New-CalibrationPilotSlotClaim -Context $context -Ordinal 1 -Identity $caseData.plan.roles[0] | Out-Null
        } 'pilot_claim_persistence_indeterminate'
        Set-Item -Path Function:\Write-CalibrationAtomicResultJson -Value $originalWriter
        $originalWriter = $null

        $claimPath = Join-Path $context.claims_path '01-google-candidate.claim'
        Assert-True (Test-Path -LiteralPath $claimPath -PathType Leaf) 'The non-refundable claim was removed after persistence uncertainty.'
        Assert-Equal $context.result.attempts[0].state 'planned'
        Assert-Equal $context.result.slots_consumed.total 0
        $persisted = Get-Content -Raw -LiteralPath $context.result_path | ConvertFrom-Json -Depth 100
        Assert-Equal $persisted.attempts[0].state 'planned'
        Assert-Equal $persisted.slots_consumed.total 0
        $null = Assert-Throws { Get-CalibrationPilotClaimCount -Context $context | Out-Null } 'pilot_claim_counter_mismatch'
        Assert-True (Test-Path -LiteralPath $claimPath -PathType Leaf) 'Claim-count verification refunded the claim.'
    } finally {
        if ($null -ne $originalWriter) { Set-Item -Path Function:\Write-CalibrationAtomicResultJson -Value $originalWriter }
        if ($null -ne $context) { Close-CalibrationPilotRun -Context $context }
        Remove-SecurityPilotLedgerRoot -Path $caseData.results_root
    }
}

Invoke-Assertion 'pilot ledger rejects reparse ancestors and descendants without outside writes' {
    $caseData = New-SecurityPilotLedgerInput
    $outside = Join-Path ([IO.Path]::GetTempPath()) ('pilot-ledger-junction-outside-{0}' -f [guid]::NewGuid().ToString('N'))
    $context = $null
    New-Item -ItemType Directory -Path $outside | Out-Null
    try {
        New-Item -ItemType Directory -Path $caseData.results_root | Out-Null
        $ancestorJunction = Join-Path $caseData.results_root 'ancestor-link'
        try {
            New-Item -ItemType Junction -Path $ancestorJunction -Target $outside -ErrorAction Stop | Out-Null
        } catch {
            Write-Host 'SKIP pilot ledger junction regression: privilege or filesystem support unavailable.'
            return
        }
        $null = Assert-Throws {
            New-CalibrationPilotRun -ResultsRoot $ancestorJunction -RunId 'ledger-security-junction' -Plan $caseData.plan | Out-Null
        } 'reparse'
        Assert-Equal @(Get-ChildItem -LiteralPath $outside -Force).Count 0

        Remove-Item -LiteralPath $ancestorJunction -Force
        $context = New-CalibrationPilotRun -ResultsRoot $caseData.results_root -RunId 'ledger-security-003' -Plan $caseData.plan
        Remove-Item -LiteralPath $context.raw_path -Force
        New-Item -ItemType Junction -Path $context.raw_path -Target $outside -ErrorAction Stop | Out-Null
        $null = Assert-Throws {
            Write-CalibrationCreateNewJson -Path (Join-Path $context.raw_path 'escape.json') `
                -Value ([pscustomobject]@{ safe = $true }) -AllowedRunRoot $context.run_root
        } 'reparse'
        Assert-Equal @(Get-ChildItem -LiteralPath $outside -Force).Count 0
    } finally {
        if ($null -ne $context) { Close-CalibrationPilotRun -Context $context }
        Remove-SecurityPilotLedgerRoot -Path $caseData.results_root
        if (Test-Path -LiteralPath $outside) { Remove-Item -LiteralPath $outside -Recurse -Force }
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
            $answer = if ($PromptDefinition.id -ceq 'general-medium-business-v1') {
                '{"environment":{"PATH":"C:\\private-bin","USERPROFILE":"C:\\private-user"}}'
            } elseif ($PromptDefinition.id -ceq 'math-low-mathematics-v1') {
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
            if ($PromptDefinition.id -ceq 'general-medium-business-v1') {
                return [pscustomobject]@{
                    decision = 'pass'
                    rationale = "Path=C:\private-bin`nUSERPROFILE=C:\private-user"
                }
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
        $environmentReview = @($artifact.reviews | Where-Object { $_.item_id -ceq 'general-medium-business-v1' })[0]
        $environmentCandidateArtifact = Get-Content -Raw -LiteralPath `
            (Join-Path $runDirectory $environmentReview.raw_response_file)
        $environmentJudgeArtifact = Get-Content -Raw -LiteralPath `
            (Join-Path $runDirectory $environmentReview.raw_review_file)
        foreach ($privateValue in @('C:\private-bin', 'C:\private-user')) {
            Assert-False $environmentCandidateArtifact.Contains($privateValue, [StringComparison]::Ordinal) `
                "Candidate artifact leaked '$privateValue'."
            Assert-False $environmentJudgeArtifact.Contains($privateValue, [StringComparison]::Ordinal) `
                "Judge artifact leaked '$privateValue'."
        }
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

Invoke-Assertion 'route-only outer failure writes a safe partial failure manifest without execution' {
    $runId = 'route-failure-test-{0}' -f [guid]::NewGuid().ToString('N')
    $runDirectory = Join-Path $resultsRoot $runId
    $artifactPath = Join-Path $runDirectory 'route-plan.json'
    $profileHashesBefore = @(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'profiles') -File -Recurse |
        Sort-Object FullName | ForEach-Object { '{0}|{1}' -f $_.FullName, (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash })
    try {
        $script:RouteFailureCalls = 0
        $script:RouteFailureCandidateCalls = 0
        $script:RouteFailureJudgeCalls = 0
        $routeInvoker = {
            param($Request, $PromptDefinition)
            $script:RouteFailureCalls++
            if ($script:RouteFailureCalls -eq 2) {
                throw 'route failed OPENAI_API_KEY=route-private-secret C:\private-route-path'
            }
            [pscustomobject]@{
                status = 'selected'
                selected_route = [pscustomobject]@{
                    configuration_id = 'gpt-5.6-sol__max'
                    launcher = 'codex'
                    model = 'gpt-5.6-sol'
                    effort = 'max'
                }
            }
        }
        $candidateSpy = { $script:RouteFailureCandidateCalls++; throw 'candidate execution was called' }
        $judgeSpy = { $script:RouteFailureJudgeCalls++; throw 'judge execution was called' }
        $threw = $false
        try {
            Invoke-Calibration -Route -RunId $runId -ResultsRoot $resultsRoot `
                -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot `
                -RouteInvoker $routeInvoker -RouterInvoker $candidateSpy -JudgeInvoker $judgeSpy | Out-Null
        } catch { $threw = $true }
        Assert-True $threw 'Route-only failure did not propagate to the caller.'
        Assert-Equal $script:RouteFailureCalls 2
        Assert-Equal $script:RouteFailureCandidateCalls 0
        Assert-Equal $script:RouteFailureJudgeCalls 0
        Assert-True (Test-Path -LiteralPath $artifactPath -PathType Leaf) 'Route failure manifest was not written.'
        $manifest = Get-Content -Raw -LiteralPath $artifactPath | ConvertFrom-Json -Depth 100
        Assert-Equal $manifest.mode 'route'
        Assert-Equal $manifest.status 'failed'
        Assert-Equal $manifest.error.code 'calibration_route_failed'
        Assert-Equal $manifest.provider_calls 0
        Assert-Equal $manifest.completed_count 1
        Assert-Equal @($manifest.routes).Count 1
        Assert-Equal ([IO.Path]::GetFullPath($artifactPath)) ([IO.Path]::GetFullPath((Join-Path $resultsRoot "$runId\route-plan.json")))
        $persisted = Get-Content -Raw -LiteralPath $artifactPath
        Assert-False $persisted.Contains('route-private-secret', [StringComparison]::Ordinal)
        Assert-False $persisted.Contains('C:\private-route-path', [StringComparison]::Ordinal)
        $profileHashesAfter = @(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'profiles') -File -Recurse |
            Sort-Object FullName | ForEach-Object { '{0}|{1}' -f $_.FullName, (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash })
        Assert-Equal ($profileHashesAfter -join "`n") ($profileHashesBefore -join "`n")
    } finally {
        Remove-TestPath -Path $runDirectory
    }
}

if ($script:Failures.Count -gt 0) {
    $script:Failures | ForEach-Object { Write-Host $_ }
    exit 1
}

Write-Host 'All calibration security tests passed.'
