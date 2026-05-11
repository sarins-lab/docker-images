param(
    [string]$Images,
    [string]$Trivy = 'trivy',
    [string]$CacheDir = '.trivy-cache',
    [string]$ResultsDir = '.trivy/results',
    [string]$IgnoreFile = '.trivyignore',
    [object]$Severity = 'UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL',
    [object]$Scanners = 'vuln',
    [string]$IgnoreUnfixed = 'false',
    [int]$ExitCode = 1
)

$ErrorActionPreference = 'Stop'

function Exit-WithError {
    param(
        [string]$Message,
        [int]$Code
    )

    [Console]::Error.WriteLine("ERROR: $Message")
    exit $Code
}

function ConvertTo-Bool {
    param([object]$Value)

    if ($Value -is [bool]) {
        return $Value
    }
    if ($null -eq $Value) {
        return $false
    }

    $normalized = ([string]$Value).Trim().ToLowerInvariant()
    return @('1', 'true', 'yes', 'y', 'on') -contains $normalized
}

function ConvertTo-CsvList {
    param([object]$Value)

    $items = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @($Value)) {
        if ($null -eq $entry) {
            continue
        }

        foreach ($part in ([string]$entry -split '[,\s]+')) {
            $text = $part.Trim()
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $items.Add($text)
            }
        }
    }

    return ($items -join ',')
}

function Get-ObjectProperty {
    param(
        [object]$InputObject,
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function ConvertTo-MarkdownCell {
    param([object]$Value)

    if ($null -eq $Value) {
        return '-'
    }

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return '-'
    }

    return ($text -replace '\r?\n', ' ' -replace '\|', '\|')
}

function ConvertTo-MarkdownLink {
    param(
        [string]$Text,
        [string]$Url
    )

    $label = ConvertTo-MarkdownCell $Text
    if ([string]::IsNullOrWhiteSpace($Url)) {
        return $label
    }

    $safeUrl = $Url.Trim() -replace '\)', '%29'
    return "[$label]($safeUrl)"
}

function Get-SeverityRank {
    param([string]$Severity)

    switch (($Severity ?? 'UNKNOWN').ToUpperInvariant()) {
        'CRITICAL' { return 5 }
        'HIGH' { return 4 }
        'MEDIUM' { return 3 }
        'LOW' { return 2 }
        default { return 1 }
    }
}

function Get-SafeFileName {
    param([string]$Value)

    return ($Value -replace '[^A-Za-z0-9._-]', '_')
}

function Get-TrivyFindings {
    param(
        [object]$Scan,
        [string]$Image
    )

    $findings = @()
    foreach ($result in @(Get-ObjectProperty $Scan 'Results')) {
        if ($null -eq $result) {
            continue
        }

        $target = Get-ObjectProperty $result 'Target'
        $type = Get-ObjectProperty $result 'Type'
        foreach ($vulnerability in @(Get-ObjectProperty $result 'Vulnerabilities')) {
            if ($null -eq $vulnerability) {
                continue
            }

            $severityValue = Get-ObjectProperty $vulnerability 'Severity'
            if ([string]::IsNullOrWhiteSpace($severityValue)) {
                $severityValue = 'UNKNOWN'
            }

            $findings += [pscustomobject]@{
                Image = $Image
                Target = $target
                Type = $type
                VulnerabilityID = Get-ObjectProperty $vulnerability 'VulnerabilityID'
                Severity = $severityValue.ToUpperInvariant()
                Package = Get-ObjectProperty $vulnerability 'PkgName'
                InstalledVersion = Get-ObjectProperty $vulnerability 'InstalledVersion'
                FixedVersion = Get-ObjectProperty $vulnerability 'FixedVersion'
                Status = Get-ObjectProperty $vulnerability 'Status'
                Title = Get-ObjectProperty $vulnerability 'Title'
                PrimaryURL = Get-ObjectProperty $vulnerability 'PrimaryURL'
            }
        }
    }

    return $findings
}

function Get-SeverityCounts {
    param([object[]]$Findings)

    $counts = [ordered]@{
        CRITICAL = 0
        HIGH = 0
        MEDIUM = 0
        LOW = 0
        UNKNOWN = 0
    }

    foreach ($finding in @($Findings)) {
        $severityValue = if ($finding.Severity) { $finding.Severity } else { 'UNKNOWN' }
        if ($counts.Contains($severityValue)) {
            $counts[$severityValue]++
        }
        else {
            $counts.UNKNOWN++
        }
    }

    return $counts
}

function Get-UniqueCveCount {
    param([object[]]$Findings)

    return @(
        $Findings |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.VulnerabilityID) } |
            Select-Object -ExpandProperty VulnerabilityID -Unique
    ).Count
}

