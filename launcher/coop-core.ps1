# coop-core.ps1 - shared helpers for PoppyCoop: finding the game, preparing an
# instance, starting the relay and the game, and reading the connection state.
#
# Dot-sourced by PoppyCoop-Launcher.ps1 (the window) and coop-cli.ps1 (headless,
# used by the automated checks). Nothing here shows UI.

$script:RepoRoot = Split-Path -Parent $PSScriptRoot          # <repo>\
$script:RelayScript = Join-Path $script:RepoRoot "relay\cooprelay.py"
$script:DeployScript = Join-Path $script:RepoRoot "deploy.ps1"

# The DLL the relay needs for the Steam transport. Pin from
# playbook/networking-steam-spacewar.md: this exact build exports the flat C API.
$script:SteamDllSha256 = "eb17909a76668cf9ae0b92a618a34a50f6c73d3a6787cb4dd8ce36a8b10bfb75"
$script:SteamDllUrl = "https://github.com/rlabrecque/Steamworks.NET/releases/download/2025.164.1/Steamworks.NET-Standalone_2025.164.1.zip"

# ---------------------------------------------------------------- finding things

function Get-PoppyBin {
    # Accepts the game root, WindowsNoEditor\Poppy_Playtime, or Binaries\Win64.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $candidates = @(
        $Path,
        (Join-Path $Path "Binaries\Win64"),
        (Join-Path $Path "Poppy_Playtime\Binaries\Win64"),
        (Join-Path $Path "WindowsNoEditor\Poppy_Playtime\Binaries\Win64")
    )
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c "Poppy_Playtime-Win64-Shipping.exe")) {
            return (Resolve-Path -LiteralPath $c).Path
        }
    }
    return $null
}

