# PoppyCoop-Launcher.ps1 - the connection window.
#
#   powershell -ExecutionPolicy Bypass -File PoppyCoop-Launcher.ps1
#
# One window: point it at a copy of the game, pick "Через Steam", press
# "Создать игру" or "Подключиться". It deploys the mod, starts the relay and
# starts the game for you, then shows the lobby id, the game and peer status and
# the relay log.
#
# It is a desktop window and not an in-game overlay on purpose: the UE4SS Lua
# API has no GUI bindings (only C++ mods can register an ImGui tab), so an
# in-game menu is not reachable without a C++ compiler.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "coop-core.ps1")

$script:Session = @{ Relay = $null; Game = $null; Role = $null; PlayerId = $null; PeerId = $null; NetDir = $null; Transport = $null }
$script:LogOffsets = @{}
$script:AnnouncedLobby = $false

# ------------------------------------------------------------------ log plumbing

function Read-NewText {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    if (-not $script:LogOffsets.ContainsKey($Path)) { $script:LogOffsets[$Path] = 0 }
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($fs.Length -lt $script:LogOffsets[$Path]) { $script:LogOffsets[$Path] = 0 }
        $fs.Seek($script:LogOffsets[$Path], [System.IO.SeekOrigin]::Begin) | Out-Null
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        $text = $sr.ReadToEnd()
        $script:LogOffsets[$Path] = $fs.Position
        return $text
    } catch {
        return ""
    } finally {
        if ($fs) { $fs.Close() }
    }
}

function Write-Log {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return }
    $txtLog.AppendText($Text.TrimEnd() + [Environment]::NewLine)
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.ScrollToCaret()
}

# --------------------------------------------------------------------- the window

$form = New-Object System.Windows.Forms.Form
$form.Text = "PoppyCoop - подключение"
$form.ClientSize = New-Object System.Drawing.Size(600, 604)
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false
$form.StartPosition = "CenterScreen"
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

function New-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 200, [int]$H = 18)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size($W, $H)
    return $l
}

$form.Controls.Add((New-Label "Папка игры (...\WindowsNoEditor\Poppy_Playtime\Binaries\Win64)" 12 10 470))

$txtGame = New-Object System.Windows.Forms.TextBox
$txtGame.Location = New-Object System.Drawing.Point(12, 30)
$txtGame.Size = New-Object System.Drawing.Size(460, 24)
$form.Controls.Add($txtGame)

$btnGame = New-Object System.Windows.Forms.Button
$btnGame.Text = "Обзор..."
$btnGame.Location = New-Object System.Drawing.Point(478, 28)
$btnGame.Size = New-Object System.Drawing.Size(110, 26)
$form.Controls.Add($btnGame)

$form.Controls.Add((New-Label "Папка со steam_api64.dll (нужна для режима Steam)" 12 62 470))

$txtDll = New-Object System.Windows.Forms.TextBox
$txtDll.Location = New-Object System.Drawing.Point(12, 82)
$txtDll.Size = New-Object System.Drawing.Size(460, 24)
$form.Controls.Add($txtDll)

$btnDll = New-Object System.Windows.Forms.Button
$btnDll.Text = "Обзор..."
$btnDll.Location = New-Object System.Drawing.Point(478, 80)
$btnDll.Size = New-Object System.Drawing.Size(110, 26)
$form.Controls.Add($btnDll)

$grpMode = New-Object System.Windows.Forms.GroupBox
$grpMode.Text = "Способ связи"
$grpMode.Location = New-Object System.Drawing.Point(12, 116)
$grpMode.Size = New-Object System.Drawing.Size(576, 58)
$form.Controls.Add($grpMode)

$rbSteam = New-Object System.Windows.Forms.RadioButton
$rbSteam.Text = "Через Steam (как у всех)"
$rbSteam.Location = New-Object System.Drawing.Point(14, 22)
$rbSteam.Size = New-Object System.Drawing.Size(200, 22)
$rbSteam.Checked = $true
$grpMode.Controls.Add($rbSteam)

