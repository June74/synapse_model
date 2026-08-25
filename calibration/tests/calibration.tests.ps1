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
    return $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
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
                } 'Pilot manifest JSON is invalid' | Out-Null
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
            } 'Pilot model matrix JSON is invalid' | Out-Null

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
            } 'Pilot profile' | Out-Null
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
                } $case.expected | Out-Null
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
                } $case.expected | Out-Null
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

    Invoke-Assertion 'canonical pilot hashes ignore object insertion order but preserve array order and values' {
        $left = [pscustomobject][ordered]@{ z = 1; a = @('first', 'second'); nested = [pscustomobject][ordered]@{ b = $true; a = $null } }
        $right = [pscustomobject][ordered]@{ nested = [pscustomobject][ordered]@{ a = $null; b = $true }; a = @('first', 'second'); z = 1 }
        $changedArray = [pscustomobject][ordered]@{ a = @('second', 'first'); nested = [pscustomobject][ordered]@{ a = $null; b = $true }; z = 1 }
        Assert-Equal (Get-CalibrationObjectSha256 -Value $left) (Get-CalibrationObjectSha256 -Value $right)
        Assert-False ((Get-CalibrationObjectSha256 -Value $left) -ceq (Get-CalibrationObjectSha256 -Value $changedArray))
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
            $hashNames = @('manifest', 'matrix', 'candidate_profile', 'calibration_set', 'prompt_definition', 'rubric', 'response_schema')
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
            } 'pilot_live_not_implemented'
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
                    -RubricsRoot $rubricsRoot -CandidateInvoker $spy -JudgeInvoker $spy | Out-Null
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
                Invoke-Calibration -Pilot -ResultsRoot $resultsRoot -CalibrationSetPath $badSetPath -RubricsRoot $rubricsRoot | Out-Null
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
                        -CandidateInvoker $spy -JudgeInvoker $spy -RouterInvoker $spy | Out-Null
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

if ($script:Failures.Count -gt 0) {
    $script:Failures | ForEach-Object { Write-Host $_ }
    exit 1
}

Write-Host 'All calibration tests passed.'
