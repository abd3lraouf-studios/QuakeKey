<#
.SYNOPSIS
    Removes QuakeKey and restores the Windows Terminal key bindings it changed.

.DESCRIPTION
    1. After one UAC prompt: stops QuakeKey, removes its scheduled tasks, C:\Program Files\QuakeKey and (unless
       -KeepLogs) C:\ProgramData\QuakeKey.
    2. Undoes the installer's changes to Windows Terminal's settings.json (backup first), using the record the
       installer saved in %LOCALAPPDATA%\QuakeKey\terminal-state.json: Terminal gets its previous quake key back.

    The debugger break key (HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AeDebug UserDebuggerHotKey), if the
    installer moved it to free F12, is left where it is.

.PARAMETER KeepTerminalSettings
    Leave Windows Terminal's settings.json as it is.

.PARAMETER KeepLogs
    Keep C:\ProgramData\QuakeKey.
#>
[CmdletBinding()]
param([switch]$KeepTerminalSettings, [switch]$KeepLogs)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\QuakeKey.Common.ps1')
Reset-QkModulePathFor51
$paths = Get-QkPaths

try {
    # QuakeKey goes first: while it runs it holds the hotkey, and Terminal could not take its key back.
    Write-QkStep 'Removing QuakeKey (Windows asks for administrator permission once)'
    $result = Invoke-QkElevated -Mode Uninstall -Parameters @{ KeepLogs = [bool]$KeepLogs }
    $result.messages | ForEach-Object { Write-QkNote $_ }
    if (-not $result.ok) { throw 'The elevated uninstall step failed (see above). Windows Terminal settings were not changed.' }

    if (-not $KeepTerminalSettings -and (Test-Path -LiteralPath $paths.TerminalSettings)) {
        Write-QkStep 'Restoring Windows Terminal key bindings'
        $state = $null
        if (Test-Path -LiteralPath $paths.StateFile) { $state = Get-Content -LiteralPath $paths.StateFile -Raw | ConvertFrom-Json }
        else { Write-QkWarn "no install record ($($paths.StateFile)); removing QuakeKey's binding only. Bind your quake key again in Terminal's settings if you want one." }

        $settings = Read-QkJsonFile $paths.TerminalSettings
        $shapeBefore = Get-QkSettingsShape $settings
        $undo = Undo-QkTerminalBinding -Settings $settings -State $state
        if ($undo.Changes.Count) {
            New-Item -ItemType Directory -Force $paths.BackupDir | Out-Null
            $backup = Join-Path $paths.BackupDir ('settings-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-before-uninstall.json')
            Copy-Item -LiteralPath $paths.TerminalSettings -Destination $backup
            Write-QkJsonFile $paths.TerminalSettings $undo.Settings
            $shapeAfter = Get-QkSettingsShape (Read-QkJsonFile $paths.TerminalSettings)
            if ($shapeAfter -ne $shapeBefore) {
                Copy-Item -LiteralPath $backup -Destination $paths.TerminalSettings -Force
                throw "Rewriting settings.json would have changed more than its key bindings ($shapeBefore -> $shapeAfter). The original was put back."
            }
            $undo.Changes | ForEach-Object { Write-QkNote $_ }
            Write-QkNote "backup of the previous file: $backup"
        }
        else { Write-QkNote 'nothing to restore' }
        if ($state) { Remove-Item -LiteralPath $paths.StateFile -Force }
    }

    if ((Get-QkDebuggerBreakVk) -ne 0x7B) {
        Write-QkNote 'The debugger break key stays moved (UserDebuggerHotKey). Set it back to 0 if you want F12 for debuggers again.'
    }
    Write-Host ''
    Write-Host 'QuakeKey is removed.' -ForegroundColor Green
}
catch {
    Write-Host ''
    Write-Host "Uninstall failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
