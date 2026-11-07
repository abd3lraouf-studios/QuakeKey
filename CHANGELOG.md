# Changelog

## 1.1.0 - 2026-11-07

Fixes from a full audit of 1.0. Each fix has a test in `tests/Run-Tests.ps1` or a proof in `tests/manual`.

### Fixed

- **Install and uninstall failed at the Terminal settings step** in both Windows PowerShell 5.1 and PowerShell 7.
  `File.Replace($tmp, $path, $null)` received `""` (PowerShell turns `$null` into an empty string for .NET string
  parameters), so writing over the existing `settings.json` threw, leaving QuakeKey half-installed and a
  `settings.json.quakekey-tmp` file behind. Uninstall failed the same way after removing QuakeKey, leaving no quake
  key at all.
- A `settings.json` that is a symbolic link (dotfiles setups) made the write fail; a hard-linked one was silently
  unlinked. Both are now written through and stay links.
- **QuakeKey was never restarted after a crash.** Task Scheduler's restart-on-failure does not fire on a program's
  exit code. The Hotkey task now has a 5-minute repeating trigger (`MultipleInstances IgnoreNew`) that starts it again.
- The z-order call before focusing the quake window always failed: `SWP_NOACTIVATE` was defined as `0x0800` instead
  of `0x0010`. It also passed `(HWND)-1`, which is `HWND_TOPMOST`, so fixing only the flag would have pinned the quake
  window always-on-top. The call is removed; `SetForegroundWindow` already raises the window.
- After Terminal exited, the watchdog announced a 2-minute wait but waited 10 minutes, logging the same line five
  times.
- A cancelled shutdown or sign-out left the watchdog off until the next logon.
- The log folder `C:\ProgramData\QuakeKey` could keep write access for a user who created it before the install
  (`icacls /grant:r` only replaces entries for the accounts it names). Log folders are now created in one step with
  their final permissions, and a pre-existing folder with other permissions is moved aside.
- A running Terminal Preview, Canary or unpackaged copy counted as "your Terminal": a key press waited 10 s and did
  nothing, and the watchdog never started the release Terminal.
- The Terminal crash guard accepted the chord text anywhere in `settings.json` (a profile name, an unrelated action);
  it now parses the file and requires the chord to be bound to a summon of the `_quake` window.
- The installer reported "could not take the key" when QuakeKey's first attempt raced Terminal releasing it; it now
  waits for the key to be registered.
- A second account installing QuakeKey replaced the first account's tasks, and either account's uninstall removed
  QuakeKey for both and stopped every account's copy.
- A program holding QuakeKey's single-instance lock name stopped the elevated copy for good; it now exits with an
  error and is retried.
- The README quoted a log line the program never writes; the docs called Terminal's hidden window "message-only".

### Changed

- Tasks and logs are per user: `\QuakeKey\<SID>\Hotkey|StartShown|StartHidden` and
  `C:\ProgramData\QuakeKey\<SID>\quakekey.log`. Installing removes the 1.0 tasks that belong to you.
- The installer changes Terminal's settings before the UAC prompt and puts them back if the elevated step is cancelled
  or fails.
- The installer checks the prerequisites (administrator account, UAC on, not the built-in Administrator, `wt.exe`
  alias) instead of failing in odd ways later.
- The elevated step installs the exe only if it matches the SHA-256 taken right after the build.
- Uninstall restores the debugger break key (`UserDebuggerHotKey`) to its value before the install (new
  `-KeepDebuggerKey` to opt out), and removes `%LOCALAPPDATA%\QuakeKey` except its backups. `-KeepTerminalSettings`
  now warns that Terminal is left without a quake key.
- The runtime-hook tripwire covers every `COR_*` and `COMPlus_*` variable, and SECURITY.md explains plainly what
  it can and cannot do.
- New `QuakeKey.exe --check-settings <path>` checks a `settings.json` the way the crash guard does.
- Tests: 77 checks became 255, including Win32 constants against the SDK, the watchdog on a fake clock, the
  log-folder ACLs, links, and a real elevated install and uninstall on CI. CI adds PSScriptAnalyzer, pins
  `actions/checkout` to a commit and runs with read-only permissions.

## 1.0.0 - 2026-11-07

First release.
