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

function Assert-SequenceEqual {
    param([object[]]$Actual, [object[]]$Expected)
    Assert-Equal $Actual.Count $Expected.Count
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        Assert-Equal $Actual[$index] $Expected[$index]
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

function Get-SecurityPilotRunListing {
    param([Parameter(Mandatory)][string]$RunRoot)
    return @(
        Get-ChildItem -LiteralPath $RunRoot -Force -Recurse |
        Sort-Object FullName |
        ForEach-Object {
            $relative = $_.FullName.Substring($RunRoot.Length)
            if ($_.PSIsContainer) { "D|$relative" }
            elseif ($_.Name -ceq '.run.claim') { "F|$relative|$($_.Length)|held" }
            else { "F|$relative|$($_.Length)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }
        }
    )
}

function Get-RecursiveKeysAndStrings {
    param([AllowNull()][object]$Value)
    $found = [Collections.Generic.List[string]]::new()
    function Visit-Value {
        param([AllowNull()][object]$Current)
        if ($null -eq $Current) { return }
        if ($Current -is [string]) { $found.Add([string]$Current); return }
        if ($Current -is [ValueType]) { return }
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

function New-SecurityPilotCommand {
    param([Parameter(Mandatory)][object]$Candidate, [Parameter(Mandatory)][string]$Prompt)
    return [pscustomobject]@{
        executable = [string]$Candidate.tool
        arguments = @()
        prompt = $Prompt
        tool = [string]$Candidate.tool
        route_id = [string]$Candidate.route_id
        working_directory = $projectRoot
    }
}

function New-SecurityPilotExecution {
    param(
        [Parameter(Mandatory)][object]$Candidate,
        [Parameter(Mandatory)][string]$RunId,
        [AllowNull()][string]$Answer,
        [AllowNull()][AllowEmptyString()][string]$FailureCode,
        [bool]$ProcessStarted = $true,
        [string[]]$Sentinels = @()
    )
    $hasFailure = -not [string]::IsNullOrEmpty($FailureCode)
    $process = if ($ProcessStarted) {
        [pscustomobject]@{
            exit_code = if (-not $hasFailure) { 0 } else { 17 }
            duration_ms = 1
            timed_out = ($FailureCode -ceq 'timeout')
            cleanup_failed = ($FailureCode -ceq 'cleanup_failed')
            cleanup_status = if ($FailureCode -ceq 'timeout') {
                'timeout_cleanup_complete'
            } elseif ($FailureCode -ceq 'cleanup_failed') {
                'timeout_cleanup_failed'
            } else { 'not_required' }
            process_exited = $true
        }
    } else { $null }
    return [pscustomobject][ordered]@{
        run_id = $RunId
        candidate = $Candidate
        process_started = $ProcessStarted
        process = $process
        canonical = if (-not $hasFailure) {
            [pscustomobject]@{ status = 'success'; answer = $Answer; error = $null }
        } else { $null }
        failure = if (-not $hasFailure) { $null } else { 'arbitrary unsafe failure text' }
        failure_code = if ($hasFailure) { $FailureCode } else { $null }
        diagnostic_note = if (-not $hasFailure) { 'completed' } else { 'unsafe diagnostic' }
        usage = [pscustomobject][ordered]@{
            actual_input_tokens = 21
            visible_output_tokens = 5
            reasoning_tokens = 2
            complete = $true
            raw_provider_usage = @($Sentinels) -join '|'
        }
        unsafe_environment = @($Sentinels)
        unsafe_arguments = @($Sentinels)
        stdout = @($Sentinels) -join '|'
        stderr = @($Sentinels) -join '|'
        provider_events = @($Sentinels)
        exception = @($Sentinels) -join '|'
    }
}

function Invoke-SecurityPilotFailureCase {
    param(
        [Parameter(Mandatory)][ValidateSet('candidate', 'judge_1', 'judge_2')][string]$FailureRole,
        [Parameter(Mandatory)][AllowEmptyString()][string]$FailureCode,
        [ValidateSet('confirmed_start', 'preclaim_throw', 'postclaim_throw')][string]$FailureMode = 'confirmed_start',
        [string[]]$Sentinels = @(),
        [scriptblock]$ArtifactWriter,
        [scriptblock]$EnvelopeMutation,
        [scriptblock]$GraderMutation,
        [scriptblock]$WrapperMutation,
        [switch]$SwallowGuardFailure,
        [scriptblock]$GuardFailureMutation
    )
    $input = New-SecurityPilotLedgerInput
    $resultsRootForGuardMutation = [string]$input.results_root
    $calls = [Collections.Generic.List[string]]::new()
    $candidate = {
        param($Candidate, $Prompt, $LaunchGuard, $RunId)
        $calls.Add('candidate')
        if ($FailureRole -ceq 'candidate' -and $FailureMode -ceq 'preclaim_throw') {
            throw (@($Sentinels) -join '|')
        }
        try {
            $null = & $LaunchGuard $Candidate (New-SecurityPilotCommand -Candidate $Candidate -Prompt $Prompt)
        } catch {
            if (-not $SwallowGuardFailure) { throw }
            if ($null -ne $GuardFailureMutation) { & $GuardFailureMutation $resultsRootForGuardMutation $RunId 1 }
            return New-SecurityPilotExecution -Candidate $Candidate -RunId $RunId -Answer $null `
                -FailureCode 'process_start_failed' -ProcessStarted:$false -Sentinels $Sentinels
        }
        if ($FailureRole -ceq 'candidate' -and $FailureMode -ceq 'postclaim_throw') {
            throw (@($Sentinels) -join '|')
        }
        $failure = if ($FailureRole -ceq 'candidate') { $FailureCode } else { $null }
        $execution = New-SecurityPilotExecution -Candidate $Candidate -RunId $RunId `
            -Answer '{"event":"Robotics club demo","date":"2026-09-14","room":"Room B12"}' `
            -FailureCode $failure -Sentinels $Sentinels
        if ($FailureRole -ceq 'candidate' -and $null -ne $EnvelopeMutation) { & $EnvelopeMutation $execution }
        return $execution
    }.GetNewClosure()
    $judge = {
        param($JudgeProfileId, $JudgePayload, $PromptDefinition, $LaunchGuard, $RunId)
        $role = if ($JudgeProfileId -ceq 'gpt-5.6-sol__max') { 'judge_1' } else { 'judge_2' }
        $calls.Add($role)
        $resolved = Get-CalibrationProfileAndCandidate -ConfigurationId $JudgeProfileId
        try {
            $null = & $LaunchGuard $resolved.candidate (New-SecurityPilotCommand -Candidate $resolved.candidate -Prompt 'safe judge payload')
        } catch {
            if (-not $SwallowGuardFailure) { throw }
            $ordinal = if ($role -ceq 'judge_1') { 2 } else { 3 }
            if ($null -ne $GuardFailureMutation) { & $GuardFailureMutation $resultsRootForGuardMutation $RunId $ordinal }
            return [pscustomobject]@{
                pilot_execution = New-SecurityPilotExecution -Candidate $resolved.candidate -RunId $RunId `
                    -Answer $null -FailureCode 'process_start_failed' -ProcessStarted:$false -Sentinels $Sentinels
                decision = $null
                stop_code = $null
            }
        }
        if ($FailureRole -ceq $role) {
            $execution = New-SecurityPilotExecution -Candidate $resolved.candidate -RunId $RunId `
                -Answer '{"decision":"pass","rationale":"bounded safe evidence"}' `
                -FailureCode $FailureCode -Sentinels $Sentinels
            if ($null -ne $EnvelopeMutation) { & $EnvelopeMutation $execution }
            $wrapper = [pscustomobject]@{
                pilot_execution = $execution
                decision = if ([string]::IsNullOrEmpty($FailureCode)) {
                    [pscustomobject]@{ decision = 'pass'; rationale = 'bounded safe evidence' }
                } else { $null }
            }
            if ($null -ne $WrapperMutation) { & $WrapperMutation $wrapper }
            return $wrapper
        }
        return [pscustomobject]@{
            pilot_execution = New-SecurityPilotExecution -Candidate $resolved.candidate -RunId $RunId `
                -Answer '{"decision":"pass","rationale":"bounded safe evidence"}' -FailureCode $null
            decision = [pscustomobject]@{ decision = 'pass'; rationale = 'bounded safe evidence' }
        }
    }.GetNewClosure()
    $grader = {
        param($Prompt, $ResponseText, $PythonExecutor, $PythonExecutable, $TimeoutMilliseconds)
        $result = Invoke-CalibrationDeterministicGrader -Prompt $Prompt -ResponseText $ResponseText
        if ($null -ne $GraderMutation) { & $GraderMutation $result }
        return $result
    }.GetNewClosure()
    $git = { [pscustomobject]@{ clean = $true; commit = ('d' * 40) } }
    $parameters = @{
        Pilot = $true
        Run = $true
        RunId = 'option1-live-20260826-002'
        ResultsRoot = $input.results_root
        CalibrationSetPath = $setPath
        RubricsRoot = $rubricsRoot
        CandidateInvoker = $candidate
        GraderInvoker = $grader
        JudgeInvoker = $judge
        PilotGitInvoker = $git
    }
    if ($null -ne $ArtifactWriter) { $parameters.PilotArtifactWriter = $ArtifactWriter }
    try {
        $result = Invoke-Calibration @parameters
        return [pscustomobject]@{ input = $input; result = $result; calls = @($calls) }
    } catch {
        $_.Exception.Data['pilot_test_calls'] = @($calls)
        Remove-SecurityPilotLedgerRoot -Path $input.results_root
        throw
    }
}

function Get-SecurityFileHashes {
    $paths = @(
        Get-ChildItem -LiteralPath (Join-Path $projectRoot 'profiles') -File -Recurse
        Get-Item -LiteralPath (Join-Path $calibrationRoot 'calibration-set-v1.json')
        Get-Item -LiteralPath (Join-Path $projectRoot 'pilot/model_matrix.json')
        Get-Item -LiteralPath (Join-Path $projectRoot 'pilot/shared/response_schema.json')
        Get-Item -LiteralPath (Join-Path $projectRoot 'router/data/pricing-snapshot-2026-08-22.json')
        Get-Item -LiteralPath (Join-Path $projectRoot 'router/data/quality-snapshot-2026-08-22.json')
        Get-ChildItem -LiteralPath (Join-Path $calibrationRoot 'pilots') -File -Recurse
        Get-ChildItem -LiteralPath (Join-Path $calibrationRoot 'rubrics') -File -Recurse
    )
    return @($paths | Sort-Object FullName | ForEach-Object {
        '{0}|{1}' -f $_.FullName, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    })
}

function Test-SecurityPilotLedgerFaultStage {
    param([Parameter(Mandatory)][string]$Stage, [Parameter(Mandatory)][object]$Value)
    switch ($Stage) {
        'slot_reservation' {
            return $Value.run_state -ceq 'running' -and $Value.attempts[0].state -ceq 'slot_reserved'
        }
        'judge_slot_reservation' {
            return $Value.run_state -ceq 'running' -and $Value.attempts[0].state -ceq 'succeeded' -and
                $Value.attempts[1].state -ceq 'slot_reserved'
        }
        'judge_2_slot_reservation' {
            return $Value.run_state -ceq 'running' -and $Value.attempts[0].state -ceq 'succeeded' -and
                $Value.attempts[1].state -ceq 'succeeded' -and $Value.attempts[2].state -ceq 'slot_reserved'
        }
        'process_start_record' {
            return $Value.run_state -ceq 'running' -and $Value.attempts[0].state -ceq 'process_started'
        }
        'candidate_attempt_completion' {
            return $Value.run_state -ceq 'running' -and $Value.attempts[0].state -ceq 'succeeded' -and
                $null -eq $Value.quality.deterministic_result
        }
        'deterministic_result_setter' {
            return $Value.run_state -ceq 'running' -and $Value.attempts[0].state -ceq 'succeeded' -and
                $null -ne $Value.quality.deterministic_result -and @($Value.quality.judge_decisions).Count -eq 0
        }
        'judge_completion' {
            return $Value.run_state -ceq 'running' -and $Value.attempts[1].state -ceq 'succeeded' -and
                @($Value.quality.judge_decisions).Count -eq 1
        }
        'quality_outcome' {
            return $Value.run_state -ceq 'running' -and
                @($Value.attempts | Where-Object { $_.state -cne 'succeeded' }).Count -eq 0 -and
                $null -ne $Value.quality.outcome
        }
        'final_completed_transition' { return $Value.run_state -ceq 'completed' }
        default { throw "Unknown test-only ledger fault stage '$Stage'." }
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

Invoke-Assertion 'atomic result replacement cleans only its owned temp after replace failure' {
    $caseData = New-SecurityPilotLedgerInput
    $context = $null
    $resultLock = $null
    try {
        $context = New-CalibrationPilotRun -ResultsRoot $caseData.results_root -RunId 'ledger-security-008' -Plan $caseData.plan
        Set-CalibrationPilotRunState -Context $context -State 'preflight_passed'
        Set-CalibrationPilotRunState -Context $context -State 'running'
        $slot = New-CalibrationPilotSlotClaim -Context $context -Ordinal 1 -Identity $caseData.plan.roles[0]
        $beforeListing = Get-SecurityPilotRunListing -RunRoot $context.run_root
        $resultHash = (Get-FileHash -LiteralPath $context.result_path -Algorithm SHA256).Hash
        $planHash = (Get-FileHash -LiteralPath $context.plan_path -Algorithm SHA256).Hash
        $slotHash = (Get-FileHash -LiteralPath $slot.claim_path -Algorithm SHA256).Hash
        $tempPath = Join-Path $context.run_root ('.result-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
        $resultLock = [IO.File]::Open($context.result_path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        $null = Assert-Throws {
            Write-CalibrationAtomicResultJson -Path $context.result_path -Value $context.result `
                -AllowedRunRoot $context.run_root -TemporaryPath $tempPath
        } 'pilot_result_replace_indeterminate'
        $resultLock.Dispose()
        $resultLock = $null

        Assert-False (Test-Path -LiteralPath $tempPath) 'The operation-owned result temp survived a failed replacement.'
        Assert-SequenceEqual (Get-SecurityPilotRunListing -RunRoot $context.run_root) $beforeListing
        Assert-Equal (Get-FileHash -LiteralPath $context.result_path -Algorithm SHA256).Hash $resultHash
        Assert-Equal (Get-FileHash -LiteralPath $context.plan_path -Algorithm SHA256).Hash $planHash
        Assert-Equal (Get-FileHash -LiteralPath $slot.claim_path -Algorithm SHA256).Hash $slotHash
        Assert-True (Test-Path -LiteralPath $context.claim_path -PathType Leaf)
    } finally {
        if ($null -ne $resultLock) { $resultLock.Dispose() }
        if ($null -ne $context) { Close-CalibrationPilotRun -Context $context }
        Remove-SecurityPilotLedgerRoot -Path $caseData.results_root
    }
}

Invoke-Assertion 'create-new initialization failure after open is indeterminate and non-refundable' {
    $caseData = New-SecurityPilotLedgerInput
    $runId = 'ledger-security-012'
    $runRoot = Join-Path $caseData.results_root $runId
    $originalHook = (Get-Command -Name Invoke-CalibrationPilotAfterCreateNewOpenHook -CommandType Function -ErrorAction Stop).ScriptBlock
    $originalOpen = (Get-Command -Name Open-CalibrationCreateNewFileStream -CommandType Function -ErrorAction Stop).ScriptBlock
    try {
        Set-Item -Path Function:\Invoke-CalibrationPilotAfterCreateNewOpenHook -Value {
            param([string]$Path)
            if ([IO.Path]::GetFileName($Path) -ceq 'plan.json') { throw 'forced raw initialization writer failure' }
        }
        $null = Assert-Throws {
            New-CalibrationPilotRun -ResultsRoot $caseData.results_root -RunId $runId -Plan $caseData.plan | Out-Null
        } 'pilot_create_new_persistence_indeterminate'
        $planPath = Join-Path $runRoot 'plan.json'
        Assert-True (Test-Path -LiteralPath $planPath -PathType Leaf) 'Partial initialization artifact was refunded.'
        Assert-True (Test-Path -LiteralPath (Join-Path $runRoot '.run.claim') -PathType Leaf)
        $planHash = (Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash
        $openFailurePath = Join-Path (Join-Path $runRoot 'raw') 'open-failure.json'
        Set-Item -Path Function:\Open-CalibrationCreateNewFileStream -Value {
            throw [IO.IOException]::new('forced raw non-collision open failure')
        }
        $null = Assert-Throws {
            Write-CalibrationCreateNewJson -Path $openFailurePath -Value ([pscustomobject]@{ safe = $true }) `
                -AllowedRunRoot $runRoot
        } 'pilot_create_new_failed'
        Assert-False (Test-Path -LiteralPath $openFailurePath)
        $null = Assert-Throws {
            New-CalibrationPilotRun -ResultsRoot $caseData.results_root -RunId $runId -Plan $caseData.plan | Out-Null
        } 'pilot_run_collision'
        Assert-Equal (Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash $planHash
        Assert-False (Test-Path -LiteralPath (Join-Path $runRoot 'result.json'))
        Assert-Equal @(Get-ChildItem -LiteralPath $runRoot -Force -Recurse -Filter '.result-*.tmp').Count 0
    } finally {
        Set-Item -Path Function:\Invoke-CalibrationPilotAfterCreateNewOpenHook -Value $originalHook
        Set-Item -Path Function:\Open-CalibrationCreateNewFileStream -Value $originalOpen
        Remove-SecurityPilotLedgerRoot -Path $caseData.results_root
    }
}

Invoke-Assertion 'result temp disposal failure is bounded and cleans the exact owned temp' {
    $caseData = New-SecurityPilotLedgerInput
    $context = $null
    $originalHook = (Get-Command -Name Close-CalibrationPilotResultTempStream -CommandType Function -ErrorAction Stop).ScriptBlock
    $originalBytes = $null
    try {
        $context = New-CalibrationPilotRun -ResultsRoot $caseData.results_root -RunId 'ledger-security-013' -Plan $caseData.plan
        $originalBytes = [IO.File]::ReadAllBytes($context.result_path)
        $originalHash = (Get-FileHash -LiteralPath $context.result_path -Algorithm SHA256).Hash
        $replacement = $context.result | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
        $replacement.run_state = 'preflight_passed'
        $tempPath = Join-Path $context.run_root ('.result-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
        Set-Item -Path Function:\Close-CalibrationPilotResultTempStream -Value { throw 'forced raw temp disposal failure' }
        $null = Assert-Throws {
            Write-CalibrationAtomicResultJson -Path $context.result_path -Value $replacement `
                -AllowedRunRoot $context.run_root -TemporaryPath $tempPath
        } 'pilot_result_temp_persistence_indeterminate'
        Assert-False (Test-Path -LiteralPath $tempPath) 'Owned result temp survived disposal failure.'
        Assert-Equal (Get-FileHash -LiteralPath $context.result_path -Algorithm SHA256).Hash $originalHash
    } finally {
        Set-Item -Path Function:\Close-CalibrationPilotResultTempStream -Value $originalHook
        if ($null -ne $context -and $null -ne $originalBytes) { [IO.File]::WriteAllBytes($context.result_path, $originalBytes) }
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
        $context.plan = Get-Content -Raw -LiteralPath $context.plan_path | ConvertFrom-Json -Depth 100 -DateKind String
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
        $null = Assert-Throws { Close-CalibrationPilotRun -Context $context } 'pilot_run_context_invalid'
        $context = $null

        $context = New-CalibrationPilotRun -ResultsRoot $caseData.results_root -RunId 'ledger-security-007' -Plan $caseData.plan
        $originalResultBytes = [IO.File]::ReadAllBytes($context.result_path)
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
        [IO.File]::WriteAllBytes($context.result_path, $originalResultBytes)
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

Invoke-Assertion 'post-claim validation drift is classified as persistence indeterminate' {
    $caseData = New-SecurityPilotLedgerInput
    $context = $null
    $originalHook = (Get-Command -Name Invoke-CalibrationPilotAfterSlotClaimHook -CommandType Function -ErrorAction Stop).ScriptBlock
    try {
        $context = New-CalibrationPilotRun -ResultsRoot $caseData.results_root -RunId 'ledger-security-009' -Plan $caseData.plan
        Set-CalibrationPilotRunState -Context $context -State 'preflight_passed'
        Set-CalibrationPilotRunState -Context $context -State 'running'
        $resultHash = (Get-FileHash -LiteralPath $context.result_path -Algorithm SHA256).Hash
        Set-Item -Path Function:\Invoke-CalibrationPilotAfterSlotClaimHook -Value {
            param([object]$Context, [int]$Ordinal)
            $context.result.stop_reason = 'forced post-claim context drift'
        }
        $null = Assert-Throws {
            New-CalibrationPilotSlotClaim -Context $context -Ordinal 1 -Identity $caseData.plan.roles[0] | Out-Null
        } 'pilot_claim_persistence_indeterminate'
        $claimPath = Join-Path $context.claims_path '01-google-candidate.claim'
        Assert-True (Test-Path -LiteralPath $claimPath -PathType Leaf) 'Post-claim validation failure refunded the claim.'
        Assert-Equal (Get-FileHash -LiteralPath $context.result_path -Algorithm SHA256).Hash $resultHash
        $persisted = Get-Content -Raw -LiteralPath $context.result_path | ConvertFrom-Json -Depth 100
        Assert-Equal $persisted.attempts[0].state 'planned'
        Assert-Equal $persisted.slots_consumed.total 0
        $context.result = $persisted
        $null = Assert-Throws { Get-CalibrationPilotClaimCount -Context $context | Out-Null } 'pilot_claim_counter_mismatch'
        Assert-True (Test-Path -LiteralPath $claimPath -PathType Leaf) 'Counter mismatch handling refunded the immutable claim.'
    } finally {
        Set-Item -Path Function:\Invoke-CalibrationPilotAfterSlotClaimHook -Value $originalHook
        if ($null -ne $context) { Close-CalibrationPilotRun -Context $context }
        Remove-SecurityPilotLedgerRoot -Path $caseData.results_root
    }
}

Invoke-Assertion 'claim write failure after create-new is persistence indeterminate and non-refundable' {
    $caseData = New-SecurityPilotLedgerInput
    $context = $null
    $originalHook = (Get-Command -Name Invoke-CalibrationPilotAfterSlotClaimCreateHook -CommandType Function -ErrorAction Stop).ScriptBlock
    try {
        $context = New-CalibrationPilotRun -ResultsRoot $caseData.results_root -RunId 'ledger-security-011' -Plan $caseData.plan
        Set-CalibrationPilotRunState -Context $context -State 'preflight_passed'
        Set-CalibrationPilotRunState -Context $context -State 'running'
        $resultHash = (Get-FileHash -LiteralPath $context.result_path -Algorithm SHA256).Hash
        $claimPath = Join-Path $context.claims_path '01-google-candidate.claim'
        Set-Item -Path Function:\Invoke-CalibrationPilotAfterSlotClaimCreateHook -Value {
            throw 'forced raw claim writer failure'
        }
        $null = Assert-Throws {
            New-CalibrationPilotSlotClaim -Context $context -Ordinal 1 -Identity $caseData.plan.roles[0] | Out-Null
        } 'pilot_claim_persistence_indeterminate'

        Assert-True (Test-Path -LiteralPath $claimPath -PathType Leaf) 'Created claim was refunded after its writer failed.'
        Assert-Equal (Get-FileHash -LiteralPath $context.result_path -Algorithm SHA256).Hash $resultHash
        $persisted = Get-Content -Raw -LiteralPath $context.result_path | ConvertFrom-Json -Depth 100
        Assert-Equal $persisted.attempts[0].state 'planned'
        Assert-Equal $persisted.slots_consumed.total 0
        $claimHash = (Get-FileHash -LiteralPath $claimPath -Algorithm SHA256).Hash
        $null = Assert-Throws {
            Write-CalibrationPilotClaimCreateNewJson -Path $claimPath -Value ([pscustomobject]@{ safe = $true }) `
                -AllowedRunRoot $context.run_root
        } 'pilot_create_new_collision'
        $null = Assert-Throws {
            New-CalibrationPilotSlotClaim -Context $context -Ordinal 1 -Identity $caseData.plan.roles[0] | Out-Null
        } 'pilot_claim_artifact_invalid'
        Assert-Equal (Get-FileHash -LiteralPath $claimPath -Algorithm SHA256).Hash $claimHash
        Assert-Equal (Get-FileHash -LiteralPath $context.result_path -Algorithm SHA256).Hash $resultHash
        Assert-Equal @(Get-ChildItem -LiteralPath $context.run_root -Force -Recurse -Filter '.result-*.tmp').Count 0
        $relativeFiles = @(Get-ChildItem -LiteralPath $context.run_root -Force -Recurse -File | ForEach-Object {
            $_.FullName.Substring($context.run_root.Length).TrimStart('\')
        } | Sort-Object)
        Assert-SequenceEqual $relativeFiles @(
            '.run.claim',
            'claims\01-google-candidate.claim',
            'plan.json',
            'result.json'
        )
    } finally {
        Set-Item -Path Function:\Invoke-CalibrationPilotAfterSlotClaimCreateHook -Value $originalHook
        if ($null -ne $context) { Close-CalibrationPilotRun -Context $context }
        Remove-SecurityPilotLedgerRoot -Path $caseData.results_root
    }
}

Invoke-Assertion 'close serializes with reservation and is idempotent after releasing the run claim' {
    $caseData = New-SecurityPilotLedgerInput
    $context = $null
    $reservationPowerShell = $null
    $closePowerShell = $null
    $reservationAsync = $null
    $closeAsync = $null
    $entered = [Threading.ManualResetEvent]::new($false)
    $release = [Threading.ManualResetEvent]::new($false)
    try {
        $context = New-CalibrationPilotRun -ResultsRoot $caseData.results_root -RunId 'ledger-security-010' -Plan $caseData.plan
        Set-CalibrationPilotRunState -Context $context -State 'preflight_passed'
        Set-CalibrationPilotRunState -Context $context -State 'running'

        $reservationPowerShell = [PowerShell]::Create()
        $null = $reservationPowerShell.AddScript({
            param($ImplementationPath, $RunContext, $Identity, $EnteredEvent, $ReleaseEvent)
            . $ImplementationPath
            function Invoke-CalibrationPilotBeforeSlotClaimHook {
                param([object]$Context, [int]$Ordinal)
                $null = $EnteredEvent.Set()
                if (-not $ReleaseEvent.WaitOne(10000)) { throw 'test_reservation_gate_timeout' }
            }
            New-CalibrationPilotSlotClaim -Context $RunContext -Ordinal 1 -Identity $Identity
        }).AddArgument($implementationPath).AddArgument($context).AddArgument($caseData.plan.roles[0]).AddArgument($entered).AddArgument($release)
        $reservationAsync = $reservationPowerShell.BeginInvoke()
        Assert-True $entered.WaitOne(10000) 'Reservation did not reach the coordinated pre-claim gate.'

        $closePowerShell = [PowerShell]::Create()
        $null = $closePowerShell.AddScript({
            param($ImplementationPath, $RunContext)
            . $ImplementationPath
            Close-CalibrationPilotRun -Context $RunContext
        }).AddArgument($implementationPath).AddArgument($context)
        $closeAsync = $closePowerShell.BeginInvoke()
        Assert-False $closeAsync.AsyncWaitHandle.WaitOne(250) 'Close released the run stream while reservation held the run lock.'
        $probeThrew = $false
        try {
            $probe = [IO.File]::Open($context.claim_path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $probe.Dispose()
        } catch { $probeThrew = $true }
        Assert-True $probeThrew 'The exclusive run claim was released before reservation exited the lock.'

        $null = $release.Set()
        $reservationOutput = @($reservationPowerShell.EndInvoke($reservationAsync))
        $reservationAsync = $null
        $null = $closePowerShell.EndInvoke($closeAsync)
        $closeAsync = $null
        Assert-Equal $reservationOutput.Count 1
        Assert-True $context.is_closed
        Assert-True ($null -eq $context.claim_stream)
        Assert-Equal $context.result.attempts[0].state 'slot_reserved'
        Assert-Equal $context.result.slots_consumed.total 1
        Assert-True (Test-Path -LiteralPath (Join-Path $context.claims_path '01-google-candidate.claim') -PathType Leaf)
        $probe = [IO.File]::Open($context.claim_path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $probe.Dispose()
        Close-CalibrationPilotRun -Context $context
    } finally {
        $null = $release.Set()
        if ($null -ne $reservationAsync -and $null -ne $reservationPowerShell) {
            try { $null = $reservationPowerShell.EndInvoke($reservationAsync) } catch { }
        }
        if ($null -ne $closeAsync -and $null -ne $closePowerShell) {
            try { $null = $closePowerShell.EndInvoke($closeAsync) } catch { }
        }
        if ($null -ne $reservationPowerShell) { $reservationPowerShell.Dispose() }
        if ($null -ne $closePowerShell) { $closePowerShell.Dispose() }
        if ($null -ne $context -and -not $context.is_closed) {
            try { Close-CalibrationPilotRun -Context $context } catch { }
        }
        $entered.Dispose()
        $release.Dispose()
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

Invoke-Assertion 'option 1 stop-code conversion accepts only the exact bounded allowlist' {
    $allowedStopCodes = @(
        'source_drift', 'repository_not_clean', 'authentication_failed', 'quota_failed',
        'unsupported_configuration', 'process_start_failed', 'timeout', 'cleanup_failed',
        'nonzero_exit', 'provider_envelope_invalid', 'response_contract_invalid',
        'artifact_persistence_failed', 'sensitive_output_detected', 'budget_invariant_failed',
        'manual_abort'
    )
    Assert-SequenceEqual @($script:CalibrationPilotAllowedStopCodes) $allowedStopCodes
    foreach ($code in $allowedStopCodes) { Assert-Equal (Resolve-CalibrationPilotStopCode $code) $code }
    foreach ($unsafe in @($null, '', 'TIMEOUT', 'exception: private text', 'pilot_candidate_execution_failed')) {
        Assert-Equal (Resolve-CalibrationPilotStopCode $unsafe) 'provider_envelope_invalid'
    }
    $malformedEnvelope = [pscustomobject]@{
        process = [pscustomobject]@{ timed_out = $false; cleanup_failed = $false; exit_code = 'EXCEPTION_SENTINEL_EXIT_42' }
        canonical = $null
    }
    Assert-Equal (Get-CalibrationPilotExecutionStopCode -Execution $malformedEnvelope -ExplicitCode $null) `
        'provider_envelope_invalid'
}

Invoke-Assertion 'option 1 rejects malformed candidate and judge execution envelopes without coercion' {
    $cases = @(
        [pscustomobject]@{ role = 'candidate'; name = 'string exit zero'; category = 'process_values'; starts = 1; terminal = 'stopped'; mutate = { param($e) $e.process.exit_code = '0' } },
        [pscustomobject]@{ role = 'candidate'; name = 'fractional exit zero'; category = 'process_values'; starts = 1; terminal = 'stopped'; mutate = { param($e) $e.process.exit_code = [decimal]0.0 } },
        [pscustomobject]@{ role = 'candidate'; name = 'contradictory start flag'; category = 'start_state'; starts = 0; terminal = 'indeterminate'; mutate = { param($e) $e.process_started = $false } },
        [pscustomobject]@{ role = 'candidate'; name = 'string start flag'; category = 'start_state'; starts = 0; terminal = 'indeterminate'; mutate = { param($e) $e.process_started = 'true' } },
        [pscustomobject]@{ role = 'candidate'; name = 'true start without process'; category = 'start_state'; starts = 0; terminal = 'indeterminate'; mutate = { param($e) $e.process = $null } },
        [pscustomobject]@{ role = 'candidate'; name = 'string timeout flag'; category = 'process_values'; starts = 1; terminal = 'stopped'; mutate = { param($e) $e.process.timed_out = 'false' } },
        [pscustomobject]@{ role = 'judge_1'; name = 'string exit zero'; category = 'process_values'; starts = 2; terminal = 'stopped'; mutate = { param($e) $e.process.exit_code = '0' } },
        [pscustomobject]@{ role = 'judge_1'; name = 'numeric cleanup flag'; category = 'process_values'; starts = 2; terminal = 'stopped'; mutate = { param($e) $e.process.cleanup_failed = 0 } },
        [pscustomobject]@{ role = 'judge_1'; name = 'string exited flag'; category = 'process_values'; starts = 2; terminal = 'stopped'; mutate = { param($e) $e.process.process_exited = 'true' } }
    )
    foreach ($case in $cases) {
        $execution = Invoke-SecurityPilotFailureCase -FailureRole $case.role -FailureCode '' `
            -EnvelopeMutation $case.mutate
        try {
            Assert-True ($execution.result.run_state -ceq $case.terminal) `
                "$($case.role)/$($case.name) expected terminal $($case.terminal), got $($execution.result.run_state)."
            Assert-True ($execution.result.stop_reason -ceq 'provider_envelope_invalid') `
                "$($case.role)/$($case.name) expected provider_envelope_invalid, got $($execution.result.stop_reason)."
            Assert-True ($execution.result.launcher_processes_started.total -eq $case.starts) `
                "$($case.role)/$($case.name) expected $($case.starts) starts, got $($execution.result.launcher_processes_started.total)."
            $expectedStates = if ($case.role -ceq 'candidate') {
                @('failed', 'skipped', 'skipped')
            } else { @('succeeded', 'failed', 'skipped') }
            Assert-SequenceEqual @($execution.result.attempts.state) $expectedStates
            $failedAttempt = if ($case.role -ceq 'candidate') { $execution.result.attempts[0] } else { $execution.result.attempts[1] }
            Assert-Equal $failedAttempt.envelope_rejection_code $case.category
            $runRoot = Join-Path $execution.input.results_root 'option1-live-20260826-002'
            $persisted = Get-Content -Raw -LiteralPath (Join-Path $runRoot 'result.json') | ConvertFrom-Json -Depth 100
            Assert-Equal $persisted.stop_reason 'provider_envelope_invalid'
            Assert-SequenceEqual @($persisted.attempts.state) $expectedStates
            $persistedFailedAttempt = if ($case.role -ceq 'candidate') { $persisted.attempts[0] } else { $persisted.attempts[1] }
            Assert-Equal $persistedFailedAttempt.envelope_rejection_code $case.category
        } finally { Remove-SecurityPilotLedgerRoot -Path $execution.input.results_root }
    }
}

Invoke-Assertion 'option 1 persists only bounded envelope categories and omits malformed-input sentinels' {
    $cases = @(
        [pscustomobject]@{
            category = 'execution_shape'
            terminal = 'indeterminate'
            sentinel = 'PROMPT_SENTINEL_ENVELOPE_42'
            mutate = { param($e) $e.PSObject.Properties.Remove('process'); $e | Add-Member unsafe_prompt 'PROMPT_SENTINEL_ENVELOPE_42' }
        },
        [pscustomobject]@{
            category = 'canonical_values'
            terminal = 'stopped'
            sentinel = 'CANONICAL_ERROR_SENTINEL_42'
            mutate = { param($e) $e.canonical.error = 'CANONICAL_ERROR_SENTINEL_42' }
        },
        [pscustomobject]@{
            category = 'process_values'
            terminal = 'stopped'
            sentinel = 'C:\private\PATH_SENTINEL_ENVELOPE_42'
            mutate = { param($e) $e.process.cleanup_status = 'C:\private\PATH_SENTINEL_ENVELOPE_42' }
        },
        [pscustomobject]@{
            category = 'semantic_conflict'
            terminal = 'stopped'
            sentinel = 'CREDENTIAL_SENTINEL_ENVELOPE_42'
            mutate = { param($e) $e.failure = 'CREDENTIAL_SENTINEL_ENVELOPE_42' }
        }
    )
    foreach ($case in $cases) {
        $execution = Invoke-SecurityPilotFailureCase -FailureRole candidate -FailureCode '' `
            -EnvelopeMutation $case.mutate -Sentinels @($case.sentinel)
        try {
            Assert-Equal $execution.result.run_state $case.terminal
            Assert-Equal $execution.result.stop_reason 'provider_envelope_invalid'
            Assert-Equal $execution.result.attempts[0].envelope_rejection_code $case.category
            foreach ($later in @($execution.result.attempts | Select-Object -Skip 1)) {
                Assert-Equal $later.envelope_rejection_code $null
            }
            $runRoot = Join-Path $execution.input.results_root 'option1-live-20260826-002'
            $persistedText = @(Get-ChildItem -LiteralPath $runRoot -File -Recurse | ForEach-Object {
                Get-Content -Raw -LiteralPath $_.FullName
            }) -join "`n"
            Assert-False $persistedText.Contains($case.sentinel, [StringComparison]::Ordinal)
            $persisted = Get-Content -Raw -LiteralPath (Join-Path $runRoot 'result.json') | ConvertFrom-Json -Depth 100
            Assert-Equal $persisted.attempts[0].envelope_rejection_code $case.category
        } finally { Remove-SecurityPilotLedgerRoot -Path $execution.input.results_root }
    }
}

Invoke-Assertion 'option 1 strictly validates deterministic grader results before any quality mutation' {
    $cases = @(
        [pscustomobject]@{ name = 'missing checks'; mutate = { param($r) $r.PSObject.Properties.Remove('checks') } },
        [pscustomobject]@{ name = 'non-string type'; mutate = { param($r) $r.type = 7 } },
        [pscustomobject]@{ name = 'non-string outcome'; mutate = { param($r) $r.outcome = $true } },
        [pscustomobject]@{ name = 'extra top-level property'; mutate = { param($r) $r | Add-Member -NotePropertyName extra -NotePropertyValue 'unsafe' } },
        [pscustomobject]@{ name = 'malformed check Boolean'; mutate = { param($r) $r.checks[0].passed = 'true' } },
        [pscustomobject]@{ name = 'extra check property'; mutate = { param($r) $r.checks[0] | Add-Member -NotePropertyName extra -NotePropertyValue 'unsafe' } }
    )
    foreach ($case in $cases) {
        $execution = Invoke-SecurityPilotFailureCase -FailureRole candidate -FailureCode '' `
            -GraderMutation $case.mutate
        try {
            Assert-SequenceEqual @($execution.calls) @('candidate')
            Assert-Equal $execution.result.run_state 'stopped'
            Assert-Equal $execution.result.stop_reason 'response_contract_invalid'
            Assert-Equal $execution.result.slots_consumed.total 1
            Assert-Equal $execution.result.launcher_processes_started.total 1
            Assert-SequenceEqual @($execution.result.attempts.state) @('succeeded', 'skipped', 'skipped')
            Assert-True ($null -eq $execution.result.quality.deterministic_result)
            $runRoot = Join-Path $execution.input.results_root 'option1-live-20260826-002'
            Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $runRoot 'claims') -File -Force).Count 1
            $persisted = Get-Content -Raw -LiteralPath (Join-Path $runRoot 'result.json') | ConvertFrom-Json -Depth 100
            Assert-Equal $persisted.stop_reason 'response_contract_invalid'
            Assert-True ($null -eq $persisted.quality.deterministic_result)
        } finally { Remove-SecurityPilotLedgerRoot -Path $execution.input.results_root }
    }
}

Invoke-Assertion 'option 1 rejects contradictory success and failure metadata symmetrically' {
    $cases = @(
        [pscustomobject]@{ role = 'candidate'; starts = 1; code = 'provider_envelope_invalid'; mutate = { param($e) $e.failure_code = 'quota_failed' } },
        [pscustomobject]@{ role = 'candidate'; starts = 1; code = 'provider_envelope_invalid'; mutate = { param($e) $e.failure = 'failure contradicts success' } },
        [pscustomobject]@{ role = 'candidate'; starts = 1; code = 'provider_envelope_invalid'; mutate = { param($e) $e.process.exit_code = 17 } },
        [pscustomobject]@{ role = 'candidate'; starts = 1; code = 'response_contract_invalid'; mutate = {
            param($e); $e.canonical.status = 'failure'; $e.canonical.answer = ''; $e.canonical.error = 'declared failure'
        } },
        [pscustomobject]@{ role = 'judge_1'; starts = 2; code = 'provider_envelope_invalid'; mutate = { param($e) $e.failure_code = 'quota_failed' } },
        [pscustomobject]@{ role = 'judge_1'; starts = 2; code = 'provider_envelope_invalid'; mutate = { param($e) $e.failure = 'failure contradicts success' } }
    )
    foreach ($case in $cases) {
        $execution = Invoke-SecurityPilotFailureCase -FailureRole $case.role -FailureCode '' `
            -EnvelopeMutation $case.mutate
        try {
            Assert-True ($execution.result.run_state -ceq 'stopped') `
                "$($case.role) consistency case expected stopped, got $($execution.result.run_state)."
            Assert-True ($execution.result.stop_reason -ceq $case.code) `
                "$($case.role) consistency case expected $($case.code), got $($execution.result.stop_reason)."
            Assert-Equal $execution.result.launcher_processes_started.total $case.starts
            $expectedStates = if ($case.role -ceq 'candidate') {
                @('failed', 'skipped', 'skipped')
            } else { @('succeeded', 'failed', 'skipped') }
            Assert-SequenceEqual @($execution.result.attempts.state) $expectedStates
        } finally { Remove-SecurityPilotLedgerRoot -Path $execution.input.results_root }
    }
}

Invoke-Assertion 'option 1 rejects malformed candidate and judge stop metadata without continuation' {
    $cases = @(
        [pscustomobject]@{ role = 'candidate'; starts = 1; envelope = { param($e) $e.failure_code = 9 }; wrapper = $null },
        [pscustomobject]@{ role = 'candidate'; starts = 1; envelope = { param($e) $e | Add-Member -NotePropertyName stop_code -NotePropertyValue $false }; wrapper = $null },
        [pscustomobject]@{ role = 'judge_1'; starts = 2; envelope = $null; wrapper = { param($w) $w | Add-Member -NotePropertyName stop_code -NotePropertyValue 9 } },
        [pscustomobject]@{ role = 'judge_1'; starts = 2; envelope = $null; wrapper = { param($w) $w | Add-Member -NotePropertyName stop_code -NotePropertyValue @('quota_failed') } }
    )
    foreach ($case in $cases) {
        $parameters = @{
            FailureRole = $case.role
            FailureCode = ''
        }
        if ($null -ne $case.envelope) { $parameters.EnvelopeMutation = $case.envelope }
        if ($null -ne $case.wrapper) { $parameters.WrapperMutation = $case.wrapper }
        $execution = Invoke-SecurityPilotFailureCase @parameters
        try {
            Assert-True ($execution.result.run_state -ceq 'stopped') `
                "$($case.role) stop-metadata case expected stopped, got $($execution.result.run_state)."
            Assert-True ($execution.result.stop_reason -ceq 'provider_envelope_invalid') `
                "$($case.role) stop-metadata case expected provider_envelope_invalid, got $($execution.result.stop_reason)."
            Assert-Equal $execution.result.launcher_processes_started.total $case.starts
            $expectedStates = if ($case.role -ceq 'candidate') {
                @('failed', 'skipped', 'skipped')
            } else { @('succeeded', 'failed', 'skipped') }
            Assert-SequenceEqual @($execution.result.attempts.state) $expectedStates
        } finally { Remove-SecurityPilotLedgerRoot -Path $execution.input.results_root }
    }
}

Invoke-Assertion 'pilot terminal transitions persist only approved normalized stop codes' {
    foreach ($case in @(
        [pscustomobject]@{ state = 'stopped'; code = 'manual_abort' },
        [pscustomobject]@{ state = 'indeterminate'; code = 'artifact_persistence_failed' }
    )) {
        $caseData = New-SecurityPilotLedgerInput
        $context = $null
        try {
            $context = New-CalibrationPilotRun -ResultsRoot $caseData.results_root `
                -RunId ("ledger-terminal-$($case.state)") -Plan $caseData.plan
            Set-CalibrationPilotRunState -Context $context -State 'preflight_passed'
            Set-CalibrationPilotRunState -Context $context -State 'running'
            $before = (Get-FileHash -LiteralPath $context.result_path -Algorithm SHA256).Hash
            $null = Assert-Throws {
                Set-CalibrationPilotRunState -Context $context -State $case.state
            } 'pilot_stop_code_invalid'
            Assert-Equal (Get-FileHash -LiteralPath $context.result_path -Algorithm SHA256).Hash $before
            $null = Assert-Throws {
                Set-CalibrationPilotRunState -Context $context -State $case.state -StopCode 'pilot_stopped'
            } 'pilot_stop_code_invalid'
            Assert-Equal (Get-FileHash -LiteralPath $context.result_path -Algorithm SHA256).Hash $before
            Set-CalibrationPilotRunState -Context $context -State $case.state -StopCode $case.code
            Assert-Equal $context.result.stop_reason $case.code
        } finally {
            if ($null -ne $context) { Close-CalibrationPilotRun -Context $context }
            Remove-SecurityPilotLedgerRoot -Path $caseData.results_root
        }
    }
}

Invoke-Assertion 'option 1 technical failures stop at each exact role and durably skip every later role' {
    $cases = @(
        [pscustomobject]@{ role = 'candidate'; code = 'timeout'; claims = 1; calls = @('candidate'); states = @('failed', 'skipped', 'skipped') },
        [pscustomobject]@{ role = 'judge_1'; code = 'authentication_failed'; claims = 2; calls = @('candidate', 'judge_1'); states = @('succeeded', 'failed', 'skipped') },
        [pscustomobject]@{ role = 'judge_2'; code = 'quota_failed'; claims = 3; calls = @('candidate', 'judge_1', 'judge_2'); states = @('succeeded', 'succeeded', 'failed') }
    )
    foreach ($case in $cases) {
        $execution = Invoke-SecurityPilotFailureCase -FailureRole $case.role -FailureCode $case.code
        try {
            try { Assert-SequenceEqual @($execution.calls) @($case.calls) } catch {
                throw "$($case.role) call sequence: $($_.Exception.Message)"
            }
            Assert-Equal $execution.result.run_state 'stopped'
            Assert-Equal $execution.result.stop_reason $case.code
            Assert-True ($execution.result.slots_consumed.total -eq $case.claims) `
                "$($case.role) expected $($case.claims) slots, got $($execution.result.slots_consumed.total)."
            Assert-True ($execution.result.launcher_processes_started.total -eq $case.claims) `
                "$($case.role) expected $($case.claims) starts, got $($execution.result.launcher_processes_started.total)."
            Assert-SequenceEqual @($execution.result.attempts.state) @($case.states)
            $runRoot = Join-Path $execution.input.results_root 'option1-live-20260826-002'
            Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $runRoot 'claims') -File -Force).Count $case.claims
            $persisted = Get-Content -Raw -LiteralPath (Join-Path $runRoot 'result.json') | ConvertFrom-Json -Depth 100
            Assert-Equal $persisted.stop_reason $case.code
            Assert-SequenceEqual @($persisted.attempts.state) @($case.states)
            $failed = @($execution.result.attempts | Where-Object { $_.state -ceq 'failed' })[0]
            Assert-Equal $failed.duration_ms 1
            Assert-True ($failed.timed_out -is [bool])
            Assert-True ($failed.cleanup_failed -is [bool])
            Assert-True ($failed.process_exited -is [bool])
            Assert-SequenceEqual @($failed.usage.PSObject.Properties.Name) @(
                'actual_input_tokens', 'visible_output_tokens', 'reasoning_tokens', 'complete'
            )
            Assert-False (($failed | ConvertTo-Json -Depth 20 -Compress).Contains('raw_provider_usage', [StringComparison]::Ordinal))
        } finally { Remove-SecurityPilotLedgerRoot -Path $execution.input.results_root }
    }
}

Invoke-Assertion 'option 1 persists normalized timeout cleanup and nonzero-exit evidence without raw provider data' {
    foreach ($case in @(
        [pscustomobject]@{ code = 'timeout'; exit = 17; timed_out = $true; cleanup_failed = $false; cleanup_status = 'timeout_cleanup_complete' },
        [pscustomobject]@{ code = 'cleanup_failed'; exit = 17; timed_out = $false; cleanup_failed = $true; cleanup_status = 'timeout_cleanup_failed' },
        [pscustomobject]@{ code = 'nonzero_exit'; exit = 17; timed_out = $false; cleanup_failed = $false; cleanup_status = 'not_required' }
    )) {
        $sentinel = "RAW_PROVIDER_USAGE_$($case.code)"
        $execution = Invoke-SecurityPilotFailureCase -FailureRole candidate -FailureCode $case.code -Sentinels @($sentinel)
        try {
            $attempt = $execution.result.attempts[0]
            Assert-Equal $attempt.state 'failed'
            Assert-Equal $attempt.exit_code $case.exit
            Assert-Equal $attempt.duration_ms 1
            Assert-Equal $attempt.timed_out $case.timed_out
            Assert-Equal $attempt.cleanup_failed $case.cleanup_failed
            Assert-Equal $attempt.cleanup_status $case.cleanup_status
            Assert-True $attempt.process_exited
            Assert-Equal $attempt.transport_status 'failed'
            Assert-Equal $attempt.contract_status 'not_evaluated'
            Assert-Equal $attempt.usage.actual_input_tokens 21
            $runRoot = Join-Path $execution.input.results_root 'option1-live-20260826-002'
            $persistedText = @(Get-ChildItem -LiteralPath $runRoot -File -Recurse | ForEach-Object {
                Get-Content -Raw -LiteralPath $_.FullName
            }) -join "`n"
            Assert-False $persistedText.Contains($sentinel, [StringComparison]::Ordinal)
            Assert-False $persistedText.Contains('raw_provider_usage', [StringComparison]::Ordinal)
        } finally { Remove-SecurityPilotLedgerRoot -Path $execution.input.results_root }
    }
}

Invoke-Assertion 'option 1 preclaim and postclaim failures preserve exact non-refundable boundaries' {
    $sentinels = @('CREDENTIAL_SENTINEL_42', 'ENVIRONMENT_SENTINEL_42', 'PROMPT_ECHO_SENTINEL_42',
        'ARGUMENTS_SENTINEL_42', 'STDOUT_SENTINEL_42', 'STDERR_SENTINEL_42',
        'PROVIDER_EVENT_SENTINEL_42', 'EXCEPTION_SENTINEL_42')
    $cases = @(
        [pscustomobject]@{ mode = 'preclaim_throw'; terminal = 'stopped'; claims = 0; states = @('skipped', 'skipped', 'skipped') },
        [pscustomobject]@{ mode = 'postclaim_throw'; terminal = 'indeterminate'; claims = 1; states = @('failed', 'skipped', 'skipped') }
    )
    foreach ($case in $cases) {
        $execution = Invoke-SecurityPilotFailureCase -FailureRole candidate -FailureCode provider_envelope_invalid `
            -FailureMode $case.mode -Sentinels $sentinels
        try {
            Assert-SequenceEqual @($execution.calls) @('candidate')
            Assert-Equal $execution.result.run_state $case.terminal
            Assert-Equal $execution.result.stop_reason 'provider_envelope_invalid'
            Assert-Equal $execution.result.slots_consumed.total $case.claims
            Assert-Equal $execution.result.launcher_processes_started.total 0
            Assert-SequenceEqual @($execution.result.attempts.state) @($case.states)
            $runRoot = Join-Path $execution.input.results_root 'option1-live-20260826-002'
            $persistedText = @(Get-ChildItem -LiteralPath $runRoot -File -Recurse | ForEach-Object {
                Get-Content -Raw -LiteralPath $_.FullName
            }) -join "`n"
            foreach ($sentinel in $sentinels) {
                Assert-False $persistedText.Contains($sentinel, [StringComparison]::Ordinal) "Failure artifact leaked $sentinel."
            }
        } finally { Remove-SecurityPilotLedgerRoot -Path $execution.input.results_root }
    }
}

Invoke-Assertion 'option 1 artifact failure after confirmed start becomes indeterminate and forbids same-run resume' {
    $writerCalls = [pscustomobject]@{ count = 0 }
    $artifactWriter = {
        param($Context, $Name, $Value)
        $writerCalls.count++
        throw 'EXCEPTION_SENTINEL_ARTIFACT_WRITER_42'
    }.GetNewClosure()
    $execution = Invoke-SecurityPilotFailureCase -FailureRole judge_2 -FailureCode quota_failed -ArtifactWriter $artifactWriter
    try {
        Assert-SequenceEqual @($execution.calls) @('candidate')
        Assert-True ($writerCalls.count -eq 1) "Expected one artifact writer call, got $($writerCalls.count)."
        Assert-Equal $execution.result.run_state 'indeterminate'
        Assert-Equal $execution.result.stop_reason 'artifact_persistence_failed'
        Assert-Equal $execution.result.slots_consumed.total 1
        Assert-Equal $execution.result.launcher_processes_started.total 1
        Assert-SequenceEqual @($execution.result.attempts.state) @('failed', 'skipped', 'skipped')
        $resumeCalls = [pscustomobject]@{ count = 0 }
        $resumeSpy = { $resumeCalls.count++; throw 'resume reached invoker' }.GetNewClosure()
        $null = Assert-Throws {
            Invoke-Calibration -Pilot -Run -RunId 'option1-live-20260826-002' `
                -ResultsRoot $execution.input.results_root -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot `
                -CandidateInvoker $resumeSpy -JudgeInvoker $resumeSpy `
                -PilotGitInvoker { [pscustomobject]@{ clean = $true; commit = ('d' * 40) } } | Out-Null
        } 'pilot_run_collision'
        Assert-Equal $resumeCalls.count 0
        $runRoot = Join-Path $execution.input.results_root 'option1-live-20260826-002'
        $persistedText = @(Get-ChildItem -LiteralPath $runRoot -File -Recurse | ForEach-Object {
            Get-Content -Raw -LiteralPath $_.FullName
        }) -join "`n"
        Assert-False $persistedText.Contains('EXCEPTION_SENTINEL_ARTIFACT_WRITER_42', [StringComparison]::Ordinal)
    } finally { Remove-SecurityPilotLedgerRoot -Path $execution.input.results_root }
}

Invoke-Assertion 'every post-launch ledger transition recovers one-shot persistence failure durably' {
    $cases = @(
        [pscustomobject]@{ stage = 'slot_reservation'; calls = @('candidate'); claims = 1; starts = 0; states = @('failed', 'skipped', 'skipped'); deterministic = $false; decisions = 0; outcome = $null },
        [pscustomobject]@{ stage = 'process_start_record'; calls = @('candidate'); claims = 1; starts = 1; states = @('failed', 'skipped', 'skipped'); deterministic = $false; decisions = 0; outcome = $null },
        [pscustomobject]@{ stage = 'candidate_attempt_completion'; calls = @('candidate'); claims = 1; starts = 1; states = @('failed', 'skipped', 'skipped'); deterministic = $false; decisions = 0; outcome = $null },
        [pscustomobject]@{ stage = 'deterministic_result_setter'; calls = @('candidate'); claims = 1; starts = 1; states = @('succeeded', 'skipped', 'skipped'); deterministic = $false; decisions = 0; outcome = $null },
        [pscustomobject]@{ stage = 'judge_completion'; calls = @('candidate', 'judge_1'); claims = 2; starts = 2; states = @('succeeded', 'failed', 'skipped'); deterministic = $true; decisions = 0; outcome = $null },
        [pscustomobject]@{ stage = 'quality_outcome'; calls = @('candidate', 'judge_1', 'judge_2'); claims = 3; starts = 3; states = @('succeeded', 'succeeded', 'succeeded'); deterministic = $true; decisions = 2; outcome = $null },
        [pscustomobject]@{ stage = 'final_completed_transition'; calls = @('candidate', 'judge_1', 'judge_2'); claims = 3; starts = 3; states = @('succeeded', 'succeeded', 'succeeded'); deterministic = $true; decisions = 2; outcome = 'retained' }
    )
    $originalWriterText = (Get-Command -Name Write-CalibrationAtomicResultJson -CommandType Function -ErrorAction Stop).ScriptBlock.ToString()
    $immutableWriter = [scriptblock]::Create($originalWriterText)
    foreach ($case in $cases) {
        $fault = [pscustomobject]@{ armed = $true; injected = 0; writes = 0 }
        Set-Item -Path Function:\Write-CalibrationAtomicResultJson -Value {
            param($Path, $Value, $AllowedRunRoot, $TemporaryPath)
            $fault.writes++
            if ($fault.armed -and (Test-SecurityPilotLedgerFaultStage -Stage $case.stage -Value $Value)) {
                $fault.armed = $false
                $fault.injected++
                throw 'ONE_SHOT_LEDGER_SENTINEL_MUST_NOT_PERSIST'
            }
            & $immutableWriter -Path $Path -Value $Value -AllowedRunRoot $AllowedRunRoot -TemporaryPath $TemporaryPath
        }.GetNewClosure()
        $execution = $null
        try {
            $execution = Invoke-SecurityPilotFailureCase -FailureRole candidate -FailureCode ''
            Assert-Equal $fault.injected 1
            Assert-False $fault.armed
            Assert-SequenceEqual @($execution.calls) @($case.calls)
            Assert-Equal $execution.result.run_state 'indeterminate'
            Assert-Equal $execution.result.stop_reason 'artifact_persistence_failed'
            Assert-Equal $execution.result.slots_consumed.total $case.claims
            Assert-Equal $execution.result.launcher_processes_started.total $case.starts
            Assert-SequenceEqual @($execution.result.attempts.state) @($case.states)
            Assert-Equal @($execution.result.attempts | Where-Object { $null -ne $_.process_started_at }).Count $case.starts
            Assert-Equal @($execution.result.attempts | Where-Object { $null -ne $_.completed_at }).Count 3
            Assert-Equal ($null -ne $execution.result.quality.deterministic_result) $case.deterministic
            Assert-Equal @($execution.result.quality.judge_decisions).Count $case.decisions
            Assert-Equal $execution.result.quality.outcome $case.outcome
            Assert-Equal $execution.result.quality.external_category 'unknown'
            Assert-False $execution.result.profile_promotion_allowed
            Assert-False $execution.result.profile_mutated
            Assert-False $execution.result.production_eligibility_changed
            $runRoot = Join-Path $execution.input.results_root 'option1-live-20260826-002'
            $persisted = Get-Content -Raw -LiteralPath (Join-Path $runRoot 'result.json') | ConvertFrom-Json -Depth 100
            Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $runRoot 'claims') -File -Force).Count $case.claims
            Assert-Equal $persisted.run_state 'indeterminate'
            Assert-Equal $persisted.stop_reason 'artifact_persistence_failed'
            Assert-Equal $persisted.launcher_processes_started.total $case.starts
            Assert-SequenceEqual @($persisted.attempts.state) @($case.states)
            Assert-Equal ($null -ne $persisted.quality.deterministic_result) $case.deterministic
            Assert-Equal @($persisted.quality.judge_decisions).Count $case.decisions
            Assert-Equal $persisted.quality.outcome $case.outcome
            $persistedText = @(Get-ChildItem -LiteralPath $runRoot -File -Recurse | ForEach-Object {
                Get-Content -Raw -LiteralPath $_.FullName
            }) -join "`n"
            Assert-False $persistedText.Contains('ONE_SHOT_LEDGER_SENTINEL_MUST_NOT_PERSIST', [StringComparison]::Ordinal)
            $resumeCalls = [pscustomobject]@{ count = 0 }
            $resumeSpy = { $resumeCalls.count++; throw 'resume reached invoker' }.GetNewClosure()
            $null = Assert-Throws {
                Invoke-Calibration -Pilot -Run -RunId 'option1-live-20260826-002' `
                    -ResultsRoot $execution.input.results_root -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot `
                    -CandidateInvoker $resumeSpy -JudgeInvoker $resumeSpy `
                    -PilotGitInvoker { [pscustomobject]@{ clean = $true; commit = ('d' * 40) } } | Out-Null
            } 'pilot_run_collision'
            Assert-Equal $resumeCalls.count 0
        } finally {
            Set-Item -Path Function:\Write-CalibrationAtomicResultJson -Value $immutableWriter
            if ($null -ne $execution) { Remove-SecurityPilotLedgerRoot -Path $execution.input.results_root }
        }
    }
    Assert-Equal (Get-Command -Name Write-CalibrationAtomicResultJson -CommandType Function -ErrorAction Stop).ScriptBlock.ToString() $originalWriterText
}

Invoke-Assertion 'swallowed launch-guard persistence failures recover exact candidate and judge claims' {
    $cases = @(
        [pscustomobject]@{ stage = 'slot_reservation'; calls = @('candidate'); claims = 1; starts = 0; states = @('failed', 'skipped', 'skipped') },
        [pscustomobject]@{ stage = 'judge_slot_reservation'; calls = @('candidate', 'judge_1'); claims = 2; starts = 1; states = @('succeeded', 'failed', 'skipped') }
    )
    $originalWriterText = (Get-Command -Name Write-CalibrationAtomicResultJson -CommandType Function -ErrorAction Stop).ScriptBlock.ToString()
    $immutableWriter = [scriptblock]::Create($originalWriterText)
    foreach ($case in $cases) {
        $fault = [pscustomobject]@{ armed = $true; injected = 0 }
        Set-Item -Path Function:\Write-CalibrationAtomicResultJson -Value {
            param($Path, $Value, $AllowedRunRoot, $TemporaryPath)
            if ($fault.armed -and (Test-SecurityPilotLedgerFaultStage -Stage $case.stage -Value $Value)) {
                $fault.armed = $false
                $fault.injected++
                throw 'SWALLOWED_GUARD_RESULT_WRITE_SENTINEL'
            }
            & $immutableWriter -Path $Path -Value $Value -AllowedRunRoot $AllowedRunRoot -TemporaryPath $TemporaryPath
        }.GetNewClosure()
        $execution = $null
        try {
            $execution = Invoke-SecurityPilotFailureCase -FailureRole candidate -FailureCode '' -SwallowGuardFailure
            Assert-Equal $fault.injected 1
            Assert-SequenceEqual @($execution.calls) @($case.calls)
            Assert-Equal $execution.result.run_state 'indeterminate'
            Assert-Equal $execution.result.stop_reason 'artifact_persistence_failed'
            Assert-Equal $execution.result.slots_consumed.total $case.claims
            Assert-Equal $execution.result.launcher_processes_started.total $case.starts
            Assert-SequenceEqual @($execution.result.attempts.state) @($case.states)
            $runRoot = Join-Path $execution.input.results_root 'option1-live-20260826-002'
            Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $runRoot 'claims') -File -Force).Count $case.claims
            $persisted = Get-Content -Raw -LiteralPath (Join-Path $runRoot 'result.json') | ConvertFrom-Json -Depth 100
            Assert-Equal $persisted.run_state 'indeterminate'
            Assert-Equal $persisted.slots_consumed.total $case.claims
            Assert-Equal $persisted.launcher_processes_started.total $case.starts
            Assert-SequenceEqual @($persisted.attempts.state) @($case.states)
            $resumeCalls = [pscustomobject]@{ count = 0 }
            $resumeSpy = { $resumeCalls.count++; throw 'resume reached invoker' }.GetNewClosure()
            $null = Assert-Throws {
                Invoke-Calibration -Pilot -Run -RunId 'option1-live-20260826-002' `
                    -ResultsRoot $execution.input.results_root -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot `
                    -CandidateInvoker $resumeSpy -JudgeInvoker $resumeSpy `
                    -PilotGitInvoker { [pscustomobject]@{ clean = $true; commit = ('d' * 40) } } | Out-Null
            } 'pilot_run_collision'
            Assert-Equal $resumeCalls.count 0
        } finally {
            Set-Item -Path Function:\Write-CalibrationAtomicResultJson -Value $immutableWriter
            if ($null -ne $execution) { Remove-SecurityPilotLedgerRoot -Path $execution.input.results_root }
        }
    }
}

Invoke-Assertion 'swallowed launch-guard write-then-throw recovery rebases exact candidate and both judge reservations' {
    $cases = @(
        [pscustomobject]@{ stage = 'slot_reservation'; calls = @('candidate'); ordinal = 1; claims = 1; starts = 0; states = @('failed', 'skipped', 'skipped') },
        [pscustomobject]@{ stage = 'judge_slot_reservation'; calls = @('candidate', 'judge_1'); ordinal = 2; claims = 2; starts = 1; states = @('succeeded', 'failed', 'skipped') },
        [pscustomobject]@{ stage = 'judge_2_slot_reservation'; calls = @('candidate', 'judge_1', 'judge_2'); ordinal = 3; claims = 3; starts = 2; states = @('succeeded', 'succeeded', 'failed') }
    )
    $originalWriterText = (Get-Command -Name Write-CalibrationAtomicResultJson -CommandType Function -ErrorAction Stop).ScriptBlock.ToString()
    $immutableWriter = [scriptblock]::Create($originalWriterText)
    foreach ($case in $cases) {
        $fault = [pscustomobject]@{ armed = $true; injected = 0; persisted = $null }
        Set-Item -Path Function:\Write-CalibrationAtomicResultJson -Value {
            param($Path, $Value, $AllowedRunRoot, $TemporaryPath)
            if ($fault.armed -and (Test-SecurityPilotLedgerFaultStage -Stage $case.stage -Value $Value)) {
                $fault.armed = $false
                $fault.injected++
                $fault.persisted = Copy-CalibrationJsonValue $Value
                & $immutableWriter -Path $Path -Value $Value -AllowedRunRoot $AllowedRunRoot -TemporaryPath $TemporaryPath
                throw 'SWALLOWED_GUARD_POST_WRITE_SENTINEL'
            }
            & $immutableWriter -Path $Path -Value $Value -AllowedRunRoot $AllowedRunRoot -TemporaryPath $TemporaryPath
        }.GetNewClosure()
        $execution = $null
        try {
            $execution = Invoke-SecurityPilotFailureCase -FailureRole candidate -FailureCode '' -SwallowGuardFailure
            Assert-Equal $fault.injected 1
            Assert-SequenceEqual @($execution.calls) @($case.calls)
            Assert-Equal $execution.result.run_state 'indeterminate'
            Assert-Equal $execution.result.stop_reason 'artifact_persistence_failed'
            Assert-Equal $execution.result.slots_consumed.total $case.claims
            Assert-Equal $execution.result.launcher_processes_started.total $case.starts
            Assert-SequenceEqual @($execution.result.attempts.state) @($case.states)
            for ($prior = 0; $prior -lt ($case.ordinal - 1); $prior++) {
                Assert-Equal (Get-CalibrationObjectSha256 -Value $execution.result.attempts[$prior]) `
                    (Get-CalibrationObjectSha256 -Value $fault.persisted.attempts[$prior])
            }
            Assert-Equal (Get-CalibrationObjectSha256 -Value $execution.result.quality) `
                (Get-CalibrationObjectSha256 -Value $fault.persisted.quality)
            $runRoot = Join-Path $execution.input.results_root 'option1-live-20260826-002'
            Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $runRoot 'claims') -File -Force).Count $case.claims
            $persisted = Get-Content -Raw -LiteralPath (Join-Path $runRoot 'result.json') | ConvertFrom-Json -Depth 100
            Assert-Equal $persisted.run_state 'indeterminate'
            Assert-Equal $persisted.slots_consumed.total $case.claims
            Assert-Equal $persisted.launcher_processes_started.total $case.starts
            Assert-SequenceEqual @($persisted.attempts.state) @($case.states)
            $resumeCalls = [pscustomobject]@{ count = 0 }
            $resumeSpy = { $resumeCalls.count++; throw 'resume reached invoker' }.GetNewClosure()
            $null = Assert-Throws {
                Invoke-Calibration -Pilot -Run -RunId 'option1-live-20260826-002' `
                    -ResultsRoot $execution.input.results_root -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot `
                    -CandidateInvoker $resumeSpy -JudgeInvoker $resumeSpy `
                    -PilotGitInvoker { [pscustomobject]@{ clean = $true; commit = ('d' * 40) } } | Out-Null
            } 'pilot_run_collision'
            Assert-Equal $resumeCalls.count 0
        } finally {
            Set-Item -Path Function:\Write-CalibrationAtomicResultJson -Value $immutableWriter
            if ($null -ne $execution) { Remove-SecurityPilotLedgerRoot -Path $execution.input.results_root }
        }
    }
}

Invoke-Assertion 'swallowed launch-guard recovery rejects a persisted result outside both exact reservation shapes' {
    $originalWriterText = (Get-Command -Name Write-CalibrationAtomicResultJson -CommandType Function -ErrorAction Stop).ScriptBlock.ToString()
    $immutableWriter = [scriptblock]::Create($originalWriterText)
    $fault = [pscustomobject]@{ armed = $true }
    Set-Item -Path Function:\Write-CalibrationAtomicResultJson -Value {
        param($Path, $Value, $AllowedRunRoot, $TemporaryPath)
        if ($fault.armed -and (Test-SecurityPilotLedgerFaultStage -Stage 'slot_reservation' -Value $Value)) {
            $fault.armed = $false
            & $immutableWriter -Path $Path -Value $Value -AllowedRunRoot $AllowedRunRoot -TemporaryPath $TemporaryPath
            throw 'SWALLOWED_GUARD_POST_WRITE_SENTINEL'
        }
        & $immutableWriter -Path $Path -Value $Value -AllowedRunRoot $AllowedRunRoot -TemporaryPath $TemporaryPath
    }.GetNewClosure()
    $execution = $null
    try {
        $guardMutation = {
            param($ResultsRoot, $RunId, $Ordinal)
            $runRoot = Join-Path $ResultsRoot $RunId
            $resultPath = Join-Path $runRoot 'result.json'
            $drifted = Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json -Depth 100 -DateKind String
            $drifted.started_at = '2000-01-01T00:00:00.0000000+00:00'
            & $immutableWriter -Path $resultPath -Value $drifted -AllowedRunRoot $runRoot
        }.GetNewClosure()
        $thrown = Assert-Throws {
            $execution = Invoke-SecurityPilotFailureCase -FailureRole candidate -FailureCode '' `
                -SwallowGuardFailure -GuardFailureMutation $guardMutation
        } 'pilot_claim_artifact_invalid'
        Assert-SequenceEqual @($thrown.Data['pilot_test_calls']) @('candidate')
    } finally {
        Set-Item -Path Function:\Write-CalibrationAtomicResultJson -Value $immutableWriter
        if ($null -ne $execution) { Remove-SecurityPilotLedgerRoot -Path $execution.input.results_root }
    }
}

Invoke-Assertion 'swallowed launch-guard recovery rejects malformed mismatched and extra claim artifacts without later calls' {
    $cases = @(
        [pscustomobject]@{ mutation = 'malformed'; stage = 'slot_reservation'; calls = @('candidate') },
        [pscustomobject]@{ mutation = 'extra'; stage = 'slot_reservation'; calls = @('candidate') },
        [pscustomobject]@{ mutation = 'missing_prior'; stage = 'judge_slot_reservation'; calls = @('candidate', 'judge_1') }
    )
    foreach ($case in $cases) {
        $originalWriterText = (Get-Command -Name Write-CalibrationAtomicResultJson -CommandType Function -ErrorAction Stop).ScriptBlock.ToString()
        $immutableWriter = [scriptblock]::Create($originalWriterText)
        $fault = [pscustomobject]@{ armed = $true }
        Set-Item -Path Function:\Write-CalibrationAtomicResultJson -Value {
            param($Path, $Value, $AllowedRunRoot, $TemporaryPath)
            if ($fault.armed -and (Test-SecurityPilotLedgerFaultStage -Stage $case.stage -Value $Value)) {
                $fault.armed = $false
                throw 'SWALLOWED_GUARD_RESULT_WRITE_SENTINEL'
            }
            & $immutableWriter -Path $Path -Value $Value -AllowedRunRoot $AllowedRunRoot -TemporaryPath $TemporaryPath
        }.GetNewClosure()
        $execution = $null
        try {
            $guardMutation = {
                param($ResultsRoot, $RunId, $Ordinal)
                $claims = Join-Path (Join-Path $ResultsRoot $RunId) 'claims'
                if ($case.mutation -ceq 'malformed') {
                    Set-Content -LiteralPath (Join-Path $claims '01-google-candidate.claim') -Value '{}' -Encoding utf8NoBOM
                } elseif ($case.mutation -ceq 'extra') {
                    Set-Content -LiteralPath (Join-Path $claims 'unexpected.claim') -Value '{}' -Encoding utf8NoBOM
                } else {
                    Remove-Item -LiteralPath (Join-Path $claims '01-google-candidate.claim') -Force
                }
            }.GetNewClosure()
            $thrown = Assert-Throws {
                $execution = Invoke-SecurityPilotFailureCase -FailureRole candidate -FailureCode '' `
                    -SwallowGuardFailure -GuardFailureMutation $guardMutation
            } $null
            Assert-True $thrown.Message.Contains('pilot_claim_artifact_invalid', [StringComparison]::Ordinal) `
                "$($case.mutation) recovery returned '$($thrown.Message)'."
            Assert-False $thrown.Message.Contains('pilot_claim_counter_mismatch', [StringComparison]::Ordinal)
            Assert-SequenceEqual @($thrown.Data['pilot_test_calls']) @($case.calls)
        } finally {
            Set-Item -Path Function:\Write-CalibrationAtomicResultJson -Value $immutableWriter
        }
    }
}

Invoke-Assertion 'option 1 failure artifacts exclude unsafe fields and do not mutate sources or routing traces' {
    $sentinels = @('CREDENTIAL_SENTINEL_99', 'ENVIRONMENT_SENTINEL_99', 'PROMPT_ECHO_SENTINEL_99',
        'ARGUMENTS_SENTINEL_99', 'STDOUT_SENTINEL_99', 'STDERR_SENTINEL_99',
        'PROVIDER_EVENT_SENTINEL_99', 'EXCEPTION_SENTINEL_99')
    $before = Get-SecurityFileHashes
    $originalTraceText = (Get-Command -Name Write-RouterTrace -CommandType Function -ErrorAction Stop).ScriptBlock.ToString()
    $immutableTrace = [scriptblock]::Create($originalTraceText)
    $traceSentinel = [pscustomobject]@{ calls = 0; routing_decisions = 0; candidate_evaluations = 0 }
    Set-Item -Path Function:\Write-RouterTrace -Value {
        param($Trace)
        $traceSentinel.calls++
        $traceSentinel.routing_decisions++
        if ($null -ne $Trace -and $Trace.PSObject.Properties.Name -ccontains 'candidate_evaluations') {
            $traceSentinel.candidate_evaluations += @($Trace.candidate_evaluations).Count
        }
        throw 'routing trace sentinel reached'
    }.GetNewClosure()
    $execution = $null
    try {
        $execution = Invoke-SecurityPilotFailureCase -FailureRole judge_2 `
            -FailureCode response_contract_invalid -Sentinels $sentinels
        $after = Get-SecurityFileHashes
        Assert-SequenceEqual @($after) @($before)
        Assert-Equal $traceSentinel.calls 0
        Assert-Equal $traceSentinel.routing_decisions 0
        Assert-Equal $traceSentinel.candidate_evaluations 0
        Assert-Equal $execution.result.run_state 'stopped'
        Assert-Equal $execution.result.stop_reason 'response_contract_invalid'
        Assert-False $execution.result.profile_mutated
        Assert-False $execution.result.production_eligibility_changed
        $runRoot = Join-Path $execution.input.results_root 'option1-live-20260826-002'
        $artifacts = @(Get-ChildItem -LiteralPath $runRoot -File -Recurse | Where-Object {
            $_.Name -in @('plan.json', 'result.json', 'candidate-response.json', 'judge-responses.json')
        })
        Assert-True ($artifacts.Count -ge 3) 'Expected plan, result, and bounded raw artifacts.'
        foreach ($artifact in $artifacts) {
            $parsed = Get-Content -Raw -LiteralPath $artifact.FullName | ConvertFrom-Json -Depth 100
            $recursive = @(Get-RecursiveKeysAndStrings $parsed) -join "`n"
            foreach ($sentinel in $sentinels) {
                Assert-False $recursive.Contains($sentinel, [StringComparison]::Ordinal) `
                    "Artifact '$($artifact.Name)' leaked $sentinel."
            }
        }
    } finally {
        Set-Item -Path Function:\Write-RouterTrace -Value $immutableTrace
        if ($null -ne $execution) { Remove-SecurityPilotLedgerRoot -Path $execution.input.results_root }
    }
    Assert-Equal (Get-Command -Name Write-RouterTrace -CommandType Function -ErrorAction Stop).ScriptBlock.ToString() $originalTraceText
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

Invoke-Assertion 'security failure fixtures leave no owned pilot result roots' {
    $ownedRoots = @(Get-ChildItem -LiteralPath $resultsRoot -Directory -Force | Where-Object {
        $_.Name -match '^pilot-ledger-security-[0-9a-f]{32}$'
    })
    Assert-Equal $ownedRoots.Count 0
}

Invoke-Assertion 'launcher lock admission rejects duplicate keys, extra fields, unsafe locators, malformed hashes, and structural omissions' {
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('launcher-lock-security-{0}' -f [guid]::NewGuid().ToString('N'))
    $schemaPath = Join-Path $calibrationRoot 'pilots/option1-launchers.schema.json'
    $canonicalPath = Join-Path $calibrationRoot 'pilots/option1-launchers-v1.json'
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $calibrationRoot 'pilots/option1-three-launch-v1.json') |
        ConvertFrom-Json -Depth 100
    try {
        $null = New-Item -ItemType Directory -Path $temporary
        $canonical = Get-Content -Raw -LiteralPath $canonicalPath | ConvertFrom-Json -Depth 100
        $cases = @(
            [pscustomobject]@{ name = 'extra-root'; mutate = { param($v) $v | Add-Member extra 'SENSITIVE_SENTINEL' } },
            [pscustomobject]@{ name = 'wrong-role-order'; mutate = { param($v) $first=$v.roles[0]; $v.roles[0]=$v.roles[1]; $v.roles[1]=$first } },
            [pscustomobject]@{ name = 'wrong-role-case'; mutate = { param($v) $v.roles[0].role = 'Candidate' } },
            [pscustomobject]@{ name = 'wrong-route'; mutate = { param($v) $v.roles[1].route_id = 'codex__gpt_5_6_sol__low' } },
            [pscustomobject]@{ name = 'wrong-component-order'; mutate = { param($v) $first=$v.roles[1].components[0]; $v.roles[1].components[0]=$v.roles[1].components[1]; $v.roles[1].components[1]=$first } },
            [pscustomobject]@{ name = 'wrong-component-case'; mutate = { param($v) $v.roles[1].components[0].id = 'Codex_Shim' } },
            [pscustomobject]@{ name = 'wrong-kind'; mutate = { param($v) $v.roles[1].components[1].kind = 'package_manifest' } },
            [pscustomobject]@{ name = 'malformed-hash'; mutate = { param($v) $v.roles[0].components[0].sha256 = 'abc' } },
            [pscustomobject]@{ name = 'absolute'; mutate = { param($v) $v.roles[0].components[0].locator.relative_path = 'C:/private/agy.exe' } },
            [pscustomobject]@{ name = 'parent'; mutate = { param($v) $v.roles[0].components[0].locator.relative_path = '../agy.exe' } },
            [pscustomobject]@{ name = 'environment'; mutate = { param($v) $v.roles[0].components[0].locator.relative_path = '%LOCALAPPDATA%/agy.exe' } },
            [pscustomobject]@{ name = 'wildcard'; mutate = { param($v) $v.roles[0].components[0].locator.relative_path = 'agy*.exe' } },
            [pscustomobject]@{ name = 'wrong-locator'; mutate = { param($v) $v.roles[2].components[1].locator.relative_path = 'claude.exe' } },
            [pscustomobject]@{ name = 'shim-only-codex'; mutate = { param($v) $v.roles[1].components = @($v.roles[1].components[0]) } },
            [pscustomobject]@{ name = 'codex-native-omitted'; mutate = { param($v) $v.roles[1].components = @($v.roles[1].components[0..2]) } },
            [pscustomobject]@{ name = 'wrong-purpose'; mutate = { param($v) $v.roles[1].components[0].purpose = 'executed' } }
        )
        foreach ($case in $cases) {
            $value = $canonical | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
            $null = & $case.mutate $value
            $path = Join-Path $temporary ($case.name + '.json')
            $value | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
            $exception = Assert-Throws {
                Import-CalibrationPilotLauncherLock -Path $path -SchemaPath $schemaPath -Manifest $manifest | Out-Null
            } 'pilot_launcher_lock_invalid'
            Assert-False $exception.Message.Contains('SENSITIVE_SENTINEL', [StringComparison]::Ordinal)
            Assert-False $exception.Message.Contains($temporary, [StringComparison]::Ordinal)
        }
        $duplicatePath = Join-Path $temporary 'duplicate.json'
        $duplicate = (Get-Content -Raw -LiteralPath $canonicalPath).Replace(
            '"lock_version": "calibration-launcher-lock/v1",',
            '"lock_version": "calibration-launcher-lock/v1", "lock_version": "calibration-launcher-lock/v1",')
        [IO.File]::WriteAllText($duplicatePath, $duplicate, [Text.UTF8Encoding]::new($false))
        $null = Assert-Throws {
            Import-CalibrationPilotLauncherLock -Path $duplicatePath -SchemaPath $schemaPath -Manifest $manifest | Out-Null
        } 'pilot_launcher_lock_invalid'
    } finally { Remove-TestPath -Path $temporary }
}

Invoke-Assertion 'launcher lock source paths cannot be externally overridden without the explicit test seam' {
    $external = Join-Path ([IO.Path]::GetTempPath()) ('external-launcher-lock-{0}.json' -f [guid]::NewGuid().ToString('N'))
    try {
        Copy-Item -LiteralPath (Join-Path $calibrationRoot 'pilots/option1-launchers-v1.json') -Destination $external
        $null = Assert-Throws {
            Invoke-Calibration -Pilot -LauncherLockPath $external | Out-Null
        } 'pilot_source_path_not_canonical'
    } finally { Remove-TestPath -Path $external }
}

if ($script:Failures.Count -gt 0) {
    $script:Failures | ForEach-Object { Write-Host $_ }
    exit 1
}

Write-Host 'All calibration security tests passed.'
