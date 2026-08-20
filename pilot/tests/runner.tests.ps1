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

Invoke-Assertion 'New-CandidateCommand constructs a boundary-preserving Codex command' {
    $candidate = [pscustomobject]@{ route_id = 'codex__gpt_5_6_sol__xhigh'; tool = 'codex'; model = 'gpt-5.6-sol'; effort = 'xhigh' }
    $command = New-CandidateCommand -Candidate $candidate -Prompt 'quoted prompt "with spaces"'

    Assert-Equal $command.executable 'codex'
    Assert-Equal $command.tool 'codex'
    Assert-Equal $command.route_id $candidate.route_id
    Assert-Equal $command.prompt 'quoted prompt "with spaces"'
    Assert-Equal $command.working_directory $projectRoot
    Assert-SequenceEqual $command.arguments @('exec', '--skip-git-repo-check', '--ephemeral', '--json', '-s', 'read-only', '--model', 'gpt-5.6-sol', '-c', 'model_reasoning_effort="xhigh"', 'quoted prompt "with spaces"')
}

Invoke-Assertion 'New-CandidateCommand constructs native Claude commands and omits Haiku effort' {
    $candidate = [pscustomobject]@{ route_id = 'claude__claude_sonnet_4_6__medium'; tool = 'claude'; model = 'claude-sonnet-4-6'; effort = 'medium' }
    $command = New-CandidateCommand -Candidate $candidate -Prompt 'hello'
    Assert-SequenceEqual $command.arguments @('-p', '--model', 'claude-sonnet-4-6', '--effort', 'medium', '--output-format', 'json', '--max-turns', '1', '--no-session-persistence', '--disable-slash-commands', '--tools', '', 'hello')

    $haiku = [pscustomobject]@{ route_id = 'claude__claude_haiku_4_5__default'; tool = 'claude'; model = 'claude-haiku-4-5'; effort = 'medium' }
    $haikuCommand = New-CandidateCommand -Candidate $haiku -Prompt 'haiku prompt'
    Assert-SequenceEqual $haikuCommand.arguments @('-p', '--model', 'claude-haiku-4-5', '--output-format', 'json', '--max-turns', '1', '--no-session-persistence', '--disable-slash-commands', '--tools', '', 'haiku prompt')
}

Invoke-Assertion 'New-CandidateCommand constructs an Agy command with repository-relative schema path' {
    $candidate = [pscustomobject]@{ route_id = 'agy__gemini_3_7_flash_high__high'; tool = 'agy'; model = 'gemini-3.7-flash-high'; effort = 'high' }
    $command = New-CandidateCommand -Candidate $candidate -Prompt 'agy prompt'

    Assert-Equal $command.executable 'agy'
    Assert-SequenceEqual $command.arguments @('-p', 'agy prompt', '--output-format', 'json', '--json-schema', 'pilot/shared/response_schema.json', '--model', 'gemini-3.7-flash-high', '--effort', 'high', '--print-timeout', '2m', '--disable-slash-commands')
}

Invoke-Assertion 'New-CandidateCommand rejects blank effort for effort-required candidates' {
    $claude = [pscustomobject]@{ route_id = 'claude__claude_sonnet_4_6__default'; tool = 'claude'; model = 'claude-sonnet-4-6'; effort = '' }
    $agy = [pscustomobject]@{ route_id = 'agy__gemini_3_7_flash_high__default'; tool = 'agy'; model = 'gemini-3.7-flash-high'; effort = '' }
    Assert-Throws { New-CandidateCommand -Candidate $claude -Prompt 'invalid' }
    Assert-Throws { New-CandidateCommand -Candidate $agy -Prompt 'invalid' }
    $codex = [pscustomobject]@{ route_id = 'codex__gpt_5_6_sol__default'; tool = 'codex'; model = 'gpt-5.6-sol'; effort = '' }
    $codexCommand = New-CandidateCommand -Candidate $codex -Prompt 'codex without effort'
    Assert-SequenceEqual $codexCommand.arguments @('exec', '--skip-git-repo-check', '--ephemeral', '--json', '-s', 'read-only', '--model', 'gpt-5.6-sol', 'codex without effort')
}

Invoke-Assertion 'Invoke-NativeCandidate captures stdout stderr exit code and duration' {
    $command = [pscustomobject]@{
        executable = 'pwsh'
        arguments = @('-NoProfile', '-Command', "Write-Output 'ok'; [Console]::Error.WriteLine('warn')")
        prompt = 'capture prompt'
        tool = 'test'
        route_id = 'test__capture'
        working_directory = $projectRoot
    }
    $result = Invoke-NativeCandidate -Command $command -TimeoutSeconds 10
    Assert-Equal $result.exit_code 0
    Assert-Contains $result.stdout 'ok'
    Assert-Contains $result.stderr 'warn'
    Assert-True ($result.duration_ms -ge 0)
    Assert-True (-not $result.timed_out)
    Assert-SequenceEqual $result.arguments $command.arguments
}

Invoke-Assertion 'Invoke-NativeCandidate decodes Unicode output before redaction' {
    $sensitivePrompt = 'Café ΔPrOmPt 😀'
    $childScript = "[Console]::OutputEncoding = [Text.UTF8Encoding]::new(); Write-Output '$sensitivePrompt'; [Console]::Error.WriteLine('$sensitivePrompt')"
    $command = [pscustomobject]@{
        executable = 'pwsh'
        arguments = @('-NoProfile', '-Command', $childScript)
        prompt = $sensitivePrompt
        tool = 'test'
        route_id = 'test__unicode_encoding_redaction'
        working_directory = $projectRoot
    }
    $result = Invoke-NativeCandidate -Command $command -TimeoutSeconds 10
    $metadata = $result | ConvertTo-Json -Depth 10
    Assert-True (-not $result.stdout.Contains($sensitivePrompt))
    Assert-True (-not $result.stderr.Contains($sensitivePrompt))
    Assert-True (-not $metadata.Contains($sensitivePrompt))
    Assert-True (-not $result.stdout.Contains([char]0xFFFD))
    Assert-True (-not $result.stderr.Contains([char]0xFFFD))
    Assert-True (-not $metadata.Contains([char]0xFFFD))
    Assert-Contains $result.stdout '[prompt redacted]'
    Assert-Contains $result.stderr '[prompt redacted]'
}

Invoke-Assertion 'Invoke-NativeCandidate redacts prompt content from returned metadata' {
    $sensitivePrompt = 'sensitive prompt text must not leak'
    $command = [pscustomobject]@{
        executable = 'pwsh'
        arguments = @('-NoProfile', '-Command', "Write-Output 'ok'; [Console]::Error.WriteLine('warn')", $sensitivePrompt)
        prompt = $sensitivePrompt
        tool = 'test'
        route_id = 'test__redaction'
        working_directory = $projectRoot
    }
    $result = Invoke-NativeCandidate -Command $command -TimeoutSeconds 10
    $metadata = $result | ConvertTo-Json -Depth 10
    Assert-True (-not $metadata.Contains($sensitivePrompt))
    Assert-True (-not $result.stdout.Contains($sensitivePrompt))
    Assert-True (-not $result.stderr.Contains($sensitivePrompt))
    Assert-Contains ($result.arguments -join '|') '[prompt redacted]'
}

Invoke-Assertion 'Invoke-NativeCandidate redacts prompt echoes from both output streams' {
    $sensitivePrompt = 'echoed sensitive prompt must be redacted'
    $command = [pscustomobject]@{
        executable = 'pwsh'
        arguments = @('-NoProfile', '-Command', "Write-Output '$sensitivePrompt'; [Console]::Error.WriteLine('$sensitivePrompt')")
        prompt = $sensitivePrompt
        tool = 'test'
        route_id = 'test__echo_redaction'
        working_directory = $projectRoot
    }
    $result = Invoke-NativeCandidate -Command $command -TimeoutSeconds 10
    Assert-True (-not $result.stdout.Contains($sensitivePrompt))
    Assert-True (-not $result.stderr.Contains($sensitivePrompt))
    Assert-Contains $result.stdout '[prompt redacted]'
    Assert-Contains $result.stderr '[prompt redacted]'
}

