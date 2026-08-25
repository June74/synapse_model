function New-RouterTraceStorageError {
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Detail,
        [Parameter(Mandatory)][string]$Message
    )

    return [pscustomobject][ordered]@{
        ok = $false
        error = [pscustomobject][ordered]@{
            code = $Code
            detail = $Detail
            path = '$'
            message = $Message
        }
    }
}

function Resolve-RouterPythonExecutable {
    param([AllowNull()][string]$PythonExecutable)

    if (-not [string]::IsNullOrWhiteSpace($PythonExecutable)) {
        if (Test-Path -LiteralPath $PythonExecutable -PathType Leaf) {
            return [IO.Path]::GetFullPath($PythonExecutable)
        }
        $explicitCommand = Get-Command -Name $PythonExecutable -CommandType Application `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $explicitCommand) {
            return [string]$explicitCommand.Source
        }
        return $null
    }

    foreach ($commandName in @('python', 'python3')) {
        $command = Get-Command -Name $commandName -CommandType Application `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) {
            return [string]$command.Source
        }
    }

    $userProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if (-not [string]::IsNullOrWhiteSpace($userProfile)) {
        $bundledPython = Join-Path $userProfile `
            '.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe'
        if (Test-Path -LiteralPath $bundledPython -PathType Leaf) {
            return [IO.Path]::GetFullPath($bundledPython)
        }
    }

    return $null
}

function Test-RouterTraceExactProperties {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string[]]$Names
    )

    if ($null -eq $Value) { return $false }
    [string[]]$actualNames = @($Value.PSObject.Properties.Name)
    if ($actualNames.Count -ne $Names.Count) { return $false }
    for ($index = 0; $index -lt $Names.Count; $index++) {
        if ($actualNames[$index] -cne $Names[$index]) { return $false }
    }
    return $true
}

function Stop-RouterTraceProcess {
    param(
        [Parameter(Mandatory)][Diagnostics.Process]$Process,
        [int]$WaitMilliseconds = 2000
    )

    try { $Process.StandardInput.Close() } catch { }
    try {
        if (-not $Process.HasExited) {
            try { $Process.Kill($true) } catch { $Process.Kill() }
        }
    } catch { }
    try { $null = $Process.WaitForExit($WaitMilliseconds) } catch { }
}

function Write-RouterTrace {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Trace,
        [string]$DatabasePath = (
            Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) `
                'data/router.sqlite'
        ),
        [AllowNull()][string]$PythonExecutable,
        [AllowNull()][string]$StorageHelperPath,
        [ValidateRange(100, 300000)][int]$TimeoutMilliseconds = 30000
    )

    $resolvedPython = Resolve-RouterPythonExecutable -PythonExecutable $PythonExecutable
    if ($null -eq $resolvedPython) {
        return New-RouterTraceStorageError -Code 'python_unavailable' `
            -Detail 'python_executable_not_found' `
            -Message 'A Python 3 executable is required for SQLite trace storage.'
    }

    if ([string]::IsNullOrWhiteSpace($StorageHelperPath)) {
        $StorageHelperPath = Join-Path (Split-Path -Parent $PSScriptRoot) `
            'storage/sqlite_store.py'
    }
    try {
        $helperPath = [IO.Path]::GetFullPath($StorageHelperPath)
    } catch {
        return New-RouterTraceStorageError -Code 'storage_helper_unavailable' `
            -Detail 'sqlite_store_not_found' `
            -Message 'The SQLite trace helper is unavailable.'
    }
    if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
        return New-RouterTraceStorageError -Code 'storage_helper_unavailable' `
            -Detail 'sqlite_store_not_found' `
            -Message 'The SQLite trace helper is unavailable.'
    }

    try {
        $resolvedDatabasePath = [IO.Path]::GetFullPath($DatabasePath)
    } catch {
        return New-RouterTraceStorageError -Code 'database_path_invalid' `
            -Detail 'database_path_resolution_failed' `
            -Message 'The SQLite database path is invalid.'
    }

    try {
        $traceJson = ConvertTo-Json -InputObject $Trace -Depth 100 -Compress -ErrorAction Stop
    } catch {
        return New-RouterTraceStorageError -Code 'trace_serialization_error' `
            -Detail 'trace_json_serialization_failed' `
            -Message 'The complete trace could not be serialized.'
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $resolvedPython
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.ArgumentList.Add('-B')
    $startInfo.ArgumentList.Add($helperPath)
    $startInfo.ArgumentList.Add('--database')
    $startInfo.ArgumentList.Add($resolvedDatabasePath)

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $completedSafely = $false
    try {
        if (-not $process.Start()) {
            return New-RouterTraceStorageError -Code 'storage_process_error' `
                -Detail 'python_process_not_started' `
                -Message 'The SQLite trace helper could not be started.'
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $stdinTask = $process.StandardInput.WriteAsync($traceJson)
        $stdinClosed = $false
        $clock = [Diagnostics.Stopwatch]::StartNew()

        while ($clock.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
            if (-not $stdinClosed -and $stdinTask.IsCompleted) {
                try {
                    $null = $stdinTask.GetAwaiter().GetResult()
                } catch {
                    Stop-RouterTraceProcess -Process $process
                    return New-RouterTraceStorageError -Code 'storage_process_error' `
                        -Detail 'stdin_write_failed' `
                        -Message 'The SQLite trace helper stopped before trace input completed.'
                }
                try {
                    $process.StandardInput.Close()
                    $stdinClosed = $true
                } catch {
                    Stop-RouterTraceProcess -Process $process
                    return New-RouterTraceStorageError -Code 'storage_process_error' `
                        -Detail 'stdin_write_failed' `
                        -Message 'The SQLite trace helper input stream could not be closed.'
                }
            }

            if ($process.HasExited -and -not $stdinClosed) {
                try { $process.StandardInput.Close() } catch { }
                $stdinClosed = $true
            }

            if ($process.HasExited -and $stdinTask.IsCompleted -and `
                $stdoutTask.IsCompleted -and $stderrTask.IsCompleted) {
                break
            }

            $remaining = $TimeoutMilliseconds - [int]$clock.ElapsedMilliseconds
            if ($remaining -le 0) { break }
            $slice = [Math]::Min(25, $remaining)
            try { $null = $process.WaitForExit($slice) } catch { }
        }
        $clock.Stop()

        if (-not ($process.HasExited -and $stdinTask.IsCompleted -and `
            $stdoutTask.IsCompleted -and $stderrTask.IsCompleted)) {
            Stop-RouterTraceProcess -Process $process
            return New-RouterTraceStorageError -Code 'storage_timeout' `
                -Detail 'python_process_timeout' `
                -Message 'The SQLite trace helper exceeded its bounded timeout.'
        }

        try {
            $null = $stdinTask.GetAwaiter().GetResult()
        } catch {
            Stop-RouterTraceProcess -Process $process
            return New-RouterTraceStorageError -Code 'storage_process_error' `
                -Detail 'stdin_write_failed' `
                -Message 'The SQLite trace helper stopped before trace input completed.'
        }
        try {
            $stdout = $stdoutTask.GetAwaiter().GetResult()
        } catch {
            Stop-RouterTraceProcess -Process $process
            return New-RouterTraceStorageError -Code 'storage_process_error' `
                -Detail 'stdout_read_failed' `
                -Message 'The SQLite trace helper output could not be read.'
        }
        try {
            $stderrOutput = $stderrTask.GetAwaiter().GetResult()
        } catch {
            Stop-RouterTraceProcess -Process $process
            return New-RouterTraceStorageError -Code 'storage_process_error' `
                -Detail 'stderr_read_failed' `
                -Message 'The SQLite trace helper diagnostics could not be read.'
        }
        $exitCode = $process.ExitCode
        $completedSafely = $true
    } catch {
        Stop-RouterTraceProcess -Process $process
        return New-RouterTraceStorageError -Code 'storage_process_error' `
            -Detail 'python_process_failed' `
            -Message 'The SQLite trace helper process failed safely.'
    } finally {
        if (-not $completedSafely) {
            Stop-RouterTraceProcess -Process $process
        }
        $process.Dispose()
    }

    if ([string]::IsNullOrWhiteSpace($stdout)) {
        return New-RouterTraceStorageError -Code 'storage_protocol_error' `
            -Detail 'writer_output_missing' `
            -Message 'The SQLite trace helper returned no structured result.'
    }
    try {
        $result = ConvertFrom-Json -InputObject $stdout -Depth 100 -ErrorAction Stop
    } catch {
        return New-RouterTraceStorageError -Code 'storage_protocol_error' `
            -Detail 'writer_output_invalid' `
            -Message 'The SQLite trace helper returned an invalid structured result.'
    }

    $successShape = Test-RouterTraceExactProperties -Value $result `
        -Names @('ok', 'trace_id', 'candidate_evaluations_inserted')
    $errorShape = Test-RouterTraceExactProperties -Value $result -Names @('ok', 'error')
    if ($successShape) {
        $count = $result.candidate_evaluations_inserted
        $integerCount = $count -is [byte] -or $count -is [sbyte] -or `
            $count -is [int16] -or $count -is [uint16] -or `
            $count -is [int32] -or $count -is [uint32] -or `
            $count -is [int64] -or $count -is [uint64]
        if ($result.ok -isnot [bool] -or -not $result.ok -or `
            $result.trace_id -isnot [string] -or `
            [string]::IsNullOrWhiteSpace($result.trace_id) -or `
            -not $integerCount -or $count -lt 0) {
            $successShape = $false
        }
    } elseif ($errorShape) {
        $errorShape = $result.ok -is [bool] -and -not $result.ok -and `
            (Test-RouterTraceExactProperties -Value $result.error `
                -Names @('code', 'detail', 'path', 'message'))
        if ($errorShape) {
            foreach ($name in @('code', 'detail', 'path', 'message')) {
                if ($result.error.$name -isnot [string] -or `
                    [string]::IsNullOrWhiteSpace($result.error.$name)) {
                    $errorShape = $false
                    break
                }
            }
        }
    }
    if (-not $successShape -and -not $errorShape) {
        return New-RouterTraceStorageError -Code 'storage_protocol_error' `
            -Detail 'writer_result_shape_invalid' `
            -Message 'The SQLite trace helper returned an unsupported result shape.'
    }
    if (($exitCode -eq 0) -ne $successShape) {
        return New-RouterTraceStorageError -Code 'storage_protocol_error' `
            -Detail 'writer_exit_status_mismatch' `
            -Message 'The SQLite trace helper returned conflicting status information.'
    }
    if (-not [string]::IsNullOrWhiteSpace($stderrOutput)) {
        return New-RouterTraceStorageError -Code 'storage_protocol_error' `
            -Detail 'writer_diagnostic_channel_used' `
            -Message 'The SQLite trace helper used an unsupported diagnostic channel.'
    }

    return $result
}
