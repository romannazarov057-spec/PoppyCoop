# PoppyCoop

Co-op for **Poppy Playtime: Chapter 1** (Unreal Engine 4.27). Work in progress.

What it does today: each player sees the other player as a second, player-shaped actor
("the puppet") standing where the other player really is. Movement is the only thing that
is synced so far — doors, the GrabPack, Huggy and the chapter objective are **not** synced
yet, so two players cannot finish the chapter together. Treat this as a foundation, not a
finished mod.

## Status

| Piece | State |
|---|---|
| Puppet: same mesh, material, scale and a walking animation as the player | works |
| Position sync, two real game instances on one PC, both directions | works (automated run) |
| Relay over UDP (`--transport udp`) | works |
| Relay over Steam P2P (`--transport steam`): init, logon, lobby created and entered | works |
| Steam P2P **message** leg (two Steam accounts, two machines) | **untested** — needs a second account |
| Game state (objectives, doors, GrabPack, Huggy) | not started |
| One-click host/join | not started |

Everything above is measured on UE 4.27.2, Steam build 21905565. Other builds are untested.

## Requirements

- Poppy Playtime: Chapter 1 (Steam). Verified against build 21905565.
- [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) v3.0.1 — the script mod loader. Newer
  versions may work; v3.0.1 is what this was built and tested against.
- Python 3 for the relay. Developed on 3.8.
- For real play over Steam: `steam_api64.dll` from the
  [Steamworks.NET standalone release](https://github.com/rlabrecque/Steamworks.NET/releases)
  (`Steamworks.NET-Standalone_2025.164.1.zip`, `Windows-x64/steam_api64.dll`). The DLL that
  ships inside the game is older and **does not export the flat API** this relay needs, so
  the game's own copy is not usable.

## Install

1. Install UE4SS 3.0.1 into the game, following its own instructions. This puts a `Mods`
   folder next to the game's `Binaries\Win64`.
2. Copy `PoppyCoop` into `<game>\WindowsNoEditor\Poppy_Playtime\Binaries\Win64\Mods\`.
3. Add the mod to `Mods\mods.txt`:
   ```
   PoppyCoop : 1
   ```
   `deploy.ps1` does steps 2 and 3 for you and also writes `playerid.txt` (which player this
   copy is):
   ```powershell
   powershell -ExecutionPolicy Bypass -File deploy.ps1 -TestBin "<game>\WindowsNoEditor\Poppy_Playtime\Binaries\Win64" -PlayerId A -NetDir "<game>\WindowsNoEditor\Poppy_Playtime\Binaries\Win64\coop-net\A"
   ```
   Use a different `-PlayerId` (B) and `-NetDir` for the second copy.

**Use a copy of the game, not your only install.** The mod is read-only towards the game, but
UE4SS and test runs are best kept away from the install you play on.

## Playing

Each player runs:

```
python relay\cooprelay.py --transport steam --role host   --self A --peer B --netdir <...>\coop-net\A --dll <dir-with-steam_api64.dll>
python relay\cooprelay.py --transport steam --role client --lobby <id> --self B --peer A --netdir <...>\coop-net\B --dll <dir-with-steam_api64.dll>
```

The host prints a lobby id; the client joins with it. The relay reads `<netdir>\<self>.state`
(the mod writes it) and writes whatever comes back to `<netdir>\<peer>.state` (the mod reads
it and drives the puppet there).

The relay also has a `--transport udp` mode that needs no Steam at all. It is useful for
testing two clients on one PC; it needs a reachable port, so it is not how you play over the
internet.

## How it works, briefly

- The mod runs under UE4SS in Lua (`PoppyCoop/Scripts/main.lua`). It cannot open sockets, so
  it talks to the relay through small state files.
- The puppet is created with the console `summon` command. UE4SS's own spawn path crashes on
  this engine (upstream issue #527 in v3.0.1), and `summon` is the game's own code path.
- The player's animation blueprint cannot go on the puppet: it is procedural and casts to the
  owning pawn, so a bare actor makes it read through a failed cast. The puppet uses a
  single-node `legs_Walk_anim` sequence on the same skeleton instead.
- Everything that touches an engine object runs on the game thread. Off-thread calls crash
  the game or freeze the mod's own loop silently.

Deeper notes, including the measurements behind each claim and the dead ends (no usable bone
read, screen-diff tests are too noisy in this game), are in the
[coop-anything write-up](https://github.com/cranebeaker/coop-anything/tree/main/games/poppy-playtime).

## Known issues

- Only movement is synced. Doors, objectives and interaction are not, so the chapter cannot be
  completed together.
- The puppet plays a fixed walk animation, not one driven by real movement speed.
- The Steam message leg has never been run with two accounts; only UDP has carried lines
  between two clients.
- The mod is loaded by every copy of the game including single-player sessions; it does
  nothing without a peer state file, but it does spawn a puppet locally.

## License

No license chosen yet. Until then, all rights reserved by the author.