Invoke-Assertion 'Invoke-NativeCandidate redacts CRLF prompts from LF-normalized output' {
    $sensitivePrompt = "line one`r`nline two"
    $command = [pscustomobject]@{
        executable = 'pwsh'
        arguments = @('-NoProfile', '-Command', "[Console]::Out.Write('line one' + [char]10 + 'line two'); [Console]::Error.Write('line one' + [char]10 + 'line two')")
        prompt = $sensitivePrompt
        tool = 'test'
        route_id = 'test__line_ending_redaction'
        working_directory = $projectRoot
    }
    $result = Invoke-NativeCandidate -Command $command -TimeoutSeconds 10
    $normalizedPrompt = "line one`nline two"
    Assert-True (-not $result.stdout.Contains($normalizedPrompt))
    Assert-True (-not $result.stderr.Contains($normalizedPrompt))
    Assert-Contains $result.stdout '[prompt redacted]'
    Assert-Contains $result.stderr '[prompt redacted]'
}

Invoke-Assertion 'Invoke-NativeCandidate redacts JSON-escaped multiline prompt echoes' {
    $sensitivePrompt = "line one`r`nquoted `"value`" and path C:\tmp"
    $escapedPrompt = $sensitivePrompt | ConvertTo-Json -Compress
    $command = [pscustomobject]@{
        executable = 'pwsh'
        arguments = @('-NoProfile', '-Command', "[Console]::Out.Write('$escapedPrompt'); [Console]::Error.Write('$escapedPrompt')")
        prompt = $sensitivePrompt
        tool = 'test'
        route_id = 'test__json_escaped_redaction'
        working_directory = $projectRoot
    }
    $result = Invoke-NativeCandidate -Command $command -TimeoutSeconds 10
    Assert-True (-not $result.stdout.Contains($sensitivePrompt))
    Assert-True (-not $result.stderr.Contains($sensitivePrompt))
    Assert-True (-not $result.stdout.Contains($escapedPrompt))
    Assert-True (-not $result.stderr.Contains($escapedPrompt))
    Assert-Contains $result.stdout '[prompt redacted]'
    Assert-Contains $result.stderr '[prompt redacted]'
}

Invoke-Assertion 'Invoke-NativeCandidate redacts JSON escaped content without outer quotes' {
    $sensitivePrompt = "inner line one`r`ninner `"quoted`" line"
    $escapedPrompt = $sensitivePrompt | ConvertTo-Json -Compress
    $escapedContent = $escapedPrompt.Substring(1, $escapedPrompt.Length - 2)
    $command = [pscustomobject]@{
        executable = 'pwsh'
        arguments = @('-NoProfile', '-Command', "[Console]::Out.Write('$escapedContent'); [Console]::Error.Write('$escapedContent')")
        prompt = $sensitivePrompt
        tool = 'test'
        route_id = 'test__json_inner_redaction'
        working_directory = $projectRoot
    }
    $result = Invoke-NativeCandidate -Command $command -TimeoutSeconds 10
    $metadata = $result | ConvertTo-Json -Depth 10
    Assert-True (-not $result.stdout.Contains($escapedContent))
    Assert-True (-not $result.stderr.Contains($escapedContent))
    Assert-True (-not $metadata.Contains($escapedContent))
    Assert-Contains $result.stdout '[prompt redacted]'
    Assert-Contains $result.stderr '[prompt redacted]'
}

Invoke-Assertion 'Invoke-NativeCandidate redacts slash and Unicode JSON prompt variants everywhere' {
    $sensitivePrompt = 'slash / and café'
    $jsonPrompt = $sensitivePrompt | ConvertTo-Json -Compress
    $jsonContent = $jsonPrompt.Substring(1, $jsonPrompt.Length - 2)
    $slashContent = $jsonContent.Replace('/', '\/')
    $unicodeContent = $jsonContent.Replace('é', '\u00E9')
    $command = [pscustomobject]@{
        executable = 'pwsh'
        arguments = @('-NoProfile', '-Command', "[Console]::Out.Write('$slashContent|$unicodeContent'); [Console]::Error.Write('$slashContent|$unicodeContent')")
        prompt = $sensitivePrompt
        tool = 'test'
        route_id = 'test__json_variant_redaction'
        working_directory = $projectRoot
    }
    $result = Invoke-NativeCandidate -Command $command -TimeoutSeconds 10
    $metadata = $result | ConvertTo-Json -Depth 10
    Assert-Equal $result.exit_code 0
    foreach ($value in @($sensitivePrompt, $slashContent, $unicodeContent)) {
        Assert-True (-not $result.stdout.Contains($value))
        Assert-True (-not $result.stderr.Contains($value))
        Assert-True (-not $metadata.Contains($value))
    }
    Assert-Contains $result.stdout '[prompt redacted]'
    Assert-Contains $result.stderr '[prompt redacted]'
    Assert-Contains ($result.arguments -join '|') '[prompt redacted]'
}

Invoke-Assertion 'Invoke-NativeCandidate redacts mixed raw and Unicode JSON escapes everywhere' {
    $sensitivePrompt = 'alpha / beta'
    $mixedEscape = 'alpha \u002F beta'
    $childScript = "[Console]::Out.Write('$mixedEscape'); [Console]::Error.Write('$mixedEscape')"
    $command = [pscustomobject]@{
        executable = 'pwsh'
        arguments = @('-NoProfile', '-Command', $childScript)
        prompt = $sensitivePrompt
        tool = 'test'
        route_id = 'test__mixed_json_redaction'
        working_directory = $projectRoot
    }
    $result = Invoke-NativeCandidate -Command $command -TimeoutSeconds 10
    $metadata = $result | ConvertTo-Json -Depth 10
    foreach ($value in @($mixedEscape, $sensitivePrompt)) {
        Assert-True (-not $result.stdout.Contains($value))
        Assert-True (-not $result.stderr.Contains($value))
        Assert-True (-not $metadata.Contains($value))
    }
    Assert-Contains $result.stdout '[prompt redacted]'
    Assert-Contains $result.stderr '[prompt redacted]'
    Assert-Contains ($result.arguments -join '|') '[prompt redacted]'
}

Invoke-Assertion 'Invoke-NativeCandidate redacts mixed CRLF Unicode escapes everywhere' {
    $sensitivePrompt = "lineA`r`nlineB"
    $mixedEscape = "lineA\u000D`nlineB"
    $childScript = "[Console]::Out.Write('$mixedEscape'); [Console]::Error.Write('$mixedEscape')"
    $command = [pscustomobject]@{
        executable = 'pwsh'
        arguments = @('-NoProfile', '-Command', $childScript)
        prompt = $sensitivePrompt
        tool = 'test'
        route_id = 'test__mixed_crlf_redaction'
        working_directory = $projectRoot
    }
    $result = Invoke-NativeCandidate -Command $command -TimeoutSeconds 10
    $metadata = $result | ConvertTo-Json -Depth 10
    foreach ($value in @($mixedEscape, $sensitivePrompt, "lineA`nlineB")) {
        Assert-True (-not $result.stdout.Contains($value))
        Assert-True (-not $result.stderr.Contains($value))
        Assert-True (-not $metadata.Contains($value))
    }
    Assert-Contains $result.stdout '[prompt redacted]'
    Assert-Contains $result.stderr '[prompt redacted]'
    Assert-Contains ($result.arguments -join '|') '[prompt redacted]'
}

Invoke-Assertion 'Invoke-NativeCandidate redacts arbitrary mixed newline and surrogate escapes' {
    $cases = @(
        [pscustomobject]@{ prompt = "lineA`r`nlineB"; emitted = "lineA`r\u000AlineB"; name = 'raw CR and Unicode LF' }
        [pscustomobject]@{ prompt = "lineA`r`nlineB"; emitted = 'lineA\u000D\u000AlineB'; name = 'Unicode CR and Unicode LF' }
        [pscustomobject]@{ prompt = 'AS😀'; emitted = '\u0041S\uD83d\uDe00'; name = 'mixed-case surrogate escapes' }
        [pscustomobject]@{ prompt = 'alpha / beta'; emitted = 'a\u006Cp\u0068a / b\u0065ta'; name = 'mixed literal and Unicode characters' }
    )
    foreach ($case in $cases) {
        $childScript = "[Console]::Out.Write('$($case.emitted)'); [Console]::Error.Write('$($case.emitted)')"
        $command = [pscustomobject]@{
            executable = 'pwsh'
            arguments = @('-NoProfile', '-Command', $childScript)
            prompt = $case.prompt
            tool = 'test'
            route_id = 'test__arbitrary_' + ($case.name -replace '[^A-Za-z0-9]', '_')
            working_directory = $projectRoot
        }
        $result = Invoke-NativeCandidate -Command $command -TimeoutSeconds 10
        $metadata = $result | ConvertTo-Json -Depth 10
        Assert-True (-not $result.stdout.Contains($case.emitted))
        Assert-True (-not $result.stderr.Contains($case.emitted))
        Assert-True (-not $metadata.Contains($case.emitted))
        Assert-Contains $result.stdout '[prompt redacted]'
        Assert-Contains $result.stderr '[prompt redacted]'
        Assert-Contains ($result.arguments -join '|') '[prompt redacted]'
    }
}

