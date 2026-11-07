# How QuakeKey works

This is the technical story: what breaks in Windows Terminal's own quake hotkey, how QuakeKey gets around it, and
why it is built the way it is. File references point at Windows Terminal 1.24 source (`microsoft/terminal`,
branch `release-1.24`; `main` behaves the same at the time of writing).

## The three problems

### 1. Admin windows swallow global hotkeys (UIPI)

`RegisterHotKey` delivers `WM_HOTKEY` through the message queue, and User Interface Privilege Isolation drops
messages from lower-integrity senders while a higher-integrity (elevated) window is in the foreground. A
normal-privilege hotkey owner therefore hears **nothing** while any "Run as administrator" window has focus.

That is the "F12 dies until I click the desktop" symptom: clicking the desktop puts a medium-integrity window in
front, and the hotkey works again. It is not a Terminal bug — no medium-privilege program can fix it.

**QuakeKey runs elevated** (Task Scheduler task with `RunLevel Highest`), so its hotkey arrives whatever has focus.
Consequence: it must be careful about everything an elevated, always-running process does — see "Security shape" below.

### 2. Every Terminal process races for the key

`WindowEmperor::HandleCommandlineArgs` calls `_setupGlobalHotkeys()` at startup, and again on every
`settings.json` reload (`SettingsChanged` handler). Each `RegisterHotKey` is first-come-first-served, so with a
normal Terminal *and* an elevated Terminal running (for example an admin terminal), the key lands in whichever
re-registered last — and pressing it then toggles that instance's quake window, or nothing at all.

**Fix:** Terminal must not own the real key. The installer binds Terminal's quake action to `ctrl+alt+shift+f24` —
a chord nobody presses — and QuakeKey owns the real key. F13–F24 chords are exactly what macro tools register, so
the installer also removes *every* other global-summon binding from `settings.json`.

### 3. Terminal cannot focus its window over an admin window

When the quake window is visible but not focused, `IslandWindow::_globalActivateWindow` never calls
`SetForegroundWindow`. It calls `AttachThreadInput` on the *foreground window's* thread and then
`BringWindowToTop`/`SetActiveWindow`. Attaching to an elevated process's thread fails with `ERROR_ACCESS_DENIED`
(UIPI again), so Terminal's own activation quietly does nothing.

**Fix:** after Terminal runs its toggle, QuakeKey checks whether the quake window actually has focus, and if not,
does the attach itself — from its elevated process, where `AttachThreadInput` succeeds. Measured on the reference
machine: over an elevated window, plain `SetForegroundWindow` from an elevated, hotkey-receiving process still
failed; `AttachThreadInput` + `SetForegroundWindow` worked (~290 ms worst case, ~25 ms typical).

## What happens on a key press

1. **Find the Terminal to drive.** Enumerate top-level windows for the class `Windows Terminal <16 hex>` — the
   message-only window of a packaged, non-elevated Terminal (the class embeds a hash of the user SID; the
   elevated instance is `Windows Terminal Admin <hash>` and is excluded by the pattern). The owning process is
   verified to be in the same session and under the same user as QuakeKey, so someone else's `runas` Terminal is
   never touched.
2. **No Terminal running?** Start one — see "The watchdog" below.
3. **Safety check before sending.** QuakeKey sends `WM_HOTKEY` with `wParam = 0` to that window, which is exactly
   what Terminal's own `WindowEmperor::_messageHandler` does for a registered hotkey. Hotkey index 0 is the
   *first keyed* `globalSummon`/`quakeMode` action in Terminal's settings. `_hotkeyPressed` bounds-checks with
   `index > size` instead of `>=`, so **if the table is empty, index 0 reads past an empty vector and Terminal
   crashes, taking every tab with it.** QuakeKey therefore sends only when (a) some Terminal process holds the
   chord (Terminals register what they are bound to) and (b) the user's `settings.json` still mentions it. When
   the check fails, QuakeKey shows/hides the window itself and logs a warning.
4. **Send, don't post.** `SendMessageTimeout(WM_HOTKEY, ..., SMTO_ABORTIFHUNG, 5000)` returns *after* Terminal has
   finished its toggle (show or hide). This ordering matters: if QuakeKey forced focus earlier, Terminal's toggle
   would see its window already focused and hide it again.
5. **Terminal's toggle** runs `IslandWindow::SummonWindow`: hide if focused (minimize → `WM_SIZE` → `SW_HIDE`,
   all inside the handler), otherwise activate — with the dropdown animation and monitor rules
   (`"monitor": "any" | "toMouse" | "toCurrent"`) from the action's settings.
