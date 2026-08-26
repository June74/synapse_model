# Calibration JSON Contract Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make exact-fields calibration grade only a complete direct JSON response and preserve ISO-8601 JSON strings through every live calibration-set parsing path.

**Architecture:** Keep the repair inside the existing calibration boundaries. `Get-CalibrationJsonPayload` will trim whitespace and parse the complete answer without Markdown extraction. The normal importer, immutable pilot source snapshot loader, and candidate-answer parser will opt into PowerShell's `-DateKind String` behavior so JSON strings remain strings. The extraction rubric will state the same complete-response rule used by the deterministic grader and judges.

**Tech Stack:** PowerShell 7, `System.Text.Json`, repository calibration functional/security suites, existing five-suite offline gate.

---

### Task 1: Enforce complete-response JSON

**Files:**
- Modify: `calibration/tests/calibration.tests.ps1:1961-1992`
- Modify: `calibration/lib/grading.ps1:36-69`
- Modify: `calibration/rubrics/extraction-v1.json`

- [ ] **Step 1: Write the strict-format failing regressions**

Replace the existing fenced-pass assertion with an explicit conservative malformed result and add equivalent uppercase-fence, unlabeled-fence, and leading-prose cases. Keep the direct object positive control.

```powershell
$fenced = Invoke-CalibrationDeterministicGrader -Prompt $prompt -ResponseText $fencedText
Assert-Equal $fenced.outcome 'review_required'
Assert-Equal $fenced.reason_code 'malformed_output'

foreach ($invalid in @($uppercaseFence, $unlabeledFence, $leadingProse)) {
    $result = Invoke-CalibrationDeterministicGrader -Prompt $prompt -ResponseText $invalid
    Assert-Equal $result.outcome 'review_required'
    Assert-Equal $result.reason_code 'malformed_output'
}
```

In the operator-documentation contract assertion, require the extraction rubric's first criterion to say that the complete whitespace-trimmed response must parse directly and that Markdown fences or prose fail the format criterion.

- [ ] **Step 2: Run the functional suite and verify RED**

Run:

```powershell
pwsh -NoProfile -File .\calibration\tests\calibration.tests.ps1
```

Expected: exit code 1. The fenced and uppercase-fenced results are `pass` instead of `review_required`, and the rubric wording assertion fails. Direct JSON continues to pass.

- [ ] **Step 3: Implement the minimum strict parser and rubric wording**

Change `Get-CalibrationJsonPayload` so it never extracts a Markdown block:

```powershell
function Get-CalibrationJsonPayload {
    param([Parameter(Mandatory)][string]$ResponseText)
    $jsonText = $ResponseText.Trim()
    try {
        $document = [Text.Json.JsonDocument]::Parse($jsonText)
        try {
            if (@(Find-RouterDuplicateJsonPropertyPath -Element $document.RootElement).Count -gt 0) {
                return [pscustomobject]@{ valid = $false; value = $null }
            }
        } finally { $document.Dispose() }
        $value = $jsonText | ConvertFrom-Json -Depth 100 -NoEnumerate -ErrorAction Stop
        if ($null -eq $value) { throw 'null is not an extraction result' }
        return [pscustomobject]@{ valid = $true; value = $value }
    } catch {
        return [pscustomobject]@{ valid = $false; value = $null }
    }
}
```

Change the extraction rubric's format criterion to:

```json
"After trimming surrounding whitespace, the complete output parses directly as the requested JSON value; Markdown fences and explanatory prose fail this criterion."
```

- [ ] **Step 4: Run the functional suite and verify GREEN**

Run the same functional command. Expected: exit code 0; direct JSON passes; all fenced/prose cases return `review_required` with `malformed_output`; ambiguity, shape, and value regressions remain green.

- [ ] **Step 5: Commit Task 1**

```powershell
git add -- calibration/lib/grading.ps1 calibration/rubrics/extraction-v1.json calibration/tests/calibration.tests.ps1
git commit -m "fix: require direct calibration JSON output"
```

### Task 2: Preserve JSON timestamp strings

**Files:**
- Modify: `calibration/tests/calibration.tests.ps1`
- Modify: `calibration/lib/grading.ps1:54-65`
- Modify: `calibration/run_calibration.ps1:401-418`
- Modify: `calibration/run_calibration.ps1:674-700`

- [ ] **Step 1: Write failing date-kind regressions for every live path**

Add one assertion covering the normal importer and pilot source snapshot:

```powershell
$imported = Import-CalibrationSet -Path $setPath -RubricsRoot $rubricsRoot
$importedHigh = @($imported.set.prompts | Where-Object { $_.id -ceq 'extraction-high-engineering-v1' })[0]
Assert-True ($importedHigh.grading.deterministic_grader.expected[0].timestamp_utc -is [string])

$bundle = New-CalibrationPilotSourceBundle -PilotManifestPath $pilotManifestPath `
    -PilotManifestSchemaPath $pilotManifestSchemaPath -CalibrationSetPath $setPath -RubricsRoot $rubricsRoot
