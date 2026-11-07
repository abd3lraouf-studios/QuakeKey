// QuakeKey: owns a global hotkey (F12 by default) and drives the Windows Terminal quake window so it always opens
// focused, including over admin windows.
//
// Why it exists (Windows Terminal 1.24, microsoft/terminal @ 7ff11ee; docs/how-it-works.md links the exact lines):
//  * Every Terminal process, normal or elevated, calls RegisterHotKey for its global-summon keys at start and again
//    on every settings.json reload (WindowEmperor::_setupGlobalHotkeys). The first caller wins, so the key could land
//    in an elevated Terminal, or be lost after a reload.
//  * When the quake window is on screen but not focused, Terminal's _globalActivateWindow never calls
//    SetForegroundWindow. It AttachThreadInput()s to the focused window's thread, and that fails with
//    ERROR_ACCESS_DENIED when the focused window is elevated (UIPI).
//  * Windows does not deliver a hotkey to a normal-privilege program while an elevated window has focus (UIPI).
//    So this program runs elevated (task \QuakeKey\<user SID>\Hotkey, exe in Program Files), and it never starts
//    Terminal itself: it runs the normal-privilege tasks StartShown / StartHidden in the same task folder, which call
//    `QuakeKey.exe --start shown|hidden`, so the quake shell stays non-admin.
//
// What it does:
//  * Registers the hotkey itself. Terminal's "globalSummon _quake" action sits on the unpressable
//    ctrl+alt+shift+f24 and is its only global-summon binding, so it is Terminal's hotkey index 0.
//  * On a press it gives the non-elevated Terminal foreground rights and sends WM_HOTKEY(0) to its window, so
//    Terminal runs its own toggle (show / hide / follow the mouse to another monitor).
//  * If the quake window should now be focused but is not, it focuses it itself: AttachThreadInput to the focused
//    window's thread (works over admin windows because this process is elevated), SetForegroundWindow, then
//    SwitchToThisWindow.
//  * Keeps a non-elevated Terminal running. With none, it starts `wt -Embedding` (windowless; the first press
//    creates the quake window in that warm process). A press with no Terminal at all starts `wt -w _quake`.
//  * Never sends the toggle unless settings.json binds ctrl+alt+shift+f24 to the quake summon and a Terminal holds
//    that chord (SafeToSendToggle): Terminal crashes on WM_HOTKEY(0) when it has no global-summon binding.
//
// Install: install.ps1. Log: %ProgramData%\QuakeKey\<user SID>\quakekey.log when elevated, %LOCALAPPDATA%\QuakeKey
// otherwise. Pure logic (key specs, settings check, watchdog policy) lives in Logic / JsonC / WatchdogPolicy below
// so tests\Run-Tests.ps1 can call it through reflection.
using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using Microsoft.Win32;

[assembly: System.Reflection.AssemblyTitle("QuakeKey")]
[assembly: System.Reflection.AssemblyDescription("Reliable global hotkey for the Windows Terminal quake window")]
[assembly: System.Reflection.AssemblyVersion("1.1.0.0")]
[assembly: System.Reflection.AssemblyFileVersion("1.1.0.0")]

internal static class QuakeKey
{
    // ---------------------------------------------------------------- Win32
    // Every constant here is checked against the Windows SDK value by tests\Run-Tests.ps1 ("win32 constants").
    const uint WM_HOTKEY = 0x0312, WM_TIMER = 0x0113, WM_QUERYENDSESSION = 0x0011, WM_ENDSESSION = 0x0016;
    const uint PM_REMOVE = 0x1;
    const uint MOD_ALT = 0x1, MOD_CONTROL = 0x2, MOD_SHIFT = 0x4, MOD_WIN = 0x8, MOD_NOREPEAT = 0x4000, VK_F12 = 0x7B, VK_F24 = 0x87;
    const int SW_SHOW = 5, SW_MINIMIZE = 6, SW_RESTORE = 9;
    const int GWL_EXSTYLE = -20, WS_EX_TOOLWINDOW = 0x80;
    const uint MONITOR_DEFAULTTONEAREST = 2, MONITOR_DEFAULTTOPRIMARY = 1;
    const uint ASFW_ANY = 0xFFFFFFFF;
    const uint WM_NULL = 0x0000, SMTO_BLOCK = 0x1, SMTO_ABORTIFHUNG = 0x2;
    const uint NORMAL_PRIORITY_CLASS = 0x20, CREATE_NO_WINDOW = 0x08000000;
    const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000, TOKEN_QUERY = 0x8;
    const int TokenElevation = 20, TokenUser = 1;
    const int DWMWA_CLOAKED = 14;
    const uint WAIT_TIMEOUT = 0x102, STILL_ACTIVE = 259;
    const int ERROR_HOTKEY_ALREADY_REGISTERED = 1409;
    const int HOTKEY_ID = 1, PROBE_ID = 2;
    const string QuakeClass = "CASCADIA_HOSTING_WINDOW_CLASS";

