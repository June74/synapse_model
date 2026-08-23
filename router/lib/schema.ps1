$script:RouterSchemaContextCache = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)

function Get-RouterExactProperty {
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $Object) { return $null }
    foreach ($property in $Object.PSObject.Properties) {
        if ([string]::Equals($property.Name, $Name, [StringComparison]::Ordinal)) { return $property }
    }
    return $null
}

function Test-RouterJsonNumber {
    param([AllowNull()][object]$Value)

    if (
        $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
        $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or
        $Value -is [Numerics.BigInteger] -or $Value -is [decimal]
    ) { return $true }
    if ($Value -is [single]) {
        return -not [single]::IsNaN($Value) -and -not [single]::IsInfinity($Value)
    }
    if ($Value -is [double]) {
        return -not [double]::IsNaN($Value) -and -not [double]::IsInfinity($Value)
    }
    return $false
}

function Test-RouterScalarEqual {
    param([AllowNull()][object]$Left, [AllowNull()][object]$Right)

    if ($null -eq $Left -or $null -eq $Right) { return $null -eq $Left -and $null -eq $Right }
    if ($Left -is [string] -and $Right -is [string]) {
        return [string]::Equals($Left, $Right, [StringComparison]::Ordinal)
    }
    if ($Left -is [bool] -and $Right -is [bool]) { return $Left -eq $Right }
    return $false
}

function Find-RouterJsonDomainError {
    param(
        [AllowNull()][object]$Value,
        [string]$Path = '$',
        [Collections.Generic.List[object]]$Ancestors = [Collections.Generic.List[object]]::new()
    )

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool] -or (Test-RouterJsonNumber $Value)) {
        return $null
    }
    if (
        ($Value -is [single] -and ([single]::IsNaN($Value) -or [single]::IsInfinity($Value))) -or
        ($Value -is [double] -and ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)))
    ) { return [pscustomobject]@{ code = 'value_not_json'; path = $Path } }

    $isArray = $Value -is [Collections.IList] -and $Value -isnot [string]
    $isObject = $Value -is [pscustomobject]
    if (-not $isArray -and -not $isObject) {
        return [pscustomobject]@{ code = 'value_not_json'; path = $Path }
    }
    foreach ($ancestor in $Ancestors) {
        if ([object]::ReferenceEquals($ancestor, $Value)) {
            return [pscustomobject]@{ code = 'value_not_json'; path = $Path }
        }
    }

    $Ancestors.Add($Value)
    try {
        if ($isArray) {
            for ($index = 0; $index -lt $Value.Count; $index++) {
                $error = Find-RouterJsonDomainError $Value[$index] ('{0}[{1}]' -f $Path, $index) $Ancestors
                if ($null -ne $error) { return $error }
            }
        } else {
            foreach ($property in $Value.PSObject.Properties) {
                $propertyPath = '{0}.{1}' -f $Path, $property.Name
                if ($property.MemberType -ne [Management.Automation.PSMemberTypes]::NoteProperty) {
                    return [pscustomobject]@{ code = 'value_not_json'; path = $propertyPath }
                }
                $error = Find-RouterJsonDomainError $property.Value $propertyPath $Ancestors
                if ($null -ne $error) { return $error }
            }
        }
    } finally {
        $Ancestors.RemoveAt($Ancestors.Count - 1)
    }
    return $null
}

function Test-RouterJsonInteger {
    param([AllowNull()][object]$Value)

    if (
        $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
        $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or $Value -is [Numerics.BigInteger]
    ) { return $true }
    if ($Value -is [decimal]) { return [decimal]::Truncate($Value) -eq $Value }
    if ($Value -is [single] -or $Value -is [double]) {
        return (Test-RouterJsonNumber $Value) -and [Math]::Truncate([double]$Value) -eq [double]$Value
    }
    return $false
}