$rbUdp = New-Object System.Windows.Forms.RadioButton
$rbUdp.Text = "Локальный тест (два окна на одном ПК или свой IP)"
$rbUdp.Location = New-Object System.Drawing.Point(224, 22)
$rbUdp.Size = New-Object System.Drawing.Size(340, 22)
$grpMode.Controls.Add($rbUdp)

$grpHost = New-Object System.Windows.Forms.GroupBox
$grpHost.Text = "1. Я создаю игру (хост)"
$grpHost.Location = New-Object System.Drawing.Point(12, 180)
$grpHost.Size = New-Object System.Drawing.Size(576, 86)
$form.Controls.Add($grpHost)

$btnHost = New-Object System.Windows.Forms.Button
$btnHost.Text = "Создать игру"
$btnHost.Location = New-Object System.Drawing.Point(14, 22)
$btnHost.Size = New-Object System.Drawing.Size(160, 46)
$grpHost.Controls.Add($btnHost)

$grpHost.Controls.Add((New-Label "ID лобби - передайте его другу:" 196 18 340))
$txtLobbyId = New-Object System.Windows.Forms.TextBox
$txtLobbyId.Location = New-Object System.Drawing.Point(196, 38)
$txtLobbyId.Size = New-Object System.Drawing.Size(230, 24)
$txtLobbyId.ReadOnly = $true
$grpHost.Controls.Add($txtLobbyId)

$btnCopy = New-Object System.Windows.Forms.Button
$btnCopy.Text = "Скопировать"
$btnCopy.Location = New-Object System.Drawing.Point(436, 36)
$btnCopy.Size = New-Object System.Drawing.Size(126, 27)
$grpHost.Controls.Add($btnCopy)

$grpJoin = New-Object System.Windows.Forms.GroupBox
$grpJoin.Text = "2. Я подключаюсь к другу"
$grpJoin.Location = New-Object System.Drawing.Point(12, 272)
$grpJoin.Size = New-Object System.Drawing.Size(576, 86)
$form.Controls.Add($grpJoin)

$grpJoin.Controls.Add((New-Label "ID лобби (Steam) или IP хоста (локальный тест):" 14 16 300))
$txtJoin = New-Object System.Windows.Forms.TextBox
$txtJoin.Location = New-Object System.Drawing.Point(14, 38)
$txtJoin.Size = New-Object System.Drawing.Size(240, 24)
$grpJoin.Controls.Add($txtJoin)

$btnJoin = New-Object System.Windows.Forms.Button
$btnJoin.Text = "Подключиться"
$btnJoin.Location = New-Object System.Drawing.Point(266, 22)
$btnJoin.Size = New-Object System.Drawing.Size(150, 46)
$grpJoin.Controls.Add($btnJoin)

$grpJoin.Controls.Add((New-Label "порт:" 426 18 40))
$txtPort = New-Object System.Windows.Forms.TextBox
$txtPort.Location = New-Object System.Drawing.Point(466, 15)
$txtPort.Size = New-Object System.Drawing.Size(90, 24)
$txtPort.Text = "27099"
$grpJoin.Controls.Add($txtPort)

$btnPaste = New-Object System.Windows.Forms.Button
$btnPaste.Text = "Вставить"
$btnPaste.Location = New-Object System.Drawing.Point(426, 45)
$btnPaste.Size = New-Object System.Drawing.Size(130, 27)
$grpJoin.Controls.Add($btnPaste)

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = "Остановить всё"
$btnStop.Location = New-Object System.Drawing.Point(12, 364)
$btnStop.Size = New-Object System.Drawing.Size(150, 30)
$form.Controls.Add($btnStop)

