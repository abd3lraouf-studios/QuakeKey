<#
.SYNOPSIS
    Installs QuakeKey: a global hotkey (F12 by default) that toggles the Windows Terminal quake window from
    anywhere, including over admin windows, and always gives it focus.

.DESCRIPTION
    1. Checks the account and machine (administrator account, UAC on, Windows Terminal 1.24+, the wt.exe alias).
    2. Builds QuakeKey.exe from src\QuakeKey.cs with the .NET Framework compiler that ships with Windows.
    3. Updates Windows Terminal's settings.json (backup first) so Terminal itself no longer registers the hotkey.
    4. After one UAC prompt: installs QuakeKey.exe to C:\Program Files\QuakeKey (checking it is the file just
       built), creates C:\ProgramData\QuakeKey\<your SID> for its log, registers the scheduled tasks
       \QuakeKey\<your SID>\Hotkey (elevated, at logon, restarted if it stops), StartShown and StartHidden (normal
       privileges), and starts it. If this step fails or is cancelled, settings.json is put back.

    Run it again at any time to update or change options; the original undo information is kept.
    Remove everything with uninstall.ps1. Details: README.md.

.PARAMETER Key
    The hotkey: modifiers ctrl, alt, shift, win joined with + to one key. Examples: F12 (default), ctrl+alt+t,
    win+backtick, shift+F12, pause. Bare letters, digits and similar typing keys need a modifier.

.PARAMETER Monitor
    Where the quake window appears. any (default): where it was last, and the hotkey always hides it.
    toMouse: on the mouse's monitor (the hotkey moves a focused window there instead of hiding it).
    toCurrent: on the monitor of the focused window. Applied when the installer creates Terminal's quake
    action, or whenever you pass it.

.PARAMETER Animation
    Slide-down / slide-up duration in milliseconds, 0 for none (default 200). Applied like -Monitor.

.PARAMETER SkipTerminalSettings
    Leave Windows Terminal's settings.json alone and print the change to make by hand.

.PARAMETER Force
    Continue even if the installed Windows Terminal is older than 1.24.

.EXAMPLE
    .\install.ps1

.EXAMPLE
    .\install.ps1 -Key ctrl+alt+t -Monitor toMouse -Animation 0
