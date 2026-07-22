[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputRoot
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($null -eq ("FrescoDesktopProbe" -as [type])) {
    Add-Type @"
using System.Runtime.InteropServices;
public static class FrescoDesktopProbe {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
}
"@
}
[FrescoDesktopProbe]::SetProcessDPIAware() | Out-Null
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$screens = @([System.Windows.Forms.Screen]::AllScreens)
$primary = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bitmap = [System.Drawing.Bitmap]::new($primary.Width, $primary.Height)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
try {
    $graphics.CopyFromScreen(
        $primary.X, $primary.Y, 0, 0, $primary.Size,
        [System.Drawing.CopyPixelOperation]::SourceCopy)
    $bitmap.Save(
        (Join-Path $OutputRoot "desktop.png"),
        [System.Drawing.Imaging.ImageFormat]::Png)
} finally {
    $graphics.Dispose()
    $bitmap.Dispose()
}

$wallpaper = @(Get-Process wallpaper64 -ErrorAction SilentlyContinue | ForEach-Object {
    [ordered]@{
        id = $_.Id
        sessionId = $_.SessionId
        path = $_.Path
    }
})
$result = [ordered]@{
    capturedAt = (Get-Date).ToUniversalTime().ToString("o")
    sessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    screens = @($screens | ForEach-Object {
        [ordered]@{
            deviceName = $_.DeviceName
            primary = $_.Primary
            x = $_.Bounds.X
            y = $_.Bounds.Y
            width = $_.Bounds.Width
            height = $_.Bounds.Height
        }
    })
    wallpaperProcesses = $wallpaper
}
$result | ConvertTo-Json -Depth 5 | Set-Content (
    Join-Path $OutputRoot "desktop.json") -Encoding UTF8
