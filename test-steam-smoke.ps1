# Steam backend smoke test: no game, no second account. Checks only that the relay
# initialises the real steam_api64.dll, logs on, creates a lobby and prints its id.
#
# Side effect to be aware of: while this runs, Steam shows the owner as playing
# "Spacewar" (AppID 480) to their friends.

$relay = "D:\coop-work\relay\cooprelay.py"
$dll   = "D:\coop-work\relay\steam"
$netS  = "D:\coop-work\relay\smoke"

$steam = Get-Process -Name "steam" -ErrorAction SilentlyContinue
"steam running: $([bool]$steam)"
if (-not $steam) { "Steam is not running - stop here and ask the owner to start it."; exit 1 }

New-Item -ItemType Directory -Force -Path $netS | Out-Null
Remove-Item "$netS\*" -Force -ErrorAction SilentlyContinue

$p = Start-Process python -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput "$netS\stdout.log" -RedirectStandardError "$netS\stderr.log" `
    -ArgumentList @($relay, "--transport", "steam", "--role", "host",
                    "--self", "A", "--peer", "B", "--netdir", $netS, "--dll", $dll,
                    "--log", "$netS\relay.log")

# Give Steam time to bring up the API and answer CreateLobby.
Start-Sleep 30
"alive after 30 s: $(-not $p.HasExited)"
if ($p.HasExited) { "exit code: $($p.ExitCode)" }

"===== relay log ====="
Get-Content "$netS\relay.log" -ErrorAction SilentlyContinue
"===== stderr ====="
Get-Content "$netS\stderr.log" -ErrorAction SilentlyContinue

if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
Start-Sleep 2
"--- done ---"
