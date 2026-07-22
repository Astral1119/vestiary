[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputRoot,

    [Parameter(Mandatory = $true)]
    [ValidateSet("idle", "cursor-step", "cursor-sweep")]
    [string]$Trial,

    [Parameter(Mandatory = $true)]
    [ValidateSet(30, 60, 120)]
    [int]$WallpaperFps,

    [ValidateRange(60, 240)]
    [int]$CaptureFps = 120,

    [Parameter(Mandatory = $true)]
    [int]$RoiX,

    [Parameter(Mandatory = $true)]
    [int]$RoiY,

    [Parameter(Mandatory = $true)]
    [int]$RoiWidth,

    [Parameter(Mandatory = $true)]
    [int]$RoiHeight
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$links = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links"
$errorLog = Join-Path $OutputRoot "launcher-error.log"
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
Remove-Item -LiteralPath $errorLog -Force -ErrorAction SilentlyContinue

try {
    & (Join-Path $root "capture.ps1") `
        -OutputRoot $OutputRoot `
        -PresentMon (Join-Path $links "presentmon.exe") `
        -Trial $Trial `
        -WallpaperFps $WallpaperFps `
        -CaptureFps $CaptureFps `
        -RoiX $RoiX `
        -RoiY $RoiY `
        -RoiWidth $RoiWidth `
        -RoiHeight $RoiHeight `
        -Ffmpeg (Join-Path $links "ffmpeg.exe") `
        -Ffprobe (Join-Path $links "ffprobe.exe")
} catch {
    ($_ | Format-List * -Force | Out-String) | Set-Content $errorLog -Encoding UTF8
    exit 1
}