function Get-RouterSchemaStructureErrors {
    param([Parameter(Mandatory)][pscustomobject]$Schema)

    $errors = [Collections.Generic.List[object]]::new()
    # V1 is intentionally limited to the keyword and value forms used by the three router schemas.
    $supportedKeywords = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    @(
        '$schema', '$id', 'title', 'type', 'properties', 'required', 'additionalProperties',
        'items', 'minLength', 'minItems', 'minimum', 'enum', 'const', 'oneOf', 'anyOf',
        'not', 'uniqueItems', 'default', 'x-error-code'
    ) | ForEach-Object { $null = $supportedKeywords.Add($_) }
    $supportedTypes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    @('null', 'object', 'array', 'string', 'boolean', 'integer', 'number') |
        ForEach-Object { $null = $supportedTypes.Add($_) }
    $isDiscriminatorSafeOneOf = {
        param([AllowNull()][object]$Branches)

        if ($Branches -isnot [Collections.IList] -or $Branches -is [string] -or $Branches.Count -lt 2) {
            return $false
        }
        foreach ($branch in $Branches) {
            if ($branch -isnot [pscustomobject]) { return $false }
            $branchType = Get-RouterExactProperty $branch 'type'
            $branchProperties = Get-RouterExactProperty $branch 'properties'
            $branchRequired = Get-RouterExactProperty $branch 'required'
            if (
                $null -eq $branchType -or $branchType.Value -isnot [string] -or $branchType.Value -cne 'object' -or
                $null -eq $branchProperties -or $branchProperties.Value -isnot [pscustomobject] -or
                $null -eq $branchRequired -or $branchRequired.Value -isnot [Collections.IList]
            ) { return $false }
        }

        $firstProperties = (Get-RouterExactProperty $Branches[0] 'properties').Value
        foreach ($candidateName in $firstProperties.PSObject.Properties.Name) {
            $allBranchesUseCandidate = $true
            $seenValues = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($branch in $Branches) {
                $requiredNames = (Get-RouterExactProperty $branch 'required').Value
                if (@($requiredNames | Where-Object { $_ -is [string] -and $_ -ceq $candidateName }).Count -ne 1) {
                    $allBranchesUseCandidate = $false
                    break
                }
                $propertySchema = Get-RouterExactProperty (Get-RouterExactProperty $branch 'properties').Value $candidateName
                if ($null -eq $propertySchema -or $propertySchema.Value -isnot [pscustomobject]) {
                    $allBranchesUseCandidate = $false
                    break
                }
                $constProperty = Get-RouterExactProperty $propertySchema.Value 'const'
                $enumProperty = Get-RouterExactProperty $propertySchema.Value 'enum'
                $branchValues = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                if ($null -ne $constProperty -and $constProperty.Value -is [string]) {
                    $null = $branchValues.Add($constProperty.Value)
                } elseif (
                    $null -ne $enumProperty -and $enumProperty.Value -is [Collections.IList] -and
                    $enumProperty.Value -isnot [string] -and $enumProperty.Value.Count -gt 0
                ) {
                    foreach ($value in $enumProperty.Value) {
                        if ($value -isnot [string]) { $allBranchesUseCandidate = $false; break }
                        $null = $branchValues.Add($value)
                    }
                } else {
                    $allBranchesUseCandidate = $false
                }
                if (-not $allBranchesUseCandidate) { break }
                foreach ($value in $branchValues) {
                    if (-not $seenValues.Add($value)) { $allBranchesUseCandidate = $false; break }
                }
                if (-not $allBranchesUseCandidate) { break }
            }
            if ($allBranchesUseCandidate) { return $true }
        }
        return $false
    }
    $visit = $null
    $visit = {
        param([AllowNull()][object]$Node, [string]$Path, [bool]$MinimumAllowed)

        if ($null -eq $Node -or $Node.GetType() -ne [Management.Automation.PSCustomObject]) {
            $errors.Add([pscustomobject]@{ code = 'schema_invalid'; path = $Path })
            return
        }

        foreach ($nodeProperty in $Node.PSObject.Properties) {
            if (-not $supportedKeywords.Contains($nodeProperty.Name)) {
                $errors.Add([pscustomobject]@{ code = 'schema_invalid'; path = ('{0}.{1}' -f $Path, $nodeProperty.Name) })
            }
        }

        foreach ($metadataName in @('$schema', '$id', 'title', 'x-error-code')) {
            $property = Get-RouterExactProperty $Node $metadataName
            if ($null -ne $property -and $property.Value -isnot [string]) {
                $errors.Add([pscustomobject]@{ code = 'schema_invalid'; path = ('{0}.{1}' -f $Path, $metadataName) })
            }
        }

        $typeProperty = Get-RouterExactProperty $Node 'type'
        if ($null -ne $typeProperty) {
            if ($typeProperty.Value -is [string]) {
                if (-not $supportedTypes.Contains($typeProperty.Value)) {
                    $errors.Add([pscustomobject]@{ code = 'schema_invalid'; path = ('{0}.type' -f $Path) })
                }
            } elseif ($typeProperty.Value -is [Collections.IList]) {
                if ($typeProperty.Value.Count -eq 0) {
                    $errors.Add([pscustomobject]@{ code = 'schema_invalid'; path = ('{0}.type' -f $Path) })
                } else {
                    $seenTypeNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                    for ($index = 0; $index -lt $typeProperty.Value.Count; $index++) {
                        $typeName = $typeProperty.Value[$index]
                        if ($typeName -isnot [string] -or -not $supportedTypes.Contains($typeName) -or -not $seenTypeNames.Add($typeName)) {
                            $errors.Add([pscustomobject]@{ code = 'schema_invalid'; path = ('{0}.type[{1}]' -f $Path, $index) })
                        }
                    }
                }
            } else {
                $errors.Add([pscustomobject]@{ code = 'schema_invalid'; path = ('{0}.type' -f $Path) })
            }
        }

        $requiredProperty = Get-RouterExactProperty $Node 'required'
        if ($null -ne $requiredProperty) {
            if ($requiredProperty.Value -isnot [Collections.IList] -or $requiredProperty.Value -is [string]) {
                $errors.Add([pscustomobject]@{ code = 'schema_invalid'; path = ('{0}.required' -f $Path) })
            } else {
                $seenRequiredNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                for ($index = 0; $index -lt $requiredProperty.Value.Count; $index++) {
                    $requiredName = $requiredProperty.Value[$index]
                    if ($requiredName -isnot [string] -or -not $seenRequiredNames.Add($requiredName)) {
                        $errors.Add([pscustomobject]@{ code = 'schema_invalid'; path = ('{0}.required[{1}]' -f $Path, $index) })
                    }
                }
            }
        }

        $enumProperty = Get-RouterExactProperty $Node 'enum'
        if ($null -ne $enumProperty -and ($enumProperty.Value -isnot [Collections.IList] -or $enumProperty.Value -is [string])) {
            $errors.Add([pscustomobject]@{ code = 'schema_invalid'; path = ('{0}.enum' -f $Path) })
        } elseif ($null -ne $enumProperty -and $enumProperty.Value.Count -eq 0) {
            $errors.Add([pscustomobject]@{ code = 'schema_invalid'; path = ('{0}.enum' -f $Path) })
        } elseif ($null -ne $enumProperty) {
            for ($index = 0; $index -lt $enumProperty.Value.Count; $index++) {
                if ($enumProperty.Value[$index] -isnot [string]) {
                    $errors.Add([pscustomobject]@{ code = 'schema_invalid'; path = ('{0}.enum[{1}]' -f $Path, $index) })
                }
            }
        }

        $constProperty = Get-RouterExactProperty $Node 'const'
        if ($null -ne $constProperty -and $constProperty.Value -isnot [string] -and $constProperty.Value -isnot [bool]) {
            $errors.Add([pscustomobject]@{ code = 'schema_invalid'; path = ('{0}.const' -f $Path) })
        }

        $defaultProperty = Get-RouterExactProperty $Node 'default'
        if ($null -ne $defaultProperty) {
            $emptyArrayDefault = (
                $defaultProperty.Value -is [Collections.IList] -and
                $defaultProperty.Value -isnot [string] -and
                $defaultProperty.Value.Count -eq 0
            )
            if ($defaultProperty.Value -isnot [string] -and -not $emptyArrayDefault) {
                $errors.Add([pscustomobject]@{ code = 'schema_invalid'; path = ('{0}.default' -f $Path) })
            }
        }

        $propertiesProperty = Get-RouterExactProperty $Node 'properties'
        if ($null -ne $propertiesProperty) {
            if ($null -eq $propertiesProperty.Value -or $propertiesProperty.Value.GetType() -ne [Management.Automation.PSCustomObject]) {
                $errors.Add([pscustomobject]@{ code = 'schema_invalid'; path = ('{0}.properties' -f $Path) })
            } else {
                foreach ($propertySchema in $propertiesProperty.Value.PSObject.Properties) {
                    & $visit $propertySchema.Value ('{0}.properties.{1}' -f $Path, $propertySchema.Name) $MinimumAllowed
                }
            }
        }
        foreach ($combinerName in @('oneOf', 'anyOf')) {
            $property = Get-RouterExactProperty $Node $combinerName
            if ($null -ne $property) {
                $combinerPath = '{0}.{1}' -f $Path, $combinerName
                if ($property.Value -isnot [Collections.IList] -or $property.Value -is [string] -or $property.Value.Count -eq 0) {
                    $errors.Add([pscustomobject]@{ code = 'schema_invalid'; path = $combinerPath })
                } else {
                    $branchMinimumAllowed = (
                        $MinimumAllowed -and $combinerName -ceq 'oneOf' -and
                        (& $isDiscriminatorSafeOneOf $property.Value)
                    )
                    for ($index = 0; $index -lt $property.Value.Count; $index++) {
                        & $visit $property.Value[$index] ('{0}[{1}]' -f $combinerPath, $index) $branchMinimumAllowed
                    }
                }
            }
        }
        $itemsProperty = Get-RouterExactProperty $Node 'items'
        if ($null -ne $itemsProperty) { & $visit $itemsProperty.Value ('{0}.items' -f $Path) $MinimumAllowed }
        $notProperty = Get-RouterExactProperty $Node 'not'
        if ($null -ne $notProperty) { & $visit $notProperty.Value ('{0}.not' -f $Path) $false }

        $minimumProperty = Get-RouterExactProperty $Node 'minimum'
        if ($null -ne $minimumProperty) {
            $approvedMinimum = (
                $MinimumAllowed -and
                (Test-RouterJsonInteger $minimumProperty.Value) -and
                ($minimumProperty.Value -eq 0 -or $minimumProperty.Value -eq 1)
            )
            if (-not $approvedMinimum) {
                $errors.Add([pscustomobject]@{ code = 'schema_invalid'; path = ('{0}.minimum' -f $Path) })
            }
        }
        foreach ($limitName in @('minLength', 'minItems')) {
            $property = Get-RouterExactProperty $Node $limitName
            if ($null -ne $property -and (-not (Test-RouterJsonInteger $property.Value) -or $property.Value -ne 1)) {
                $errors.Add([pscustomobject]@{ code = 'schema_invalid'; path = ('{0}.{1}' -f $Path, $limitName) })
            }
        }
        $additionalProperty = Get-RouterExactProperty $Node 'additionalProperties'
        if ($null -ne $additionalProperty -and $additionalProperty.Value -isnot [bool]) {
            $errors.Add([pscustomobject]@{ code = 'schema_invalid'; path = ('{0}.additionalProperties' -f $Path) })
        }

        $uniqueProperty = Get-RouterExactProperty $Node 'uniqueItems'
        if ($null -ne $uniqueProperty) {
            if ($uniqueProperty.Value -isnot [bool] -or -not $uniqueProperty.Value) {
                $errors.Add([pscustomobject]@{ code = 'schema_invalid'; path = ('{0}.uniqueItems' -f $Path) })
            } else {
                $itemsProperty = Get-RouterExactProperty $Node 'items'
                $arrayType = $null -ne $typeProperty -and $typeProperty.Value -is [string] -and $typeProperty.Value -ceq 'array'
                $stringItems = $false
                if ($null -ne $itemsProperty -and $null -ne $itemsProperty.Value -and $itemsProperty.Value.GetType() -eq [Management.Automation.PSCustomObject]) {
                    $itemType = Get-RouterExactProperty $itemsProperty.Value 'type'
                    $itemConst = Get-RouterExactProperty $itemsProperty.Value 'const'
                    $itemEnum = Get-RouterExactProperty $itemsProperty.Value 'enum'
                    $stringItems = (
                        ($null -ne $itemType -and $itemType.Value -is [string] -and $itemType.Value -ceq 'string') -or
                        ($null -ne $itemConst -and $itemConst.Value -is [string]) -or
                        ($null -ne $itemEnum -and @($itemEnum.Value | Where-Object { $_ -isnot [string] }).Count -eq 0)
                    )
                }
                if (-not $arrayType -or -not $stringItems) {
                    $errors.Add([pscustomobject]@{ code = 'schema_invalid'; path = ('{0}.uniqueItems' -f $Path) })
                }
            }
        }
    }

    & $visit $Schema '$' $true
    return @($errors)
}

