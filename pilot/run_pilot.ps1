param(
    [switch]$RunAll,
    [switch]$IncludeSpecialRoutes,
    [string]$RouteId,
    # Deliberate migration boundary: leave legacy pilot/results/test-run.jsonl untouched.
    [string]$ResultsPath = 'pilot/results/runner-test-run.jsonl'
)

$ErrorActionPreference = 'Stop'

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $projectRoot 'pilot/lib/runner.ps1')

try {
    $matrixPath = Join-Path $projectRoot 'pilot/model_matrix.json'
    $matrix = Get-Content -Raw -LiteralPath $matrixPath | ConvertFrom-Json -Depth 30
    $run = Invoke-PilotRun -Matrix $matrix -RunAll:$RunAll -IncludeSpecialRoutes:$IncludeSpecialRoutes -RouteId $RouteId -ResultsPath $ResultsPath

    if ($run.mode -eq 'dry-run') {
        Write-Output "Dry run: $($run.selected.Count) candidate(s) selected; no provider processes invoked."
        $run.selected | ForEach-Object {
            Write-Output ("{0} [{1}/{2}/{3}]" -f $_.route_id, $_.tool, $_.provider, $_.model)
        }
    } else {
        Write-Output "Run complete: $($run.records.Count) candidate(s) recorded."
    }
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
