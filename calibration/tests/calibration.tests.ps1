$ErrorActionPreference = 'Stop'

$script:Failures = [Collections.Generic.List[string]]::new()
$calibrationRoot = Split-Path -Parent $PSScriptRoot
$projectRoot = Split-Path -Parent $calibrationRoot
$implementationPath = Join-Path $calibrationRoot 'run_calibration.ps1'
$setPath = Join-Path $calibrationRoot 'calibration-set-v1.json'
$rubricsRoot = Join-Path $calibrationRoot 'rubrics'
$pilotManifestPath = Join-Path $calibrationRoot 'pilots/option1-three-launch-v1.json'
$pilotManifestSchemaPath = Join-Path $calibrationRoot 'pilots/option1-three-launch-manifest.schema.json'

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

function Invoke-Assertion {
    param([string]$Name, [scriptblock]$Test)
    try {
        & $Test
        Write-Host "PASS $Name"
    } catch {
        $script:Failures.Add("FAIL ${Name}: $($_.Exception.Message)")
    }
}

function Copy-TestObject {
    param([object]$Value)
    return $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100 -DateKind String
}

function Get-ObjectStringsAndKeys {
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

function New-TestDirectory {
    $path = Join-Path ([IO.Path]::GetTempPath()) ('router-calibration-test-{0}' -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path | Out-Null
    return $path
}

function Get-TestCalibrationObjectSha256 {
    param([Parameter(Mandatory)][object]$Value)
    $text = ConvertTo-TestCalibrationCanonicalJson -Value $Value
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function ConvertTo-TestCalibrationCanonicalJson {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [ValueType]) { return ($Value | ConvertTo-Json -Compress) }
    if ($Value -is [Collections.IDictionary]) {
        $keys = [Collections.Generic.List[string]]::new()
        foreach ($key in $Value.Keys) { $keys.Add([string]$key) }
        $keys.Sort([StringComparer]::Ordinal)
        return '{' + (($keys | ForEach-Object {
            (ConvertTo-TestCalibrationCanonicalJson -Value $_) + ':' + (ConvertTo-TestCalibrationCanonicalJson -Value $Value[$_])
        }) -join ',') + '}'
    }
    if ($Value -is [Collections.IEnumerable]) {
        return '[' + ((@($Value | ForEach-Object { ConvertTo-TestCalibrationCanonicalJson -Value $_ }) -join ',')) + ']'
    }
    $names = [Collections.Generic.List[string]]::new()
    foreach ($name in $Value.PSObject.Properties.Name) { $names.Add([string]$name) }
    $names.Sort([StringComparer]::Ordinal)
    return '{' + (($names | ForEach-Object {
        (ConvertTo-TestCalibrationCanonicalJson -Value $_) + ':' + (ConvertTo-TestCalibrationCanonicalJson -Value $Value.$_)
    }) -join ',') + '}'
}

function New-CalibrationResultsTestRoot {
    $path = Join-Path $calibrationRoot ('results/pilot-admission-{0}' -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path | Out-Null
    return $path
}

function New-TestCalibrationPilotLedgerInput {
    $leaf = 'pilot-ledger-{0}' -f [guid]::NewGuid().ToString('N')
    return [pscustomobject]@{
        results_root = Join-Path (Join-Path $calibrationRoot 'results') $leaf
        plan = Invoke-Calibration -Pilot -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot
    }
}

function Remove-TestCalibrationPilotLedgerRoot {
    param([Parameter(Mandatory)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $boundary = [IO.Path]::GetFullPath((Join-Path $calibrationRoot 'results')).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $leaf = [IO.Path]::GetFileName($fullPath)
    Assert-True ($fullPath.StartsWith(($boundary + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) `
        'Refusing to clean a pilot ledger root outside calibration/results.'
    Assert-True ($leaf -match '^pilot-ledger-[0-9a-f]{32}$') 'Refusing to clean a pilot ledger root not owned by this test.'
    if (Test-Path -LiteralPath $fullPath) { Remove-Item -LiteralPath $fullPath -Recurse -Force }
}

function New-TestCalibrationPilotCommand {
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

function New-TestCalibrationPilotExecution {
    param([Parameter(Mandatory)][object]$Candidate, [Parameter(Mandatory)][string]$Answer, [Parameter(Mandatory)][string]$RunId)
    return [pscustomobject][ordered]@{
        run_id = $RunId
        candidate = $Candidate
        process = [pscustomobject]@{ exit_code = 0; duration_ms = 1; timed_out = $false; cleanup_failed = $false; cleanup_status = 'not_required'; process_exited = $true }
        canonical = [pscustomobject]@{ status = 'success'; answer = $Answer; error = $null }
        failure = $null
        diagnostic_note = 'completed'
        latency_ms = 1
        usage = [pscustomobject][ordered]@{
            actual_input_tokens = 12
            visible_output_tokens = 4
            reasoning_tokens = 0
            complete = $true
        }
        cli_reported_cost_usd = $null
        record = [pscustomobject]@{ diagnostic_note = 'completed' }
    }
}

function Assert-TestCalibrationPilotLaunchBoundary {
    param(
        [Parameter(Mandatory)][string]$ResultsRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][int]$Ordinal,
        [Parameter(Mandatory)][int]$ExpectedClaimCount
    )
    $runRoot = Join-Path $ResultsRoot $RunId
    $result = Get-Content -Raw -LiteralPath (Join-Path $runRoot 'result.json') | ConvertFrom-Json -Depth 100 -DateKind String
    Assert-Equal $result.run_state 'running'
    Assert-Equal $result.attempts[$Ordinal - 1].state 'slot_reserved'
    for ($index = 0; $index -lt ($Ordinal - 1); $index++) {
        Assert-Equal $result.attempts[$index].state 'succeeded'
    }
    Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $runRoot 'claims') -File -Force).Count $ExpectedClaimCount
    if ($Ordinal -ge 2) {
        Assert-True (Test-Path -LiteralPath (Join-Path $runRoot 'raw/candidate-response.json') -PathType Leaf)
    }
    if ($Ordinal -eq 3) {
        $judges = Get-Content -Raw -LiteralPath (Join-Path $runRoot 'raw/judge-responses.json') | ConvertFrom-Json -Depth 100
        Assert-Equal @($judges.normalized_decisions).Count 1
    }
}

function Assert-TestCalibrationPilotGraderBoundary {
    param(
        [Parameter(Mandatory)][string]$ResultsRoot,
        [Parameter(Mandatory)][string]$RunId
    )
    $runRoot = Join-Path $ResultsRoot $RunId
    $result = Get-Content -Raw -LiteralPath (Join-Path $runRoot 'result.json') | ConvertFrom-Json -Depth 100 -DateKind String
    Assert-Equal $result.run_state 'running'
    Assert-Equal $result.attempts[0].state 'succeeded'
    Assert-Equal $result.attempts[1].state 'planned'
    Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $runRoot 'claims') -File -Force).Count 1
    Assert-True (Test-Path -LiteralPath (Join-Path $runRoot 'raw/candidate-response.json') -PathType Leaf)
}

function Invoke-TestCalibrationPilotRun {
    param(
        [Parameter(Mandatory)][string]$CandidateAnswer,
        [Parameter(Mandatory)][ValidateSet('pass', 'fail')][string]$JudgeOneDecision,
        [Parameter(Mandatory)][ValidateSet('pass', 'fail')][string]$JudgeTwoDecision
    )
    $ledgerInput = New-TestCalibrationPilotLedgerInput
    $invocations = [Collections.Generic.List[string]]::new()
    $boundaryEvents = [Collections.Generic.List[string]]::new()
    $graderCalls = [pscustomobject]@{ count = 0 }
    $candidateInvoker = {
        param($Candidate, $Prompt, $LaunchGuard, $RunId)
        $command = New-TestCalibrationPilotCommand -Candidate $Candidate -Prompt $Prompt
        $null = & $LaunchGuard $Candidate $command
        Assert-TestCalibrationPilotLaunchBoundary -ResultsRoot $ledgerInput.results_root -RunId $RunId -Ordinal 1 -ExpectedClaimCount 1
        $boundaryEvents.Add('candidate:slot_reserved:claims=1')
        $invocations.Add([string]$Candidate.route_id)
        return New-TestCalibrationPilotExecution -Candidate $Candidate -Answer $CandidateAnswer -RunId $RunId
    }.GetNewClosure()
    $judgeInvoker = {
        param($JudgeProfileId, $JudgePayload, $PromptDefinition, $LaunchGuard, $RunId)
        $resolved = Get-CalibrationProfileAndCandidate -ConfigurationId $JudgeProfileId
        $command = New-TestCalibrationPilotCommand -Candidate $resolved.candidate -Prompt 'anonymized-judge-payload'
        $null = & $LaunchGuard $resolved.candidate $command
        $ordinal = if ($JudgeProfileId -ceq 'gpt-5.6-sol__max') { 2 } else { 3 }
        Assert-TestCalibrationPilotLaunchBoundary -ResultsRoot $ledgerInput.results_root -RunId $RunId `
            -Ordinal $ordinal -ExpectedClaimCount $ordinal
        $boundaryEvents.Add("judge$($ordinal - 1):slot_reserved:claims=$ordinal")
        $invocations.Add([string]$resolved.candidate.route_id)
        $decision = if ($JudgeProfileId -ceq 'gpt-5.6-sol__max') { $JudgeOneDecision } else { $JudgeTwoDecision }
        return [pscustomobject]@{
            pilot_execution = New-TestCalibrationPilotExecution -Candidate $resolved.candidate `
                -Answer ('{{"decision":"{0}","rationale":"sanitized {0} evidence"}}' -f $decision) -RunId $RunId
            decision = [pscustomobject]@{ decision = $decision; rationale = "sanitized $decision evidence" }
        }
    }.GetNewClosure()
    $graderInvoker = {
        param($Prompt, $ResponseText, $PythonExecutor, $PythonExecutable, $PythonTimeoutMilliseconds)
        Assert-TestCalibrationPilotGraderBoundary -ResultsRoot $ledgerInput.results_root -RunId 'option1-live-20260826-002'
        $boundaryEvents.Add('grader:candidate_persisted:claims=1')
        $graderCalls.count++
        return Invoke-CalibrationDeterministicGrader -Prompt $Prompt -ResponseText $ResponseText
    }.GetNewClosure()
    $gitInvoker = { [pscustomobject]@{ clean = $true; commit = ('a' * 40) } }
    try {
        $result = Invoke-Calibration -Pilot -Run -RunId 'option1-live-20260826-002' `
            -ResultsRoot $ledgerInput.results_root -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot `
            -CandidateInvoker $candidateInvoker -JudgeInvoker $judgeInvoker -GraderInvoker $graderInvoker `
            -PilotGitInvoker $gitInvoker
        return [pscustomobject]@{
            result = $result
            input = $ledgerInput
            invocations = @($invocations)
            boundary_events = @($boundaryEvents)
            local_grader_calls = $graderCalls.count
        }
    } catch {
        Remove-TestCalibrationPilotLedgerRoot -Path $ledgerInput.results_root
        throw
    }
}

function Get-CalibrationResultsTreeSnapshot {
    param([Parameter(Mandatory)][string]$Root)
    return @(
        Get-ChildItem -LiteralPath $Root -Force -Recurse |
        Sort-Object FullName |
        ForEach-Object {
            $relative = $_.FullName.Substring($Root.Length)
            if ($_.PSIsContainer) { "D|$relative" }
            else { "F|$relative|$($_.Length)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant())" }
        } |
        Sort-Object
    )
}

function Invoke-CalibrationCliCapture {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = (Get-Command pwsh -ErrorAction Stop).Source
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $null = $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $null = $process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{ exit_code = $process.ExitCode; stdout = $stdout; stderr = $stderr }
}

function Write-TestPilotMatrix {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][scriptblock]$Mutation)
    $matrix = Copy-TestObject (Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'pilot/model_matrix.json') | ConvertFrom-Json -Depth 100)
    $candidate = @($matrix.candidates | Where-Object { $_.route_id -ceq 'agy__gemini_3_7_flash_low__low' })
    Assert-Equal $candidate.Count 1
    & $Mutation $candidate[0]
    $path = Join-Path $Directory 'model_matrix.json'
    $matrix | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    return $path
}

function Write-TestPilotProfileRoot {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][scriptblock]$Mutation)
    $profilesRoot = Join-Path $Directory 'profiles'
    $destinationDirectory = Join-Path $profilesRoot 'agy'
    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    $profile = Copy-TestObject (Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'profiles/agy/gemini-3.7-flash-low__low.json') | ConvertFrom-Json -Depth 100)
    & $Mutation $profile
    $profile | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $destinationDirectory 'gemini-3.7-flash-low__low.json') -Encoding utf8NoBOM
    return $profilesRoot
}

function Copy-TestPilotProfilesRoot {
    param([Parameter(Mandatory)][string]$Directory)
    $profilesRoot = Join-Path $Directory ('profiles-{0}' -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $profilesRoot | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $projectRoot 'profiles') -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $profilesRoot -Recurse
    }
    return $profilesRoot
}

Invoke-Assertion 'Task 9 production script exists before behavioral checks' {
    Assert-True (Test-Path -LiteralPath $implementationPath -PathType Leaf) 'Missing calibration/run_calibration.ps1.'
}

