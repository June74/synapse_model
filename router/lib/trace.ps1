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

function Write-RouterTrace {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Trace,
        [string]$DatabasePath = (
            Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) `
                'data/router.sqlite'
        ),
        [AllowNull()][string]$PythonExecutable
    )

    $resolvedPython = Resolve-RouterPythonExecutable -PythonExecutable $PythonExecutable
    if ($null -eq $resolvedPython) {
        return New-RouterTraceStorageError -Code 'python_unavailable' `
            -Detail 'python_executable_not_found' `
            -Message 'A Python 3 executable is required for SQLite trace storage.'
    }

    $helperPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'storage/sqlite_store.py'
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
    $startInfo.ArgumentList.Add([IO.Path]::GetFullPath($helperPath))
    $startInfo.ArgumentList.Add('--database')
    $startInfo.ArgumentList.Add($resolvedDatabasePath)

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            return New-RouterTraceStorageError -Code 'storage_process_error' `
                -Detail 'python_process_not_started' `
                -Message 'The SQLite trace helper could not be started.'
        }
        $process.StandardInput.Write($traceJson)
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderrOutput = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    } catch {
        return New-RouterTraceStorageError -Code 'storage_process_error' `
            -Detail 'python_process_failed' `
            -Message 'The SQLite trace helper process failed safely.'
    } finally {
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

    $okProperty = $result.PSObject.Properties | Where-Object { $_.Name -ceq 'ok' } |
        Select-Object -First 1
    if ($null -eq $okProperty -or $okProperty.Value -isnot [bool]) {
        return New-RouterTraceStorageError -Code 'storage_protocol_error' `
            -Detail 'writer_result_shape_invalid' `
            -Message 'The SQLite trace helper returned an unsupported result shape.'
    }
    if ($exitCode -eq 0 -and -not $result.ok) {
        return New-RouterTraceStorageError -Code 'storage_protocol_error' `
            -Detail 'writer_exit_status_mismatch' `
            -Message 'The SQLite trace helper returned conflicting status information.'
    }
    if ($exitCode -ne 0 -and $result.ok) {
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
