<#
.SYNOPSIS
    Removes QuakeKey for your account and restores the Windows Terminal key bindings it changed.

.DESCRIPTION
    1. After one UAC prompt: stops your QuakeKey, removes your scheduled tasks (\QuakeKey\<your SID>\) and, unless
       -KeepLogs, your log folder C:\ProgramData\QuakeKey\<your SID>. When no other account on this PC still uses
       QuakeKey, it also removes C:\Program Files\QuakeKey and C:\ProgramData\QuakeKey and puts the debugger break
       key (HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AeDebug UserDebuggerHotKey) back to the value it had
       before the install, if the installer moved it.
    2. Undoes the installer's changes to Windows Terminal's settings.json (backup first), using the record the
       installer saved in %LOCALAPPDATA%\QuakeKey\terminal-state.json: Terminal gets its previous quake key back.
    3. Removes %LOCALAPPDATA%\QuakeKey except its backups folder.

.PARAMETER KeepTerminalSettings
    Leave Windows Terminal's settings.json as it is. Terminal then has no working quake key (its quake action stays
    bound only to ctrl+alt+shift+f24) until you bind one yourself.

.PARAMETER KeepLogs
    Keep the log folder(s) under C:\ProgramData\QuakeKey.

.PARAMETER KeepDebuggerKey
    Leave the debugger break key where the installer moved it (so F12 stays free for other programs).
#>
[CmdletBinding()]
param([switch]$KeepTerminalSettings, [switch]$KeepLogs, [switch]$KeepDebuggerKey)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\QuakeKey.Common.ps1')
Reset-QkModulePathFor51
$paths = Get-QkPaths

try {
    # QuakeKey goes first: while it runs it holds the hotkey, and Terminal could not take its key back.
    Write-QkStep 'Removing QuakeKey (Windows asks for administrator permission once)'
    $result = Invoke-QkElevated -Mode Uninstall -Parameters @{
        User            = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        KeepLogs        = [bool]$KeepLogs
        KeepDebuggerKey = [bool]$KeepDebuggerKey
    }
    $result.messages | ForEach-Object { Write-QkNote $_ }
    if (-not $result.ok) { throw 'The elevated uninstall step failed (see above). Windows Terminal settings were not changed.' }

    if ($KeepTerminalSettings) {
        Write-QkWarn "settings.json was left as it is (-KeepTerminalSettings): Terminal's quake action is bound only to $QkTerminalChord, so there is no quake key until you bind one (or run uninstall.ps1 again without -KeepTerminalSettings)."
    }
    elseif (Test-Path -LiteralPath $paths.TerminalSettings) {
        Write-QkStep 'Restoring Windows Terminal key bindings'
        $state = $null
        if (Test-Path -LiteralPath $paths.StateFile) { $state = Get-Content -LiteralPath $paths.StateFile -Raw | ConvertFrom-Json }
        else { Write-QkWarn "no install record ($($paths.StateFile)); removing QuakeKey's binding only. Bind your quake key again in Terminal's settings if you want one." }

        $settings = Read-QkJsonFile $paths.TerminalSettings
        $shapeBefore = Get-QkSettingsShape $settings
        $undo = Undo-QkTerminalBinding -Settings $settings -State $state
        if ($undo.Changes.Count) {
            $saved = Save-QkTerminalSettings -Path $paths.TerminalSettings -Settings $undo.Settings -BackupDir $paths.BackupDir -ShapeBefore $shapeBefore -Suffix '-before-uninstall'
            $undo.Changes | ForEach-Object { Write-QkNote $_ }
            Write-QkNote "backup of the previous file: $($saved.Backup)"
        }
        else { Write-QkNote 'nothing to restore' }
    }

    # Local leftovers: the install record, the launcher's log, results of interrupted runs. Backups stay.
    if (Test-Path -LiteralPath $paths.UserDir) {
        Get-ChildItem -LiteralPath $paths.UserDir -Force | Where-Object { $_.Name -ne 'backups' } | ForEach-Object { Remove-QkTreeSafely $_.FullName }
        if (Test-Path -LiteralPath $paths.BackupDir) { Write-QkNote "settings.json backups are kept in $($paths.BackupDir)" }
        else { Remove-QkTreeSafely $paths.UserDir }
    }

    if ($result.rebootNeeded) { Write-QkNote 'Reboot to give the debugger break key back to F12.' }
    elseif ((Get-QkDebuggerBreakVk) -ne 0x7B) {
        Write-QkNote 'The debugger break key (UserDebuggerHotKey) is not on F12; F12 stays free for other programs.'
    }
    Write-Host ''
    Write-Host 'QuakeKey is removed.' -ForegroundColor Green
}
catch {
    Write-Host ''
    Write-Host "Uninstall failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
