[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputRoot,

    [Parameter(Mandatory = $true)]
    [string]$PresentMon,

    [Parameter(Mandatory = $true)]
    [ValidateSet("idle", "cursor-step", "cursor-sweep")]
    [string]$Trial,

    [Parameter(Mandatory = $true)]
    [ValidateSet(30, 60, 120)]
    [int]$WallpaperFps,

    [ValidateRange(60, 240)]
    [int]$CaptureFps = 120,

    [ValidateRange(10, 30)]
    [double]$DurationSeconds = 12,

    [Parameter(Mandatory = $true)]
    [ValidateRange(0, 32768)]
    [int]$RoiX,

    [Parameter(Mandatory = $true)]
    [ValidateRange(0, 32768)]
    [int]$RoiY,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 32768)]
    [int]$RoiWidth,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 32768)]
    [int]$RoiHeight,

    [string]$ProcessName = "wallpaper64.exe",

    [string]$ScenePackage = "${env:ProgramFiles(x86)}\Steam\steamapps\workshop\content\431960\3448290956\scene.pkg",

    [string]$Ffmpeg = "ffmpeg",

    [string]$Ffprobe = "ffprobe"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$expectedWallpaperID = "3448290956"
$expectedSceneSha256 = "4bac6871f95380c374653c44a903538cfa841a8d17abe310a092543dd9ac6ac1"

function Resolve-Executable([string]$Value) {
    $command = Get-Command $Value -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }
    if (Test-Path -LiteralPath $Value -PathType Leaf) {
        return (Resolve-Path -LiteralPath $Value).Path
    }
    throw "executable not found: $Value"
}

function Quote-ProcessArgument([object]$Value) {
    $text = [string]$Value
    if ($text -match '[\s"]') {
        return '"' + $text.Replace('"', '\"') + '"'
    }
    return $text
}

function Add-CursorEvent(
    [System.Collections.Generic.List[object]]$Events,
    [System.Diagnostics.Stopwatch]$Clock,
    [string]$Kind,
    [int]$X,
    [int]$Y
) {
    if (-not [FrescoCursorCapture]::SetCursorPos($X, $Y)) {
        throw "SetCursorPos failed for $Kind at $X,$Y"
    }
    $Events.Add([pscustomobject]@{
        elapsedMilliseconds = [math]::Round($Clock.Elapsed.TotalMilliseconds, 3)
        kind = $Kind
        x = $X
        y = $Y
    })
}

function Wait-Until(
    [System.Diagnostics.Stopwatch]$Clock,
    [double]$TargetSeconds
) {
    while ($Clock.Elapsed.TotalSeconds -lt $TargetSeconds) {
        $remaining = $TargetSeconds - $Clock.Elapsed.TotalSeconds
        $milliseconds = [math]::Max(1, [math]::Min(10, [int]($remaining * 500)))
        [System.Threading.Thread]::Sleep($milliseconds)
    }
}

$ffmpegPath = Resolve-Executable $Ffmpeg
$ffprobePath = Resolve-Executable $Ffprobe
$presentMonPath = Resolve-Executable $PresentMon

