# Elevated half of install.ps1 and uninstall.ps1. They start it with a single UAC prompt; do not run it directly.
#  Install:   copies QuakeKey.exe to Program Files, creates the admin-only log folder, optionally moves the debugger
#             break key off the chosen hotkey, registers the scheduled tasks and starts QuakeKey.
#  Uninstall: stops QuakeKey and removes its tasks, Program Files folder and (unless -KeepLogs) its logs.
# Writes a JSON result to -ResultFile (created new; never overwrites an existing file).
param(
    [Parameter(Mandatory)][ValidateSet('Install', 'Uninstall')][string]$Mode,
    [Parameter(Mandatory)][string]$ResultFile,
    [string]$Source,
    [string]$Key = 'F12',
    [string]$User,
    [switch]$MoveDebuggerKey,
    [int]$DebuggerBreakVk = 0x91,
    [switch]$KeepLogs
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'QuakeKey.Common.ps1')
Reset-QkModulePathFor51

$messages = New-Object System.Collections.Generic.List[string]
$ok = $false
$reboot = $false

# Current task layout, then the layouts of the first (unpublished) versions, which are always removed.
$currentTasks = @(@{ Path = '\QuakeKey\'; Name = 'Hotkey' }, @{ Path = '\QuakeKey\'; Name = 'StartHidden' }, @{ Path = '\QuakeKey\'; Name = 'StartShown' })
$legacyTasks = @(@{ Path = '\Elevated\'; Name = 'QuakeKey' }, @{ Path = '\'; Name = 'QuakeKey' })

function Get-QkTask($t) { Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue }

# %ProgramData% lets every user create files, so the log folder gets its own ACL: SYSTEM and Administrators full
# control, Users read. The elevated QuakeKey only writes there, and never through a link.
function Initialize-QkLogDir([string]$Dir) {
    if (Test-Path -LiteralPath $Dir) {
        $item = Get-Item -LiteralPath $Dir -Force
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            [System.IO.Directory]::Delete($Dir)   # removes a planted junction/symlink itself, not its target
            $messages.Add("removed a link that sat at $Dir")
        }
    }
    New-Item -ItemType Directory -Force $Dir | Out-Null
    $out = & icacls.exe $Dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /Q 2>&1
    if ($LASTEXITCODE -ne 0) { throw "icacls could not secure $Dir`: $out" }
    $out = & icacls.exe $Dir /setowner '*S-1-5-32-544' /T /Q 2>&1
    if ($LASTEXITCODE -ne 0) { throw "icacls could not set the owner of $Dir`: $out" }
    Get-ChildItem -LiteralPath $Dir -Force | Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force; $messages.Add("removed a link that sat at $($_.FullName)") }
}

try {
    if (-not (Test-QkElevated)) { throw 'This step must run elevated.' }
    $paths = Get-QkPaths
    $exe = Join-Path $paths.InstallDir 'QuakeKey.exe'
    if (-not $User) { $User = [Security.Principal.WindowsIdentity]::GetCurrent().Name }

    # Stop every running copy so the exe can be replaced or removed.
    foreach ($t in $currentTasks + $legacyTasks) { $task = Get-QkTask $t; if ($task) { $task | Stop-ScheduledTask -ErrorAction SilentlyContinue } }
    Get-Process -Name QuakeKey -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    foreach ($t in $legacyTasks) {
        if (Get-QkTask $t) { Unregister-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -Confirm:$false; $messages.Add("removed the old task $($t.Path)$($t.Name)") }
    }

    if ($Mode -eq 'Install') {
        if (-not $Source -or -not (Test-Path -LiteralPath $Source)) { throw "The built QuakeKey.exe was not found at '$Source'." }
        New-Item -ItemType Directory -Force $paths.InstallDir | Out-Null
        Copy-Item -LiteralPath $Source -Destination $exe -Force
        $messages.Add("installed $exe")

        Initialize-QkLogDir $paths.LogDir
        $messages.Add("log folder $($paths.LogDir) (administrators write, users read)")

        if ($MoveDebuggerKey) {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
            try {
                $k = $base.CreateSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\AeDebug')
                $k.SetValue('UserDebuggerHotKey', $DebuggerBreakVk, [Microsoft.Win32.RegistryValueKind]::DWord)
                $k.Close()
            }
            finally { $base.Close() }
            $reboot = $true
            $messages.Add(('moved the debugger break key (UserDebuggerHotKey) to 0x{0:X2}; {1} works after the next reboot' -f $DebuggerBreakVk, $Key))
        }

        $common = @{ AllowStartIfOnBatteries = $true; DontStopIfGoingOnBatteries = $true; Priority = 4 }   # 4 = normal (default 7 is below normal)
        $hotkeySettings = New-ScheduledTaskSettingsSet @common -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
            -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
        Register-ScheduledTask -TaskPath '\QuakeKey\' -TaskName 'Hotkey' -Force `
            -Action (New-ScheduledTaskAction -Execute $exe -Argument ('--key "' + $Key + '"') -WorkingDirectory $paths.InstallDir) `
            -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $User) `
            -Principal (New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Highest) `
            -Settings $hotkeySettings -Description "QuakeKey: $Key toggles the Windows Terminal quake window (https://github.com/abd3lraouf-studios/QuakeKey)." | Out-Null
        $messages.Add("registered task \QuakeKey\Hotkey for $User (runs elevated at logon)")

        $launchSettings = New-ScheduledTaskSettingsSet @common -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -MultipleInstances Parallel
        foreach ($which in 'Shown', 'Hidden') {   # not $mode: PowerShell variables ignore case and $Mode is a parameter
            Register-ScheduledTask -TaskPath '\QuakeKey\' -TaskName "Start$which" -Force `
                -Action (New-ScheduledTaskAction -Execute $exe -Argument "--start $($which.ToLower())" -WorkingDirectory $paths.InstallDir) `
                -Principal (New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited) `
                -Settings $launchSettings -Description "QuakeKey: starts Windows Terminal ($($which.ToLower())) without admin rights." | Out-Null
        }
        $messages.Add('registered tasks \QuakeKey\StartShown and \QuakeKey\StartHidden (normal privileges)')

        Start-ScheduledTask -TaskPath '\QuakeKey\' -TaskName 'Hotkey'
        $messages.Add('started QuakeKey')
    }
    else {
        foreach ($t in $currentTasks) {
            if (Get-QkTask $t) { Unregister-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -Confirm:$false; $messages.Add("removed task $($t.Path)$($t.Name)") }
        }
        try {
            $svc = New-Object -ComObject Schedule.Service
            $svc.Connect()
            $svc.GetFolder('\').DeleteFolder('QuakeKey', 0)
        }
        catch { }
        if (Test-Path -LiteralPath $paths.InstallDir) { Remove-Item -LiteralPath $paths.InstallDir -Recurse -Force; $messages.Add("removed $($paths.InstallDir)") }
        if (-not $KeepLogs -and (Test-Path -LiteralPath $paths.LogDir)) { Remove-Item -LiteralPath $paths.LogDir -Recurse -Force; $messages.Add("removed $($paths.LogDir)") }
    }
    $ok = $true
}
catch { $messages.Add("ERROR: $($_.Exception.Message)") }
finally {
    $json = [pscustomobject]@{ ok = $ok; rebootNeeded = $reboot; messages = $messages.ToArray() } | ConvertTo-Json -Depth 4
    try {
        $fs = [System.IO.File]::Open($ResultFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
        try { $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($json); $fs.Write($bytes, 0, $bytes.Length) }
        finally { $fs.Close() }
    }
    catch { }
}
if ($ok) { exit 0 } else { exit 1 }
