# End-to-end test of the relay: two game clients, each with its own transport
# folder, bridged by cooprelay.py over UDP (the stand-in for Steam).
#
# Expected chain:
#   game A -> netA\A.state -> relay A -> udp -> relay B -> netB\A.state -> game B
#   game B -> netB\B.state -> relay B -> udp -> relay A -> netA\B.state -> game A
#
# The test then teleports player A to a distinctive spot via netA\cmd.txt and
# checks that the spot shows up in netB\A.state and in game B's log.

$pt    = "D:\coop-work\poppy-playtime"
$netA  = "$pt\net\A"
$netB  = "$pt\net\B"
$binA  = "$pt\WindowsNoEditor\Poppy_Playtime\Binaries\Win64"
$binB  = "D:\coop-work\poppy-playtime-b\WindowsNoEditor\Poppy_Playtime\Binaries\Win64"
$exeA  = "$binA\Poppy_Playtime-Win64-Shipping.exe"
$exeB  = "$binB\Poppy_Playtime-Win64-Shipping.exe"
$relay = "D:\coop-work\relay\cooprelay.py"
$port  = 27099

New-Item -ItemType Directory -Force -Path $netA, $netB | Out-Null
Remove-Item "$netA\*", "$netB\*" -Force -ErrorAction SilentlyContinue
Remove-Item "$binA\UE4SS.log", "$binB\UE4SS.log" -Force -ErrorAction SilentlyContinue

$ra = Start-Process python -ArgumentList @($relay, "--transport", "udp", "--role", "host",
        "--self", "A", "--peer", "B", "--netdir", $netA, "--port", $port,
        "--log", "$netA\relay.log") -PassThru -WindowStyle Hidden
Start-Sleep 1
$rb = Start-Process python -ArgumentList @($relay, "--transport", "udp", "--role", "client",
        "--host", "127.0.0.1", "--port", $port,
        "--self", "B", "--peer", "A", "--netdir", $netB,
        "--log", "$netB\relay.log") -PassThru -WindowStyle Hidden
Start-Sleep 1

$pa = Start-Process $exeA -PassThru -WorkingDirectory $binA
Start-Sleep 6
$pb = Start-Process $exeB -PassThru -WorkingDirectory $binB

Start-Sleep 50
"--- teleporting player A to -3000 800 200 ---"
Set-Content -Path "$netA\cmd.txt" -Value "pawnloc -3000 800 200" -Encoding ascii
Start-Sleep 25

"alive: relayA=$(-not $ra.HasExited) relayB=$(-not $rb.HasExited) gameA=$(-not $pa.HasExited) gameB=$(-not $pb.HasExited)"

"===== relay A log ====="
Get-Content "$netA\relay.log" -ErrorAction SilentlyContinue | Select-Object -Last 8
"===== relay B log ====="
Get-Content "$netB\relay.log" -ErrorAction SilentlyContinue | Select-Object -Last 8

"===== state files ====="
foreach ($p in @("$netA\A.state", "$netA\B.state", "$netB\A.state", "$netB\B.state")) {
    $v = if (Test-Path $p) { (Get-Content $p -Raw).Trim() } else { "MISSING" }
    "$p  ->  $v"
}

"===== game A log (last 4 sync lines) ====="
Select-String -Path "$binA\UE4SS.log" -Pattern "PoppyCoop" | ForEach-Object { $_.Line } | Select-Object -Last 4
"===== game B log (last 4 sync lines) ====="
Select-String -Path "$binB\UE4SS.log" -Pattern "PoppyCoop" | ForEach-Object { $_.Line } | Select-Object -Last 4

Get-Process -Name "Poppy_Playtime*" -ErrorAction SilentlyContinue | Stop-Process -Force
foreach ($r in @($ra, $rb)) { if (-not $r.HasExited) { Stop-Process -Id $r.Id -Force } }
Start-Sleep 2
"--- done ---"
