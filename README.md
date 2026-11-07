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
[docs/how-it-works.md](docs/how-it-works.md), which links the exact lines of Terminal's source.

## Features

- One key toggles the quake window from anywhere, including over elevated apps, and always gives it keyboard focus.
- Your Terminal stays a normal, non-admin process; QuakeKey only drives it.
- Terminal is started at logon in its windowless background mode, so the first press is fast and nothing flashes.
- If QuakeKey ever stops, Task Scheduler starts it again within 5 minutes.
- Slide-down/slide-up animation and monitor behavior are configurable.
- One-command install with a single UAC prompt; the uninstaller puts your Terminal key bindings back.
- Built from source on your machine with the compiler that ships with Windows. No binaries, no runtime to install.
- Per user: several accounts on one PC can each install it with their own key.

## Requirements

The installer checks all of these and stops with an explanation if one is missing.

- Windows 10 or 11, 64-bit, and an administrator account (one UAC prompt during install).
- UAC on, and not the built-in Administrator account: QuakeKey tells your normal Terminal from elevated ones by the
  token's elevation, which needs Windows' split admin token.
- Windows Terminal **1.24 or newer**, the Microsoft Store / winget package (the one built into Windows 11), with its
  `wt.exe` app execution alias on (the default). Terminal Preview, Canary and portable builds are not driven.
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

1. checks the prerequisites above;
2. builds `QuakeKey.exe` from `src\QuakeKey.cs` with the .NET Framework compiler in Windows;
3. updates Windows Terminal's `settings.json` (a backup is saved first) so Terminal stops claiming the key itself;
4. asks for administrator permission **once**, installs the exe (checking it is the file it just built), registers
   your scheduled tasks and starts QuakeKey. If you cancel the prompt or this step fails, `settings.json` is put back;
5. waits for QuakeKey to report that it holds the key, and tells you the result.

If you keep the default **F12**, Windows may have it reserved for its debugger break key. The installer moves that key
to Scroll Lock and tells you to **reboot once**; after the reboot F12 is free. Uninstalling puts it back.

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

If `settings.json` is a symbolic or hard link (a dotfiles setup), the installer writes through it and the link stays.

### Change options or update

Run `install.ps1` again, with new options or after `git pull`. It replaces the installed copy and keeps the record it
needs to undo its Terminal changes later.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

It asks for administrator permission once, then:

- stops QuakeKey and removes your scheduled tasks and your log folder;
- restores the Terminal key bindings it changed (your previous quake key comes back);
- removes `%LOCALAPPDATA%\QuakeKey` except `backups`, the copies of `settings.json` taken before each change;
- if no other account on the PC still uses QuakeKey: removes `C:\Program Files\QuakeKey` and
  `C:\ProgramData\QuakeKey`, and puts the debugger break key back where it was (takes effect after a reboot).

| Option | Meaning |
|---|---|
| `-KeepTerminalSettings` | Leave `settings.json` alone. Terminal then has no working quake key until you bind one. |
| `-KeepLogs` | Keep the log folder(s) under `C:\ProgramData\QuakeKey`. |
| `-KeepDebuggerKey` | Leave the debugger break key on Scroll Lock (F12 stays free for other programs). |

## What gets installed

`<SID>` is your account's security identifier (`whoami /user`).

