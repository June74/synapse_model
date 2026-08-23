function New-RouterCatalogError {
    param(
        [Parameter(Mandatory)][string]$Code,
        [AllowNull()][string]$File,
        [AllowNull()][string]$Path,
        [AllowNull()][string]$Identity,
        [Parameter(Mandatory)][string]$Message
    )

    return [pscustomobject][ordered]@{
        code = $Code
        file = $File
        path = $Path
        identity = $Identity
        message = $Message
    }
}

function Sort-RouterCatalogObjectsOrdinal {
    param(
        [AllowEmptyCollection()][object[]]$Values,
        [Parameter(Mandatory)][scriptblock]$KeySelector
    )

    $byKey = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    [string[]]$keys = @(
        for ($index = 0; $index -lt $Values.Count; $index++) {
            $key = '{0}|{1:D10}' -f ([string](& $KeySelector $Values[$index])), $index
            $byKey.Add($key, $Values[$index])
            $key
        }
    )
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    return @($keys | ForEach-Object { $byKey[$_] })
}

function Find-RouterDuplicateJsonPropertyPath {
    param(
        [Parameter(Mandatory)][Text.Json.JsonElement]$Element,
        [string]$Path = '$'
    )

    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            $propertyPath = '{0}.{1}' -f $Path, $property.Name
            if (-not $names.Add($property.Name)) { return $propertyPath }
            $nested = @(Find-RouterDuplicateJsonPropertyPath -Element $property.Value -Path $propertyPath)
            if ($nested.Count -gt 0) { return $nested[0] }
        }
    } elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($item in $Element.EnumerateArray()) {
            $nested = @(Find-RouterDuplicateJsonPropertyPath -Element $item -Path ('{0}[{1}]' -f $Path, $index))
            if ($nested.Count -gt 0) { return $nested[0] }
            $index++
        }
    }
    return @()
}

function Read-RouterCatalogJson {
    param([Parameter(Mandatory)][string]$FilePath)

    try {
        $text = [IO.File]::ReadAllText($FilePath)
        $document = [Text.Json.JsonDocument]::Parse($text)
        try {
            $duplicatePath = @(Find-RouterDuplicateJsonPropertyPath -Element $document.RootElement)
            if ($duplicatePath.Count -gt 0) {
                return [pscustomobject]@{ valid = $false; value = $null; path = $duplicatePath[0]; message = 'Duplicate JSON property names are not allowed.' }
            }
        } finally {
            $document.Dispose()
        }
        $value = $text | ConvertFrom-Json -Depth 100 -ErrorAction Stop
        if ($null -eq $value) { throw 'JSON document is null.' }
        return [pscustomobject]@{ valid = $true; value = $value; path = '$'; message = '' }
    } catch {
        return [pscustomobject]@{ valid = $false; value = $null; path = '$'; message = 'The file is not valid unambiguous JSON.' }
    }
}

function Test-RouterCatalogNonnegativeNumber {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or $Value -is [bool]) { return $false }
    if ($Value -isnot [byte] -and $Value -isnot [sbyte] -and
        $Value -isnot [int16] -and $Value -isnot [uint16] -and
        $Value -isnot [int32] -and $Value -isnot [uint32] -and
        $Value -isnot [int64] -and $Value -isnot [uint64] -and
        $Value -isnot [single] -and $Value -isnot [double] -and
        $Value -isnot [decimal] -and $Value -isnot [Numerics.BigInteger]) { return $false }
    if ($Value -is [double] -and ([double]::IsNaN($Value) -or [double]::IsInfinity($Value))) { return $false }
    if ($Value -is [single] -and ([single]::IsNaN($Value) -or [single]::IsInfinity($Value))) { return $false }
    return $Value -ge 0
}

function Test-RouterCatalogPositiveInteger {
    param([AllowNull()][object]$Value)

    if (-not (Test-RouterCatalogNonnegativeNumber $Value)) { return $false }
    try { return $Value -ge 1 -and [decimal]$Value -eq [decimal]::Truncate([decimal]$Value) } catch { return $false }
}