Invoke-Assertion 'Invoke-NativeCandidate redacts raw prompt case-insensitively everywhere' {
    $sensitivePrompt = 'CaseSensitive'
    $emitted = 'cAsEsEnSiTiVe'
    $childScript = "[Console]::Out.Write('$emitted'); [Console]::Error.Write('$emitted')"
    $command = [pscustomobject]@{
        executable = 'pwsh'
        arguments = @('-NoProfile', '-Command', $childScript)
        prompt = $sensitivePrompt
        tool = 'test'
        route_id = 'test__case_insensitive_redaction'
        working_directory = $projectRoot
    }
    $result = Invoke-NativeCandidate -Command $command -TimeoutSeconds 10
    $metadata = $result | ConvertTo-Json -Depth 10
    foreach ($value in @($emitted, $sensitivePrompt)) {
        Assert-True (-not $result.stdout.Contains($value))
        Assert-True (-not $result.stderr.Contains($value))
        Assert-True (-not $metadata.Contains($value))
    }
    Assert-Contains $result.stdout '[prompt redacted]'
    Assert-Contains $result.stderr '[prompt redacted]'
    Assert-Contains ($result.arguments -join '|') '[prompt redacted]'
}

Invoke-Assertion 'Invoke-NativeCandidate redacts fully Unicode escaped prompt variants including surrogate pairs' {
    $sensitivePrompt = 'AS😀'
    $fullyEscaped = '\u0041\u0053\uD83D\uDE00'
    $command = [pscustomobject]@{
        executable = 'pwsh'
        arguments = @('-NoProfile', '-Command', "[Console]::Out.Write('$fullyEscaped'); [Console]::Error.Write('$fullyEscaped'); Write-Output '$fullyEscaped'")
        prompt = $sensitivePrompt
        tool = 'test'
        route_id = 'test__fully_unicode_redaction'
        working_directory = $projectRoot
    }
    $result = Invoke-NativeCandidate -Command $command -TimeoutSeconds 10
    foreach ($property in $result.PSObject.Properties) {
        Assert-True (-not ([string]$property.Value).Contains($fullyEscaped))
    }
    Assert-Contains $result.stdout '[prompt redacted]'
    Assert-Contains $result.stderr '[prompt redacted]'
}

Invoke-Assertion 'Invoke-NativeCandidate redacts prompt content from every string metadata field' {
    $command = [pscustomobject]@{
        executable = 'pwsh'
        arguments = @('-NoProfile', '-Command', "Write-Output 'safe'; [Console]::Error.WriteLine('safe')")
        prompt = 'pwsh'
        tool = 'test'
        route_id = 'test__executable_prompt'
        working_directory = $projectRoot
    }
    $result = Invoke-NativeCandidate -Command $command -TimeoutSeconds 10
    foreach ($property in $result.PSObject.Properties) {
        Assert-True (-not ([string]$property.Value).Contains('pwsh'))
    }
    Assert-Contains $result.executable '[prompt redacted]'
}

Invoke-Assertion 'Invoke-NativeCandidate redacts echoes from a constructed command' {
    $sensitivePrompt = "constructed line one`r`nquoted `"value`" and path C:\tmp"
    $candidate = [pscustomobject]@{ route_id = 'codex__gpt_5_6_sol__medium'; tool = 'codex'; model = 'gpt-5.6-sol'; effort = 'medium' }
    $command = New-CandidateCommand -Candidate $candidate -Prompt $sensitivePrompt
    $escapedPrompt = $sensitivePrompt | ConvertTo-Json -Compress
    $command.executable = 'pwsh'
    $command.arguments = @('-NoProfile', '-Command', "[Console]::Out.Write('constructed line one' + [char]13 + [char]10 + 'quoted `"value`" and path C:\tmp|$escapedPrompt'); [Console]::Error.Write('constructed line one' + [char]10 + 'quoted `"value`" and path C:\tmp|$escapedPrompt')")

    $result = Invoke-NativeCandidate -Command $command -TimeoutSeconds 10
    $normalizedPrompt = $sensitivePrompt -replace "`r`n", "`n"
    Assert-True (-not $result.stdout.Contains($sensitivePrompt))
    Assert-True (-not $result.stderr.Contains($sensitivePrompt))
    Assert-True (-not $result.stdout.Contains($normalizedPrompt))
    Assert-True (-not $result.stderr.Contains($normalizedPrompt))
    Assert-True (-not $result.stdout.Contains($escapedPrompt))
    Assert-True (-not $result.stderr.Contains($escapedPrompt))
    Assert-Contains $result.stdout '[prompt redacted]'
    Assert-Contains $result.stderr '[prompt redacted]'
}

Invoke-Assertion 'Invoke-NativeCandidate terminates a timed out process without throwing' {
    $command = [pscustomobject]@{
        executable = 'pwsh'
        arguments = @('-NoProfile', '-Command', '$child = Start-Process -FilePath ''pwsh'' -ArgumentList @(''-NoProfile'', ''-Command'', ''Start-Sleep -Seconds 30'') -PassThru; Write-Output (''CHILD_PID='' + $child.Id); Start-Sleep -Seconds 30')
        prompt = ''
        tool = 'test'
        route_id = 'test__timeout'
        working_directory = $projectRoot
    }
    $result = Invoke-NativeCandidate -Command $command -TimeoutSeconds 1
    Assert-True $result.timed_out
    Assert-True ($result.duration_ms -ge 0)
    Assert-True ($result.duration_ms -lt 5000)
    Assert-True ($result.PSObject.Properties.Name -contains 'cleanup_failed')
    Assert-True ($result.PSObject.Properties.Name -contains 'cleanup_status')
    Assert-True (-not $result.cleanup_failed)
    Assert-Equal $result.cleanup_status 'timeout_cleanup_complete'
    Assert-True $result.process_exited
    Assert-True ($result.process_id -gt 0)
    Assert-True ($null -eq (Get-Process -Id $result.process_id -ErrorAction SilentlyContinue))
    $childPidMatch = [regex]::Match($result.stdout, 'CHILD_PID=(\d+)')
    Assert-True $childPidMatch.Success
    Assert-True ($null -eq (Get-Process -Id ([int]$childPidMatch.Groups[1].Value) -ErrorAction SilentlyContinue))
}

Invoke-Assertion 'Invoke-NativeCandidate drains output after parent exits with descendant-held pipes' {
    $parentScript = '$childInfo = [System.Diagnostics.ProcessStartInfo]::new(); $childInfo.FileName = ''pwsh''; $childInfo.UseShellExecute = $false; $childInfo.CreateNoWindow = $true; [void]$childInfo.ArgumentList.Add(''-NoProfile''); [void]$childInfo.ArgumentList.Add(''-Command''); [void]$childInfo.ArgumentList.Add(''Start-Sleep -Seconds 2''); $child = [System.Diagnostics.Process]::new(); $child.StartInfo = $childInfo; [void]$child.Start(); Write-Output (''CHILD_PID='' + $child.Id); [Console]::Error.WriteLine(''parent warning retained'')'
    $command = [pscustomobject]@{
        executable = 'pwsh'
        arguments = @('-NoProfile', '-Command', $parentScript)
        prompt = ''
        tool = 'test'
        route_id = 'test__parent_exit_drain'
        working_directory = $projectRoot
    }
    $result = Invoke-NativeCandidate -Command $command -TimeoutSeconds 5
    Assert-Contains $result.stdout 'CHILD_PID='
    Assert-Contains $result.stderr 'parent warning retained'
    Assert-True (-not $result.cleanup_failed)
    Assert-True $result.process_exited
    Assert-True ($result.duration_ms -ge 1000)
    $childPidMatch = [regex]::Match($result.stdout, 'CHILD_PID=(\d+)')
    Assert-True $childPidMatch.Success
    Assert-True ($null -eq (Get-Process -Id ([int]$childPidMatch.Groups[1].Value) -ErrorAction SilentlyContinue))
}

