# Confirmed live pilot path (traced forward from pilot/run_pilot.ps1):
# Matrix load: Get-Content + ConvertFrom-Json (no reusable loader function) -> Invoke-PilotRun.
# Candidate load/selection: Select-PilotCandidates -> Test-CandidateMatrix -> Test-CandidateDefinition.
# One-candidate execution: Invoke-PilotRun -> New-PilotPrompt -> New-CandidateCommand -> Invoke-NativeCandidate.
# Provider normalization: ConvertFrom-CodexOutput / ConvertFrom-ClaudeOutput / ConvertFrom-AgyOutput -> Test-CanonicalResponse.
# Result construction/persistence: New-ResultRecord -> Add-PilotResultRecord.
# Reusable runner functions: Select-PilotCandidates, Test-CandidateMatrix, Test-CandidateDefinition,
# New-PilotPrompt, New-CandidateCommand, Invoke-NativeCandidate, ConvertFrom-CodexOutput,
# ConvertFrom-ClaudeOutput, ConvertFrom-AgyOutput, Test-CanonicalResponse, New-ResultRecord,
# Add-PilotResultRecord, and Invoke-PilotRun.
# Wished-for schema result: Test-RouterSchema returns
# [pscustomobject]@{ valid = [bool]; errors = @([pscustomobject]@{ code = [string]; path = [string] }) }.
# An omitted required property uses code 'required_property_missing' and an exact JSONPath such as '$.task_type'.
# Stable policy ties use ascending ordinal composite identity: launcher|configuration_id.

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $projectRoot

$schemaModulePath = Join-Path $projectRoot 'router/lib/schema.ps1'
$policyModulePath = Join-Path $projectRoot 'router/lib/policy.ps1'
$requestSchemaPath = Join-Path $projectRoot 'router/schemas/request-profile.schema.json'
$profileSchemaPath = Join-Path $projectRoot 'router/schemas/model-profile.schema.json'

$schemaBoundary = [ordered]@{
    'schema module' = $schemaModulePath
    'request schema' = $requestSchemaPath
    'model profile schema' = $profileSchemaPath
}
$missingBoundary = @(
    foreach ($entry in $schemaBoundary.GetEnumerator()) {
        if (-not (Test-Path -LiteralPath $entry.Value -PathType Leaf)) {
            '{0} ({1})' -f $entry.Key, [System.IO.Path]::GetRelativePath($projectRoot, $entry.Value)
        }
    }
)

if ($missingBoundary.Count -gt 0) {
    [Console]::Error.WriteLine(
        'RED: router production boundary missing: {0}' -f ($missingBoundary -join '; ')
    )
    exit 1
}

. $schemaModulePath
$policyAvailable = Test-Path -LiteralPath $policyModulePath -PathType Leaf
if ($policyAvailable) {
    . $policyModulePath
}

$failures = [System.Collections.Generic.List[string]]::new()
$requiredQualityKeys = [ordered]@{
    task_types = @('general', 'coding', 'math', 'reasoning', 'writing', 'summarization', 'extraction', 'research_synthesis')
    domains = @('general', 'computer_science', 'mathematics', 'physics', 'chemistry', 'biology', 'medicine', 'engineering', 'social_science', 'humanities', 'business', 'finance', 'law')
    complexities = @('low', 'medium', 'high')
    capabilities = @('instruction_following', 'reasoning', 'structured_output', 'factual_reliability', 'source_grounded_synthesis', 'long_context')
}

function Assert-Equal {
    param(
        [AllowNull()][object]$Actual,
        [AllowNull()][object]$Expected
    )

    if ($Actual -ne $Expected) {
        throw "Expected '$Expected' but got '$Actual'."
    }
}

function Assert-False {
    param([bool]$Condition)

    if ($Condition) {
        throw 'Expected condition to be false.'
    }
}

function Assert-ValidationSuccess {
    param([Parameter(Mandatory)][object]$Validation)

    Assert-Equal $Validation.valid $true
    Assert-Equal (@($Validation.errors).Count) 0
}

function Assert-RequiredPropertyError {
    param(
        [Parameter(Mandatory)][object]$Validation,
        [Parameter(Mandatory)][string]$Path
    )

    Assert-False $Validation.valid
    $matchingErrors = @(
        $Validation.errors | Where-Object {
            $_.code -ceq 'required_property_missing' -and $_.path -ceq $Path
        }
    )
    Assert-Equal $matchingErrors.Count 1
}

function Assert-SequenceEqual {
    param(
        [object[]]$Actual,
        [object[]]$Expected
    )

    Assert-Equal $Actual.Count $Expected.Count
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        Assert-Equal $Actual[$index] $Expected[$index]
    }
}

function Invoke-Assertion {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Script
    )

    try {
        & $Script
        Write-Host "PASS $Name"
    } catch {
        $failures.Add("FAIL ${Name}: $($_.Exception.Message)")
    }
}

function Copy-TestObject {
    param([Parameter(Mandatory)][object]$Value)

    return ($Value | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30)
}

function New-MinimalRequest {
    [pscustomobject]@{
        request_text = 'Explain why this algorithm fails on an empty list.'
        task_type = 'coding'
        domain = 'computer_science'
        complexity = 'medium'
        quality_floor = 'strong'
        latency = 'normal'
        privacy_level = 'standard'
        risk_level = 'standard'
        output_length = 'normal'
        language = 'english'
        additional_capabilities = @()
    }
}

