param(
    [ValidateSet('Images', 'BuildBase', 'BuildTools', 'BuildAll')]
    [string]$Command = 'Images',
    [string]$VersionsFile = 'versions.yml',
    [string]$Version = '1.0.0',
    [string]$Docker = 'docker',
    [string]$GitSha = '',
    [switch]$AsArgumentString,
    [switch]$IncludeGitShaTag,
    [switch]$BuildDependencies,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Get-YamlValue {
    param([string]$Value)

    $text = $Value.Trim()
    if ($text.StartsWith('"') -and $text.EndsWith('"')) {
        return $text.Substring(1, $text.Length - 2)
    }
    if ($text.StartsWith("'") -and $text.EndsWith("'")) {
        return $text.Substring(1, $text.Length - 2)
    }
    return $text
}

function ConvertFrom-VersionRegistry {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Version registry not found: $Path"
    }

    $sections = @{
        'base-tracks' = [System.Collections.Generic.List[object]]::new()
        'tool-tracks' = [System.Collections.Generic.List[object]]::new()
    }

    $section = $null
    $item = $null
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*(#.*)?$') {
            continue
        }

        if ($line -match '^([A-Za-z0-9_-]+):\s*$') {
            if ($item -and $section) {
                $sections[$section].Add([pscustomobject]$item)
                $item = $null
            }
            $sectionName = $Matches[1]
            $section = if ($sections.ContainsKey($sectionName)) { $sectionName } else { $null }
            continue
        }

        if (-not $section) {
            continue
        }

        if ($line -match '^\s*-\s*([A-Za-z0-9_-]+):\s*(.*?)\s*$') {
            if ($item) {
                $sections[$section].Add([pscustomobject]$item)
            }
            $item = [ordered]@{}
            $item[$Matches[1]] = Get-YamlValue $Matches[2]
            continue
        }

        if ($item -and $line -match '^\s+([A-Za-z0-9_-]+):\s*(.*?)\s*$') {
            $item[$Matches[1]] = Get-YamlValue $Matches[2]
        }
    }

    if ($item -and $section) {
        $sections[$section].Add([pscustomobject]$item)
    }

    return [pscustomobject]@{
        BaseTracks = @($sections['base-tracks'])
        ToolTracks = @($sections['tool-tracks'])
    }
}

