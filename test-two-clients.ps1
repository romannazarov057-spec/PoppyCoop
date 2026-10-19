# Two-client test over the local file transport, with crash accounting.
# Copy A runs as player A, copy B as player B; the mod writes <id>.state and drives
# its puppet to the other player's <id>.state.

$net  = "D:\coop-work\poppy-playtime\net"
$binA = "D:\coop-work\poppy-playtime\WindowsNoEditor\Poppy_Playtime\Binaries\Win64"
$binB = "D:\coop-work\poppy-playtime-b\WindowsNoEditor\Poppy_Playtime\Binaries\Win64"
$exeA = "$binA\Poppy_Playtime-Win64-Shipping.exe"
$exeB = "$binB\Poppy_Playtime-Win64-Shipping.exe"
$crashDir = "$env:LOCALAPPDATA\Poppy_Playtime\Saved\Crashes"

$before = @(Get-ChildItem $crashDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })

Remove-Item "$net\*.state" -ErrorAction SilentlyContinue
Remove-Item "$binA\UE4SS.log" -ErrorAction SilentlyContinue
Remove-Item "$binB\UE4SS.log" -ErrorAction SilentlyContinue

$pa = Start-Process $exeA -PassThru -WorkingDirectory $binA
Start-Sleep 6
$pb = Start-Process $exeB -PassThru -WorkingDirectory $binB

Start-Sleep 100
"alive: A=$(-not $pa.HasExited) (code=$($pa.ExitCode))  B=$(-not $pb.HasExited) (code=$($pb.ExitCode))"
Get-Process -Name "Poppy_Playtime*" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 3

$after = @(Get-ChildItem $crashDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
$new = $after | Where-Object { $before -notcontains $_ }
"new crash reports during run: $($new.Count)"
$new | ForEach-Object { "  $_" }

foreach ($pair in @(@("A", $binA), @("B", $binB))) {
    $who = $pair[0]; $bin = $pair[1]
    $lines = @(Select-String -Path "$bin\UE4SS.log" -Pattern "PoppyCoop" -ErrorAction SilentlyContinue | ForEach-Object { $_.Line })
    "===== player $who : $($lines.Count) PoppyCoop lines ====="
    $lines | Select-Object -First 3
    "  ..."
    $lines | Select-Object -Last 2
}
"===== state files ====="
Get-ChildItem $net -Filter "*.state" -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name): " + ((Get-Content $_.FullName) -join " ") }