function Get-RouterSchemaContext {
    param([Parameter(Mandatory)][string]$SchemaPath)

    try {
        if (-not (Test-Path -LiteralPath $SchemaPath -PathType Leaf)) {
            return [pscustomobject]@{ error_code = 'schema_not_found' }
        }
        $file = Get-Item -LiteralPath $SchemaPath -ErrorAction Stop
        $canonicalPath = $file.FullName
        $cached = $null
        if ($script:RouterSchemaContextCache.TryGetValue($canonicalPath, [ref]$cached)) {
            if ($cached.Item2 -eq $file.LastWriteTimeUtc.Ticks -and $cached.Item3 -eq $file.Length) {
                return [pscustomobject]@{
                    error_code = $null
                    last_write_ticks = $cached.Item2
                    length = $cached.Item3
                    schema_text = $cached.Item1
                }
            }
        }

        $schemaText = Get-Content -Raw -LiteralPath $canonicalPath -ErrorAction Stop
        $context = [pscustomobject]@{
            error_code = $null
            last_write_ticks = $file.LastWriteTimeUtc.Ticks
            length = $file.Length
            schema_text = $schemaText
        }
        if ($script:RouterSchemaContextCache.Count -ge 16 -and -not $script:RouterSchemaContextCache.ContainsKey($canonicalPath)) {
            $script:RouterSchemaContextCache.Clear()
        }
        $script:RouterSchemaContextCache[$canonicalPath] = [Tuple[string, long, long]]::new(
            $schemaText,
            $file.LastWriteTimeUtc.Ticks,
            $file.Length
        )
        return $context
    } catch {
        return [pscustomobject]@{ error_code = 'schema_invalid' }
    }
}

