# Manual proofs

`tests/Run-Tests.ps1` runs on every push. The scripts here demonstrate Windows behaviour the design depends on, or
bugs fixed in 1.1, and are too slow or need a desktop session for CI. Each prints `PROVEN` (exit 0) or
`NOT REPRODUCED` (exit 1), needs no admin rights, and removes whatever it created.

| Script | What it shows | Time |
|---|---|---|
| `Prove-RestartOnFailure.ps1` | Task Scheduler's restart-on-failure does not restart a program that exits with an error code. 1.0 relied on it. | ~3.5 min |
| `Prove-Supervisor.ps1` | The 5-minute repeating trigger with `MultipleInstances IgnoreNew` (here 1 minute) restarts the program after it stops, one copy at a time, indefinitely. | ~3.5 min |
| `Prove-SetWindowPosFlags.ps1` | 1.0's `SetWindowPos` call always failed (`SWP_NOACTIVATE` = 0x0800), and fixing only the flag would have made the quake window always-on-top (`(HWND)-1` is `HWND_TOPMOST`). | seconds |
| `Prove-WatchdogGrace.ps1` | 1.0's watchdog, compiled from git history against a fake clock, waited 10 minutes while logging "waiting 2 minutes" five times. | seconds |

```powershell
pwsh -File .\tests\manual\Prove-SetWindowPosFlags.ps1
powershell -ExecutionPolicy Bypass -File .\tests\manual\Prove-Supervisor.ps1
```

## End-to-end check on a real machine

The elevated install and uninstall run for real on CI, but CI has no desktop, no Windows Terminal and no admin
windows. After changing anything that runs elevated, check on a real PC:

1. `install.ps1` (accept the one UAC prompt). Expect "QuakeKey is installed. Press F12 ..." or the reboot message.
2. `Get-ScheduledTask -TaskPath "\QuakeKey\$((whoami /user /fo csv | ConvertFrom-Csv).SID)\"` lists Hotkey,
   StartShown and StartHidden; the log in `C:\ProgramData\QuakeKey\<SID>\quakekey.log` says `F12 registered`.
3. Press F12 over a normal window, over an elevated window (e.g. an admin Terminal), and with the quake window
   visible but unfocused. Each press logs one line; none says `FAILED`.
4. Close every Terminal window: the log says `Terminal exited; waiting 2 minutes ...` once, then starts one.
5. `Stop-Process -Name QuakeKey -Force` (elevated): within 5 minutes the task starts it again.
6. Run `install.ps1` again: it says `already set up for QuakeKey` and finishes normally.
7. `uninstall.ps1`: settings.json matches the backup taken by the first install (apart from formatting and
   comments), the tasks, `C:\Program Files\QuakeKey` and `C:\ProgramData\QuakeKey` are gone.
