# Proof of the SetWindowPos bug fixed in 1.1. QuakeKey 1.0 called
#     SetWindowPos(quake, (IntPtr)-1 /*HWND_TOP*/, 0, 0, 0, 0, SWP_ASYNCWINDOWPOS | SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE)
# with SWP_NOACTIVATE defined as 0x0800 (the SDK value is 0x0010), and (IntPtr)-1 is HWND_TOPMOST, not HWND_TOP (0).
# A window owned by another thread gets the same three calls; the script prints whether each worked and whether the
# window ended up always-on-top. Expected:
#     as in 1.0          -> SetWindowPos fails with 1004 (ERROR_INVALID_FLAGS): the call never did anything
#     flag fixed, -1     -> succeeds, WS_EX_TOPMOST set: the quake window would have been pinned on top
#     flag fixed, 0      -> succeeds, not topmost (what was meant)
# The window is created off-screen and closed again. Needs a desktop session; no admin rights.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System; using System.Threading; using System.Runtime.InteropServices;
public static class QkSwpProof {
  delegate IntPtr WndProc(IntPtr h, uint m, IntPtr w, IntPtr l);
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct WNDCLASS { public uint style; public WndProc proc; public int a, b; public IntPtr inst, icon, cur, bg; public string menu, cls; }
  [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr h; public uint m; public IntPtr w, l; public uint t; public int x, y; }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern ushort RegisterClass(ref WNDCLASS c);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr CreateWindowEx(uint ex, string c, string n, uint s, int x, int y, int w, int h, IntPtr p, IntPtr m, IntPtr i, IntPtr pa);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr DefWindowProc(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] static extern int GetMessage(out MSG m, IntPtr h, uint a, uint b);
  [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG m);
  [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr h);
  [DllImport("user32.dll")] static extern void PostQuitMessage(int c);
  [DllImport("user32.dll", SetLastError=true)] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint f);
  [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern IntPtr GetModuleHandle(string n);
  static WndProc keep; static IntPtr win;
  static IntPtr Proc(IntPtr h, uint m, IntPtr w, IntPtr l) { if (m == 0x0010) { DestroyWindow(h); return IntPtr.Zero; } if (m == 0x0002) { PostQuitMessage(0); return IntPtr.Zero; } return DefWindowProc(h, m, w, l); }
  public static string Run(IntPtr after, uint flags) {
    var ready = new ManualResetEvent(false);
    var t = new Thread(() => {
      keep = Proc;
      var c = new WNDCLASS { proc = keep, inst = GetModuleHandle(null), cls = "QkSwpProof" + Guid.NewGuid().ToString("N") };
      RegisterClass(ref c);
      win = CreateWindowEx(0, c.cls, "QuakeKey SetWindowPos proof", 0x10000000 | 0x00CF0000, -3000, -3000, 100, 100, IntPtr.Zero, IntPtr.Zero, c.inst, IntPtr.Zero);
      ready.Set();
      MSG msg; while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0) DispatchMessage(ref msg);
    });
    t.IsBackground = true; t.Start(); ready.WaitOne();
    bool ok = SetWindowPos(win, after, 0, 0, 0, 0, flags); int err = Marshal.GetLastWin32Error();
    Thread.Sleep(300);
    bool topmost = (GetWindowLong(win, -20) & 0x8) != 0;
    PostMessage(win, 0x0010, IntPtr.Zero, IntPtr.Zero); t.Join(2000);
    return string.Format("SetWindowPos returned {0} (error {1}), WS_EX_TOPMOST {2}", ok, ok ? 0 : err, topmost);
  }
}
'@
$asIn10 = [QkSwpProof]::Run([IntPtr](-1), 0x4803)   # 0x4000 | 0x0800 | 0x2 | 0x1
$flagFixed = [QkSwpProof]::Run([IntPtr](-1), 0x4013)
$meant = [QkSwpProof]::Run([IntPtr]::Zero, 0x4013)
Write-Host "as in 1.0 (0x0800, -1): $asIn10"
Write-Host "flag fixed, -1:         $flagFixed"
Write-Host "flag fixed, HWND_TOP:   $meant"
if ($asIn10 -like '*False (error 1004), WS_EX_TOPMOST False' -and $flagFixed -like '*True (error 0), WS_EX_TOPMOST True' -and $meant -like '*True (error 0), WS_EX_TOPMOST False') {
    Write-Host 'PROVEN: the 1.0 call never worked, and fixing only the flag would have made the quake window always-on-top.' -ForegroundColor Green
    exit 0
}
Write-Host 'NOT REPRODUCED: see the lines above.' -ForegroundColor Yellow
exit 1
