$ErrorActionPreference = 'Stop'

$script:Failures = [Collections.Generic.List[string]]::new()
$calibrationRoot = Split-Path -Parent $PSScriptRoot
$projectRoot = Split-Path -Parent $calibrationRoot
$implementationPath = Join-Path $calibrationRoot 'run_calibration.ps1'
$setPath = Join-Path $calibrationRoot 'calibration-set-v1.json'
$rubricsRoot = Join-Path $calibrationRoot 'rubrics'

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

Invoke-Assertion 'Task 9 production script exists before behavioral checks' {
    Assert-True (Test-Path -LiteralPath $implementationPath -PathType Leaf) 'Missing calibration/run_calibration.ps1.'
}

if (Test-Path -LiteralPath $implementationPath -PathType Leaf) {
    . $implementationPath

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
                [pscustomobject]@{
                    response = [pscustomobject]@{
                        status = 'completed'; configuration_id = 'gpt-5.6-sol__max'; provider = 'openai'
                        launcher = 'codex'; model = 'gpt-5.6-sol'; effort = 'max'; output = "answer-$($PromptDefinition.id)"
                        price = 1.25; latency = 12
                    }
                    trace = [pscustomobject]@{ effective_quality = 'strong'; quality_bottleneck = 'task_types.general' }
                }
            }
            $judge = {
                param($JudgeProfileId, $JudgePayload, $PromptDefinition)
                $script:RunJudgeCalls++
                [pscustomobject]@{ decision = 'pass'; rationale = "reviewed-$JudgeProfileId" }
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
            foreach ($review in $artifact.reviews) { Assert-Equal @($review.judge_decisions).Count 2 }
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