function Get-RouterDiagnosticBranchIndex {
    param([Parameter(Mandatory)][pscustomobject]$Candidate, [Parameter(Mandatory)][object[]]$Branches)

    foreach ($candidateProperty in $Candidate.PSObject.Properties) {
        $matches = [Collections.Generic.List[int]]::new()
        $allBranchesDiscriminate = $true
        for ($index = 0; $index -lt $Branches.Count; $index++) {
            $properties = Get-RouterExactProperty $Branches[$index] 'properties'
            $propertySchema = if ($null -ne $properties) { Get-RouterExactProperty $properties.Value $candidateProperty.Name }
            if ($null -eq $propertySchema) { $allBranchesDiscriminate = $false; break }
            $constProperty = Get-RouterExactProperty $propertySchema.Value 'const'
            $enumProperty = Get-RouterExactProperty $propertySchema.Value 'enum'
            if ($null -eq $constProperty -and $null -eq $enumProperty) { $allBranchesDiscriminate = $false; break }

            $matched = $false
            if ($null -ne $constProperty) {
                $matched = Test-RouterScalarEqual $candidateProperty.Value $constProperty.Value
            } else {
                foreach ($allowed in @($enumProperty.Value)) {
                    if (Test-RouterScalarEqual $candidateProperty.Value $allowed) { $matched = $true; break }
                }
            }
            if ($matched) { $matches.Add($index) }
        }
        if ($allBranchesDiscriminate -and $matches.Count -eq 1) { return $matches[0] }
    }
    return -1
}

