param(
    [Parameter(Mandatory)]
    [string]$PackageName,
    [string]$Scope = "@thetestgame"
)

$ErrorActionPreference = "Stop"

$TempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$WorkDir = Join-Path $TempRoot $PackageName
$ProjectDir = Join-Path $TempRoot "$PackageName-project"
$OutputDir = Join-Path $PWD "artifacts"

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
    dotnet add package $PackageName --no-restore
    dotnet restore --packages $WorkDir
}
finally {
    Pop-Location
}

# dotnet restore lays packages out as <id-lower>\<version>\, one level deeper than legacy `nuget install`
Get-ChildItem $WorkDir -Directory | ForEach-Object {
    Get-ChildItem $_.FullName -Directory | ForEach-Object {
        $packageDir = $_.FullName
        $nuspec = Get-ChildItem $packageDir *.nuspec -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $nuspec) {
            return
        }

        [xml]$xml = Get-Content $nuspec.FullName
        $meta = $xml.package.metadata
        $dependencies = @{}

        if ($meta.dependencies) {
            foreach ($d in $meta.dependencies.dependency) {
                $dependencies["$Scope/org.nuget.$($d.id.ToLower())"] = $d.version
            }

            foreach ($group in $meta.dependencies.group) {
                foreach ($d in $group.dependency) {
                    $dependencies["$Scope/org.nuget.$($d.id.ToLower())"] = $d.version
                }
            }
        }

        $upmName = "org.nuget.$($meta.id.ToLower())"
        $targetDir = Join-Path $OutputDir $upmName
        New-Item -ItemType Directory -Path $targetDir | Out-Null
        Get-ChildItem $packageDir -Exclude *.nupkg, *.nupkg.sha512, *.signature.p7s, .nupkg.metadata | ForEach-Object {
            Copy-Item $_.FullName $targetDir -Recurse
        }

        @{
            name         = "$Scope/$upmName"
            version      = $meta.version
            displayName  = $meta.id
            description  = $meta.description
            dependencies = $dependencies
        } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $targetDir "package.json")
        Write-Host "Generated $Scope/$upmName"
    }
}
