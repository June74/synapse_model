$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $projectRoot

$runnerPath = Join-Path $projectRoot 'pilot/lib/runner.ps1'
if (Test-Path $runnerPath) {
    . $runnerPath
}

$failures = [System.Collections.Generic.List[string]]::new()

function Assert-Equal {
    param(
        [object]$Actual,
        [object]$Expected
    )

    if ($Actual -ne $Expected) {
        throw "Expected '$Expected' but got '$Actual'."
    }
}

function Assert-True {
    param([bool]$Condition)

    if (-not $Condition) {
        throw 'Expected condition to be true.'
    }
}

function Assert-Contains {
    param(
        [string]$Haystack,
        [string]$Needle
    )

    if (-not $Haystack.Contains($Needle)) {
        throw "Expected '$Haystack' to contain '$Needle'."
    }
}

function Assert-Throws {
    param([scriptblock]$Script)

    $threw = $false
    try {
        & $Script
    } catch {
        $threw = $true
    }

    if (-not $threw) {
        throw 'Expected script to throw.'
    }
}

function Invoke-Assertion {
    param(
        [string]$Name,
        [scriptblock]$Script
    )

    try {
        & $Script
        Write-Host "PASS $Name"
    } catch {
        $failures.Add("FAIL ${Name}: $($_.Exception.Message)")
    }
}

Invoke-Assertion 'New-RouteId normalizes route components' {
    Assert-Equal (New-RouteId -Tool 'codex' -Model 'gpt-5.6-sol' -Effort 'xhigh') 'codex__gpt_5_6_sol__xhigh'
}

Invoke-Assertion 'New-RouteId replaces punctuation in each route component' {
    $routeId = New-RouteId -Tool 'co-dex' -Model 'gpt.5/6' -Effort 'x-high'
    Assert-Contains $routeId 'co_dex'
    Assert-Contains $routeId 'gpt_5_6'
    Assert-Contains $routeId 'x_high'
}

Invoke-Assertion 'ConvertFrom-CodexOutput reads the agent message envelope' {
    $codex = ConvertFrom-CodexOutput (Get-Content -Raw pilot/tests/fixtures/codex-success.jsonl)
    Assert-Equal $codex.status 'success'
    Assert-Equal $codex.answer '4'
    Assert-Equal $codex.error $null
}

Invoke-Assertion 'ConvertFrom-ClaudeOutput reads the result envelope' {
    $claude = ConvertFrom-ClaudeOutput (Get-Content -Raw pilot/tests/fixtures/claude-success.json)
    Assert-Equal $claude.status 'success'
    Assert-Equal $claude.answer '4'
    Assert-Equal $claude.error $null
}

Invoke-Assertion 'ConvertFrom-AgyOutput reads structured output' {
    $agy = ConvertFrom-AgyOutput (Get-Content -Raw pilot/tests/fixtures/agy-success.json)
    Assert-Equal $agy.status 'success'
    Assert-Equal $agy.answer '4'
    Assert-Equal $agy.error $null
}

Invoke-Assertion 'Test-CanonicalResponse rejects a non-string answer' {
    $invalid = Test-CanonicalResponse (Get-Content -Raw pilot/tests/fixtures/contract-type-failure.json | ConvertFrom-Json)
    Assert-True (-not $invalid.valid)
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    exit 1
}

exit 0