$bundleHigh = @($bundle.sources.calibration_set.value.prompts |
    Where-Object { $_.id -ceq 'extraction-high-engineering-v1' })[0]
Assert-True ($bundleHigh.grading.deterministic_grader.expected[0].timestamp_utc -is [string])
```

Add a direct-array grader positive control built from the exact expected JSON:

```powershell
$response = $importedHigh.grading.deterministic_grader.expected | ConvertTo-Json -Depth 20 -Compress
$result = Invoke-CalibrationDeterministicGrader -Prompt $importedHigh -ResponseText $response
Assert-Equal $result.outcome 'pass'
Assert-Equal @($result.checks | Where-Object { -not $_.passed }).Count 0
```

- [ ] **Step 2: Run the functional suite and verify RED**

Run the calibration functional suite. Expected: exit code 1. Imported and pilot-snapshot timestamps are `System.DateTime`, and the direct high/engineering array fails the string schema check.

- [ ] **Step 3: Preserve JSON strings in the three parsing boundaries**

Add `-DateKind String` to:

```powershell
# Import-CalibrationSet
$set = $setText | ConvertFrom-Json -Depth 100 -DateKind String -ErrorAction Stop

# Read-CalibrationPilotJsonSnapshot
$value = $text | ConvertFrom-Json -Depth 100 -DateKind String -ErrorAction Stop

# Get-CalibrationJsonPayload
$value = $jsonText | ConvertFrom-Json -Depth 100 -NoEnumerate -DateKind String -ErrorAction Stop
```

Do not change general router JSON parsing, provider envelopes, or persisted live artifacts.

- [ ] **Step 4: Run the functional suite and verify GREEN**

Expected: exit code 0. Both source paths retain `timestamp_utc` as `System.String`; the exact direct array passes schema and value checks; strict fenced-output regressions remain green.

- [ ] **Step 5: Commit Task 2**

```powershell
git add -- calibration/lib/grading.ps1 calibration/run_calibration.ps1 calibration/tests/calibration.tests.ps1
git commit -m "fix: preserve calibration JSON string types"
```

### Task 3: Close evidence and run the offline gate

**Files:**
- Modify: `docs/superpowers/specs/2026-08-26-calibration-json-rubric-adjudication.md`
- Modify: `docs/operations/setbacks/incidents/2026-08-26T175410Z-exact-fields-date-coercion.md`
- Modify: `docs/operations/setbacks/INDEX.md`

- [ ] **Step 1: Run focused security verification**

```powershell
pwsh -NoProfile -File .\calibration\tests\calibration_security.tests.ps1
```

Expected: exit code 0. No artifact, credential-sanitization, source-snapshot, or bounded-output regression fails.

- [ ] **Step 2: Run all five offline suites sequentially**

```powershell
pwsh -NoProfile -File .\pilot\tests\runner.tests.ps1
pwsh -NoProfile -File .\router\tests\router.tests.ps1
. .\router\lib\trace.ps1
$python = Resolve-RouterPythonExecutable
& $python -m unittest router.storage.test_sqlite_store
pwsh -NoProfile -File .\calibration\tests\calibration.tests.ps1
pwsh -NoProfile -File .\calibration\tests\calibration_security.tests.ps1
```

Expected: every command exits 0; the pilot suite may retain its documented privilege-only symbolic-link skip. No `-Run`, provider, launcher, or network operation occurs.

- [ ] **Step 3: Verify scope and immutable live evidence**

```powershell
git diff --check
git diff --name-only HEAD~2..HEAD -- profiles pilot/model_matrix.json router/lib/policy.ps1 router/lib/quality.ps1
Get-FileHash .\calibration\results\option1-live-20260826-002\result.json -Algorithm SHA256
```

Expected: no production profile/routing file appears; the live result SHA-256 remains `b8b4cbfbe5a4122f33716efd69e8aea4bf935e69b2bc850245a4422cb19a1a7b`.

- [ ] **Step 4: Close the contained date-coercion incident and update the adjudication**

Record the exact RED/GREEN evidence, final suite counts, implementation commits, no-live-operation boundary, and immutable result hash. Change `SB-20260826-175410-exact-fields-date-coercion` from `contained` to `closed` only after the complete gate passes.

- [ ] **Step 5: Obtain specification and code-quality reviews**

Review the completed diff against `2026-08-26-calibration-json-rubric-adjudication.md`. Fix every material finding and rerun affected suites.

- [ ] **Step 6: Commit documentation closure**

```powershell
git add -- docs/superpowers/specs/2026-08-26-calibration-json-rubric-adjudication.md `
    docs/operations/setbacks/incidents/2026-08-26T175410Z-exact-fields-date-coercion.md `
    docs/operations/setbacks/INDEX.md
git commit -m "docs: close calibration JSON repair"
```

No push, pull request, merge, provider execution, live calibration, retry, result rewrite, or quality promotion is part of this plan.