function Import-RouterProfileCatalog {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$ProfilesRoot,
        [Parameter(Mandatory)][string]$MatrixPath,
        [Parameter(Mandatory)][string]$ProfileSchemaPath
    )

    if ($null -eq (Get-Command Test-RouterSchema -ErrorAction SilentlyContinue)) {
        . (Join-Path $PSScriptRoot 'schema.ps1')
    }

    $errors = [Collections.Generic.List[object]]::new()
    $loaded = [Collections.Generic.List[object]]::new()
    $matrixRead = Read-RouterCatalogJson -FilePath $MatrixPath
    if (-not $matrixRead.valid) {
        $errors.Add((New-RouterCatalogError -Code 'matrix_json_invalid' -File $MatrixPath -Path $matrixRead.path -Identity $null -Message $matrixRead.message))
        return [pscustomobject]@{ valid = $false; profiles = @(); errors = @($errors) }
    }

    $candidates = @($matrixRead.value.candidates | Where-Object { $_.enabled -and $_.candidate_kind -ceq 'model' })
    [string[]]$profileFiles = @()
    if (Test-Path -LiteralPath $ProfilesRoot -PathType Container) {
        [string[]]$profileFiles = @(Get-ChildItem -LiteralPath $ProfilesRoot -Recurse -File -Filter '*.json' | ForEach-Object { $_.FullName })
        [Array]::Sort($profileFiles, [StringComparer]::Ordinal)
    }

    foreach ($profileFile in $profileFiles) {
        $relativeFile = [IO.Path]::GetRelativePath($ProfilesRoot, $profileFile).Replace('\', '/')
        $read = Read-RouterCatalogJson -FilePath $profileFile
        if (-not $read.valid) {
            $errors.Add((New-RouterCatalogError -Code 'profile_json_invalid' -File $relativeFile -Path $read.path -Identity $null -Message $read.message))
            continue
        }

        $profile = $read.value
        $launcher = if ($profile.PSObject.Properties.Name -ccontains 'launcher') { [string]$profile.launcher } else { '' }
        $configurationId = if ($profile.PSObject.Properties.Name -ccontains 'configuration_id') { [string]$profile.configuration_id } else { '' }
        $identity = if ($launcher -and $configurationId) { '{0}|{1}' -f $launcher, $configurationId } else { $null }
        $schemaResult = Test-RouterSchema -Value $profile -SchemaPath $ProfileSchemaPath
        if (-not $schemaResult.valid) {
            $firstSchemaError = @($schemaResult.errors)[0]
            $errors.Add((New-RouterCatalogError -Code 'profile_schema_invalid' -File $relativeFile -Path $firstSchemaError.path -Identity $identity -Message ('Profile schema validation failed: {0}.' -f $firstSchemaError.code)))
            continue
        }

        $loaded.Add([pscustomobject]@{ profile = $profile; file = $relativeFile; identity = $identity })
    }

    $byIdentity = [Collections.Generic.Dictionary[string, Collections.Generic.List[object]]]::new([StringComparer]::Ordinal)
    foreach ($entry in $loaded) {
        if (-not $byIdentity.ContainsKey($entry.identity)) { $byIdentity.Add($entry.identity, [Collections.Generic.List[object]]::new()) }
        $byIdentity[$entry.identity].Add($entry)
    }
    foreach ($identity in $byIdentity.Keys) {
        if ($byIdentity[$identity].Count -gt 1) {
            [string[]]$duplicateFiles = @($byIdentity[$identity] | ForEach-Object { $_.file })
            [Array]::Sort($duplicateFiles, [StringComparer]::Ordinal)
            $errors.Add((New-RouterCatalogError -Code 'duplicate_profile_identity' -File ($duplicateFiles -join ',') -Path '$.configuration_id' -Identity $identity -Message 'More than one profile uses this launcher and configuration ID.'))
        }
    }

    $expectedIdentities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($candidate in $candidates) {
        $effort = if ($candidate.PSObject.Properties.Name -ccontains 'effort') { [string]$candidate.effort } else { 'default' }
        $configurationId = '{0}__{1}' -f $candidate.model, $effort
        $identity = '{0}|{1}' -f $candidate.tool, $configurationId
        $null = $expectedIdentities.Add($identity)
        if (-not $byIdentity.ContainsKey($identity)) {
            $errors.Add((New-RouterCatalogError -Code 'profile_coverage_missing' -File $null -Path '$' -Identity $identity -Message 'No checked-in profile covers this enabled normal matrix candidate.'))
            continue
        }
        if ($byIdentity[$identity].Count -ne 1) { continue }

        $entry = $byIdentity[$identity][0]
        $profile = $entry.profile
        if ($profile.launcher -cne $candidate.tool -or $profile.provider -cne $candidate.provider -or
            $profile.model -cne $candidate.model -or $profile.effort -cne $effort -or
            $profile.configuration_id -cne $configurationId -or -not $profile.enabled) {
            $errors.Add((New-RouterCatalogError -Code 'candidate_profile_mismatch' -File $entry.file -Path '$' -Identity $identity -Message 'Profile fields do not exactly match the enabled matrix candidate.'))
        }
    }
    foreach ($identity in $byIdentity.Keys) {
        if (-not $expectedIdentities.Contains($identity)) {
            $entry = $byIdentity[$identity][0]
            $errors.Add((New-RouterCatalogError -Code 'profile_coverage_unexpected' -File $entry.file -Path '$' -Identity $identity -Message 'Profile does not map to an enabled normal matrix candidate.'))
        }
    }

    foreach ($entry in $loaded) {
        $profile = $entry.profile
        $pricingValid = if ($profile.pricing.cost_comparable) {
            (Test-RouterCatalogNonnegativeNumber $profile.pricing.input_usd_per_million_tokens) -and
                (Test-RouterCatalogNonnegativeNumber $profile.pricing.output_usd_per_million_tokens)
        } else {
            $null -eq $profile.pricing.input_usd_per_million_tokens -and $null -eq $profile.pricing.output_usd_per_million_tokens
        }
        if (-not $pricingValid) {
            $errors.Add((New-RouterCatalogError -Code 'profile_pricing_invalid' -File $entry.file -Path '$.pricing' -Identity $entry.identity -Message 'Comparable pricing requires finite nonnegative rates; non-comparable pricing requires two null rates.'))
        }

        $latency = $profile.latency_observation
        $latencyValid = if ($latency.available) {
            -not [string]::IsNullOrWhiteSpace([string]$latency.metric) -and
                (Test-RouterCatalogNonnegativeNumber $latency.milliseconds) -and
                (Test-RouterCatalogPositiveInteger $latency.sample_count) -and
                -not [string]::IsNullOrWhiteSpace([string]$latency.observed_on)
        } else {
            $null -eq $latency.metric -and $null -eq $latency.milliseconds -and $null -eq $latency.sample_count -and $null -eq $latency.observed_on
        }
        if (-not $latencyValid) {
            $errors.Add((New-RouterCatalogError -Code 'profile_latency_invalid' -File $entry.file -Path '$.latency_observation' -Identity $entry.identity -Message 'Available latency requires complete measurements; unavailable latency requires null measurement fields.'))
        }
    }

    $validEntries = @(
        $loaded | Where-Object {
            $entryIdentity = $_.identity
            @($errors | Where-Object { $_.identity -ceq $entryIdentity -and $_.code -in @('duplicate_profile_identity', 'candidate_profile_mismatch', 'profile_coverage_unexpected', 'profile_pricing_invalid', 'profile_latency_invalid') }).Count -eq 0
        }
    )
    $sortedEntries = @(Sort-RouterCatalogObjectsOrdinal -Values $validEntries -KeySelector { param($entry) $entry.identity })
    $sortedErrors = @(Sort-RouterCatalogObjectsOrdinal -Values @($errors) -KeySelector {
        param($error)
        '{0}|{1}|{2}|{3}' -f $error.code, $error.file, $error.identity, $error.path
    })
    return [pscustomobject]@{
        valid = $sortedErrors.Count -eq 0
        profiles = @($sortedEntries | ForEach-Object { $_.profile })
        errors = $sortedErrors
    }
}