Invoke-Assertion 'Invoke-NativeCandidate preserves parent output when a descendant exceeds drain timeout' {
    $childPid = $null
    try {
        $parentScript = '$childInfo = [System.Diagnostics.ProcessStartInfo]::new(); $childInfo.FileName = ''pwsh''; $childInfo.UseShellExecute = $false; $childInfo.CreateNoWindow = $true; [void]$childInfo.ArgumentList.Add(''-NoProfile''); [void]$childInfo.ArgumentList.Add(''-Command''); [void]$childInfo.ArgumentList.Add(''Start-Sleep -Seconds 30''); $child = [System.Diagnostics.Process]::new(); $child.StartInfo = $childInfo; [void]$child.Start(); Write-Output (''LONG_CHILD_PID='' + $child.Id); Write-Output ''parent output retained''; [Console]::Error.WriteLine(''parent warning retained'')'
        $command = [pscustomobject]@{
            executable = 'pwsh'
            arguments = @('-NoProfile', '-Command', $parentScript)
            prompt = ''
            tool = 'test'
            route_id = 'test__parent_drain_timeout'
            working_directory = $projectRoot
        }
        $result = Invoke-NativeCandidate -Command $command -TimeoutSeconds 1
        Assert-Contains $result.stdout 'parent output retained'
        Assert-Contains $result.stderr 'parent warning retained'
        Assert-True $result.cleanup_failed
        Assert-Equal $result.cleanup_status 'output_drain_timeout'
        $childPidMatch = [regex]::Match($result.stdout, 'LONG_CHILD_PID=(\d+)')
        Assert-True $childPidMatch.Success
        $childPid = [int]$childPidMatch.Groups[1].Value
    } finally {
        if ($null -ne $childPid) {
            $child = Get-Process -Id $childPid -ErrorAction SilentlyContinue
            if ($null -ne $child) { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue }
        }
    }
}

Invoke-Assertion 'Invoke-NativeCandidate preserves partial stdout and stderr with inherited pipes' {
    $childPid = $null
    try {
        $parentScript = '$childInfo = [System.Diagnostics.ProcessStartInfo]::new(); $childInfo.FileName = ''pwsh''; $childInfo.UseShellExecute = $false; $childInfo.CreateNoWindow = $true; [void]$childInfo.ArgumentList.Add(''-NoProfile''); [void]$childInfo.ArgumentList.Add(''-Command''); [void]$childInfo.ArgumentList.Add(''Start-Sleep -Seconds 30''); $child = [System.Diagnostics.Process]::new(); $child.StartInfo = $childInfo; [void]$child.Start(); [Console]::Out.Write(''PARTIAL_STDOUT|CHILD_PID='' + $child.Id); [Console]::Error.Write(''PARTIAL_STDERR'')'
        $command = [pscustomobject]@{
            executable = 'pwsh'
            arguments = @('-NoProfile', '-Command', $parentScript)
            prompt = ''
            tool = 'test'
            route_id = 'test__partial_pipe_capture'
            working_directory = $projectRoot
        }
        $result = Invoke-NativeCandidate -Command $command -TimeoutSeconds 1
        Assert-Contains $result.stdout 'PARTIAL_STDOUT|CHILD_PID='
        Assert-Contains $result.stderr 'PARTIAL_STDERR'
        Assert-True $result.cleanup_failed
        Assert-Equal $result.cleanup_status 'output_drain_timeout'
        $childPidMatch = [regex]::Match($result.stdout, 'CHILD_PID=(\d+)')
        Assert-True $childPidMatch.Success
        $childPid = [int]$childPidMatch.Groups[1].Value
    } finally {
        if ($null -ne $childPid) {
            $child = Get-Process -Id $childPid -ErrorAction SilentlyContinue
            if ($null -ne $child) { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue }
        }
    }
}

Invoke-Assertion 'Invoke-NativeCandidate default timeout classifies descendant-held pipes' {
    $childPid = $null
    try {
        $parentScript = '$childInfo = [System.Diagnostics.ProcessStartInfo]::new(); $childInfo.FileName = ''pwsh''; $childInfo.UseShellExecute = $false; $childInfo.CreateNoWindow = $true; [void]$childInfo.ArgumentList.Add(''-NoProfile''); [void]$childInfo.ArgumentList.Add(''-Command''); [void]$childInfo.ArgumentList.Add(''Start-Sleep -Seconds 30''); $child = [System.Diagnostics.Process]::new(); $child.StartInfo = $childInfo; [void]$child.Start(); Write-Output (''DEFAULT_CHILD_PID='' + $child.Id); Write-Output ''default parent output''; [Console]::Error.WriteLine(''default parent warning'')'
        $command = [pscustomobject]@{
            executable = 'pwsh'
            arguments = @('-NoProfile', '-Command', $parentScript)
            prompt = ''
            tool = 'test'
            route_id = 'test__default_pipe_timeout'
            working_directory = $projectRoot
        }
        $result = Invoke-NativeCandidate -Command $command
        Assert-Contains $result.stdout 'default parent output'
        Assert-Contains $result.stderr 'default parent warning'
        Assert-True $result.cleanup_failed
        Assert-Equal $result.cleanup_status 'output_drain_timeout'
        Assert-True (-not $result.timed_out)
        Assert-True ($result.duration_ms -lt 10000)
        $childPidMatch = [regex]::Match($result.stdout, 'DEFAULT_CHILD_PID=(\d+)')
        Assert-True $childPidMatch.Success
        $childPid = [int]$childPidMatch.Groups[1].Value
    } finally {
        if ($null -ne $childPid) {
            $child = Get-Process -Id $childPid -ErrorAction SilentlyContinue
            if ($null -ne $child) { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue }
        }
    }
}

Invoke-Assertion 'New-RouteId replaces punctuation in each route component' {
    $routeId = New-RouteId -Tool 'co-dex' -Model 'gpt.5/6' -Effort 'x-high'
    Assert-Contains $routeId 'co_dex'
    Assert-Contains $routeId 'gpt_5_6'
    Assert-Contains $routeId 'x_high'
}

Invoke-Assertion 'New-RouteId uses a stable default effort for Claude Haiku' {
    Assert-Equal (New-RouteId -Tool 'claude' -Model 'claude-haiku-4-5') 'claude__claude_haiku_4_5__default'
}

