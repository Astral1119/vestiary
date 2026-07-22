[CmdletBinding(DefaultParameterSetName = "Set")]
param(
    [Parameter(Mandatory = $true, ParameterSetName = "Set")]
    [ValidateSet(30, 60, 120)]
    [int]$Fps,

    [Parameter(Mandatory = $true, ParameterSetName = "Restore")]
    [switch]$Restore,

    [Parameter(Mandatory = $true)]
    [string]$Backup,

    [string]$Profile,

    [string]$WallpaperEngine = "${env:ProgramFiles(x86)}\Steam\steamapps\common\wallpaper_engine\wallpaper64.exe",

    [string]$Config = "${env:ProgramFiles(x86)}\Steam\steamapps\common\wallpaper_engine\config.json"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Resolve-FpsProfile([object]$Document, [string]$RequestedProfile) {
    $candidates = @($Document.PSObject.Properties | Where-Object {
        if ($null -eq $_.Value) {
            return $false
        }
        $general = $_.Value.PSObject.Properties["general"]
        $user = if ($null -ne $general -and $null -ne $general.Value) {
            $general.Value.PSObject.Properties["user"]
        } else {
            $null
        }
        $fps = if ($null -ne $user -and $null -ne $user.Value) {
            $user.Value.PSObject.Properties["fps"]
        } else {
            $null
        }
        $null -ne $fps
    })
    if ($RequestedProfile) {
        $match = @($candidates | Where-Object { $_.Name -eq $RequestedProfile })
        if ($match.Count -ne 1) {
            throw "Wallpaper Engine FPS profile not found: $RequestedProfile"
        }
        return $match[0]
    }
    if ($candidates.Count -ne 1) {
        $names = ($candidates | ForEach-Object { $_.Name }) -join ", "
        throw "cannot choose Wallpaper Engine FPS profile; pass -Profile from: $names"
    }
    return $candidates[0]
}

if (-not (Test-Path -LiteralPath $WallpaperEngine -PathType Leaf)) {
    throw "Wallpaper Engine executable not found: $WallpaperEngine"
}
if (-not (Test-Path -LiteralPath $Config -PathType Leaf)) {
    throw "Wallpaper Engine configuration not found: $Config"
}

Get-Process wallpaper64 -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

if ($Restore) {
    if (-not (Test-Path -LiteralPath $Backup -PathType Leaf)) {
        throw "Wallpaper Engine configuration backup not found: $Backup"
    }
    Copy-Item -LiteralPath $Backup -Destination $Config -Force
} else {
    if (-not (Test-Path -LiteralPath $Backup -PathType Leaf)) {
        Copy-Item -LiteralPath $Config -Destination $Backup
    }
    $document = Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json
    $profileProperty = Resolve-FpsProfile $document $Profile
    $profileProperty.Value.general.user.fps = $Fps
    $json = $document | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText(
        $Config, $json, [System.Text.UTF8Encoding]::new($false))
}

Start-Process -FilePath $WallpaperEngine -ArgumentList "-silent"
Start-Sleep -Seconds 10

$document = Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json
$profileProperty = Resolve-FpsProfile $document $Profile
[ordered]@{
    restored = [bool]$Restore
    profile = $profileProperty.Name
    fps = $profileProperty.Value.general.user.fps
    backup = (Resolve-Path -LiteralPath $Backup).Path
    wallpaperProcess = @(Get-Process wallpaper64 -ErrorAction SilentlyContinue).Count
} | ConvertTo-Json | Write-Output
