# Appearance test: one client, puppet parked in front of the player, then a screenshot.
#
# Why this exists: "the puppet is dressed" and "the puppet is animated" are not things a
# log line proves on its own. This test produces (a) the mod's own diagnostics about the
# mesh, its material slots and its anim instance, (b) a bone position sampled over time,
# which is what shows a pose is actually moving, and (c) a PNG the owner can look at.
#
# The transport folder is left empty, so the mod has no peer to follow; "drive pose"
# switches it to pose mode, which parks the puppet CONFIG.poseDistance in front of the
# player and turns it to face the camera.
#
# -Extra adds one more cmd.txt line (e.g. a different animation attempt) without editing
# this script.

param(
    [string]$Out = "D:\coop-work\shots\puppet.png",
    [int]$LevelWaitSec = 78,
    [int]$SettleSec = 14,
    [string]$Extra = ""
)

$root = "C:\Users\User\Documents\Проект по умолчанию\poppy-coop"
$pt   = "D:\coop-work\poppy-playtime"
$net  = "$pt\net\vis"
$binA = "$pt\WindowsNoEditor\Poppy_Playtime\Binaries\Win64"
$exeA = "$binA\Poppy_Playtime-Win64-Shipping.exe"

New-Item -ItemType Directory -Force -Path $net | Out-Null
Remove-Item "$net\*" -Force -ErrorAction SilentlyContinue
Remove-Item "$binA\UE4SS.log" -Force -ErrorAction SilentlyContinue
Get-Process -Name "Poppy_Playtime*" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 2

powershell -ExecutionPolicy Bypass -File "$root\deploy.ps1" -TestBin $binA -PlayerId A -NetDir $net | Select-Object -First 2

$pa = Start-Process $exeA -PassThru -WorkingDirectory $binA
"launched game A (pid $($pa.Id)) at $(Get-Date -Format HH:mm:ss)"

Start-Sleep $LevelWaitSec
if ($pa.HasExited) { "GAME EXITED EARLY (code $($pa.ExitCode)) - stopping"; exit 1 }

"--- pose + diagnostics ---"
Set-Content -Path "$net\cmd.txt" -Value "drive pose`ndiag`nbones" -Encoding ascii
Start-Sleep 8

if ($Extra -ne "") {
    "--- extra: $Extra ---"
    Add-Content -Path "$net\cmd.txt" -Value $Extra -Encoding ascii
    Start-Sleep $SettleSec
}
Start-Sleep 4

"alive: gameA=$(-not $pa.HasExited)"
"===== mod log ====="
Select-String -Path "$binA\UE4SS.log" -Pattern "PoppyCoop" | ForEach-Object { $_.Line } |
    Where-Object { $_ -match "dress:|diag|bones:|anim:|mats:|bone |spawn: adopted|ERROR" } |
    Select-Object -Last 40

& "$root\tools\screenshot.ps1" -Out $Out

Get-Process -Name "Poppy_Playtime*" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 2
"--- done ---"