Invoke-Assertion 'New-RouteId uses a stable default effort for any model' {
    Assert-Equal (New-RouteId -Tool 'codex' -Model 'gpt-5.6-sol') 'codex__gpt_5_6_sol__default'
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

Invoke-Assertion 'Test-CanonicalResponse rejects a missing error property' {
    $invalid = [pscustomobject]@{ status = 'success'; answer = '4' }
    Assert-True (-not (Test-CanonicalResponse $invalid).valid)
}

Invoke-Assertion 'Test-CanonicalResponse rejects unexpected properties' {
    $invalid = [pscustomobject]@{ status = 'success'; answer = '4'; error = $null; extra = 'not allowed' }
    Assert-True (-not (Test-CanonicalResponse $invalid).valid)
}

Invoke-Assertion 'Test-CanonicalResponse rejects success with a non-null error' {
    $invalid = [pscustomobject]@{ status = 'success'; answer = '4'; error = 'unexpected error' }
    Assert-True (-not (Test-CanonicalResponse $invalid).valid)
}

Invoke-Assertion 'Test-CanonicalResponse rejects failure with a nonempty answer and null error' {
    $invalid = [pscustomobject]@{ status = 'failure'; answer = 'not empty'; error = $null }
    Assert-True (-not (Test-CanonicalResponse $invalid).valid)
}

Invoke-Assertion 'Test-CanonicalResponse rejects success with an empty answer' {
    $invalid = [pscustomobject]@{ status = 'success'; answer = ''; error = $null }
    Assert-True (-not (Test-CanonicalResponse $invalid).valid)
}

Invoke-Assertion 'Test-CandidateDefinition accepts a valid normal candidate' {
    $candidate = [pscustomobject]@{ route_id = 'codex__gpt_5_6_sol__xhigh'; tool = 'codex'; provider = 'openai'; model = 'gpt-5.6-sol'; effort = 'xhigh'; enabled = $true; candidate_kind = 'model'; instruction_file = 'pilot/providers/openai/AGENTS.md' }
    Assert-True (Test-CandidateDefinition $candidate).valid
}

Invoke-Assertion 'Test-CandidateMatrix rejects duplicate route IDs' {
    $first = [pscustomobject]@{ route_id = 'codex__gpt_5_6_sol__low'; tool = 'codex'; provider = 'openai'; model = 'gpt-5.6-sol'; effort = 'low'; enabled = $true; candidate_kind = 'model'; instruction_file = 'pilot/providers/openai/AGENTS.md' }
    $second = $first.PSObject.Copy()
    Assert-True (-not (Test-CandidateMatrix @($first, $second)).valid)
}

Invoke-Assertion 'Test-CandidateDefinition rejects unsupported effort' {
    $candidate = [pscustomobject]@{ route_id = 'codex__gpt_5_6_sol__extreme'; tool = 'codex'; provider = 'openai'; model = 'gpt-5.6-sol'; effort = 'extreme'; enabled = $true; candidate_kind = 'model'; instruction_file = 'pilot/providers/openai/AGENTS.md' }
    $result = Test-CandidateDefinition $candidate
    Assert-True (-not $result.valid)
    Assert-Contains $result.reason 'effort'
}

Invoke-Assertion 'Test-CandidateDefinition rejects missing model' {
    $candidate = [pscustomobject]@{ route_id = 'bad'; tool = 'codex'; provider = 'openai'; effort = 'low'; enabled = $true }
    $result = Test-CandidateDefinition $candidate
    Assert-True (-not $result.valid)
    Assert-Contains $result.reason 'model'
}

Invoke-Assertion 'Test-CandidateDefinition accepts disabled special route' {
    $candidate = [pscustomobject]@{ route_id = 'codex__codex_auto_review__low'; tool = 'codex'; provider = 'openai'; model = 'codex-auto-review'; effort = 'low'; enabled = $false; candidate_kind = 'special_route'; instruction_file = 'pilot/providers/openai/AGENTS.md' }
    Assert-True (Test-CandidateDefinition $candidate).valid
}

Invoke-Assertion 'Test-CandidateDefinition rejects enabled special route' {
    $candidate = [pscustomobject]@{ route_id = 'codex__codex_auto_review__low'; tool = 'codex'; provider = 'openai'; model = 'codex-auto-review'; effort = 'low'; enabled = $true; candidate_kind = 'special_route'; instruction_file = 'pilot/providers/openai/AGENTS.md' }
    $result = Test-CandidateDefinition $candidate
    Assert-True (-not $result.valid)
    Assert-Contains $result.reason 'disabled'
}

Invoke-Assertion 'Test-CandidateDefinition rejects string enabled values' {
    $candidate = [pscustomobject]@{ route_id = 'codex__gpt_5_6_sol__low'; tool = 'codex'; provider = 'openai'; model = 'gpt-5.6-sol'; effort = 'low'; enabled = 'false'; candidate_kind = 'model' }
    Assert-True (-not (Test-CandidateDefinition $candidate).valid)
}

Invoke-Assertion 'Test-CandidateDefinition rejects numeric enabled values' {
    $candidate = [pscustomobject]@{ route_id = 'codex__gpt_5_6_sol__low'; tool = 'codex'; provider = 'openai'; model = 'gpt-5.6-sol'; effort = 'low'; enabled = 1; candidate_kind = 'model' }
    Assert-True (-not (Test-CandidateDefinition $candidate).valid)
}

Invoke-Assertion 'Test-CandidateDefinition rejects missing candidate_kind' {
    $candidate = [pscustomobject]@{ route_id = 'missing-kind'; tool = 'codex'; provider = 'openai'; model = 'gpt-5.6-sol'; effort = 'low'; enabled = $true }
    Assert-True (-not (Test-CandidateDefinition $candidate).valid)
}

Invoke-Assertion 'Test-CandidateDefinition rejects invalid candidate_kind' {
    $candidate = [pscustomobject]@{ route_id = 'codex__gpt_5_6_sol__low'; tool = 'codex'; provider = 'openai'; model = 'gpt-5.6-sol'; effort = 'low'; enabled = $true; candidate_kind = 'other' }
    Assert-True (-not (Test-CandidateDefinition $candidate).valid)
}

Invoke-Assertion 'Test-CandidateDefinition rejects unexpected properties' {
    $candidate = [pscustomobject]@{ route_id = 'codex__gpt_5_6_sol__low'; tool = 'codex'; provider = 'openai'; model = 'gpt-5.6-sol'; effort = 'low'; enabled = $true; candidate_kind = 'model'; extra = 'not allowed' }
    Assert-True (-not (Test-CandidateDefinition $candidate).valid)
}

Invoke-Assertion 'Test-CandidateDefinition rejects Claude special route' {
    $candidate = [pscustomobject]@{ route_id = 'claude__claude_sonnet_5__medium'; tool = 'claude'; provider = 'anthropic'; model = 'claude-sonnet-5'; effort = 'medium'; enabled = $false; candidate_kind = 'special_route' }
    Assert-True (-not (Test-CandidateDefinition $candidate).valid)
}

Invoke-Assertion 'Test-CandidateDefinition rejects codex-auto-review marked as model' {
    $candidate = [pscustomobject]@{ route_id = 'codex__codex_auto_review__low'; tool = 'codex'; provider = 'openai'; model = 'codex-auto-review'; effort = 'low'; enabled = $false; candidate_kind = 'model' }
    Assert-True (-not (Test-CandidateDefinition $candidate).valid)
}

Invoke-Assertion 'Test-CandidateDefinition rejects enabled codex-auto-review' {
    $candidate = [pscustomobject]@{ route_id = 'codex__codex_auto_review__low'; tool = 'codex'; provider = 'openai'; model = 'codex-auto-review'; effort = 'low'; enabled = $true; candidate_kind = 'special_route' }
    Assert-True (-not (Test-CandidateDefinition $candidate).valid)
}

Invoke-Assertion 'Test-CandidateDefinition rejects mismatched tool provider and model' {
    $candidate = [pscustomobject]@{ route_id = 'codex__gpt_5_6_sol__medium'; tool = 'claude'; provider = 'openai'; model = 'gpt-5.6-sol'; effort = 'medium'; enabled = $true; candidate_kind = 'model' }
    Assert-True (-not (Test-CandidateDefinition $candidate).valid)
}

Invoke-Assertion 'Test-CandidateDefinition rejects ultra effort for gpt-5.6-luna' {
    $candidate = [pscustomobject]@{ route_id = 'codex__gpt_5_6_luna__ultra'; tool = 'codex'; provider = 'openai'; model = 'gpt-5.6-luna'; effort = 'ultra'; enabled = $true; candidate_kind = 'model' }
    Assert-True (-not (Test-CandidateDefinition $candidate).valid)
}

Invoke-Assertion 'Test-CandidateDefinition rejects a mismatched route ID' {
    $candidate = [pscustomobject]@{ route_id = 'codex__gpt_5_6_sol__low'; tool = 'codex'; provider = 'openai'; model = 'gpt-5.6-sol'; effort = 'high'; enabled = $true; candidate_kind = 'model' }
    Assert-True (-not (Test-CandidateDefinition $candidate).valid)
}

Invoke-Assertion 'Test-CandidateDefinition accepts instruction_file' {
    $candidate = [pscustomobject]@{ route_id = 'claude__claude_sonnet_5__medium'; tool = 'claude'; provider = 'anthropic'; model = 'claude-sonnet-5'; effort = 'medium'; enabled = $true; candidate_kind = 'model'; instruction_file = 'pilot/providers/anthropic/CLAUDE.md' }
    Assert-True (Test-CandidateDefinition $candidate).valid
}

Invoke-Assertion 'Test-CandidateDefinition rejects missing instruction_file' {
    $candidate = [pscustomobject]@{ route_id = 'codex__gpt_5_6_sol__medium'; tool = 'codex'; provider = 'openai'; model = 'gpt-5.6-sol'; effort = 'medium'; enabled = $true; candidate_kind = 'model' }
    Assert-True (-not (Test-CandidateDefinition $candidate).valid)
}

Invoke-Assertion 'Test-CandidateDefinition rejects nonexistent instruction_file' {
    $candidate = [pscustomobject]@{ route_id = 'codex__gpt_5_6_sol__medium'; tool = 'codex'; provider = 'openai'; model = 'gpt-5.6-sol'; effort = 'medium'; enabled = $true; candidate_kind = 'model'; instruction_file = 'pilot/providers/openai/missing-wrapper.md' }
    Assert-True (-not (Test-CandidateDefinition $candidate).valid)
}

Invoke-Assertion 'Test-CandidateDefinition accepts an existing wrapper instruction_file' {
    $candidate = [pscustomobject]@{ route_id = 'codex__gpt_5_6_sol__medium'; tool = 'codex'; provider = 'openai'; model = 'gpt-5.6-sol'; effort = 'medium'; enabled = $true; candidate_kind = 'model'; instruction_file = 'pilot/providers/openai/AGENTS.md' }
    Assert-True (Test-CandidateDefinition $candidate).valid
}

Invoke-Assertion 'Test-CandidateDefinition rejects a non-string route_id' {
    $candidate = [pscustomobject]@{ route_id = @('codex__gpt_5_6_sol__medium', 'extra'); tool = 'codex'; provider = 'openai'; model = 'gpt-5.6-sol'; effort = 'medium'; enabled = $true; candidate_kind = 'model'; instruction_file = 'pilot/providers/openai/AGENTS.md' }
    Assert-True (-not (Test-CandidateDefinition $candidate).valid)
}

Invoke-Assertion 'Resolve-RunnerInstructionFile accepts an existing wrapper file' {
    $resolved = Resolve-RunnerInstructionFile 'pilot/providers/openai/AGENTS.md'
    Assert-True ($null -ne $resolved -and -not $resolved.PSIsContainer)
}

Invoke-Assertion 'Resolve-RunnerInstructionFile rejects an external parent reparse target' {
    $externalTarget = [System.IO.Path]::GetFullPath((Join-Path $projectRoot '..\external-instruction-target'))
    Assert-True (-not (Test-RunnerResolvedTargetInsideRepository $externalTarget))
}

Invoke-Assertion 'Test-CandidateDefinition rejects arrays in every scalar field' {
    $base = [pscustomobject]@{ route_id = 'codex__gpt_5_6_sol__medium'; tool = 'codex'; provider = 'openai'; model = 'gpt-5.6-sol'; effort = 'medium'; enabled = $true; candidate_kind = 'model'; instruction_file = 'pilot/providers/openai/AGENTS.md' }
    foreach ($field in @('route_id', 'tool', 'provider', 'model', 'effort', 'candidate_kind', 'instruction_file')) {
        $candidate = $base.PSObject.Copy()
        $candidate.$field = @('not-scalar', 'extra')
        Assert-True (-not (Test-CandidateDefinition $candidate).valid)
    }
}

Invoke-Assertion 'Resolve-RunnerInstructionFile rejects a real external directory junction parent' {
    $token = [guid]::NewGuid().ToString('N')
    $outsideDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "runner-outside-$token"
    $junctionPath = Join-Path $projectRoot "pilot/tests/.runner-junction-$token"
    $outsideCreated = $false
    $junctionCreated = $false
    try {
        New-Item -ItemType Directory -Path $outsideDirectory -Force -ErrorAction Stop | Out-Null
        $outsideCreated = $true
        Set-Content -LiteralPath (Join-Path $outsideDirectory 'wrapper.md') -Value 'outside' -NoNewline -ErrorAction Stop
        if (Test-Path -LiteralPath $junctionPath) { throw "Refusing to use pre-existing test path '$junctionPath'." }
        try {
            New-Item -ItemType Junction -Path $junctionPath -Target $outsideDirectory -ErrorAction Stop | Out-Null
        } catch {
            Write-Host "SKIP real parent junction regression: $($_.Exception.Message)"
            Assert-True (-not (Test-RunnerResolvedTargetInsideRepository $outsideDirectory))
            return
        }
        $junctionCreated = $true
        $candidatePath = "pilot/tests/.runner-junction-$token/wrapper.md"
        Assert-Equal (Resolve-RunnerInstructionFile $candidatePath) $null
    } finally {
        if ($junctionCreated -and (Test-Path -LiteralPath $junctionPath)) {
            Remove-Item -LiteralPath $junctionPath -Force -ErrorAction SilentlyContinue
        }
        if ($outsideCreated -and (Test-Path -LiteralPath $outsideDirectory)) {
            Remove-Item -LiteralPath $outsideDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Invoke-Assertion 'Resolve-RunnerInstructionFile rejects a real external final-file symbolic link' {
    $token = [guid]::NewGuid().ToString('N')
    $outsideDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "runner-outside-$token"
    $outsideFile = Join-Path $outsideDirectory 'outside-wrapper.md'
    $linkPath = Join-Path $projectRoot "pilot/tests/.runner-file-link-$token.md"
    $outsideCreated = $false
    $linkCreated = $false
    try {
        New-Item -ItemType Directory -Path $outsideDirectory -Force -ErrorAction Stop | Out-Null
        $outsideCreated = $true
        Set-Content -LiteralPath $outsideFile -Value 'outside' -NoNewline -ErrorAction Stop
        if (Test-Path -LiteralPath $linkPath) { throw "Refusing to use pre-existing test path '$linkPath'." }
        try {
            New-Item -ItemType SymbolicLink -Path $linkPath -Target $outsideFile -ErrorAction Stop | Out-Null
        } catch {
            Write-Host "SKIP real final-file symbolic-link regression: $($_.Exception.Message)"
            Assert-True (-not (Test-RunnerResolvedTargetInsideRepository $outsideFile))
            return
        }
        $linkCreated = $true
        $relativeLink = "pilot/tests/.runner-file-link-$token.md"
        Assert-Equal (Resolve-RunnerInstructionFile $relativeLink) $null
    } finally {
        if ($linkCreated -and (Test-Path -LiteralPath $linkPath)) {
            Remove-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue
        }
        if ($outsideCreated -and (Test-Path -LiteralPath $outsideDirectory)) {
            Remove-Item -LiteralPath $outsideDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Invoke-Assertion 'Subscription model matrix exists and has the complete validated catalog' {
    $matrixPath = Join-Path $projectRoot 'pilot/model_matrix.json'
    Assert-True (Test-Path -LiteralPath $matrixPath -PathType Leaf)
    $matrix = Get-Content -Raw -LiteralPath $matrixPath | ConvertFrom-Json

    Assert-Equal $matrix.schema_version 1
    Assert-Equal $matrix.generated_from 'subscription model catalog'
    Assert-Equal $matrix.candidates.Count 63
    Assert-Equal $matrix.special_routes.Count 5
    Assert-Equal (@($matrix.candidates | Where-Object { $_.enabled }).Count) 63
    Assert-Equal (@($matrix.special_routes | Where-Object { -not $_.enabled }).Count) 5
    Assert-Equal (@($matrix.candidates.route_id + $matrix.special_routes.route_id | Select-Object -Unique).Count) 68
    Assert-True ((Test-CandidateMatrix @($matrix.candidates)).valid)
    Assert-True ((Test-CandidateMatrix @($matrix.special_routes)).valid)
    foreach ($candidate in @($matrix.candidates + $matrix.special_routes)) {
        Assert-True ((Test-CandidateDefinition $candidate).valid)
    }
}

Invoke-Assertion 'Subscription model matrix has the exact tool and model counts' {
    $matrix = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'pilot/model_matrix.json') | ConvertFrom-Json
    $candidates = @($matrix.candidates)

    Assert-Equal (@($candidates | Where-Object { $_.tool -eq 'agy' }).Count) 14
    Assert-Equal (@($candidates | Where-Object { $_.tool -eq 'codex' }).Count) 33
    Assert-Equal (@($candidates | Where-Object { $_.tool -eq 'claude' }).Count) 16
    Assert-Equal (@($matrix.special_routes | Where-Object { $_.tool -eq 'codex' }).Count) 5
    $expectedAgyModels = @(
        'gemini-3.7-flash-high', 'gemini-3.7-flash-medium', 'gemini-3.7-flash-low',
        'gemini-3.6-flash-high', 'gemini-3.6-flash-medium', 'gemini-3.6-flash-low',
        'gemini-3.5-flash-high', 'gemini-3.5-flash-medium', 'gemini-3.5-flash-low',
        'gemini-3.1-pro-high', 'gemini-3.1-pro-low', 'claude-sonnet-4-6',
        'claude-opus-4-6-thinking', 'gpt-oss-120b-medium'
    )
    Assert-Equal (@($candidates | Where-Object { $_.tool -eq 'agy' } | Select-Object -ExpandProperty model -Unique) -join ',') ($expectedAgyModels -join ',')
    Assert-Equal (@($candidates | Where-Object { $_.tool -eq 'claude' } | Select-Object -ExpandProperty model -Unique).Count) 4
    Assert-Equal (@($candidates | Where-Object { $_.tool -eq 'codex' } | Select-Object -ExpandProperty model -Unique).Count) 7
    Assert-Equal (@($candidates | Where-Object { $_.model -eq 'claude-haiku-4-5' -and $null -eq $_.effort }).Count) 1
}

Invoke-Assertion 'Subscription model matrix uses exact instruction files and provider mapping' {
    $matrix = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'pilot/model_matrix.json') | ConvertFrom-Json
    $allRoutes = @($matrix.candidates + $matrix.special_routes)
    foreach ($route in $allRoutes) {
        $expectedInstruction = switch ($route.tool) {
            'agy' { 'pilot/providers/google/GEMINI.md' }
            'codex' { 'pilot/providers/openai/AGENTS.md' }
            'claude' { 'pilot/providers/anthropic/CLAUDE.md' }
        }
        Assert-Equal $route.instruction_file $expectedInstruction
    }
    Assert-Equal (@($matrix.candidates | Where-Object { $_.tool -eq 'agy' -and $_.provider -eq 'google' }).Count) 11
    Assert-Equal (@($matrix.candidates | Where-Object { $_.tool -eq 'agy' -and $_.provider -eq 'anthropic' }).Count) 2
    Assert-Equal (@($matrix.candidates | Where-Object { $_.tool -eq 'agy' -and $_.provider -eq 'openai' }).Count) 1
}

Invoke-Assertion 'providers registry points to the subscription model matrix' {
    $providers = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'pilot/providers.json') | ConvertFrom-Json
    Assert-Equal $providers.model_matrix_path 'pilot/model_matrix.json'
    Assert-Equal $providers.providers.Count 3
}

Invoke-Assertion 'Invoke-PilotRun dry-run does not invoke the native process' {
    $matrix = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'pilot/model_matrix.json') | ConvertFrom-Json
    $state = @{ calls = 0 }
    $result = Invoke-PilotRun -Matrix $matrix -DryRun -NativeInvoker {
        $state.calls++
        throw 'native process must not be called during dry-run'
    }
    Assert-Equal $state.calls 0
    Assert-Equal $result.mode 'dry-run'
    Assert-Equal $result.selected.Count 63
}

Invoke-Assertion 'Invoke-PilotRun selects one route and appends one normalized record' {
    $matrix = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'pilot/model_matrix.json') | ConvertFrom-Json
    $route = @($matrix.candidates | Where-Object { $_.tool -eq 'codex' } | Select-Object -First 1)[0]
    $resultsPath = Join-Path $projectRoot 'pilot/tests/.runner-task5-route.jsonl'
    if (Test-Path -LiteralPath $resultsPath) { Remove-Item -LiteralPath $resultsPath -Force }
    try {
        $invoker = {
            [pscustomobject]@{ exit_code = 0; stdout = (Get-Content -Raw (Join-Path $projectRoot 'pilot/tests/fixtures/codex-success.jsonl')); stderr = ''; duration_ms = 7 }
        }
        $run = Invoke-PilotRun -Matrix $matrix -RouteId $route.route_id -ResultsPath $resultsPath -NativeInvoker $invoker
        $records = @(Get-Content -LiteralPath $resultsPath | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-Equal $run.selected.Count 1
        Assert-Equal $records.Count 1
        Assert-Equal $records[0].route_id $route.route_id
        Assert-True $records[0].transport_success
        Assert-True $records[0].contract_compliant
        Assert-Equal $records[0].answer '4'
        Assert-Equal $records[0].error $null
        Assert-True ($records[0].run_id.Length -gt 0)
    } finally {
        if (Test-Path -LiteralPath $resultsPath) { Remove-Item -LiteralPath $resultsPath -Force }
    }
}

Invoke-Assertion 'New-PilotPrompt includes only contract wrapper and task content' {
    $matrix = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'pilot/model_matrix.json') | ConvertFrom-Json
    $candidate = @($matrix.candidates | Select-Object -First 1)[0]
    $prompt = New-PilotPrompt -Candidate $candidate
    Assert-Contains $prompt 'Shared Experiment Contract'
    Assert-Contains $prompt 'Compute `2 + 2`.'
    Assert-Contains $prompt 'Do not browse the web.'
    Assert-True (-not $prompt.Contains('gpt-5.6-sol'))
    Assert-True (-not $prompt.Contains('model_matrix.json'))
    Assert-True (-not $prompt.Contains('auth_verified'))
}

Invoke-Assertion 'Invoke-PilotRun continues after a failed candidate' {
    $matrix = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'pilot/model_matrix.json') | ConvertFrom-Json
    $selected = @($matrix.candidates | Where-Object { $_.tool -eq 'codex' } | Select-Object -First 2)
    $resultsPath = Join-Path $projectRoot 'pilot/tests/.runner-task5-continue.jsonl'
    if (Test-Path -LiteralPath $resultsPath) { Remove-Item -LiteralPath $resultsPath -Force }
    try {
        $failedRoute = $selected[0].route_id
        $invoker = {
            param($command)
            if ($command.route_id -eq $failedRoute) { throw 'fixture transport failure' }
            [pscustomobject]@{ exit_code = 0; stdout = (Get-Content -Raw (Join-Path $projectRoot 'pilot/tests/fixtures/codex-success.jsonl')); stderr = ''; duration_ms = 8 }
        }
        Invoke-PilotRun -Matrix $matrix -RouteId $selected[0].route_id -ResultsPath $resultsPath -NativeInvoker $invoker | Out-Null
        Invoke-PilotRun -Matrix $matrix -RouteId $selected[1].route_id -ResultsPath $resultsPath -NativeInvoker $invoker | Out-Null
        $records = @(Get-Content -LiteralPath $resultsPath | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-Equal $records.Count 2
        Assert-True (-not $records[0].transport_success)
        Assert-True $records[1].transport_success
    } finally {
        if (Test-Path -LiteralPath $resultsPath) { Remove-Item -LiteralPath $resultsPath -Force }
    }
}

Invoke-Assertion 'Invoke-PilotRun appends without overwriting prior JSONL records' {
    $matrix = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'pilot/model_matrix.json') | ConvertFrom-Json
    $routes = @($matrix.candidates | Select-Object -First 2)
    $resultsPath = Join-Path $projectRoot 'pilot/tests/.runner-task5-append.jsonl'
    if (Test-Path -LiteralPath $resultsPath) { Remove-Item -LiteralPath $resultsPath -Force }
    try {
        $invoker = { [pscustomobject]@{ exit_code = 0; stdout = (Get-Content -Raw (Join-Path $projectRoot 'pilot/tests/fixtures/codex-success.jsonl')); stderr = ''; duration_ms = 1 } }
        Invoke-PilotRun -Matrix $matrix -RouteId $routes[0].route_id -ResultsPath $resultsPath -NativeInvoker $invoker | Out-Null
        Invoke-PilotRun -Matrix $matrix -RouteId $routes[1].route_id -ResultsPath $resultsPath -NativeInvoker $invoker | Out-Null
        $lines = @(Get-Content -LiteralPath $resultsPath)
        Assert-Equal $lines.Count 2
        Assert-Equal (@($lines | ForEach-Object { $_ | ConvertFrom-Json }).Count) 2
    } finally {
        if (Test-Path -LiteralPath $resultsPath) { Remove-Item -LiteralPath $resultsPath -Force }
    }
}

Invoke-Assertion 'result normalization separates transport success from contract failure' {
    $matrix = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'pilot/model_matrix.json') | ConvertFrom-Json
    $route = @($matrix.candidates | Where-Object { $_.tool -eq 'codex' } | Select-Object -First 1)[0]
    $resultsPath = Join-Path $projectRoot 'pilot/tests/.runner-task5-contract.jsonl'
    if (Test-Path -LiteralPath $resultsPath) { Remove-Item -LiteralPath $resultsPath -Force }
    try {
        $invoker = { [pscustomobject]@{ exit_code = 0; stdout = (Get-Content -Raw (Join-Path $projectRoot 'pilot/tests/fixtures/contract-type-failure.json')); stderr = 'raw stderr must not be persisted'; duration_ms = 3 } }
        Invoke-PilotRun -Matrix $matrix -RouteId $route.route_id -ResultsPath $resultsPath -NativeInvoker $invoker | Out-Null
        $record = Get-Content -Raw -LiteralPath $resultsPath | ConvertFrom-Json
        foreach ($field in @('run_id','route_id','tool','provider','model','effort','transport_success','contract_compliant','status','answer','error','exit_code','duration_ms','diagnostic_note')) {
            Assert-True ($record.PSObject.Properties.Name -contains $field)
        }
        Assert-True $record.transport_success
        Assert-True (-not $record.contract_compliant)
        Assert-Equal $record.answer ''
        Assert-True ($record.error -is [string])
        Assert-True (-not ([string]$record | Select-String 'raw stderr'))
    } finally {
        if (Test-Path -LiteralPath $resultsPath) { Remove-Item -LiteralPath $resultsPath -Force }
    }
}