function Add-RouterMinimumErrors {
    param(
        [AllowNull()][object]$Candidate,
        [Parameter(Mandatory)][pscustomobject]$Schema,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Errors
    )

    $minimumProperty = Get-RouterExactProperty $Schema 'minimum'
    if (
        $null -ne $minimumProperty -and
        (Test-RouterJsonNumber $Candidate) -and
        $Candidate -lt $minimumProperty.Value
    ) {
        $Errors.Add([pscustomobject]@{ code = 'number_below_minimum'; path = $Path })
    }

    $oneOfProperty = Get-RouterExactProperty $Schema 'oneOf'
    if ($null -ne $oneOfProperty -and $Candidate -is [pscustomobject]) {
        [object[]]$branches = @($oneOfProperty.Value)
        $branchIndex = Get-RouterDiagnosticBranchIndex $Candidate $branches
        if ($branchIndex -ge 0) {
            Add-RouterMinimumErrors $Candidate $branches[$branchIndex] $Path $Errors
        }
    }

    $propertiesProperty = Get-RouterExactProperty $Schema 'properties'
    if ($null -ne $propertiesProperty -and $Candidate -is [pscustomobject]) {
        foreach ($propertySchema in $propertiesProperty.Value.PSObject.Properties) {
            $candidateProperty = Get-RouterExactProperty $Candidate $propertySchema.Name
            if ($null -ne $candidateProperty) {
                Add-RouterMinimumErrors $candidateProperty.Value $propertySchema.Value ('{0}.{1}' -f $Path, $propertySchema.Name) $Errors
            }
        }
    }

    $itemsProperty = Get-RouterExactProperty $Schema 'items'
    if ($null -ne $itemsProperty -and $Candidate -is [Collections.IList] -and $Candidate -isnot [string]) {
        for ($index = 0; $index -lt $Candidate.Count; $index++) {
            Add-RouterMinimumErrors $Candidate[$index] $itemsProperty.Value ('{0}[{1}]' -f $Path, $index) $Errors
        }
    }
}

