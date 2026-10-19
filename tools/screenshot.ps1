# Grabs the screen (so an agent can actually look at the game instead of guessing).
#
# Brings the game window to the front first, because a background window would be
# captured as whatever is on top of it. Captures the primary screen and scales it
# down, since a full 1080p PNG is more pixels than anything here needs.
#
# Note: works for windowed/borderless play. Exclusive fullscreen can come back black
# (the desktop compositor has nothing to copy).

param(
    [Parameter(Mandatory = $true)][string]$Out,
    [double]$Scale = 0.5,
    [string]$ProcessName = "Poppy_Playtime-Win64-Shipping",
    [int]$SettleMs = 900
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class CoopWin {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
}
"@

$proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
if ($proc -and $proc.MainWindowHandle -ne 0) {
    [CoopWin]::ShowWindow($proc.MainWindowHandle, 9) | Out-Null   # SW_RESTORE
    [CoopWin]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null
    Start-Sleep -Milliseconds $SettleMs
} else {
    "warning: no '$ProcessName' window found; capturing whatever is on top"
}

$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$src = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
$g = [System.Drawing.Graphics]::FromImage($src)
$g.CopyFromScreen($bounds.X, $bounds.Y, 0, 0, $src.Size)

$w = [int]($bounds.Width * $Scale)
$h = [int]($bounds.Height * $Scale)
$dst = New-Object System.Drawing.Bitmap $w, $h
$g2 = [System.Drawing.Graphics]::FromImage($dst)
$g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g2.DrawImage($src, 0, 0, $w, $h)

$dir = Split-Path -Parent $Out
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$dst.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)

$g.Dispose(); $g2.Dispose(); $src.Dispose(); $dst.Dispose()
"saved $Out ($w x $h)"