Invoke-Assertion 'persisted result strings redact the complete generated prompt and encoded variants' {
    $matrix = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'pilot/model_matrix.json') | ConvertFrom-Json
    $route = @($matrix.candidates | Where-Object { $_.tool -eq 'codex' } | Select-Object -First 1)[0]
    $expectedPrompt = New-PilotPrompt -Candidate $route
    $resultsPath = Join-Path $projectRoot 'pilot/tests/.runner-task5-prompt-leak.jsonl'
    if (Test-Path -LiteralPath $resultsPath) { Remove-Item -LiteralPath $resultsPath -Force }
    try {
        $invoker = {
            param($command)
            $inner = [pscustomobject]@{ status = 'success'; answer = $expectedPrompt; error = $null } | ConvertTo-Json -Compress
            $outer = [pscustomobject]@{ type = 'item.completed'; item = [pscustomobject]@{ type = 'agent_message'; text = $inner } } | ConvertTo-Json -Compress
            [pscustomobject]@{ exit_code = 0; stdout = $outer; stderr = ''; duration_ms = 2 }
        }
        Invoke-PilotRun -Matrix $matrix -RouteId $route.route_id -ResultsPath $resultsPath -NativeInvoker $invoker | Out-Null
        $jsonl = Get-Content -Raw -LiteralPath $resultsPath
        $encodedPrompt = $expectedPrompt | ConvertTo-Json -Compress
        $fullyEncodedPrompt = ConvertTo-RunnerFullyUnicodeEscaped -Text $expectedPrompt
        Assert-True (-not $jsonl.Contains($expectedPrompt))
        Assert-True (-not $jsonl.Contains($encodedPrompt))
        Assert-True (-not $jsonl.Contains($fullyEncodedPrompt))
        $record = $jsonl | ConvertFrom-Json
        Assert-Equal $record.answer '[prompt redacted]'
        Assert-Equal $record.error $null
    } finally {
        if (Test-Path -LiteralPath $resultsPath) { Remove-Item -LiteralPath $resultsPath -Force }
    }
}