if (Test-Path -LiteralPath $implementationPath -PathType Leaf) {
    . $implementationPath

    Invoke-Assertion 'option 1 pilot manifest resolves the exact approved three-launch contract' {
        $pilot = Import-CalibrationPilotManifest -Path $pilotManifestPath -SchemaPath $pilotManifestSchemaPath `
            -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot
        Assert-Equal ([string]$pilot.manifest.pilot_id) 'option1-three-launch-v1'
        Assert-Equal ([string]$pilot.prompt.id) 'extraction-low-general-v1'
        Assert-SequenceEqual @($pilot.roles.route_id) @(
            'agy__gemini_3_7_flash_low__low',
            'codex__gpt_5_6_sol__max',
            'claude__claude_opus_5__max'
        )
        Assert-Equal $pilot.manifest.limits.total 3
        Assert-False ([bool]$pilot.manifest.profile_promotion_allowed)
    }

    Invoke-Assertion 'option 1 pilot manifest rejects independent contract mutations' {
        $manifest = Get-Content -Raw -LiteralPath $pilotManifestPath | ConvertFrom-Json -Depth 100
        $mutations = @(
            { param($value) $value | Add-Member -NotePropertyName unexpected -NotePropertyValue 'nope' },
            { param($value) $value.limits.total = 4 },
            { param($value) $value.roles[0].route_id = 'agy__wrong__low' }
        )
        foreach ($mutation in $mutations) {
            $mutated = Copy-TestObject $manifest
            & $mutation $mutated
            Assert-Throws {
                Test-CalibrationPilotManifestObject -Manifest $mutated -SchemaPath $pilotManifestSchemaPath `
                    -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot | Out-Null
            } 'Pilot manifest' | Out-Null
        }
    }

    Invoke-Assertion 'option 1 pilot manifest rejects duplicate top-level and nested properties before conversion' {
        $temporary = New-TestDirectory
        try {
            $manifestText = Get-Content -Raw -LiteralPath $pilotManifestPath
            $duplicateTopLevel = $manifestText -replace '\r?\n}\s*$', ",`n  `"pilot_id`": `"option1-three-launch-v1`"`n}"
            $duplicateNested = $manifestText.Replace(
                '"id": "extraction-low-general-v1", "version": "1.0.0"',
                '"id": "extraction-low-general-v1", "id": "duplicate", "version": "1.0.0"')
            foreach ($case in @(
                [pscustomobject]@{ name = 'top-level'; text = $duplicateTopLevel }
                [pscustomobject]@{ name = 'nested'; text = $duplicateNested }
            )) {
                $path = Join-Path $temporary ("duplicate-$($case.name).json")
                Set-Content -LiteralPath $path -Value $case.text -Encoding utf8NoBOM
                Assert-Throws {
                    Import-CalibrationPilotManifest -Path $path -SchemaPath $pilotManifestSchemaPath `
                        -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot | Out-Null
                } $null | Out-Null
            }
        } finally {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
        }
    }

    Invoke-Assertion 'option 1 pilot rejects duplicate matrix and profile identities through isolated source paths' {
        $temporary = New-TestDirectory
        try {
            $manifest = Get-Content -Raw -LiteralPath $pilotManifestPath | ConvertFrom-Json -Depth 100
            $matrixPath = Join-Path $temporary 'duplicate-matrix.json'
            $matrixText = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'pilot/model_matrix.json')
            $matrixText = $matrixText.Replace(
                '"route_id": "agy__gemini_3_7_flash_low__low",',
                '"route_id": "agy__gemini_3_7_flash_low__low", "route_id": "duplicate",')
            Set-Content -LiteralPath $matrixPath -Value $matrixText -Encoding utf8NoBOM
            Assert-Throws {
                Test-CalibrationPilotManifestObject -Manifest $manifest -SchemaPath $pilotManifestSchemaPath `
                    -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot -MatrixPath $matrixPath | Out-Null
            } $null | Out-Null

            $profileRoot = Join-Path $temporary 'duplicate-profiles'
            $profilePath = Join-Path $profileRoot 'agy/gemini-3.7-flash-low__low.json'
            New-Item -ItemType Directory -Path (Split-Path -Parent $profilePath) -Force | Out-Null
            $profileText = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'profiles/agy/gemini-3.7-flash-low__low.json')
            $profileText = $profileText.Replace(
                '"configuration_id": "gemini-3.7-flash-low__low",',
                '"configuration_id": "gemini-3.7-flash-low__low", "configuration_id": "duplicate",')
            Set-Content -LiteralPath $profilePath -Value $profileText -Encoding utf8NoBOM
            Assert-Throws {
                Test-CalibrationPilotManifestObject -Manifest $manifest -SchemaPath $pilotManifestSchemaPath `
                    -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot -ProfilesRoot $profileRoot | Out-Null
            } $null | Out-Null
        } finally {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
        }
    }

    Invoke-Assertion 'option 1 pilot rejects non-Boolean or disabled matrix and profile candidates' {
        $temporary = New-TestDirectory
        try {
            $manifest = Get-Content -Raw -LiteralPath $pilotManifestPath | ConvertFrom-Json -Depth 100
            foreach ($case in @(
                [pscustomobject]@{ name = 'false'; value = $false; expected = 'is disabled' }
                [pscustomobject]@{ name = 'string'; value = 'false'; expected = 'enabled must be a Boolean' }
                [pscustomobject]@{ name = 'numeric'; value = 1; expected = 'enabled must be a Boolean' }
                [pscustomobject]@{ name = 'missing'; value = $null; expected = 'enabled must be a Boolean' }
            )) {
                $matrixPath = Write-TestPilotMatrix -Directory $temporary -Mutation {
                    param($candidate)
                    if ($case.name -ceq 'missing') { $candidate.PSObject.Properties.Remove('enabled') }
                    else { $candidate.enabled = $case.value }
                }
                Assert-Throws {
                    Test-CalibrationPilotManifestObject -Manifest $manifest -SchemaPath $pilotManifestSchemaPath `
                        -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot -MatrixPath $matrixPath | Out-Null
                } $null | Out-Null
            }
            foreach ($case in @(
                [pscustomobject]@{ name = 'false'; value = $false; expected = 'enabled values disagree' }
                [pscustomobject]@{ name = 'string'; value = 'false'; expected = 'enabled must be a Boolean' }
                [pscustomobject]@{ name = 'numeric'; value = 1; expected = 'enabled must be a Boolean' }
                [pscustomobject]@{ name = 'missing'; value = $null; expected = 'enabled must be a Boolean' }
            )) {
                $profileRoot = Write-TestPilotProfileRoot -Directory $temporary -Mutation {
                    param($profile)
                    if ($case.name -ceq 'missing') { $profile.PSObject.Properties.Remove('enabled') }
                    else { $profile.enabled = $case.value }
                }
                Assert-Throws {
                    Test-CalibrationPilotManifestObject -Manifest $manifest -SchemaPath $pilotManifestSchemaPath `
                        -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot -ProfilesRoot $profileRoot | Out-Null
                } $null | Out-Null
            }
        } finally {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
        }
    }

    Invoke-Assertion 'option 1 pilot rejects non-scalar bound identity fields and ordinal values' {
        $temporary = New-TestDirectory
        try {
            $manifest = Get-Content -Raw -LiteralPath $pilotManifestPath | ConvertFrom-Json -Depth 100
            $invalidScalars = @(
                [pscustomobject]@{ value = [object[]]@('one-item-array') },
                [pscustomobject]@{ value = [pscustomobject]@{ value = 'object' } },
                [pscustomobject]@{ value = $null },
                [pscustomobject]@{ value = 7 }
            )
            $matrixCases = @(
                'route_id', 'tool', 'provider', 'model', 'effort', 'candidate_kind'
            )
            foreach ($field in $matrixCases) {
                foreach ($invalidCase in $invalidScalars) {
                    $invalid = $invalidCase.value
                    $matrixPath = Write-TestPilotMatrix -Directory $temporary -Mutation { param($candidate) $candidate.$field = $invalid }
                    $null = Assert-Throws {
                        Test-CalibrationPilotManifestObject -Manifest $manifest -SchemaPath $pilotManifestSchemaPath `
                            -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot -MatrixPath $matrixPath | Out-Null
                    } $null
                }
            }
            foreach ($field in @('configuration_id', 'launcher', 'provider', 'model', 'effort')) {
                foreach ($invalidCase in $invalidScalars) {
                    $invalid = $invalidCase.value
                    $profileRoot = Write-TestPilotProfileRoot -Directory $temporary -Mutation { param($profile) $profile.$field = $invalid }
                    $null = Assert-Throws {
                        Test-CalibrationPilotManifestObject -Manifest $manifest -SchemaPath $pilotManifestSchemaPath `
                            -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot -ProfilesRoot $profileRoot | Out-Null
                    } $null
                }
            }
            foreach ($invalidCase in @(
                [pscustomobject]@{ value = [object[]]@(1) },
                [pscustomobject]@{ value = [pscustomobject]@{ value = 1 } },
                [pscustomobject]@{ value = $null },
                [pscustomobject]@{ value = '1' }
            )) {
                $invalid = $invalidCase.value
                $mutated = Copy-TestObject $manifest
                $mutated.roles[0].ordinal = $invalid
                $null = Assert-Throws {
                    Test-CalibrationPilotManifestObject -Manifest $mutated -SchemaPath $pilotManifestSchemaPath `
                        -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot | Out-Null
                } $null
            }
        } finally {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
        }
    }

    Invoke-Assertion 'calibration set validates and contains the exact approved coverage' {
        $loaded = Import-CalibrationSet -Path $setPath -RubricsRoot $rubricsRoot
        Assert-True $loaded.valid (($loaded.errors | ConvertTo-Json -Compress -Depth 20))
        Assert-Equal @($loaded.set.prompts).Count 24
        Assert-Equal ([string]$loaded.set.version) 'calibration-set-v1'

        $taskTypes = @('general', 'coding', 'math', 'reasoning', 'writing', 'summarization', 'extraction', 'research_synthesis')
        $complexities = @('low', 'medium', 'high')
        foreach ($taskType in $taskTypes) {
            foreach ($complexity in $complexities) {
                Assert-Equal @($loaded.set.prompts | Where-Object {
                    $_.request.task_type -ceq $taskType -and $_.request.complexity -ceq $complexity
                }).Count 1
            }
        }

        $domains = @($loaded.set.prompts.request.domain | Sort-Object -Unique)
        Assert-SequenceEqual $domains @(
            'biology', 'business', 'chemistry', 'computer_science', 'engineering', 'finance',
            'general', 'humanities', 'law', 'mathematics', 'medicine', 'physics', 'social_science'
        )
        foreach ($prompt in $loaded.set.prompts) {
            Assert-True (-not [string]::IsNullOrWhiteSpace([string]$prompt.version))
            Assert-Equal ([string]$prompt.request.privacy_level) 'standard'
            Assert-Equal ([string]$prompt.request.risk_level) 'standard'
            Assert-Equal ([string]$prompt.request.language) 'english'
            Assert-True (-not [string]::IsNullOrWhiteSpace([string]$prompt.grading.rubric_ref))
        }
    }

    Invoke-Assertion 'objective prompt families declare deterministic graders appropriate to their task' {
        $set = (Import-CalibrationSet -Path $setPath -RubricsRoot $rubricsRoot).set
        foreach ($prompt in @($set.prompts | Where-Object { $_.request.task_type -ceq 'coding' })) {
            Assert-Equal $prompt.grading.deterministic_grader.type 'executable_tests'
            Assert-True @($prompt.grading.deterministic_grader.tests).Count
        }
        foreach ($prompt in @($set.prompts | Where-Object {
            $_.request.task_type -ceq 'math' -or $_.request.domain -in @('physics', 'chemistry', 'biology')
        })) {
            Assert-Equal $prompt.grading.deterministic_grader.type 'verified_answer'
            Assert-True @($prompt.grading.deterministic_grader.required_reasoning).Count
        }
        foreach ($prompt in @($set.prompts | Where-Object { $_.request.task_type -ceq 'extraction' })) {
            Assert-Equal $prompt.grading.deterministic_grader.type 'exact_fields'
            Assert-True ($null -ne $prompt.grading.deterministic_grader.expected)
        }
        foreach ($prompt in @($set.prompts | Where-Object { $_.request.task_type -ceq 'summarization' })) {
            Assert-Equal $prompt.grading.deterministic_grader.type 'summary_checks'
            Assert-True @($prompt.grading.deterministic_grader.required_facts).Count
            Assert-True ($prompt.grading.deterministic_grader.PSObject.Properties.Name -ccontains 'forbidden_claims')
        }
        foreach ($prompt in @($set.prompts | Where-Object { $_.request.task_type -in @('writing', 'research_synthesis') })) {
            Assert-True (-not [string]::IsNullOrWhiteSpace([string]$prompt.grading.rubric_ref))
        }
    }

    Invoke-Assertion 'judge pairs are exact, cross-family, and never self-only' {
        $expected = @{
            openai = @('claude-opus-5__max', 'gemini-3.7-flash-high__high')
            'gpt-oss' = @('claude-opus-5__max', 'gemini-3.7-flash-high__high')
            anthropic = @('gpt-5.6-sol__max', 'gemini-3.7-flash-high__high')
            google = @('gpt-5.6-sol__max', 'claude-opus-5__max')
        }
        foreach ($family in $expected.Keys) {
            $pair = @(Get-CalibrationJudgePair -CandidateFamily $family)
            Assert-SequenceEqual $pair $expected[$family]
            Assert-Equal $pair.Count 2
            Assert-Equal @($pair | Sort-Object -Unique).Count 2
        }
    }

    Invoke-Assertion 'default dry-run emits a deterministic plan and invokes neither router nor judges' {
        $script:RouterCalls = 0
        $script:JudgeCalls = 0
        $routerSpy = { $script:RouterCalls++; throw 'dry-run invoked router' }
        $judgeSpy = { $script:JudgeCalls++; throw 'dry-run invoked judge' }
        $first = Invoke-Calibration -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot `
            -RouterInvoker $routerSpy -JudgeInvoker $judgeSpy
        $second = Invoke-Calibration -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot `
            -RouterInvoker $routerSpy -JudgeInvoker $judgeSpy
        Assert-Equal $first.mode 'dry-run'
        Assert-Equal @($first.plan).Count 24
        Assert-Equal $script:RouterCalls 0
        Assert-Equal $script:JudgeCalls 0
        Assert-Equal ($first | ConvertTo-Json -Depth 100 -Compress) ($second | ConvertTo-Json -Depth 100 -Compress)
    }

    Invoke-Assertion 'shared calibration-set object validator preserves importer results for checked-in sources' {
        $imported = Import-CalibrationSet -Path $setPath -RubricsRoot $rubricsRoot
        $entries = New-CalibrationRubricEntriesFromFiles -SetValue $imported.set -RubricsRoot $rubricsRoot
        $shared = Test-CalibrationSetObject -SetValue $imported.set -RubricEntriesByRef $entries
        Assert-Equal $shared.valid $imported.valid
        Assert-SequenceEqual @($shared.errors) @($imported.errors)
        Assert-Equal $shared.set.version $imported.set.version
        Assert-Equal @($shared.set.prompts).Count @($imported.set.prompts).Count
        Assert-SequenceEqual @($shared.rubrics.Keys | Sort-Object) @($imported.rubrics.Keys | Sort-Object)
    }

    Invoke-Assertion 'shared calibration-set validator preserves importer contract for malformed prompt and rubric sources' {
        $temporary = New-TestDirectory
        try {
            $nonSelectedId = 'general-low-biology-v1'
            $cases = @(
                [pscustomobject]@{ name = 'missing request field'; mutate = { param($set) (@($set.prompts | Where-Object { $_.id -ceq $nonSelectedId })[0]).request.PSObject.Properties.Remove('language') } },
                [pscustomobject]@{ name = 'wrong task type'; mutate = { param($set) (@($set.prompts | Where-Object { $_.id -ceq $nonSelectedId })[0]).request.task_type = 'invalid-task' } },
                [pscustomobject]@{ name = 'wrong domain'; mutate = { param($set) (@($set.prompts | Where-Object { $_.id -ceq $nonSelectedId })[0]).request.domain = 'invalid-domain' } },
                [pscustomobject]@{ name = 'wrong complexity'; mutate = { param($set) (@($set.prompts | Where-Object { $_.id -ceq $nonSelectedId })[0]).request.complexity = 'invalid-complexity' } },
                [pscustomobject]@{ name = 'wrong quality'; mutate = { param($set) (@($set.prompts | Where-Object { $_.id -ceq $nonSelectedId })[0]).request.quality_floor = 'invalid-quality' } },
                [pscustomobject]@{ name = 'wrong privacy'; mutate = { param($set) (@($set.prompts | Where-Object { $_.id -ceq $nonSelectedId })[0]).request.privacy_level = 'private' } },
                [pscustomobject]@{ name = 'wrong risk'; mutate = { param($set) (@($set.prompts | Where-Object { $_.id -ceq $nonSelectedId })[0]).request.risk_level = 'high' } },
                [pscustomobject]@{ name = 'wrong language'; mutate = { param($set) (@($set.prompts | Where-Object { $_.id -ceq $nonSelectedId })[0]).request.language = 'spanish' } },
                [pscustomobject]@{ name = 'duplicate prompt id'; mutate = { param($set) $set.prompts[1].id = $set.prompts[0].id } },
                [pscustomobject]@{ name = 'wrong prompt count'; mutate = { param($set) $set.prompts = @($set.prompts | Select-Object -First 23) } },
                [pscustomobject]@{ name = 'coverage drift'; mutate = { param($set) (@($set.prompts | Where-Object { $_.id -ceq $nonSelectedId })[0]).request.complexity = 'medium' } },
                [pscustomobject]@{ name = 'domain coverage drift'; mutate = { param($set) (@($set.prompts | Where-Object { $_.id -ceq $nonSelectedId })[0]).request.domain = 'general' } },
                [pscustomobject]@{ name = 'invalid deterministic grader'; mutate = { param($set) (@($set.prompts | Where-Object { $_.request.task_type -ceq 'coding' })[0]).grading.deterministic_grader = $null } },
                [pscustomobject]@{ name = 'sensitive request text'; mutate = { param($set) (@($set.prompts | Where-Object { $_.id -ceq $nonSelectedId })[0]).request.request_text = 'Synthetic api key label only.' } },
                [pscustomobject]@{ name = 'invalid rubric ref'; mutate = { param($set) (@($set.prompts | Where-Object { $_.id -ceq $nonSelectedId })[0]).grading.rubric_ref = '../escape.json' } },
                [pscustomobject]@{ name = 'missing rubric'; mutate = { param($set) (@($set.prompts | Where-Object { $_.id -ceq $nonSelectedId })[0]).grading.rubric_ref = 'missing-rubric.json' } },
                [pscustomobject]@{
                    name = 'invalid rubric object'
                    mutate = { param($set) }
                    mutateRubrics = {
                        param($root, $set)
                        $ref = [string]$set.prompts[0].grading.rubric_ref
                        $path = Join-Path $root $ref
                        $rubric = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -Depth 100
                        $rubric.PSObject.Properties.Remove('version')
                        $rubric | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
                    }
                }
            )
            foreach ($case in $cases) {
                $caseDirectory = Join-Path $temporary ($case.name -replace '[^A-Za-z0-9]', '-')
                New-Item -ItemType Directory -Path $caseDirectory | Out-Null
                $set = Copy-TestObject (Get-Content -Raw -LiteralPath $setPath | ConvertFrom-Json -Depth 100)
                $null = & $case.mutate $set
                $caseSetPath = Join-Path $caseDirectory 'calibration-set.json'
                $set | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $caseSetPath -Encoding utf8NoBOM
                $caseRubricsRoot = Join-Path $caseDirectory 'rubrics'
                Copy-Item -LiteralPath $rubricsRoot -Destination $caseRubricsRoot -Recurse
                if ($case.PSObject.Properties.Name -ccontains 'mutateRubrics') { $null = & $case.mutateRubrics $caseRubricsRoot $set }

                $imported = Import-CalibrationSet -Path $caseSetPath -RubricsRoot $caseRubricsRoot
                $parsed = Get-Content -Raw -LiteralPath $caseSetPath | ConvertFrom-Json -Depth 100
                $entries = New-CalibrationRubricEntriesFromFiles -SetValue $parsed -RubricsRoot $caseRubricsRoot
                $shared = Test-CalibrationSetObject -SetValue $parsed -RubricEntriesByRef $entries
                Assert-Equal $shared.valid $imported.valid
                Assert-SequenceEqual @($shared.errors) @($imported.errors)
                Assert-Equal $shared.set.version $imported.set.version
                Assert-Equal @($shared.set.prompts).Count @($imported.set.prompts).Count
                Assert-SequenceEqual @($shared.rubrics.Keys | Sort-Object) @($imported.rubrics.Keys | Sort-Object)
            }
        } finally {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
        }
    }

    Invoke-Assertion 'importer and pilot source bundle delegate to the same calibration-set validator' {
        $importerSource = (Get-Command -Name Import-CalibrationSet -CommandType Function -ErrorAction Stop).ScriptBlock.ToString()
        $bundleSource = (Get-Command -Name New-CalibrationPilotSourceBundle -CommandType Function -ErrorAction Stop).ScriptBlock.ToString()
        $sharedSource = (Get-Command -Name Test-CalibrationSetObject -CommandType Function -ErrorAction Stop).ScriptBlock.ToString()
        Assert-True $importerSource.Contains('Test-CalibrationSetObject', [StringComparison]::Ordinal)
        Assert-True $bundleSource.Contains('Test-CalibrationSetObject', [StringComparison]::Ordinal)
        Assert-True $sharedSource.Contains('calibration_prompt_sensitive:', [StringComparison]::Ordinal)
        Assert-False $importerSource.Contains('calibration_prompt_sensitive:', [StringComparison]::Ordinal)
        Assert-False $bundleSource.Contains('calibration_prompt_sensitive:', [StringComparison]::Ordinal)
    }

    Invoke-Assertion 'pilot source bundle retains the exact byte text value and hash snapshot for every accepted source' {
        $bundle = New-CalibrationPilotSourceBundle -PilotManifestPath $pilotManifestPath -PilotManifestSchemaPath $pilotManifestSchemaPath `
            -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot
        foreach ($source in @(
            $bundle.sources.manifest, $bundle.sources.manifest_schema, $bundle.sources.matrix, $bundle.sources.calibration_set,
            $bundle.sources.model_profile_schema, $bundle.sources.response_schema,
            $bundle.sources.launcher_lock, $bundle.sources.launcher_lock_schema
        )) {
            Assert-True ($source.bytes -is [byte[]]) 'A source snapshot must retain its original bytes.'
            Assert-True ($source.text -is [string]) 'A source snapshot must retain its strict UTF-8 text.'
            Assert-True ($null -ne $source.value) 'A source snapshot must retain its parsed value.'
            Assert-Equal ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($source.bytes)).ToLowerInvariant()) $source.sha256
        }
        Assert-Equal @($bundle.sources.profiles.Keys).Count 3
        Assert-True (@($bundle.sources.rubrics.Keys).Count -gt 0)
        foreach ($source in @($bundle.sources.profiles.Values) + @($bundle.sources.rubrics.Values)) {
            Assert-True ($source.bytes -is [byte[]]) 'Captured profile and rubric sources must retain original bytes.'
            Assert-Equal ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($source.bytes)).ToLowerInvariant()) $source.sha256
        }
    }

    Invoke-Assertion 'pilot admission binds its exact ordered judges to the google calibration pair' {
        $original = (Get-Command -Name Get-CalibrationJudgePair -CommandType Function -ErrorAction Stop).ScriptBlock
        try {
            Set-Item -Path Function:\Get-CalibrationJudgePair -Value {
                param([string]$CandidateFamily)
                if ($CandidateFamily -ceq 'google') { return @('claude-opus-5__max', 'gpt-5.6-sol__max') }
                throw 'unexpected family'
            }
            $null = Assert-Throws {
                New-CalibrationPilotSourceBundle -PilotManifestPath $pilotManifestPath `
                    -PilotManifestSchemaPath $pilotManifestSchemaPath -CalibrationSetPath $setPath `
                    -RubricsRoot $rubricsRoot | Out-Null
            } 'Pilot judge pair differs from calibration policy'
        } finally {
            Set-Item -Path Function:\Get-CalibrationJudgePair -Value $original
        }
    }

    Invoke-Assertion 'canonical pilot hashes ignore object insertion order but preserve array order and values' {
        $left = [pscustomobject][ordered]@{ z = 1; a = @('first', 'second'); nested = [pscustomobject][ordered]@{ b = $true; a = $null } }
        $right = [pscustomobject][ordered]@{ nested = [pscustomobject][ordered]@{ a = $null; b = $true }; a = @('first', 'second'); z = 1 }
        $changedArray = [pscustomobject][ordered]@{ a = @('second', 'first'); nested = [pscustomobject][ordered]@{ a = $null; b = $true }; z = 1 }
        Assert-Equal (Get-CalibrationObjectSha256 -Value $left) (Get-CalibrationObjectSha256 -Value $right)
        Assert-False ((Get-CalibrationObjectSha256 -Value $left) -ceq (Get-CalibrationObjectSha256 -Value $changedArray))
        foreach ($pair in @(
            @([pscustomobject]@{ value = '1' }, [pscustomobject]@{ value = 1 }),
            @([pscustomobject]@{ value = $true }, [pscustomobject]@{ value = 1 }),
            @([pscustomobject]@{ value = $null }, [pscustomobject]@{ value = '' }),
            @([pscustomobject]@{ nested = [pscustomobject]@{ value = 'left' } }, [pscustomobject]@{ nested = [pscustomobject]@{ value = 'right' } }),
            @([pscustomobject]@{ values = @($null, 'x') }, [pscustomobject]@{ values = @('x', $null) })
        )) {
            Assert-False ((Get-CalibrationObjectSha256 -Value $pair[0]) -ceq (Get-CalibrationObjectSha256 -Value $pair[1]))
        }
    }

    Invoke-Assertion 'pilot source bundle rejects invalid response schemas and binds a plan to its parsed snapshot' {
        $temporary = New-TestDirectory
        try {
            $responseSchemaPath = Join-Path $temporary 'response-schema.json'
            Set-Content -LiteralPath $responseSchemaPath -Value '{"type":"unsupported"}' -Encoding utf8NoBOM
            $null = Assert-Throws {
                New-CalibrationPilotSourceBundle -PilotManifestPath $pilotManifestPath -PilotManifestSchemaPath $pilotManifestSchemaPath `
                    -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot -ResponseSchemaPath $responseSchemaPath | Out-Null
            } 'response schema'

            Copy-Item -LiteralPath (Join-Path $projectRoot 'pilot/shared/response_schema.json') -Destination $responseSchemaPath -Force
            $bundle = New-CalibrationPilotSourceBundle -PilotManifestPath $pilotManifestPath -PilotManifestSchemaPath $pilotManifestSchemaPath `
                -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot -ResponseSchemaPath $responseSchemaPath
            $before = $bundle.hashes.response_schema
            Set-Content -LiteralPath $responseSchemaPath -Value '{"type":"object","properties":{}}' -Encoding utf8NoBOM
            $plan = New-CalibrationPilotPlan -SourceBundle $bundle
            Assert-Equal $plan.source_hashes.response_schema $before
        } finally {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
        }
    }

    Invoke-Assertion 'production pilot source bundle validates complete captured model profiles before identity binding' {
        $temporary = New-TestDirectory
        try {
            foreach ($case in @(
                [pscustomobject]@{ name = 'missing quality'; mutate = { param($profile) $profile.PSObject.Properties.Remove('quality') } }
                [pscustomobject]@{ name = 'extra profile field'; mutate = { param($profile) $profile | Add-Member -NotePropertyName unexpected -NotePropertyValue $true } }
                [pscustomobject]@{ name = 'wrong nested type'; mutate = { param($profile) $profile.quality.task_types.general = 7 } }
                [pscustomobject]@{ name = 'invalid quality enum'; mutate = { param($profile) $profile.quality.task_types.general = 'invalid-enum' } }
            )) {
                $profilesRoot = Copy-TestPilotProfilesRoot -Directory $temporary
                $profilePath = Join-Path $profilesRoot 'agy/gemini-3.7-flash-low__low.json'
                $profile = Get-Content -Raw -LiteralPath $profilePath | ConvertFrom-Json -Depth 100
                & $case.mutate $profile
                $profile | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $profilePath -Encoding utf8NoBOM
                $null = Assert-Throws {
                    New-CalibrationPilotSourceBundle -PilotManifestPath $pilotManifestPath -PilotManifestSchemaPath $pilotManifestSchemaPath `
                        -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot -ProfilesRoot $profilesRoot | Out-Null
                } 'profile schema validation failed'
            }
        } finally {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
        }
    }

    Invoke-Assertion 'non-pilot CLI failure envelope preserves the original three-property contract' {
        $output = & pwsh -NoProfile -File $implementationPath -Run -Route
        $exitCode = $LASTEXITCODE
        Assert-Equal $exitCode 1
        Assert-Equal @($output).Count 1
        $envelope = $output | ConvertFrom-Json -Depth 100
        Assert-SequenceEqual @($envelope.PSObject.Properties.Name) @('mode', 'error', 'message')
        Assert-Equal $envelope.mode 'run'
        Assert-Equal $envelope.error 'calibration_failed'
        Assert-Equal $envelope.message 'Run and Route are mutually exclusive.'
    }

    Invoke-Assertion 'pilot admission returns the immutable offline three-launch plan without calls or result writes' {
        $resultsRoot = New-CalibrationResultsTestRoot
        try {
            $before = Get-CalibrationResultsTreeSnapshot -Root $resultsRoot
            $script:PilotCandidateCalls = 0
            $script:PilotJudgeCalls = 0
            $candidateSpy = { $script:PilotCandidateCalls++; throw 'pilot plan executed a candidate' }
            $judgeSpy = { $script:PilotJudgeCalls++; throw 'pilot plan executed a judge' }
            $result = Invoke-Calibration -Pilot -ResultsRoot $resultsRoot `
                -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot `
                -CandidateInvoker $candidateSpy -JudgeInvoker $judgeSpy
            Assert-Equal $result.mode 'pilot-plan'
            Assert-SequenceEqual @($result.PSObject.Properties.Name) @('artifact_version', 'pilot_id', 'mode', 'selection_mode', 'prompt', 'roles', 'limits', 'source_hashes', 'provider_calls', 'provider_side_requests', 'profile_promotion_allowed', 'profile_mutated', 'production_eligibility_changed')
            Assert-Equal $result.artifact_version 'calibration-pilot-plan/v1'
            Assert-Equal $result.pilot_id 'option1-three-launch-v1'
            Assert-Equal $result.selection_mode 'calibration_only_exact_pin'
            Assert-Equal $result.prompt.id 'extraction-low-general-v1'
            Assert-Equal $result.prompt.version '1.0.0'
            Assert-SequenceEqual @($result.prompt.PSObject.Properties.Name) @('id', 'version')
            $expectedRoles = @(
                [pscustomobject][ordered]@{ ordinal = 1; role = 'candidate'; family = 'google'; launcher = 'agy'; route_id = 'agy__gemini_3_7_flash_low__low'; configuration_id = 'gemini-3.7-flash-low__low'; model = 'gemini-3.7-flash-low'; effort = 'low' }
                [pscustomobject][ordered]@{ ordinal = 2; role = 'judge_1'; family = 'openai'; launcher = 'codex'; route_id = 'codex__gpt_5_6_sol__max'; configuration_id = 'gpt-5.6-sol__max'; model = 'gpt-5.6-sol'; effort = 'max' }
                [pscustomobject][ordered]@{ ordinal = 3; role = 'judge_2'; family = 'anthropic'; launcher = 'claude'; route_id = 'claude__claude_opus_5__max'; configuration_id = 'claude-opus-5__max'; model = 'claude-opus-5'; effort = 'max' }
            )
            Assert-Equal @($result.roles).Count 3
            for ($index = 0; $index -lt $expectedRoles.Count; $index++) {
                $actualRole = $result.roles[$index]
                $expectedRole = $expectedRoles[$index]
                Assert-SequenceEqual @($actualRole.PSObject.Properties.Name) @('ordinal', 'role', 'family', 'launcher', 'route_id', 'configuration_id', 'model', 'effort')
                foreach ($name in @('ordinal', 'role', 'family', 'launcher', 'route_id', 'configuration_id', 'model', 'effort')) {
                    Assert-Equal $actualRole.$name $expectedRole.$name
                }
                Assert-False ($actualRole.PSObject.Properties.Name -ccontains 'candidate')
                Assert-False ($actualRole.PSObject.Properties.Name -ccontains 'profile')
            }
            Assert-Equal $result.limits.total 3
            Assert-SequenceEqual @($result.limits.PSObject.Properties.Name) @('total', 'provider_family', 'application_retries')
            Assert-SequenceEqual @($result.limits.provider_family.PSObject.Properties.Name) @('google', 'openai', 'anthropic')
            Assert-Equal $result.limits.provider_family.google 1
            Assert-Equal $result.limits.provider_family.openai 1
            Assert-Equal $result.limits.provider_family.anthropic 1
            Assert-Equal $result.limits.application_retries 0
            Assert-Equal $result.provider_calls 0
            Assert-SequenceEqual @($result.provider_side_requests.PSObject.Properties.Name) @('observable', 'count')
            Assert-False ([bool]$result.provider_side_requests.observable)
            Assert-Equal $result.provider_side_requests.count $null
            Assert-False ([bool]$result.profile_promotion_allowed)
            Assert-False ([bool]$result.profile_mutated)
            Assert-False ([bool]$result.production_eligibility_changed)
            $hashNames = @('manifest', 'matrix', 'candidate_profile', 'calibration_set', 'prompt_definition', 'rubric',
                'response_schema', 'launcher_lock', 'launcher_lock_schema')
            Assert-SequenceEqual @($result.source_hashes.PSObject.Properties.Name) $hashNames
            $validatedSources = Import-CalibrationPilotManifest -Path $pilotManifestPath -SchemaPath $pilotManifestSchemaPath `
                -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot
            $candidateProfilePath = Join-Path $projectRoot 'profiles/agy/gemini-3.7-flash-low__low.json'
            $expectedHashes = [ordered]@{
                manifest = (Get-FileHash -LiteralPath $pilotManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
                matrix = (Get-FileHash -LiteralPath (Join-Path $projectRoot 'pilot/model_matrix.json') -Algorithm SHA256).Hash.ToLowerInvariant()
                candidate_profile = Get-TestCalibrationObjectSha256 -Value (Get-Content -Raw -LiteralPath $candidateProfilePath | ConvertFrom-Json -Depth 100)
                calibration_set = (Get-FileHash -LiteralPath $setPath -Algorithm SHA256).Hash.ToLowerInvariant()
                prompt_definition = Get-TestCalibrationObjectSha256 -Value $validatedSources.prompt
                rubric = Get-TestCalibrationObjectSha256 -Value $validatedSources.rubric
                response_schema = (Get-FileHash -LiteralPath (Join-Path $projectRoot 'pilot/shared/response_schema.json') -Algorithm SHA256).Hash.ToLowerInvariant()
                launcher_lock = (Get-FileHash -LiteralPath (Join-Path $calibrationRoot 'pilots/option1-launchers-v1.json') -Algorithm SHA256).Hash.ToLowerInvariant()
                launcher_lock_schema = (Get-FileHash -LiteralPath (Join-Path $calibrationRoot 'pilots/option1-launchers.schema.json') -Algorithm SHA256).Hash.ToLowerInvariant()
            }
            foreach ($name in $hashNames) {
                $hash = [string]$result.source_hashes.$name
                Assert-True ($hash -cmatch '^[0-9a-f]{64}$') "Expected a lowercase SHA-256 for '$name'."
                Assert-Equal $hash $expectedHashes[$name]
            }
            Assert-Equal $script:PilotCandidateCalls 0
            Assert-Equal $script:PilotJudgeCalls 0
            $serializedPlan = $result | ConvertTo-Json -Depth 100 -Compress
            foreach ($forbidden in @('"request_text"', '"grading"', '"profile":', '"candidate":', 'raw source text')) {
                Assert-False $serializedPlan.Contains($forbidden, [StringComparison]::Ordinal)
            }
            Assert-SequenceEqual (Get-CalibrationResultsTreeSnapshot -Root $resultsRoot) $before
        } finally {
            if (Test-Path -LiteralPath $resultsRoot) { Remove-Item -LiteralPath $resultsRoot -Recurse -Force }
        }
    }

    Invoke-Assertion 'pilot ledger creates one claimed run with an exact safe initial result' {
        $input = New-TestCalibrationPilotLedgerInput
        $context = $null
        try {
            $context = New-CalibrationPilotRun -ResultsRoot $input.results_root -RunId 'ledger-test-001' -Plan $input.plan
            $runRoot = Join-Path $input.results_root 'ledger-test-001'
            Assert-SequenceEqual @(
                Get-ChildItem -LiteralPath $runRoot -Force | Sort-Object Name | ForEach-Object Name
            ) @('.run.claim', 'claims', 'plan.json', 'raw', 'result.json')
            $persistedPlan = Get-Content -Raw -LiteralPath (Join-Path $runRoot 'plan.json') | ConvertFrom-Json -Depth 100
            $result = Get-Content -Raw -LiteralPath (Join-Path $runRoot 'result.json') | ConvertFrom-Json -Depth 100
            Assert-Equal (Get-CalibrationObjectSha256 -Value $persistedPlan) (Get-CalibrationObjectSha256 -Value $input.plan)
            Assert-SequenceEqual @($result.PSObject.Properties.Name) @(
                'artifact_version', 'run_id', 'pilot_id', 'selection_mode', 'run_state', 'stop_reason',
                'started_at', 'finished_at', 'source_hashes', 'limits', 'attempts', 'slots_consumed',
                'launcher_processes_started', 'provider_side_requests', 'quality',
                'profile_promotion_allowed', 'profile_mutated', 'production_eligibility_changed'
            )
            Assert-Equal $result.artifact_version 'calibration-pilot-result/v1'
            Assert-Equal $result.run_id 'ledger-test-001'
            Assert-Equal $result.pilot_id 'option1-three-launch-v1'
            Assert-Equal $result.selection_mode 'calibration_only_exact_pin'
            Assert-Equal $result.run_state 'planned'
            Assert-True ($null -eq $result.stop_reason)
            Assert-True ($null -eq $result.started_at)
            Assert-True ($null -eq $result.finished_at)
            Assert-Equal (Get-CalibrationObjectSha256 -Value $result.source_hashes) (Get-CalibrationObjectSha256 -Value $input.plan.source_hashes)
            Assert-Equal (Get-CalibrationObjectSha256 -Value $result.limits) (Get-CalibrationObjectSha256 -Value $input.plan.limits)
            Assert-Equal @($result.attempts).Count 3
            for ($index = 0; $index -lt 3; $index++) {
                $attempt = $result.attempts[$index]
                $role = $input.plan.roles[$index]
                Assert-SequenceEqual @($attempt.PSObject.Properties.Name) @(
                    'ordinal', 'role', 'family', 'launcher', 'route_id', 'configuration_id', 'model', 'effort',
                    'state', 'slot_claimed_at', 'process_started_at', 'completed_at', 'exit_code',
                    'duration_ms', 'timed_out', 'cleanup_failed', 'cleanup_status', 'process_exited', 'usage',
                    'transport_status', 'contract_status', 'envelope_rejection_code', 'decision'
                )
                foreach ($name in @('ordinal', 'role', 'family', 'launcher', 'route_id', 'configuration_id', 'model', 'effort')) {
                    Assert-Equal $attempt.$name $role.$name
                }
                Assert-Equal $attempt.state 'planned'
                foreach ($name in @('slot_claimed_at', 'process_started_at', 'completed_at', 'exit_code',
                        'duration_ms', 'timed_out', 'cleanup_failed', 'cleanup_status', 'process_exited', 'usage',
                        'transport_status', 'contract_status', 'envelope_rejection_code', 'decision')) {
                    Assert-True ($null -eq $attempt.$name) "Expected initial attempt '$name' to be null."
                }
            }
            Assert-Equal $result.slots_consumed.total 0
            Assert-Equal $result.slots_consumed.provider_family.google 0
            Assert-Equal $result.slots_consumed.provider_family.openai 0
            Assert-Equal $result.slots_consumed.provider_family.anthropic 0
            Assert-Equal $result.launcher_processes_started.total 0
            Assert-False $result.provider_side_requests.observable
            Assert-True ($null -eq $result.provider_side_requests.count)
            Assert-Equal $result.quality.external_category 'unknown'
            Assert-False $result.profile_promotion_allowed
            Assert-False $result.profile_mutated
            Assert-False $result.production_eligibility_changed
        } finally {
            if ($null -ne $context) { Close-CalibrationPilotRun -Context $context }
            Remove-TestCalibrationPilotLedgerRoot -Path $input.results_root
        }
    }

    Invoke-Assertion 'pilot run and attempt state machines reject invalid or stale mutations without changing result' {
        $input = New-TestCalibrationPilotLedgerInput
        $context = $null
        try {
            $timestampCopy = Copy-TestObject ([pscustomobject]@{ timestamp = '2026-08-25T18:46:10.1234560+00:00' })
            Assert-True ($timestampCopy.timestamp -is [string]) 'Test JSON copies must preserve durable timestamp strings.'
            $context = New-CalibrationPilotRun -ResultsRoot $input.results_root -RunId 'ledger-test-002' -Plan $input.plan
            $resultPath = $context.result_path
            $before = (Get-FileHash -LiteralPath $resultPath -Algorithm SHA256).Hash
            $null = Assert-Throws {
                Set-CalibrationPilotAttemptState -Context $context -Ordinal 1 -State 'skipped'
            } 'pilot_attempt_run_not_running'
            Assert-Equal (Get-FileHash -LiteralPath $resultPath -Algorithm SHA256).Hash $before
            Set-CalibrationPilotRunState -Context $context -State 'preflight_passed'
            Assert-Equal $context.result.run_state 'preflight_passed'
            $before = (Get-FileHash -LiteralPath $resultPath -Algorithm SHA256).Hash
            $null = Assert-Throws {
                Set-CalibrationPilotAttemptState -Context $context -Ordinal 1 -State 'skipped'
            } 'pilot_attempt_run_not_running'
            Assert-Equal (Get-FileHash -LiteralPath $resultPath -Algorithm SHA256).Hash $before
            $crossState = Copy-TestObject $context.result
            $crossState.attempts[0].state = 'skipped'
            $crossState.attempts[0].completed_at = [DateTimeOffset]::UtcNow.ToString('o')
            $null = Assert-Throws {
                Assert-CalibrationPilotResultContract -Context $context -Result $crossState `
                    -SkipClaimCounterCheck -SkipPersistedResultMatch
            } 'pilot_result_contract_invalid'
            $context.result.stop_reason = 'arbitrary exception text must not persist'
            $null = Assert-Throws { Set-CalibrationPilotRunState -Context $context -State 'running' } 'pilot_result_contract_invalid'
            Assert-Equal (Get-FileHash -LiteralPath $resultPath -Algorithm SHA256).Hash $before
            $context.result = Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json -Depth 100 -DateKind String
            $null = Assert-Throws { Set-CalibrationPilotRunState -Context $context -State 'completed' } 'pilot_run_transition_invalid'
            Assert-Equal (Get-FileHash -LiteralPath $resultPath -Algorithm SHA256).Hash $before
            Set-CalibrationPilotRunState -Context $context -State 'running'

            Assert-SequenceEqual @($script:PilotRunTransitions.planned) @('preflight_passed', 'stopped')
            Assert-SequenceEqual @($script:PilotRunTransitions.preflight_passed) @('running', 'stopped')
            Assert-SequenceEqual @($script:PilotRunTransitions.running) @('completed', 'stopped', 'indeterminate')
            foreach ($terminal in @('completed', 'stopped', 'indeterminate')) {
                Assert-Equal @($script:PilotRunTransitions[$terminal]).Count 0
            }
            Assert-SequenceEqual @($script:PilotAttemptTransitions.planned) @('slot_reserved', 'skipped')
            Assert-SequenceEqual @($script:PilotAttemptTransitions.slot_reserved) @('process_started', 'failed')
            Assert-SequenceEqual @($script:PilotAttemptTransitions.process_started) @('succeeded', 'failed')
            foreach ($terminal in @('succeeded', 'failed', 'skipped')) {
                Assert-Equal @($script:PilotAttemptTransitions[$terminal]).Count 0
            }

            $null = Assert-Throws { Set-CalibrationPilotRunState -Context $context -State 'completed' } 'pilot_run_completion_invalid'

            $null = Assert-Throws { Set-CalibrationPilotAttemptState -Context $context -Ordinal 2 -State 'slot_reserved' } 'pilot_attempt_transition_invalid'
            $null = Assert-Throws { Set-CalibrationPilotAttemptState -Context $context -Ordinal 4 -State 'slot_reserved' } 'pilot_attempt_ordinal_invalid'
            $null = Assert-Throws { Set-CalibrationPilotAttemptState -Context $context -Ordinal 'one' -State 'skipped' } 'pilot_attempt_ordinal_invalid'
            $missing = Copy-TestObject $context.result
            $missing.attempts = @($missing.attempts | Select-Object -First 2)
            $context.result = $missing
            $before = (Get-FileHash -LiteralPath $resultPath -Algorithm SHA256).Hash
            $null = Assert-Throws { Set-CalibrationPilotRunState -Context $context -State 'stopped' } 'pilot_result_contract_invalid'
            Assert-Equal (Get-FileHash -LiteralPath $resultPath -Algorithm SHA256).Hash $before
            $context.result = Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json -Depth 100 -DateKind String
            Set-CalibrationPilotRunState -Context $context -State 'stopped' -StopCode 'manual_abort'
            $before = (Get-FileHash -LiteralPath $resultPath -Algorithm SHA256).Hash
            $null = Assert-Throws { Set-CalibrationPilotRunState -Context $context -State 'running' } 'pilot_run_transition_invalid'
            $null = Assert-Throws { Set-CalibrationPilotAttemptState -Context $context -Ordinal 1 -State 'skipped' } 'pilot_attempt_run_terminal'
            Assert-Equal (Get-FileHash -LiteralPath $resultPath -Algorithm SHA256).Hash $before
        } finally {
            if ($null -ne $context) { Close-CalibrationPilotRun -Context $context }
            Remove-TestCalibrationPilotLedgerRoot -Path $input.results_root
        }
    }

    Invoke-Assertion 'pilot slot claims are exact ordered durable and non-refundable' {
        $input = New-TestCalibrationPilotLedgerInput
        $context = $null
        try {
            $context = New-CalibrationPilotRun -ResultsRoot $input.results_root -RunId 'ledger-test-003' -Plan $input.plan
            Set-CalibrationPilotRunState -Context $context -State 'preflight_passed'
            Set-CalibrationPilotRunState -Context $context -State 'running'
            $google = $input.plan.roles[0]
            $openai = $input.plan.roles[1]
            $anthropic = $input.plan.roles[2]
            $first = New-CalibrationPilotSlotClaim -Context $context -Ordinal 1 -Identity $google
            Assert-True (Test-Path -LiteralPath $first.claim_path -PathType Leaf)
            Assert-Equal (Get-CalibrationPilotClaimCount -Context $context).total 1
            Assert-Equal $context.result.attempts[0].state 'slot_reserved'
            $null = Assert-Throws { New-CalibrationPilotSlotClaim -Context $context -Ordinal 1 -Identity $google } 'pilot_slot_not_next'
            $null = Assert-Throws { New-CalibrationPilotSlotClaim -Context $context -Ordinal 3 -Identity $anthropic } 'pilot_slot_not_next'
            $null = Assert-Throws { New-CalibrationPilotSlotClaim -Context $context -Ordinal 4 -Identity $anthropic } 'pilot_slot_ordinal_invalid'
            $null = Assert-Throws { New-CalibrationPilotSlotClaim -Context $context -Ordinal 2 -Identity $openai } 'pilot_slot_previous_incomplete'
            $wrong = Copy-TestObject $openai
            $wrong.family = 'google'
            $null = Assert-Throws { New-CalibrationPilotSlotClaim -Context $context -Ordinal 2 -Identity $wrong } 'pilot_slot_identity_invalid'

            Set-CalibrationPilotAttemptState -Context $context -Ordinal 1 -State 'failed'
            Assert-True (Test-Path -LiteralPath $first.claim_path -PathType Leaf)
            Assert-Equal (Get-CalibrationPilotClaimCount -Context $context).total 1
            $null = Assert-Throws { New-CalibrationPilotSlotClaim -Context $context -Ordinal 2 -Identity $openai } 'pilot_slot_prior_attempt_failed'
            Assert-False (Test-Path -LiteralPath (Join-Path $context.claims_path '02-openai-judge.claim'))
            Set-CalibrationPilotRunState -Context $context -State 'stopped' -StopCode 'manual_abort'
            $null = Assert-Throws { New-CalibrationPilotSlotClaim -Context $context -Ordinal 2 -Identity $openai } 'pilot_slot_run_not_running'
        } finally {
            if ($null -ne $context) { Close-CalibrationPilotRun -Context $context }
            Remove-TestCalibrationPilotLedgerRoot -Path $input.results_root
        }
    }

    Invoke-Assertion 'pilot slot claims consume exactly one slot per family after prior success' {
        $input = New-TestCalibrationPilotLedgerInput
        $context = $null
        try {
            $context = New-CalibrationPilotRun -ResultsRoot $input.results_root -RunId 'ledger-test-004' -Plan $input.plan
            Set-CalibrationPilotRunState -Context $context -State 'preflight_passed'
            Set-CalibrationPilotRunState -Context $context -State 'running'
            $google = $input.plan.roles[0]
            $openai = $input.plan.roles[1]
            $anthropic = $input.plan.roles[2]
            $first = New-CalibrationPilotSlotClaim -Context $context -Ordinal 1 -Identity $google
            Set-CalibrationPilotAttemptState -Context $context -Ordinal 1 -State 'process_started'
            Set-CalibrationPilotAttemptState -Context $context -Ordinal 1 -State 'succeeded'
            $second = New-CalibrationPilotSlotClaim -Context $context -Ordinal 2 -Identity $openai
            Set-CalibrationPilotAttemptState -Context $context -Ordinal 2 -State 'process_started'
            Set-CalibrationPilotAttemptState -Context $context -Ordinal 2 -State 'succeeded'
            $third = New-CalibrationPilotSlotClaim -Context $context -Ordinal 3 -Identity $anthropic
            $counts = Get-CalibrationPilotClaimCount -Context $context
            Assert-Equal $counts.total 3
            Assert-Equal $counts.provider_family.google 1
            Assert-Equal $counts.provider_family.openai 1
            Assert-Equal $counts.provider_family.anthropic 1
            Assert-True (Test-Path -LiteralPath $second.claim_path -PathType Leaf)
            Assert-True (Test-Path -LiteralPath $third.claim_path -PathType Leaf)
            $thirdHash = (Get-FileHash -LiteralPath $third.claim_path -Algorithm SHA256).Hash
            Set-CalibrationPilotAttemptState -Context $context -Ordinal 3 -State 'process_started'
            Assert-Equal $context.result.launcher_processes_started.total 3
            Assert-Equal $context.result.launcher_processes_started.provider_family.anthropic 1
            Set-CalibrationPilotAttemptState -Context $context -Ordinal 3 -State 'succeeded'
            Assert-Equal (Get-FileHash -LiteralPath $third.claim_path -Algorithm SHA256).Hash $thirdHash
            $before = (Get-FileHash -LiteralPath $context.result_path -Algorithm SHA256).Hash
            $null = Assert-Throws { Set-CalibrationPilotAttemptState -Context $context -Ordinal 3 -State 'failed' } 'pilot_attempt_transition_invalid'
            Assert-Equal (Get-FileHash -LiteralPath $context.result_path -Algorithm SHA256).Hash $before
            $null = Assert-Throws { New-CalibrationPilotSlotClaim -Context $context -Ordinal 4 -Identity $anthropic } 'pilot_slot_ordinal_invalid'
        } finally {
            if ($null -ne $context) { Close-CalibrationPilotRun -Context $context }
            Remove-TestCalibrationPilotLedgerRoot -Path $input.results_root
        }
    }

    Invoke-Assertion 'option 1 fake execution completes exactly three ordered launches and retains unknown quality' {
        $execution = Invoke-TestCalibrationPilotRun `
            -CandidateAnswer '{"event":"Robotics club demo","date":"2026-09-14","room":"Room B12"}' `
            -JudgeOneDecision pass -JudgeTwoDecision pass
        try {
            $result = $execution.result
            Assert-SequenceEqual @($execution.invocations) @(
                'agy__gemini_3_7_flash_low__low',
                'codex__gpt_5_6_sol__max',
                'claude__claude_opus_5__max'
            )
            Assert-SequenceEqual @($execution.boundary_events) @(
                'candidate:slot_reserved:claims=1',
                'grader:candidate_persisted:claims=1',
                'judge1:slot_reserved:claims=2',
                'judge2:slot_reserved:claims=3'
            )
            Assert-Equal $execution.local_grader_calls 1
            Assert-Equal $result.run_state 'completed'
            Assert-Equal $result.slots_consumed.total 3
            Assert-Equal $result.launcher_processes_started.total 3
            Assert-False $result.provider_side_requests.observable
            Assert-True ($null -eq $result.provider_side_requests.count)
            Assert-Equal $result.quality.external_category 'unknown'
            Assert-Equal $result.quality.deterministic_result.outcome 'pass'
            Assert-SequenceEqual @($result.quality.judge_decisions.decision) @('pass', 'pass')
            Assert-Equal $result.quality.outcome 'retained'
            Assert-False $result.profile_promotion_allowed
            Assert-False $result.profile_mutated
            Assert-False $result.production_eligibility_changed
            foreach ($attempt in $result.attempts) {
                Assert-SequenceEqual @($attempt.PSObject.Properties.Name) @(
                    'ordinal', 'role', 'family', 'launcher', 'route_id', 'configuration_id', 'model', 'effort', 'state',
                    'slot_claimed_at', 'process_started_at', 'completed_at', 'exit_code', 'duration_ms', 'timed_out',
                    'cleanup_failed', 'cleanup_status', 'process_exited', 'usage', 'transport_status', 'contract_status',
                    'envelope_rejection_code', 'decision'
                )
                Assert-Equal $attempt.exit_code 0
                Assert-Equal $attempt.duration_ms 1
                Assert-False $attempt.timed_out
                Assert-False $attempt.cleanup_failed
                Assert-Equal $attempt.cleanup_status 'not_required'
                Assert-True $attempt.process_exited
                Assert-SequenceEqual @($attempt.usage.PSObject.Properties.Name) @(
                    'actual_input_tokens', 'visible_output_tokens', 'reasoning_tokens', 'complete'
                )
                Assert-Equal $attempt.usage.actual_input_tokens 12
                Assert-Equal $attempt.usage.visible_output_tokens 4
                Assert-Equal $attempt.usage.reasoning_tokens 0
                Assert-True $attempt.usage.complete
                Assert-Equal $attempt.transport_status 'success'
                Assert-Equal $attempt.contract_status 'success'
                Assert-Equal $attempt.envelope_rejection_code $null
            }
            $runRoot = Join-Path $execution.input.results_root 'option1-live-20260826-002'
            $plan = Get-Content -Raw -LiteralPath (Join-Path $runRoot 'plan.json') | ConvertFrom-Json -Depth 100
            Assert-Equal $plan.git_commit ('a' * 40)
            Assert-True (Test-Path -LiteralPath (Join-Path $runRoot 'raw/candidate-response.json') -PathType Leaf)
            Assert-True (Test-Path -LiteralPath (Join-Path $runRoot 'raw/judge-responses.json') -PathType Leaf)
            $persisted = Get-Content -Raw -LiteralPath (Join-Path $runRoot 'result.json') | ConvertFrom-Json -Depth 100
            Assert-Equal $persisted.run_state 'completed'
            Assert-SequenceEqual @($persisted.quality.judge_decisions.decision) @('pass', 'pass')
        } finally { Remove-TestCalibrationPilotLedgerRoot -Path $execution.input.results_root }
    }

    Invoke-Assertion 'option 1 deterministic quality failure still runs both judges and completes technically' {
        $execution = Invoke-TestCalibrationPilotRun `
            -CandidateAnswer '{"event":"Robotics club demo","date":"2026-09-14","room":"Wrong room"}' `
            -JudgeOneDecision pass -JudgeTwoDecision pass
        try {
            Assert-SequenceEqual @($execution.invocations) @(
                'agy__gemini_3_7_flash_low__low',
                'codex__gpt_5_6_sol__max',
                'claude__claude_opus_5__max'
            )
            Assert-Equal $execution.result.run_state 'completed'
            Assert-Equal $execution.result.quality.deterministic_result.outcome 'fail'
            Assert-SequenceEqual @($execution.result.quality.judge_decisions.decision) @('pass', 'pass')
            Assert-Equal $execution.result.quality.outcome 'review_required'
            Assert-Equal $execution.result.quality.external_category 'unknown'
        } finally { Remove-TestCalibrationPilotLedgerRoot -Path $execution.input.results_root }
    }

    Invoke-Assertion 'option 1 first judge quality failure still runs the second judge and completes technically' {
        $execution = Invoke-TestCalibrationPilotRun `
            -CandidateAnswer '{"event":"Robotics club demo","date":"2026-09-14","room":"Room B12"}' `
            -JudgeOneDecision fail -JudgeTwoDecision pass
        try {
            Assert-SequenceEqual @($execution.invocations) @(
                'agy__gemini_3_7_flash_low__low',
                'codex__gpt_5_6_sol__max',
                'claude__claude_opus_5__max'
            )
            Assert-Equal $execution.result.run_state 'completed'
            Assert-Equal $execution.result.quality.deterministic_result.outcome 'pass'
            Assert-SequenceEqual @($execution.result.quality.judge_decisions.decision) @('fail', 'pass')
            Assert-Equal $execution.result.quality.judge_decisions[0].rationale 'sanitized fail evidence'
            Assert-Equal $execution.result.quality.outcome 'review_required'
            Assert-Equal $execution.result.quality.external_category 'unknown'
        } finally { Remove-TestCalibrationPilotLedgerRoot -Path $execution.input.results_root }
    }

    Invoke-Assertion 'option 1 native Agy provider-declared failure retains evidence and launches no judges' {
        $input = New-TestCalibrationPilotLedgerInput
        $calls = [pscustomobject]@{ candidate = 0; native = 0; grader = 0; judge = 0; execution = $null }
        $nativeText = [ordered]@{
            thread_id = 'fixture-thread'
            session_id = 'fixture-session'
            status = 'SUCCESS'
            created_at = '2026-08-25T00:00:00Z'
            finished_at = '2026-08-25T00:00:01Z'
            result = ''
            structured_output = [ordered]@{ answer = ''; error = 'provider declined'; status = 'failure' }
            usage = [ordered]@{ input_tokens = 160; output_tokens = 57; thinking_tokens = 13; total_tokens = 230 }
        } | ConvertTo-Json -Compress -Depth 10
        $nativeInvoker = {
            param($Command)
            $calls.native++
            [pscustomobject]@{
                exit_code = 0
                stdout = $nativeText
                stderr = ''
                duration_ms = 17
                timed_out = $false
                cleanup_failed = $false
                cleanup_status = 'not_required'
                process_exited = $true
            }
        }.GetNewClosure()
        $candidateInvoker = {
            param($Candidate, $Prompt, $LaunchGuard, $RunId)
            $calls.candidate++
            $calls.execution = Invoke-PilotCandidate -Candidate $Candidate -Prompt $Prompt -LaunchGuard $LaunchGuard `
                -RunId $RunId -NativeInvoker $nativeInvoker
            return $calls.execution
        }.GetNewClosure()
        $graderInvoker = { $calls.grader++; throw 'grader must not run after provider-declared failure' }.GetNewClosure()
        $judgeInvoker = { $calls.judge++; throw 'judge must not run after provider-declared failure' }.GetNewClosure()
        $gitInvoker = { [pscustomobject]@{ clean = $true; commit = ('c' * 40) } }
        try {
            $result = Invoke-Calibration -Pilot -Run -RunId 'option1-live-20260826-002' `
                -ResultsRoot $input.results_root -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot `
                -CandidateInvoker $candidateInvoker -GraderInvoker $graderInvoker -JudgeInvoker $judgeInvoker `
                -PilotGitInvoker $gitInvoker

            Assert-Equal $calls.candidate 1
            Assert-Equal $calls.native 1
            Assert-Equal $calls.grader 0
            Assert-Equal $calls.judge 0
            $envelope = Test-CalibrationPilotExecutionEnvelope -Execution $calls.execution
            Assert-True $envelope.valid
            Assert-False $envelope.success
            Assert-Equal $envelope.stop_code 'response_contract_invalid'
            Assert-Equal $calls.execution.failure $null
            Assert-Equal $calls.execution.diagnostic_note 'provider-declared failure'
            Assert-Equal $result.run_state 'stopped'
            Assert-Equal $result.stop_reason 'response_contract_invalid'
            Assert-Equal $result.slots_consumed.total 1
            Assert-Equal $result.launcher_processes_started.total 1
            Assert-Equal $result.attempts[0].state 'failed'
            Assert-Equal $result.attempts[0].exit_code 0
            Assert-Equal $result.attempts[0].duration_ms 17
            Assert-False $result.attempts[0].timed_out
            Assert-False $result.attempts[0].cleanup_failed
            Assert-Equal $result.attempts[0].cleanup_status 'not_required'
            Assert-True $result.attempts[0].process_exited
            Assert-Equal $result.attempts[0].transport_status 'success'
            Assert-Equal $result.attempts[0].contract_status 'success'
            Assert-Equal $result.attempts[0].envelope_rejection_code $null
            Assert-Equal $result.attempts[0].usage.actual_input_tokens 160
            Assert-Equal $result.attempts[0].usage.visible_output_tokens 44
            Assert-Equal $result.attempts[0].usage.reasoning_tokens 13
            Assert-True $result.attempts[0].usage.complete
            Assert-Equal $result.attempts[1].state 'skipped'
            Assert-Equal $result.attempts[2].state 'skipped'
            $runRoot = Join-Path $input.results_root 'option1-live-20260826-002'
            Assert-False (Test-Path -LiteralPath (Join-Path $runRoot 'raw/candidate-response.json') -PathType Leaf)
            Assert-False (Test-Path -LiteralPath (Join-Path $runRoot 'raw/judge-responses.json') -PathType Leaf)
        } finally { Remove-TestCalibrationPilotLedgerRoot -Path $input.results_root }
    }

    Invoke-Assertion 'pilot execution envelope returns one bounded first-failure category and null for valid envelopes' {
        $valid = [pscustomobject][ordered]@{
            process_started = $true
            process = [pscustomobject][ordered]@{
                exit_code = 0
                duration_ms = 1
                timed_out = $false
                cleanup_failed = $false
                cleanup_status = 'not_required'
                process_exited = $true
            }
            canonical = [pscustomobject][ordered]@{ status = 'success'; answer = 'safe'; error = $null }
            failure = $null
            failure_code = $null
            stop_code = $null
            usage = [pscustomobject][ordered]@{
                actual_input_tokens = 1
                visible_output_tokens = 1
                reasoning_tokens = 0
                complete = $true
            }
        }
        $cases = @(
            [pscustomobject]@{ code = 'execution_shape'; make = { 'not an execution object' } },
            [pscustomobject]@{ code = 'start_state'; make = {
                $value = Copy-TestObject $valid; $value.process_started = 'true'; $value
            }.GetNewClosure() },
            [pscustomobject]@{ code = 'failure_metadata'; make = {
                $value = Copy-TestObject $valid; $value.failure_code = 9; $value
            }.GetNewClosure() },
            [pscustomobject]@{ code = 'process_shape'; make = {
                $value = Copy-TestObject $valid; $value.process.PSObject.Properties.Remove('duration_ms'); $value
            }.GetNewClosure() },
            [pscustomobject]@{ code = 'process_values'; make = {
                $value = Copy-TestObject $valid; $value.process.duration_ms = -1; $value
            }.GetNewClosure() },
            [pscustomobject]@{ code = 'usage'; make = {
                $value = Copy-TestObject $valid; $value.usage.complete = 'true'; $value
            }.GetNewClosure() },
            [pscustomobject]@{ code = 'canonical_shape'; make = {
                $value = Copy-TestObject $valid; $value.canonical.PSObject.Properties.Remove('error'); $value
            }.GetNewClosure() },
            [pscustomobject]@{ code = 'canonical_values'; make = {
                $value = Copy-TestObject $valid; $value.canonical.status = 'Success'; $value
            }.GetNewClosure() },
            [pscustomobject]@{ code = 'semantic_conflict'; make = {
                $value = Copy-TestObject $valid; $value.failure = 'contradicts canonical success'; $value
            }.GetNewClosure() }
        )
        Assert-SequenceEqual @($script:CalibrationPilotEnvelopeRejectionCodes) @(
            'execution_shape', 'start_state', 'failure_metadata', 'process_shape', 'process_values', 'usage',
            'canonical_shape', 'canonical_values', 'semantic_conflict'
        )
        foreach ($case in $cases) {
            $envelope = Test-CalibrationPilotExecutionEnvelope -Execution (& $case.make)
            Assert-SequenceEqual @($envelope.PSObject.Properties.Name) @(
                'valid', 'process_started', 'start_indeterminate', 'success', 'stop_code', 'rejection_code'
            )
            Assert-False $envelope.valid
            Assert-Equal $envelope.stop_code 'provider_envelope_invalid'
            Assert-Equal $envelope.rejection_code $case.code
        }

        $success = Test-CalibrationPilotExecutionEnvelope -Execution $valid
        Assert-True $success.valid
        Assert-True $success.success
        Assert-Equal $success.rejection_code $null

        $providerFailureExecution = Copy-TestObject $valid
        $providerFailureExecution.canonical.status = 'failure'
        $providerFailureExecution.canonical.answer = ''
        $providerFailureExecution.canonical.error = 'provider declined'
        $providerFailure = Test-CalibrationPilotExecutionEnvelope -Execution $providerFailureExecution
        Assert-True $providerFailure.valid
        Assert-False $providerFailure.success
        Assert-Equal $providerFailure.stop_code 'response_contract_invalid'
        Assert-Equal $providerFailure.rejection_code $null

        $technicalFailureExecution = Copy-TestObject $valid
        $technicalFailureExecution.process.exit_code = 17
        $technicalFailureExecution.canonical = $null
        $technicalFailureExecution.failure = 'bounded technical failure'
        $technicalFailureExecution.failure_code = 'nonzero_exit'
        $technicalFailure = Test-CalibrationPilotExecutionEnvelope -Execution $technicalFailureExecution
        Assert-True $technicalFailure.valid
        Assert-False $technicalFailure.success
        Assert-Equal $technicalFailure.stop_code 'nonzero_exit'
        Assert-Equal $technicalFailure.rejection_code $null
    }

    Invoke-Assertion 'native Agy adapter rejects mixed-case status values before the calibration envelope' {
        $resolved = Get-CalibrationProfileAndCandidate -ConfigurationId 'gemini-3.7-flash-low__low'
        $cases = @(
            [pscustomobject]@{ status = 'Success'; answer = '4'; error = $null }
            [pscustomobject]@{ status = 'Failure'; answer = ''; error = 'provider declined' }
        )
        foreach ($case in $cases) {
            $nativeText = [ordered]@{
                thread_id = 'fixture-thread'
                session_id = 'fixture-session'
                status = 'SUCCESS'
                created_at = '2026-08-25T00:00:00Z'
                finished_at = '2026-08-25T00:00:01Z'
                result = $case.answer
                structured_output = [ordered]@{
                    status = $case.status
                    answer = $case.answer
                    error = $case.error
                }
                usage = [ordered]@{ input_tokens = 20; output_tokens = 5; thinking_tokens = 1; total_tokens = 25 }
            } | ConvertTo-Json -Compress -Depth 10
            $execution = Invoke-PilotCandidate -Candidate $resolved.candidate -Prompt 'mixed-case status' `
                -RunId ("agy-mixed-status-$($case.status)") -NativeInvoker {
                    [pscustomobject]@{
                        exit_code = 0
                        stdout = $nativeText
                        stderr = ''
                        duration_ms = 3
                        timed_out = $false
                        cleanup_failed = $false
                        cleanup_status = 'not_required'
                        process_exited = $true
                    }
                }
            $envelope = Test-CalibrationPilotExecutionEnvelope -Execution $execution

            Assert-True ([string]::Equals(
                    [string]$execution.canonical.status, [string]$case.status, [StringComparison]::Ordinal))
            Assert-Equal $execution.diagnostic_note 'contract failure'
            Assert-Equal $execution.failure 'contract failure'
            Assert-False $execution.record.contract_compliant
            Assert-False $envelope.valid
            Assert-True $envelope.process_started
            Assert-False $envelope.start_indeterminate
            Assert-Equal $envelope.stop_code 'provider_envelope_invalid'
            Assert-Equal $envelope.rejection_code 'canonical_values'
        }
    }

    Invoke-Assertion 'option 1 default adapters forward the exact run id and guarded launch without native execution' {
        $input = New-TestCalibrationPilotLedgerInput
        $runId = 'option1-live-20260826-002'
        $originalText = (Get-Command -Name Invoke-PilotCandidate -CommandType Function -ErrorAction Stop).ScriptBlock.ToString()
        $immutableOriginal = [scriptblock]::Create($originalText)
        $script:PilotDefaultAdapterState = [pscustomobject]@{
            results_root = $input.results_root
            invocations = [Collections.Generic.List[string]]::new()
            guard_calls = 0
            grader_calls = 0
        }
        $result = $null
        try {
            Set-Item -Path Function:\Invoke-PilotCandidate -Value {
                param(
                    [Parameter(Mandatory)][object]$Candidate,
                    [Parameter(Mandatory)][string]$Prompt,
                    [scriptblock]$NativeInvoker,
                    [AllowNull()][string]$RunId,
                    [int]$TimeoutSeconds = -1,
                    [scriptblock]$LaunchGuard
                )
                Assert-Equal $RunId 'option1-live-20260826-002'
                Assert-True ($null -ne $LaunchGuard) 'Default adapter omitted the launch guard.'
                $command = New-TestCalibrationPilotCommand -Candidate $Candidate -Prompt $Prompt
                $before = $script:PilotDefaultAdapterState.guard_calls
                $null = & $LaunchGuard $Candidate $command
                $script:PilotDefaultAdapterState.guard_calls++
                Assert-Equal $script:PilotDefaultAdapterState.guard_calls ($before + 1)
                $ordinal = switch ([string]$Candidate.route_id) {
                    'agy__gemini_3_7_flash_low__low' { 1 }
                    'codex__gpt_5_6_sol__max' { 2 }
                    'claude__claude_opus_5__max' { 3 }
                    default { throw 'Unexpected default-adapter route.' }
                }
                Assert-TestCalibrationPilotLaunchBoundary -ResultsRoot $script:PilotDefaultAdapterState.results_root `
                    -RunId $RunId -Ordinal $ordinal -ExpectedClaimCount $ordinal
                $script:PilotDefaultAdapterState.invocations.Add([string]$Candidate.route_id)
                $answer = switch ($ordinal) {
                    1 { '{"event":"Robotics club demo","date":"2026-09-14","room":"Room B12"}' }
                    2 { '{"decision":"pass","rationale":"sanitized openai evidence"}' }
                    3 { '{"decision":"pass","rationale":"sanitized anthropic evidence"}' }
                }
                return New-TestCalibrationPilotExecution -Candidate $Candidate -Answer $answer -RunId $RunId
            }
            $grader = {
                param($Prompt, $ResponseText, $PythonExecutor, $PythonExecutable, $PythonTimeoutMilliseconds)
                Assert-TestCalibrationPilotGraderBoundary -ResultsRoot $script:PilotDefaultAdapterState.results_root `
                    -RunId 'option1-live-20260826-002'
                $script:PilotDefaultAdapterState.grader_calls++
                return Invoke-CalibrationDeterministicGrader -Prompt $Prompt -ResponseText $ResponseText
            }
            $git = { [pscustomobject]@{ clean = $true; commit = ('b' * 40) } }
            $result = Invoke-Calibration -Pilot -Run -RunId $runId -ResultsRoot $input.results_root `
                -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot -GraderInvoker $grader -PilotGitInvoker $git
            Assert-Equal $result.run_state 'completed'
            Assert-SequenceEqual @($script:PilotDefaultAdapterState.invocations) @(
                'agy__gemini_3_7_flash_low__low',
                'codex__gpt_5_6_sol__max',
                'claude__claude_opus_5__max'
            )
            Assert-Equal $script:PilotDefaultAdapterState.guard_calls 3
            Assert-Equal $script:PilotDefaultAdapterState.grader_calls 1
        } finally {
            Set-Item -Path Function:\Invoke-PilotCandidate -Value $immutableOriginal
            Remove-TestCalibrationPilotLedgerRoot -Path $input.results_root
            Remove-Variable -Scope Script -Name PilotDefaultAdapterState -ErrorAction SilentlyContinue
        }
        Assert-Equal (Get-Command -Name Invoke-PilotCandidate -CommandType Function -ErrorAction Stop).ScriptBlock.ToString() $originalText
    }

    Invoke-Assertion 'pilot plan and bounded live rejection never reach providers launch guard claims or writers' {
        $resultsRoot = New-CalibrationResultsTestRoot
        $originalFunctions = @{}
        foreach ($name in @('Invoke-PilotCandidate', 'New-CalibrationRunClaim', 'Write-CalibrationJsonFile')) {
            $originalFunctions[$name] = (Get-Command -Name $name -CommandType Function -ErrorAction Stop).ScriptBlock
        }
        try {
            $before = Get-CalibrationResultsTreeSnapshot -Root $resultsRoot
            $script:PilotCandidateCalls = 0
            $script:PilotJudgeCalls = 0
            $script:PilotRouterCalls = 0
            $script:PilotProviderCalls = 0
            $script:PilotClaimCalls = 0
            $script:PilotWriterCalls = 0
            Set-Item -Path Function:\Invoke-PilotCandidate -Value { $script:PilotProviderCalls++; throw 'pilot called Invoke-PilotCandidate' }
            Set-Item -Path Function:\New-CalibrationRunClaim -Value { $script:PilotClaimCalls++; throw 'pilot claimed a result directory' }
            Set-Item -Path Function:\Write-CalibrationJsonFile -Value { $script:PilotWriterCalls++; throw 'pilot wrote an artifact' }
            $candidateSpy = { $script:PilotCandidateCalls++; throw 'pilot invoked candidate seam' }
            $judgeSpy = { $script:PilotJudgeCalls++; throw 'pilot invoked judge seam' }
            $routerSpy = { $script:PilotRouterCalls++; throw 'pilot invoked router seam' }
            Invoke-Calibration -Pilot -ResultsRoot $resultsRoot -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot `
                -CandidateInvoker $candidateSpy -JudgeInvoker $judgeSpy -RouterInvoker $routerSpy | Out-Null
            $null = Assert-Throws {
                Invoke-Calibration -Pilot -Run -RunId 'task3-live-not-implemented' -ResultsRoot $resultsRoot `
                    -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot -CandidateInvoker $candidateSpy `
                    -JudgeInvoker $judgeSpy -RouterInvoker $routerSpy | Out-Null
            } 'pilot_run_id_invalid'
            foreach ($counter in @('PilotCandidateCalls', 'PilotJudgeCalls', 'PilotRouterCalls', 'PilotProviderCalls', 'PilotClaimCalls', 'PilotWriterCalls')) {
                Assert-Equal (Get-Variable -Scope Script -Name $counter -ValueOnly) 0
            }
            Assert-SequenceEqual (Get-CalibrationResultsTreeSnapshot -Root $resultsRoot) $before
        } finally {
            foreach ($name in $originalFunctions.Keys) { Set-Item -Path ("Function:\$name") -Value $originalFunctions[$name] }
            if (Test-Path -LiteralPath $resultsRoot) { Remove-Item -LiteralPath $resultsRoot -Recurse -Force }
        }
        foreach ($name in $originalFunctions.Keys) {
            Assert-Equal (Get-Command -Name $name -CommandType Function -ErrorAction Stop).ScriptBlock.ToString() $originalFunctions[$name].ToString()
        }
    }

    Invoke-Assertion 'consumed option 1 run id is rejected before git launch preparation invokers or writes' {
        $resultsRoot = New-CalibrationResultsTestRoot
        try {
            $before = Get-CalibrationResultsTreeSnapshot -Root $resultsRoot
            $calls = [pscustomobject]@{
                git = 0
                launcher = 0
                candidate = 0
                judge = 0
                artifact_writer = 0
            }
            $gitSpy = { $calls.git++; throw 'consumed run id reached git preflight' }.GetNewClosure()
            $launcherSpy = { $calls.launcher++; throw 'consumed run id reached launcher preparation' }.GetNewClosure()
            $candidateSpy = { $calls.candidate++; throw 'consumed run id reached candidate invoker' }.GetNewClosure()
            $judgeSpy = { $calls.judge++; throw 'consumed run id reached judge invoker' }.GetNewClosure()
            $artifactWriterSpy = { $calls.artifact_writer++; throw 'consumed run id reached artifact writer' }.GetNewClosure()

            $null = Assert-Throws {
                Invoke-Calibration -Pilot -Run -RunId 'option1-live-20260825-001' -ResultsRoot $resultsRoot `
                    -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot `
                    -PilotGitInvoker $gitSpy -LauncherResolver $launcherSpy `
                    -CandidateInvoker $candidateSpy -JudgeInvoker $judgeSpy `
                    -PilotArtifactWriter $artifactWriterSpy | Out-Null
            } 'pilot_run_id_invalid'

            Assert-Equal $calls.git 0
            Assert-Equal $calls.launcher 0
            Assert-Equal $calls.candidate 0
            Assert-Equal $calls.judge 0
            Assert-Equal $calls.artifact_writer 0
            Assert-SequenceEqual (Get-CalibrationResultsTreeSnapshot -Root $resultsRoot) $before
        } finally {
            if (Test-Path -LiteralPath $resultsRoot) { Remove-Item -LiteralPath $resultsRoot -Recurse -Force }
        }
    }

    Invoke-Assertion 'forced nested shadow failure restores every protected function definition' {
        $names = @('Invoke-PilotCandidate', 'New-CalibrationRunClaim', 'Write-CalibrationJsonFile')
        $original = @{}
        foreach ($name in $names) { $original[$name] = (Get-Command -Name $name -CommandType Function -ErrorAction Stop).ScriptBlock }
        $caught = $false
        try {
            Set-Item -Path Function:\Invoke-PilotCandidate -Value { throw 'forced nested shadow failure' }
            try {
                & {
                    Invoke-PilotCandidate -Candidate ([pscustomobject]@{}) -Prompt 'never-run' -RunId 'never-run' | Out-Null
                }
            } catch { $caught = $true }
        } finally {
            foreach ($name in $names) { Set-Item -Path ("Function:\$name") -Value $original[$name] }
        }
        Assert-True $caught
        foreach ($name in $names) {
            Assert-Equal (Get-Command -Name $name -CommandType Function -ErrorAction Stop).ScriptBlock.ToString() $original[$name].ToString()
        }
    }

    Invoke-Assertion 'pilot live CLI rejection is compact bounded and leaves results unchanged' {
        $resultsRoot = Join-Path $calibrationRoot 'results'
        $before = Get-CalibrationResultsTreeSnapshot -Root $resultsRoot
        $output = & pwsh -NoProfile -File $implementationPath -Pilot -Run -RunId 'task3-live-not-implemented'
        $exitCode = $LASTEXITCODE
        $after = Get-CalibrationResultsTreeSnapshot -Root $resultsRoot
        Assert-Equal $exitCode 1
        Assert-Equal @($output).Count 1
        $envelope = $output | ConvertFrom-Json -Depth 100
        Assert-SequenceEqual @($envelope.PSObject.Properties.Name) @('mode', 'error', 'message', 'code')
        Assert-Equal $envelope.mode 'pilot'
        Assert-Equal $envelope.error 'pilot_failed'
        Assert-Equal $envelope.message 'pilot_admission_failed'
        Assert-Equal $envelope.code 'pilot_admission_failed'
        Assert-False ([string]$output).Contains('pilot_live_not_implemented', [StringComparison]::Ordinal)
        Assert-SequenceEqual $after $before
    }

    Invoke-Assertion 'pilot CLI success is one compact clean plan and preserves the results tree bytes' {
        $resultsRoot = Join-Path $calibrationRoot 'results'
        $before = Get-CalibrationResultsTreeSnapshot -Root $resultsRoot
        $capture = Invoke-CalibrationCliCapture -Arguments @('-NoProfile', '-File', $implementationPath, '-Pilot')
        $after = Get-CalibrationResultsTreeSnapshot -Root $resultsRoot
        Assert-Equal $capture.exit_code 0
        Assert-Equal $capture.stderr ''
        $lines = @($capture.stdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        Assert-Equal $lines.Count 1
        $plan = $lines[0] | ConvertFrom-Json -Depth 100
        Assert-SequenceEqual @($plan.PSObject.Properties.Name) @('artifact_version', 'pilot_id', 'mode', 'selection_mode', 'prompt', 'roles', 'limits', 'source_hashes', 'provider_calls', 'provider_side_requests', 'profile_promotion_allowed', 'profile_mutated', 'production_eligibility_changed')
        Assert-Equal $plan.mode 'pilot-plan'
        Assert-Equal $plan.provider_calls 0
        Assert-Equal @($plan.roles).Count 3
        Assert-SequenceEqual $after $before
    }

    Invoke-Assertion 'public pilot CLI rejects external calibration and rubric copies before writes' {
        $temporary = New-TestDirectory
        $resultsRoot = New-CalibrationResultsTestRoot
        try {
            $externalSet = Join-Path $temporary 'calibration-set-v1.json'
            $externalRubrics = Join-Path $temporary 'rubrics'
            Copy-Item -LiteralPath $setPath -Destination $externalSet
            Copy-Item -LiteralPath $rubricsRoot -Destination $externalRubrics -Recurse
            $before = Get-CalibrationResultsTreeSnapshot -Root $resultsRoot
            foreach ($arguments in @(
                @('-NoProfile', '-File', $implementationPath, '-Pilot', '-CalibrationSetPath', $externalSet, '-ResultsRoot', $resultsRoot),
                @('-NoProfile', '-File', $implementationPath, '-Pilot', '-RubricsRoot', $externalRubrics, '-ResultsRoot', $resultsRoot),
                @('-NoProfile', '-File', $implementationPath, '-Pilot', '-Run', '-RunId', 'option1-live-20260826-002', '-CalibrationSetPath', $externalSet, '-ResultsRoot', $resultsRoot)
            )) {
                $capture = Invoke-CalibrationCliCapture -Arguments $arguments
                Assert-Equal $capture.exit_code 1
                Assert-Equal $capture.stderr ''
                Assert-SequenceEqual (Get-CalibrationResultsTreeSnapshot -Root $resultsRoot) $before
            }
        } finally {
            if (Test-Path -LiteralPath $resultsRoot) { Remove-Item -LiteralPath $resultsRoot -Recurse -Force }
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
        }
    }

    Invoke-Assertion 'public pilot function rejects external sources before fake calls while test seam remains explicit' {
        $temporary = New-TestDirectory
        $resultsRoot = New-CalibrationResultsTestRoot
        try {
            $externalSet = Join-Path $temporary 'calibration-set-v1.json'
            $externalRubrics = Join-Path $temporary 'rubrics'
            Copy-Item -LiteralPath $setPath -Destination $externalSet
            Copy-Item -LiteralPath $rubricsRoot -Destination $externalRubrics -Recurse
            $calls = [pscustomobject]@{ count = 0 }
            $spy = { $calls.count++; throw 'external source reached provider seam' }.GetNewClosure()
            $before = Get-CalibrationResultsTreeSnapshot -Root $resultsRoot
            $null = Assert-Throws {
                Invoke-Calibration -Pilot -Run -RunId 'option1-live-20260826-002' -ResultsRoot $resultsRoot `
                    -CalibrationSetPath $externalSet -RubricsRoot $externalRubrics `
                    -CandidateInvoker $spy -JudgeInvoker $spy -PilotGitInvoker $spy | Out-Null
            } 'pilot_source_path_not_canonical'
            Assert-Equal $calls.count 0
            Assert-SequenceEqual (Get-CalibrationResultsTreeSnapshot -Root $resultsRoot) $before

            $plan = Invoke-Calibration -Pilot -CalibrationSetPath $externalSet -RubricsRoot $externalRubrics `
                -AllowPilotSourceOverridesForTest
            Assert-Equal $plan.mode 'pilot-plan'
            Assert-Equal $plan.provider_calls 0
        } finally {
            if (Test-Path -LiteralPath $resultsRoot) { Remove-Item -LiteralPath $resultsRoot -Recurse -Force }
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
        }
    }

    Invoke-Assertion 'pilot validates all 24 calibration prompts before fixed-prompt selection without calls or writes' {
        $resultsRoot = New-CalibrationResultsTestRoot
        try {
            $sourceDirectory = Join-Path $resultsRoot 'sources'
            New-Item -ItemType Directory -Path $sourceDirectory | Out-Null
            $badSet = Copy-TestObject (Get-Content -Raw -LiteralPath $setPath | ConvertFrom-Json -Depth 100)
            $nonSelected = @($badSet.prompts | Where-Object { $_.id -ceq 'general-low-biology-v1' })[0]
            $nonSelected.PSObject.Properties.Remove('version')
            $badSetPath = Join-Path $sourceDirectory 'bad-calibration-set.json'
            $badSet | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $badSetPath -Encoding utf8NoBOM
            $before = Get-CalibrationResultsTreeSnapshot -Root $resultsRoot
            $script:PilotValidationCalls = 0
            $spy = { $script:PilotValidationCalls++; throw 'pilot validation executed a provider' }
            $null = Assert-Throws {
                Invoke-Calibration -Pilot -ResultsRoot $resultsRoot -CalibrationSetPath $badSetPath `
                    -RubricsRoot $rubricsRoot -CandidateInvoker $spy -JudgeInvoker $spy `
                    -AllowPilotSourceOverridesForTest | Out-Null
            } 'Pilot calibration set validation failed'
            Assert-Equal $script:PilotValidationCalls 0
            Assert-SequenceEqual (Get-CalibrationResultsTreeSnapshot -Root $resultsRoot) $before
        } finally {
            if (Test-Path -LiteralPath $resultsRoot) { Remove-Item -LiteralPath $resultsRoot -Recurse -Force }
        }
    }

    Invoke-Assertion 'pilot source bundle rejects a malformed nonselected request before pinning the fixed prompt' {
        $resultsRoot = New-CalibrationResultsTestRoot
        try {
            $sourceDirectory = Join-Path $resultsRoot 'sources'
            New-Item -ItemType Directory -Path $sourceDirectory | Out-Null
            $badSet = Copy-TestObject (Get-Content -Raw -LiteralPath $setPath | ConvertFrom-Json -Depth 100)
            (@($badSet.prompts | Where-Object { $_.id -ceq 'general-low-biology-v1' })[0]).request.task_type = 'invalid-task-type'
            $badSetPath = Join-Path $sourceDirectory 'bad-request-calibration-set.json'
            $badSet | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $badSetPath -Encoding utf8NoBOM
            $before = Get-CalibrationResultsTreeSnapshot -Root $resultsRoot
            $null = Assert-Throws {
                Invoke-Calibration -Pilot -ResultsRoot $resultsRoot -CalibrationSetPath $badSetPath -RubricsRoot $rubricsRoot `
                    -AllowPilotSourceOverridesForTest | Out-Null
            } 'Pilot calibration set validation failed'
            Assert-SequenceEqual (Get-CalibrationResultsTreeSnapshot -Root $resultsRoot) $before
        } finally {
            if (Test-Path -LiteralPath $resultsRoot) { Remove-Item -LiteralPath $resultsRoot -Recurse -Force }
        }
    }

    Invoke-Assertion 'pilot snapshot validation preserves importer parity for sensitive text and rubric references' {
        $resultsRoot = New-CalibrationResultsTestRoot
        try {
            $sourceDirectory = Join-Path $resultsRoot 'sources'
            New-Item -ItemType Directory -Path $sourceDirectory | Out-Null
            $nonSelectedId = 'general-low-biology-v1'
            $cases = @(
                [pscustomobject]@{
                    name = 'sensitive request text'; expected = "calibration_prompt_sensitive:$nonSelectedId"
                    mutate = { param($prompt) $prompt.request.request_text = 'This synthetic test mentions an api key label only.' }
                }
                [pscustomobject]@{
                    name = 'traversal rubric ref'; expected = "calibration_rubric_ref_invalid:$nonSelectedId"
                    mutate = { param($prompt) $prompt.grading.rubric_ref = '../outside.json' }
                }
                [pscustomobject]@{
                    name = 'nested rubric ref'; expected = "calibration_rubric_ref_invalid:$nonSelectedId"
                    mutate = { param($prompt) $prompt.grading.rubric_ref = 'nested/file.json' }
                }
                [pscustomobject]@{
                    name = 'missing rubric extension'; expected = "calibration_rubric_ref_invalid:$nonSelectedId"
                    mutate = { param($prompt) $prompt.grading.rubric_ref = 'missing-extension' }
                }
                [pscustomobject]@{
                    name = 'wrong rubric extension'; expected = "calibration_rubric_ref_invalid:$nonSelectedId"
                    mutate = { param($prompt) $prompt.grading.rubric_ref = 'wrong.txt' }
                }
                [pscustomobject]@{
                    name = 'invalid leading rubric character'; expected = "calibration_rubric_ref_invalid:$nonSelectedId"
                    mutate = { param($prompt) $prompt.grading.rubric_ref = '.leading.json' }
                }
                [pscustomobject]@{
                    name = 'backslash rubric ref'; expected = "calibration_rubric_ref_invalid:$nonSelectedId"
                    mutate = { param($prompt) $prompt.grading.rubric_ref = 'nested\file.json' }
                }
            )
            foreach ($case in $cases) {
                $set = Copy-TestObject (Get-Content -Raw -LiteralPath $setPath | ConvertFrom-Json -Depth 100)
                $prompt = @($set.prompts | Where-Object { $_.id -ceq $nonSelectedId })[0]
                & $case.mutate $prompt
                $casePath = Join-Path $sourceDirectory ("$($case.name -replace '[^A-Za-z0-9]', '-')-set.json")
                $set | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $casePath -Encoding utf8NoBOM
                $imported = Import-CalibrationSet -Path $casePath -RubricsRoot $rubricsRoot
                Assert-True (@($imported.errors) -ccontains $case.expected) "Importer did not report $($case.expected)."
                $before = Get-CalibrationResultsTreeSnapshot -Root $resultsRoot
                $script:PilotParityCalls = 0
                $spy = { $script:PilotParityCalls++; throw 'pilot parity validation invoked work' }
                $null = Assert-Throws {
                    Invoke-Calibration -Pilot -ResultsRoot $resultsRoot -CalibrationSetPath $casePath -RubricsRoot $rubricsRoot `
                        -CandidateInvoker $spy -JudgeInvoker $spy -RouterInvoker $spy `
                        -AllowPilotSourceOverridesForTest | Out-Null
                } ("Pilot calibration set validation failed: {0}" -f $case.expected)
                Assert-Equal $script:PilotParityCalls 0
                Assert-SequenceEqual (Get-CalibrationResultsTreeSnapshot -Root $resultsRoot) $before
            }
        } finally {
            if (Test-Path -LiteralPath $resultsRoot) { Remove-Item -LiteralPath $resultsRoot -Recurse -Force }
        }
    }

    Invoke-Assertion 'pilot rejects route and a non-live run id before calls or result writes' {
        $resultsRoot = New-CalibrationResultsTestRoot
        try {
            $before = Get-CalibrationResultsTreeSnapshot -Root $resultsRoot
            $script:PilotExclusiveCalls = 0
            $spy = { $script:PilotExclusiveCalls++; throw 'pilot incompatibility executed work' }
            $null = Assert-Throws {
                Invoke-Calibration -Pilot -Route -ResultsRoot $resultsRoot -CalibrationSetPath $setPath `
                    -RubricsRoot $rubricsRoot -CandidateInvoker $spy -JudgeInvoker $spy | Out-Null
            } 'Pilot and Route are mutually exclusive'
            $null = Assert-Throws {
                Invoke-Calibration -Pilot -RunId 'not-live' -ResultsRoot $resultsRoot -CalibrationSetPath $setPath `
                    -RubricsRoot $rubricsRoot -CandidateInvoker $spy -JudgeInvoker $spy | Out-Null
            } 'Pilot RunId requires Run'
            Assert-Equal $script:PilotExclusiveCalls 0
            Assert-SequenceEqual (Get-CalibrationResultsTreeSnapshot -Root $resultsRoot) $before
        } finally {
            if (Test-Path -LiteralPath $resultsRoot) { Remove-Item -LiteralPath $resultsRoot -Recurse -Force }
        }
    }

    Invoke-Assertion 'judge payload recursively hides all supplied identity metadata from keys and values' {
        $prompt = (Import-CalibrationSet -Path $setPath -RubricsRoot $rubricsRoot).set.prompts[0]
        $rubric = Get-Content -Raw -LiteralPath (Join-Path $rubricsRoot $prompt.grading.rubric_ref) | ConvertFrom-Json -Depth 100
        $identity = [pscustomobject]@{
            model = 'secret-model-zeta'
            provider = 'secret-provider-zeta'
            family = 'secret-family-zeta'
            tool = 'secret-tool-zeta'
            effort = 'secret-effort-zeta'
            price = '73.991'
            latency = '987654'
            profile_id = 'secret-profile-zeta'
            candidate_id = 'secret-candidate-zeta'
        }
        $response = 'Answer from secret-model-zeta using secret-provider-zeta at secret-effort-zeta for 73.991.'
        $payload = New-CalibrationJudgePayload -Prompt $prompt -Rubric $rubric `
            -ResponseText $response -IdentityMetadata $identity
        $allText = @(Get-ObjectStringsAndKeys $payload)
        foreach ($forbiddenKey in @('model', 'provider', 'family', 'tool', 'effort', 'price', 'latency', 'profile', 'candidate')) {
            Assert-Equal @($allText | Where-Object { $_ -match "(?i)$forbiddenKey" }).Count 0
        }
        foreach ($forbiddenValue in @($identity.PSObject.Properties.Value)) {
            Assert-Equal @($allText | Where-Object { $_ -match [regex]::Escape([string]$forbiddenValue) }).Count 0
        }
    }

    Invoke-Assertion 'conservative confirmation retains only unanimous passes and never upgrades' {
        $bothPass = Get-CalibrationCategoryProposal -ExternalCategory 'strong' -JudgeDecisions @('pass', 'pass')
        Assert-Equal $bothPass.proposed_category 'strong'
        Assert-Equal $bothPass.outcome 'retained'
        $deterministicPass = [pscustomobject]@{ outcome = 'pass'; checks = @() }
        $deterministicFail = [pscustomobject]@{ outcome = 'fail'; checks = @() }
        $deterministicUnavailable = [pscustomobject]@{ outcome = 'review_required'; reason_code = 'python_unavailable'; checks = @() }
        $confirmed = Get-CalibrationCategoryProposal -ExternalCategory 'strong' `
            -JudgeDecisions @('pass', 'pass') -DeterministicResult $deterministicPass
        Assert-Equal $confirmed.proposed_category 'strong'
        foreach ($deterministicResult in @($deterministicFail, $deterministicUnavailable)) {
            $proposal = Get-CalibrationCategoryProposal -ExternalCategory 'frontier' `
                -JudgeDecisions @('pass', 'pass') -DeterministicResult $deterministicResult
            Assert-Equal $proposal.proposed_category 'unknown'
            Assert-Equal $proposal.outcome 'review_required'
        }
        foreach ($decisions in @(@('fail', 'fail'), @('pass', 'fail'), @('fail', 'pass'))) {
            $proposal = Get-CalibrationCategoryProposal -ExternalCategory 'frontier' -JudgeDecisions $decisions
            Assert-Equal $proposal.proposed_category 'unknown'
            Assert-Equal $proposal.outcome 'review_required'
        }
        $unknown = Get-CalibrationCategoryProposal -ExternalCategory 'unknown' -JudgeDecisions @('pass', 'pass')
        Assert-Equal $unknown.proposed_category 'unknown'
        $threw = $false
        try { Get-CalibrationCategoryProposal -ExternalCategory 'unsupported' -JudgeDecisions @('pass', 'pass') | Out-Null } catch { $threw = $true }
        Assert-True $threw 'Calibration must never produce or retain unsupported.'
    }

    Invoke-Assertion 'exact-fields grader accepts one exact JSON value and rejects ambiguity shape drift and malformed output' {
        $prompt = @((Import-CalibrationSet -Path $setPath -RubricsRoot $rubricsRoot).set.prompts |
            Where-Object { $_.id -ceq 'extraction-low-general-v1' })[0]
        $exact = '{"event":"Robotics club demo","date":"2026-09-14","room":"Room B12"}'
        $pass = Invoke-CalibrationDeterministicGrader -Prompt $prompt -ResponseText $exact
        Assert-Equal $pass.outcome 'pass'
        Assert-Equal @($pass.checks | Where-Object { -not $_.passed }).Count 0

        $fenced = Invoke-CalibrationDeterministicGrader -Prompt $prompt -ResponseText @'
```json
{"event":"Robotics club demo","date":"2026-09-14","room":"Room B12"}
```
'@
        Assert-Equal $fenced.outcome 'pass'

        $extra = Invoke-CalibrationDeterministicGrader -Prompt $prompt `
            -ResponseText '{"event":"Robotics club demo","date":"2026-09-14","room":"Room B12","extra":true}'
        Assert-Equal $extra.outcome 'fail'
        Assert-True @($extra.checks | Where-Object { $_.id -ceq 'schema' -and -not $_.passed }).Count

        $ambiguous = Invoke-CalibrationDeterministicGrader -Prompt $prompt -ResponseText @'
```json
{"event":"Robotics club demo","date":"2026-09-14","room":"Room B12"}
```
and
```json
{"event":"Robotics club demo","date":"2026-09-14","room":"Room B12"}
```
'@
        Assert-Equal $ambiguous.outcome 'review_required'
        Assert-Equal $ambiguous.reason_code 'malformed_output'
    }

    Invoke-Assertion 'verified-answer and summary graders normalize evidence and record every check' {
        $set = (Import-CalibrationSet -Path $setPath -RubricsRoot $rubricsRoot).set
        $mathPrompt = @($set.prompts | Where-Object { $_.id -ceq 'math-low-mathematics-v1' })[0]
        $mathPass = Invoke-CalibrationDeterministicGrader -Prompt $mathPrompt `
            -ResponseText 'Subtract 5 from both sides, divide by 3, therefore X = 5.'
        Assert-Equal $mathPass.outcome 'pass'
        Assert-Equal @($mathPass.checks).Count 3
        $mathFail = Invoke-CalibrationDeterministicGrader -Prompt $mathPrompt -ResponseText 'x = 5.'
        Assert-Equal $mathFail.outcome 'fail'
        Assert-Equal @($mathFail.checks | Where-Object { -not $_.passed }).Count 2

        $summaryPrompt = @($set.prompts | Where-Object { $_.id -ceq 'summarization-medium-medicine-v1' })[0]
        $summaryPass = Invoke-CalibrationDeterministicGrader -Prompt $summaryPrompt -ResponseText @'
- Tuesday at 9 a.m. in Room 4.
- Covers room labels and record filing.
- Attendance questions go to the training coordinator.
'@
        Assert-Equal $summaryPass.outcome 'pass'
        Assert-Equal @($summaryPass.checks | Where-Object { -not $_.passed }).Count 0
        $summaryFail = Invoke-CalibrationDeterministicGrader -Prompt $summaryPrompt -ResponseText @'
Tuesday at 9 a.m. in Room 4 covers room labels and record filing. Ask the training coordinator about attendance and clinical advice for patient treatment.
'@
        Assert-Equal $summaryFail.outcome 'fail'
        Assert-True @($summaryFail.checks | Where-Object { $_.kind -in @('forbidden_claim_absent', 'required_omission_absent') -and -not $_.passed }).Count
    }

    Invoke-Assertion 'executable grader handles pass fail malformed timeout and unavailable runtime without provider calls' {
        $prompt = @((Import-CalibrationSet -Path $setPath -RubricsRoot $rubricsRoot).set.prompts |
            Where-Object { $_.id -ceq 'coding-low-computer-science-v1' })[0]
        $code = @'
```python
def sum_even(values):
    return sum(value for value in values if value % 2 == 0)
```
'@
        $script:PythonExecutions = 0
        $passingExecutor = {
            param($ExtractedCode, $Grader, $PythonExecutable, $TimeoutMilliseconds)
            $script:PythonExecutions++
            [pscustomobject]@{
                status = 'completed'
                checks = @(
                    [pscustomobject]@{ id = 'test[0]'; passed = $true; detail = 'matched' }
                    [pscustomobject]@{ id = 'test[1]'; passed = $true; detail = 'matched' }
                    [pscustomobject]@{ id = 'test[2]'; passed = $true; detail = 'matched' }
                )
            }
        }
        $pass = Invoke-CalibrationDeterministicGrader -Prompt $prompt -ResponseText $code `
            -PythonExecutor $passingExecutor
        Assert-Equal $pass.outcome 'pass'
        Assert-Equal $script:PythonExecutions 1

        $failingExecutor = {
            param($ExtractedCode, $Grader, $PythonExecutable, $TimeoutMilliseconds)
            [pscustomobject]@{
                status = 'completed'
                checks = @(
                    [pscustomobject]@{ id = 'test[0]'; passed = $false; detail = 'mismatch' }
                    [pscustomobject]@{ id = 'test[1]'; passed = $true; detail = 'matched' }
                    [pscustomobject]@{ id = 'test[2]'; passed = $true; detail = 'matched' }
                )
            }
        }
        $failed = Invoke-CalibrationDeterministicGrader -Prompt $prompt -ResponseText $code `
            -PythonExecutor $failingExecutor
        Assert-Equal $failed.outcome 'fail'

        $timeoutExecutor = {
            param($ExtractedCode, $Grader, $PythonExecutable, $TimeoutMilliseconds)
            [pscustomobject]@{ status = 'timeout'; checks = @() }
        }
        $timedOut = Invoke-CalibrationDeterministicGrader -Prompt $prompt -ResponseText $code `
            -PythonExecutor $timeoutExecutor
        Assert-Equal $timedOut.outcome 'review_required'
        Assert-Equal $timedOut.reason_code 'timeout'

        $beforeMalformed = $script:PythonExecutions
        $malformed = Invoke-CalibrationDeterministicGrader -Prompt $prompt -ResponseText @'
```python
def sum_even(values): return 0
```
text
```python
def other(): return 1
```
'@ `
            -PythonExecutor $passingExecutor
        Assert-Equal $malformed.outcome 'review_required'
        Assert-Equal $malformed.reason_code 'malformed_output'
        Assert-Equal $script:PythonExecutions $beforeMalformed

        $unavailable = Invoke-CalibrationDeterministicGrader -Prompt $prompt -ResponseText $code `
            -PythonExecutable 'definitely-missing-python-runtime'
        Assert-Equal $unavailable.outcome 'review_required'
        Assert-Equal $unavailable.reason_code 'sandbox_unavailable'
    }

    Invoke-Assertion 'default executable grader requires an explicitly approved sandbox executor' {
        $prompt = @((Import-CalibrationSet -Path $setPath -RubricsRoot $rubricsRoot).set.prompts |
            Where-Object { $_.id -ceq 'coding-low-computer-science-v1' })[0]
        $result = Invoke-CalibrationDeterministicGrader -Prompt $prompt -ResponseText @'
```python
def sum_even(values):
    return sum(value for value in values if value % 2 == 0)
```
'@
        Assert-Equal $result.outcome 'review_required'
        Assert-Equal $result.reason_code 'sandbox_unavailable'
        Assert-Equal @($result.checks).Count 0
    }

    Invoke-Assertion 'route-only selects all routes without candidate or judge execution and writes one bounded artifact' {
        $runId = 'route-test-{0}' -f [guid]::NewGuid().ToString('N')
        $resultsRoot = Join-Path $calibrationRoot 'results'
        $temporary = Join-Path $resultsRoot $runId
        try {
            $script:RouteCalls = 0
            $script:RouteCandidateCalls = 0
            $script:RouteJudgeCalls = 0
            $routeInvoker = {
                param($Request, $PromptDefinition)
                $script:RouteCalls++
                [pscustomobject]@{
                    status = 'selected'
                    selected_route = [pscustomobject]@{
                        configuration_id = 'gpt-5.6-sol__max'; provider = 'openai'; launcher = 'codex'
                        model = 'gpt-5.6-sol'; effort = 'max'
                    }
                }
            }
            $candidateSpy = { $script:RouteCandidateCalls++; throw 'route-only executed a candidate' }
            $judgeSpy = { $script:RouteJudgeCalls++; throw 'route-only executed a judge' }
            $result = Invoke-Calibration -Route -RunId $runId -ResultsRoot $resultsRoot `
                -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot -RouteInvoker $routeInvoker `
                -RouterInvoker $candidateSpy -JudgeInvoker $judgeSpy
            Assert-Equal $result.mode 'route'
            Assert-Equal $script:RouteCalls 24
            Assert-Equal $script:RouteCandidateCalls 0
            Assert-Equal $script:RouteJudgeCalls 0
            Assert-Equal @($result.routes).Count 24
            Assert-True (Test-Path -LiteralPath $result.artifact_path -PathType Leaf)
            Assert-False (Test-Path -LiteralPath (Join-Path $temporary 'raw'))
        } finally {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
        }
    }

    Invoke-Assertion 'route and run are mutually exclusive before calls or writes' {
        $runId = 'exclusive-test-{0}' -f [guid]::NewGuid().ToString('N')
        $resultsRoot = Join-Path $calibrationRoot 'results'
        $temporary = Join-Path $resultsRoot $runId
        $script:ExclusiveCalls = 0
        $spy = { $script:ExclusiveCalls++; throw 'mutually exclusive mode invoked work' }
        $threw = $false
        try {
            Invoke-Calibration -Route -Run -RunId $runId -ResultsRoot $resultsRoot `
                -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot `
                -RouteInvoker $spy -RouterInvoker $spy -JudgeInvoker $spy | Out-Null
        } catch { $threw = $true }
        Assert-True $threw
        Assert-Equal $script:ExclusiveCalls 0
        Assert-False (Test-Path -LiteralPath $temporary)
    }

    Invoke-Assertion 'explicit run uses injected orchestration, records two decisions, and does not mutate profiles' {
        $runId = 'test-run-{0}' -f [guid]::NewGuid().ToString('N')
        $resultsRoot = Join-Path $calibrationRoot 'results'
        $temporary = Join-Path $resultsRoot $runId
        try {
            $profilePath = Join-Path $projectRoot 'profiles/codex/gpt-5.6-sol__max.json'
            $beforeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $profilePath).Hash
            $script:RunRouterCalls = 0
            $script:RunJudgeCalls = 0
            $router = {
                param($Request, $PromptDefinition)
                $script:RunRouterCalls++
                $answer = "answer-$($PromptDefinition.id)"
                if ($PromptDefinition.id -ceq 'general-low-biology-v1') {
                    $answer = "$answer api_key=calibrationsecret123"
                }
                [pscustomobject]@{
                    response = [pscustomobject]@{
                        status = 'completed'; configuration_id = 'gpt-5.6-sol__max'; provider = 'openai'
                        launcher = 'codex'; model = 'gpt-5.6-sol'; effort = 'max'; output = $answer
                        price = 1.25; latency = 12
                    }
                    trace = [pscustomobject]@{ effective_quality = 'strong'; quality_bottleneck = 'task_types.general' }
                }
            }
            $judge = {
                param($JudgeProfileId, $JudgePayload, $PromptDefinition)
                $script:RunJudgeCalls++
                [pscustomobject]@{ decision = 'pass'; rationale = "reviewed-$JudgeProfileId Bearer judgecredential123" }
            }
            $result = Invoke-Calibration -Run -RunId $runId -ResultsRoot $resultsRoot `
                -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot -RouterInvoker $router -JudgeInvoker $judge
            Assert-Equal $result.mode 'run'
            Assert-Equal $script:RunRouterCalls 24
            Assert-Equal $script:RunJudgeCalls 48
            Assert-Equal @($result.reviews).Count 24
            foreach ($review in $result.reviews) { Assert-Equal @($review.judge_decisions).Count 2 }
            Assert-True (Test-Path -LiteralPath $result.artifact_path -PathType Leaf)
            $artifact = Get-Content -Raw -LiteralPath $result.artifact_path | ConvertFrom-Json -Depth 100
            Assert-Equal @($artifact.reviews).Count 24
            $promptById = @{}
            foreach ($prompt in (Import-CalibrationSet -Path $setPath -RubricsRoot $rubricsRoot).set.prompts) {
                $promptById[[string]$prompt.id] = $prompt
            }
            foreach ($review in $artifact.reviews) {
                Assert-Equal @($review.judge_decisions).Count 2
                $hasGrader = $promptById[[string]$review.item_id].grading.PSObject.Properties.Name -ccontains 'deterministic_grader'
                Assert-Equal ($null -ne $review.deterministic_result) $hasGrader
                $rawResponse = Get-Content -Raw -LiteralPath (Join-Path $temporary $review.raw_response_file) | ConvertFrom-Json -Depth 100
                $expectedRaw = "answer-$($review.item_id)"
                if ($review.item_id -ceq 'general-low-biology-v1') { $expectedRaw = "$expectedRaw api_key=[credential redacted]" }
                Assert-Equal $rawResponse.raw_candidate_output $expectedRaw
                $rawReviews = Get-Content -Raw -LiteralPath (Join-Path $temporary $review.raw_review_file) | ConvertFrom-Json -Depth 100
                Assert-Equal @($rawReviews.raw_judge_outputs).Count 2
                Assert-True ($null -ne $rawReviews.anonymized_payload)
            }
            $persistedResults = @(Get-ChildItem -LiteralPath $temporary -File -Recurse |
                ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName }) -join "`n"
            Assert-False $persistedResults.Contains('calibrationsecret123', [StringComparison]::Ordinal)
            Assert-False $persistedResults.Contains('judgecredential123', [StringComparison]::Ordinal)
            Assert-True $persistedResults.Contains('[credential redacted]', [StringComparison]::Ordinal)
            $repeatThrew = $false
            try {
                Invoke-Calibration -Run -RunId $runId -ResultsRoot $resultsRoot `
                    -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot -RouterInvoker $router -JudgeInvoker $judge | Out-Null
            } catch { $repeatThrew = $true }
            Assert-True $repeatThrew 'An existing calibration run must not be overwritten.'
            Assert-Equal $script:RunRouterCalls 24
            Assert-Equal $script:RunJudgeCalls 48
            $afterHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $profilePath).Hash
            Assert-Equal $afterHash $beforeHash
        } finally {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
        }
    }

    Invoke-Assertion 'malformed calibration sets and rubrics are rejected' {
        $temporary = New-TestDirectory
        try {
            $badSet = Copy-TestObject (Get-Content -Raw -LiteralPath $setPath | ConvertFrom-Json -Depth 100)
            $badSet.prompts = @($badSet.prompts | Select-Object -First 23)
            $badSetPath = Join-Path $temporary 'bad-set.json'
            $badSet | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $badSetPath -Encoding utf8NoBOM
            $setResult = Import-CalibrationSet -Path $badSetPath -RubricsRoot $rubricsRoot
            Assert-False $setResult.valid

            $unsafeIdSet = Copy-TestObject (Get-Content -Raw -LiteralPath $setPath | ConvertFrom-Json -Depth 100)
            $unsafeIdSet.prompts[0].id = '../escape'
            $unsafeIdPath = Join-Path $temporary 'unsafe-id-set.json'
            $unsafeIdSet | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $unsafeIdPath -Encoding utf8NoBOM
            $unsafeIdResult = Import-CalibrationSet -Path $unsafeIdPath -RubricsRoot $rubricsRoot
            Assert-False $unsafeIdResult.valid

            $rubricCopy = Join-Path $temporary 'rubrics'
            Copy-Item -LiteralPath $rubricsRoot -Destination $rubricCopy -Recurse
            $firstRubric = Get-ChildItem -LiteralPath $rubricCopy -Filter '*.json' | Select-Object -First 1
            $badRubric = Get-Content -Raw -LiteralPath $firstRubric.FullName | ConvertFrom-Json -Depth 100
            $badRubric.PSObject.Properties.Remove('version')
            $badRubric | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $firstRubric.FullName -Encoding utf8NoBOM
            $rubricResult = Import-CalibrationSet -Path $setPath -RubricsRoot $rubricCopy
            Assert-False $rubricResult.valid
        } finally {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
        }
    }

    Invoke-Assertion 'operator documentation freezes the option 1 three-launch safety contract' {
        $readmePath = Join-Path $projectRoot 'router/README.md'
        $readme = [IO.File]::ReadAllText($readmePath).Replace("`r`n", "`n")
        $heading = '## Option 1 three-launch calibration pilot'
        $sectionStart = $readme.IndexOf($heading, [StringComparison]::Ordinal)
        Assert-True ($sectionStart -ge 0) 'README must contain the Option 1 operator section.'
        $sectionEnd = $readme.IndexOf("`n## ", $sectionStart + $heading.Length, [StringComparison]::Ordinal)
        if ($sectionEnd -lt 0) { $sectionEnd = $readme.Length }
        $section = $readme.Substring($sectionStart, $sectionEnd - $sectionStart)
        $lines = @($section -split "`n")
        $offlineCommand = 'pwsh -NoProfile -File .\calibration\run_calibration.ps1 -Pilot'
        $liveCommand = 'pwsh -NoProfile -File .\calibration\run_calibration.ps1 -Pilot -Run -RunId option1-live-20260826-002'
        $orderedRoleBlock = @'
1. Google candidate: `agy__gemini_3_7_flash_low__low`.
2. Local exact-fields grading. This local deterministic grader does not consume a launcher slot.
3. OpenAI Judge 1: `codex__gpt_5_6_sol__max`.
4. Anthropic Judge 2: `claude__claude_opus_5__max`.
'@.Trim().Replace("`r`n", "`n")

        Assert-True ($lines -ccontains $offlineCommand) 'README must contain the exact offline Option 1 command on its own line.'
        Assert-True ($lines -ccontains $liveCommand) 'README must contain the frozen accepted live command on its own line.'
        Assert-True ($section.IndexOf($orderedRoleBlock, [StringComparison]::Ordinal) -ge 0) `
            'README must contain one exact adjacent numbered block for the ordered candidate, local grader, and two judges.'
        foreach ($fragment in @(
            'candidate execution',
            'local deterministic grader',
            'two independent cross-family judges',
            'does not consume a launcher slot',
            'maximum of three non-refundable application launch slots',
            '`provider_side_requests.observable: false`',
            '`provider_side_requests.count: null`',
            'No retry, fallback, or resume',
            'new RunId and new explicit approval',
            'never promote production quality',
            'never mutate model profiles',
            'never change production eligibility',
            'safe artifacts',
            'exact commit and exact ordered identities',
            'The current build accepts only `option1-live-20260826-002`.',
            'Do not edit the command to invent a replacement RunId.',
            'A replacement RunId requires a new reviewed build that accepts it and a revised acceptance packet that freezes and authorizes the exact replacement command, followed by new explicit approval.',
            '`.run.claim`',
            '`claims/01-google-candidate.claim`',
            '`claims/02-openai-judge.claim`',
            '`claims/03-anthropic-judge.claim`',
            '`plan.json`',
            '`result.json`',
            '`raw/candidate-response.json`',
            '`raw/judge-responses.json`',
            '`item_id`, `status`, credential-sanitized `output`, and bounded `error_code`',
            '`item_id`, the anonymized judge payload, and accumulated normalized decisions',
            'Cleanup-indeterminate exceptional residue may include an owned `.result-*.tmp` or `.raw-*.tmp` file.',
            'The operator must not delete that residue, resume or retry the run, or reuse its RunId automatically.',
            'Preserve the complete run directory for review; a later replacement still requires the new reviewed build, revised acceptance packet, and new explicit approval described above.'
        )) {
            Assert-True ($section.IndexOf($fragment, [StringComparison]::Ordinal) -ge 0) "README Option 1 section is missing required contract text: $fragment"
        }
        Assert-False ($section.IndexOf('manifest or acceptance packet', [StringComparison]::Ordinal) -ge 0) `
            'README must not imply that a manifest can replace the revised acceptance packet.'
        Assert-False ($section.IndexOf('removed after use', [StringComparison]::Ordinal) -ge 0) `
            'README must not promise successful temporary-file cleanup after an indeterminate cleanup boundary.'
    }

    Invoke-Assertion 'result paths are bounded beneath calibration results and reject traversal' {
        $resultsRoot = Join-Path $calibrationRoot 'results'
        try {
            $safe = Resolve-CalibrationResultPath -ResultsRoot $resultsRoot -RunId 'safe-run_001'
            Assert-True ([IO.Path]::GetFullPath($safe).StartsWith(([IO.Path]::GetFullPath($resultsRoot) + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase))
            foreach ($unsafe in @('../escape', '..\escape', 'nested/escape', 'C:\escape', '.', '', 'CON', 'safe.')) {
                $threw = $false
                try { Resolve-CalibrationResultPath -ResultsRoot $resultsRoot -RunId $unsafe | Out-Null } catch { $threw = $true }
                Assert-True $threw "Expected unsafe run id '$unsafe' to be rejected."
            }
        } finally { }
    }
}

function New-TestCalibrationLauncherFixture {
    $root = New-TestDirectory
    $anchors = [ordered]@{
        agy = Join-Path $root 'agy-bin'
        codex = Join-Path $root 'npm-bin'
        claude = Join-Path $root 'npm-bin'
    }
    $relative = [ordered]@{
        agy_native = 'agy.exe'
        codex_shim = 'codex.ps1'
        codex_javascript = 'node_modules/@openai/codex/bin/codex.js'
        codex_platform_manifest = 'node_modules/@openai/codex/node_modules/@openai/codex-win32-x64/package.json'
        codex_native = 'node_modules/@openai/codex/node_modules/@openai/codex-win32-x64/vendor/x86_64-pc-windows-msvc/bin/codex.exe'
        claude_shim = 'claude.ps1'
        claude_native = 'node_modules/@anthropic-ai/claude-code/bin/claude.exe'
    }
    $componentRole = [ordered]@{
        agy_native = 'agy'; codex_shim = 'codex'; codex_javascript = 'codex'
        codex_platform_manifest = 'codex'; codex_native = 'codex'
        claude_shim = 'claude'; claude_native = 'claude'
    }
    $paths = @{}
    foreach ($id in $relative.Keys) {
        $path = Join-Path $anchors[$componentRole[$id]] ($relative[$id].Replace('/', [IO.Path]::DirectorySeparatorChar))
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
        [IO.File]::WriteAllText($path, "fixture-$id", [Text.UTF8Encoding]::new($false))
        $paths[$id] = $path
    }
    function New-TestComponent([string]$Id, [string]$Kind, [string]$Purpose) {
        [pscustomobject][ordered]@{
            id = $Id; kind = $Kind; purpose = $Purpose
            locator = [pscustomobject][ordered]@{ anchor = 'resolved_launcher_dir'; relative_path = $relative[$Id] }
            sha256 = (Get-FileHash -LiteralPath $paths[$Id] -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $lock = [pscustomobject][ordered]@{
        lock_version = 'calibration-launcher-lock/v1'
        pilot_id = 'option1-three-launch-v1'
        roles = @(
            [pscustomobject][ordered]@{ ordinal = 1; role = 'candidate'; launcher = 'agy'; route_id = 'agy__gemini_3_7_flash_low__low'; components = @(
                (New-TestComponent 'agy_native' 'native_executable' 'executed')) }
            [pscustomobject][ordered]@{ ordinal = 2; role = 'judge_1'; launcher = 'codex'; route_id = 'codex__gpt_5_6_sol__max'; components = @(
                (New-TestComponent 'codex_shim' 'powershell_shim' 'provenance'),
                (New-TestComponent 'codex_javascript' 'javascript_entrypoint' 'provenance'),
                (New-TestComponent 'codex_platform_manifest' 'package_manifest' 'provenance'),
                (New-TestComponent 'codex_native' 'native_executable' 'executed')) }
            [pscustomobject][ordered]@{ ordinal = 3; role = 'judge_2'; launcher = 'claude'; route_id = 'claude__claude_opus_5__max'; components = @(
                (New-TestComponent 'claude_shim' 'powershell_shim' 'provenance'),
                (New-TestComponent 'claude_native' 'native_executable' 'executed')) }
        )
    }
    $lockPath = Join-Path $root 'launchers.json'
    $lock | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $lockPath -Encoding utf8NoBOM
    return [pscustomobject]@{ root = $root; anchors = $anchors; paths = $paths; lock = $lock; lock_path = $lockPath }
}

function Assert-TestCalibrationDirectoryRenameBlocked {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    $caught = $null
    try { [IO.Directory]::Move($Source, $Destination) }
    catch { $caught = $_ }
    if ($null -eq $caught) {
        if (Test-Path -LiteralPath $Destination) {
            [IO.Directory]::Move($Destination, $Source)
        }
        throw "Expected held launcher handles to block directory rename: $Source"
    }
    $cause = $caught.Exception
    while ($null -ne $cause -and $cause -isnot [IO.IOException]) { $cause = $cause.InnerException }
    Assert-True ($cause -is [IO.IOException]) `
        "Expected IOException for held launcher directory rename, got $($caught.Exception.GetType().FullName)."
    Assert-True (Test-Path -LiteralPath $Source -PathType Container)
    Assert-False (Test-Path -LiteralPath $Destination)
}

Invoke-Assertion 'pilot plan binds launcher lock and schema bytes without resolving installed launchers' {
    $resolverCalls = [Collections.Generic.List[string]]::new()
    $resolver = { param($role, $lockRole) $resolverCalls.Add([string]$role.launcher); throw 'offline plan resolved a launcher' }.GetNewClosure()
    $plan = Invoke-Calibration -Pilot -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot -LauncherResolver $resolver
    Assert-Equal $resolverCalls.Count 0
    Assert-SequenceEqual @($plan.source_hashes.PSObject.Properties.Name) @(
        'manifest', 'matrix', 'candidate_profile', 'calibration_set', 'prompt_definition', 'rubric',
        'response_schema', 'launcher_lock', 'launcher_lock_schema')
    Assert-Equal $plan.source_hashes.launcher_lock `
        (Get-FileHash -LiteralPath (Join-Path $calibrationRoot 'pilots/option1-launchers-v1.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Equal $plan.source_hashes.launcher_lock_schema `
        (Get-FileHash -LiteralPath (Join-Path $calibrationRoot 'pilots/option1-launchers.schema.json') -Algorithm SHA256).Hash.ToLowerInvariant()
}

Invoke-Assertion 'launcher preparation verifies all ordered fake roles, locks every component, and builds direct native commands' {
    $fixture = New-TestCalibrationLauncherFixture
    $prepared = $null
    try {
        $bundle = New-CalibrationPilotSourceBundle -PilotManifestPath $pilotManifestPath `
            -PilotManifestSchemaPath $pilotManifestSchemaPath -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot `
            -LauncherLockPath $fixture.lock_path `
            -LauncherLockSchemaPath (Join-Path $calibrationRoot 'pilots/option1-launchers.schema.json')
        $plan = New-CalibrationPilotPlan -SourceBundle $bundle
        $events = [Collections.Generic.List[string]]::new()
        $resolver = {
            param($role, $lockRole)
            $events.Add("resolve:$($role.launcher)")
            $anchor = [string]$fixture.anchors[[string]$role.launcher]
            $componentId = [string]$lockRole.components[0].id
            return [pscustomobject][ordered]@{ anchor_path = $anchor; resolved_path = [IO.Path]::GetFullPath($fixture.paths[$componentId]) }
        }.GetNewClosure()
        $prepared = New-CalibrationPilotPreparedLaunches -Plan $plan -SourceBundle $bundle -LauncherResolver $resolver
        Assert-SequenceEqual @($events) @('resolve:agy', 'resolve:codex', 'resolve:claude')
        Assert-SequenceEqual @($prepared.roles.launcher) @('agy', 'codex', 'claude')
        Assert-Equal $prepared.roles[0].executable ([IO.Path]::GetFullPath($fixture.paths.agy_native))
        Assert-Equal $prepared.roles[1].executable ([IO.Path]::GetFullPath($fixture.paths.codex_native))
        Assert-Equal $prepared.roles[2].executable ([IO.Path]::GetFullPath($fixture.paths.claude_native))
        Assert-SequenceEqual @($prepared.roles[1].environment.clear) @(
            'CODEX_MANAGED_BY_NPM', 'CODEX_MANAGED_BY_BUN', 'CODEX_MANAGED_BY_PNPM')
        $expectedPackageRoot = [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($fixture.paths.codex_javascript)))
        Assert-SequenceEqual @($prepared.roles[1].environment.set.PSObject.Properties.Name) @(
            'CODEX_MANAGED_PACKAGE_ROOT', 'CODEX_MANAGED_BY_NPM')
        Assert-Equal $prepared.roles[1].environment.set.CODEX_MANAGED_PACKAGE_ROOT $expectedPackageRoot
        Assert-Equal $prepared.roles[1].environment.set.CODEX_MANAGED_BY_NPM '1'
        $null = Assert-Throws {
            $stream = [IO.File]::Open($fixture.paths.codex_native, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $stream.Dispose()
        } $null
    } finally {
        if ($null -ne $prepared) { Close-CalibrationPilotPreparedLaunches -PreparedLaunches $prepared }
        if (Test-Path -LiteralPath $fixture.root) { Remove-Item -LiteralPath $fixture.root -Recurse -Force }
    }
}

Invoke-Assertion 'later-role launcher drift stops before every claim and provider invoker and releases opened handles' {
    $fixture = New-TestCalibrationLauncherFixture
    $resultsRoot = New-CalibrationResultsTestRoot
    try {
        [IO.File]::WriteAllText($fixture.paths.claude_native, 'drifted', [Text.UTF8Encoding]::new($false))
        $resolverCalls = [Collections.Generic.List[string]]::new()
        $providerCalls = [pscustomobject]@{ count = 0 }
        $resolver = {
            param($role, $lockRole)
            $resolverCalls.Add([string]$role.launcher)
            $anchor = [string]$fixture.anchors[[string]$role.launcher]
            $componentId = [string]$lockRole.components[0].id
            return [pscustomobject][ordered]@{ anchor_path = $anchor; resolved_path = [IO.Path]::GetFullPath($fixture.paths[$componentId]) }
        }.GetNewClosure()
        $providerSpy = { $providerCalls.count++; throw 'provider invoker must not run' }.GetNewClosure()
        $result = Invoke-Calibration -Pilot -Run -RunId 'option1-live-20260826-002' -ResultsRoot $resultsRoot `
            -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot -AllowPilotSourceOverridesForTest `
            -LauncherLockPath $fixture.lock_path `
            -LauncherLockSchemaPath (Join-Path $calibrationRoot 'pilots/option1-launchers.schema.json') `
            -LauncherResolver $resolver -CandidateInvoker $providerSpy -JudgeInvoker $providerSpy `
            -PilotGitInvoker { [pscustomobject]@{ clean = $true; commit = ('a' * 40) } }
        Assert-Equal $result.stop_reason 'source_drift'
        Assert-Equal $result.slots_consumed.total 0
        Assert-Equal $result.launcher_processes_started.total 0
        Assert-Equal $providerCalls.count 0
        Assert-SequenceEqual @($resolverCalls) @('agy', 'codex', 'claude')
        $persisted = Get-Content -Raw -LiteralPath (Join-Path $resultsRoot 'option1-live-20260826-002/result.json')
        $packageRoot = [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($fixture.paths.codex_javascript)))
        Assert-False $persisted.Contains($packageRoot, [StringComparison]::OrdinalIgnoreCase)
        $stream = [IO.File]::Open($fixture.paths.agy_native, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Dispose()
    } finally {
        if (Test-Path -LiteralPath $resultsRoot) { Remove-Item -LiteralPath $resultsRoot -Recurse -Force }
        if (Test-Path -LiteralPath $fixture.root) { Remove-Item -LiteralPath $fixture.root -Recurse -Force }
    }
}

Invoke-Assertion 'prepared identity hash drift propagates source_drift through the composed runner before claim or process' {
    $fixture = New-TestCalibrationLauncherFixture
    $resultsRoot = New-CalibrationResultsTestRoot
    $context = $null
    $prepared = $null
    try {
        $bundle = New-CalibrationPilotSourceBundle -PilotManifestPath $pilotManifestPath `
            -PilotManifestSchemaPath $pilotManifestSchemaPath -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot `
            -LauncherLockPath $fixture.lock_path `
            -LauncherLockSchemaPath (Join-Path $calibrationRoot 'pilots/option1-launchers.schema.json')
        $plan = Add-CalibrationPilotGitCommitToPlan -Plan (New-CalibrationPilotPlan -SourceBundle $bundle) -Commit ('d' * 40)
        $resolver = {
            param($role, $lockRole)
            $anchor = [string]$fixture.anchors[[string]$role.launcher]
            $componentId = [string]$lockRole.components[0].id
            [pscustomobject][ordered]@{
                anchor_path = $anchor
                resolved_path = [IO.Path]::GetFullPath($fixture.paths[$componentId])
            }
        }.GetNewClosure()
        $context = New-CalibrationPilotRun -ResultsRoot $resultsRoot -RunId 'prepared-hash-drift' -Plan $plan
        Set-CalibrationPilotRunState -Context $context -State 'preflight_passed'
        Set-CalibrationPilotRunState -Context $context -State 'running'
        $prepared = New-CalibrationPilotPreparedLaunches -Plan $plan -SourceBundle $bundle -LauncherResolver $resolver
        $context | Add-Member -NotePropertyName prepared_launches -NotePropertyValue $prepared
        $prepared.roles[0].executable = [IO.Path]::GetFullPath((Join-Path $fixture.anchors.agy 'other-agy.exe'))
        $nativeCalls = [pscustomobject]@{ count = 0 }
        $guard = New-CalibrationPilotLaunchGuard -Context $context -Role $context.plan.roles[0]
        $null = Assert-Throws {
            Invoke-PilotCandidate -Candidate $bundle.roles[0].candidate -Prompt $bundle.prompt.request.request_text `
                -LaunchGuard $guard -NativeInvoker { param($command) $nativeCalls.count++; throw 'must_not_start' }.GetNewClosure() `
                -RunId 'prepared-hash-drift' | Out-Null
        } 'source_drift'
        Assert-Equal $context.result.slots_consumed.total 0
        Assert-Equal $context.result.launcher_processes_started.total 0
        Assert-Equal $nativeCalls.count 0
        Assert-False (Test-Path -LiteralPath (Join-Path $context.claims_path '01-google-candidate.claim'))
    } finally {
        if ($null -ne $prepared) { Close-CalibrationPilotPreparedLaunches -PreparedLaunches $prepared }
        if ($null -ne $context -and $context.is_closed -eq $false) { Close-CalibrationPilotRun -Context $context }
        if (Test-Path -LiteralPath $resultsRoot) { Remove-Item -LiteralPath $resultsRoot -Recurse -Force }
        if (Test-Path -LiteralPath $fixture.root) { Remove-Item -LiteralPath $fixture.root -Recurse -Force }
    }
}

Invoke-Assertion 'claim persistence indeterminate propagates through the composed runner into existing recovery' {
    $fixture = New-TestCalibrationLauncherFixture
    $resultsRoot = New-CalibrationResultsTestRoot
    $originalHook = ${function:Invoke-CalibrationPilotAfterSlotClaimHook}
    try {
        $resolver = {
            param($role, $lockRole)
            $anchor = [string]$fixture.anchors[[string]$role.launcher]
            $componentId = [string]$lockRole.components[0].id
            [pscustomobject][ordered]@{
                anchor_path = $anchor
                resolved_path = [IO.Path]::GetFullPath($fixture.paths[$componentId])
            }
        }.GetNewClosure()
        Set-Item -Path Function:Invoke-CalibrationPilotAfterSlotClaimHook -Value {
            param($Context, $Ordinal)
            if ($Ordinal -eq 1) { throw 'forced_post_claim_persistence_failure' }
        }
        $nativeCalls = [pscustomobject]@{ count = 0 }
        $observedControlFailure = [pscustomobject]@{ code = $null }
        $candidateInvoker = {
            param($Candidate, $Prompt, $LaunchGuard, $RunId)
            try {
                Invoke-PilotCandidate -Candidate $Candidate -Prompt $Prompt -LaunchGuard $LaunchGuard `
                    -NativeInvoker { param($command) $nativeCalls.count++; throw 'must_not_start' }.GetNewClosure() `
                    -RunId $RunId
            } catch {
                $observedControlFailure.code = $_.Exception.Message
                throw
            }
        }.GetNewClosure()
        $result = Invoke-Calibration -Pilot -Run -RunId 'option1-live-20260826-002' -ResultsRoot $resultsRoot `
            -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot -AllowPilotSourceOverridesForTest `
            -LauncherLockPath $fixture.lock_path `
            -LauncherLockSchemaPath (Join-Path $calibrationRoot 'pilots/option1-launchers.schema.json') `
            -LauncherResolver $resolver -CandidateInvoker $candidateInvoker `
            -PilotGitInvoker { [pscustomobject]@{ clean = $true; commit = ('e' * 40) } }
        Assert-Equal $result.run_state 'indeterminate'
        Assert-Equal $result.stop_reason 'artifact_persistence_failed'
        Assert-Equal $result.slots_consumed.total 1
        Assert-Equal $result.launcher_processes_started.total 0
        Assert-Equal $nativeCalls.count 0
        Assert-Equal $observedControlFailure.code 'pilot_claim_persistence_indeterminate'
        Assert-True (Test-Path -LiteralPath (Join-Path $resultsRoot 'option1-live-20260826-002/claims/01-google-candidate.claim'))
    } finally {
        Set-Item -Path Function:Invoke-CalibrationPilotAfterSlotClaimHook -Value $originalHook
        if (Test-Path -LiteralPath $resultsRoot) { Remove-Item -LiteralPath $resultsRoot -Recurse -Force }
        if (Test-Path -LiteralPath $fixture.root) { Remove-Item -LiteralPath $fixture.root -Recurse -Force }
    }
}

Invoke-Assertion 'Windows held launcher handles block ancestor replacement from preflight through completion and preserve ordering' {
    $fixture = New-TestCalibrationLauncherFixture
    $resultsRoot = New-CalibrationResultsTestRoot
    $parentDestination = $fixture.root + '-renamed'
    $agyDestination = $fixture.anchors.agy + '-renamed'
    $npmDestination = $fixture.anchors.codex + '-renamed'
    $events = [Collections.Generic.List[string]]::new()
    try {
        $resolver = {
            param($role, $lockRole)
            $events.Add("resolve:$($role.launcher)")
            $anchor = [string]$fixture.anchors[[string]$role.launcher]
            $componentId = [string]$lockRole.components[0].id
            [pscustomobject][ordered]@{
                anchor_path = $anchor
                resolved_path = [IO.Path]::GetFullPath($fixture.paths[$componentId])
            }
        }.GetNewClosure()
        $candidateInvoker = {
            param($Candidate, $Prompt, $LaunchGuard, $RunId)
            $events.Add('preflight-rename-probe')
            try {
                Assert-TestCalibrationDirectoryRenameBlocked -Source $fixture.root -Destination $parentDestination
            } catch {
                $events.Add(('preflight-rename-error:' + $_.Exception.Message))
                throw
            }
            $events.Add('preflight-parent-blocked')
            foreach ($path in @($fixture.paths.agy_native, $fixture.paths.codex_native, $fixture.paths.claude_native)) {
                $null = Assert-Throws {
                    $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    $stream.Dispose()
                } $null
                $events.Add(('write-blocked:' + [IO.Path]::GetFileName($path)))
            }
            $events.Add('all-role-prepare-verify')
            $identity = & $LaunchGuard $Candidate (New-TestCalibrationPilotCommand -Candidate $Candidate -Prompt $Prompt)
            $events.Add('claim:1')
            Assert-TestCalibrationDirectoryRenameBlocked -Source $fixture.anchors.agy -Destination $agyDestination
            $events.Add('start:1')
            Assert-Equal $identity.executable ([IO.Path]::GetFullPath($fixture.paths.agy_native))
            Assert-TestCalibrationDirectoryRenameBlocked -Source $fixture.root -Destination $parentDestination
            $events.Add('candidate-complete')
            New-TestCalibrationPilotExecution -Candidate $Candidate `
                -Answer '{"invoice_id":"INV-1042","total":"138.50","currency":"USD"}' -RunId $RunId
        }.GetNewClosure()
        $graderInvoker = {
            param($Prompt, $ResponseText, $PythonExecutor, $PythonExecutable, $PythonTimeoutMilliseconds)
            Assert-TestCalibrationDirectoryRenameBlocked -Source $fixture.root -Destination $parentDestination
            $events.Add('grader-complete')
            Invoke-CalibrationDeterministicGrader -Prompt $Prompt -ResponseText $ResponseText
        }.GetNewClosure()
        $judgeInvoker = {
            param($JudgeProfileId, $JudgePayload, $PromptDefinition, $LaunchGuard, $RunId)
            $resolved = Get-CalibrationProfileAndCandidate -ConfigurationId $JudgeProfileId
            $logical = New-TestCalibrationPilotCommand -Candidate $resolved.candidate -Prompt 'safe judge payload'
            $identity = & $LaunchGuard $resolved.candidate $logical
            $events.Add("claim:$($identity.ordinal)")
            Assert-TestCalibrationDirectoryRenameBlocked -Source $fixture.anchors.codex -Destination $npmDestination
            $events.Add("start:$($identity.ordinal)")
            [pscustomobject]@{
                pilot_execution = New-TestCalibrationPilotExecution -Candidate $resolved.candidate `
                    -Answer '{"decision":"pass","rationale":"safe evidence"}' -RunId $RunId
                decision = [pscustomobject]@{ decision = 'pass'; rationale = 'safe evidence' }
            }
        }.GetNewClosure()
        $result = Invoke-Calibration -Pilot -Run -RunId 'option1-live-20260826-002' -ResultsRoot $resultsRoot `
            -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot -AllowPilotSourceOverridesForTest `
            -LauncherLockPath $fixture.lock_path `
            -LauncherLockSchemaPath (Join-Path $calibrationRoot 'pilots/option1-launchers.schema.json') `
            -LauncherResolver $resolver -CandidateInvoker $candidateInvoker -JudgeInvoker $judgeInvoker `
            -GraderInvoker $graderInvoker -PilotGitInvoker { [pscustomobject]@{ clean = $true; commit = ('f' * 40) } }
        Assert-True ($result.run_state -ceq 'completed') `
            "Expected completed but got state '$($result.run_state)', stop '$($result.stop_reason)', events '$(@($events) -join ',')'."
        Assert-SequenceEqual @($events) @(
            'resolve:agy', 'resolve:codex', 'resolve:claude', 'preflight-rename-probe', 'preflight-parent-blocked',
            'write-blocked:agy.exe', 'write-blocked:codex.exe', 'write-blocked:claude.exe', 'all-role-prepare-verify',
            'claim:1', 'start:1', 'candidate-complete', 'grader-complete',
            'claim:2', 'start:2', 'claim:3', 'start:3')
        [IO.Directory]::Move($fixture.root, $parentDestination)
        Assert-True (Test-Path -LiteralPath $parentDestination -PathType Container)
    } finally {
        if (Test-Path -LiteralPath $resultsRoot) { Remove-Item -LiteralPath $resultsRoot -Recurse -Force }
        foreach ($path in @($parentDestination, $fixture.root)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
        }
    }
}

Invoke-Assertion 'lock-derived Codex start observer ignores alternate package injection and releases handles after start failure' {
    $fixture = New-TestCalibrationLauncherFixture
    $resultsRoot = New-CalibrationResultsTestRoot
    $alternateRoot = Join-Path $fixture.root 'alternate-codex-package'
    $alternateNative = Join-Path $alternateRoot 'vendor/x86_64-pc-windows-msvc/bin/codex.exe'
    $parentDestination = $fixture.root + '-renamed'
    $oldPackageRoot = $env:CODEX_MANAGED_PACKAGE_ROOT
    try {
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $alternateNative) -Force
        [IO.File]::WriteAllText($alternateNative, 'alternate-native-must-not-run', [Text.UTF8Encoding]::new($false))
        $env:CODEX_MANAGED_PACKAGE_ROOT = $alternateRoot
        $resolver = {
            param($role, $lockRole)
            $anchor = [string]$fixture.anchors[[string]$role.launcher]
            $componentId = [string]$lockRole.components[0].id
            [pscustomobject][ordered]@{
                anchor_path = $anchor
                resolved_path = [IO.Path]::GetFullPath($fixture.paths[$componentId])
            }
        }.GetNewClosure()
        $candidateInvoker = {
            param($Candidate, $Prompt, $LaunchGuard, $RunId)
            $null = & $LaunchGuard $Candidate (New-TestCalibrationPilotCommand -Candidate $Candidate -Prompt $Prompt)
            New-TestCalibrationPilotExecution -Candidate $Candidate `
                -Answer '{"invoice_id":"INV-1042","total":"138.50","currency":"USD"}' -RunId $RunId
        }
        $observerState = [pscustomobject]@{ count = 0; start_calls = 0; start_error = $null; file_name = $null; package_root = $null }
        $judgeCalls = [pscustomobject]@{ count = 0 }
        $startInfoObserver = {
            param($startInfo, $preparedCommand)
            $observerState.count++
            $observerState.file_name = [string]$startInfo.FileName
            $observerState.package_root = [string]$startInfo.Environment.CODEX_MANAGED_PACKAGE_ROOT
            Assert-Equal $startInfo.FileName ([IO.Path]::GetFullPath($fixture.paths.codex_native))
            Assert-True ($startInfo.FileName -cne [IO.Path]::GetFullPath($alternateNative))
            $expectedRoot = [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($fixture.paths.codex_javascript)))
            Assert-Equal $startInfo.Environment.CODEX_MANAGED_PACKAGE_ROOT $expectedRoot
            Assert-TestCalibrationDirectoryRenameBlocked -Source $fixture.root -Destination $parentDestination
            throw 'fake_start_failure_before_process_start'
        }.GetNewClosure()
        $judgeInvoker = {
            param($JudgeProfileId, $JudgePayload, $PromptDefinition, $LaunchGuard, $RunId)
            $judgeCalls.count++
            $resolved = Get-CalibrationProfileAndCandidate -ConfigurationId $JudgeProfileId
            if ($JudgeProfileId -cne 'gpt-5.6-sol__max') { throw 'second_judge_must_not_run' }
            $logical = New-CandidateCommand -Candidate $resolved.candidate -Prompt 'safe judge payload'
            $identity = & $LaunchGuard $resolved.candidate $logical
            $preparedCommand = Bind-RunnerPreparedCommand -Command $logical -PreparedIdentity $identity
            $observerState.start_calls++
            try { Invoke-NativeCandidate -Command $preparedCommand -StartInfoObserver $startInfoObserver -PreserveRawOutput | Out-Null }
            catch { $observerState.start_error = $_.Exception.Message }
            Assert-Equal $observerState.start_error 'fake_start_failure_before_process_start'
            $execution = [pscustomobject][ordered]@{
                process_started = $false
                process = $null
                canonical = $null
                failure = 'process start failed'
                stop_code = 'process_start_failed'
            }
            [pscustomobject]@{ pilot_execution = $execution; decision = $null; stop_code = 'process_start_failed' }
        }.GetNewClosure()
        $result = Invoke-Calibration -Pilot -Run -RunId 'option1-live-20260826-002' -ResultsRoot $resultsRoot `
            -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot -AllowPilotSourceOverridesForTest `
            -LauncherLockPath $fixture.lock_path `
            -LauncherLockSchemaPath (Join-Path $calibrationRoot 'pilots/option1-launchers.schema.json') `
            -LauncherResolver $resolver -CandidateInvoker $candidateInvoker -JudgeInvoker $judgeInvoker `
            -PilotGitInvoker { [pscustomobject]@{ clean = $true; commit = ('1' * 40) } }
        Assert-True ($result.run_state -ceq 'stopped') `
            "Expected stopped but got '$($result.run_state)', stop '$($result.stop_reason)', observer '$($observerState.count)', start error '$($observerState.start_error)'."
        Assert-Equal $result.stop_reason 'process_start_failed'
        Assert-Equal $result.slots_consumed.total 2
        Assert-True ($result.launcher_processes_started.total -eq 1) `
            "Expected only the fake candidate execution to be counted, got '$($result.launcher_processes_started.total)'."
        Assert-Equal $result.launcher_processes_started.provider_family.openai 0
        Assert-True ($judgeCalls.count -eq 1) "Expected one judge call, got '$($judgeCalls.count)'."
        Assert-True ($observerState.count -eq 1) `
            "Expected one start observer call, got '$($observerState.count)'; start calls '$($observerState.start_calls)', error '$($observerState.start_error)'."
        Assert-Equal $observerState.file_name ([IO.Path]::GetFullPath($fixture.paths.codex_native))
        Assert-False $observerState.file_name.Contains($alternateRoot, [StringComparison]::OrdinalIgnoreCase)
        [IO.Directory]::Move($fixture.root, $parentDestination)
        Assert-True (Test-Path -LiteralPath $parentDestination -PathType Container)
    } finally {
        $env:CODEX_MANAGED_PACKAGE_ROOT = $oldPackageRoot
        if (Test-Path -LiteralPath $resultsRoot) { Remove-Item -LiteralPath $resultsRoot -Recurse -Force }
        foreach ($path in @($parentDestination, $fixture.root)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
        }
    }
}

Invoke-Assertion 'prepared launcher handles release after success claim failure invoker failure and timeout' {
    foreach ($caseName in @('success', 'claim_failure', 'invoker_failure', 'timeout')) {
        $fixture = New-TestCalibrationLauncherFixture
        $resultsRoot = New-CalibrationResultsTestRoot
        $originalClaim = ${function:New-CalibrationPilotSlotClaim}
        try {
            $lockChecks = [pscustomobject]@{ count = 0 }
            $resolver = {
                param($role, $lockRole)
                $anchor = [string]$fixture.anchors[[string]$role.launcher]
                $componentId = [string]$lockRole.components[0].id
                return [pscustomobject][ordered]@{ anchor_path = $anchor; resolved_path = [IO.Path]::GetFullPath($fixture.paths[$componentId]) }
            }.GetNewClosure()
            if ($caseName -ceq 'claim_failure') {
                Set-Item -Path Function:New-CalibrationPilotSlotClaim -Value { throw 'claim_failure_test' }
            }
            $candidateInvoker = {
                param($Candidate, $Prompt, $LaunchGuard, $RunId)
                $preparedIdentity = & $LaunchGuard $Candidate (New-TestCalibrationPilotCommand -Candidate $Candidate -Prompt $Prompt)
                Assert-Equal $preparedIdentity.route_id $Candidate.route_id
                $null = Assert-Throws {
                    $stream = [IO.File]::Open($fixture.paths.agy_native, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    $stream.Dispose()
                } $null
                $lockChecks.count++
                if ($caseName -ceq 'invoker_failure') { throw 'process_start_failed' }
                $execution = New-TestCalibrationPilotExecution -Candidate $Candidate `
                    -Answer '{"invoice_id":"INV-1042","total":"138.50","currency":"USD"}' -RunId $RunId
                if ($caseName -ceq 'timeout') {
                    $execution.process.timed_out = $true
                    $execution.process.exit_code = $null
                }
                return $execution
            }.GetNewClosure()
            $judgeInvoker = {
                param($JudgeProfileId, $JudgePayload, $PromptDefinition, $LaunchGuard, $RunId)
                $resolved = Get-CalibrationProfileAndCandidate -ConfigurationId $JudgeProfileId
                $preparedIdentity = & $LaunchGuard $resolved.candidate `
                    (New-TestCalibrationPilotCommand -Candidate $resolved.candidate -Prompt 'safe judge payload')
                Assert-Equal $preparedIdentity.route_id $resolved.candidate.route_id
                return [pscustomobject]@{
                    pilot_execution = New-TestCalibrationPilotExecution -Candidate $resolved.candidate `
                        -Answer '{"decision":"pass","rationale":"safe evidence"}' -RunId $RunId
                    decision = [pscustomobject]@{ decision = 'pass'; rationale = 'safe evidence' }
                }
            }.GetNewClosure()
            $graderInvoker = {
                param($Prompt, $ResponseText, $PythonExecutor, $PythonExecutable, $PythonTimeoutMilliseconds)
                $null = Assert-Throws {
                    $stream = [IO.File]::Open($fixture.paths.codex_native, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    $stream.Dispose()
                } $null
                $lockChecks.count++
                return Invoke-CalibrationDeterministicGrader -Prompt $Prompt -ResponseText $ResponseText
            }.GetNewClosure()
            $result = Invoke-Calibration -Pilot -Run -RunId 'option1-live-20260826-002' -ResultsRoot $resultsRoot `
                -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot -AllowPilotSourceOverridesForTest `
                -LauncherLockPath $fixture.lock_path `
                -LauncherLockSchemaPath (Join-Path $calibrationRoot 'pilots/option1-launchers.schema.json') `
                -LauncherResolver $resolver -CandidateInvoker $candidateInvoker -JudgeInvoker $judgeInvoker `
                -GraderInvoker $graderInvoker -PilotGitInvoker { [pscustomobject]@{ clean = $true; commit = ('b' * 40) } }
            if ($caseName -ceq 'success') {
                Assert-Equal $result.run_state 'completed'
                Assert-True ($lockChecks.count -ge 2)
            } else {
                Assert-True ($result.run_state -cin @('stopped', 'indeterminate'))
            }
            $stream = [IO.File]::Open($fixture.paths.agy_native, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $stream.Dispose()
            $stream = [IO.File]::Open($fixture.paths.codex_native, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $stream.Dispose()
        } finally {
            Set-Item -Path Function:New-CalibrationPilotSlotClaim -Value $originalClaim
            if (Test-Path -LiteralPath $resultsRoot) { Remove-Item -LiteralPath $resultsRoot -Recurse -Force }
            if (Test-Path -LiteralPath $fixture.root) { Remove-Item -LiteralPath $fixture.root -Recurse -Force }
        }
    }
}

Invoke-Assertion 'launcher preparation rejects reparse components and releases prior verified handles' {
    $fixture = New-TestCalibrationLauncherFixture
    $junctionPath = Join-Path $fixture.anchors.codex 'node_modules'
    $targetPath = Join-Path $fixture.root 'outside-node_modules'
    $prepared = $null
    try {
        Move-Item -LiteralPath $junctionPath -Destination $targetPath
        $null = New-Item -ItemType Junction -Path $junctionPath -Target $targetPath -ErrorAction Stop
        $bundle = New-CalibrationPilotSourceBundle -PilotManifestPath $pilotManifestPath `
            -PilotManifestSchemaPath $pilotManifestSchemaPath -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot `
            -LauncherLockPath $fixture.lock_path `
            -LauncherLockSchemaPath (Join-Path $calibrationRoot 'pilots/option1-launchers.schema.json')
        $plan = New-CalibrationPilotPlan -SourceBundle $bundle
        $resolver = {
            param($role, $lockRole)
            $anchor = [string]$fixture.anchors[[string]$role.launcher]
            $componentId = [string]$lockRole.components[0].id
            return [pscustomobject][ordered]@{
                anchor_path = $anchor
                resolved_path = [IO.Path]::GetFullPath($fixture.paths[$componentId])
            }
        }.GetNewClosure()
        $null = Assert-Throws {
            New-CalibrationPilotPreparedLaunches -Plan $plan -SourceBundle $bundle -LauncherResolver $resolver | Out-Null
        } 'source_drift'
        foreach ($path in @($fixture.paths.agy_native, $fixture.paths.codex_shim)) {
            $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $stream.Dispose()
        }
    } finally {
        if (Test-Path -LiteralPath $junctionPath) { Remove-Item -LiteralPath $junctionPath -Force }
        if (Test-Path -LiteralPath $targetPath) { Remove-Item -LiteralPath $targetPath -Recurse -Force }
        if (Test-Path -LiteralPath $fixture.root) { Remove-Item -LiteralPath $fixture.root -Recurse -Force }
    }
}

if ($script:Failures.Count -gt 0) {
    $script:Failures | ForEach-Object { Write-Host $_ }
    exit 1
}

Write-Host 'All calibration tests passed.'