function Get-PropertyValue {
    param(
        [object]$InputObject,
        [string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if (-not $property) {
        return $null
    }
    return $property.Value
}

function Get-LiveTracks {
    param([object[]]$Tracks)

    return @($Tracks | Where-Object { (Get-PropertyValue $_ 'status') -ne 'eol' })
}

function Get-DockerfileTitle {
    param([string]$Dockerfile)

    if (-not (Test-Path -LiteralPath $Dockerfile)) {
        throw "Dockerfile not found: $Dockerfile"
    }

    $content = Get-Content -Raw -LiteralPath $Dockerfile
    if ($content -notmatch 'org\.opencontainers\.image\.title\s*=\s*"([^"]+)"') {
        throw "Dockerfile $Dockerfile does not declare org.opencontainers.image.title"
    }

    return $Matches[1]
}

function Get-BaseImageTag {
    param(
        [object]$Track,
        [string]$Version
    )

    $name = Get-DockerfileTitle (Get-PropertyValue $Track 'dockerfile')
    $suffix = Get-PropertyValue $Track 'suffix'
    return "${name}:${Version}-${suffix}"
}

function Get-ToolImageTag {
    param(
        [object]$Track,
        [string]$Version
    )

    $name = Get-DockerfileTitle (Get-PropertyValue $Track 'dockerfile')
    return "${name}:${Version}"
}

function Get-ImageTags {
    param(
        [object]$Config,
        [string]$Version,
        [string]$GitSha,
        [bool]$IncludeGitShaTag
    )

    $tags = [System.Collections.Generic.List[string]]::new()
    foreach ($track in Get-LiveTracks $Config.BaseTracks) {
        $tags.Add((Get-BaseImageTag $track $Version))
    }
    foreach ($track in Get-LiveTracks $Config.ToolTracks) {
        $tags.Add((Get-ToolImageTag $track $Version))
        if ($IncludeGitShaTag -and -not [string]::IsNullOrWhiteSpace($GitSha)) {
            $name = Get-DockerfileTitle (Get-PropertyValue $track 'dockerfile')
            $tags.Add("${name}:sha-${GitSha}")
        }
    }

    return @($tags)
}

function Invoke-Docker {
    param([string[]]$Arguments)

    Write-Host "$Docker $($Arguments -join ' ')"
    if ($DryRun) {
        return
    }

    & $Docker @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Docker command failed with exit code $LASTEXITCODE"
    }
}

function Invoke-BuildBaseTracks {
    param(
        [object[]]$Tracks,
        [string]$Version
    )

    foreach ($track in Get-LiveTracks $Tracks) {
        $tag = Get-BaseImageTag $track $Version
        Invoke-Docker @(
            'build',
            '--build-arg', (Get-PropertyValue $track 'build-arg'),
            '-f', (Get-PropertyValue $track 'dockerfile'),
            '-t', $tag,
            '.'
        )
    }
}

function Get-BaseTrackBySuffix {
    param(
        [object[]]$Tracks,
        [string]$Suffix
    )

    $matches = @(Get-LiveTracks $Tracks | Where-Object { (Get-PropertyValue $_ 'suffix') -eq $Suffix })
    if ($matches.Count -ne 1) {
        throw "Expected one live base track for suffix '$Suffix', found $($matches.Count)."
    }
    return $matches[0]
}

function Invoke-BuildToolTracks {
    param(
        [object]$Config,
        [string]$Version,
        [string]$GitSha,
        [bool]$BuildDependencies
    )

    $dependencySuffixes = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($track in Get-LiveTracks $Config.ToolTracks) {
        [void]$dependencySuffixes.Add((Get-PropertyValue $track 'base-suffix'))
    }

    if ($BuildDependencies) {
        foreach ($suffix in $dependencySuffixes) {
            Invoke-BuildBaseTracks @((Get-BaseTrackBySuffix $Config.BaseTracks $suffix)) $Version
        }
    }

    foreach ($track in Get-LiveTracks $Config.ToolTracks) {
        $baseSuffix = Get-PropertyValue $track 'base-suffix'
        $baseTrack = Get-BaseTrackBySuffix $Config.BaseTracks $baseSuffix
        $baseImage = Get-PropertyValue $track 'base-image'
        if ([string]::IsNullOrWhiteSpace($baseImage)) {
            $baseImage = Get-DockerfileTitle (Get-PropertyValue $baseTrack 'dockerfile')
        }

        $arguments = [System.Collections.Generic.List[string]]::new()
        $arguments.Add('build')
        $arguments.Add('--build-arg')
        $arguments.Add("BASE_IMAGE=${baseImage}:${Version}-${baseSuffix}")
        $arguments.Add('-f')
        $arguments.Add((Get-PropertyValue $track 'dockerfile'))
        $arguments.Add('-t')
        $arguments.Add((Get-ToolImageTag $track $Version))
        if (-not [string]::IsNullOrWhiteSpace($GitSha)) {
            $name = Get-DockerfileTitle (Get-PropertyValue $track 'dockerfile')
            $arguments.Add('-t')
            $arguments.Add("${name}:sha-${GitSha}")
        }
        $arguments.Add('.')

        Invoke-Docker @($arguments)
    }
}

$config = ConvertFrom-VersionRegistry $VersionsFile

switch ($Command) {
    'Images' {
        $tags = Get-ImageTags $config $Version $GitSha $IncludeGitShaTag
        if ($AsArgumentString) {
            Write-Output ($tags -join ' ')
        }
        else {
            $tags | ForEach-Object { Write-Output $_ }
        }
    }
    'BuildBase' {
        Invoke-BuildBaseTracks $config.BaseTracks $Version
    }
    'BuildTools' {
        Invoke-BuildToolTracks $config $Version $GitSha $BuildDependencies
    }
    'BuildAll' {
        Invoke-BuildBaseTracks $config.BaseTracks $Version
        Invoke-BuildToolTracks $config $Version $GitSha $false
    }
}
