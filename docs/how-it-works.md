# How QuakeKey works

This is the technical story: what breaks in Windows Terminal's own quake hotkey, how QuakeKey gets around it, and
why it is built the way it is. Source references point at Windows Terminal **v1.24.12741.0**, commit
[`7ff11ee`](https://github.com/microsoft/terminal/tree/7ff11ee107c984e236960ec948b450ccbc10187b) of
`microsoft/terminal` (the tip of `release-1.24` at the time of writing). Every claim about Terminal below was checked
against that commit.

[WE]: https://github.com/microsoft/terminal/blob/7ff11ee107c984e236960ec948b450ccbc10187b/src/cascadia/WindowsTerminal/WindowEmperor.cpp
[IW]: https://github.com/microsoft/terminal/blob/7ff11ee107c984e236960ec948b450ccbc10187b/src/cascadia/WindowsTerminal/IslandWindow.cpp

## The three problems

### 1. Admin windows swallow global hotkeys (UIPI)

`RegisterHotKey` delivers `WM_HOTKEY` through the message queue, and User Interface Privilege Isolation drops
messages from lower-integrity senders while a higher-integrity (elevated) window is in the foreground. A
normal-privilege hotkey owner therefore hears **nothing** while any "Run as administrator" window has focus.

That is the "F12 dies until I click the desktop" symptom: clicking the desktop puts a medium-integrity window in
front, and the hotkey works again. It is not a Terminal bug, and no medium-privilege program can fix it.

**QuakeKey runs elevated** (Task Scheduler task with `RunLevel Highest`), so its hotkey arrives whatever has focus.
Consequence: it must be careful about everything an elevated, always-running process does; see "Security shape" below
and [SECURITY.md](../SECURITY.md).

### 2. Every Terminal process races for the key

`WindowEmperor` calls `_setupGlobalHotkeys()` at startup ([WindowEmperor.cpp:378][WE-start]) and again on every
`settings.json` reload ([:384-389][WE-reload]). It unregisters and re-registers every global-summon key
([:1347-1371][WE-setup]), and each `RegisterHotKey` is first-come-first-served. With a normal Terminal *and* an elevated
Terminal running, the key lands in whichever registered last, and pressing it toggles that instance's quake window,
or nothing at all.

**Fix:** Terminal must not own the real key. The installer binds Terminal's quake action to `ctrl+alt+shift+f24`
(a chord nobody presses) and QuakeKey owns the real key. The installer also removes *every* other global-summon
binding from `settings.json`, so the quake action is hotkey index 0.

[WE-start]: https://github.com/microsoft/terminal/blob/7ff11ee107c984e236960ec948b450ccbc10187b/src/cascadia/WindowsTerminal/WindowEmperor.cpp#L378
[WE-reload]: https://github.com/microsoft/terminal/blob/7ff11ee107c984e236960ec948b450ccbc10187b/src/cascadia/WindowsTerminal/WindowEmperor.cpp#L384-L389
[WE-setup]: https://github.com/microsoft/terminal/blob/7ff11ee107c984e236960ec948b450ccbc10187b/src/cascadia/WindowsTerminal/WindowEmperor.cpp#L1347-L1371

### 3. Terminal cannot focus its window over an admin window

When the quake window is visible but not focused, `IslandWindow::_globalActivateWindow` never calls
`SetForegroundWindow`. It calls `AttachThreadInput` on the *foreground window's* thread, then `BringWindowToTop` and
`SetActiveWindow` ([IslandWindow.cpp:1470-1480][IW-activate]). Attaching to an elevated process's thread fails with
`ERROR_ACCESS_DENIED` (UIPI again), so Terminal's own activation quietly does nothing.

**Fix:** after Terminal runs its toggle, QuakeKey checks whether the quake window actually has focus. If not, it does
the attach itself from its elevated process, where `AttachThreadInput` succeeds. Measured on the reference machine:
over an elevated window, plain `SetForegroundWindow` from an elevated, hotkey-receiving process still failed;
`AttachThreadInput` + `SetForegroundWindow` worked (~290 ms worst case, ~25 ms typical).

[IW-activate]: https://github.com/microsoft/terminal/blob/7ff11ee107c984e236960ec948b450ccbc10187b/src/cascadia/WindowsTerminal/IslandWindow.cpp#L1470-L1480

## What happens on a key press

1. **Find the Terminal to drive.** Enumerate top-level windows for the class `Windows Terminal <16 hex>`. That is the
   hidden top-level window a packaged, non-elevated release Terminal creates for its global messages
   ([WindowEmperor.cpp:316-341][WE-class]). The class embeds a hash of the user SID. Elevated (`... Admin ...`),
   Preview, Canary, Dev and unpackaged builds produce other class names. Terminal notes that this window "cannot be a
   HWND_MESSAGE window" ([:815-816][WE-notmsg]), which is why `EnumWindows` sees it. The owning process is also
   checked: same session, same user, not elevated, and its image is the release package
   (`...\WindowsApps\Microsoft.WindowsTerminal_<version>_<arch>__8wekyb3d8bbwe\WindowsTerminal.exe`). So someone
   else's `runas` Terminal or a running Preview is never touched.
2. **No Terminal running?** Start one; see "The watchdog" below.
3. **Safety check before sending.** QuakeKey sends `WM_HOTKEY` with `wParam = 0` to that window, which is exactly
   what Terminal's own window procedure does for a registered hotkey ([WindowEmperor.cpp:1022-1024][WE-hotkey]).
   Hotkey index 0 is the first keyed `globalSummon`/`quakeMode` action in Terminal's settings. `_hotkeyPressed` checks
   `index > size` instead of `>=` ([:1274][WE-bounds]). **If the table is empty, index 0 reads past an empty vector
   and Terminal crashes, taking every tab with it.** (A failed `RegisterHotKey` still adds the entry, [:1367-1369][WE-setup],
   so only an empty table is dangerous.) QuakeKey therefore sends only when (a) some process holds the chord
   (Terminals register what they are bound to) and (b) the user's `settings.json`, parsed as JSON with comments, binds
   the chord to a summon of the `_quake` window, with the last binding of the chord winning as in Terminal. When the
   check fails, QuakeKey shows/hides the window itself and logs a warning. `QuakeKey.exe --check-settings <path>` runs
   check (b) on any file.
4. **Send, don't post.** `SendMessageTimeout(WM_HOTKEY, ..., SMTO_ABORTIFHUNG, 5000)` returns *after* Terminal has
   finished its toggle (show or hide). This ordering matters: if QuakeKey forced focus earlier, Terminal's toggle
   would see its window already focused and hide it again.
5. **Terminal's toggle** runs `IslandWindow::SummonWindow` ([IslandWindow.cpp:1248][IW-summon]): hide if focused
   (minimize -> `WM_SIZE` -> `SW_HIDE`, all inside the handler), otherwise activate, with the dropdown animation and
   monitor rules (`"monitor": "any" | "toMouse" | "toCurrent"`) from the action's settings.
6. **Focus guarantee.** If the quake window should now be focused but is not, QuakeKey forces it:
   `AttachThreadInput` to the foreground thread first (the method that works over admin windows), then
   `SetForegroundWindow`, two rounds, then `SwitchToThisWindow`. Window changes on the quake window use
   `ShowWindowAsync`, and threads are only attached after a `WM_NULL` responsiveness probe, so a hung Terminal can
   never hang QuakeKey.

[WE-class]: https://github.com/microsoft/terminal/blob/7ff11ee107c984e236960ec948b450ccbc10187b/src/cascadia/WindowsTerminal/WindowEmperor.cpp#L316-L341
[WE-notmsg]: https://github.com/microsoft/terminal/blob/7ff11ee107c984e236960ec948b450ccbc10187b/src/cascadia/WindowsTerminal/WindowEmperor.cpp#L815-L816
[WE-hotkey]: https://github.com/microsoft/terminal/blob/7ff11ee107c984e236960ec948b450ccbc10187b/src/cascadia/WindowsTerminal/WindowEmperor.cpp#L1022-L1024
[WE-bounds]: https://github.com/microsoft/terminal/blob/7ff11ee107c984e236960ec948b450ccbc10187b/src/cascadia/WindowsTerminal/WindowEmperor.cpp#L1272-L1279
[IW-summon]: https://github.com/microsoft/terminal/blob/7ff11ee107c984e236960ec948b450ccbc10187b/src/cascadia/WindowsTerminal/IslandWindow.cpp#L1248

## The quake window

Terminal does not expose window names, so the quake window is identified by geometry: flush with the top of a
monitor's work area, at least as wide as it, shorter than it, not maximized (that is `_getQuakeModeSize`'s layout).
The found window is cached and re-validated by `IsWindow`, process, class and geometry, so the scan runs once. A
`PerMonitorV2` manifest keeps coordinates honest on mixed-DPI screens, and windows cloaked by another virtual
desktop (`DwmGetWindowAttribute(DWMWA_CLOAKED)`) do not count as "shown". Known limit: a normal Terminal window
snapped to a top-half zone has the same shape.