$btnCheck = New-Object System.Windows.Forms.Button
$btnCheck.Text = "Проверить готовность"
$btnCheck.Location = New-Object System.Drawing.Point(170, 364)
$btnCheck.Size = New-Object System.Drawing.Size(160, 30)
$form.Controls.Add($btnCheck)

$lblStatus = New-Label "релей: -   игра: -   друг: -" 340 370 250 40
$form.Controls.Add($lblStatus)

$form.Controls.Add((New-Label "Журнал:" 12 398 120))
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(12, 416)
$txtLog.Size = New-Object System.Drawing.Size(576, 176)
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
$form.Controls.Add($txtLog)

# ------------------------------------------------------------------ the behaviour

function Get-Transport { if ($rbUdp.Checked) { "udp" } else { "steam" } }

function Show-Notice {
    # Never block the window during the automated UI check.
    param([string]$Text)
    Write-Log $Text
    if ($env:POPPYCOOP_UI_SELFTEST) { return }
    [System.Windows.Forms.MessageBox]::Show($Text, "PoppyCoop") | Out-Null
}

function Stop-Session {
    $stopped = $false
    foreach ($key in @("Game", "Relay")) {
        $p = $script:Session[$key]
        if ($p) {
            if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; $stopped = $true }
            $script:Session[$key] = $null
        }
    }
    if ($stopped) { Write-Log "--- остановлено ---" }
    $script:Session.Role = $null
    $script:Session.OutLog = $null
    $script:Session.ErrLog = $null
    $script:AnnouncedLobby = $false
}

