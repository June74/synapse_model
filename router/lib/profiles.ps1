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

function Get-RouterCatalogQualityPaths {
    $qualityKeys = [ordered]@{
        task_types = @('general', 'coding', 'math', 'reasoning', 'writing', 'summarization', 'extraction', 'research_synthesis')
        domains = @('general', 'computer_science', 'mathematics', 'physics', 'chemistry', 'biology', 'medicine', 'engineering', 'social_science', 'humanities', 'business', 'finance', 'law')
        complexities = @('low', 'medium', 'high')
        capabilities = @('instruction_following', 'reasoning', 'structured_output', 'factual_reliability', 'source_grounded_synthesis', 'long_context')
    }
    return @(
        foreach ($mapName in $qualityKeys.Keys) {
            foreach ($qualityKey in $qualityKeys[$mapName]) { '$.quality.{0}.{1}' -f $mapName, $qualityKey }
        }
    )
}

function Import-RouterProfileCatalog {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$ProfilesRoot,
        [Parameter(Mandatory)][string]$MatrixPath,
        [Parameter(Mandatory)][string]$ProfileSchemaPath,
        [Parameter(Mandatory)][string]$PricingSnapshotPath,
        [Parameter(Mandatory)][string]$QualitySnapshotPath
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

    $pricingRead = Read-RouterCatalogJson -FilePath $PricingSnapshotPath
    if (-not $pricingRead.valid) {
        $errors.Add((New-RouterCatalogError -Code 'pricing_snapshot_json_invalid' -File $PricingSnapshotPath -Path $pricingRead.path -Identity $null -Message $pricingRead.message))
        return [pscustomobject]@{ valid = $false; profiles = @(); errors = @($errors) }
    }
    $pricingSnapshot = $pricingRead.value
    if ($pricingSnapshot.PSObject.Properties.Name -cnotcontains 'schedules' -or
        $pricingSnapshot.PSObject.Properties.Name -cnotcontains 'snapshot_date' -or
        $pricingSnapshot.PSObject.Properties.Name -cnotcontains 'currency' -or
        $pricingSnapshot.PSObject.Properties.Name -cnotcontains 'rate_unit') {
        $errors.Add((New-RouterCatalogError -Code 'pricing_snapshot_invalid' -File $PricingSnapshotPath -Path '$' -Identity $null -Message 'Pricing snapshot lacks required catalog fields.'))
        return [pscustomobject]@{ valid = $false; profiles = @(); errors = @($errors) }
    }

    $pricingByProfileModel = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $scheduleIndex = 0
    foreach ($schedule in @($pricingSnapshot.schedules)) {
        $schedulePath = '$.schedules[{0}]' -f $scheduleIndex
        $scheduleIndex++
        if ($null -eq $schedule -or
            $schedule.PSObject.Properties.Name -cnotcontains 'provider' -or
            $schedule.PSObject.Properties.Name -cnotcontains 'model' -or
            $schedule.PSObject.Properties.Name -cnotcontains 'profile_models' -or
            $schedule.PSObject.Properties.Name -cnotcontains 'cost_comparable' -or
            $schedule.PSObject.Properties.Name -cnotcontains 'rate_periods' -or
            $schedule.cost_comparable -isnot [bool] -or
            @($schedule.profile_models).Count -eq 0) {
            $errors.Add((New-RouterCatalogError -Code 'pricing_snapshot_invalid' -File $PricingSnapshotPath -Path $schedulePath -Identity $null -Message 'Pricing schedule is incomplete.'))
            continue
        }
        foreach ($profileModel in @($schedule.profile_models)) {
            if ([string]::IsNullOrWhiteSpace([string]$profileModel)) {
                $errors.Add((New-RouterCatalogError -Code 'pricing_snapshot_invalid' -File $PricingSnapshotPath -Path ($schedulePath + '.profile_models') -Identity $null -Message 'Pricing schedule contains a blank profile model.'))
            } elseif ($pricingByProfileModel.ContainsKey([string]$profileModel)) {
                $errors.Add((New-RouterCatalogError -Code 'pricing_snapshot_duplicate_model' -File $PricingSnapshotPath -Path ($schedulePath + '.profile_models') -Identity ([string]$profileModel) -Message 'More than one pricing schedule applies to this profile model.'))
            } else {
                $pricingByProfileModel.Add([string]$profileModel, $schedule)
            }
        }
    }
    if ($errors.Count -gt 0) {
        $sortedSnapshotErrors = @(Sort-RouterCatalogObjectsOrdinal -Values @($errors) -KeySelector {
            param($error)
            '{0}|{1}|{2}|{3}' -f $error.code, $error.file, $error.identity, $error.path
        })
        return [pscustomobject]@{ valid = $false; profiles = @(); errors = $sortedSnapshotErrors }
    }

    $qualityRead = Read-RouterCatalogJson -FilePath $QualitySnapshotPath
    if (-not $qualityRead.valid) {
        $errors.Add((New-RouterCatalogError -Code 'quality_snapshot_json_invalid' -File $QualitySnapshotPath -Path $qualityRead.path -Identity $null -Message $qualityRead.message))
        return [pscustomobject]@{ valid = $false; profiles = @(); errors = @($errors) }
    }
    $qualitySnapshot = $qualityRead.value
    $requiredQualitySnapshotFields = @('snapshot_date', 'retrieved_on', 'methodology_url', 'policy', 'records')
    $missingQualitySnapshotFields = @($requiredQualitySnapshotFields | Where-Object { $qualitySnapshot.PSObject.Properties.Name -cnotcontains $_ })
    if ($missingQualitySnapshotFields.Count -gt 0 -or
        [string]::IsNullOrWhiteSpace([string]$qualitySnapshot.snapshot_date) -or
        [string]::IsNullOrWhiteSpace([string]$qualitySnapshot.retrieved_on) -or
        [string]::IsNullOrWhiteSpace([string]$qualitySnapshot.methodology_url) -or
        [string]::IsNullOrWhiteSpace([string]$qualitySnapshot.policy) -or
        $qualitySnapshot.records -isnot [Collections.IList]) {
        $errors.Add((New-RouterCatalogError -Code 'quality_snapshot_invalid' -File $QualitySnapshotPath -Path '$' -Identity $null -Message 'Quality snapshot lacks required top-level fields.'))
        return [pscustomobject]@{ valid = $false; profiles = @(); errors = @($errors) }
    }

    $allowedQualityPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($qualityPath in @(Get-RouterCatalogQualityPaths)) { $null = $allowedQualityPaths.Add($qualityPath) }
    $qualityByIdentity = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $qualityAuthorizationsByIdentity = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $duplicateQualityIdentities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $qualityRecordIndex = 0
    foreach ($qualityRecord in @($qualitySnapshot.records)) {
        $recordPath = '$.records[{0}]' -f $qualityRecordIndex
        $qualityRecordIndex++
        $requiredRecordFields = @(
            'launcher', 'configuration_id', 'model', 'effort', 'source_url', 'retrieved_on',
            'exact_model_match', 'exact_effort_match', 'benchmark_slice', 'provisional_category',
            'quality_authorizations', 'note'
        )
        $recordMissingFields = if ($null -eq $qualityRecord) { $requiredRecordFields } else {
            @($requiredRecordFields | Where-Object { $qualityRecord.PSObject.Properties.Name -cnotcontains $_ })
        }
        $identity = if ($null -ne $qualityRecord -and
            $qualityRecord.PSObject.Properties.Name -ccontains 'launcher' -and
            $qualityRecord.PSObject.Properties.Name -ccontains 'configuration_id') {
            '{0}|{1}' -f $qualityRecord.launcher, $qualityRecord.configuration_id
        } else { $null }
        $recordValid = $recordMissingFields.Count -eq 0
        $authorizationByPath = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        if ($recordValid) {
            foreach ($stringField in @('launcher', 'configuration_id', 'model', 'effort', 'source_url', 'retrieved_on', 'benchmark_slice', 'note')) {
                if ([string]::IsNullOrWhiteSpace([string]$qualityRecord.$stringField)) { $recordValid = $false }
            }
            if ($qualityRecord.exact_model_match -isnot [bool] -or $qualityRecord.exact_effort_match -isnot [bool] -or
                $qualityRecord.provisional_category -cnotin @('unknown', 'standard', 'strong', 'frontier')) {
                $recordValid = $false
            }
            if ($qualityRecord.quality_authorizations -isnot [Collections.IList]) {
                $errors.Add((New-RouterCatalogError -Code 'quality_snapshot_authorization_invalid' -File $QualitySnapshotPath -Path ($recordPath + '.quality_authorizations') -Identity $identity -Message 'Quality authorizations must be an array of exact path, slice, category, and evidence-kind bindings.'))
            } else {
                $authorizationIndex = 0
                foreach ($authorization in @($qualityRecord.quality_authorizations)) {
                    $authorizationPath = '{0}.quality_authorizations[{1}]' -f $recordPath, $authorizationIndex
                    $authorizationIndex++
                    $requiredAuthorizationFields = @('path', 'benchmark_slice', 'category', 'evidence_kind')
                    $missingAuthorizationFields = if ($null -eq $authorization) { $requiredAuthorizationFields } else {
                        @($requiredAuthorizationFields | Where-Object { $authorization.PSObject.Properties.Name -cnotcontains $_ })
                    }
                    $authorizationValid = $missingAuthorizationFields.Count -eq 0
                    if ($authorizationValid) {
                        foreach ($stringField in $requiredAuthorizationFields) {
                            if ([string]::IsNullOrWhiteSpace([string]$authorization.$stringField)) { $authorizationValid = $false }
                        }
                        if (-not $allowedQualityPaths.Contains([string]$authorization.path)) { $authorizationValid = $false }
                        if ($authorization.evidence_kind -ceq 'artificial_analysis') {
                            if ($authorization.category -cnotin @('standard', 'strong', 'frontier') -or
                                -not $qualityRecord.exact_model_match -or -not $qualityRecord.exact_effort_match -or
                                $qualityRecord.benchmark_slice -ceq 'unavailable' -or
                                $authorization.benchmark_slice -cne $qualityRecord.benchmark_slice -or
                                $authorization.category -cne $qualityRecord.provisional_category) {
                                $authorizationValid = $false
                            }
                        } elseif ($authorization.evidence_kind -ceq 'provider') {
                            if ($authorization.category -cne 'unsupported' -or $authorization.benchmark_slice -cne 'provider_capability') {
                                $authorizationValid = $false
                            }
                        } else {
                            $authorizationValid = $false
                        }
                    }
                    if (-not $authorizationValid) {
                        $errors.Add((New-RouterCatalogError -Code 'quality_snapshot_authorization_invalid' -File $QualitySnapshotPath -Path $authorizationPath -Identity $identity -Message 'Quality authorization is malformed or contradicts its record-level evidence.'))
                        continue
                    }
                    if ($authorizationByPath.ContainsKey([string]$authorization.path)) {
                        $errors.Add((New-RouterCatalogError -Code 'duplicate_quality_authorization_path' -File $QualitySnapshotPath -Path $authorizationPath -Identity $identity -Message 'More than one quality authorization targets the same exact path.'))
                        continue
                    }
                    $authorizationByPath.Add([string]$authorization.path, $authorization)
                }
            }
            if ($qualityRecord.provisional_category -cin @('standard', 'strong', 'frontier') -and
                (-not $qualityRecord.exact_model_match -or -not $qualityRecord.exact_effort_match -or
                    [string]::Equals([string]$qualityRecord.benchmark_slice, 'unavailable', [StringComparison]::OrdinalIgnoreCase))) {
                $recordValid = $false
            }
        }
        if (-not $recordValid) {
            $errors.Add((New-RouterCatalogError -Code 'quality_snapshot_record_invalid' -File $QualitySnapshotPath -Path $recordPath -Identity $identity -Message 'Quality snapshot record is incomplete or internally inconsistent.'))
            continue
        }
        if ($qualityByIdentity.ContainsKey($identity)) {
            if ($duplicateQualityIdentities.Add($identity)) {
                $errors.Add((New-RouterCatalogError -Code 'duplicate_quality_snapshot_identity' -File $QualitySnapshotPath -Path $recordPath -Identity $identity -Message 'More than one quality snapshot record uses this composite identity.'))
            }
        } else {
            $qualityByIdentity.Add($identity, $qualityRecord)
            $qualityAuthorizationsByIdentity.Add($identity, $authorizationByPath)
        }
    }
    if ($errors.Count -gt 0) {
        $sortedQualityErrors = @(Sort-RouterCatalogObjectsOrdinal -Values @($errors) -KeySelector {
            param($error)
            '{0}|{1}|{2}|{3}' -f $error.code, $error.file, $error.identity, $error.path
        })
        return [pscustomobject]@{ valid = $false; profiles = @(); errors = $sortedQualityErrors }
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
    foreach ($identity in $expectedIdentities) {
        if (-not $qualityByIdentity.ContainsKey($identity)) {
            $errors.Add((New-RouterCatalogError -Code 'quality_snapshot_record_missing' -File $QualitySnapshotPath -Path '$.records' -Identity $identity -Message 'No quality snapshot record covers this enabled matrix candidate.'))
        }
    }
    foreach ($identity in $qualityByIdentity.Keys) {
        if (-not $expectedIdentities.Contains($identity)) {
            $errors.Add((New-RouterCatalogError -Code 'quality_snapshot_record_unexpected' -File $QualitySnapshotPath -Path '$.records' -Identity $identity -Message 'Quality snapshot record does not map to an enabled matrix candidate.'))
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

        $pricingSnapshotValid = $false
        if ($pricingByProfileModel.ContainsKey([string]$profile.model)) {
            $schedule = $pricingByProfileModel[[string]$profile.model]
            if ($schedule.provider -ceq $profile.provider -and
                $profile.pricing_snapshot_date -ceq $pricingSnapshot.snapshot_date -and
                $profile.pricing.currency -ceq $pricingSnapshot.currency -and
                $profile.pricing.rate_unit -ceq $pricingSnapshot.rate_unit -and
                $profile.pricing.cost_comparable -eq $schedule.cost_comparable) {
                if (-not $schedule.cost_comparable) {
                    $pricingSnapshotValid = @($schedule.rate_periods).Count -eq 0 -and
                        $null -eq $profile.pricing.input_usd_per_million_tokens -and
                        $null -eq $profile.pricing.output_usd_per_million_tokens -and
                        $profile.pricing.effective_from -ceq $pricingSnapshot.snapshot_date -and
                        $null -eq $profile.pricing.effective_through
                } else {
                    $matchingPeriods = @(
                        $schedule.rate_periods | Where-Object {
                            $_.input_tokens_min -eq 0 -and
                            $_.effective_from -ceq $profile.pricing.effective_from -and
                            (($null -eq $_.effective_through -and $null -eq $profile.pricing.effective_through) -or
                                ($null -ne $_.effective_through -and $_.effective_through -ceq $profile.pricing.effective_through))
                        }
                    )
                    if ($matchingPeriods.Count -eq 1) {
                        $pricingSnapshotValid = $profile.pricing.input_usd_per_million_tokens -eq $matchingPeriods[0].input_usd_per_million_tokens -and
                            $profile.pricing.output_usd_per_million_tokens -eq $matchingPeriods[0].output_usd_per_million_tokens
                    }
                }
            }
        }
        if (-not $pricingSnapshotValid) {
            $errors.Add((New-RouterCatalogError -Code 'profile_pricing_snapshot_mismatch' -File $entry.file -Path '$.pricing' -Identity $entry.identity -Message 'Profile pricing does not exactly match its applicable dated pricing schedule.'))
        }

        $artificialAnalysis = $profile.evidence.artificial_analysis
        $qualitySnapshotValid = $false
        if ($qualityByIdentity.ContainsKey($entry.identity)) {
            $qualityRecord = $qualityByIdentity[$entry.identity]
            $qualitySnapshotValid = $profile.quality_snapshot_date -ceq $qualitySnapshot.snapshot_date -and
                $profile.launcher -ceq $qualityRecord.launcher -and
                $profile.configuration_id -ceq $qualityRecord.configuration_id -and
                $profile.model -ceq $qualityRecord.model -and
                $profile.effort -ceq $qualityRecord.effort -and
                $artificialAnalysis.source_url -ceq $qualityRecord.source_url -and
                $artificialAnalysis.retrieved_on -ceq $qualityRecord.retrieved_on -and
                $artificialAnalysis.exact_model_match -eq $qualityRecord.exact_model_match -and
                $artificialAnalysis.exact_effort_match -eq $qualityRecord.exact_effort_match -and
                $artificialAnalysis.benchmark_slice -ceq $qualityRecord.benchmark_slice
            if ($qualitySnapshotValid) {
                $authorizationByPath = $qualityAuthorizationsByIdentity[$entry.identity]
                foreach ($mapName in @('task_types', 'domains', 'complexities', 'capabilities')) {
                    foreach ($qualityProperty in $profile.quality.$mapName.PSObject.Properties) {
                        $qualityPath = '$.quality.{0}.{1}' -f $mapName, $qualityProperty.Name
                        if ($qualityProperty.Value -ceq 'unknown') { continue }
                        if (-not $authorizationByPath.ContainsKey($qualityPath)) {
                            $qualitySnapshotValid = $false
                            continue
                        }
                        $authorization = $authorizationByPath[$qualityPath]
                        if ($qualityProperty.Value -ceq 'unsupported') {
                            if ($authorization.category -cne 'unsupported' -or
                                $authorization.evidence_kind -cne 'provider' -or
                                $authorization.benchmark_slice -cne 'provider_capability') {
                                $qualitySnapshotValid = $false
                            }
                        } elseif ($qualityProperty.Value -cin @('standard', 'strong', 'frontier')) {
                            if ($authorization.category -cne $qualityProperty.Value -or
                                $authorization.evidence_kind -cne 'artificial_analysis' -or
                                $authorization.benchmark_slice -cne $qualityRecord.benchmark_slice -or
                                -not $qualityRecord.exact_model_match -or -not $qualityRecord.exact_effort_match) {
                                $qualitySnapshotValid = $false
                            }
                        } else {
                            $qualitySnapshotValid = $false
                        }
                    }
                }
            }
        }
        if (-not $qualitySnapshotValid -and $qualityByIdentity.ContainsKey($entry.identity)) {
            $errors.Add((New-RouterCatalogError -Code 'profile_quality_snapshot_mismatch' -File $entry.file -Path '$.quality' -Identity $entry.identity -Message 'Profile quality or embedded evidence does not match its authoritative quality snapshot record.'))
        }
        $benchmarkEvidenceEligible = $artificialAnalysis.exact_model_match -and
            $artificialAnalysis.exact_effort_match -and
            -not [string]::IsNullOrWhiteSpace([string]$artificialAnalysis.benchmark_slice) -and
            -not [string]::Equals([string]$artificialAnalysis.benchmark_slice, 'unavailable', [StringComparison]::OrdinalIgnoreCase)
        if (-not $benchmarkEvidenceEligible) {
            $measuredQualityPaths = [Collections.Generic.List[string]]::new()
            foreach ($mapName in @('task_types', 'domains', 'complexities', 'capabilities')) {
                foreach ($qualityProperty in $profile.quality.$mapName.PSObject.Properties) {
                    if ($qualityProperty.Value -cin @('standard', 'strong', 'frontier')) {
                        $measuredQualityPaths.Add(('$.quality.{0}.{1}' -f $mapName, $qualityProperty.Name))
                    }
                }
            }
            if ($measuredQualityPaths.Count -gt 0) {
                [string[]]$qualityPaths = @($measuredQualityPaths)
                [Array]::Sort($qualityPaths, [StringComparer]::Ordinal)
                $errors.Add((New-RouterCatalogError -Code 'profile_quality_evidence_invalid' -File $entry.file -Path $qualityPaths[0] -Identity $entry.identity -Message 'Measured quality requires exact model, exact effort, and a relevant benchmark slice; unknown and unsupported remain allowed without it.'))
            }
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
            @($errors | Where-Object { $_.identity -ceq $entryIdentity -and $_.code -in @('duplicate_profile_identity', 'candidate_profile_mismatch', 'profile_coverage_unexpected', 'profile_pricing_invalid', 'profile_pricing_snapshot_mismatch', 'profile_quality_snapshot_mismatch', 'profile_quality_evidence_invalid', 'profile_latency_invalid') }).Count -eq 0
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
