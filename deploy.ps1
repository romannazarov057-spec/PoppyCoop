# Deploy the PoppyCoop mod into the isolated test copy of the game.
# The owner's real install is never touched.
param(
    [string]$TestBin = "D:\coop-work\poppy-playtime\WindowsNoEditor\Poppy_Playtime\Binaries\Win64",
    [switch]$EnableProbe,
    [string]$PlayerId = "A",
    [string]$NetDir = ""
)

$ErrorActionPreference = "Stop"
$src = Join-Path $PSScriptRoot "PoppyCoop"
$dst = Join-Path $TestBin "Mods\PoppyCoop"

if (-not (Test-Path $TestBin)) { throw "test bin not found: $TestBin" }

robocopy $src $dst /E /NFL /NDL /NP /R:1 /W:1 | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with code $LASTEXITCODE" }

# Which player this copy is: the mod reads playerid.txt from its working directory
# (the game's Win64 folder). Lets two copies of the game run side by side.
Set-Content -Path (Join-Path $TestBin "playerid.txt") -Value $PlayerId -Encoding ascii
Write-Host "playerid=$PlayerId"

# Optional: this instance's transport folder, so two copies do not share one folder.
$netFile = Join-Path $TestBin "netdir.txt"
if ($NetDir -ne "") {
    Set-Content -Path $netFile -Value $NetDir -Encoding ascii
    Write-Host "netdir=$NetDir"
} else {
    Remove-Item $netFile -Force -ErrorAction SilentlyContinue
}

# Keep mods.txt authoritative: PoppyCoop on, CoopProbe off unless asked for.
$mods = Join-Path $TestBin "Mods\mods.txt"
$lines = Get-Content $mods | Where-Object { $_ -notmatch '^\s*CoopProbe\s*:' -and $_ -notmatch '^\s*PoppyCoop\s*:' }
$probe = if ($EnableProbe) { 1 } else { 0 }
$new = @()
$inserted = $false
foreach ($line in $lines) {
    if (-not $inserted -and $line -match '^\s*;\s*Built-in keybinds') {
        $new += "PoppyCoop : 1"
        $new += "CoopProbe : $probe"
        $inserted = $true
    }
    $new += $line
}
if (-not $inserted) {
    $new += "PoppyCoop : 1"
    $new += "CoopProbe : $probe"
}
$new | Out-File $mods -Encoding ascii
Write-Host "deployed PoppyCoop -> $dst (CoopProbe=$probe)"
Get-Content $mods