## The watchdog

QuakeKey keeps a non-elevated Terminal alive so the key always has something to drive:

- Every 3 s it looks for one. None running -> it runs the **normal-privilege** task `\QuakeKey\<SID>\StartHidden`,
  which runs `QuakeKey.exe --start hidden` -> `wt -Embedding`: Terminal's windowless COM-server mode (the same thing
  Windows starts for default-terminal hand-offs). No window, no flash, hotkey table loaded: the first key press
  creates the quake window inside the warm process.
- It never starts Terminal from the elevated process itself; Terminal would inherit admin rights.
- A press with *no* Terminal at all runs `\QuakeKey\<SID>\StartShown` -> `wt -w _quake`.
- The launcher refuses to hand `-Embedding` to a Terminal that is already running. The single-instance hand-off
  (`WM_COPYDATA` -> `AppHost::DispatchCommandline`) would show an unknown-option error box for `-Embedding`, or, for
  `-w _quake`, summon the window and open an extra tab.
- A Terminal that exits on purpose (you closed it, or typed `exit`) gets **one** 2-minute grace before a background
  one starts. A Terminal that will not come up is retried with backoff: 15 s, 30 s, 60 s ... 5 min.
  (QuakeKey 1.0 re-armed the grace every 2 minutes and in fact waited 10.) The policy is a pure class,
  `WatchdogPolicy`, that the tests drive with a fake clock.
