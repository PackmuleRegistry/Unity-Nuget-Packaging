<#
.SYNOPSIS
    Generates a Unity Package Manager (UPM) compatible package from a NuGet package, ensuring it has netstandard2.0 or netstandard2.1 assemblies.

.DESCRIPTION
    Generates a Unity Package Manager (UPM) compatible package from a NuGet package, ensuring it has netstandard2.0 or netstandard2.1 assemblies.
    This script is intended to be used in a CI/CD pipeline to automate the conversion of NuGet packages to UPM packages, while tracking any incompatible 
    packages in an `incompatible.json` file.

.PARAMETER PackageName
    The name of the NuGet package to convert to a UPM package.

.EXAMPLE
    .\Package.ps1 -PackageName "Newtonsoft.Json" -Scope "@packmuleregistry"
#>
param(
    [Parameter(Mandatory)]
    [string]$PackageName,
)

$ErrorActionPreference = "Stop"

# RUNNER_TEMP keeps CI runs isolated; fall back to the OS temp dir for local runs
$TempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$WorkDir = Join-Path $TempRoot $PackageName
$ProjectDir = Join-Path $TempRoot "$PackageName-project"
$OutputDir = Join-Path $PWD "artifacts"

# Start from a clean slate in case a previous run for this package failed partway through
foreach ($dir in @($WorkDir, $ProjectDir)) {
    if (Test-Path $dir) {
        Remove-Item $dir -Recurse -Force
    }
}

New-Item -ItemType Directory -Path $WorkDir | Out-Null
New-Item -ItemType Directory -Path $ProjectDir | Out-Null

# net8.0 avoids implicit framework-reference packages (e.g. NETStandard.Library) polluting the restore output
dotnet new classlib -o $ProjectDir --framework net8.0 | Out-Null
Push-Location $ProjectDir
try {
    # --no-restore lets us add the (often unversioned/latest) package reference before triggering a single restore
    dotnet add package $PackageName --no-restore
    # --packages redirects NuGet's extraction target so packages land in $WorkDir instead of the global cache
    dotnet restore --packages $WorkDir
}
finally {
    Pop-Location
}

# dotnet restore lays packages out as <id-lower>\<version>\, one level deeper than legacy `nuget install`
# incompatible.json persists across multiple invocations within the same CI job/shard, so we load
# any prior entries first and only ever append to them (see Generate-and-Publish step in the workflow)
$incompatiblePath = Join-Path $PWD "incompatible.json"
$incompatible = @()
if (Test-Path $incompatiblePath) {
    $incompatible = @(Get-Content $incompatiblePath -Raw | ConvertFrom-Json)
}

function Get-NuspecText {
    param($Node)

    if ($null -eq $Node) {
        return $null
    }

    $value = if ($Node -is [System.Xml.XmlElement]) { $Node.InnerText.Trim() } else { ([string]$Node).Trim() }
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    return $value
}

function Get-NuspecAttribute {
    param(
        $Node,
        [string]$Name
    )

    if ($Node -isnot [System.Xml.XmlElement]) {
        return $null
    }

    return Get-NuspecText $Node.GetAttribute($Name)
}

function Add-JsonProperty {
    param(
        [System.Collections.IDictionary]$Object,
        [string]$Name,
        $Value
    )

    if ($null -eq $Value) {
        return
    }

    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    if ($Value -is [System.Collections.ICollection] -and $Value.Count -eq 0) {
        return
    }

    $Object[$Name] = $Value
}