function Test-RouterDiagnosticType {
    param([AllowNull()][object]$Candidate, [Parameter(Mandatory)][string]$ExpectedType)

    switch ($ExpectedType) {
        'null' { return $null -eq $Candidate }
        'object' { return $Candidate -is [pscustomobject] }
        'array' { return $Candidate -is [Collections.IList] -and $Candidate -isnot [string] }
        'string' { return $Candidate -is [string] }
        'boolean' { return $Candidate -is [bool] }
        'integer' { return Test-RouterJsonInteger $Candidate }
        'number' { return Test-RouterJsonNumber $Candidate }
        default { return $false }
    }
}

function Add-RouterProjectDiagnostics {
    param(
        [AllowNull()][object]$Candidate,
        [Parameter(Mandatory)][pscustomobject]$Schema,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Errors
    )

    $oneOfProperty = Get-RouterExactProperty $Schema 'oneOf'
    if ($null -ne $oneOfProperty) {
        [object[]]$branches = @($oneOfProperty.Value)
        $branchIndex = if ($Candidate -is [pscustomobject]) { Get-RouterDiagnosticBranchIndex $Candidate $branches } else { -1 }
        if ($branchIndex -ge 0) {
            Add-RouterProjectDiagnostics $Candidate $branches[$branchIndex] $Path $Errors
            return
        }
        $branchResults = [Collections.Generic.List[object]]::new()
        foreach ($branch in $branches) {
            $branchErrors = [Collections.Generic.List[object]]::new()
            Add-RouterProjectDiagnostics $Candidate $branch $Path $branchErrors
            $branchResults.Add([pscustomobject]@{ errors = $branchErrors })
        }
        $best = @($branchResults | Sort-Object { $_.errors.Count })[0]
        foreach ($error in $best.errors) { $Errors.Add($error) }
        return
    }

    $notProperty = Get-RouterExactProperty $Schema 'not'
    $customCode = Get-RouterExactProperty $Schema 'x-error-code'
    if ($null -ne $notProperty -and $null -ne $customCode) {
        try {
            $candidateJson = ConvertTo-Json -InputObject $Candidate -Depth 100 -Compress -WarningAction Stop -ErrorAction Stop
            $notSchemaJson = ConvertTo-Json -InputObject $notProperty.Value -Depth 100 -Compress -WarningAction Stop -ErrorAction Stop
            $notMatched = [bool](Test-Json -Json $candidateJson -Schema $notSchemaJson -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)
        } catch { $notMatched = $false }
        if ($notMatched) {
            $Errors.Add([pscustomobject]@{ code = [string]$customCode.Value; path = $Path })
            return
        }
    }

    $typeProperty = Get-RouterExactProperty $Schema 'type'
    if ($null -ne $typeProperty) {
        $typeMatched = $false
        foreach ($expectedType in @($typeProperty.Value)) {
            if (Test-RouterDiagnosticType $Candidate ([string]$expectedType)) {
                $typeMatched = $true
                break
            }
        }
        if (-not $typeMatched) {
            $Errors.Add([pscustomobject]@{ code = 'type_mismatch'; path = $Path })
            return
        }
    }

    if ($Candidate -is [pscustomobject]) {
        $requiredProperty = Get-RouterExactProperty $Schema 'required'
        if ($null -ne $requiredProperty) {
            foreach ($requiredName in @($requiredProperty.Value)) {
                if ($null -eq (Get-RouterExactProperty $Candidate ([string]$requiredName))) {
                    $Errors.Add([pscustomobject]@{ code = 'required_property_missing'; path = ('{0}.{1}' -f $Path, $requiredName) })
                }
            }
        }
        $propertiesProperty = Get-RouterExactProperty $Schema 'properties'
        if ($null -ne $propertiesProperty) {
            foreach ($propertySchema in $propertiesProperty.Value.PSObject.Properties) {
                $candidateProperty = Get-RouterExactProperty $Candidate $propertySchema.Name
                if ($null -ne $candidateProperty) {
                    Add-RouterProjectDiagnostics $candidateProperty.Value $propertySchema.Value ('{0}.{1}' -f $Path, $propertySchema.Name) $Errors
                }
            }
        }
        $additionalProperty = Get-RouterExactProperty $Schema 'additionalProperties'
        if ($null -ne $additionalProperty -and $additionalProperty.Value -eq $false) {
            $allowedNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            if ($null -ne $propertiesProperty) {
                foreach ($name in $propertiesProperty.Value.PSObject.Properties.Name) { $null = $allowedNames.Add($name) }
            }
            foreach ($property in $Candidate.PSObject.Properties) {
                if (-not $allowedNames.Contains($property.Name)) {
                    $Errors.Add([pscustomobject]@{ code = 'additional_property_not_allowed'; path = ('{0}.{1}' -f $Path, $property.Name) })
                }
            }
        }
    }

    $enumProperty = Get-RouterExactProperty $Schema 'enum'
    if ($null -ne $enumProperty) {
        $matched = $false
        foreach ($allowed in @($enumProperty.Value)) {
            if (Test-RouterScalarEqual $Candidate $allowed) { $matched = $true; break }
        }
        if (-not $matched) {
            $codeProperty = Get-RouterExactProperty $Schema 'x-error-code'
            $code = if ($null -ne $codeProperty) { [string]$codeProperty.Value } else { 'enum_value_not_allowed' }
            $Errors.Add([pscustomobject]@{ code = $code; path = $Path })
        }
    }
    $itemsProperty = Get-RouterExactProperty $Schema 'items'
    if ($null -ne $itemsProperty -and $Candidate -is [Collections.IList]) {
        for ($index = 0; $index -lt $Candidate.Count; $index++) {
            Add-RouterProjectDiagnostics $Candidate[$index] $itemsProperty.Value ('{0}[{1}]' -f $Path, $index) $Errors
        }
    }
}