- A hidden top-level window (not a message-only one, which gets no `WM_QUERYENDSESSION`) tells the watchdog when
  Windows is shutting down, so it does not start a Terminal mid-logoff. If the shutdown is cancelled
  (`WM_ENDSESSION` with `wParam = FALSE`), the watchdog runs again. 1.0 stayed paused until the next logon.

## Keeping QuakeKey itself running

Task Scheduler's "restart if the task fails" setting does **not** fire when the program exits with an error code or
crashes. It only covers a task that fails to launch: `tests/manual/Prove-RestartOnFailure.ps1` shows a task with 3
restarts allowed whose program exits with 1 running exactly once. QuakeKey 1.0 relied on it. So the Hotkey task has a
second trigger that repeats every 5 minutes, with `MultipleInstances IgnoreNew`: while QuakeKey runs, the repeats are
ignored, and at most 5 minutes after it stops, it runs again (`tests/manual/Prove-Supervisor.ps1`).

## Security shape of an elevated helper

An always-running elevated process is a target. The routes a normal-privilege program could use are closed where
they can be, and documented where they cannot (see [SECURITY.md](../SECURITY.md)):

- **Program location:** `C:\Program Files\QuakeKey` (admin-writable only), started by Task Scheduler with an
  absolute path. The elevated install step copies the exe only if its SHA-256 matches the hash the installer took
  right after building it, before the UAC prompt, and it writes the bytes it checked.
- **Log:** the elevated process writes only to `C:\ProgramData\QuakeKey\<SID>`. It never creates folders there and
  refuses to write through reparse points. The installer creates `C:\ProgramData\QuakeKey` and the per-user folder
  in one step with their final, protected DACL: SYSTEM and Administrators full control, the user read, and Users may
  list the root. Any user may create folders in `%ProgramData%`, so a `QuakeKey` folder that already exists with
  other permissions is moved aside, not re-permissioned. Re-permissioning keeps entries it does not name: QuakeKey
  1.0's `icacls /grant:r` left a pre-planted `Everyone:Modify` in place. It would also keep handles opened before it.
  Inside the user's folder only administrators can create entries, so no planted link or hard link can redirect a
  write.
- **Runtime hooks:** .NET reads `COR_*` / `COMPlus_*` environment variables (a profiler DLL, an alternative JIT and
  more) while it starts, before `Main`. An elevated QuakeKey refuses to keep running when one is set. That is a
  tripwire, not a defense: the variable has already taken effect. See SECURITY.md.
- **Single instance:** separate mutexes for elevated and normal runs; a manual (non-elevated) double-click stands
  down if the elevated instance is running, instead of silently stealing the key. Any program in the session can
  create those names first. The elevated copy notices when the lock is held but no elevated QuakeKey runs, exits
  with an error, and the 5-minute trigger tries again.
- **Input to Terminal:** one `WM_HOTKEY` message with a fixed `wParam` to a verified same-user, same-session,
  non-elevated release Terminal. No window text, no command lines, nothing else crosses the boundary.

## Why not change Terminal instead?

The three problems above are upstream (`microsoft/terminal`) behavior: the `index > size` bounds check, the
attach-only activation, and the every-instance-registers-hotkeys design. QuakeKey is the small, local tool that
works with the Terminal that ships today. If Terminal ever fixes its focus path, QuakeKey's focus guarantee
simply stops firing.

## Files on this machine

`<SID>` is the user's security identifier.

| Path | Purpose |
|---|---|
| `C:\Program Files\QuakeKey\QuakeKey.exe` | the program, shared by all accounts (task `\QuakeKey\<SID>\Hotkey`) |
| `C:\Program Files\QuakeKey\debugger-key.json` | the debugger break key's value before the install, if it was moved |
| `C:\ProgramData\QuakeKey\<SID>\quakekey.log` | one line per key press: what happened, who had focus |
| `%LOCALAPPDATA%\QuakeKey\launcher.log` | Terminal starts |
| `%LOCALAPPDATA%\QuakeKey\terminal-state.json` | what the installer changed in `settings.json` (for uninstall) |
| `%LOCALAPPDATA%\QuakeKey\backups\` | a copy of `settings.json` before every change |