Invoke-Assertion 'Claude envelope cost metadata is recorded without persisting provider output' {
    $matrix = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'pilot/model_matrix.json') | ConvertFrom-Json
    $route = @($matrix.candidates | Where-Object { $_.tool -eq 'claude' } | Select-Object -First 1)[0]
    $resultsPath = Join-Path $projectRoot 'pilot/tests/.runner-task5-cost.jsonl'
    if (Test-Path -LiteralPath $resultsPath) { Remove-Item -LiteralPath $resultsPath -Force }
    try {
        $invoker = { [pscustomobject]@{ exit_code = 0; stdout = (Get-Content -Raw (Join-Path $projectRoot 'pilot/tests/fixtures/claude-cost-success.json')); stderr = ''; duration_ms = 4 } }
        Invoke-PilotRun -Matrix $matrix -RouteId $route.route_id -ResultsPath $resultsPath -NativeInvoker $invoker | Out-Null
        $jsonl = Get-Content -Raw -LiteralPath $resultsPath
        $record = $jsonl | ConvertFrom-Json
        Assert-Equal $record.cli_reported_cost_usd 0.0123
        Assert-True (-not $jsonl.Contains('total_cost_usd'))
        Assert-True (-not $jsonl.Contains('modelUsage'))
        $metadataResult = [pscustomobject]@{ stdout = ''; metadata = [pscustomobject]@{ cost_usd = 0.045 } }
        Assert-Equal (Get-PilotReportedCost -ProcessResult $metadataResult) 0.045
    } finally {
        if (Test-Path -LiteralPath $resultsPath) { Remove-Item -LiteralPath $resultsPath -Force }
    }
}