function Get-MinimalProfiles {
    $fixtureRoot = Join-Path $PSScriptRoot 'fixtures/minimal-profiles'
    return @(
        Get-ChildItem -LiteralPath $fixtureRoot -File -Filter '*.json' |
            Sort-Object -Property Name |
            ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json -Depth 30 }
    )
}

function Get-CompositeIdentity {
    param([Parameter(Mandatory)][object]$Candidate)

    return '{0}|{1}' -f $Candidate.launcher, $Candidate.configuration_id
}

Invoke-Assertion 'request schema rejects a record missing a required field' {
    $validRequest = New-MinimalRequest
    $validValidation = Test-RouterSchema -Value $validRequest -SchemaPath $requestSchemaPath
    Assert-ValidationSuccess $validValidation

    $invalidRequest = Copy-TestObject $validRequest
    $invalidRequest.PSObject.Properties.Remove('task_type')

    $validation = Test-RouterSchema -Value $invalidRequest -SchemaPath $requestSchemaPath

    Assert-RequiredPropertyError -Validation $validation -Path '$.task_type'
}

Invoke-Assertion 'profile schema rejects every omitted required quality key' {
    $validProfiles = @(Get-MinimalProfiles)
    foreach ($profile in $validProfiles) {
        $validValidation = Test-RouterSchema -Value $profile -SchemaPath $profileSchemaPath
        Assert-ValidationSuccess $validValidation
    }
    $validProfile = $validProfiles[0]

    foreach ($mapName in $requiredQualityKeys.Keys) {
        $actualKeys = @($validProfile.quality.$mapName.PSObject.Properties.Name | Sort-Object)
        $expectedKeys = @($requiredQualityKeys[$mapName] | Sort-Object)
        Assert-SequenceEqual $actualKeys $expectedKeys

        foreach ($qualityKey in $requiredQualityKeys[$mapName]) {
            $invalidProfile = Copy-TestObject $validProfile
            $invalidProfile.quality.$mapName.PSObject.Properties.Remove($qualityKey)

            $validation = Test-RouterSchema -Value $invalidProfile -SchemaPath $profileSchemaPath

            Assert-RequiredPropertyError -Validation $validation -Path "$.quality.$mapName.$qualityKey"
        }
    }
}

if ($policyAvailable) {
    Invoke-Assertion 'stable identity is ascending ordinal launcher|configuration_id' {
        $agyIdentity = 'agy|shared-model__medium'
        $codexIdentity = 'codex|shared-model__medium'

        Assert-Equal ([string]::CompareOrdinal($agyIdentity, $codexIdentity) -lt 0) $true
    }

    Invoke-Assertion 'policy preserves exact composite identity' {
        $decision = Invoke-RouterPolicy -Request (New-MinimalRequest) -Profiles (Get-MinimalProfiles)
        $identities = @(
            $decision.candidate_evaluations |
                ForEach-Object { Get-CompositeIdentity $_ }
        )

        Assert-Equal $identities.Count 2
        Assert-Equal (@($identities | Where-Object { $_ -ceq 'agy|shared-model__medium' }).Count) 1
        Assert-Equal (@($identities | Where-Object { $_ -ceq 'codex|shared-model__medium' }).Count) 1
    }

    Invoke-Assertion 'policy selects exactly one candidate' {
        $decision = Invoke-RouterPolicy -Request (New-MinimalRequest) -Profiles (Get-MinimalProfiles)

        Assert-Equal (@($decision.selected_candidate).Count) 1
        Assert-Equal (Get-CompositeIdentity $decision.selected_candidate) 'agy|shared-model__medium'
    }

    Invoke-Assertion 'policy selection is invariant to forward and reverse tied input order' {
        $forwardProfiles = @(Get-MinimalProfiles)
        $reverseProfiles = [object[]]$forwardProfiles.Clone()
        [array]::Reverse($reverseProfiles)
        Assert-SequenceEqual @($forwardProfiles | ForEach-Object { Get-CompositeIdentity $_ }) @(
            'agy|shared-model__medium'
            'codex|shared-model__medium'
        )
        Assert-SequenceEqual @($reverseProfiles | ForEach-Object { Get-CompositeIdentity $_ }) @(
            'codex|shared-model__medium'
            'agy|shared-model__medium'
        )
        $inputOrders = @(
            [pscustomobject]@{ name = 'forward'; profiles = $forwardProfiles }
            [pscustomobject]@{ name = 'reverse'; profiles = $reverseProfiles }
        )
        $selectedIdentities = @(
            foreach ($inputOrder in $inputOrders) {
                1..25 | ForEach-Object {
                    $decision = Invoke-RouterPolicy -Request (New-MinimalRequest) -Profiles $inputOrder.profiles
                    $selectedIdentity = Get-CompositeIdentity $decision.selected_candidate
                    if ($selectedIdentity -cne 'agy|shared-model__medium') {
                        throw "The $($inputOrder.name) tied input selected '$selectedIdentity'."
                    }
                    $selectedIdentity
                }
            }
        )

        Assert-Equal (@($selectedIdentities | Select-Object -Unique).Count) 1
        Assert-Equal $selectedIdentities[0] 'agy|shared-model__medium'
    }
} else {
    Write-Host 'PENDING policy tests: router/lib/policy.ps1 is planned for Task 6.'
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    exit 1
}

exit 0
