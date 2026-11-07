# Elevated half of install.ps1 and uninstall.ps1. They start it with a single UAC prompt; do not run it directly.
#  Install:   copies the built QuakeKey.exe to Program Files after checking its SHA-256, creates the admin-only log
#             folders, optionally moves the debugger break key off the chosen hotkey (recording the old value),
#             registers this user's scheduled tasks under \QuakeKey\<SID>\ and starts QuakeKey.
#  Uninstall: stops this user's QuakeKey and removes their tasks and log folder. The last user to uninstall also
#             removes Program Files\QuakeKey and the log root, and puts the debugger break key back.
# Writes a JSON result to -ResultFile (created new; never overwrites an existing file or writes through a link).
param(
    [Parameter(Mandatory)][ValidateSet('Install', 'Uninstall')][string]$Mode,
    [Parameter(Mandatory)][string]$ResultFile,
    [string]$User,
    [string]$Source,
    [string]$SourceSha256,
    [string]$Key = 'F12',
    [switch]$MoveDebuggerKey,
    [int]$DebuggerBreakVk = 0x91,
    [switch]$KeepLogs,
    [switch]$KeepDebuggerKey
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'QuakeKey.Common.ps1')
Reset-QkModulePathFor51

$messages = New-Object System.Collections.Generic.List[string]
$ok = $false
$reboot = $false

