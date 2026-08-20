$script:RunnerProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))

if ($null -eq ('RunnerNativeStreamCapture' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
using System.Threading;

public sealed class RunnerNativeStreamCapture
{
    public readonly ConcurrentQueue<string> Chunks;
    public readonly ManualResetEventSlim Closed = new ManualResetEventSlim(false);
    public Task ReaderTask;

    private RunnerNativeStreamCapture(ConcurrentQueue<string> chunks)
    {
        Chunks = chunks;
    }

    public static RunnerNativeStreamCapture Attach(Process process, ConcurrentQueue<string> chunks, bool stdout)
    {
        StreamReader reader = stdout ? process.StandardOutput : process.StandardError;
        var capture = new RunnerNativeStreamCapture(chunks);
        capture.ReaderTask = Task.Run(async () =>
        {
            var buffer = new char[4096];
            int count;
            while ((count = await reader.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false)) > 0)
            {
                capture.Chunks.Enqueue(new string(buffer, 0, count));
            }
            capture.Closed.Set();
        });

        return capture;
    }
}
'@
}

function New-RouteId {
    param(
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][string]$Model,
        [AllowNull()][string]$Effort
    )

    if ([string]::IsNullOrWhiteSpace($Effort)) {
        $Effort = 'default'
    }

    $parts = @($Tool, $Model, $Effort) | ForEach-Object {
        ($_ -replace '[^a-zA-Z0-9]+', '_').Trim('_').ToLowerInvariant()
    }

    return ($parts -join '__')
}

