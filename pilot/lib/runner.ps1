$script:RunnerProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))

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