if (-not (Test-Path -LiteralPath $ScenePackage -PathType Leaf)) {
    throw "GBC scene package not found: $ScenePackage"
}
$scenePackagePath = (Resolve-Path -LiteralPath $ScenePackage).Path
$scenePackageInfo = Get-Item -LiteralPath $scenePackagePath
$sceneHash = (Get-FileHash -LiteralPath $scenePackagePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($sceneHash -ne $expectedSceneSha256) {
    throw "GBC scene package hash changed: expected $expectedSceneSha256, received $sceneHash"
}

Add-Type -AssemblyName System.Windows.Forms
if ($null -eq ("FrescoCursorCapture" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class FrescoCursorCapture {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);
}
"@
}

[FrescoCursorCapture]::SetProcessDPIAware() | Out-Null
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$desktop = @{
    x = [int]$screen.X
    y = [int]$screen.Y
    width = [int]$screen.Width
    height = [int]$screen.Height
}
if ($RoiX + $RoiWidth -gt $desktop.width -or $RoiY + $RoiHeight -gt $desktop.height) {
    throw "ROI lies outside the primary display"
}

$capturedAtUtc = (Get-Date).ToUniversalTime()
$timestamp = $capturedAtUtc.ToString("yyyyMMdd-HHmmss-fff")
$runName = "gbc-$WallpaperFps-$Trial-$timestamp"
$runDirectory = Join-Path $OutputRoot $runName
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null

$videoPath = Join-Path $runDirectory "capture.mkv"
$rawVideoPath = Join-Path $runDirectory "capture.raw.nut"
$presentMonCsv = Join-Path $runDirectory "presentmon.csv"
$eventsPath = Join-Path $runDirectory "events.csv"
$ffmpegLog = Join-Path $runDirectory "ffmpeg.log"
$ffmpegTranscodeLog = Join-Path $runDirectory "ffmpeg-transcode.log"
$presentMonLog = Join-Path $runDirectory "presentmon.log"
$presentMonErrorLog = Join-Path $runDirectory "presentmon-error.log"

$centerX = $desktop.x + [int]($desktop.width / 2)
$centerY = $desktop.y + [int]($desktop.height / 2)
$leftX = $desktop.x + [int]($desktop.width * 0.2)
$rightX = $desktop.x + [int]($desktop.width * 0.8)
if (-not [FrescoCursorCapture]::SetCursorPos($centerX, $centerY)) {
    throw "SetCursorPos failed while centering the cursor before capture"
}
Start-Sleep -Milliseconds 500

$presentMonArguments = @(
    "--process_name", $ProcessName,
    "--output_file", $presentMonCsv,
    "--qpc_time_ms",
    "--exclude_dropped",
    "--no_console_stats",
    "--timed", $DurationSeconds.ToString([Globalization.CultureInfo]::InvariantCulture),
    "--terminate_after_timed"
)
$presentMonProcess = $null
$ffmpegProcess = $null
try {
$presentMonProcess = Start-Process -FilePath $presentMonPath `
    -ArgumentList ($presentMonArguments | ForEach-Object { Quote-ProcessArgument $_ }) `
    -PassThru `
    -NoNewWindow `
    -RedirectStandardOutput $presentMonLog `
    -RedirectStandardError $presentMonErrorLog

$desktopFilter = (
    "ddagrab=output_idx=0:draw_mouse=1:framerate={0}:video_size={1}x{2}:offset_x={3}:offset_y={4}" -f
    $CaptureFps,
    $RoiWidth,
    $RoiHeight,
    ($desktop.x + $RoiX),
    ($desktop.y + $RoiY)
)
$ffmpegArguments = @(
    "-hide_banner",
    "-y",
    "-loglevel", "info",
    "-f", "lavfi",
    "-i", $desktopFilter,
    "-t", $DurationSeconds.ToString([Globalization.CultureInfo]::InvariantCulture),
    "-vf", "hwdownload,format=bgra",
    "-an",
    "-c:v", "rawvideo",
    "-pix_fmt", "bgra",
    "-f", "nut",
    $rawVideoPath
)
$ffmpegProcess = Start-Process -FilePath $ffmpegPath `
    -ArgumentList ($ffmpegArguments | ForEach-Object { Quote-ProcessArgument $_ }) `
    -PassThru `
    -NoNewWindow `
    -RedirectStandardError $ffmpegLog

$captureStartDeadline = [DateTime]::UtcNow.AddSeconds(5)
while (-not (Test-Path -LiteralPath $rawVideoPath -PathType Leaf) -or
       (Get-Item -LiteralPath $rawVideoPath -ErrorAction SilentlyContinue).Length -eq 0) {
    if ($ffmpegProcess.HasExited) {
        throw "FFmpeg exited before the capture stream became active; see $ffmpegLog"
    }
    if ([DateTime]::UtcNow -ge $captureStartDeadline) {
        throw "FFmpeg capture stream did not become active within five seconds; see $ffmpegLog"
    }
    Start-Sleep -Milliseconds 5
}

$events = [System.Collections.Generic.List[object]]::new()
$clock = [System.Diagnostics.Stopwatch]::StartNew()
Add-CursorEvent $events $clock "capture-start-center" $centerX $centerY

switch ($Trial) {
    "idle" {
        Wait-Until $clock $DurationSeconds
    }
    "cursor-step" {
        Wait-Until $clock 3.0
        Add-CursorEvent $events $clock "step-left" $leftX $centerY
        Wait-Until $clock 6.0
        Add-CursorEvent $events $clock "step-right" $rightX $centerY
        Wait-Until $clock 9.0
        Add-CursorEvent $events $clock "step-center" $centerX $centerY
        Wait-Until $clock $DurationSeconds
    }
    "cursor-sweep" {
        Wait-Until $clock 2.0
        $events.Add([pscustomobject]@{
            elapsedMilliseconds = [math]::Round($clock.Elapsed.TotalMilliseconds, 3)
            kind = "sweep-start"
            x = $centerX
            y = $centerY
        })
        $sweepStart = $clock.Elapsed.TotalSeconds
        $sweepDuration = 8.0
        $samplesPerSecond = 120.0
        $sample = 0
        while ($clock.Elapsed.TotalSeconds -lt $sweepStart + $sweepDuration) {
            $phase = ($clock.Elapsed.TotalSeconds - $sweepStart) / $sweepDuration
            $x = $centerX + [int](0.3 * $desktop.width * [math]::Sin(4.0 * [math]::PI * $phase))
            Add-CursorEvent $events $clock "sweep-sample" $x $centerY
            $sample += 1
            Wait-Until $clock ($sweepStart + $sample / $samplesPerSecond)
        }
        Add-CursorEvent $events $clock "sweep-end-center" $centerX $centerY
        Wait-Until $clock $DurationSeconds
    }
}

$clock.Stop()
$events | Export-Csv -LiteralPath $eventsPath -NoTypeInformation -Encoding UTF8

$ffmpegProcess.WaitForExit()
$presentMonProcess.WaitForExit()
if ($null -ne $ffmpegProcess.ExitCode -and $ffmpegProcess.ExitCode -ne 0) {
    throw "FFmpeg failed with exit code $($ffmpegProcess.ExitCode); see $ffmpegLog"
}
if ($null -ne $presentMonProcess.ExitCode -and $presentMonProcess.ExitCode -ne 0) {
    throw "PresentMon failed with exit code $($presentMonProcess.ExitCode); see $presentMonErrorLog"
}
if (-not (Test-Path -LiteralPath $rawVideoPath -PathType Leaf)) {
    throw "FFmpeg produced no raw video"
}
if (-not (Test-Path -LiteralPath $presentMonCsv -PathType Leaf)) {
    throw "PresentMon produced no CSV; confirm the process name and elevation"
}
} catch {
    foreach ($captureProcess in @($ffmpegProcess, $presentMonProcess)) {
        if ($null -ne $captureProcess -and -not $captureProcess.HasExited) {
            Stop-Process -Id $captureProcess.Id -Force -ErrorAction SilentlyContinue
        }
    }
    throw
}

$transcodeArguments = @(
    "-hide_banner",
    "-y",
    "-loglevel", "info",
    "-i", $rawVideoPath,
    "-an",
    "-c:v", "ffv1",
    "-level", "3",
    "-g", "1",
    $videoPath
)
$transcodeProcess = Start-Process -FilePath $ffmpegPath `
    -ArgumentList ($transcodeArguments | ForEach-Object { Quote-ProcessArgument $_ }) `
    -PassThru `
    -NoNewWindow `
    -RedirectStandardError $ffmpegTranscodeLog
$transcodeProcess.WaitForExit()
if ($null -ne $transcodeProcess.ExitCode -and $transcodeProcess.ExitCode -ne 0) {
    throw "FFmpeg transcode failed with exit code $($transcodeProcess.ExitCode); see $ffmpegTranscodeLog"
}
if (-not (Test-Path -LiteralPath $videoPath -PathType Leaf)) {
    throw "FFmpeg produced no FFV1 video"
}
Remove-Item -LiteralPath $rawVideoPath -Force

$os = Get-CimInstance Win32_OperatingSystem
$videoControllers = @(Get-CimInstance Win32_VideoController | ForEach-Object {
    @{
        name = $_.Name
        driverVersion = $_.DriverVersion
        adapterRAM = $_.AdapterRAM
    }
})
$ffmpegVersion = (& $ffmpegPath -version | Select-Object -First 1)
$ffprobeVersion = (& $ffprobePath -version | Select-Object -First 1)
$presentMonVersion = (Get-Item -LiteralPath $presentMonPath).VersionInfo.FileVersion

$metadata = [ordered]@{
    schemaVersion = 1
    wallpaperID = $expectedWallpaperID
    scenePackage = [ordered]@{
        path = $scenePackagePath
        sha256 = $sceneHash
        bytes = [int64]$scenePackageInfo.Length
    }
    trial = $Trial
    requestedWallpaperFps = $WallpaperFps
    requestedCaptureFps = $CaptureFps
    captureBackend = "ddagrab"
    durationSeconds = $DurationSeconds
    desktop = $desktop
    capture = [ordered]@{
        x = $RoiX
        y = $RoiY
        width = $RoiWidth
        height = $RoiHeight
    }
    roi = [ordered]@{
        x = $RoiX
        y = $RoiY
        width = $RoiWidth
        height = $RoiHeight
    }
    processName = $ProcessName
    files = [ordered]@{
        video = "capture.mkv"
        presentMon = "presentmon.csv"
        events = "events.csv"
        ffmpegLog = "ffmpeg.log"
        ffmpegTranscodeLog = "ffmpeg-transcode.log"
        presentMonLog = "presentmon.log"
        presentMonErrorLog = "presentmon-error.log"
    }
    host = [ordered]@{
        capturedAtUtc = $capturedAtUtc.ToString("o")
        computerName = $env:COMPUTERNAME
        os = "$($os.Caption) $($os.Version) build $($os.BuildNumber)"
        videoControllers = $videoControllers
    }
    tools = [ordered]@{
        ffmpeg = $ffmpegVersion
        ffprobe = $ffprobeVersion
        presentMon = $presentMonVersion
    }
}
$metadata | ConvertTo-Json -Depth 8 | Set-Content `
    -LiteralPath (Join-Path $runDirectory "capture.json") `
    -Encoding UTF8

Write-Host "GBC reference capture complete: $runDirectory"
