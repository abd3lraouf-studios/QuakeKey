# Proof of the watchdog bug fixed in 1.1: after Terminal exited, 1.0 logged "waiting 2 minutes" but waited about 10.
# Takes the Watchdog() method of QuakeKey 1.0 straight from git history (needs git and this repository's history),
# compiles it against a fake clock, and simulates: Terminal running, closed at t = 60 s, no key pressed.
# Expected: "waiting 2 minutes" at 60, 180, 300, 420 and 540 s, the background start at 660 s.
# (The fixed policy is tested on every run by tests\Run-Tests.ps1, "watchdog policy".)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot)
$source = (& git -C $repo show 'f76a056:src/QuakeKey.cs') -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'git could not read QuakeKey 1.0 (commit f76a056) from this repository.' }
$m = [regex]::Match($source, '(?s)    static void Watchdog\(\)\n    \{.*?\n    \}\n')
if (-not $m.Success) { throw 'Watchdog() not found in the 1.0 source.' }
$body = $m.Value -replace 'DateTime\.Now', 'Clock.Now'
Add-Type -TypeDefinition @"
using System; using System.Collections.Generic;
public static class Clock { public static DateTime Now; }
public static class QkWatchdog10 {
    public static bool sessionEnding = false;
    static DateTime nextLaunch = DateTime.MinValue, lastTerminalSeen = DateTime.MinValue, lastLaunchAt = DateTime.MinValue;
    static int launchesWithoutTerminal;
    static bool terminalAlive = true;
    public static List<string> log = new List<string>();
    static DateTime t0;
    static bool FindNormalTerminal(out IntPtr e, out uint p) { e = IntPtr.Zero; p = 0; return terminalAlive; }
    static bool NormalTerminalProcessRunning() { return terminalAlive; }
    static bool StartQuake(bool background) { terminalAlive = true; return true; }
    static void Log(string s) { log.Add(string.Format("t={0,4:0} s  {1}", (Clock.Now - t0).TotalSeconds, s)); }
$body
    public static void Run() {
        t0 = new DateTime(2026, 11, 7, 12, 0, 0);
        for (int s = 0; s <= 900; s += 3) { Clock.Now = t0.AddSeconds(s); if (s == 60) terminalAlive = false; Watchdog(); }
    }
}
"@
[QkWatchdog10]::Run()
[QkWatchdog10]::log | ForEach-Object { Write-Host "  $_" }
$waits = @([QkWatchdog10]::log | Where-Object { $_ -match 'waiting 2 minutes' }).Count
$start = @([QkWatchdog10]::log | Where-Object { $_ -match 'starting one in the background' }) | Select-Object -First 1
if ($waits -eq 5 -and $start -match 't= 660') { Write-Host 'PROVEN: 1.0 waited 10 minutes, announcing 2 minutes five times.' -ForegroundColor Green; exit 0 }
Write-Host 'NOT REPRODUCED: see the lines above.' -ForegroundColor Yellow
exit 1