| What | Where |
|---|---|
| The program (shared by all accounts) | `C:\Program Files\QuakeKey\QuakeKey.exe` |
| Its log: administrators write, you read | `C:\ProgramData\QuakeKey\<SID>\quakekey.log` |
| Hotkey owner: elevated, at logon, restarted within 5 minutes if it stops | Task Scheduler `\QuakeKey\<SID>\Hotkey` |
| Terminal starters: normal privileges, run on demand | `\QuakeKey\<SID>\StartShown`, `\QuakeKey\<SID>\StartHidden` |
| Install record, `settings.json` backups, Terminal start log | `%LOCALAPPDATA%\QuakeKey\` |
| Only if your key is the debugger break key (default F12) | `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AeDebug` `UserDebuggerHotKey` -> `0x91` (Scroll Lock); the old value is kept in `C:\Program Files\QuakeKey\debugger-key.json` |

The Terminal settings change: the quake window gets one `globalSummon` action (yours is reused if you have one), bound
only to `ctrl+alt+shift+f24`, a chord nobody presses; Terminal's default Win+\` quake key is switched off; any other
global-summon key is removed. Comments in `settings.json` are not kept (they are in the backup).

## Security

QuakeKey runs elevated, every time you sign in, so that Windows delivers its key over admin windows. Read
[SECURITY.md](SECURITY.md) before installing it on a machine where that matters. In short: the installed files, the
log folder and the task definitions are admin-only. But a .NET program started with your environment can be steered
by environment variables you (or any program running as you) set. An elevated logon task therefore gives code that
already runs as you a silent way to admin rights: the kind of step UAC prompts are meant to stop. QuakeKey detects the
known variables and refuses to run, but by then they have taken effect. Windows does not treat UAC as a security
boundary; on a single-user PC where you approve every UAC prompt anyway, this changes little.

## Troubleshooting

Every key press writes one line to `C:\ProgramData\QuakeKey\<SID>\quakekey.log` saying what happened and which
window had focus. Terminal starts are logged in `%LOCALAPPDATA%\QuakeKey\launcher.log`.

| Log line | Meaning / fix |
|---|---|
| `F12 registered` | Working. |
| `could not be registered (error 1409) ... Windows reserves it for the debugger break key` | Reboot (after the installer moved the debugger key), or run the installer again. |
| `could not be registered (error 1409) ... another program holds it` | Another app owns that key. Pick another `-Key`, or check that Terminal's `settings.json` doesn't bind it. |
| `WARNING: Terminal's settings do not bind` | Terminal's quake binding is missing (settings.json was edited or reset). Run the installer again. QuakeKey still shows/hides the window meanwhile, without Terminal's own toggle. |
| `show: Terminal did not focus it ... focused with AttachThreadInput` | Normal when an admin window had focus. |
| `FAILED to focus` | Please open an issue with the log lines around it. |
| `Terminal exited; waiting ... minutes before starting a background one` | You closed Terminal. QuakeKey starts a hidden one after the wait; press the key to start it at once. |
| `not starting elevated: the environment variable ... is set` | A `COR_*` / `COMPlus_*` variable is set for your account. See [SECURITY.md](SECURITY.md). |
| `the single-instance lock ... is held, but no other elevated QuakeKey is running` | Another program holds QuakeKey's lock name. QuakeKey tries again every 5 minutes; signing out and in clears it. |
| `the wt.exe app execution alias is off` | In `launcher.log`: turn on "Terminal" under Settings > Apps > Advanced app settings > App execution aliases. |

To check Terminal's side yourself:

```powershell
& "C:\Program Files\QuakeKey\QuakeKey.exe" --check-settings "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json" | Out-Host
```

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
Details, measurements and links to Terminal's source: [docs/how-it-works.md](docs/how-it-works.md).

## Development

```
src/QuakeKey.cs              the program (C# 5, .NET Framework 4.x, one file)
install.ps1, uninstall.ps1   entry points
scripts/QuakeKey.Common.ps1  shared code: build, Terminal settings edit/undo, file writes, log folders, tasks
scripts/Elevated.ps1         the elevated half of install/uninstall
tests/Run-Tests.ps1          the test suite (see below)
tests/manual/                slow proofs of Windows behaviour the design relies on
```

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1   # Windows PowerShell 5.1
pwsh -File .\tests\Run-Tests.ps1                                 # PowerShell 7
```

The tests build the exe and check its Win32 constants against the SDK, the key parser, the Terminal crash guard
(`--check-settings`), the watchdog policy on a fake clock and session-end handling (through reflection on the built
exe), plus the installer logic: settings edit and undo on fixtures, writes over existing files and links, the
hash-checked exe copy, link-safe deletes, the log-folder ACLs and the task definitions. They install nothing outside a
temp folder. On GitHub Actions, whose runners are elevated throwaway machines, they also run the elevated install and
uninstall for real. CI runs everything in both shells, plus PSScriptAnalyzer, on every push and pull request.

`tests/manual/` holds proofs that take minutes or need a desktop: Task Scheduler's restart-on-failure not firing on an
exit code, the repeating trigger that replaces it, and the `SetWindowPos` flags bug fixed in 1.1.

## License

[MIT](LICENSE)
