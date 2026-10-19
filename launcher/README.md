# PoppyCoop launcher

A small window that does the whole setup for one session: it installs the mod into the copy
of the game you point it at, starts the relay, starts the game, and then shows the lobby id,
the state of both processes and whether the other player's position is still arriving.

It is a **desktop window, not an in-game overlay**, and that is a limitation of the tooling,
not a choice: UE4SS's Lua API has no GUI bindings — only C++ mods can register an ImGui tab —
and this project has no C++ compiler behind it. A Lua mod can print to the UE4SS console, so
the in-game side stays the console commands in `PoppyCoop/Scripts/main.lua`.

```
powershell -ExecutionPolicy Bypass -File launcher\PoppyCoop-Launcher.ps1
```

## Using it

| Field | What to put there |
|---|---|
| Папка игры | `...\WindowsNoEditor\Poppy_Playtime\Binaries\Win64` of a **copy** of the game |
| Папка со steam_api64.dll | the folder you unzipped `Windows-x64\steam_api64.dll` into |
| Через Steam | real play over Steam |
| Локальный тест | two windows on one PC (UDP, no Steam involved) |

**Host:** press *Создать игру*, wait for the id to appear, press *Скопировать*, send the id to
the friend by any means (Steam chat, Discord).

**Friend:** put the id into the lower field and press *Подключиться*. In local-test mode that
field holds the host's IP instead (`127.0.0.1` on one PC) and the port defaults to 27099.

The status line reads *релей* (the helper process), *игра* (the game process) and *друг* (how
long ago the other player's state file changed — under 3 s is "на связи"). The log pane mirrors
the relay's own output, including the lobby id line.

## What it checks before starting

* the folder really holds `Poppy_Playtime-Win64-Shipping.exe`
* UE4SS is installed there (`UE4SS.dll`, `Mods\`)
* Python 3 is on `PATH`
* `relay\cooprelay.py` sits next to the launcher
* in Steam mode, `steam_api64.dll` exists **and** is the pinned build — the DLL inside the game
  does not export the flat API the relay needs, and an arbitrary DLL from the internet is not
  guaranteed to either

The launcher says which of those is missing instead of failing later with a stack trace.

If the game folder is inside `steamapps\common`, the check notes that it is your main install:
the mod adds a `Mods\PoppyCoop` folder there. Use a copy for experiments.

## Headless use and tests

`coop-cli.ps1` does the same thing without a window — useful on a machine with no desktop, and
it is what the automated checks drive:

```
powershell -ExecutionPolicy Bypass -File launcher\coop-cli.ps1 -Role host -Transport udp `
    -GameBin "<...>\Binaries\Win64" -NetDir "<...>\coop-net\A"
```

Useful switches: `-NoGame` (start the relay only), `-NoDeploy` (leave the copy alone),
`-Duration <sec>` (stop by itself), `-SelfTest` (check the helpers and the argument building,
start nothing).

`coop-cli.ps1 -SelfTest` prints the relay arguments it would use and whether the helpers find
the game, Python and the relay — a fast way to see what the window would do.

The window itself has a click-free self-check used by the automated runs:

```
set POPPYCOOP_UI_SELFTEST=host      &:: or "ui" for "build the window only"
set POPPYCOOP_UI_GAME=<...>\Binaries\Win64
set POPPYCOOP_UI_TRANSPORT=udp
set POPPYCOOP_UI_NOGAME=1
set POPPYCOOP_UI_SECONDS=20
powershell -ExecutionPolicy Bypass -File launcher\PoppyCoop-Launcher.ps1
```

It builds the real window, starts a real session, pumps the message loop, prints the log and
stops everything. `POPPYCOOP_UI_NOGAME` skips starting the game (the relay and the state files
still work, so connection checks stay cheap).

## Files

| File | Role |
|---|---|
| `PoppyCoop-Launcher.ps1` | the window (WinForms, PowerShell 5.1) |
| `coop-core.ps1` | finding the game, preparing a copy, starting the relay and the game |
| `coop-cli.ps1` | the same, headless, plus `-SelfTest` |
| `launcher.json` | remembers paths and the last used lobby id (not in git) |