function Find-PoppyInstall {
    # Looks in every Steam library the registry and libraryfolders.vdf mention.
    $roots = @()
    $steam = (Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
    if ($steam) { $roots += $steam }
    $roots += @("C:\Program Files (x86)\Steam", "C:\Steam", "D:\Steam")
    $seen = @{}
    foreach ($root in $roots) {
        if (-not $root -or $seen.ContainsKey($root.ToLower())) { continue }
        $seen[$root.ToLower()] = $true
        $libraries = @()
        $vdf = Join-Path $root "steamapps\libraryfolders.vdf"
        if (Test-Path -LiteralPath $vdf) {
            $text = Get-Content -LiteralPath $vdf -Raw
            foreach ($m in [regex]::Matches($text, '"path"\s+"([^"]+)"')) {
                $libraries += $m.Groups[1].Value.Replace('\\', '\')
            }
        }
        $libraries += $root
        foreach ($lib in $libraries) {
            $game = Join-Path $lib "steamapps\common\Poppy Playtime"
            $bin = Get-PoppyBin $game
            if ($bin) { return $bin }
        }
    }
    return $null
}

function Get-PythonExe {
    foreach ($name in @("python", "python3", "py")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { return $cmd.Source }
    }
    return $null
}

function Get-FileSha256 {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
}

function Get-SteamDllInfo {
    # Where the relay's steam_api64.dll is, and whether it is the pinned build.
    param([string]$DllDir)
    if ([string]::IsNullOrWhiteSpace($DllDir)) { return @{ Path = $null; Pinned = $false } }
    $candidates = @(
        (Join-Path $DllDir "steam_api64.dll"),
        (Join-Path $DllDir "Windows-x64\steam_api64.dll")
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) {
            $hash = Get-FileSha256 $c
            return @{ Path = (Resolve-Path -LiteralPath $c).Path; Pinned = ($hash -eq $script:SteamDllSha256) }
        }
    }
    return @{ Path = $null; Pinned = $false }
}

function Test-PoppySetup {
    # Returns a list of human-readable problems; empty means ready to play.
    param([string]$Bin, [string]$Transport, [string]$DllDir, [string]$Python)
    $problems = @()
    if (-not $Bin) {
        $problems += "Не найдена папка игры. Укажите ...\WindowsNoEditor\Poppy_Playtime\Binaries\Win64"
    } else {
        if (-not (Test-Path (Join-Path $Bin "UE4SS.dll"))) {
            $problems += "В папке игры нет UE4SS.dll - сначала установите UE4SS v3.0.1"
        }
        if (-not (Test-Path (Join-Path $Bin "Mods"))) {
            $problems += "В папке игры нет папки Mods - UE4SS установлен не полностью"
        }
    }
    if (-not $Python) {
        $problems += "Не найден Python. Установите Python 3 и добавьте его в PATH"
    }
    if (-not (Test-Path -LiteralPath $script:RelayScript)) {
        $problems += "Не найден relay\cooprelay.py рядом с лончером"
    }
    if ($Transport -eq "steam") {
        $dll = Get-SteamDllInfo $DllDir
        if (-not $dll.Path) {
            $problems += "Не найден steam_api64.dll. Скачайте Steamworks.NET-Standalone_2025.164.1.zip и распакуйте Windows-x64\steam_api64.dll"
        } elseif (-not $dll.Pinned) {
            $problems += "steam_api64.dll не тот сборки (нужен Steamworks.NET-Standalone 2025.164.1) - в нём может не быть нужных функций"
        }
    }
    return $problems
}

# ------------------------------------------------------------- session plumbing

function Install-PoppyInstance {
    # Deploy the mod into this copy of the game and tell it who it is.
    param([string]$Bin, [string]$PlayerId, [string]$NetDir)
    if (-not (Test-Path -LiteralPath $script:DeployScript)) {
        throw "deploy.ps1 not found: $($script:DeployScript)"
    }
    New-Item -ItemType Directory -Force -Path $NetDir | Out-Null
    Remove-Item (Join-Path $NetDir "*.state") -Force -ErrorAction SilentlyContinue
    $out = & $script:DeployScript -TestBin $Bin -PlayerId $PlayerId -NetDir $NetDir 2>&1
    return ($out | Out-String)
}

function New-RelayArgs {
    param(
        [string]$Transport = "steam",
        [string]$Role = "host",
        [string]$SelfId = "A",
        [string]$PeerId = "B",
        [string]$NetDir,
        [string]$Lobby = "0",
        [string]$DllDir,
        [int]$Port = 27099,
        [string]$HostAddress = "127.0.0.1"
    )
    $a = @("--transport", $Transport, "--role", $Role, "--self", $SelfId, "--peer", $PeerId, "--netdir", $NetDir)
    if ($Transport -eq "steam") { $a += @("--dll", $DllDir) }
    if ($Role -eq "client") {
        if ($Transport -eq "steam") { $a += @("--lobby", $Lobby) } else { $a += @("--host", $HostAddress) }
    }
    if ($Transport -eq "udp") { $a += @("--port", "$Port") }
    # Quote anything that could contain spaces (every path here can).
    $quoted = $a | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
    return ($quoted -join " ")
}

function Start-PoppyRelay {
    # Start the relay hidden, with its output going to files we can read.
    # NOTE: never name a parameter $Args - that is an automatic variable and
    # PowerShell will not bind it (same trap as $A / $a).
    param([string]$Python, [string]$ArgLine, [string]$LogDir, [string]$Tag)
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $outLog = Join-Path $LogDir "relay-$Tag.out.log"
    $errLog = Join-Path $LogDir "relay-$Tag.err.log"
    Remove-Item $outLog, $errLog -Force -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath $Python `
        -ArgumentList ('"' + $script:RelayScript + '" ' + $ArgLine) `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    return @{ Process = $p; OutLog = $outLog; ErrLog = $errLog }
}

function Start-PoppyGame {
    param([string]$Bin)
    return (Start-Process -FilePath (Join-Path $Bin "Poppy_Playtime-Win64-Shipping.exe") `
        -WorkingDirectory $Bin -PassThru)
}

function Get-PeerLink {
    # Is the other player's position still arriving?
    param([string]$NetDir, [string]$PeerId)
    $f = Join-Path $NetDir ($PeerId + ".state")
    if (-not (Test-Path -LiteralPath $f)) {
        return @{ Ok = $false; AgeSec = $null; Text = "нет данных" }
    }
    $age = ((Get-Date) - (Get-Item -LiteralPath $f).LastWriteTime).TotalSeconds
    if ($age -lt 3) {
        return @{ Ok = $true; AgeSec = $age; Text = ("на связи, {0:N1} с назад" -f $age) }
    }
    return @{ Ok = $false; AgeSec = $age; Text = ("молчит {0:N0} с" -f $age) }
}

function Get-LobbyIdFromLog {
    # The relay prints "LOBBY READY. Friend joins with: --lobby <id>".
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $text = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if (-not $text) { return $null }
    $m = [regex]::Match($text, "--lobby\s+(\d+)")
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

# ------------------------------------------------------------------- the config

function Get-DefaultConfigPath { return (Join-Path $PSScriptRoot "launcher.json") }

function Save-PoppyConfig {
    param([hashtable]$Config, [string]$Path)
    if (-not $Path) { $Path = Get-DefaultConfigPath }
    # Two launchers can be open on one PC (local-test mode). A shared config file
    # must never take a session down, so retry briefly and then give up quietly.
    for ($i = 0; $i -lt 4; $i++) {
        try {
            ($Config | ConvertTo-Json) | Set-Content -LiteralPath $Path -Encoding UTF8
            return
        } catch {
            Start-Sleep -Milliseconds 200
        }
    }
}

function Load-PoppyConfig {
    param([string]$Path)
    if (-not $Path) { $Path = Get-DefaultConfigPath }
    if (-not (Test-Path -LiteralPath $Path)) { return @{} }
    try {
        $obj = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $table = @{}
        foreach ($p in $obj.PSObject.Properties) { $table[$p.Name] = $p.Value }
        return $table
    } catch {
        return @{}
    }
}
