# coop-cli.ps1 - the same thing the window does, but headless.
# Used by the automated checks and by anyone who prefers a console.
#
#   powershell -ExecutionPolicy Bypass -File coop-cli.ps1 -Role host -Transport udp -GameBin <...> -NetDir <...>
#
# See -SelfTest for a no-side-effects check of the helpers and the arguments.

param(
    [ValidateSet("host", "client")][string]$Role = "host",
    [ValidateSet("steam", "udp")][string]$Transport = "udp",
    [string]$GameBin,
    [string]$DllDir,
    [string]$Lobby = "0",
    [string]$HostAddress = "127.0.0.1",
    [int]$Port = 27099,
    [string]$PlayerId,
    [string]$NetDir,
    [string]$LogDir,
    [switch]$NoGame,
    [switch]$NoDeploy,
    [int]$Duration = 0,          # seconds to stay up; 0 = until Ctrl+C
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "coop-core.ps1")

if ($SelfTest) {
    Write-Host "self-test: helpers and arguments, nothing is started"
    $fake = Get-PoppyBin "C:\definitely\not\here"
    Write-Host ("  Get-PoppyBin on a bogus path      -> {0}" -f ($(if ($fake) { $fake } else { "null (correct)" })))
    $found = Find-PoppyInstall
    Write-Host ("  Find-PoppyInstall                 -> {0}" -f ($(if ($found) { $found } else { "not found" })))
    Write-Host ("  Get-PythonExe                     -> {0}" -f (Get-PythonExe))
    Write-Host ("  relay script exists               -> {0}" -f (Test-Path -LiteralPath $script:RelayScript))
    $hostArgs = New-RelayArgs -Transport steam -Role host -SelfId A -PeerId B -NetDir "C:\a b\net" -DllDir "C:\dll"
    Write-Host ("  host args (steam)                 -> {0}" -f $hostArgs)
    $joinArgs = New-RelayArgs -Transport steam -Role client -SelfId B -PeerId A -NetDir "C:\net B" -Lobby 109775242000000000 -DllDir "C:\dll"
    Write-Host ("  client args (steam)               -> {0}" -f $joinArgs)
    $udpArgs = New-RelayArgs -Transport udp -Role client -SelfId B -PeerId A -NetDir "C:\net" -Port 27100
    Write-Host ("  client args (udp)                 -> {0}" -f $udpArgs)
    $expectedHost = '--transport steam --role host --self A --peer B --netdir "C:\a b\net" --dll C:\dll'
    Write-Host ("  host args match expected          -> {0}" -f ($hostArgs -eq $expectedHost))
    $expectedUdp = "--transport udp --role client --self B --peer A --netdir C:\net --host 127.0.0.1 --port 27100"
    Write-Host ("  udp args match expected           -> {0}" -f ($udpArgs -eq $expectedUdp))
    Write-Host ("  lobby id parsed from a log        -> {0}" -f (Get-LobbyIdFromLog (Join-Path $PSScriptRoot "nonexistent.log")))
    exit 0
}

if (-not $GameBin) { $GameBin = Find-PoppyInstall }
$Bin = Get-PoppyBin $GameBin
if (-not $PlayerId) { $PlayerId = if ($Role -eq "host") { "A" } else { "B" } }
$PeerId = if ($PlayerId -eq "A") { "B" } else { "A" }
if (-not $NetDir) {
    if (-not $Bin) { throw "no game folder; pass -GameBin" }
    $NetDir = Join-Path $Bin ("coop-net\" + $PlayerId)
}
if (-not $LogDir) { $LogDir = Join-Path $NetDir "logs" }
$Python = Get-PythonExe

$problems = Test-PoppySetup -Bin $Bin -Transport $Transport -DllDir $DllDir -Python $Python
if ($problems.Count -gt 0) {
    Write-Host "not ready:"
    $problems | ForEach-Object { Write-Host ("  - " + $_) }
    exit 2
}

Write-Host ("role={0} player={1} peer={2} transport={3}" -f $Role, $PlayerId, $PeerId, $Transport)
Write-Host ("game   = {0}" -f $Bin)
Write-Host ("netdir = {0}" -f $NetDir)

if (-not $NoDeploy) {
    Install-PoppyInstance -Bin $Bin -PlayerId $PlayerId -NetDir $NetDir | Out-Null
    Write-Host "mod deployed"
}

$relayArgs = New-RelayArgs -Transport $Transport -Role $Role -SelfId $PlayerId -PeerId $PeerId `
    -NetDir $NetDir -Lobby $Lobby -DllDir $DllDir -Port $Port -HostAddress $HostAddress
Write-Host ("relay  = {0}" -f $relayArgs)
$relay = Start-PoppyRelay -Python $Python -ArgLine $relayArgs -LogDir $LogDir -Tag $PlayerId

$game = $null
if (-not $NoGame) { $game = Start-PoppyGame -Bin $Bin }
if ($game) { Write-Host ("game started, pid {0}" -f $game.Id) }

$lobbySeen = $null
$deadline = if ($Duration -gt 0) { (Get-Date).AddSeconds($Duration) } else { $null }
try {
    while ($true) {
        Start-Sleep -Seconds 1
        if ($relay.Process.HasExited) {
            Write-Host ("relay exited with code {0}" -f $relay.Process.ExitCode)
            Get-Content -LiteralPath $relay.ErrLog -ErrorAction SilentlyContinue | Select-Object -Last 5 | ForEach-Object { Write-Host ("  ! " + $_) }
            break
        }
        if (-not $lobbySeen) {
            $lobbySeen = Get-LobbyIdFromLog $relay.OutLog
            if ($lobbySeen) { Write-Host ("LOBBY ID = {0}" -f $lobbySeen) }
        }
        $link = Get-PeerLink -NetDir $NetDir -PeerId $PeerId
        Write-Host ("[{0}] relay=alive lobby={1} peer={2}" -f (Get-Date -Format HH:mm:ss), $(if ($lobbySeen) { $lobbySeen } else { "-" }), $link.Text)
        if ($deadline -and (Get-Date) -gt $deadline) { break }
        if ($game -and $game.HasExited) { Write-Host "game exited"; break }
    }
} finally {
    foreach ($p in @($game, $relay.Process)) {
        if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
    Write-Host "stopped"
}