# Layouts of earlier versions, removed when they belong to this user: v1.0 (\QuakeKey\Hotkey, Start*) and the
# unpublished versions before it.
$legacyTasks = @(
    @{ Path = '\QuakeKey\'; Name = 'Hotkey' }, @{ Path = '\QuakeKey\'; Name = 'StartShown' }, @{ Path = '\QuakeKey\'; Name = 'StartHidden' },
    @{ Path = '\Elevated\'; Name = 'QuakeKey' }, @{ Path = '\'; Name = 'QuakeKey' })

function Test-QkTaskOwner($Task, [string]$Sid) {
    $id = $Task.Principal.UserId
    if (-not $id) { return $false }   # a group principal; Get-QkUserSid '' would mean "the current user"
    try { (Get-QkUserSid $id) -eq $Sid } catch { $false }
}

function Stop-QkUserProcesses([string]$Sid) {
    $stopped = 0
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='QuakeKey.exe'")) {
        # A process that is exiting (the task stop just above) can still be listed and then fail GetOwnerSid.
        try { $owner = Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid }
        catch { Write-Verbose "process $($p.ProcessId) exited while being checked"; continue }
        if ($owner.Sid -eq $Sid) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue; $stopped++ }
    }
    $stopped
}

function Remove-QkTaskFolder([string]$Path) {
    # Path like \QuakeKey\S-1-...\ or \QuakeKey\ ; the folder is only deleted when empty.
    $parts = $Path.Trim('\').Split('\')
    $parent = if ($parts.Count -gt 1) { '\' + ($parts[0..($parts.Count - 2)] -join '\') } else { '\' }
    try {
        $svc = New-Object -ComObject Schedule.Service
        $svc.Connect()
        $svc.GetFolder($parent).DeleteFolder($parts[-1], 0)
    }
    catch { Write-Verbose "task folder $Path not removed: not empty or already gone" }
}

try {
    if (-not (Test-QkElevated)) { throw 'This step must run elevated.' }
    if (-not $User) { $User = [Security.Principal.WindowsIdentity]::GetCurrent().Name }
    $sid = Get-QkUserSid $User
    $paths = Get-QkPaths -Sid $sid
    $exe = Join-Path $paths.InstallDir 'QuakeKey.exe'
    $debuggerRecord = Join-Path $paths.InstallDir 'debugger-key.json'

    # Stop this user's copies so the exe can be replaced or removed. Other users' QuakeKey keeps running.
    $mine = @(Get-ScheduledTask -TaskPath $paths.TaskFolder -ErrorAction SilentlyContinue)
    $legacy = @($legacyTasks | ForEach-Object { Get-ScheduledTask -TaskPath $_.Path -TaskName $_.Name -ErrorAction SilentlyContinue } |
            Where-Object { Test-QkTaskOwner $_ $sid })
    foreach ($task in $mine + $legacy) { $task | Stop-ScheduledTask -ErrorAction SilentlyContinue }
    $stopped = Stop-QkUserProcesses $sid
    if ($stopped) { $messages.Add("stopped $stopped running QuakeKey process(es) of $User") }
    Start-Sleep -Milliseconds 500
    foreach ($task in $legacy) {
        Unregister-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -Confirm:$false
        $messages.Add("removed the old task $($task.TaskPath)$($task.TaskName)")
    }

    if ($Mode -eq 'Install') {
        if (-not $Source -or -not $SourceSha256) { throw 'Install needs -Source and -SourceSha256.' }
        New-Item -ItemType Directory -Force $paths.InstallDir | Out-Null
        $how = Copy-QkVerifiedFile -Source $Source -Destination $exe -Sha256 $SourceSha256
        $messages.Add("$exe $how (SHA-256 checked)")

        foreach ($m in (Initialize-QkLogFolders -Root $paths.LogRoot -Sid $sid)) { $messages.Add($m) }
        $messages.Add("log folder $($paths.LogDir) (administrators write, $User reads)")

        if ($MoveDebuggerKey) {
            # The first install that moves it records the original value; uninstall puts that back.
            if (-not (Test-Path -LiteralPath $debuggerRecord)) {
                $record = [pscustomobject]@{ original = (Get-QkDebuggerKeyValue); set = $DebuggerBreakVk }
                [IO.File]::WriteAllText($debuggerRecord, ($record | ConvertTo-Json))
            }
            Set-QkDebuggerKeyValue $DebuggerBreakVk
            $reboot = $true
            $messages.Add(('moved the debugger break key (UserDebuggerHotKey) to 0x{0:X2}; {1} works after the next reboot' -f $DebuggerBreakVk, $Key))
        }

        $definitions = New-QkTaskDefinitions -Exe $exe -Key $Key -User $User -WorkingDirectory $paths.InstallDir
        foreach ($name in $definitions.Keys) {
            $d = $definitions[$name]
            $register = @{ TaskPath = $paths.TaskFolder; TaskName = $name; Action = $d.Action; Principal = $d.Principal; Settings = $d.Settings; Description = $d.Description; Force = $true }
            if ($d.ContainsKey('Trigger')) { $register.Trigger = $d.Trigger }
            Register-ScheduledTask @register | Out-Null
        }
        $messages.Add("registered tasks $($paths.TaskFolder)Hotkey (elevated, at logon, restarted within 5 minutes if it stops), StartShown and StartHidden (normal privileges)")

        try {
            Start-ScheduledTask -TaskPath $paths.TaskFolder -TaskName 'Hotkey'
            $messages.Add('started QuakeKey')
        }
        catch { $messages.Add("could not start QuakeKey now ($($_.Exception.Message)); it starts at the next sign-in") }
    }
    else {
        foreach ($task in $mine) {
            Unregister-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -Confirm:$false
            $messages.Add("removed task $($task.TaskPath)$($task.TaskName)")
        }
        Remove-QkTaskFolder $paths.TaskFolder
        if (-not $KeepLogs -and (Test-QkPathExists $paths.LogDir)) { Remove-QkTreeSafely $paths.LogDir; $messages.Add("removed $($paths.LogDir)") }

        $others = @(Get-QkInstalledUserSids | Where-Object { $_ -ne $sid })
        if ($others.Count) {
            $messages.Add("kept $($paths.InstallDir): $($others.Count) other user(s) still use QuakeKey")
        }
        else {
            if (Test-Path -LiteralPath $debuggerRecord) {
                $record = Get-Content -LiteralPath $debuggerRecord -Raw | ConvertFrom-Json
                $current = Get-QkDebuggerKeyValue
                if ($KeepDebuggerKey) { $messages.Add('left the debugger break key where the installer moved it (-KeepDebuggerKey)') }
                elseif ($current -eq [int]$record.set) {
                    Set-QkDebuggerKeyValue $record.original
                    $reboot = $true
                    $was = if ($null -eq $record.original) { 'not set (F12)' } else { '0x{0:X2}' -f [int]$record.original }
                    $messages.Add("put the debugger break key back ($was); takes effect after a reboot")
                }
                else { $messages.Add('left the debugger break key as it is: it was changed after the install') }
            }
            if (Test-QkPathExists $paths.InstallDir) { Remove-QkTreeSafely $paths.InstallDir; $messages.Add("removed $($paths.InstallDir)") }
            if (-not $KeepLogs -and (Test-QkPathExists $paths.LogRoot)) { Remove-QkTreeSafely $paths.LogRoot; $messages.Add("removed $($paths.LogRoot)") }
            Remove-QkTaskFolder '\QuakeKey\'
        }
    }
    $ok = $true
}
catch { $messages.Add("ERROR: $($_.Exception.Message)") }
finally {
    $json = [pscustomobject]@{ ok = $ok; rebootNeeded = $reboot; messages = $messages.ToArray() } | ConvertTo-Json -Depth 4
    try {
        $parent = Split-Path $ResultFile
        if ((Test-QkPathExists $parent) -and -not (Test-QkLink $parent)) {
            $fs = [System.IO.File]::Open($ResultFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
            try { $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($json); $fs.Write($bytes, 0, $bytes.Length) }
            finally { $fs.Close() }
        }
    }
    catch { Write-Verbose "could not write the result file: $($_.Exception.Message)" }
}
if ($ok) { exit 0 } else { exit 1 }
