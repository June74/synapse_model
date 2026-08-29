# Shared fake launcher tree, lock and resolver for the offline Option 1 pilot suites.
#
# A pilot run prepares its launchers before the first provider call, and the default
# resolver looks up the installed agy, codex and claude executables and verifies them
# against the SHA-256 values pinned in calibration/pilots/option1-launchers-v1.json.
# No offline test host has those, so every suite that drives a full pilot run injects
# this fixture instead: a temporary launcher tree plus a lock generated from its own
# bytes. Dot-source this file, then pass -AllowPilotSourceOverridesForTest with the
# fixture lock path and New-TestCalibrationLauncherResolver.

function New-TestCalibrationLauncherFixture {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('router-calibration-test-{0}' -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    $anchors = [ordered]@{
        agy = Join-Path $root 'agy-bin'
        codex = Join-Path $root 'npm-bin'
        claude = Join-Path $root 'npm-bin'
    }
    $relative = [ordered]@{
        agy_native = 'agy.exe'
        codex_shim = 'codex.ps1'
        codex_javascript = 'node_modules/@openai/codex/bin/codex.js'
        codex_platform_manifest = 'node_modules/@openai/codex/node_modules/@openai/codex-win32-x64/package.json'
        codex_native = 'node_modules/@openai/codex/node_modules/@openai/codex-win32-x64/vendor/x86_64-pc-windows-msvc/bin/codex.exe'
        claude_shim = 'claude.ps1'
        claude_native = 'node_modules/@anthropic-ai/claude-code/bin/claude.exe'
    }
    $componentRole = [ordered]@{
        agy_native = 'agy'; codex_shim = 'codex'; codex_javascript = 'codex'
        codex_platform_manifest = 'codex'; codex_native = 'codex'
        claude_shim = 'claude'; claude_native = 'claude'
    }
    $paths = @{}
    foreach ($id in $relative.Keys) {
        $path = Join-Path $anchors[$componentRole[$id]] ($relative[$id].Replace('/', [IO.Path]::DirectorySeparatorChar))
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
        [IO.File]::WriteAllText($path, "fixture-$id", [Text.UTF8Encoding]::new($false))
        $paths[$id] = $path
    }
    function New-TestComponent([string]$Id, [string]$Kind, [string]$Purpose) {
        [pscustomobject][ordered]@{
            id = $Id; kind = $Kind; purpose = $Purpose
            locator = [pscustomobject][ordered]@{ anchor = 'resolved_launcher_dir'; relative_path = $relative[$Id] }
            sha256 = (Get-FileHash -LiteralPath $paths[$Id] -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $lock = [pscustomobject][ordered]@{
        lock_version = 'calibration-launcher-lock/v1'
        pilot_id = 'option1-three-launch-v1'
        roles = @(
            [pscustomobject][ordered]@{ ordinal = 1; role = 'candidate'; launcher = 'agy'; route_id = 'agy__gemini_3_7_flash_low__low'; components = @(
                (New-TestComponent 'agy_native' 'native_executable' 'executed')) }
            [pscustomobject][ordered]@{ ordinal = 2; role = 'judge_1'; launcher = 'codex'; route_id = 'codex__gpt_5_6_sol__max'; components = @(
                (New-TestComponent 'codex_shim' 'powershell_shim' 'provenance'),
                (New-TestComponent 'codex_javascript' 'javascript_entrypoint' 'provenance'),
                (New-TestComponent 'codex_platform_manifest' 'package_manifest' 'provenance'),
                (New-TestComponent 'codex_native' 'native_executable' 'executed')) }
            [pscustomobject][ordered]@{ ordinal = 3; role = 'judge_2'; launcher = 'claude'; route_id = 'claude__claude_opus_5__max'; components = @(
                (New-TestComponent 'claude_shim' 'powershell_shim' 'provenance'),
                (New-TestComponent 'claude_native' 'native_executable' 'executed')) }
        )
    }
    $lockPath = Join-Path $root 'launchers.json'
    $lock | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $lockPath -Encoding utf8NoBOM
    return [pscustomobject]@{ root = $root; anchors = $anchors; paths = $paths; lock = $lock; lock_path = $lockPath }
}

function New-TestCalibrationLauncherResolver {
    param([Parameter(Mandatory)][object]$Fixture)
    return {
        param($role, $lockRole)
        $anchor = [string]$Fixture.anchors[[string]$role.launcher]
        $componentId = [string]$lockRole.components[0].id
        return [pscustomobject][ordered]@{
            anchor_path = $anchor
            resolved_path = [IO.Path]::GetFullPath($Fixture.paths[$componentId])
        }
    }.GetNewClosure()
}

function Remove-TestCalibrationLauncherFixture {
    param([AllowNull()][object]$Fixture)
    if ($null -eq $Fixture) { return }
    if (Test-Path -LiteralPath $Fixture.root) { Remove-Item -LiteralPath $Fixture.root -Recurse -Force }
}

function Get-TestCalibrationPilotRunSummary {
    param([Parameter(Mandatory)][object]$Result)
    return ("run_state '{0}', stop_reason '{1}'" -f $Result.run_state, $Result.stop_reason)
}

function Assert-TestCalibrationPilotLaunchPrepared {
    param([Parameter(Mandatory)][object]$Result)
    if ($Result.stop_reason -ceq 'source_drift') {
        throw ("Pilot run stopped before any provider launch ({0}). Launcher preparation failed: this run needs an injected launcher fixture, lock and resolver." -f
            (Get-TestCalibrationPilotRunSummary -Result $Result))
    }
}
