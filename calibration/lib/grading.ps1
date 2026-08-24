function New-CalibrationGraderResult {
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][ValidateSet('pass', 'fail', 'review_required')][string]$Outcome,
        [AllowNull()][string]$ReasonCode,
        [AllowEmptyCollection()][object[]]$Checks = @()
    )
    return [pscustomobject][ordered]@{
        type = $Type
        outcome = $Outcome
        reason_code = $ReasonCode
        checks = @($Checks)
    }
}

function ConvertTo-CalibrationEvidenceKey {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    $normalized = $Text.Normalize([Text.NormalizationForm]::FormKC).ToLowerInvariant()
    return [regex]::Replace($normalized, '[^\p{L}\p{Nd}]', '')
}

function Get-CalibrationJsonPayload {
    param([Parameter(Mandatory)][string]$ResponseText)
    $trimmed = $ResponseText.Trim()
    $jsonText = $null
    if ($trimmed.StartsWith('{', [StringComparison]::Ordinal) -or
        $trimmed.StartsWith('[', [StringComparison]::Ordinal)) {
        $jsonText = $trimmed
    } else {
        $match = [regex]::Match(
            $trimmed,
            '\A```json[ \t]*\r?\n(?<json>[\s\S]*?)\r?\n```\z',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        if (-not $match.Success) {
            return [pscustomobject]@{ valid = $false; value = $null }
        }
        $jsonText = $match.Groups['json'].Value.Trim()
    }
    try {
        $document = [Text.Json.JsonDocument]::Parse($jsonText)
        try {
            if (@(Find-RouterDuplicateJsonPropertyPath -Element $document.RootElement).Count -gt 0) {
                return [pscustomobject]@{ valid = $false; value = $null }
            }
        } finally {
            $document.Dispose()
        }
        $value = $jsonText | ConvertFrom-Json -Depth 100 -NoEnumerate -ErrorAction Stop
        if ($null -eq $value) { throw 'null is not an extraction result' }
        return [pscustomobject]@{ valid = $true; value = $value }
    } catch {
        return [pscustomobject]@{ valid = $false; value = $null }
    }
}

function Test-CalibrationJsonObject {
    param([AllowNull()][object]$Value)
    return $null -ne $Value -and
        ($Value -is [Collections.IDictionary] -or $Value.GetType() -eq [Management.Automation.PSCustomObject])
}

function Get-CalibrationJsonPropertyNames {
    param([Parameter(Mandatory)][object]$Value)
    if ($Value -is [Collections.IDictionary]) { return @($Value.Keys | ForEach-Object { [string]$_ }) }
    return @($Value.PSObject.Properties.Name)
}

function Get-CalibrationJsonPropertyValue {
    param([Parameter(Mandatory)][object]$Value, [Parameter(Mandatory)][string]$Name)
    if ($Value -is [Collections.IDictionary]) { return $Value[$Name] }
    return $Value.PSObject.Properties[$Name].Value
}

function Test-CalibrationJsonNumber {
    param([AllowNull()][object]$Value, [switch]$Integer)
    if ($null -eq $Value -or $Value -is [bool]) { return $false }
    $numericTypes = @([byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64], [single], [double], [decimal], [Numerics.BigInteger])
    if ($Value.GetType() -notin $numericTypes) { return $false }
    try {
        $number = [decimal]$Value
        if ($Integer -and $number -ne [decimal]::Truncate($number)) { return $false }
        return $true
    } catch { return $false }
}

function Test-CalibrationJsonSchemaValue {
    param([AllowNull()][object]$Value, [AllowNull()][object]$Schema)
    if ($Schema -is [string]) {
        switch ([string]$Schema) {
            'string' { return $Value -is [string] }
            'integer' { return Test-CalibrationJsonNumber -Value $Value -Integer }
            'number' { return Test-CalibrationJsonNumber -Value $Value }
            'boolean' { return $Value -is [bool] }
            'null' { return $null -eq $Value }
            default { return $false }
        }
    }
    if ($Schema -is [Collections.IList]) {
        if ($Schema.Count -ne 1 -or $Value -isnot [Collections.IList]) { return $false }
        foreach ($item in @($Value)) {
            if (-not (Test-CalibrationJsonSchemaValue -Value $item -Schema $Schema[0])) { return $false }
        }
        return $true
    }
    if (Test-CalibrationJsonObject $Schema) {
        if (-not (Test-CalibrationJsonObject $Value)) { return $false }
        [string[]]$expectedNames = @(Get-CalibrationJsonPropertyNames $Schema)
        [string[]]$actualNames = @(Get-CalibrationJsonPropertyNames $Value)
        [Array]::Sort($expectedNames, [StringComparer]::Ordinal)
        [Array]::Sort($actualNames, [StringComparer]::Ordinal)
        if ($expectedNames.Count -ne $actualNames.Count) { return $false }
        for ($index = 0; $index -lt $expectedNames.Count; $index++) {
            if ($expectedNames[$index] -cne $actualNames[$index]) { return $false }
            if (-not (Test-CalibrationJsonSchemaValue `
                -Value (Get-CalibrationJsonPropertyValue $Value $expectedNames[$index]) `
                -Schema (Get-CalibrationJsonPropertyValue $Schema $expectedNames[$index]))) { return $false }
        }
        return $true
    }
    return $false
}

function Test-CalibrationJsonExactValue {
    param([AllowNull()][object]$Actual, [AllowNull()][object]$Expected)
    if ($null -eq $Actual -or $null -eq $Expected) { return $null -eq $Actual -and $null -eq $Expected }
    if (Test-CalibrationJsonObject $Expected) {
        if (-not (Test-CalibrationJsonObject $Actual)) { return $false }
        [string[]]$expectedNames = @(Get-CalibrationJsonPropertyNames $Expected)
        [string[]]$actualNames = @(Get-CalibrationJsonPropertyNames $Actual)
        [Array]::Sort($expectedNames, [StringComparer]::Ordinal)
        [Array]::Sort($actualNames, [StringComparer]::Ordinal)
        if ($expectedNames.Count -ne $actualNames.Count) { return $false }
        for ($index = 0; $index -lt $expectedNames.Count; $index++) {
            if ($expectedNames[$index] -cne $actualNames[$index] -or
                -not (Test-CalibrationJsonExactValue `
                    -Actual (Get-CalibrationJsonPropertyValue $Actual $expectedNames[$index]) `
                    -Expected (Get-CalibrationJsonPropertyValue $Expected $expectedNames[$index]))) { return $false }
        }
        return $true
    }
    if ($Expected -is [Collections.IList]) {
        if ($Actual -isnot [Collections.IList] -or $Actual.Count -ne $Expected.Count) { return $false }
        for ($index = 0; $index -lt $Expected.Count; $index++) {
            if (-not (Test-CalibrationJsonExactValue -Actual $Actual[$index] -Expected $Expected[$index])) { return $false }
        }
        return $true
    }
    if ((Test-CalibrationJsonNumber $Expected) -and (Test-CalibrationJsonNumber $Actual)) {
        return [decimal]$Actual -eq [decimal]$Expected
    }
    if ($Expected -is [string]) { return $Actual -is [string] -and $Actual -ceq $Expected }
    if ($Expected -is [bool]) { return $Actual -is [bool] -and $Actual -eq $Expected }
    return $Actual -eq $Expected
}

function Invoke-CalibrationExactFieldsGrader {
    param([Parameter(Mandatory)][object]$Grader, [Parameter(Mandatory)][string]$ResponseText)
    $parsed = Get-CalibrationJsonPayload -ResponseText $ResponseText
    if (-not $parsed.valid) {
        return New-CalibrationGraderResult -Type 'exact_fields' -Outcome 'review_required' `
            -ReasonCode 'malformed_output' -Checks @(
                [pscustomobject]@{ id = 'parse'; kind = 'json_parse'; passed = $false; detail = 'not_one_unambiguous_json_value' }
            )
    }
    $schemaPassed = Test-CalibrationJsonSchemaValue -Value $parsed.value -Schema $Grader.schema
    $expectedPassed = $schemaPassed -and (Test-CalibrationJsonExactValue -Actual $parsed.value -Expected $Grader.expected)
    $checks = @(
        [pscustomobject]@{ id = 'parse'; kind = 'json_parse'; passed = $true; detail = 'one_unambiguous_json_value' }
        [pscustomobject]@{ id = 'schema'; kind = 'exact_schema'; passed = $schemaPassed; detail = if ($schemaPassed) { 'matched' } else { 'mismatch' } }
        [pscustomobject]@{ id = 'expected'; kind = 'exact_value'; passed = $expectedPassed; detail = if ($expectedPassed) { 'matched' } else { 'mismatch' } }
    )
    return New-CalibrationGraderResult -Type 'exact_fields' `
        -Outcome $(if ($schemaPassed -and $expectedPassed) { 'pass' } else { 'fail' }) `
        -ReasonCode $(if ($schemaPassed -and $expectedPassed) { $null } else { 'deterministic_check_failed' }) `
        -Checks $checks
}

function Invoke-CalibrationVerifiedAnswerGrader {
    param([Parameter(Mandatory)][object]$Grader, [Parameter(Mandatory)][string]$ResponseText)
    $responseKey = ConvertTo-CalibrationEvidenceKey $ResponseText
    $checks = [Collections.Generic.List[object]]::new()
    $expectedKey = ConvertTo-CalibrationEvidenceKey ([string]$Grader.expected_answer)
    $expectedPassed = -not [string]::IsNullOrWhiteSpace($expectedKey) -and $responseKey.Contains($expectedKey, [StringComparison]::Ordinal)
    $checks.Add([pscustomobject]@{ id = 'expected_answer'; kind = 'evidence_present'; passed = $expectedPassed; detail = if ($expectedPassed) { 'present' } else { 'missing' } })
    $index = 0
    foreach ($reasoning in @($Grader.required_reasoning)) {
        $key = ConvertTo-CalibrationEvidenceKey ([string]$reasoning)
        $passed = -not [string]::IsNullOrWhiteSpace($key) -and $responseKey.Contains($key, [StringComparison]::Ordinal)
        $checks.Add([pscustomobject]@{ id = "required_reasoning[$index]"; kind = 'evidence_present'; passed = $passed; detail = if ($passed) { 'present' } else { 'missing' } })
        $index++
    }
    $allPassed = @($checks | Where-Object { -not $_.passed }).Count -eq 0
    return New-CalibrationGraderResult -Type 'verified_answer' `
        -Outcome $(if ($allPassed) { 'pass' } else { 'fail' }) `
        -ReasonCode $(if ($allPassed) { $null } else { 'deterministic_check_failed' }) -Checks @($checks)
}

function Invoke-CalibrationSummaryChecksGrader {
    param([Parameter(Mandatory)][object]$Grader, [Parameter(Mandatory)][string]$ResponseText)
    $responseKey = ConvertTo-CalibrationEvidenceKey $ResponseText
    $checks = [Collections.Generic.List[object]]::new()
    $index = 0
    foreach ($fact in @($Grader.required_facts)) {
        $key = ConvertTo-CalibrationEvidenceKey ([string]$fact)
        $passed = -not [string]::IsNullOrWhiteSpace($key) -and $responseKey.Contains($key, [StringComparison]::Ordinal)
        $checks.Add([pscustomobject]@{ id = "required_fact[$index]"; kind = 'required_fact_present'; passed = $passed; detail = if ($passed) { 'present' } else { 'missing' } })
        $index++
    }
    $index = 0
    foreach ($claim in @($Grader.forbidden_claims)) {
        $key = ConvertTo-CalibrationEvidenceKey ([string]$claim)
        $passed = [string]::IsNullOrWhiteSpace($key) -or -not $responseKey.Contains($key, [StringComparison]::Ordinal)
        $checks.Add([pscustomobject]@{ id = "forbidden_claim[$index]"; kind = 'forbidden_claim_absent'; passed = $passed; detail = if ($passed) { 'absent' } else { 'present' } })
        $index++
    }
    $index = 0
    foreach ($omission in @($Grader.required_omissions)) {
        $key = ConvertTo-CalibrationEvidenceKey ([string]$omission)
        $passed = [string]::IsNullOrWhiteSpace($key) -or -not $responseKey.Contains($key, [StringComparison]::Ordinal)
        $checks.Add([pscustomobject]@{ id = "required_omission[$index]"; kind = 'required_omission_absent'; passed = $passed; detail = if ($passed) { 'absent' } else { 'present' } })
        $index++
    }
    $allPassed = @($checks | Where-Object { -not $_.passed }).Count -eq 0
    return New-CalibrationGraderResult -Type 'summary_checks' `
        -Outcome $(if ($allPassed) { 'pass' } else { 'fail' }) `
        -ReasonCode $(if ($allPassed) { $null } else { 'deterministic_check_failed' }) -Checks @($checks)
}

function Get-CalibrationPythonCode {
    param([Parameter(Mandatory)][string]$ResponseText, [Parameter(Mandatory)][string]$EntryPoint)
    $trimmed = $ResponseText.Trim()
    $match = [regex]::Match(
        $trimmed,
        '\A```(?:python|py)[ \t]*\r?\n(?<code>[\s\S]*?)\r?\n```\z',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    $code = if ($match.Success -and $match.Groups['code'].Value -notmatch '```') {
        $match.Groups['code'].Value.Trim()
    } elseif (-not $match.Success -and $trimmed -notmatch '```' -and
        $trimmed -match ('(?m)^\s*def\s+{0}\s*\(' -f [regex]::Escape($EntryPoint))) { $trimmed } else { $null }
    if ([string]::IsNullOrWhiteSpace($code) -or
        @([regex]::Matches($code, ('(?m)^\s*def\s+{0}\s*\(' -f [regex]::Escape($EntryPoint)))).Count -ne 1) {
        return [pscustomobject]@{ valid = $false; code = $null }
    }
    return [pscustomobject]@{ valid = $true; code = $code }
}

function Invoke-CalibrationPythonProcess {
    param(
        [Parameter(Mandatory)][string]$ExtractedCode,
        [Parameter(Mandatory)][object]$Grader,
        [AllowNull()][string]$PythonExecutable,
        [ValidateRange(100, 10000)][int]$TimeoutMilliseconds = 2000
    )
    $resolvedPython = Resolve-RouterPythonExecutable -PythonExecutable $PythonExecutable
    if ($null -eq $resolvedPython) { return [pscustomobject]@{ status = 'unavailable'; checks = @() } }
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('router-calibration-python-{0}' -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    try {
        $candidatePath = Join-Path $temporaryRoot 'candidate.py'
        $testsPath = Join-Path $temporaryRoot 'tests.json'
        $harnessPath = Join-Path $temporaryRoot 'harness.py'
        Set-Content -LiteralPath $candidatePath -Value $ExtractedCode -Encoding utf8NoBOM
        [pscustomobject]@{ tests = @($Grader.tests) } | ConvertTo-Json -Depth 100 -Compress |
            Set-Content -LiteralPath $testsPath -Encoding utf8NoBOM
        @'
import ast
import json
import sys

candidate_path, tests_path, entry_point = sys.argv[1:4]
result = {"status": "error", "checks": []}
try:
    source = open(candidate_path, "r", encoding="utf-8").read()
    tree = ast.parse(source, filename="candidate.py", mode="exec")
    allowed_top = [node for node in tree.body if isinstance(node, (ast.FunctionDef, ast.Expr))]
    functions = [node for node in tree.body if isinstance(node, ast.FunctionDef)]
    if len(allowed_top) != len(tree.body) or len(functions) != 1 or functions[0].name != entry_point:
        raise ValueError("unsafe_shape")
    allowed_names = {"abs", "all", "any", "bool", "dict", "enumerate", "float", "int", "len", "list", "max", "min", "range", "reversed", "set", "sorted", "str", "sum", "tuple", "ValueError", entry_point}
    allowed_methods = {"add", "append", "copy", "discard", "get", "items", "keys", "pop", "remove", "reverse", "setdefault", "sort", "values"}
    for node in ast.walk(tree):
        if isinstance(node, (ast.Import, ast.ImportFrom, ast.ClassDef, ast.AsyncFunctionDef, ast.Global, ast.Nonlocal)):
            raise ValueError("unsafe_syntax")
        if isinstance(node, ast.Name) and node.id.startswith("__"):
            raise ValueError("unsafe_name")
        if isinstance(node, ast.Attribute) and (node.attr.startswith("__") or node.attr not in allowed_methods):
            raise ValueError("unsafe_attribute")
        if isinstance(node, ast.Call):
            if isinstance(node.func, ast.Name) and node.func.id not in allowed_names:
                raise ValueError("unsafe_call")
            if not isinstance(node.func, (ast.Name, ast.Attribute)):
                raise ValueError("unsafe_call")
    safe_builtins = {name: getattr(__builtins__, name) for name in allowed_names if name != entry_point and hasattr(__builtins__, name)}
    namespace = {"__builtins__": safe_builtins}
    exec(compile(tree, "candidate.py", "exec"), namespace, namespace)
    function = namespace[entry_point]
    tests = json.load(open(tests_path, "r", encoding="utf-8"))["tests"]
    checks = []
    for index, test in enumerate(tests):
        passed = False
        detail = "mismatch"
        try:
            value = function(*test.get("arguments", []))
            if "expected_error" in test:
                detail = "missing_expected_error"
            else:
                passed = value == test.get("expected")
                detail = "matched" if passed else "mismatch"
        except Exception as error:
            if test.get("expected_error") == type(error).__name__:
                passed = True
                detail = "expected_error"
            else:
                detail = "unexpected_error"
        checks.append({"id": f"test[{index}]", "passed": passed, "detail": detail})
    result = {"status": "completed", "checks": checks}
except Exception:
    result = {"status": "error", "checks": []}
print(json.dumps(result, separators=(",", ":")))
'@ | Set-Content -LiteralPath $harnessPath -Encoding utf8NoBOM

        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $resolvedPython
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.WorkingDirectory = $temporaryRoot
        $startInfo.ArgumentList.Add('-I')
        $startInfo.ArgumentList.Add('-S')
        $startInfo.ArgumentList.Add($harnessPath)
        $startInfo.ArgumentList.Add($candidatePath)
        $startInfo.ArgumentList.Add($testsPath)
        $startInfo.ArgumentList.Add([string]$Grader.entry_point)
        $startInfo.Environment.Clear()
        $startInfo.Environment['PYTHONIOENCODING'] = 'utf-8'
        $startInfo.Environment['PYTHONDONTWRITEBYTECODE'] = '1'
        foreach ($name in @('SystemRoot', 'WINDIR')) {
            $value = [Environment]::GetEnvironmentVariable($name)
            if (-not [string]::IsNullOrWhiteSpace($value)) { $startInfo.Environment[$name] = $value }
        }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        try {
            if (-not $process.Start()) { return [pscustomobject]@{ status = 'error'; checks = @() } }
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit($TimeoutMilliseconds)) {
                try { $process.Kill($true) } catch { }
                $process.WaitForExit()
                $null = $stdoutTask.GetAwaiter().GetResult()
                $null = $stderrTask.GetAwaiter().GetResult()
                return [pscustomobject]@{ status = 'timeout'; checks = @() }
            }
            $stdout = $stdoutTask.GetAwaiter().GetResult()
            $null = $stderrTask.GetAwaiter().GetResult()
            if ($process.ExitCode -ne 0) { return [pscustomobject]@{ status = 'error'; checks = @() } }
            try {
                $result = $stdout | ConvertFrom-Json -Depth 20 -ErrorAction Stop
                if ($result.status -cnotin @('completed', 'error') -or $result.checks -isnot [Collections.IList]) { throw 'invalid result' }
                return $result
            } catch { return [pscustomobject]@{ status = 'error'; checks = @() } }
        } finally {
            $process.Dispose()
        }
    } catch {
        return [pscustomobject]@{ status = 'error'; checks = @() }
    } finally {
        if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
    }
}

function Invoke-CalibrationExecutableTestsGrader {
    param(
        [Parameter(Mandatory)][object]$Grader,
        [Parameter(Mandatory)][string]$ResponseText,
        [scriptblock]$PythonExecutor,
        [AllowNull()][string]$PythonExecutable,
        [ValidateRange(100, 10000)][int]$TimeoutMilliseconds = 2000
    )
    $extracted = Get-CalibrationPythonCode -ResponseText $ResponseText -EntryPoint ([string]$Grader.entry_point)
    if (-not $extracted.valid) {
        return New-CalibrationGraderResult -Type 'executable_tests' -Outcome 'review_required' `
            -ReasonCode 'malformed_output' -Checks @()
    }
    $execution = if ($null -ne $PythonExecutor) {
        & $PythonExecutor $extracted.code $Grader $PythonExecutable $TimeoutMilliseconds
    } else {
        Invoke-CalibrationPythonProcess -ExtractedCode $extracted.code -Grader $Grader `
            -PythonExecutable $PythonExecutable -TimeoutMilliseconds $TimeoutMilliseconds
    }
    if ($null -eq $execution -or $execution.status -cnotin @('completed', 'timeout', 'unavailable', 'error') -or
        $execution.checks -isnot [Collections.IList]) {
        return New-CalibrationGraderResult -Type 'executable_tests' -Outcome 'review_required' `
            -ReasonCode 'execution_error' -Checks @()
    }
    if ($execution.status -cne 'completed') {
        $reasonCode = switch ([string]$execution.status) {
            'timeout' { 'timeout' }
            'unavailable' { 'python_unavailable' }
            default { 'execution_error' }
        }
        return New-CalibrationGraderResult -Type 'executable_tests' -Outcome 'review_required' `
            -ReasonCode $reasonCode -Checks @($execution.checks)
    }
    $checks = @($execution.checks | ForEach-Object {
        [pscustomobject]@{
            id = [string]$_.id
            kind = 'executable_test'
            passed = $_.passed -is [bool] -and $_.passed
            detail = if ($_.detail -cin @('matched', 'mismatch', 'expected_error', 'missing_expected_error', 'unexpected_error')) { [string]$_.detail } else { 'invalid_result' }
        }
    })
    if ($checks.Count -ne @($Grader.tests).Count) {
        return New-CalibrationGraderResult -Type 'executable_tests' -Outcome 'review_required' `
            -ReasonCode 'execution_error' -Checks $checks
    }
    $allPassed = @($checks | Where-Object { -not $_.passed }).Count -eq 0
    return New-CalibrationGraderResult -Type 'executable_tests' `
        -Outcome $(if ($allPassed) { 'pass' } else { 'fail' }) `
        -ReasonCode $(if ($allPassed) { $null } else { 'deterministic_check_failed' }) -Checks $checks
}

function Invoke-CalibrationDeterministicGrader {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Prompt,
        [Parameter(Mandatory)][string]$ResponseText,
        [scriptblock]$PythonExecutor,
        [AllowNull()][string]$PythonExecutable,
        [ValidateRange(100, 10000)][int]$PythonTimeoutMilliseconds = 2000
    )
    if ($Prompt.grading.PSObject.Properties.Name -cnotcontains 'deterministic_grader' -or
        $null -eq $Prompt.grading.deterministic_grader) { return $null }
    $grader = $Prompt.grading.deterministic_grader
    switch ([string]$grader.type) {
        'exact_fields' { return Invoke-CalibrationExactFieldsGrader -Grader $grader -ResponseText $ResponseText }
        'verified_answer' { return Invoke-CalibrationVerifiedAnswerGrader -Grader $grader -ResponseText $ResponseText }
        'summary_checks' { return Invoke-CalibrationSummaryChecksGrader -Grader $grader -ResponseText $ResponseText }
        'executable_tests' {
            return Invoke-CalibrationExecutableTestsGrader -Grader $grader -ResponseText $ResponseText `
                -PythonExecutor $PythonExecutor -PythonExecutable $PythonExecutable `
                -TimeoutMilliseconds $PythonTimeoutMilliseconds
        }
        default {
            return New-CalibrationGraderResult -Type ([string]$grader.type) -Outcome 'review_required' `
                -ReasonCode 'unsupported_grader' -Checks @()
        }
    }
}