    delegate IntPtr WndProcFn(IntPtr h, uint m, IntPtr w, IntPtr l);
    delegate bool EnumProc(IntPtr h, IntPtr l);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WNDCLASS { public uint style; public WndProcFn lpfnWndProc; public int cbClsExtra, cbWndExtra; public IntPtr hInstance, hIcon, hCursor, hbrBackground; public string lpszMenuName, lpszClassName; }
    [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int x, y; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct WINDOWPLACEMENT { public int length, flags, showCmd; public POINT ptMin, ptMax; public RECT rcNormal; }
    [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public uint dwFlags; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO { public int cb; public string lpReserved, lpDesktop, lpTitle; public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute; public uint dwFlags; public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError; }
    [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern ushort RegisterClass(ref WNDCLASS wc);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateWindowEx(uint ex, string cls, string name, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr DefWindowProc(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetMessage(out MSG msg, IntPtr h, uint min, uint max);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG msg);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr DispatchMessage(ref MSG msg);
    [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    [DllImport("user32.dll")] static extern UIntPtr SetTimer(IntPtr h, UIntPtr id, uint ms, IntPtr fn);
    [DllImport("user32.dll")] static extern bool PeekMessage(out MSG msg, IntPtr h, uint min, uint max, uint remove);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern void SwitchToThisWindow(IntPtr h, bool altTab);
    [DllImport("user32.dll")] static extern bool AllowSetForegroundWindow(uint pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint attach, uint attachTo, bool on);
    [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool GetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int idx);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromRect(ref RECT r, uint flags);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT p, uint flags);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CreateProcess(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool QueryFullProcessImageName(IntPtr process, int flags, StringBuilder name, ref int size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool ProcessIdToSessionId(uint pid, out uint session);
    [DllImport("kernel32.dll")] static extern uint GetCurrentProcessId();
    [DllImport("advapi32.dll")] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool GetTokenInformation(IntPtr token, int cls, IntPtr info, int len, out int retLen);
    [DllImport("advapi32.dll")] static extern bool EqualSid(IntPtr a, IntPtr b);
    [DllImport("advapi32.dll")] static extern int GetLengthSid(IntPtr sid);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int value, int size);

    // ---------------------------------------------------------------- state
    // Static initializers run in textual order: LogDir needs SelfElevated and UserSid.
    static readonly bool SelfElevated = IsElevated(GetCurrentProcessId());
    static readonly string UserSid = WindowsIdentity.GetCurrent().User.Value;

    // Release build, packaged, not elevated: "Windows Terminal <16 hex of the user SID hash>" (WindowEmperor.cpp,
    // HandleCommandlineArgs). Elevated ("... Admin ..."), Preview, Canary, Dev and unpackaged builds never match.
    static readonly Regex NormalEmperorClass = new Regex(@"^Windows Terminal [0-9a-f]{16}$");
    static readonly string WtPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Microsoft\WindowsApps\wt.exe");
    static readonly string TerminalSettingsPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        @"Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json");

    // The elevated process logs to %ProgramData%\QuakeKey\<user SID>, a folder the installer creates with an
    // admin-only DACL (the user can read it), so a normal-privilege program cannot plant a link or a hard link there and
    // make an admin process write or delete files for it. Normal-privilege runs log to %LOCALAPPDATA%\QuakeKey.
    static readonly string LogRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "QuakeKey");
    static readonly string LogDir = SelfElevated
        ? Path.Combine(LogRoot, UserSid)
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "QuakeKey");
    static string logName = "quakekey.log";

    // The task folder install.ps1 registers for this user: Hotkey, StartShown, StartHidden.
    static readonly string TaskFolder = @"\QuakeKey\" + UserSid + @"\";

    // Terminal's globalSummon _quake action is bound to this chord (install.ps1 sets it). Nobody presses it; it only
    // makes Terminal's binding hotkey index 0 and lets TerminalBindingPresent() see that the binding exists.
    internal const string TerminalChord = "ctrl+alt+shift+f24";

    struct HotKeySpec { public uint Mods, Vk; public string Text; }
    static HotKeySpec hotkey;

    static WndProcFn wndProcKeepAlive;   // keeps the delegate alive for the native window class
    static IntPtr msgWindow;
    static bool hotkeyOn, hotkeyFailLogged, sessionEnding;
    static IntPtr quakeCache;
    static DateTime lastLaunchAt = DateTime.MinValue;       // a start is in flight: don't start a second one
    static readonly WatchdogPolicy watchdog = new WatchdogPolicy();
    static int ticks;

    // Usage:
    //   QuakeKey.exe [--key <spec>]          own the hotkey (default F12); what the Hotkey task runs
    //   QuakeKey.exe --start hidden|shown    start Terminal at normal privilege (the StartHidden / StartShown tasks)
    //   QuakeKey.exe --validate-key <spec>   print "<normalized> vk=0x.. mods=0x.." and exit 0, or the reason and exit 2
    //   QuakeKey.exe --check-settings <path> exit 0 if that settings.json binds the quake chord, 3 if not, 2 on errors
    // <spec>: modifiers ctrl, alt, shift, win joined with '+' to one key: F1-F24, A-Z, 0-9, numpad0-9, space, tab,
    // enter, esc, insert, delete, home, end, pageup, pagedown, up, down, left, right, pause, scrolllock, apps,
    // backtick, or vk:0xNN.
    [STAThread]
    static int Main(string[] args)
    {
        if (args.Length == 2 && args[0] == "--validate-key")
        {
            HotKeySpec k;
            string why;
            if (!TryParseKey(args[1], out k, out why)) { Console.Error.WriteLine(why); return 2; }
            Console.WriteLine(k.Text + " vk=0x" + k.Vk.ToString("X2") + " mods=0x" + k.Mods.ToString("X"));
            return 0;
        }

        if (args.Length == 2 && args[0] == "--check-settings")
        {
            string message;
            int code = Logic.CheckSettingsFile(args[1], TerminalChord, out message);
            (code == 0 ? Console.Out : Console.Error).WriteLine(message);
            return code;
        }

        // Launcher mode, run at normal privilege by the StartShown / StartHidden tasks.
        //  hidden: `wt -Embedding`, Terminal's windowless server mode (what Windows itself starts for default-terminal
        //          hand-offs). No window, process stays up, global-summon table loaded: the first press creates the
        //          quake window inside the warm process. Terminal has no "start minimized" switch, and the show flag
        //          of a CreateProcess is lost through the wt.exe alias, so this is the no-flash way.
        //  shown:  `wt -w _quake`, used when the key is pressed and no Terminal is running.
        if (args.Length == 2 && args[0] == "--start")
        {
            logName = "launcher.log";
            bool hidden = args[1] == "hidden";
            // A background start must never reach a running Terminal: the hand-off would hand it "-Embedding"
            // (an unknown option there, so an error box) or, for `-w _quake`, summon the window with an extra tab.
            if (hidden && NormalTerminalProcessRunning())
            {
                Log("launcher: a non-elevated Terminal is already running, background start skipped");
                return 0;
            }
            bool ok = StartDirect(hidden ? "-Embedding" : "-w _quake");
            if (ok) Log(hidden ? "launcher: started Terminal in the background (no window)" : "launcher: started Terminal with the quake window");
            return ok ? 0 : 1;
        }

        // Tripwire, not a defense: .NET reads COR_* / COMPlus_* variables while it starts, so a profiler or another
        // runtime knob planted in the user environment has already taken effect by the time Main runs. Refusing to
        // carry on elevated at least stops QuakeKey from running that way unnoticed. See SECURITY.md.
        if (SelfElevated)
        {
            string planted = Logic.RuntimeHookVariable(Environment.GetEnvironmentVariables());
            if (planted != null)
            {
                Log("not starting elevated: the environment variable " + planted + " is set. .NET reads COR_* and COMPlus_* variables at startup,"
                    + " so it may already have loaded code into this admin process. Delete it (HKCU\\Environment), sign out and in, and see SECURITY.md.");
                return 0;
            }
        }

        // Configuration errors exit 0: running again would not fix them.
        string spec = "F12";
        if (args.Length == 2 && args[0] == "--key") spec = args[1];
        else if (args.Length != 0) { Log("unknown arguments: " + string.Join(" ", args) + " (not starting)"); return 0; }
        string error;
        if (!TryParseKey(spec, out hotkey, out error)) { Log("bad --key '" + spec + "': " + error + " (not starting)"); return 0; }

        // Two single-instance locks. A manual (non-elevated) start also checks for the elevated one and stands down,
        // so double-clicking the exe cannot silently steal the key from the installed elevated copy. Any program in
        // the session can create these names first; that case is detected and exits 1 (the Hotkey task's 5-minute
        // repeat trigger tries again) instead of looking like a normal "already running".
        bool first;
        Mutex mine;
        EventWaitHandle elevatedRunning;
        try
        {
            mine = new Mutex(true, SelfElevated ? @"Local\QuakeKey.elevated" : @"Local\QuakeKey.user", out first);
            elevatedRunning = new EventWaitHandle(false, EventResetMode.ManualReset, @"Local\QuakeKey.elevatedRunning");
        }
        catch (Exception ex)
        {
            Log("could not open QuakeKey's single-instance lock (" + ex.GetType().Name + ": " + ex.Message + "); another program may be holding its name. Exiting; Task Scheduler tries again within 5 minutes.");
            return 1;
        }
        using (mine)
        using (elevatedRunning)
        {
            if (SelfElevated) elevatedRunning.Set();
            else if (elevatedRunning.WaitOne(0))
            {
                Log("the elevated QuakeKey is already running; this non-elevated copy stands down (its key presses would not arrive over admin windows anyway)");
                return 0;
            }
            if (!first)
            {
                if (SelfElevated && !OtherElevatedInstanceRunning())
                {
                    Log("the single-instance lock Local\\QuakeKey.elevated is held, but no other elevated QuakeKey is running: another program holds it. Exiting; Task Scheduler tries again within 5 minutes.");
                    return 1;
                }
                Log("another QuakeKey with the same privileges is already running");
                return 0;
            }
            try { Run(); return 0; }
            catch (Exception ex) { Log("FATAL " + ex); return 1; }   // the Hotkey task's 5-minute repeat trigger starts us again
        }
    }

    static void Run()
    {
        wndProcKeepAlive = WindowProc;
        var wc = new WNDCLASS { lpfnWndProc = wndProcKeepAlive, hInstance = GetModuleHandle(null), lpszClassName = "QuakeKey.MessageWindow" };
        if (RegisterClass(ref wc) == 0) throw new Win32Exception();
        // A hidden top-level window, not a message-only one: message-only windows get no WM_QUERYENDSESSION, and the
        // watchdog must know when Windows is shutting down instead of starting a Terminal mid-logoff.
        const uint WS_OVERLAPPED = 0;
        msgWindow = CreateWindowEx(0, wc.lpszClassName, "QuakeKey", WS_OVERLAPPED, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, wc.hInstance, IntPtr.Zero);
        if (msgWindow == IntPtr.Zero) throw new Win32Exception();

        int pid;
        using (var self = Process.GetCurrentProcess()) pid = self.Id;
        Log("started, pid " + pid + ", key " + K
            + (SelfElevated ? ", elevated" : ", NOT elevated: the key will not arrive while an admin window has focus"));
        TryRegisterHotkey();
        Watchdog();
        SetTimer(msgWindow, new UIntPtr(1), 1000, IntPtr.Zero);

        MSG msg;
        while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0)
        {
            TranslateMessage(ref msg);
            DispatchMessage(ref msg);
        }
    }

    static IntPtr WindowProc(IntPtr h, uint m, IntPtr w, IntPtr l)
    {
        try
        {
            if (m == WM_HOTKEY && w.ToInt64() == HOTKEY_ID) { OnHotkey(); return IntPtr.Zero; }
            if (m == WM_TIMER) { OnTimer(); return IntPtr.Zero; }
            if (m == WM_QUERYENDSESSION)
            {
                sessionEnding = true;   // pauses the watchdog; Terminal comes back at the next logon anyway
                return new IntPtr(1);   // "go ahead"
            }
            if (m == WM_ENDSESSION)
            {
                // wParam FALSE: the shutdown or sign-out was cancelled (an app refused, or the user pressed Cancel).
                sessionEnding = w != IntPtr.Zero;
                return IntPtr.Zero;
            }
        }
        catch (Exception ex) { Log("ERROR " + ex); }
        return DefWindowProc(h, m, w, l);
    }

    // ---------------------------------------------------------------- the key
    static void OnHotkey()
    {
        var sw = Stopwatch.StartNew();
        IntPtr fg = GetForegroundWindow();
        string fgWas = Describe(fg);

        IntPtr emperor; uint pid;
        if (!FindNormalTerminal(out emperor, out pid))
        {
            bool startInFlight = NormalTerminalProcessRunning() || DateTime.Now - lastLaunchAt < TimeSpan.FromSeconds(10);
            if (!startInFlight)
            {
                AllowSetForegroundWindow(ASFW_ANY);
                if (!StartQuake(false)) { DrainQueuedPresses(); return; }
                lastLaunchAt = DateTime.Now;
                watchdog.Postpone(DateTime.Now.AddSeconds(15));
                IntPtr started = WaitForShownQuake(0, 10000);
                Log(K + " start: no Terminal was running; " + (started == IntPtr.Zero ? "quake window did not appear" : EnsureForeground(started))
                    + " [" + sw.ElapsedMilliseconds + " ms, focus was " + fgWas + "]");
                DrainQueuedPresses();
                return;
            }
            // A Terminal is starting (usually the background start). Wait for it instead of starting another one,
            // whose hand-off would pop the quake window up with an extra tab.
            var starting = Stopwatch.StartNew();
            while (!FindNormalTerminal(out emperor, out pid) && starting.ElapsedMilliseconds < 10000) Thread.Sleep(50);
            if (emperor == IntPtr.Zero)
            {
                Log(K + ": a Terminal is starting but its window did not come up within 10 s");
                DrainQueuedPresses();
                return;
            }
            // No quake-window wait here: a starting Terminal registers its global-summon hotkeys right after its
            // window exists, and the toggle below then creates the quake window itself.
        }

        // Focus may have moved during the waits above; decide "is the quake focused" from the current state.
        fg = GetForegroundWindow();
        fgWas = Describe(fg);

        IntPtr quake = FindQuake(pid);
        bool shown = quake != IntPtr.Zero && IsWindowVisible(quake) && !IsIconic(quake) && !IsCloaked(quake);
        bool active = shown && fg == quake;

        if (!SafeToSendToggle())
        {
            Log("WARNING: Terminal's settings do not bind " + TerminalChord + " to the quake window, or no Terminal holds that chord; toggling the window directly. Run install.ps1 again to restore the binding.");
            DirectToggle(quake, active, sw, fgWas);
            DrainQueuedPresses();
            return;
        }

        // With "monitor": "toMouse" Terminal moves a focused quake window to the mouse's monitor instead of hiding it
        // ("any" always hides). Noted before the toggle, the outcome is read after it.
        bool mouseElsewhere = active && quake != IntPtr.Zero && MouseOnOtherMonitor(quake);

        // Hotkey index 0 = Terminal's globalSummon _quake. Sent, not posted: SendMessageTimeout returns once Terminal
        // has run its toggle, so focus is forced only after that. Forcing it earlier would let Terminal see its window
        // already focused and hide it again. lParam is what Windows would send for the chord (Terminal ignores it).
        AllowSetForegroundWindow(pid);
        IntPtr ignored;
        IntPtr chordLParam = new IntPtr((int)((VK_F24 << 16) | MOD_CONTROL | MOD_ALT | MOD_SHIFT));
        if (SendMessageTimeout(emperor, WM_HOTKEY, IntPtr.Zero, chordLParam, SMTO_ABORTIFHUNG, 5000, out ignored) == IntPtr.Zero)
        {
            Log(K + ": Terminal did not finish the toggle within 5 s (busy or hung), error " + Marshal.GetLastWin32Error() + " [focus was " + fgWas + "]");
            DrainQueuedPresses();
            return;
        }

        if (active)
        {
            // Terminal hides (minimize -> hide) inside its handler, so the result is settled once the send returns.
            bool stillUp = IsWindowVisible(quake) && !IsIconic(quake);
            Log(K + (!stillUp ? " hide [focus was the quake window]"
                : mouseElsewhere ? ": Terminal moved the quake window to the mouse's monitor instead of hiding it (monitor: toMouse)"
                : ": Terminal left the focused quake window up (expected a hide)"));
            DrainQueuedPresses();
            return;
        }

        IntPtr q = WaitForShownQuake(pid, quake == IntPtr.Zero ? 8000 : 1500);
        if (q == IntPtr.Zero)
        {
            Log(K + " show: quake window did not appear [" + sw.ElapsedMilliseconds + " ms, focus was " + fgWas + "]");
            DrainQueuedPresses();
            return;
        }
        // An existing window is activated inside Terminal's handler (done by now); a new one shows up asynchronously
        // and focuses itself a moment later.
        if (WaitForeground(q, quake == IntPtr.Zero ? 300 : 30))
        {
            Log(K + " show: Terminal focused it itself [" + sw.ElapsedMilliseconds + " ms, " + (shown ? "was visible" : "was hidden") + ", focus was " + fgWas + "]");
            DrainQueuedPresses();
            return;
        }
        string how = EnsureForeground(q);
        Log(K + " show: Terminal did not focus it; " + how + " [" + sw.ElapsedMilliseconds + " ms, " + (shown ? "was visible" : "was hidden") + ", focus was " + fgWas + "]");
        DrainQueuedPresses();
    }

    // A press that arrived while this handler was blocked (cold starts can wait several seconds) must not run after
    // it as a surprise second toggle: it would see the quake focused and hide it again.
    static void DrainQueuedPresses()
    {
        MSG m;
        while (PeekMessage(out m, msgWindow, WM_HOTKEY, WM_HOTKEY, PM_REMOVE)) { }
    }

    // Sending hotkey index 0 is only safe while the target Terminal has a global-summon binding:
    // WindowEmperor::_hotkeyPressed checks `index > size` rather than `>=`, so with no binding it reads past an empty
    // vector and Terminal crashes, taking every tab with it. Two checks:
    //  * a Terminal process holds the chord (it registers what its settings bind),
    //  * the user's settings.json binds the chord to the quake summon (a third-party tool can hold an F24 chord too).
    static bool TerminalBindingPresent()
    {
        if (!RegisterHotKey(msgWindow, PROBE_ID, MOD_ALT | MOD_CONTROL | MOD_SHIFT | MOD_NOREPEAT, VK_F24)) return true;
        UnregisterHotKey(msgWindow, PROBE_ID);
        return false;   // nobody holds the chord: Terminal has no keyed binding
    }

    static bool SafeToSendToggle()
    {
        return TerminalBindingPresent() && SettingsBindChord();
    }

    static bool SettingsBindChord()
    {
        try
        {
            var fi = new FileInfo(TerminalSettingsPath);
            if (!fi.Exists || fi.Length > 8 * 1024 * 1024) return true;   // fall back to the hotkey probe alone
            string why;
            return Logic.SettingsBindChord(File.ReadAllText(fi.FullName), TerminalChord, out why);
        }
        catch { return true; }   // unreadable or not valid JSON (Terminal keeps its last good settings): probe alone
    }

    // Fallback without Terminal's toggle (no follow-the-mouse to another monitor). ShowWindowAsync everywhere:
    // the synchronous form waits for Terminal's UI thread, and a busy Terminal would freeze this one.
    static void DirectToggle(IntPtr quake, bool active, Stopwatch sw, string fgWas)
    {
        if (quake == IntPtr.Zero)
        {
            AllowSetForegroundWindow(ASFW_ANY);
            if (!StartQuake(false)) return;   // `wt -w _quake` creates the missing quake window
            IntPtr q = WaitForShownQuake(0, 10000);
            Log(K + " direct start: " + (q == IntPtr.Zero ? "quake window did not appear" : EnsureForeground(q)) + " [" + sw.ElapsedMilliseconds + " ms, focus was " + fgWas + "]");
            return;
        }
        if (active)
        {
            ShowWindowAsync(quake, SW_MINIMIZE);   // Terminal hides a quake window when it is minimized
            Log(K + " direct hide");
            return;
        }
        if (!IsWindowVisible(quake)) ShowWindowAsync(quake, SW_SHOW);
        Log(K + " direct show: " + EnsureForeground(quake) + " [" + sw.ElapsedMilliseconds + " ms, focus was " + fgWas + "]");
    }

    // Attaching to the focused window's input queue is what works over admin windows (plain SetForegroundWindow
    // failed there even from this elevated, hotkey-receiving process), so it goes first. Two rounds, in case another
    // window grabs focus in the middle. SetForegroundWindow also brings the window to the top of the z-order.
    static string EnsureForeground(IntPtr q)
    {
        if (IsIconic(q)) ShowWindowAsync(q, SW_RESTORE);
        for (int round = 1; round <= 2; round++)
        {
            string tag = round == 1 ? "" : ", 2nd round";
            bool attached = ForegroundViaAttach(q);
            if (WaitForeground(q, 100)) return "focused with AttachThreadInput (attached=" + attached + tag + ")";
            SetForegroundWindow(q);
            if (WaitForeground(q, 100)) return "focused with SetForegroundWindow" + (round == 1 ? "" : " (2nd round)");
        }
        SwitchToThisWindow(q, true);
        if (WaitForeground(q, 250)) return "focused with SwitchToThisWindow";
        return "FAILED to focus, focus is " + Describe(GetForegroundWindow());
    }

    static bool ForegroundViaAttach(IntPtr q)
    {
        IntPtr fg = GetForegroundWindow();
        uint ignored;
        uint fgThread = fg == IntPtr.Zero ? 0 : GetWindowThreadProcessId(fg, out ignored);
        uint me = GetCurrentThreadId();
        IntPtr result;
        // Like Terminal: never join the input of a hung window, that can hang this thread too.
        bool responsive = fg != IntPtr.Zero && SendMessageTimeout(fg, WM_NULL, IntPtr.Zero, IntPtr.Zero, SMTO_ABORTIFHUNG | SMTO_BLOCK, 200, out result) != IntPtr.Zero;
        // And never join the input of the window we are raising if it is not answering either.
        IntPtr qResult;
        bool qResponsive = SendMessageTimeout(q, WM_NULL, IntPtr.Zero, IntPtr.Zero, SMTO_ABORTIFHUNG, 200, out qResult) != IntPtr.Zero;
        if (!qResponsive) return false;
        bool attached = responsive && fgThread != 0 && fgThread != me && AttachThreadInput(me, fgThread, true);
        try { SetForegroundWindow(q); }
        finally { if (attached) AttachThreadInput(me, fgThread, false); }
        return attached;
    }

    static bool MouseOnOtherMonitor(IntPtr h)
    {
        POINT p;
        return GetCursorPos(out p) && MonitorFromPoint(p, MONITOR_DEFAULTTONEAREST) != MonitorFromWindow(h, MONITOR_DEFAULTTONEAREST);
    }

    // ---------------------------------------------------------------- keep-alive
    static void OnTimer()
    {
        ticks++;
        TryRegisterHotkey();
        if (ticks % 3 == 0) Watchdog();
    }

    static void TryRegisterHotkey()
    {
        if (hotkeyOn) return;
        if (RegisterHotKey(msgWindow, HOTKEY_ID, hotkey.Mods | MOD_NOREPEAT, hotkey.Vk))
        {
            hotkeyOn = true;
            Log(K + " registered");
        }
        else if (!hotkeyFailLogged)
        {
            int err = Marshal.GetLastWin32Error();
            hotkeyFailLogged = true;
            Log(K + " could not be registered (error " + err + "): " + HotkeyBusyReason(err) + "; retrying every second");
        }
    }

    // Windows keeps the user-mode debugger break key (UserDebuggerHotKey, 0 = F12) registered at all times, which is
    // why a plain F12 hotkey fails with 1409 on a default system. install.ps1 moves it to Scroll Lock (needs a reboot).
    static string HotkeyBusyReason(int err)
    {
        if (err == ERROR_HOTKEY_ALREADY_REGISTERED && (hotkey.Mods == 0 || hotkey.Mods == MOD_SHIFT) && hotkey.Vk == DebuggerBreakVk())
            return "Windows reserves it for the debugger break key (HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\AeDebug"
                 + " UserDebuggerHotKey); install.ps1 moves that to Scroll Lock, then reboot";
        if (err == ERROR_HOTKEY_ALREADY_REGISTERED) return "another program holds it (is Terminal itself still bound to it in settings.json?)";
        return "Windows refused it";
    }

    static uint DebuggerBreakVk()
    {
        try
        {
            object v = Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AeDebug", "UserDebuggerHotKey", 0);
            uint vk = v is int ? (uint)(int)v : 0;
            return vk == 0 ? VK_F12 : vk;
        }
        catch { return VK_F12; }
    }

    // ---------------------------------------------------------------- key specs
    static string K { get { return hotkey.Text ?? "hotkey"; } }

    static bool TryParseKey(string spec, out HotKeySpec key, out string error)
    {
        key = new HotKeySpec();
        error = null;
        if (string.IsNullOrWhiteSpace(spec)) { error = "empty key"; return false; }
        uint mods = 0, vk = 0;
        string name = null;
        foreach (string part in spec.Split('+'))
        {
            string t = part.Trim().ToLowerInvariant();
            if (t == "ctrl" || t == "control") { mods |= MOD_CONTROL; continue; }
            if (t == "alt") { mods |= MOD_ALT; continue; }
            if (t == "shift") { mods |= MOD_SHIFT; continue; }
            if (t == "win" || t == "windows") { mods |= MOD_WIN; continue; }
            if (vk != 0) { error = "more than one key in '" + spec + "'"; return false; }
            if (!TryParseKeyName(t, out vk, out name)) { error = "unknown key '" + part.Trim() + "'"; return false; }
        }
        if (vk == 0) { error = "'" + spec + "' has only modifiers"; return false; }
        if (mods == 0 && !UsableWithoutModifiers(vk))
        {
            error = "'" + name + "' on its own would stop that key from working anywhere else; add a modifier (ctrl+" + name
                  + ") or use F1-F24, pause, scrolllock, insert or apps";
            return false;
        }
        if (mods == (MOD_CONTROL | MOD_ALT | MOD_SHIFT) && vk == VK_F24) { error = TerminalChord + " is reserved for Terminal's own binding"; return false; }
        key.Mods = mods;
        key.Vk = vk;
        key.Text = ((mods & MOD_CONTROL) != 0 ? "ctrl+" : "") + ((mods & MOD_ALT) != 0 ? "alt+" : "")
                 + ((mods & MOD_SHIFT) != 0 ? "shift+" : "") + ((mods & MOD_WIN) != 0 ? "win+" : "") + name;
        return true;
    }

    static bool TryParseKeyName(string t, out uint vk, out string name)
    {
        vk = 0;
        name = t;
        int n;
        if (t.Length >= 2 && t[0] == 'f' && int.TryParse(t.Substring(1), NumberStyles.None, CultureInfo.InvariantCulture, out n) && n >= 1 && n <= 24) { vk = (uint)(0x70 + n - 1); name = "F" + n; return true; }
        if (t.Length == 1 && t[0] >= 'a' && t[0] <= 'z') { vk = (uint)char.ToUpperInvariant(t[0]); name = t.ToUpperInvariant(); return true; }
        if (t.Length == 1 && t[0] >= '0' && t[0] <= '9') { vk = t[0]; return true; }
        if (t.Length == 7 && t.StartsWith("numpad", StringComparison.Ordinal) && t[6] >= '0' && t[6] <= '9') { vk = (uint)(0x60 + t[6] - '0'); return true; }
        if (t.StartsWith("vk:", StringComparison.Ordinal))
        {
            string v = t.Substring(3);
            uint parsed;
            bool ok = v.StartsWith("0x", StringComparison.Ordinal)
                ? uint.TryParse(v.Substring(2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out parsed)
                : uint.TryParse(v, NumberStyles.None, CultureInfo.InvariantCulture, out parsed);
            if (!ok || parsed == 0 || parsed > 0xFE) return false;
            vk = parsed;
            name = "vk:0x" + parsed.ToString("X2");
            return true;
        }
        switch (t)
        {
            case "space": vk = 0x20; return true;
            case "tab": vk = 0x09; return true;
            case "enter": vk = 0x0D; return true;
            case "esc": case "escape": vk = 0x1B; name = "esc"; return true;
            case "insert": case "ins": vk = 0x2D; name = "insert"; return true;
            case "delete": case "del": vk = 0x2E; name = "delete"; return true;
            case "home": vk = 0x24; return true;
            case "end": vk = 0x23; return true;
            case "pageup": case "pgup": vk = 0x21; name = "pageup"; return true;
            case "pagedown": case "pgdn": vk = 0x22; name = "pagedown"; return true;
            case "up": vk = 0x26; return true;
            case "down": vk = 0x28; return true;
            case "left": vk = 0x25; return true;
            case "right": vk = 0x27; return true;
            case "pause": vk = 0x13; return true;
            case "scrolllock": vk = 0x91; return true;
            case "apps": case "menu": vk = 0x5D; name = "apps"; return true;
            case "`": case "backtick": case "grave": vk = 0xC0; name = "backtick"; return true;
        }
        return false;
    }

    // Keys that type, navigate or edit must come with a modifier: a bare global hotkey swallows the key everywhere.
    static bool UsableWithoutModifiers(uint vk)
    {
        return (vk >= 0x70 && vk <= 0x87) || vk == 0x13 || vk == 0x91 || vk == 0x2D || vk == 0x5D;
    }

    static void Watchdog()
    {
        if (sessionEnding) return;
        IntPtr emperor; uint pid;
        bool running = FindNormalTerminal(out emperor, out pid) || NormalTerminalProcessRunning();
        switch (watchdog.Decide(DateTime.Now, running))
        {
            case WatchdogStep.Grace:
                Log("Terminal exited; waiting " + (int)WatchdogPolicy.ExitGrace.TotalMinutes + " minutes before starting a background one (press the key to start it now)");
                break;
            case WatchdogStep.Start:
                Log("no non-elevated Terminal running, starting one in the background");
                if (StartQuake(true)) lastLaunchAt = DateTime.Now;
                break;
        }
    }

    // A Terminal of this user, in this session, not elevated, the release package - including one still starting up
    // (no window yet). Preview, Canary, unpackaged and other users' Terminals also run as WindowsTerminal.exe but can
    // never be driven through the window QuakeKey looks for, so they do not count.
    static bool NormalTerminalProcessRunning()
    {
        foreach (var p in Process.GetProcessesByName("WindowsTerminal"))
        {
            try
            {
                if (IsDrivableTerminal((uint)p.Id)) return true;
            }
            catch { }   // process exited between enumeration and query
            finally { p.Dispose(); }
        }
        return false;
    }

    static bool IsDrivableTerminal(uint pid)
    {
        return SameSession(pid) && SameUser(pid) && !IsElevated(pid) && Logic.IsReleaseTerminalImage(ProcessImagePath(pid));
    }

    static bool OtherElevatedInstanceRunning()
    {
        uint me = GetCurrentProcessId();
        foreach (var p in Process.GetProcessesByName("QuakeKey"))
        {
            try
            {
                uint id = (uint)p.Id;
                if (id != me && SameSession(id) && SameUser(id) && IsElevated(id)) return true;
            }
            catch { }
            finally { p.Dispose(); }
        }
        return false;
    }

    // Elevated: hand the start to a normal-privilege task so Terminal is not started as admin.
    static bool StartQuake(bool background)
    {
        if (!SelfElevated) return StartDirect(background ? "-Embedding" : "-w _quake");
        string task = TaskFolder + (background ? "StartHidden" : "StartShown");
        var si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        var cmd = new StringBuilder("\"" + Path.Combine(Environment.SystemDirectory, "schtasks.exe") + "\" /run /tn \"" + task + "\"");
        PROCESS_INFORMATION pi;
        if (!CreateProcess(null, cmd, IntPtr.Zero, IntPtr.Zero, false, NORMAL_PRIORITY_CLASS | CREATE_NO_WINDOW, IntPtr.Zero, Environment.SystemDirectory, ref si, out pi))
        {
            Log("could not run task " + task + ": error " + Marshal.GetLastWin32Error());
            return false;
        }
        CloseHandle(pi.hThread);
        // schtasks exits 0 once Task Scheduler has accepted the run request: wait for that (briefly, this blocks the
        // thread that answers the key).
        uint exit = STILL_ACTIVE;
        bool timedOut = false;
        try
        {
            uint wait = WaitForSingleObject(pi.hProcess, 10000);
            timedOut = wait == WAIT_TIMEOUT;
            if (!timedOut) GetExitCodeProcess(pi.hProcess, out exit);
        }
        finally { CloseHandle(pi.hProcess); }
        if (timedOut) { Log("task " + task + " did not report within 10 s"); return true; }   // the task may still run
        if (exit != 0) { Log("task " + task + " failed (exit code " + exit + "); is it registered? run install.ps1"); return false; }
        return true;
    }

    static bool StartDirect(string wtArgs)
    {
        var si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        var cmd = new StringBuilder("\"" + WtPath + "\" " + wtArgs);
        PROCESS_INFORMATION pi;
        string cwd = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (!CreateProcess(null, cmd, IntPtr.Zero, IntPtr.Zero, false, NORMAL_PRIORITY_CLASS, IntPtr.Zero, cwd, ref si, out pi))
        {
            Log("could not start Terminal (" + WtPath + "): error " + Marshal.GetLastWin32Error()
                + (File.Exists(WtPath) ? "" : "; the wt.exe app execution alias is off (Settings > Apps > Advanced app settings > App execution aliases)"));
            return false;
        }
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        return true;
    }

    // ---------------------------------------------------------------- window lookup
    static bool FindNormalTerminal(out IntPtr emperor, out uint pid)
    {
        IntPtr found = IntPtr.Zero;
        uint foundPid = 0;
        EnumWindows((h, l) =>
        {
            if (!NormalEmperorClass.IsMatch(ClassOf(h))) return true;
            uint owner;
            GetWindowThreadProcessId(h, out owner);
            // This user's session only: another account's Terminal produces the same class pattern (its SID hash
            // differs) and must never be driven.
            if (!IsDrivableTerminal(owner)) return true;
            found = h;
            foundPid = owner;
            return false;
        }, IntPtr.Zero);
        emperor = found;
        pid = foundPid;
        return found != IntPtr.Zero;
    }

    // Terminal does not expose window names, so the quake window is recognised by where Terminal puts it:
    // flush with the top of a monitor's work area, at least as wide as it, shorter than it, not maximized.
    static IntPtr FindQuake(uint pid)
    {
        if (quakeCache != IntPtr.Zero && IsWindow(quakeCache) && OwnerPid(quakeCache) == pid && ClassOf(quakeCache) == QuakeClass && LooksLikeQuake(quakeCache))
            return quakeCache;
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) =>
        {
            if (OwnerPid(h) != pid || ClassOf(h) != QuakeClass || !LooksLikeQuake(h)) return true;
            found = h;
            return false;
        }, IntPtr.Zero);
        if (found != IntPtr.Zero) quakeCache = found;
        return found;
    }