# Outer loop: one folder per resolved NuGet package id (the requested package plus all of its transitive dependencies)
# Inner loop: one folder per version of that package id (normally just one, since dotnet restore resolves a single version)
Get-ChildItem $WorkDir -Directory | ForEach-Object {
    Get-ChildItem $_.FullName -Directory | ForEach-Object {
        $packageDir = $_.FullName
        $nuspec = Get-ChildItem $packageDir *.nuspec -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $nuspec) {
            # No .nuspec means this isn't a real package folder (e.g. stray restore metadata); nothing to mirror
            return
        }

        [xml]$xml = Get-Content $nuspec.FullName
        $meta = $xml.package.metadata

        # Unity only understands netstandard2.0/2.1 assemblies; anything else (net48-only, netcoreapp-only,
        # analyzer-only packages with no lib folder, etc.) can't be consumed by the Unity Package Manager
        $libDir = Join-Path $packageDir "lib"
        $hasNetStandard = (Test-Path $libDir) -and (
            Get-ChildItem $libDir -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -in @("netstandard2.0", "netstandard2.1") }
        )
        if (-not $hasNetStandard) {
            # Record it instead of publishing so CI can flag it (e.g. file a GitHub issue) rather than fail silently
            Write-Host "::warning::$($meta.id) $($meta.version) has no netstandard2.0/netstandard2.1 assemblies, skipping"
            $incompatible += [pscustomobject]@{
                requestedPackage = $PackageName
                id               = $meta.id
                version          = $meta.version
            }
            return
        }

        # Map NuGet dependency ids to their mirrored UPM package names/scope so Unity can resolve them transitively
        $dependencies = @{}
        if ($meta.dependencies) {
            foreach ($d in $meta.dependencies.dependency) {
                $dependencies["org.nuget.$($d.id.ToLower())"] = $d.version
            }

            # Newer nuspecs group dependencies per target framework instead of listing them flatly
            foreach ($group in $meta.dependencies.group) {
                foreach ($d in $group.dependency) {
                    $dependencies["org.nuget.$($d.id.ToLower())"] = $d.version
                }
            }
        }

        $packageId = Get-NuspecText $meta.id
        $description = Get-NuspecText $meta.description
        $authors = Get-NuspecText $meta.authors
        $owners = Get-NuspecText $meta.owners
        $projectUrl = Get-NuspecText $meta.projectUrl
        $licenseUrl = Get-NuspecText $meta.licenseUrl
        $releaseNotes = Get-NuspecText $meta.releaseNotes
        $copyright = Get-NuspecText $meta.copyright
        $repositoryUrl = Get-NuspecAttribute $meta.repository "url"
        $repositoryType = Get-NuspecAttribute $meta.repository "type"
        $repositoryBranch = Get-NuspecText $meta.repository.branch
        $repositoryCommit = Get-NuspecText $meta.repository.commit
        $licenseType = Get-NuspecAttribute $meta.license "type"
        $licenseValue = Get-NuspecText $meta.license
        $tags = Get-NuspecText $meta.tags
        
        $keywords = [System.Collections.Generic.List[string]]::new()
        if ($tags) {
            foreach ($keyword in ($tags -split '\s+' | Where-Object { $_ })) {
                $keywords.Add($keyword)
            }
        }
        $authorName = if ($authors) { $authors } elseif ($owners) { $owners } else { "NuGet" }

        $license = $null
        if ($licenseValue -and $licenseType -eq "expression") {
            $license = $licenseValue
        }
        elseif ($licenseValue -and $licenseType -eq "file") {
            $license = "SEE LICENSE IN $licenseValue"
        }

        $upmName = "org.nuget.$($packageId.ToLower())"
        $targetDir = Join-Path $OutputDir $upmName
        if (Test-Path $targetDir) {
            # dotnet restore can extract the same package id under multiple case-variant folders on
            # case-sensitive filesystems (e.g. Linux runners), which would otherwise process it twice
            Write-Host "$upmName already generated this run, skipping duplicate"
            return
        }
        New-Item -ItemType Directory -Path $targetDir | Out-Null

        # Copy everything except NuGet-specific signing/cache metadata that Unity doesn't need
        Get-ChildItem $packageDir -Exclude *.nupkg, *.nupkg.sha512, *.signature.p7s, .nupkg.metadata | ForEach-Object {
            Copy-Item $_.FullName $targetDir -Recurse
        }

        # This package.json is what actually gets published to the npm/GitHub Packages registry and
        # is what Unity's Package Manager reads to resolve the package and its dependencies
        $packageJson = [ordered]@{
            name         = "$upmName"
            version      = $meta.version
            displayName  = $packageId
            description  = $description
            author       = @{
                name = $authorName
            }
            dependencies = $dependencies
        }

        Add-JsonProperty $packageJson "keywords" $keywords
        Add-JsonProperty $packageJson "homepage" $projectUrl
        Add-JsonProperty $packageJson "license" $license
        Add-JsonProperty $packageJson "licensesUrl" $licenseUrl

        if ($repositoryUrl) {
            Add-JsonProperty $packageJson "repository" ([ordered]@{
                    type = if ($repositoryType) { $repositoryType } else { "git" }
                    url  = $repositoryUrl
                })
        }

        $packageJson | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $targetDir "package.json")
        Write-Host "Generated $upmName"
    }
}

# Use -InputObject (not a pipeline) so an empty array is still serialized as `[]` instead of producing no output
ConvertTo-Json -InputObject $incompatible -Depth 5 | Set-Content $incompatiblePath
