# QuakeKey

[![CI](https://github.com/abd3lraouf-studios/QuakeKey/actions/workflows/ci.yml/badge.svg)](https://github.com/abd3lraouf-studios/QuakeKey/actions/workflows/ci.yml)

A reliable global hotkey for the [Windows Terminal](https://github.com/microsoft/terminal) quake window.
Press **F12** (or a key you choose) anywhere and the Terminal drops down from the top of the screen with the cursor in
it; press it again and it slides away.

Windows Terminal has a quake mode of its own, but its global hotkey breaks in everyday situations:

| Situation | Terminal's own hotkey | QuakeKey |
|---|---|---|
| An app running as administrator has focus | the key never arrives | works |
| The quake window is on screen but another window has focus | often does nothing until you click the desktop | focuses it |
| You also run an elevated Terminal | both Terminals fight over the key; the admin one may win | always your normal Terminal |
| You closed every Terminal window | the hotkey is gone until you start Terminal again | Terminal is kept ready in the background |

The causes are in Terminal's own code and in how Windows isolates admin windows; see
[docs/how-it-works.md](docs/how-it-works.md).

## Features

- One key toggles the quake window from anywhere, including over elevated apps, and always gives it keyboard focus.
- Your Terminal stays a normal, non-admin process; QuakeKey only drives it.
- Terminal is started at logon in its windowless background mode, so the first press is fast and nothing flashes.
- Slide-down/slide-up animation and monitor behavior are configurable.
- One-command install with a single UAC prompt; the uninstaller puts your Terminal key bindings back.
- Built from source on your machine with the compiler that ships with Windows. No binaries, no runtime to install.

## Requirements

- Windows 10 or 11, 64-bit, and an administrator account (one UAC prompt during install).
- UAC enabled and not running as the built-in Administrator account: QuakeKey distinguishes your normal Terminal
  from elevated ones, which needs Windows' two integrity levels to exist.
- Windows Terminal **1.24 or newer**, the Microsoft Store / winget package (the one built into Windows 11).
  Terminal Preview, Canary and portable builds are not supported.
- Windows PowerShell 5.1 (built in) or PowerShell 7 to run the installer.

Tested on Windows 11 (build 26300) with Windows Terminal 1.24.12741.0 on two monitors.

## Install

Open Windows Terminal at least once (so it creates its `settings.json`), then:

```powershell
git clone https://github.com/abd3lraouf-studios/QuakeKey.git
cd QuakeKey
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

No git? Download the ZIP from GitHub, extract it, and run the same `powershell` line inside the folder.

The installer:

1. builds `QuakeKey.exe` from `src\QuakeKey.cs` with the .NET Framework compiler in Windows;
2. asks for administrator permission **once**, installs the exe, registers its scheduled tasks and starts it;
3. updates Windows Terminal's `settings.json` (a backup is saved first) so Terminal stops claiming the key itself;
4. checks the log and tells you the result.

If you keep the default **F12**, Windows may have it reserved for its debugger break key. The installer moves that key
to Scroll Lock and tells you to **reboot once**; after the reboot F12 is free.

### Options

| Option | Default | Meaning |
|---|---|---|
| `-Key <spec>` | `F12` | The hotkey: modifiers `ctrl`, `alt`, `shift`, `win` joined with `+` to one key, e.g. `ctrl+alt+t`, `win+backtick`, `shift+F12`, `pause`. Keys: `F1`-`F24`, `A`-`Z`, `0`-`9`, `numpad0`-`numpad9`, `space`, `tab`, `enter`, `esc`, `insert`, `delete`, `home`, `end`, `pageup`, `pagedown`, arrows, `pause`, `scrolllock`, `apps`, `backtick`, `vk:0xNN`. Typing keys need a modifier. |
| `-Monitor <any\|toMouse\|toCurrent>` | `any` | `any`: the window opens where it was last and the key always hides it. `toMouse`: it opens on the mouse's monitor (the key then moves a focused window to the mouse's monitor instead of hiding it). `toCurrent`: the monitor of the focused window. |
| `-Animation <ms>` | `200` | Slide duration; `0` turns the animation off. |
| `-SkipTerminalSettings` | | Don't touch `settings.json`; print the change to make by hand. |
| `-Force` | | Continue with a Windows Terminal older than 1.24. |

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Key ctrl+alt+t -Monitor toMouse
```

`-Monitor` and `-Animation` are applied when the installer creates Terminal's quake action, and whenever you pass them;
otherwise the values already in your Terminal settings are kept.

### Change options or update

Run `install.ps1` again, with new options or after `git pull`. It replaces the installed copy and keeps the record it
needs to undo its Terminal changes later.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

It asks for administrator permission once, removes everything below, and restores the Terminal key bindings it changed
(your previous quake key comes back). `-KeepTerminalSettings` leaves `settings.json` alone; `-KeepLogs` keeps the log.

## What gets installed

| What | Where |
|---|---|
| The program | `C:\Program Files\QuakeKey\QuakeKey.exe` |
| Its log (admins write, users read) | `C:\ProgramData\QuakeKey\quakekey.log` |
| Hotkey owner: runs elevated at logon, restarted if it fails | Task Scheduler `\QuakeKey\Hotkey` |
| Terminal starters: normal privileges, run on demand | `\QuakeKey\StartShown`, `\QuakeKey\StartHidden` |
| Terminal `settings.json` changes, backups, undo record | `%LOCALAPPDATA%\QuakeKey\` |
| Only if your key is the debugger break key (default F12) | `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AeDebug` `UserDebuggerHotKey` → `0x91` (Scroll Lock) |

The Terminal settings change: the quake window gets one `globalSummon` action (yours is reused if you have one), bound
only to `ctrl+alt+shift+f24`, a chord nobody presses; Terminal's default Win+\` quake key is switched off; any other
global-summon key is removed. Comments in `settings.json` are not kept (they are in the backup). The uninstaller leaves
`UserDebuggerHotKey` as it is.

## Troubleshooting

Every key press writes one line to `C:\ProgramData\QuakeKey\quakekey.log` saying what happened and which window had
focus. Terminal starts are logged in `%LOCALAPPDATA%\QuakeKey\launcher.log`.

| Log line | Meaning / fix |
|---|---|
| `F12 registered` | Working. |
| `could not be registered (error 1409): Windows reserves it for the debugger break key` | Reboot (after the installer moved the debugger key), or run the installer again. |
| `could not be registered (error 1409): another program holds it` | Another app owns that key. Pick another `-Key`, or check that Terminal's `settings.json` doesn't bind it. |
| `WARNING: no Terminal holds ctrl+alt+shift+f24` | Terminal's quake binding is missing (settings.json was edited or reset). Run the installer again. QuakeKey still shows/hides the window meanwhile. |
| `Terminal did not focus it; focused with AttachThreadInput` | Normal when an admin window had focus. |
| `FAILED to focus` | Please open an issue with the log lines around it. |

- **The installer refuses: "global-summon keys for other windows".** QuakeKey triggers Terminal's first global-summon
  binding, so the quake toggle must be the only one. Remove the other `globalSummon` keys from `settings.json`.
- **Full-screen games.** Some games block global hotkeys while they have focus; no hotkey tool can get past that.
- **The first press after logon has no slide.** Terminal creates the quake window on that press and shows new windows
  without the animation; later presses slide.

## How it works

QuakeKey runs elevated so Windows delivers the key to it whatever has focus. On a press it sends Terminal's own
global-summon message to your normal (non-elevated) Terminal, so Terminal does the toggle with its animation and monitor
rules. If the window should now have focus but doesn't, QuakeKey gives it focus. A watchdog keeps a normal Terminal
running, starting it through a normal-privilege task so the shell never becomes admin.
Details, measurements and references to Terminal's source: [docs/how-it-works.md](docs/how-it-works.md).

## Development

```
src/QuakeKey.cs              the program (C#, .NET Framework 4.x, one file)
install.ps1, uninstall.ps1   entry points
scripts/QuakeKey.Common.ps1  shared code: build, Terminal settings analysis/edit/undo, elevation
scripts/Elevated.ps1         the elevated half of install/uninstall
tests/Run-Tests.ps1          builds the exe, tests the key parser and the settings logic on tests/fixtures
```

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1   # Windows PowerShell 5.1
pwsh -File .\tests\Run-Tests.ps1                                 # PowerShell 7
```

The tests install nothing. CI runs them in both shells on every push.

## License

[MIT](LICENSE)