    static bool LooksLikeQuake(IntPtr h)
    {
        if (IsZoomed(h)) return false;
        RECT r;
        if (IsWindowVisible(h) && !IsIconic(h))
        {
            if (!GetWindowRect(h, out r)) return false;
        }
        else
        {
            var wp = new WINDOWPLACEMENT { length = Marshal.SizeOf(typeof(WINDOWPLACEMENT)) };
            if (!GetWindowPlacement(h, ref wp)) return false;
            r = wp.rcNormal;
            if ((GetWindowLong(h, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) == 0)
            {
                // rcNormalPosition is in workspace coordinates: relative to the primary monitor's work area.
                var pmi = new MONITORINFO { cbSize = Marshal.SizeOf(typeof(MONITORINFO)) };
                GetMonitorInfo(MonitorFromPoint(new POINT(), MONITOR_DEFAULTTOPRIMARY), ref pmi);
                int dx = pmi.rcWork.Left - pmi.rcMonitor.Left, dy = pmi.rcWork.Top - pmi.rcMonitor.Top;
                r.Left += dx; r.Right += dx; r.Top += dy; r.Bottom += dy;
            }
        }
        var mi = new MONITORINFO { cbSize = Marshal.SizeOf(typeof(MONITORINFO)) };
        if (!GetMonitorInfo(MonitorFromRect(ref r, MONITOR_DEFAULTTONEAREST), ref mi)) return false;
        RECT w = mi.rcWork;
        return Math.Abs(r.Top - w.Top) <= 2
            && r.Left <= w.Left + 2
            && r.Right >= w.Right - 2
            && (r.Bottom - r.Top) < (w.Bottom - w.Top) - 8;
    }

    static IntPtr WaitForShownQuake(uint pid, int ms)
    {
        var sw = Stopwatch.StartNew();
        do
        {
            uint p = pid;
            IntPtr emperor;
            if (p != 0 || FindNormalTerminal(out emperor, out p))
            {
                IntPtr q = FindQuake(p);
                if (q != IntPtr.Zero && IsWindowVisible(q) && !IsIconic(q) && !IsCloaked(q)) return q;
            }
            Thread.Sleep(15);
        } while (sw.ElapsedMilliseconds < ms);
        return IntPtr.Zero;
    }

    static bool WaitForeground(IntPtr h, int ms)
    {
        var sw = Stopwatch.StartNew();
        do
        {
            if (GetForegroundWindow() == h) return true;
            Thread.Sleep(10);
        } while (sw.ElapsedMilliseconds < ms);
        return GetForegroundWindow() == h;
    }

    // A window on another virtual desktop is "visible" but cloaked; it must not count as shown, or the toggle
    // logic decides the quake is up when the user cannot see it.
    static bool IsCloaked(IntPtr h)
    {
        int cloaked;
        return DwmGetWindowAttribute(h, DWMWA_CLOAKED, out cloaked, sizeof(int)) == 0 && cloaked != 0;
    }

    // ---------------------------------------------------------------- helpers
    static string ClassOf(IntPtr h)
    {
        var sb = new StringBuilder(128);
        GetClassName(h, sb, sb.Capacity);
        return sb.ToString();
    }

    static uint OwnerPid(IntPtr h)
    {
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        return pid;
    }

    static string Describe(IntPtr h)
    {
        if (h == IntPtr.Zero) return "none";
        uint pid = OwnerPid(h);
        string name = "?";
        try { using (var p = Process.GetProcessById((int)pid)) name = p.ProcessName; } catch { }
        return name + "#" + pid + (IsElevated(pid) ? " (elevated)" : "");
    }

    static string ProcessImagePath(uint pid)
    {
        IntPtr proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (proc == IntPtr.Zero) return null;
        try
        {
            var sb = new StringBuilder(1024);
            int size = sb.Capacity;
            return QueryFullProcessImageName(proc, 0, sb, ref size) ? sb.ToString(0, size) : null;
        }
        finally { CloseHandle(proc); }
    }

    // A token this process cannot read belongs to a higher-integrity (elevated) process.
    static bool IsElevated(uint pid)
    {
        IntPtr proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (proc == IntPtr.Zero) return true;
        try
        {
            IntPtr token;
            if (!OpenProcessToken(proc, TOKEN_QUERY, out token)) return true;
            try
            {
                int len;
                IntPtr buf = Marshal.AllocHGlobal(4);
                try
                {
                    bool ok = GetTokenInformation(token, TokenElevation, buf, 4, out len);
                    return ok && Marshal.ReadInt32(buf) != 0;
                }
                finally { Marshal.FreeHGlobal(buf); }
            }
            finally { CloseHandle(token); }
        }
        finally { CloseHandle(proc); }
    }

    static bool SameSession(uint pid)
    {
        uint mine, theirs;
        return ProcessIdToSessionId(GetCurrentProcessId(), out mine) && ProcessIdToSessionId(pid, out theirs) && mine == theirs;
    }

    // The interactive user's process, not one started under another account (a Terminal's window class matches the
    // same pattern; driving someone else's Terminal would toggle their windows and could crash it).
    static bool SameUser(uint pid)
    {
        IntPtr sid = ProcessSid(pid), mySid = ProcessSid(GetCurrentProcessId());
        bool same = sid != IntPtr.Zero && mySid != IntPtr.Zero && EqualSid(sid, mySid);
        if (sid != IntPtr.Zero) Marshal.FreeHGlobal(sid);
        if (mySid != IntPtr.Zero) Marshal.FreeHGlobal(mySid);
        return same;
    }

    // A heap copy of the process's user SID (free it), or IntPtr.Zero. The SID lives inside GetTokenInformation's
    // buffer, so it must be copied out before the buffer is freed.
    static IntPtr ProcessSid(uint pid)
    {
        IntPtr proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (proc == IntPtr.Zero) return IntPtr.Zero;
        try
        {
            IntPtr token;
            if (!OpenProcessToken(proc, TOKEN_QUERY, out token)) return IntPtr.Zero;
            try
            {
                int len;
                GetTokenInformation(token, TokenUser, IntPtr.Zero, 0, out len);
                if (len <= 0) return IntPtr.Zero;
                IntPtr buf = Marshal.AllocHGlobal(len);
                try
                {
                    if (!GetTokenInformation(token, TokenUser, buf, len, out len)) return IntPtr.Zero;
                    // TOKEN_USER { SID_AND_ATTRIBUTES { SID*, ULONG } }: the SID follows the struct in the same buffer.
                    IntPtr sid = Marshal.ReadIntPtr(buf);
                    if (sid == IntPtr.Zero) return IntPtr.Zero;
                    int sidLen = GetLengthSid(sid);
                    if (sidLen <= 0) return IntPtr.Zero;
                    IntPtr copy = Marshal.AllocHGlobal(sidLen);
                    // CopyFromHGlobal-to-HGlobal via byte walk (keep .NET Framework 4.0 API surface).
                    for (int i = 0; i < sidLen; i++) Marshal.WriteByte(copy, i, Marshal.ReadByte(sid, i));
                    return copy;
                }
                finally { Marshal.FreeHGlobal(buf); }
            }
            finally { CloseHandle(token); }
        }
        finally { CloseHandle(proc); }
    }

    static bool IsLink(string path)
    {
        return (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
    }

    static void Log(string line)
    {
        try
        {
            if (SelfElevated)
            {
                // Only the installer creates these folders (admin-only DACL). Never create them here, and never write
                // through a junction or symlink, which is how a planted link would redirect an admin write.
                if (!Directory.Exists(LogRoot) || IsLink(LogRoot) || !Directory.Exists(LogDir) || IsLink(LogDir)) return;
            }
            else Directory.CreateDirectory(LogDir);
            string path = Path.Combine(LogDir, logName);
            var fi = new FileInfo(path);
            if (fi.Exists && (fi.Attributes & FileAttributes.ReparsePoint) != 0) return;
            if (fi.Exists && fi.Length > 512 * 1024)
            {
                // Rotate by rename only: a copy plus delete as admin is an operation a planted link must never earn.
                try { File.Delete(path + ".old"); } catch { }
                try { File.Move(path, path + ".old"); } catch { }
            }
            File.AppendAllText(path, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff", CultureInfo.InvariantCulture) + "  " + line + Environment.NewLine);
        }
        catch { }
    }
}

// ---------------------------------------------------------------- watchdog policy
internal enum WatchdogStep { Wait, Grace, Start }

// When to start a background Terminal. Pure (the caller passes the time), so the tests drive it with a fake clock.
internal sealed class WatchdogPolicy
{
    // A Terminal seen within RecentlySeen that is now gone probably exited on purpose (the user closed it or typed
    // exit): wait ExitGrace once before starting a background one, instead of fighting the user.
    internal static readonly TimeSpan RecentlySeen = TimeSpan.FromMinutes(10);
    internal static readonly TimeSpan ExitGrace = TimeSpan.FromMinutes(2);

    DateTime nextLaunch = DateTime.MinValue;
    DateTime lastTerminalSeen = DateTime.MinValue;
    bool graceGiven;
    int launchesWithoutTerminal;

    internal WatchdogStep Decide(DateTime now, bool terminalRunning)
    {
        if (terminalRunning)
        {
            lastTerminalSeen = now;
            launchesWithoutTerminal = 0;
            graceGiven = false;
            return WatchdogStep.Wait;
        }
        if (now < nextLaunch) return WatchdogStep.Wait;
        if (!graceGiven && lastTerminalSeen != DateTime.MinValue && now - lastTerminalSeen < RecentlySeen)
        {
            graceGiven = true;
            nextLaunch = now + ExitGrace;
            return WatchdogStep.Grace;
        }
        launchesWithoutTerminal++;
        // 15 s, 30 s, 60 s ... 5 min between attempts while Terminal will not come up.
        nextLaunch = now.AddSeconds(Math.Min(300, 15 * Math.Pow(2, launchesWithoutTerminal - 1)));
        return WatchdogStep.Start;
    }

    // A start made outside the watchdog (the key was pressed with no Terminal running).
    internal void Postpone(DateTime until)
    {
        if (until > nextLaunch) nextLaunch = until;
    }
}

// ---------------------------------------------------------------- pure helpers
internal static class Logic
{
    // The release package's Terminal: ...\WindowsApps\Microsoft.WindowsTerminal_<version>_<arch>__8wekyb3d8bbwe\WindowsTerminal.exe.
    // Preview (Microsoft.WindowsTerminalPreview_...), Canary and unpackaged copies do not match.
    static readonly Regex ReleaseTerminalImage = new Regex(
        @"\\WindowsApps\\Microsoft\.WindowsTerminal_[^\\]+__8wekyb3d8bbwe\\WindowsTerminal\.exe$", RegexOptions.IgnoreCase);

    internal static bool IsReleaseTerminalImage(string path)
    {
        return !string.IsNullOrEmpty(path) && ReleaseTerminalImage.IsMatch(path);
    }

    // The first COR_* or COMPlus_* environment variable with a value (sorted by name), or null.
    internal static string RuntimeHookVariable(IDictionary environment)
    {
        var names = new List<string>();
        foreach (DictionaryEntry e in environment)
        {
            string name = e.Key as string;
            string value = e.Value as string;
            if (name == null || string.IsNullOrEmpty(value)) continue;
            if (name.StartsWith("COR_", StringComparison.OrdinalIgnoreCase) || name.StartsWith("COMPLUS_", StringComparison.OrdinalIgnoreCase))
                names.Add(name);
        }
        if (names.Count == 0) return null;
        names.Sort(StringComparer.OrdinalIgnoreCase);
        return names[0];
    }

    // Terminal key chord text, normalized the way scripts\QuakeKey.Common.ps1 (ConvertTo-QkChord) does it.
    internal static string NormalizeChord(string keys)
    {
        if (keys == null) return null;
        bool ctrl = false, alt = false, shift = false, win = false;
        string key = "";
        foreach (string raw in keys.ToLowerInvariant().Split('+'))
        {
            string p = raw.Trim();
            if (p == "ctrl") ctrl = true;
            else if (p == "alt") alt = true;
            else if (p == "shift") shift = true;
            else if (p == "win") win = true;
            else key = p == "`" ? "sc(41)" : p;
        }
        return (ctrl ? "ctrl+" : "") + (alt ? "alt+" : "") + (shift ? "shift+" : "") + (win ? "win+" : "") + key;
    }

    // True when settings.json binds `chord` to a summon of the quake window: the binding that keeps Terminal's global
    // hotkey table from being empty. Terminal applies inline "keys" on actions first, then "keybindings"; for one
    // chord the last binding wins, and "id": null unbinds it.
    internal static bool SettingsBindChord(string json, string chord, out string why)
    {
        var root = JsonC.Parse(json) as Dictionary<string, object>;
        if (root == null) { why = "settings.json is not a JSON object"; return false; }
        string want = NormalizeChord(chord);
        var byId = new Dictionary<string, Dictionary<string, object>>(StringComparer.Ordinal);
        bool bound = false;
        string boundTo = null;
        object command = null;
        foreach (object a in AsList(Get(root, "actions")))
        {
            var action = a as Dictionary<string, object>;
            if (action == null) continue;
            string id = Get(action, "id") as string;
            if (id != null) byId[id] = action;
            if (!KeysMatch(Get(action, "keys"), want)) continue;
            bound = true;
            boundTo = id ?? "an action without an id";
            command = Get(action, "command");
        }
        foreach (object b in AsList(Get(root, "keybindings")))
        {
            var binding = b as Dictionary<string, object>;
            if (binding == null || !KeysMatch(Get(binding, "keys"), want)) continue;
            bound = true;
            boundTo = Get(binding, "id") as string;
            Dictionary<string, object> action;
            command = boundTo != null && byId.TryGetValue(boundTo, out action) ? Get(action, "command") : null;
            if (boundTo == "Terminal.QuakeMode") command = "quakeMode";
        }
        if (!bound) { why = want + " is not bound"; return false; }
        if (boundTo == null) { why = want + " is unbound (\"id\": null)"; return false; }
        if (!IsQuakeSummon(command)) { why = want + " is bound to " + boundTo + ", which does not summon the _quake window"; return false; }
        why = want + " -> " + boundTo;
        return true;
    }

    // --check-settings: 0 = bound, 3 = not bound, 2 = the file could not be read or parsed.
    internal static int CheckSettingsFile(string path, string chord, out string message)
    {
        string text;
        try { text = File.ReadAllText(path); }
        catch (Exception ex) { message = "error: " + ex.Message; return 2; }
        try
        {
            string why;
            bool ok = SettingsBindChord(text, chord, out why);
            message = (ok ? "ok: " : "missing: ") + why;
            return ok ? 0 : 3;
        }
        catch (FormatException ex) { message = "error: settings.json is not valid JSON: " + ex.Message; return 2; }
    }

    static bool IsQuakeSummon(object command)
    {
        var text = command as string;
        if (text != null) return text == "quakeMode";
        var args = command as Dictionary<string, object>;
        if (args == null) return false;
        var action = Get(args, "action") as string;
        if (action == "quakeMode") return true;
        return action == "globalSummon" && (Get(args, "name") as string) == "_quake";
    }

    static bool KeysMatch(object keys, string want)
    {
        var text = keys as string;
        if (text != null) return NormalizeChord(text) == want;
        foreach (object k in AsList(keys))
        {
            var s = k as string;
            if (s != null && NormalizeChord(s) == want) return true;
        }
        return false;
    }

    static object Get(Dictionary<string, object> o, string name)
    {
        object v;
        return o.TryGetValue(name, out v) ? v : null;
    }

    static List<object> AsList(object v)
    {
        var list = v as List<object>;
        if (list != null) return list;
        var one = new List<object>();
        if (v != null) one.Add(v);
        return one;
    }
}

// JSON with // and /* */ comments and trailing commas, as Windows Terminal accepts it. Objects become
// Dictionary<string, object>, arrays List<object>, numbers double. Throws FormatException on bad input.
internal sealed class JsonC
{
    readonly string s;
    int i;

    JsonC(string text) { s = text; }

    internal static object Parse(string text)
    {
        if (text == null) throw new ArgumentNullException("text");
        var p = new JsonC(text);
        p.Skip();
        object v = p.Value(0);
        p.Skip();
        if (p.i != p.s.Length) throw p.Error("unexpected text after the end");
        return v;
    }

    FormatException Error(string what) { return new FormatException(what + " at offset " + i); }

    void Skip()
    {
        while (i < s.Length)
        {
            char c = s[i];
            if (c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == (char)0xFEFF) { i++; continue; }
            if (c == '/' && i + 1 < s.Length && s[i + 1] == '/') { while (i < s.Length && s[i] != '\n') i++; continue; }
            if (c == '/' && i + 1 < s.Length && s[i + 1] == '*')
            {
                int end = s.IndexOf("*/", i + 2, StringComparison.Ordinal);
                if (end < 0) throw Error("unterminated /* comment");
                i = end + 2;
                continue;
            }
            return;
        }
    }

    object Value(int depth)
    {
        if (depth > 256) throw Error("nested too deeply");
        if (i >= s.Length) throw Error("unexpected end");
        char c = s[i];
        if (c == '{') return ObjectValue(depth);
        if (c == '[') return ArrayValue(depth);
        if (c == '"') return StringValue();
        if (Word("true")) return true;
        if (Word("false")) return false;
        if (Word("null")) return null;
        return NumberValue();
    }

    bool Word(string w)
    {
        if (i + w.Length > s.Length || string.CompareOrdinal(s, i, w, 0, w.Length) != 0) return false;
        i += w.Length;
        return true;
    }

    Dictionary<string, object> ObjectValue(int depth)
    {
        var o = new Dictionary<string, object>(StringComparer.Ordinal);
        i++;
        while (true)
        {
            Skip();
            if (i < s.Length && s[i] == '}') { i++; return o; }
            if (i >= s.Length || s[i] != '"') throw Error("expected a property name");
            string key = StringValue();
            Skip();
            if (i >= s.Length || s[i] != ':') throw Error("expected ':'");
            i++;
            Skip();
            o[key] = Value(depth + 1);
            Skip();
            if (i < s.Length && s[i] == ',') { i++; continue; }
            if (i < s.Length && s[i] == '}') { i++; return o; }
            throw Error("expected ',' or '}'");
        }
    }

    List<object> ArrayValue(int depth)
    {
        var a = new List<object>();
        i++;
        while (true)
        {
            Skip();
            if (i < s.Length && s[i] == ']') { i++; return a; }
            a.Add(Value(depth + 1));
            Skip();
            if (i < s.Length && s[i] == ',') { i++; continue; }
            if (i < s.Length && s[i] == ']') { i++; return a; }
            throw Error("expected ',' or ']'");
        }
    }

    string StringValue()
    {
        i++;
        var sb = new StringBuilder();
        while (true)
        {
            if (i >= s.Length) throw Error("unterminated string");
            char c = s[i++];
            if (c == '"') return sb.ToString();
            if (c != '\\') { sb.Append(c); continue; }
            if (i >= s.Length) throw Error("unterminated string");
            char e = s[i++];
            switch (e)
            {
                case '"': sb.Append('"'); break;
                case '\\': sb.Append('\\'); break;
                case '/': sb.Append('/'); break;
                case 'b': sb.Append('\b'); break;
                case 'f': sb.Append('\f'); break;
                case 'n': sb.Append('\n'); break;
                case 'r': sb.Append('\r'); break;
                case 't': sb.Append('\t'); break;
                case 'u':
                    int code;
                    if (i + 4 > s.Length || !int.TryParse(s.Substring(i, 4), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out code))
                        throw Error("bad \\u escape");
                    sb.Append((char)code);
                    i += 4;
                    break;
                default: throw Error("bad escape \\" + e);
            }
        }
    }

    object NumberValue()
    {
        int start = i;
        while (i < s.Length && "+-0123456789.eE".IndexOf(s[i]) >= 0) i++;
        double d;
        if (i == start || !double.TryParse(s.Substring(start, i - start), NumberStyles.Float, CultureInfo.InvariantCulture, out d))
        {
            i = start;
            throw Error("unexpected character '" + s[start] + "'");
        }
        return d;
    }
}