function Start-Session {
    param([string]$Role)
    Stop-Session

    $bin = Get-PoppyBin $txtGame.Text
    $python = Get-PythonExe
    $transport = Get-Transport
    $dllDir = $txtDll.Text
    $port = 27099
    if (-not [int]::TryParse($txtPort.Text, [ref]$port)) { $port = 27099 }

    $playerId = if ($Role -eq "host") { "A" } else { "B" }
    $peerId = if ($playerId -eq "A") { "B" } else { "A" }
    $lobby = "0"
    $hostAddress = "127.0.0.1"
    if ($Role -eq "client") {
        $value = $txtJoin.Text.Trim()
        if (-not $value) {
            Show-Notice "Введите ID лобби (Steam) или IP хоста."
            return
        }
        if ($transport -eq "steam") { $lobby = $value } else { $hostAddress = $value }
    }

    $problems = Test-PoppySetup -Bin $bin -Transport $transport -DllDir $dllDir -Python $python
    if ($problems.Count -gt 0) {
        Write-Log "--- не готово к запуску ---"
        $problems | ForEach-Object { Write-Log ("  - " + $_) }
        Show-Notice ($problems -join [Environment]::NewLine)
        return
    }

    $netDir = Join-Path $bin ("coop-net\" + $playerId)
    $logDir = Join-Path $netDir "logs"

    Write-Log ("=== {0}: игрок {1}, режим {2} ===" -f $(if ($Role -eq "host") { "создаю игру" } else { "подключаюсь" }), $playerId, $transport)
    try {
        Install-PoppyInstance -Bin $bin -PlayerId $playerId -NetDir $netDir | ForEach-Object { Write-Log ($_ -replace '\s+$', '') }
    } catch {
        Write-Log ("ошибка установки мода: " + $_.Exception.Message)
        return
    }

    $relayArgs = New-RelayArgs -Transport $transport -Role $Role -SelfId $playerId -PeerId $peerId `
        -NetDir $netDir -Lobby $lobby -DllDir $dllDir -Port $port -HostAddress $hostAddress
    Write-Log ("релей: " + $relayArgs)

    $relay = Start-PoppyRelay -Python $python -ArgLine $relayArgs -LogDir $logDir -Tag $playerId
    $script:Session.Relay = $relay.Process
    $script:Session.OutLog = $relay.OutLog
    $script:Session.ErrLog = $relay.ErrLog
    $script:Session.Role = $Role
    $script:Session.PlayerId = $playerId
    $script:Session.PeerId = $peerId
    $script:Session.NetDir = $netDir
    $script:Session.Transport = $transport

    Start-Sleep -Milliseconds 800
    if ($relay.Process.HasExited) {
        Write-Log "релей не запустился:"
        Write-Log (Read-NewText $relay.ErrLog)
        return
    }

    if ($env:POPPYCOOP_UI_NOGAME) {
        Write-Log "игра не запускается (POPPYCOOP_UI_NOGAME)"
    } else {
        $game = Start-PoppyGame -Bin $bin
        $script:Session.Game = $game
        Write-Log ("игра запущена (pid {0}), ждём загрузки" -f $game.Id)
    }

    Save-Config
}

function Update-Ui {
    $out = $script:Session.OutLog
    if ($out) { Write-Log (Read-NewText $out) }

    if ($script:Session.Role -eq "host" -and -not $script:AnnouncedLobby) {
        $id = Get-LobbyIdFromLog $out
        if ($id) {
            $txtLobbyId.Text = $id
            $script:AnnouncedLobby = $true
            Write-Log ("ID ЛОББИ ГОТОВ: {0} - скопируйте и передайте другу" -f $id)
        }
    }

    $relayState = "нет"
    if ($script:Session.Relay) {
        if ($script:Session.Relay.HasExited) {
            $relayState = "остановился"
            Write-Log "релей завершился:"
            Write-Log (Read-NewText $script:Session.ErrLog)
            $script:Session.Relay = $null
        } else {
            $relayState = "работает"
        }
    }

    $gameState = "нет"
    if ($script:Session.Game) {
        if ($script:Session.Game.HasExited) { $gameState = "закрыта"; $script:Session.Game = $null } else { $gameState = "запущена" }
    }

    $peerState = "-"
    if ($script:Session.NetDir) {
        $peerState = (Get-PeerLink -NetDir $script:Session.NetDir -PeerId $script:Session.PeerId).Text
    }

    $lblStatus.Text = ("релей: {0}   игра: {1}`r`nдруг: {2}" -f $relayState, $gameState, $peerState)
}

function Save-Config {
    Save-PoppyConfig -Config @{
        game = $txtGame.Text
        dll = $txtDll.Text
        transport = Get-Transport
        join = $txtJoin.Text
        port = $txtPort.Text
        python = (Get-PythonExe)
    }
}

# --------------------------------------------------------------- button handlers

$btnGame.add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Выберите папку Binaries\Win64 копии игры"
    if ($dlg.ShowDialog() -eq "OK") { $txtGame.Text = $dlg.SelectedPath }
})

$btnDll.add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Выберите папку, где лежит steam_api64.dll"
    if ($dlg.ShowDialog() -eq "OK") { $txtDll.Text = $dlg.SelectedPath }
})

$btnCopy.add_Click({
    if ($txtLobbyId.Text) {
        Set-Clipboard -Value $txtLobbyId.Text
        Write-Log "ID лобби скопирован в буфер обмена"
    }
})

$btnPaste.add_Click({
    try { $txtJoin.Text = (Get-Clipboard).Trim() } catch { }
})

$btnCheck.add_Click({
    $bin = Get-PoppyBin $txtGame.Text
    $problems = Test-PoppySetup -Bin $bin -Transport (Get-Transport) -DllDir $txtDll.Text -Python (Get-PythonExe)
    if ($problems.Count -eq 0) {
        Write-Log ("--- всё готово: {0}" -f $bin)
        if ($bin -match '\\steamapps\\common\\' -and $bin -notmatch 'coop-work') {
            Write-Log "! это ваша основная установка игры: мод добавит в неё папку Mods\PoppyCoop. Для опытов лучше копия."
        }
    } else {
        $problems | ForEach-Object { Write-Log ("  - " + $_) }
    }
})

$btnHost.add_Click({ try { Start-Session -Role "host" } catch { Show-Notice ("ошибка запуска: " + $_.Exception.Message) } })
$btnJoin.add_Click({ try { Start-Session -Role "client" } catch { Show-Notice ("ошибка запуска: " + $_.Exception.Message) } })
$btnStop.add_Click({ Stop-Session })

$form.add_FormClosing({
    Save-Config
    Stop-Session
})

# ------------------------------------------------------------------------ startup

$cfg = Load-PoppyConfig
if ($cfg.game) { $txtGame.Text = $cfg.game } else { $g = Find-PoppyInstall; if ($g) { $txtGame.Text = $g } }
if ($cfg.dll) { $txtDll.Text = $cfg.dll }
if ($cfg.transport -eq "udp") { $rbUdp.Checked = $true } else { $rbSteam.Checked = $true }
if ($cfg.join) { $txtJoin.Text = $cfg.join }
if ($cfg.port) { $txtPort.Text = $cfg.port }

if (-not $txtDll.Text) {
    foreach ($cand in @(
        (Join-Path $script:RepoRoot "steam"),
        (Join-Path $script:RepoRoot "relay\steam"),
        $PSScriptRoot
    )) {
        if ($cand -and (Test-Path -LiteralPath (Join-Path $cand "steam_api64.dll"))) { $txtDll.Text = $cand; break }
    }
}

Write-Log "PoppyCoop: выберите папку игры и нажмите «Создать игру» или «Подключиться»."
Write-Log "Мод ставится только в указанную копию игры. Основную установку лучше не трогать."
Write-Log ("Python: {0}" -f (Get-PythonExe))
if (-not (Get-PythonExe)) {
    Write-Log "! Python не найден в PATH - без него релей не запустится (нужен Python 3)."
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 700
$timer.add_Tick({ try { Update-Ui } catch { Write-Log ("сбой обновления окна: " + $_.Exception.Message) } })
$timer.Start()

# Automated UI check (no clicks): build the window, optionally start a session,
# pump the message loop, print the log, stop everything.
#   set POPPYCOOP_UI_SELFTEST=host|ui   (ui = build the window only)
#   set POPPYCOOP_UI_GAME=<bin>, POPPYCOOP_UI_TRANSPORT=udp, POPPYCOOP_UI_JOIN=<ip>,
#       POPPYCOOP_UI_SECONDS=<n>, POPPYCOOP_UI_NOGAME=1
if ($env:POPPYCOOP_UI_SELFTEST) {
    $seconds = 10
    if ($env:POPPYCOOP_UI_SECONDS) { $seconds = [int]$env:POPPYCOOP_UI_SECONDS }
    if ($env:POPPYCOOP_UI_GAME) { $txtGame.Text = $env:POPPYCOOP_UI_GAME }
    if ($env:POPPYCOOP_UI_TRANSPORT -eq "udp") { $rbUdp.Checked = $true } else { $rbSteam.Checked = $true }
    if ($env:POPPYCOOP_UI_JOIN) { $txtJoin.Text = $env:POPPYCOOP_UI_JOIN }
    $mode = $env:POPPYCOOP_UI_SELFTEST
    try {
        if ($mode -eq "host" -or $mode -eq "client") { Start-Session -Role $mode }
        $deadline = (Get-Date).AddSeconds($seconds)
        while ((Get-Date) -lt $deadline) {
            Update-Ui
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 500
        }
        $lobby = $txtLobbyId.Text
        $status = $lblStatus.Text
    } finally {
        # Always take the relay and the game down, even if a step threw.
        Stop-Session
    }
    Write-Output "--- ui self-test ---"
    Write-Output ("mode={0} lobby=[{1}]" -f $mode, $lobby)
    Write-Output ("status: " + ($status -replace "`r`n", " | "))
    Write-Output $txtLog.Text
    $form.Dispose()
    exit 0
}

[void]$form.ShowDialog()
