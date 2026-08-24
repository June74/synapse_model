function Test-RouterCandidateQuality {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Candidate,
        [Parameter(Mandatory)][object]$Request,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RequiredCapabilities
    )

    $categoryRanks = @{
        standard = 0
        strong = 1
        frontier = 2
    }
    $relevantCategories = [Collections.Generic.List[object]]::new()
    $addRelevantCategory = {
        param(
            [Parameter(Mandatory)][string]$Key,
            [Parameter(Mandatory)][object]$Map,
            [Parameter(Mandatory)][string]$Name
        )

        $property = $Map.PSObject.Properties |
            Where-Object { $_.Name -ceq $Name } |
            Select-Object -First 1
        $category = if ($null -eq $property) { 'unknown' } else { [string]$property.Value }
        if ($category -cnotin @('unsupported', 'unknown', 'standard', 'strong', 'frontier')) {
            $category = 'unknown'
        }
        $relevantCategories.Add([pscustomobject][ordered]@{
            key = $Key
            category = $category
        })
    }

    & $addRelevantCategory ('task_type.{0}' -f $Request.task_type) `
        $Candidate.quality.task_types ([string]$Request.task_type)
    & $addRelevantCategory ('domain.{0}' -f $Request.domain) `
        $Candidate.quality.domains ([string]$Request.domain)
    & $addRelevantCategory ('complexity.{0}' -f $Request.complexity) `
        $Candidate.quality.complexities ([string]$Request.complexity)
    foreach ($capability in $RequiredCapabilities) {
        & $addRelevantCategory $capability $Candidate.quality.capabilities $capability
    }

    $unsupported = $relevantCategories |
        Where-Object { $_.category -ceq 'unsupported' } |
        Select-Object -First 1
    if ($null -ne $unsupported) {
        return [pscustomobject][ordered]@{
            candidate_identity = '{0}|{1}' -f $Candidate.launcher, $Candidate.configuration_id
            passed = $false
            reason_code = 'required_capability_unavailable'
            effective_quality = $null
            quality_bottleneck = $unsupported.key
            relevant_categories = @($relevantCategories)
        }
    }

    $unknown = $relevantCategories |
        Where-Object { $_.category -ceq 'unknown' } |
        Select-Object -First 1
    if ($null -ne $unknown) {
        return [pscustomobject][ordered]@{
            candidate_identity = '{0}|{1}' -f $Candidate.launcher, $Candidate.configuration_id
            passed = $false
            reason_code = 'quality_evidence_unknown'
            effective_quality = $null
            quality_bottleneck = $unknown.key
            relevant_categories = @($relevantCategories)
        }
    }

    $minimumRank = [int]::MaxValue
    $effectiveQuality = $null
    $qualityBottleneck = $null
    foreach ($entry in $relevantCategories) {
        $rank = [int]$categoryRanks[$entry.category]
        if ($rank -lt $minimumRank) {
            $minimumRank = $rank
            $effectiveQuality = $entry.category
            $qualityBottleneck = $entry.key
        }
    }

    $passed = $minimumRank -ge [int]$categoryRanks[[string]$Request.quality_floor]
    return [pscustomobject][ordered]@{
        candidate_identity = '{0}|{1}' -f $Candidate.launcher, $Candidate.configuration_id
        passed = $passed
        reason_code = if ($passed) { $null } else { 'quality_floor_not_met' }
        effective_quality = $effectiveQuality
        quality_bottleneck = $qualityBottleneck
        relevant_categories = @($relevantCategories)
    }
}