function ConvertFrom-CodexOutput {
    param([Parameter(Mandatory)][string]$Text)

    $lastMessage = $null
    foreach ($line in ($Text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        try {
            $outer = $line | ConvertFrom-Json -Depth 20
        } catch {
            throw "Invalid Codex JSONL output: $($_.Exception.Message)"
        }

        if ($outer.type -eq 'item.completed' -and $outer.item.type -eq 'agent_message') {
            $lastMessage = $outer.item.text
        }
    }

    if ($null -eq $lastMessage) {
        throw 'Codex output did not contain a completed agent_message event.'
    }

    try {
        return ($lastMessage | ConvertFrom-Json -Depth 20)
    } catch {
        throw "Invalid inner JSON in Codex agent_message: $($_.Exception.Message)"
    }
}

function ConvertFrom-ClaudeOutput {
    param([Parameter(Mandatory)][string]$Text)

    try {
        $outer = $Text | ConvertFrom-Json -Depth 20
    } catch {
        throw "Invalid Claude output JSON: $($_.Exception.Message)"
    }

    if (-not ($outer.PSObject.Properties.Name -contains 'result') -or
        $outer.result -isnot [string] -or [string]::IsNullOrWhiteSpace($outer.result)) {
        throw 'Claude output is missing a usable result string.'
    }

    try {
        return ($outer.result | ConvertFrom-Json -Depth 20)
    } catch {
        throw "Invalid inner JSON in Claude result: $($_.Exception.Message)"
    }
}

function ConvertFrom-AgyOutput {
    param([Parameter(Mandatory)][string]$Text)

    try {
        $outer = $Text | ConvertFrom-Json -Depth 20
    } catch {
        throw "Invalid Agy output JSON: $($_.Exception.Message)"
    }

    $hasStructured = $outer.PSObject.Properties.Name -contains 'structured_output'
    if ($hasStructured -and $null -ne $outer.structured_output) {
        if ($outer.structured_output -is [string]) {
            try {
                return ($outer.structured_output | ConvertFrom-Json -Depth 20)
            } catch {
                throw "Invalid inner JSON in Agy structured_output: $($_.Exception.Message)"
            }
        }
        return $outer.structured_output
    }

    if (($outer.PSObject.Properties.Name -contains 'response') -and
        $outer.response -is [string] -and -not [string]::IsNullOrWhiteSpace($outer.response)) {
        try {
            return ($outer.response | ConvertFrom-Json -Depth 20)
        } catch {
            throw "Invalid inner JSON in Agy response: $($_.Exception.Message)"
        }
    }

    throw 'Agy output contains neither usable structured_output nor response.'
}

function Test-CanonicalResponse {
    param([Parameter(Mandatory)][object]$Response)

    $reason = $null
    if ($null -eq $Response) {
        $reason = 'Response is null.'
    } else {
        $propertyNames = @($Response.PSObject.Properties.Name)
        foreach ($required in @('status', 'answer', 'error')) {
            if ($required -notin $propertyNames) {
                $reason = "Missing required property '$required'."
                break
            }
        }

        if ($null -eq $reason) {
            $unexpected = @($propertyNames | Where-Object { $_ -notin @('status', 'answer', 'error') })
            if ($unexpected.Count -gt 0) {
                $reason = "Unexpected properties: $($unexpected -join ', ')."
            }
        }

        if ($null -eq $reason -and ($Response.status -isnot [string] -or $Response.status -notin @('success', 'failure'))) {
            $reason = 'status must be exactly success or failure.'
        } elseif ($null -eq $reason -and $Response.answer -isnot [string]) {
            $reason = 'answer must be a string.'
        } elseif ($null -eq $reason -and $null -ne $Response.error -and $Response.error -isnot [string]) {
            $reason = 'error must be null or a string.'
        } elseif ($null -eq $reason -and $Response.status -eq 'success' -and $null -ne $Response.error) {
            $reason = 'success responses must have null error.'
        } elseif ($null -eq $reason -and $Response.status -eq 'success' -and $Response.answer -eq '') {
            $reason = 'success responses must have a nonempty answer.'
        } elseif ($null -eq $reason -and $Response.status -eq 'failure' -and
            ($Response.answer -ne '' -or $Response.error -isnot [string] -or [string]::IsNullOrWhiteSpace($Response.error))) {
            $reason = 'failure responses must have an empty answer and a nonempty error.'
        }
    }

    [pscustomobject]@{
        valid = $null -eq $reason
        reason = $reason
        response = $Response
    }
}

function Test-RunnerResolvedTargetInsideRepository {
    param([Parameter(Mandatory)][string]$TargetPath)

    try {
        $rootPath = [System.IO.Path]::GetFullPath($script:RunnerProjectRoot).TrimEnd('\')
        $target = [System.IO.Path]::GetFullPath($TargetPath).TrimEnd('\')
        return $target.Equals($rootPath, [System.StringComparison]::OrdinalIgnoreCase) -or
            $target.StartsWith("$rootPath\", [System.StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Test-RunnerPathComponentsInsideRepository {
    param([Parameter(Mandatory)][string]$CandidatePath)

    try {
        $rootPath = [System.IO.Path]::GetFullPath($script:RunnerProjectRoot).TrimEnd('\')
        $rootPrefix = "$rootPath\"
        $candidate = [System.IO.Path]::GetFullPath($CandidatePath)
        if (-not $candidate.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }

        $current = $rootPath
        $relative = $candidate.Substring($rootPrefix.Length)
        foreach ($component in ($relative -split '[\\/]')) {
            if ([string]::IsNullOrWhiteSpace($component)) { continue }
            $current = Join-Path $current $component
            if (-not (Test-Path -LiteralPath $current)) { break }

            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                $targetInfo = $item.ResolveLinkTarget($true)
                if ($null -eq $targetInfo -or
                    -not (Test-RunnerResolvedTargetInsideRepository $targetInfo.FullName)) {
                    return $false
                }
            }
        }
        return $true
    } catch {
        return $false
    }
}

function Resolve-RunnerInstructionFile {
    param([Parameter(Mandatory)][string]$InstructionFile)

    try {
        $rootPath = [System.IO.Path]::GetFullPath($script:RunnerProjectRoot).TrimEnd('\')
        $instructionPath = if ([System.IO.Path]::IsPathRooted($InstructionFile)) {
            [System.IO.Path]::GetFullPath($InstructionFile)
        } else {
            [System.IO.Path]::GetFullPath((Join-Path $rootPath $InstructionFile))
        }
        $rootPrefix = "$rootPath\"
        if (-not $instructionPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }
        if (-not (Test-RunnerPathComponentsInsideRepository $instructionPath)) {
            return $null
        }

        $linkItem = Get-Item -LiteralPath $instructionPath -ErrorAction Stop
        if ($linkItem.PSIsContainer) {
            return $null
        }

        $fileInfo = [System.IO.FileInfo]::new($linkItem.FullName)
        $targetInfo = $fileInfo.ResolveLinkTarget($true)
        $finalPath = if ($null -ne $targetInfo) { $targetInfo.FullName } else { $fileInfo.FullName }
        $finalPath = [System.IO.Path]::GetFullPath($finalPath)
        if (-not (Test-RunnerResolvedTargetInsideRepository $finalPath)) {
            return $null
        }
        if (-not [System.IO.File]::Exists($finalPath)) {
            return $null
        }

        $finalItem = Get-Item -LiteralPath $finalPath -ErrorAction Stop
        if ($finalItem.PSIsContainer) {
            return $null
        }
        return $finalItem
    } catch {
        return $null
    }
}

function Test-CandidateDefinition {
    param([Parameter(Mandatory)][object]$Candidate)

    $reason = $null
    if ($null -eq $Candidate) {
        $reason = 'Candidate is null.'
    } else {
        $propertyNames = @($Candidate.PSObject.Properties.Name)
        $allowedProperties = @('route_id', 'tool', 'provider', 'model', 'effort', 'enabled', 'candidate_kind', 'instruction_file')
        $unexpected = @($propertyNames | Where-Object { $_ -notin $allowedProperties })
        if ($unexpected.Count -gt 0) {
            $reason = "Unexpected candidate properties: $($unexpected -join ', ')."
        }

        foreach ($field in @('route_id', 'tool', 'provider', 'model', 'candidate_kind', 'instruction_file')) {
            if ($null -eq $reason -and -not ($propertyNames -contains $field)) {
                $reason = "$field must be present."
            } elseif ($null -eq $reason -and $Candidate.$field -isnot [string]) {
                $reason = "$field must be a string."
            } elseif ($null -eq $reason -and [string]::IsNullOrWhiteSpace($Candidate.$field)) {
                $reason = "$field must be nonempty."
            }
        }

        if ($null -eq $reason -and $Candidate.candidate_kind -notin @('model', 'special_route')) {
            $reason = 'candidate_kind must be model or special_route.'
        }

        $hasEffort = $propertyNames -contains 'effort'
        if ($null -eq $reason -and $hasEffort -and $Candidate.effort -isnot [string]) {
            $reason = 'effort must be a string when present.'
        }

        if ($null -eq $reason -and $null -eq (Resolve-RunnerInstructionFile $Candidate.instruction_file)) {
            $reason = 'instruction_file must resolve to an existing regular file inside the project repository.'
        }

        if ($null -eq $reason -and $Candidate.tool -notin @('codex', 'claude', 'agy')) {
            $reason = 'tool must be codex, claude, or agy.'
        }

        $hasEnabled = $Candidate.PSObject.Properties.Name -contains 'enabled'
        if ($null -eq $reason -and (-not $hasEnabled -or $Candidate.enabled -isnot [bool])) {
            $reason = 'enabled must be a Boolean.'
        }

        $isCodexAutoReview = $Candidate.tool -eq 'codex' -and
            $Candidate.provider -eq 'openai' -and
            $Candidate.model -eq 'codex-auto-review'
        if ($null -eq $reason -and $Candidate.candidate_kind -eq 'special_route' -and -not $isCodexAutoReview) {
            $reason = 'special_route must be the Codex/OpenAI codex-auto-review route.'
        }

        if ($null -eq $reason -and $Candidate.model -eq 'codex-auto-review' -and $Candidate.candidate_kind -eq 'model') {
            $reason = 'codex-auto-review must be a special_route.'
        }

        if ($null -eq $reason -and $isCodexAutoReview -and $Candidate.enabled -ne $false) {
            $reason = 'codex-auto-review must be disabled.'
        }

        $hasEffort = $Candidate.PSObject.Properties.Name -contains 'effort'
        if ($null -eq $reason -and $hasEffort -and -not [string]::IsNullOrWhiteSpace([string]$Candidate.effort) -and
            $Candidate.effort -notin @('low', 'medium', 'high', 'xhigh', 'max', 'ultra')) {
            $reason = 'effort must be low, medium, high, xhigh, max, or ultra.'
        }

        if ($null -eq $reason -and (-not $hasEffort -or [string]::IsNullOrWhiteSpace([string]$Candidate.effort)) -and
            $Candidate.model -ne 'claude-haiku-4-5') {
            $reason = 'effort is required except for claude-haiku-4-5.'
        }

        $codexCatalog = @{
            'gpt-5.6-sol' = @('low', 'medium', 'high', 'xhigh', 'max', 'ultra')
            'gpt-5.6-terra' = @('low', 'medium', 'high', 'xhigh', 'max', 'ultra')
            'gpt-5.6-luna' = @('low', 'medium', 'high', 'xhigh', 'max')
            'gpt-5.5' = @('low', 'medium', 'high', 'xhigh')
            'gpt-5.4' = @('low', 'medium', 'high', 'xhigh')
            'gpt-5.4-mini' = @('low', 'medium', 'high', 'xhigh')
            'gpt-5.3-codex-spark' = @('low', 'medium', 'high', 'xhigh')
        }
        $claudeCatalog = @{
            'claude-opus-5' = @('low', 'medium', 'high', 'xhigh', 'max')
            'claude-sonnet-5' = @('low', 'medium', 'high', 'xhigh', 'max')
            'claude-fable-5' = @('low', 'medium', 'high', 'xhigh', 'max')
            'claude-haiku-4-5' = @()
        }
        $agyCatalog = @{
            'gemini-3.7-flash-high' = @{ provider = 'google'; effort = 'high' }
            'gemini-3.7-flash-medium' = @{ provider = 'google'; effort = 'medium' }
            'gemini-3.7-flash-low' = @{ provider = 'google'; effort = 'low' }
            'gemini-3.6-flash-high' = @{ provider = 'google'; effort = 'high' }
            'gemini-3.6-flash-medium' = @{ provider = 'google'; effort = 'medium' }
            'gemini-3.6-flash-low' = @{ provider = 'google'; effort = 'low' }
            'gemini-3.5-flash-high' = @{ provider = 'google'; effort = 'high' }
            'gemini-3.5-flash-medium' = @{ provider = 'google'; effort = 'medium' }
            'gemini-3.5-flash-low' = @{ provider = 'google'; effort = 'low' }
            'gemini-3.1-pro-high' = @{ provider = 'google'; effort = 'high' }
            'gemini-3.1-pro-low' = @{ provider = 'google'; effort = 'low' }
            'claude-sonnet-4-6' = @{ provider = 'anthropic'; effort = 'medium' }
            'claude-opus-4-6-thinking' = @{ provider = 'anthropic'; effort = 'medium' }
            'gpt-oss-120b-medium' = @{ provider = 'openai'; effort = 'medium' }
        }

        if ($null -eq $reason) {
            $hasUsableEffort = $hasEffort -and -not [string]::IsNullOrWhiteSpace([string]$Candidate.effort)
            switch ($Candidate.tool) {
                'codex' {
                    if ($Candidate.provider -ne 'openai') {
                        $reason = 'codex candidates must use provider openai.'
                    } elseif ($Candidate.model -eq 'codex-auto-review') {
                        if (-not $hasUsableEffort -or $Candidate.effort -notin @('low', 'medium', 'high', 'xhigh', 'max')) {
                            $reason = 'codex-auto-review effort must be low, medium, high, xhigh, or max.'
                        }
                    } elseif (-not $codexCatalog.ContainsKey($Candidate.model)) {
                        $reason = "Unsupported codex model '$($Candidate.model)'."
                    } elseif (-not $hasUsableEffort -or $Candidate.effort -notin $codexCatalog[$Candidate.model]) {
                        $reason = "effort '$($Candidate.effort)' is not supported for codex model '$($Candidate.model)'."
                    }
                }
                'claude' {
                    if ($Candidate.provider -ne 'anthropic') {
                        $reason = 'claude candidates must use provider anthropic.'
                    } elseif (-not $claudeCatalog.ContainsKey($Candidate.model)) {
                        $reason = "Unsupported claude model '$($Candidate.model)'."
                    } elseif ($Candidate.model -eq 'claude-haiku-4-5') {
                        if ($hasUsableEffort) {
                            $reason = 'claude-haiku-4-5 permits omitted effort only.'
                        }
                    } elseif (-not $hasUsableEffort -or $Candidate.effort -notin $claudeCatalog[$Candidate.model]) {
                        $reason = "effort '$($Candidate.effort)' is not supported for claude model '$($Candidate.model)'."
                    }
                }
                'agy' {
                    if (-not $agyCatalog.ContainsKey($Candidate.model)) {
                        $reason = "Unsupported agy model '$($Candidate.model)'."
                    } elseif ($Candidate.provider -ne $agyCatalog[$Candidate.model].provider) {
                        $reason = "agy model '$($Candidate.model)' must use provider $($agyCatalog[$Candidate.model].provider)."
                    } elseif (-not $hasUsableEffort -or $Candidate.effort -ne $agyCatalog[$Candidate.model].effort) {
                        $reason = "agy model '$($Candidate.model)' requires registered effort $($agyCatalog[$Candidate.model].effort)."
                    }
                }
            }
        }

        if ($null -eq $reason) {
            $expectedRouteId = New-RouteId -Tool $Candidate.tool -Model $Candidate.model -Effort $Candidate.effort
            if ($Candidate.route_id -ne $expectedRouteId) {
                $reason = "route_id must equal '$expectedRouteId'."
            }
        }
    }

    [pscustomobject]@{
        valid = $null -eq $reason
        reason = $reason
        candidate = $Candidate
    }
}

function Test-CandidateMatrix {
    param([Parameter(Mandatory)][object[]]$Candidates)

    $seen = @{}
    foreach ($candidate in $Candidates) {
        $validation = Test-CandidateDefinition $candidate
        if (-not $validation.valid) {
            return [pscustomobject]@{ valid = $false; reason = $validation.reason; candidates = $Candidates }
        }
        if ($seen.ContainsKey($candidate.route_id)) {
            return [pscustomobject]@{ valid = $false; reason = "Duplicate route_id '$($candidate.route_id)'."; candidates = $Candidates }
        }
        $seen[$candidate.route_id] = $true
    }

    [pscustomobject]@{ valid = $true; reason = $null; candidates = $Candidates }
}

function New-CandidateCommand {
    param(
        [Parameter(Mandatory)][object]$Candidate,
        [Parameter(Mandatory)][string]$Prompt
    )

    $arguments = [System.Collections.Generic.List[string]]::new()
    switch ($Candidate.tool) {
        'codex' {
            $executable = 'codex'
            $arguments.AddRange([string[]]@('exec', '--skip-git-repo-check', '--ephemeral', '--json', '-s', 'read-only', '--model', [string]$Candidate.model))
            if (-not [string]::IsNullOrWhiteSpace([string]$Candidate.effort)) {
                $arguments.Add('-c')
                $arguments.Add(('model_reasoning_effort="{0}"' -f $Candidate.effort))
            }
            $arguments.Add($Prompt)
        }
        'claude' {
            $executable = 'claude'
            if ($Candidate.model -ne 'claude-haiku-4-5' -and [string]::IsNullOrWhiteSpace([string]$Candidate.effort)) {
                throw "Claude model '$($Candidate.model)' requires effort."
            }
            $arguments.AddRange([string[]]@('-p', '--model', [string]$Candidate.model))
            if ($Candidate.model -ne 'claude-haiku-4-5' -and -not [string]::IsNullOrWhiteSpace([string]$Candidate.effort)) {
                $arguments.AddRange([string[]]@('--effort', [string]$Candidate.effort))
            }
            $arguments.AddRange([string[]]@('--output-format', 'json', '--max-turns', '1', '--no-session-persistence', '--disable-slash-commands', '--tools', '', $Prompt))
        }
        'agy' {
            $executable = 'agy'
            if ([string]::IsNullOrWhiteSpace([string]$Candidate.effort)) {
                throw "agy model '$($Candidate.model)' requires effort."
            }
            $arguments.AddRange([string[]]@('-p', $Prompt, '--output-format', 'json', '--json-schema', 'pilot/shared/response_schema.json', '--model', [string]$Candidate.model))
            if (-not [string]::IsNullOrWhiteSpace([string]$Candidate.effort)) {
                $arguments.AddRange([string[]]@('--effort', [string]$Candidate.effort))
            }
            $arguments.AddRange([string[]]@('--print-timeout', '2m', '--disable-slash-commands'))
        }
        default { throw "Unsupported candidate tool '$($Candidate.tool)'." }
    }

    [pscustomobject]@{
        executable = $executable
        arguments = @($arguments)
        prompt = $Prompt
        tool = [string]$Candidate.tool
        route_id = [string]$Candidate.route_id
        working_directory = $script:RunnerProjectRoot
    }
}

function ConvertTo-RunnerNormalizedLineEndings {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) { return '' }
    return [System.Text.RegularExpressions.Regex]::Replace($Text, "`r`n|`r", "`n")
}

function ConvertTo-RunnerJsonUnicodeEscaped {
    param(
        [Parameter(Mandatory)][string]$JsonText,
        [switch]$Lowercase
    )

    $format = if ($Lowercase) { 'x4' } else { 'X4' }
    $builder = [System.Text.StringBuilder]::new()
    foreach ($character in $JsonText.ToCharArray()) {
        if ([int][char]$character -gt 127) {
            [void]$builder.Append(('\u{0}' -f ([int][char]$character).ToString($format)))
        } else {
            [void]$builder.Append($character)
        }
    }
    return $builder.ToString()
}

function ConvertTo-RunnerFullyUnicodeEscaped {
    param([Parameter(Mandatory)][string]$Text)

    $builder = [System.Text.StringBuilder]::new()
    foreach ($character in $Text.ToCharArray()) {
        [void]$builder.Append(('\u{0}' -f ([int][char]$character).ToString('X4')))
    }
    return $builder.ToString()
}

function Get-RunnerJsonPromptVariants {
    param([Parameter(Mandatory)][string]$JsonText)

    $variants = [System.Collections.Generic.List[string]]::new()
    $slash = $JsonText.Replace('/', '\/')
    foreach ($unicode in @(
        (ConvertTo-RunnerJsonUnicodeEscaped -JsonText $JsonText),
        (ConvertTo-RunnerJsonUnicodeEscaped -JsonText $JsonText -Lowercase)
    )) {
        $variants.Add($unicode)
        $variants.Add($unicode.Replace('/', '\/'))
    }
    $variants.Add($JsonText)
    $variants.Add($slash)
    return @($variants | Select-Object -Unique)
}

function ConvertTo-RunnerPromptRegex {
    param([Parameter(Mandatory)][string]$Prompt)

    $characterPatterns = [System.Collections.Generic.List[string]]::new()
    foreach ($character in $Prompt.ToCharArray()) {
        $alternatives = [System.Collections.Generic.List[string]]::new()
        $literal = [string]$character
        $alternatives.Add(('(?i:' + [regex]::Escape($literal) + ')'))
        $code = ([int][char]$character).ToString('X4')
        $alternatives.Add(('(?i:' + [regex]::Escape(('\u{0}' -f $code)) + ')'))
        switch ($character) {
            '/' { $alternatives.Add([regex]::Escape('\/')) }
            '"' { $alternatives.Add([regex]::Escape('\"')) }
            '\' { $alternatives.Add([regex]::Escape('\\')) }
            "`n" {
                $alternatives.Add([regex]::Escape('\n'))
                $alternatives.Add([regex]::Escape('\r\n'))
                $lineFeedRepresentations = @(
                    [regex]::Escape("`n"),
                    [regex]::Escape('\n'),
                    [regex]::Escape('\r\n'),
                    ('(?i:' + [regex]::Escape('\u000A') + ')')
                )
                $carriageReturnRepresentations = @(
                    [regex]::Escape("`n"),
                    [regex]::Escape('\r'),
                    ('(?i:' + [regex]::Escape('\u000D') + ')')
                )
                foreach ($lineFeedRepresentation in $lineFeedRepresentations) {
                    $alternatives.Add($lineFeedRepresentation)
                }
                foreach ($carriageReturnRepresentation in $carriageReturnRepresentations) {
                    foreach ($lineFeedRepresentation in $lineFeedRepresentations) {
                        $alternatives.Add($carriageReturnRepresentation + $lineFeedRepresentation)
                    }
                }
            }
            "`t" { $alternatives.Add([regex]::Escape('\t')) }
            "`b" { $alternatives.Add([regex]::Escape('\b')) }
            "`f" { $alternatives.Add([regex]::Escape('\f')) }
            "`r" { $alternatives.Add([regex]::Escape('\r')) }
        }
        $characterPatterns.Add('(?:' + (($alternatives | Select-Object -Unique) -join '|') + ')')
    }
    return ($characterPatterns -join '')
}

function ConvertTo-RunnerRedactedText {
    param(
        [AllowNull()][string]$Text,
        [string[]]$PromptVariants,
        [string]$PromptRegex
    )

    $result = ConvertTo-RunnerNormalizedLineEndings $Text
    if (-not [string]::IsNullOrEmpty($PromptRegex)) {
        $result = [regex]::Replace($result, $PromptRegex, '[prompt redacted]')
    }
    foreach ($variant in @($PromptVariants)) {
        if (-not [string]::IsNullOrEmpty($variant)) {
            $result = $result.Replace($variant, '[prompt redacted]')
        }
    }
    return $result
}

function New-RunnerStreamCapture {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)][System.Collections.Concurrent.ConcurrentQueue[string]]$Chunks,
        [Parameter(Mandatory)][ValidateSet('stdout', 'stderr')][string]$Stream
    )

    return [RunnerNativeStreamCapture]::Attach($Process, $Chunks, $Stream -eq 'stdout')
}

function Receive-RunnerStreamOutput {
    param([Parameter(Mandatory)][System.Collections.Concurrent.ConcurrentQueue[string]]$Chunks)

    $parts = [System.Collections.Generic.List[string]]::new()
    $chunk = $null
    while ($Chunks.TryDequeue([ref]$chunk)) {
        [void]$parts.Add($chunk)
        $chunk = $null
    }
    return ($parts -join '')
}

function New-RunnerPromptRedactionContext {
    param([AllowNull()][string]$Prompt)

    $promptText = if ($null -eq $Prompt) { '' } else { [string]$Prompt }
    $normalizedPromptText = ConvertTo-RunnerNormalizedLineEndings $promptText
    $promptVariants = [System.Collections.Generic.List[string]]::new()
    foreach ($variant in @($promptText, $normalizedPromptText)) {
        if ([string]::IsNullOrEmpty($variant)) { continue }
        $promptVariants.Add($variant)
        $fullyUnicodeVariant = ConvertTo-RunnerFullyUnicodeEscaped -Text $variant
        $promptVariants.Add($fullyUnicodeVariant)
        $promptVariants.Add($fullyUnicodeVariant.ToLowerInvariant())
        $jsonVariant = ConvertTo-Json -InputObject $variant -Compress
        foreach ($jsonSpelling in @(Get-RunnerJsonPromptVariants -JsonText $jsonVariant)) {
            $promptVariants.Add($jsonSpelling)
            if ($jsonSpelling.Length -gt 1) {
                $promptVariants.Add($jsonSpelling.Substring(1, $jsonSpelling.Length - 2))
            }
        }
    }

    [pscustomobject]@{
        variants = @($promptVariants | Sort-Object Length -Descending | Select-Object -Unique)
        regex = if ([string]::IsNullOrEmpty($normalizedPromptText)) { '' } else { ConvertTo-RunnerPromptRegex -Prompt $normalizedPromptText }
    }
}

function Invoke-NativeCandidate {
    param(
        [Parameter(Mandatory)][object]$Command,
        [int]$TimeoutSeconds = 0
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = [string]$Command.executable
    $startInfo.WorkingDirectory = [string]$Command.working_directory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $utf8Encoding = [System.Text.UTF8Encoding]::new($false)
    $startInfo.StandardOutputEncoding = $utf8Encoding
    $startInfo.StandardErrorEncoding = $utf8Encoding
    foreach ($argument in @($Command.arguments)) {
        [void]$startInfo.ArgumentList.Add([string]$argument)
    }

    $promptProperty = $Command.PSObject.Properties['prompt']
    $promptText = if ($null -ne $promptProperty) { [string]$promptProperty.Value } else { '' }
    $redactionContext = New-RunnerPromptRedactionContext -Prompt $promptText
    $orderedPromptVariants = $redactionContext.variants
    $promptRegex = $redactionContext.regex
    $safeArguments = @($Command.arguments | ForEach-Object {
        ConvertTo-RunnerRedactedText -Text ([string]$_) -PromptVariants $orderedPromptVariants -PromptRegex $promptRegex
    })

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        [void]$process.Start()
        $processId = $process.Id
        $stdoutChunks = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        $stderrChunks = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        $stdoutCapture = New-RunnerStreamCapture -Process $process -Chunks $stdoutChunks -Stream stdout
        $stderrCapture = New-RunnerStreamCapture -Process $process -Chunks $stderrChunks -Stream stderr

        $timedOut = $false
        $cleanupFailed = $false
        $cleanupStatus = 'not_required'
        $cleanupIssues = [System.Collections.Generic.List[string]]::new()
        $processWaitMilliseconds = if ($TimeoutSeconds -gt 0) { $TimeoutSeconds * 1000 } else { 30000 }
        if (-not $process.WaitForExit($processWaitMilliseconds)) {
                $timedOut = $true
                $cleanupStatus = 'timeout_cleanup_complete'
                try {
                    $process.Kill($true)
                } catch {
                    $cleanupIssues.Add('kill_failed')
                }
                if (-not $process.WaitForExit(1000)) {
                    $cleanupIssues.Add('process_exit_timeout')
                }
                if (-not $stdoutCapture.ReaderTask.Wait(1000)) {
                    $cleanupIssues.Add('stdout_read_timeout')
                }
                if (-not $stderrCapture.ReaderTask.Wait(1000)) {
                    $cleanupIssues.Add('stderr_read_timeout')
                }
        } else {
            $drainWaitMilliseconds = if ($TimeoutSeconds -gt 0) {
                [Math]::Max(1000, $TimeoutSeconds * 1000)
            } else {
                1000
            }
            if (-not $stdoutCapture.ReaderTask.Wait($drainWaitMilliseconds)) {
                $cleanupIssues.Add('stdout_drain_timeout')
            }
            if (-not $stderrCapture.ReaderTask.Wait($drainWaitMilliseconds)) {
                $cleanupIssues.Add('stderr_drain_timeout')
            }
            if ($cleanupIssues.Count -gt 0) {
                $cleanupStatus = 'output_drain_timeout'
            }
        }

        $stdout = Receive-RunnerStreamOutput -Chunks $stdoutChunks
        $stderr = Receive-RunnerStreamOutput -Chunks $stderrChunks
        $stdout = ConvertTo-RunnerRedactedText -Text $stdout -PromptVariants $orderedPromptVariants -PromptRegex $promptRegex
        $stderr = ConvertTo-RunnerRedactedText -Text $stderr -PromptVariants $orderedPromptVariants -PromptRegex $promptRegex
        if ($cleanupIssues.Count -gt 0) {
            $cleanupFailed = $true
            if ($timedOut) {
                $cleanupStatus = 'timeout_cleanup_failed'
            }
        }
        $processExited = $process.HasExited
        $exitCode = if ($processExited) { $process.ExitCode } else { $null }
        $stopwatch.Stop()

        [pscustomobject]@{
            exit_code = $exitCode
            stdout = $stdout
            stderr = $stderr
            duration_ms = [int64]$stopwatch.ElapsedMilliseconds
            timed_out = $timedOut
            cleanup_failed = $cleanupFailed
            cleanup_status = $cleanupStatus
            process_id = $processId
            process_exited = $processExited
            executable = ConvertTo-RunnerRedactedText -Text ([string]$Command.executable) -PromptVariants $orderedPromptVariants -PromptRegex $promptRegex
            tool = ConvertTo-RunnerRedactedText -Text ([string]$Command.tool) -PromptVariants $orderedPromptVariants -PromptRegex $promptRegex
            route_id = ConvertTo-RunnerRedactedText -Text ([string]$Command.route_id) -PromptVariants $orderedPromptVariants -PromptRegex $promptRegex
            working_directory = ConvertTo-RunnerRedactedText -Text ([string]$Command.working_directory) -PromptVariants $orderedPromptVariants -PromptRegex $promptRegex
            arguments = $safeArguments
        }
    } finally {
        $stopwatch.Stop()
        $process.Dispose()
    }
}

function Resolve-PilotProjectPath {
    param([Parameter(Mandatory)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $script:RunnerProjectRoot $Path))
}

function New-PilotPrompt {
    param(
        [Parameter(Mandatory)][object]$Candidate,
        [string]$ContractPath = 'pilot/shared/experiment_contract.md',
        [string]$TaskPath = 'pilot/tasks/001_smoke_test.md'
    )

    $wrapper = Resolve-RunnerInstructionFile $Candidate.instruction_file
    if ($null -eq $wrapper) {
        throw "Instruction file could not be resolved for route '$($Candidate.route_id)'."
    }
    $contractFile = Resolve-PilotProjectPath $ContractPath
    $taskFile = Resolve-PilotProjectPath $TaskPath
    if (-not (Test-Path -LiteralPath $contractFile -PathType Leaf)) { throw "Contract file not found: $ContractPath" }
    if (-not (Test-Path -LiteralPath $taskFile -PathType Leaf)) { throw "Task file not found: $TaskPath" }

    return @(
        '=== Shared experiment contract ==='
        (Get-Content -Raw -LiteralPath $contractFile)
        '=== Provider wrapper instructions ==='
        (Get-Content -Raw -LiteralPath $wrapper.FullName)
        '=== Experiment task ==='
        (Get-Content -Raw -LiteralPath $taskFile)
    ) -join "`n`n"
}

function Select-PilotCandidates {
    param(
        [Parameter(Mandatory)][object]$Matrix,
        [switch]$RunAll,
        [switch]$IncludeSpecialRoutes,
        [AllowEmptyString()][string]$RouteId
    )

    if ($RunAll -and -not [string]::IsNullOrWhiteSpace($RouteId)) {
        throw '-RunAll and -RouteId cannot be used together.'
    }

    $normal = @($Matrix.candidates)
    $special = @($Matrix.special_routes)
    $all = @($normal + $special)
    if ($null -eq $Matrix.candidates -or $null -eq $Matrix.special_routes) {
        throw 'Model matrix must contain candidates and special_routes arrays.'
    }
    $validation = Test-CandidateMatrix $all
    if (-not $validation.valid) { throw "Invalid model matrix: $($validation.reason)" }

    if (-not [string]::IsNullOrWhiteSpace($RouteId)) {
        $match = @($all | Where-Object { $_.route_id -eq $RouteId })
        if ($match.Count -ne 1) { throw "RouteId '$RouteId' did not resolve to exactly one candidate." }
        if ($match[0].candidate_kind -eq 'special_route' -and -not $IncludeSpecialRoutes) {
            throw "Special route '$RouteId' requires -IncludeSpecialRoutes."
        }
        return $match
    }

    $selected = @($normal | Where-Object { $_.enabled })
    if ($IncludeSpecialRoutes) {
        $selected += @($special)
    }
    return @($selected)
}

function ConvertTo-PilotDiagnostic {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    $text = ([string]$Value -replace '[\r\n\t]+', ' ' -replace '\s{2,}', ' ').Trim()
    if ($text.Length -gt 300) { $text = $text.Substring(0, 300) + '...' }
    return $text
}

function ConvertTo-PilotSafeCost {
    param([AllowNull()][object]$Value)

    $numericTypes = @([byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64], [single], [double], [decimal])
    if ($null -eq $Value -or $Value.GetType() -notin $numericTypes) { return $null }
    $number = [double]$Value
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt 0) { return $null }
    return $number
}

function Get-PilotCostFromEnvelope {
    param([AllowNull()][object]$Envelope)

    if ($null -eq $Envelope) { return $null }
    $allowedCostFields = @('total_cost_usd', 'cost_usd', 'totalCostUsd', 'costUsd')
    foreach ($container in @($Envelope, $Envelope.usage, $Envelope.metadata, $Envelope.cost)) {
        if ($null -eq $container) { continue }
        foreach ($field in $allowedCostFields) {
            if ($container.PSObject.Properties.Name -contains $field) {
                $cost = ConvertTo-PilotSafeCost $container.$field
                if ($null -ne $cost) { return $cost }
            }
        }
    }
    return $null
}

function Get-PilotReportedCost {
    param([AllowNull()][object]$ProcessResult)

    if ($null -eq $ProcessResult) { return $null }
    if ($ProcessResult.PSObject.Properties.Name -contains 'cli_reported_cost_usd') {
        $directCost = ConvertTo-PilotSafeCost $ProcessResult.cli_reported_cost_usd
        if ($null -ne $directCost) { return $directCost }
    }
    foreach ($metadataField in @('metadata', 'provider_metadata', 'cli_metadata')) {
        if ($ProcessResult.PSObject.Properties.Name -contains $metadataField) {
            $metadataCost = Get-PilotCostFromEnvelope $ProcessResult.$metadataField
            if ($null -ne $metadataCost) { return $metadataCost }
        }
    }

    $envelopes = [System.Collections.Generic.List[object]]::new()
    $stdout = [string]$ProcessResult.stdout
    if ([string]::IsNullOrWhiteSpace($stdout)) { return $null }
    try { [void]$envelopes.Add(($stdout | ConvertFrom-Json -Depth 30)) } catch { }
    foreach ($line in ($stdout -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { [void]$envelopes.Add(($line | ConvertFrom-Json -Depth 30)) } catch { }
    }

    foreach ($envelope in @($envelopes)) {
        $envelopeCost = Get-PilotCostFromEnvelope $envelope
        if ($null -ne $envelopeCost) { return $envelopeCost }
    }
    return $null
}

function Protect-PilotRecordStrings {
    param(
        [Parameter(Mandatory)][object]$Record,
        [AllowNull()][string]$Prompt
    )

    if ([string]::IsNullOrEmpty($Prompt)) { return $Record }
    $redactionContext = New-RunnerPromptRedactionContext -Prompt $Prompt
    foreach ($property in $Record.PSObject.Properties) {
        if ($property.Value -is [string]) {
            $property.Value = ConvertTo-RunnerRedactedText -Text $property.Value -PromptVariants $redactionContext.variants -PromptRegex $redactionContext.regex
        }
    }
    return $Record
}

function New-ResultRecord {
    param(
        [Parameter(Mandatory)][object]$Candidate,
        [AllowNull()][object]$ProcessResult,
        [AllowNull()][object]$Canonical,
        [Parameter(Mandatory)][string]$RunId,
        [AllowNull()][string]$DiagnosticNote,
        [AllowNull()][string]$FailureError,
        [AllowNull()][string]$Prompt,
        [AllowNull()][object]$CliReportedCostUsd
    )

    $transportSuccess = $null -ne $ProcessResult -and
        $ProcessResult.exit_code -eq 0 -and
        (-not [bool]$ProcessResult.timed_out) -and
        (-not [bool]$ProcessResult.cleanup_failed)
    $contractCompliant = $transportSuccess -and $null -ne $Canonical -and (Test-CanonicalResponse $Canonical).valid
    $answer = if ($contractCompliant) { [string]$Canonical.answer } else { '' }
    $error = if ($contractCompliant) { $null } elseif ($null -ne $FailureError) { ConvertTo-PilotDiagnostic $FailureError } elseif ($null -ne $Canonical -and $Canonical.error -is [string]) { ConvertTo-PilotDiagnostic $Canonical.error } else { 'Candidate did not produce a contract-compliant response.' }

    $record = [ordered]@{
        run_id = $RunId
        route_id = [string]$Candidate.route_id
        tool = [string]$Candidate.tool
        provider = [string]$Candidate.provider
        model = [string]$Candidate.model
        effort = if ($Candidate.PSObject.Properties.Name -contains 'effort') { [string]$Candidate.effort } else { 'default' }
        transport_success = [bool]$transportSuccess
        contract_compliant = [bool]$contractCompliant
        status = if ($contractCompliant) { [string]$Canonical.status } else { 'failure' }
        answer = [string]$answer
        error = $error
        exit_code = if ($null -ne $ProcessResult) { $ProcessResult.exit_code } else { $null }
        duration_ms = if ($null -ne $ProcessResult) { [int64]$ProcessResult.duration_ms } else { [int64]0 }
        diagnostic_note = ConvertTo-PilotDiagnostic $DiagnosticNote
    }
    if ($null -ne $ProcessResult -and $ProcessResult.PSObject.Properties.Name -contains 'cli_reported_cost_usd') {
        $processCost = ConvertTo-PilotSafeCost $ProcessResult.cli_reported_cost_usd
        if ($null -ne $processCost) { $record.cli_reported_cost_usd = $processCost }
    }
    if ($null -ne $CliReportedCostUsd) {
        $safeCost = ConvertTo-PilotSafeCost $CliReportedCostUsd
        if ($null -ne $safeCost) { $record.cli_reported_cost_usd = $safeCost }
    }
    return Protect-PilotRecordStrings -Record ([pscustomobject]$record) -Prompt $Prompt
}

function Add-PilotResultRecord {
    param(
        [Parameter(Mandatory)][object]$Record,
        [Parameter(Mandatory)][string]$ResultsPath,
        [AllowNull()][string]$Prompt
    )

    $path = Resolve-PilotProjectPath $ResultsPath
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $safeRecord = Protect-PilotRecordStrings -Record $Record -Prompt $Prompt
    $line = $safeRecord | ConvertTo-Json -Compress -Depth 10
    Add-Content -LiteralPath $path -Value $line -Encoding utf8
}

function Invoke-PilotRun {
    param(
        [Parameter(Mandatory)][object]$Matrix,
        [switch]$RunAll,
        [switch]$IncludeSpecialRoutes,
        [AllowEmptyString()][string]$RouteId,
        [string]$ResultsPath = 'pilot/results/test-run.jsonl',
        [switch]$DryRun,
        [scriptblock]$NativeInvoker
    )

    $selected = @(Select-PilotCandidates -Matrix $Matrix -RunAll:$RunAll -IncludeSpecialRoutes:$IncludeSpecialRoutes -RouteId $RouteId)
    if (-not $RunAll -and [string]::IsNullOrWhiteSpace($RouteId)) { $DryRun = $true }
    $summary = [pscustomobject]@{ mode = if ($DryRun) { 'dry-run' } else { 'run' }; selected = $selected; records = @() }
    if ($DryRun) { return $summary }

    $runId = [guid]::NewGuid().ToString('N')
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($candidate in $selected) {
        $processResult = $null
        $canonical = $null
        $failure = $null
        $prompt = ''
        $reportedCost = $null
        $note = 'completed'
        try {
            $prompt = New-PilotPrompt -Candidate $candidate
            $command = New-CandidateCommand -Candidate $candidate -Prompt $prompt
            $processResult = if ($null -ne $NativeInvoker) { & $NativeInvoker $command } else { Invoke-NativeCandidate -Command $command }
            $reportedCost = Get-PilotReportedCost -ProcessResult $processResult
            if ($processResult.exit_code -ne 0) {
                $note = 'transport failure'
                $failure = "Process exited with code $($processResult.exit_code)."
            } else {
                try {
                    $canonical = switch ($candidate.tool) {
                        'codex' { ConvertFrom-CodexOutput $processResult.stdout }
                        'claude' { ConvertFrom-ClaudeOutput $processResult.stdout }
                        'agy' { ConvertFrom-AgyOutput $processResult.stdout }
                    }
                    $canonicalCheck = Test-CanonicalResponse $canonical
                    if (-not $canonicalCheck.valid) {
                        $note = 'contract validation failure'
                        $failure = $canonicalCheck.reason
                    }
                } catch {
                    $note = 'output parse failure'
                    $failure = $_.Exception.Message
                }
            }
        } catch {
            $note = 'candidate execution failure'
            $failure = $_.Exception.Message
        }
        $record = New-ResultRecord -Candidate $candidate -ProcessResult $processResult -Canonical $canonical -RunId $runId -DiagnosticNote $note -FailureError $failure -Prompt $prompt -CliReportedCostUsd $reportedCost
        Add-PilotResultRecord -Record $record -ResultsPath $ResultsPath -Prompt $prompt
        [void]$records.Add($record)
    }
    $summary.records = @($records)
    return $summary
}