#>
[CmdletBinding()]
param(
    [string]$Key = 'F12',
    [ValidateSet('any', 'toMouse', 'toCurrent')][string]$Monitor = 'any',
    [ValidateRange(0, 2000)][int]$Animation = 200,
    [switch]$SkipTerminalSettings,
    [switch]$Force
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\QuakeKey.Common.ps1')
Reset-QkModulePathFor51
$paths = Get-QkPaths

try {
    Write-QkStep 'Checking prerequisites'
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'QuakeKey needs 64-bit Windows.' }
    $problems = @(Test-QkPrerequisites (Get-QkAccountFacts))
    if ($problems.Count) { throw ($problems -join ' ') }
    $wt = Get-AppxPackage -Name Microsoft.WindowsTerminal -ErrorAction SilentlyContinue | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
    if (-not $wt) { throw 'Windows Terminal (the Microsoft Store / winget package) is not installed. Install it first: winget install Microsoft.WindowsTerminal' }
    if ([version]$wt.Version -lt [version]'1.24.0.0') {
        if (-not $Force) { throw "Windows Terminal $($wt.Version) is older than 1.24, the version QuakeKey is built and tested against. Update it, or pass -Force to try anyway." }
        Write-QkWarn "Windows Terminal $($wt.Version) is older than 1.24; continuing because of -Force."
    }
    Write-QkNote "Windows Terminal $($wt.Version)"
    if (-not $SkipTerminalSettings -and -not (Test-Path -LiteralPath $paths.TerminalSettings)) {
        throw "Windows Terminal has not created its settings.json yet ($($paths.TerminalSettings)). Open Windows Terminal once, close it, and run the installer again."
    }

    Write-QkStep 'Building QuakeKey.exe'
    $exe = Join-Path $PSScriptRoot 'bin\QuakeKey.exe'
    Build-QuakeKey -Source (Join-Path $PSScriptRoot 'src\QuakeKey.cs') -OutFile $exe
    $exeSha256 = Get-QkSha256 -Path $exe   # the elevated step installs only this exact file
    Write-QkNote "$exe (SHA-256 $exeSha256)"

    Write-QkStep 'Checking the hotkey'
    $keyInfo = Get-QkKeyInfo -Exe $exe -Key $Key
    $moveDebugger = Test-QkKeyNeedsDebuggerMove $keyInfo
    Write-QkNote "hotkey: $($keyInfo.Text)"
    if ($moveDebugger) { Write-QkNote "Windows reserves $($keyInfo.Text) for its debugger break key; the installer moves that to Scroll Lock (takes effect after a reboot)." }

    # Terminal settings first: a conflict stops the install before anything is touched, and Terminal lets go of the
    # key before QuakeKey starts. The elevated step below puts them back if it fails.
    $plan = $null
    $settingsWrite = $null
    if (-not $SkipTerminalSettings) {
        Write-QkStep 'Updating Windows Terminal settings'
        $previous = $null
        if (Test-Path -LiteralPath $paths.StateFile) { $previous = Get-Content -LiteralPath $paths.StateFile -Raw | ConvertFrom-Json }
        $current = Read-QkJsonFile $paths.TerminalSettings
        $shapeBefore = Get-QkSettingsShape $current
        $plan = Set-QkTerminalBinding -Settings $current -Monitor $Monitor -Animation $Animation `
            -SetMonitor:$PSBoundParameters.ContainsKey('Monitor') -SetAnimation:$PSBoundParameters.ContainsKey('Animation') -PreviousState $previous
        if ($plan.Changes.Count) {
            $plan.Changes | ForEach-Object { Write-QkNote $_ }
            $settingsWrite = Save-QkTerminalSettings -Path $paths.TerminalSettings -Settings $plan.Settings -BackupDir $paths.BackupDir -ShapeBefore $shapeBefore
            Write-QkNote "saved; backup of the previous file: $($settingsWrite.Backup)"
            Write-QkNote 'comments in settings.json are not kept (they are in the backup)'
        }
        else { Write-QkNote 'already set up for QuakeKey' }

        $globals = Get-QkProp $plan.Settings 'globals'   # null on settings.json without a "globals" block
        $persisted = [string](Get-QkProp $globals 'firstWindowPreference')
        $allowHeadless = [bool](Get-QkProp (Get-QkProp $globals 'compatibility') 'allowHeadless')
        if ($persisted -eq 'persistedWindowLayout' -and -not $allowHeadless) {
            Write-QkWarn "Terminal is set to restore saved window layouts (firstWindowPreference: persistedWindowLayout). Its background start will re-open those windows, and it cannot be fully closed while QuakeKey keeps it running. Set `"compatibility`": { `"allowHeadless`": true } in settings.json to change that."
        }
    }

    Write-QkStep 'Installing (Windows asks for administrator permission once)'
    $elevatedArgs = @{
        Source          = $exe
        SourceSha256    = $exeSha256
        Key             = $keyInfo.Text
        User            = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        MoveDebuggerKey = [bool]$moveDebugger
        DebuggerBreakVk = $(if ($keyInfo.Vk -eq 0x91) { 0x13 } else { 0x91 })   # Scroll Lock, or Pause if the hotkey is Scroll Lock
    }
    $since = Get-Date
    try {
        $result = Invoke-QkElevated -Mode Install -Parameters $elevatedArgs
        $result.messages | ForEach-Object { Write-QkNote $_ }
        if (-not $result.ok) { throw 'The elevated install step failed (see above).' }
    }
    catch {
        if ($settingsWrite) { Write-QkNote (Restore-QkSettingsBackup $settingsWrite) }
        throw
    }

    if ($plan) {
        New-Item -ItemType Directory -Force $paths.UserDir | Out-Null
        Write-QkJsonFile $paths.StateFile $plan.State   # what uninstall.ps1 undoes
    }
    else {
        Write-QkStep 'Windows Terminal settings: change these by hand (-SkipTerminalSettings)'
        Write-QkNote 'In settings.json, give the quake window one global-summon action and bind it only to ctrl+alt+shift+f24:'
        Write-QkNote '  "actions":     { "command": { "action": "globalSummon", "name": "_quake", "monitor": "any", "dropdownDuration": 200 }, "id": "QuakeKey.Toggle" }'
        Write-QkNote '  "keybindings": { "id": "QuakeKey.Toggle", "keys": "ctrl+alt+shift+f24" },  { "id": null, "keys": "win+sc(41)" }'
        Write-QkNote "Remove any other globalSummon / quakeMode key, especially one on $($keyInfo.Text)."
    }

    # QuakeKey retries the key every second, and Terminal lets go of it a moment after its settings change, so a
    # first "could not be registered" is not final: wait up to 15 s for "registered".
    Write-QkStep 'Checking that QuakeKey runs'
    $log = Join-Path $paths.LogDir 'quakekey.log'
    $userLog = Join-Path $paths.UserDir 'quakekey.log'   # where a non-elevated QuakeKey would log
    $status = Get-QkStartStatus -Lines @() -Since $since
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $lines = @()
        foreach ($file in $log, $userLog) { if (Test-Path -LiteralPath $file) { $lines += @(Get-Content -LiteralPath $file -Tail 50) } }
        $status = Get-QkStartStatus -Lines $lines -Since $since
        if ($status.State -eq 'ok' -or $status.State -eq 'stopped') { break }
    }

    Write-Host ''
    if ($status.State -eq 'ok' -and $status.Elevated -eq $false) {
        Write-Host "QuakeKey is installed but runs WITHOUT admin rights, so $($keyInfo.Text) will not work while an admin window has focus." -ForegroundColor Yellow
    }
    elseif ($status.State -eq 'ok') {
        Write-Host "QuakeKey is installed. Press $($keyInfo.Text) to drop down the Terminal quake window; press it again to hide it." -ForegroundColor Green
    }
    elseif ($result.rebootNeeded) {
        Write-Host "QuakeKey is installed. Reboot once: Windows frees $($keyInfo.Text) from its debugger break key at startup." -ForegroundColor Yellow
    }
    elseif ($status.State -eq 'failed' -or $status.State -eq 'stopped') {
        Write-Host "QuakeKey is installed but could not take the key: $($status.Text)" -ForegroundColor Yellow
    }
    else {
        Write-Host "QuakeKey is installed, but its log shows no start yet. Check $log in a moment." -ForegroundColor Yellow
    }
    Write-Host "  log:       $log"
    Write-Host "  uninstall: $(Join-Path $PSScriptRoot 'uninstall.ps1')"
}
catch {
    Write-Host ''
    Write-Host "Install failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