Invoke-Assertion 'RunAll continues after one injected candidate failure in the same invocation' {
    $matrix = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'pilot/model_matrix.json') | ConvertFrom-Json
    $runMatrix = [pscustomobject]@{
        candidates = @($matrix.candidates | Where-Object { $_.tool -eq 'codex' } | Select-Object -First 2)
        special_routes = @()
    }
    $failedRoute = $runMatrix.candidates[0].route_id
    $resultsPath = Join-Path $projectRoot 'pilot/tests/.runner-task5-runall.jsonl'
    if (Test-Path -LiteralPath $resultsPath) { Remove-Item -LiteralPath $resultsPath -Force }
    try {
        $invoker = {
            param($command)
            if ($command.route_id -eq $failedRoute) { throw 'offline fixture transport failure' }
            [pscustomobject]@{ exit_code = 0; stdout = (Get-Content -Raw (Join-Path $projectRoot 'pilot/tests/fixtures/codex-success.jsonl')); stderr = ''; duration_ms = 5 }
        }
        $run = Invoke-PilotRun -Matrix $runMatrix -RunAll -ResultsPath $resultsPath -NativeInvoker $invoker
        $records = @(Get-Content -LiteralPath $resultsPath | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-Equal $run.records.Count 2
        Assert-Equal $records.Count 2
        Assert-True (-not $records[0].transport_success)
        Assert-True $records[1].transport_success
    } finally {
        if (Test-Path -LiteralPath $resultsPath) { Remove-Item -LiteralPath $resultsPath -Force }
    }
}

Invoke-Assertion 'public CLI no-switch entrypoint performs a 63-candidate dry-run without writing results' {
    $resultsPath = Join-Path $projectRoot 'pilot/tests/.runner-task5-cli-dry-run.jsonl'
    $sentinel = 'prior record must remain untouched'
    Set-Content -LiteralPath $resultsPath -Value $sentinel -Encoding utf8
    try {
        $output = @(pwsh -NoProfile -File (Join-Path $projectRoot 'pilot/run_pilot.ps1') -ResultsPath 'pilot/tests/.runner-task5-cli-dry-run.jsonl' 2>&1)
        Assert-Equal $LASTEXITCODE 0
        $joinedOutput = $output -join "`n"
        Assert-Contains $joinedOutput 'Dry run: 63 candidate(s) selected; no provider processes invoked.'
        Assert-Equal (Get-Content -Raw -LiteralPath $resultsPath).Trim() $sentinel
    } finally {
        if (Test-Path -LiteralPath $resultsPath) { Remove-Item -LiteralPath $resultsPath -Force }
    }
}

Invoke-Assertion 'special routes require explicit opt-in' {
    $matrix = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'pilot/model_matrix.json') | ConvertFrom-Json
    $special = @($matrix.special_routes | Select-Object -First 1)[0]
    $normal = Invoke-PilotRun -Matrix $matrix -DryRun
    $included = Invoke-PilotRun -Matrix $matrix -DryRun -IncludeSpecialRoutes
    Assert-True ($normal.selected.route_id -notcontains $special.route_id)
    Assert-True ($included.selected.route_id -contains $special.route_id)
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    exit 1
}

exit 0