6. **Focus guarantee.** If the quake window should now be focused but is not, QuakeKey forces it:
   `AttachThreadInput` to the foreground thread first (the method that works over admin windows), then
   `SetForegroundWindow`, two rounds, then `SwitchToThisWindow`. Window changes on the quake window use
   `ShowWindowAsync`/`SWP_ASYNCWINDOWPOS`, and threads are only attached after a `WM_NULL` responsiveness probe,
   so a hung Terminal can never hang QuakeKey.

## The quake window

Terminal does not expose window names, so the quake window is identified by geometry: flush with the top of a
monitor's work area, at least as wide as it, shorter than it, not maximized (that is `_getQuakeModeSize`'s
layout). The found window is cached and re-validated by `IsWindow` + process + class, so the scan runs once. A
`PerMonitorV2` manifest keeps coordinates honest on mixed-DPI screens, and windows cloaked by another virtual
desktop (`DwmGetWindowAttribute(DWMWA_CLOAKED)`) do not count as "shown".

## The watchdog

QuakeKey keeps a non-elevated Terminal alive so the key always has something to drive:

- Every 3 s it looks for one. None running → it runs the **normal-privilege** task `\QuakeKey\StartHidden`, which
  runs `QuakeKey.exe --start hidden` → `wt -Embedding`: Terminal's windowless COM-server mode (the same thing
  Windows starts for default-terminal hand-offs). No window, no flash, hotkey table loaded — the first key press
  creates the quake window inside the warm process.
- It never starts Terminal from the elevated process itself; Terminal would inherit admin rights.
- A press with *no* Terminal at all runs `\QuakeKey\StartShown` → `wt -w _quake`.
- The launcher refuses to hand `-Embedding` (or `-w _quake`) to a Terminal that is already running: the
  single-instance hand-off (`WM_COPYDATA` → `AppHost::DispatchCommandline`) would summon the window and open an
  extra tab — or, for `-Embedding`, an unknown-option error box.
- Restarts back off (15 s → 5 min), and a Terminal that exited on purpose is left alone for 2 minutes first.
- A hidden top-level window (not a message-only one — those get no `WM_QUERYENDSESSION`) tells the watchdog when
  Windows is shutting down, so it does not start a Terminal mid-logoff.

## Security shape of an elevated helper

An always-running elevated process is a target, so the cheap routes in are closed:

- **Program location:** `C:\Program Files\QuakeKey` (admin-writable only), started by Task Scheduler with an
  absolute path. Nothing a normal-privilege process can replace is executed or loaded.
- **Log:** the elevated process writes only to `C:\ProgramData\QuakeKey`, a folder **the installer creates** with
  its own ACL (SYSTEM and Administrators full control, Users read). The program never creates the folder, refuses
  to write through reparse points, and rotates the log by rename.
- **Profiler hooks:** environment variables like `COR_ENABLE_PROFILING` load a DLL into any .NET process at
  startup. If one is set, an elevated QuakeKey refuses to start rather than run with a hook.
- **Single instance:** separate mutexes for elevated and normal runs; a manual (non-elevated) double-click stands
  down if the elevated instance is running, instead of silently stealing the key.
- **Input to Terminal:** one `WM_HOTKEY` message with a fixed `wParam` to a verified same-user, same-session,
  non-elevated Terminal. No window text, no command lines, nothing else crosses the boundary.

## Why not change Terminal instead?

The three problems above are upstream (`microsoft/terminal`) behavior: the `index > size` bounds check, the
attach-only activation, and the every-instance-registers-hotkeys design. QuakeKey is the small, local tool that
works with the Terminal that ships today. If Terminal ever fixes its focus path, QuakeKey's focus guarantee
simply stops firing.

## Files on this machine

| Path | Purpose |
|---|---|
| `C:\Program Files\QuakeKey\QuakeKey.exe` | the program (task `\QuakeKey\Hotkey`) |
| `C:\ProgramData\QuakeKey\quakekey.log` | one line per key press: what happened, who had focus |
| `%LOCALAPPDATA%\QuakeKey\launcher.log` | Terminal starts |
| `%LOCALAPPDATA%\QuakeKey\terminal-state.json` | what the installer changed in `settings.json` (for uninstall) |
| `%LOCALAPPDATA%\QuakeKey\backups\` | a copy of `settings.json` before every change |