function Test-RouterSchema {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$SchemaPath
    )

    $context = Get-RouterSchemaContext $SchemaPath
    if ($null -ne $context.error_code) {
        return [pscustomobject]@{ valid = $false; errors = @([pscustomobject]@{ code = $context.error_code; path = '$' }) }
    }
    $schemaText = $context.schema_text
    try {
        $schema = $schemaText | ConvertFrom-Json -Depth 100 -ErrorAction Stop
        if ($null -eq $schema -or $schema.GetType() -ne [Management.Automation.PSCustomObject]) {
            return [pscustomobject]@{ valid = $false; errors = @([pscustomobject]@{ code = 'schema_invalid'; path = '$' }) }
        }
        $schemaErrors = @(Get-RouterSchemaStructureErrors $schema)
    } catch {
        return [pscustomobject]@{ valid = $false; errors = @([pscustomobject]@{ code = 'schema_invalid'; path = '$' }) }
    }
    if ($schemaErrors.Count -gt 0) { return [pscustomobject]@{ valid = $false; errors = $schemaErrors } }

    $domainError = Find-RouterJsonDomainError $Value
    if ($null -ne $domainError) { return [pscustomobject]@{ valid = $false; errors = @($domainError) } }
    try {
        $candidateJson = ConvertTo-Json -InputObject $Value -Depth 100 -Compress -WarningAction Stop -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ valid = $false; errors = @([pscustomobject]@{ code = 'value_not_json'; path = '$' }) }
    }

    try {
        $builtInErrors = @()
        $builtInValid = [bool](Test-Json -Json $candidateJson -Schema $schemaText -ErrorAction SilentlyContinue -ErrorVariable +builtInErrors -WarningAction SilentlyContinue)
    } catch {
        return [pscustomobject]@{ valid = $false; errors = @([pscustomobject]@{ code = 'schema_invalid'; path = '$' }) }
    }

    $minimumErrors = [Collections.Generic.List[object]]::new()
    $minimumGuardFailed = $false
    try {
        Add-RouterMinimumErrors $Value $schema '$' $minimumErrors
    } catch {
        $minimumGuardFailed = $true
    }

    $diagnostics = [Collections.Generic.List[object]]::new()
    if (-not $builtInValid) {
        try { Add-RouterProjectDiagnostics $Value $schema '$' $diagnostics } catch { $diagnostics.Clear() }
    }

    $errors = [Collections.Generic.List[object]]::new()
    $seenErrors = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($error in @($minimumErrors) + @($diagnostics)) {
        $identity = '{0}|{1}' -f $error.code, $error.path
        if ($seenErrors.Add($identity)) { $errors.Add($error) }
    }
    if ($errors.Count -gt 0) { return [pscustomobject]@{ valid = $false; errors = @($errors) } }
    if ($minimumGuardFailed -or -not $builtInValid) {
        return [pscustomobject]@{ valid = $false; errors = @([pscustomobject]@{ code = 'schema_validation_failed'; path = '$' }) }
    }
    return [pscustomobject]@{ valid = $true; errors = @() }
}