function New-ImageMarkdownReport {
    param(
        [string]$Image,
        [object[]]$Findings,
        [string]$JsonFile,
        [string]$Severity,
        [string]$Scanners,
        [bool]$IgnoreUnfixed,
        [string]$IgnoreFile,
        [string]$GeneratedAt
    )

    $counts = Get-SeverityCounts $Findings
    $unfixedMode = if ($IgnoreUnfixed) { 'excluded' } else { 'included' }
    $lines = [System.Collections.Generic.List[string]]::new()

    $lines.Add('# Trivy CVE Report')
    $lines.Add('')
    $lines.Add("- Image: ``$Image``")
    $lines.Add("- Generated: ``$GeneratedAt``")
    $lines.Add("- Severity filter: ``$Severity``")
    $lines.Add("- Scanners: ``$Scanners``")
    $lines.Add("- Unfixed findings: ``$unfixedMode``")
    $lines.Add("- Ignore file: ``$IgnoreFile``")
    $lines.Add("- Raw JSON: ``$JsonFile``")
    $lines.Add('')
    $lines.Add('## Summary')
    $lines.Add('')
    $lines.Add("| Total findings | Unique CVEs | Critical | High | Medium | Low | Unknown |")
    $lines.Add("| ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    $lines.Add("| $($Findings.Count) | $(Get-UniqueCveCount $Findings) | $($counts.CRITICAL) | $($counts.HIGH) | $($counts.MEDIUM) | $($counts.LOW) | $($counts.UNKNOWN) |")
    $lines.Add('')

    if ($Findings.Count -eq 0) {
        $lines.Add('No vulnerabilities were reported.')
        return ($lines -join [Environment]::NewLine)
    }

    $lines.Add('## Findings')
    $lines.Add('')
    $lines.Add("| Severity | CVE | Package | Installed | Fixed | Status | Target | Title |")
    $lines.Add("| --- | --- | --- | --- | --- | --- | --- | --- |")

    $sortedFindings = @(
        $Findings |
            Sort-Object `
                @{ Expression = { Get-SeverityRank $_.Severity }; Descending = $true },
                'VulnerabilityID',
                'Package',
                'Target'
    )

    foreach ($finding in $sortedFindings) {
        $cve = ConvertTo-MarkdownLink $finding.VulnerabilityID $finding.PrimaryURL
        $lines.Add("| $(ConvertTo-MarkdownCell $finding.Severity) | $cve | $(ConvertTo-MarkdownCell $finding.Package) | $(ConvertTo-MarkdownCell $finding.InstalledVersion) | $(ConvertTo-MarkdownCell $finding.FixedVersion) | $(ConvertTo-MarkdownCell $finding.Status) | $(ConvertTo-MarkdownCell $finding.Target) | $(ConvertTo-MarkdownCell $finding.Title) |")
    }

    return ($lines -join [Environment]::NewLine)
}

function New-AggregateMarkdownReport {
    param(
        [string[]]$Images,
        [object[]]$Findings,
        [string]$Severity,
        [string]$Scanners,
        [bool]$IgnoreUnfixed,
        [string]$IgnoreFile,
        [string]$GeneratedAt
    )

    $counts = Get-SeverityCounts $Findings
    $unfixedMode = if ($IgnoreUnfixed) { 'excluded' } else { 'included' }
    $lines = [System.Collections.Generic.List[string]]::new()

    $lines.Add('# Local Trivy CVE Report')
    $lines.Add('')
    $lines.Add("- Generated: ``$GeneratedAt``")
    $lines.Add("- Images scanned: $($Images.Count)")
    $lines.Add("- Severity filter: ``$Severity``")
    $lines.Add("- Scanners: ``$Scanners``")
    $lines.Add("- Unfixed findings: ``$unfixedMode``")
    $lines.Add("- Ignore file: ``$IgnoreFile``")
    $lines.Add('')
    $lines.Add('## Summary')
    $lines.Add('')
    $lines.Add("| Total findings | Unique CVEs | Critical | High | Medium | Low | Unknown |")
    $lines.Add("| ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    $lines.Add("| $($Findings.Count) | $(Get-UniqueCveCount $Findings) | $($counts.CRITICAL) | $($counts.HIGH) | $($counts.MEDIUM) | $($counts.LOW) | $($counts.UNKNOWN) |")
    $lines.Add('')

    $lines.Add('## Images')
    $lines.Add('')
    $lines.Add("| Image | Total | Unique CVEs | Critical | High | Medium | Low | Unknown |")
    $lines.Add("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    foreach ($image in $Images) {
        $imageFindings = @($Findings | Where-Object { $_.Image -eq $image })
        $imageCounts = Get-SeverityCounts $imageFindings
        $lines.Add("| ``$(ConvertTo-MarkdownCell $image)`` | $($imageFindings.Count) | $(Get-UniqueCveCount $imageFindings) | $($imageCounts.CRITICAL) | $($imageCounts.HIGH) | $($imageCounts.MEDIUM) | $($imageCounts.LOW) | $($imageCounts.UNKNOWN) |")
    }
    $lines.Add('')

    if ($Findings.Count -eq 0) {
        $lines.Add('No vulnerabilities were reported.')
        return ($lines -join [Environment]::NewLine)
    }

    $lines.Add('## All Findings')
    $lines.Add('')
    $lines.Add("| Image | Severity | CVE | Package | Installed | Fixed | Status | Target | Title |")
    $lines.Add("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")

    $sortedFindings = @(
        $Findings |
            Sort-Object `
                'Image',
                @{ Expression = { Get-SeverityRank $_.Severity }; Descending = $true },
                'VulnerabilityID',
                'Package',
                'Target'
    )

    foreach ($finding in $sortedFindings) {
        $cve = ConvertTo-MarkdownLink $finding.VulnerabilityID $finding.PrimaryURL
        $lines.Add("| ``$(ConvertTo-MarkdownCell $finding.Image)`` | $(ConvertTo-MarkdownCell $finding.Severity) | $cve | $(ConvertTo-MarkdownCell $finding.Package) | $(ConvertTo-MarkdownCell $finding.InstalledVersion) | $(ConvertTo-MarkdownCell $finding.FixedVersion) | $(ConvertTo-MarkdownCell $finding.Status) | $(ConvertTo-MarkdownCell $finding.Target) | $(ConvertTo-MarkdownCell $finding.Title) |")
    }

    return ($lines -join [Environment]::NewLine)
}

if (-not $Images) {
    Exit-WithError 'No images were provided for Trivy scanning.' 2
}

$imageList = $Images -split '\s+' | Where-Object { $_ }
if ($imageList.Count -eq 0) {
    Exit-WithError 'No images were provided for Trivy scanning.' 2
}

$trivyCommand = Get-Command $Trivy -ErrorAction SilentlyContinue
if (-not $trivyCommand) {
    Exit-WithError "Trivy CLI not found. Install it from https://trivy.dev/ or set Trivy to the executable path." 127
}

$trivyExe = if ($trivyCommand.Path) { $trivyCommand.Path } else { $trivyCommand.Source }
$ignoreUnfixedFlag = ConvertTo-Bool $IgnoreUnfixed
$severityCsv = ConvertTo-CsvList $Severity
$scannersCsv = ConvertTo-CsvList $Scanners

if ([string]::IsNullOrWhiteSpace($severityCsv)) {
    Exit-WithError 'No Trivy severities were provided.' 2
}
if ([string]::IsNullOrWhiteSpace($scannersCsv)) {
    Exit-WithError 'No Trivy scanners were provided.' 2
}

New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null

$generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
$allFindings = @()
foreach ($image in $imageList) {
    $reportName = Get-SafeFileName $image
    $jsonFile = Join-Path $ResultsDir "$reportName.raw.json"
    $markdownFile = Join-Path $ResultsDir "$reportName.md"

    Write-Host "Scanning $image"

    $trivyArgs = @(
        'image',
        '--cache-dir', $CacheDir,
        '--no-progress',
        '--skip-version-check',
        '--scanners', $scannersCsv,
        '--severity', $severityCsv,
        '--exit-code', '0',
        '--format', 'json'
    )
    if ($IgnoreFile) {
        if (Test-Path -LiteralPath $IgnoreFile) {
            $trivyArgs += @('--ignorefile', $IgnoreFile)
        }
        else {
            Write-Warning "Ignore file not found: $IgnoreFile"
        }
    }
    if ($ignoreUnfixedFlag) {
        $trivyArgs += '--ignore-unfixed'
    }
    $trivyArgs += $image

    $jsonLines = & $trivyExe @trivyArgs
    $scanExit = $LASTEXITCODE
    if ($scanExit -ne 0) {
        Exit-WithError "Trivy scan failed for $image with exit code $scanExit." $scanExit
    }

    $jsonText = [string]::Join([Environment]::NewLine, @($jsonLines))
    Set-Content -LiteralPath $jsonFile -Value $jsonText -Encoding utf8

    try {
        $scan = $jsonText | ConvertFrom-Json -Depth 100
    }
    catch {
        Exit-WithError "Failed to parse Trivy JSON for ${image}: $($_.Exception.Message)" 3
    }

    $findings = @(Get-TrivyFindings -Scan $scan -Image $image)
    $allFindings += $findings

    $markdown = New-ImageMarkdownReport `
        -Image $image `
        -Findings $findings `
        -JsonFile $jsonFile `
        -Severity $severityCsv `
        -Scanners $scannersCsv `
        -IgnoreUnfixed $ignoreUnfixedFlag `
        -IgnoreFile $IgnoreFile `
        -GeneratedAt $generatedAt
    Set-Content -LiteralPath $markdownFile -Value $markdown -Encoding utf8

    if ($findings.Count -eq 0) {
        Write-Host "  clean -> $markdownFile"
    }
    else {
        Write-Host "  findings: $($findings.Count) -> $markdownFile"
    }
}

$aggregateFile = Join-Path $ResultsDir 'all-cves.md'
$aggregateMarkdown = New-AggregateMarkdownReport `
    -Images $imageList `
    -Findings $allFindings `
    -Severity $severityCsv `
    -Scanners $scannersCsv `
    -IgnoreUnfixed $ignoreUnfixedFlag `
    -IgnoreFile $IgnoreFile `
    -GeneratedAt $generatedAt
Set-Content -LiteralPath $aggregateFile -Value $aggregateMarkdown -Encoding utf8

Write-Host "Trivy Markdown reports written to $ResultsDir"
Write-Host "Aggregate CVE report -> $aggregateFile"

if ($allFindings.Count -gt 0 -and $ExitCode -ne 0) {
    exit $ExitCode
}

exit 0
