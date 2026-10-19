# Automated test of the transport seam (receive path), one game instance.
#
# A fake peer writes a moving position into <netDir>\peer.state while the game
# runs; the mod must drive its puppet to exactly those coordinates. Also proves
# the send path: the mod writes its own position into <netDir>\local.state.
#
# Usage: powershell -ExecutionPolicy Bypass -File test-peer.ps1

$ErrorActionPreference = "Stop"

$net   = "D:\coop-work\poppy-playtime\net"
$bin   = "D:\coop-work\poppy-playtime\WindowsNoEditor\Poppy_Playtime\Binaries\Win64"
$exe   = "$bin\Poppy_Playtime-Win64-Shipping.exe"

New-Item -ItemType Directory -Force -Path $net | Out-Null
Remove-Item "$net\peer.state"  -ErrorAction SilentlyContinue
Remove-Item "$net\local.state" -ErrorAction SilentlyContinue

Remove-Item "$bin\UE4SS.log" -ErrorAction SilentlyContinue
$p = Start-Process $exe -PassThru -WorkingDirectory $bin

# Let the mod enter the game and adopt the puppet.
Start-Sleep 30

# The fake peer walks +200 in X every 2 s, so the puppet's target keeps changing.
$peerX = -3200
for ($i = 0; $i -lt 15; $i++) {
    $peerX += 200
    Set-Content -Path "$net\peer.state" -Value ("{0} 120 95 0" -f $peerX) -Encoding ascii
    Start-Sleep 2
}

Start-Sleep 3
if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force; "killed (NO CRASH)" }
else { "exited early: $($p.ExitCode)" }
Start-Sleep 3

"===== PoppyCoop log ====="
Select-String -Path "$bin\UE4SS.log" -Pattern "PoppyCoop" | ForEach-Object { $_.Line }
"===== local.state (written by the mod) ====="
if (Test-Path "$net\local.state") { Get-Content "$net\local.state" } else { "MISSING" }
