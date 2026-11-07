<#
.SYNOPSIS
    Installs QuakeKey: a global hotkey (F12 by default) that toggles the Windows Terminal quake window from
    anywhere, including over admin windows, and always gives it focus.

.DESCRIPTION
    1. Builds QuakeKey.exe from src\QuakeKey.cs with the .NET Framework compiler that ships with Windows.
    2. After one UAC prompt: installs it to C:\Program Files\QuakeKey, creates C:\ProgramData\QuakeKey for its log,
       registers the scheduled tasks \QuakeKey\Hotkey (elevated, at logon), \QuakeKey\StartShown and
       \QuakeKey\StartHidden (normal privileges), and starts it.
    3. Updates Windows Terminal's settings.json (backup first) so Terminal itself no longer registers the hotkey.

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
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\QuakeKey.Common.ps1')
Reset-QkModulePathFor51
$paths = Get-QkPaths

try {
    Write-QkStep 'Checking prerequisites'
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'QuakeKey needs 64-bit Windows.' }
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
    Write-QkNote $exe

    Write-QkStep 'Checking the hotkey'
    $keyInfo = Get-QkKeyInfo -Exe $exe -Key $Key
    $moveDebugger = Test-QkKeyNeedsDebuggerMove $keyInfo
    Write-QkNote "hotkey: $($keyInfo.Text)"
    if ($moveDebugger) { Write-QkNote "Windows reserves $($keyInfo.Text) for its debugger break key; the installer moves that to Scroll Lock (takes effect after a reboot)." }

    # Plan the Terminal change first, so a conflict stops the install before anything is touched.
    $plan = $null
    $previous = $null
    if (-not $SkipTerminalSettings) {
        Write-QkStep 'Checking Windows Terminal settings'
        if (Test-Path -LiteralPath $paths.StateFile) { $previous = Get-Content -LiteralPath $paths.StateFile -Raw | ConvertFrom-Json }
        $setArgs = @{ Monitor = $Monitor; Animation = $Animation; SetMonitor = $PSBoundParameters.ContainsKey('Monitor'); SetAnimation = $PSBoundParameters.ContainsKey('Animation'); PreviousState = $previous }
        $plan = Set-QkTerminalBinding -Settings (Read-QkJsonFile $paths.TerminalSettings) @setArgs
        if ($plan.Changes.Count) { $plan.Changes | ForEach-Object { Write-QkNote $_ } } else { Write-QkNote 'already set up for QuakeKey' }

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
        Key             = $keyInfo.Text
        User            = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        MoveDebuggerKey = [bool]$moveDebugger
        DebuggerBreakVk = $(if ($keyInfo.Vk -eq 0x91) { 0x13 } else { 0x91 })   # Scroll Lock, or Pause if the hotkey is Scroll Lock
    }
    $result = Invoke-QkElevated -Mode Install -Parameters $elevatedArgs
    $result.messages | ForEach-Object { Write-QkNote $_ }
    if (-not $result.ok) { throw 'The elevated install step failed (see above). Windows Terminal settings were not changed.' }

    if (-not $SkipTerminalSettings) {
        Write-QkStep 'Updating Windows Terminal settings'
        New-Item -ItemType Directory -Force $paths.UserDir | Out-Null
        # Re-read: Terminal may have saved the file while the UAC prompt was open.
        $current = Read-QkJsonFile $paths.TerminalSettings
        $shapeBefore = Get-QkSettingsShape $current
        $plan = Set-QkTerminalBinding -Settings $current @setArgs
        if ($plan.Changes.Count) {
            New-Item -ItemType Directory -Force $paths.BackupDir | Out-Null
            $backup = Join-Path $paths.BackupDir ('settings-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
            Copy-Item -LiteralPath $paths.TerminalSettings -Destination $backup
            Write-QkJsonFile $paths.TerminalSettings $plan.Settings
            $shapeAfter = Get-QkSettingsShape (Read-QkJsonFile $paths.TerminalSettings)
            if ($shapeAfter -ne $shapeBefore) {
                Copy-Item -LiteralPath $backup -Destination $paths.TerminalSettings -Force
                throw "Rewriting settings.json would have changed more than its key bindings ($shapeBefore -> $shapeAfter). The original was put back."
            }
            Write-QkNote "saved; backup of the previous file: $backup"
            Write-QkNote 'comments in settings.json are not kept (they are in the backup)'
        }
        else { Write-QkNote 'no change needed' }
        Write-QkJsonFile $paths.StateFile $plan.State   # what uninstall.ps1 undoes
    }
    else {
        Write-QkStep 'Windows Terminal settings: change these by hand (-SkipTerminalSettings)'
        Write-QkNote 'In settings.json, give the quake window one global-summon action and bind it only to ctrl+alt+shift+f24:'
        Write-QkNote '  "actions":     { "command": { "action": "globalSummon", "name": "_quake", "monitor": "any", "dropdownDuration": 200 }, "id": "QuakeKey.Toggle" }'
        Write-QkNote '  "keybindings": { "id": "QuakeKey.Toggle", "keys": "ctrl+alt+shift+f24" },  { "id": null, "keys": "win+sc(41)" }'
        Write-QkNote "Remove any other globalSummon / quakeMode key, especially one on $($keyInfo.Text)."
    }

    Write-QkStep 'Checking that QuakeKey runs'
    $log = Join-Path $paths.LogDir 'quakekey.log'
    $since = (Get-Date).AddSeconds(-30)
    $status = $null
    for ($i = 0; $i -lt 20 -and -not $status; $i++) {
        Start-Sleep -Milliseconds 500
        if (-not (Test-Path -LiteralPath $log)) { continue }
        foreach ($line in (Get-Content -LiteralPath $log -Tail 20)) {
            if ($line.Length -lt 23) { continue }
            $stamp = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($line.Substring(0, 23), 'yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$stamp) -or $stamp -lt $since) { continue }
            if ($line -match ' registered$') { $status = 'ok' }
            elseif ($line -match 'could not be registered') { $status = $line.Substring(25) }
        }
    }

    Write-Host ''
    if ($status -eq 'ok') {
        Write-Host "QuakeKey is installed. Press $($keyInfo.Text) to drop down the Terminal quake window; press it again to hide it." -ForegroundColor Green
    }
    elseif ($result.rebootNeeded) {
        Write-Host "QuakeKey is installed. Reboot once: Windows frees $($keyInfo.Text) from its debugger break key at startup." -ForegroundColor Yellow
    }
    elseif ($status) {
        Write-Host "QuakeKey is installed but could not take the key: $status" -ForegroundColor Yellow
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
