# Shared helpers for install.ps1, uninstall.ps1 and tests\Run-Tests.ps1.
# Works in Windows PowerShell 5.1 and PowerShell 7+. Dot-source it; it defines functions and constants only.

# Terminal's globalSummon _quake action is bound to this chord. Nobody presses it: it keeps Terminal from owning the
# real hotkey and makes that action Terminal's only (index 0) global-summon binding. src\QuakeKey.cs uses the same chord.
$QkTerminalChord = 'ctrl+alt+shift+f24'
$QkNewActionId = 'QuakeKey.Toggle'
$QkWinBacktick = 'win+sc(41)'   # Terminal's default quakeMode key (Win+`)

function Get-QkPaths {
    $programFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }   # 64-bit folder even from a 32-bit shell
    $userDir = Join-Path $env:LOCALAPPDATA 'QuakeKey'
    [pscustomobject]@{
        InstallDir       = Join-Path $programFiles 'QuakeKey'
        LogDir           = Join-Path $env:ProgramData 'QuakeKey'
        UserDir          = $userDir
        StateFile        = Join-Path $userDir 'terminal-state.json'
        BackupDir        = Join-Path $userDir 'backups'
        TerminalSettings = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
        Csc              = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    }
}

function Write-QkStep([string]$Text) { Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-QkNote([string]$Text) { Write-Host "    $Text" }
function Write-QkWarn([string]$Text) { Write-Host "    WARNING: $Text" -ForegroundColor Yellow }

function Test-QkElevated {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# A powershell.exe (5.1) started from PowerShell 7 can inherit 7's PSModulePath and load the wrong modules.
function Reset-QkModulePathFor51 {
    if ($PSVersionTable.PSVersion.Major -lt 6 -and $env:PSModulePath -match '\\PowerShell\\[0-9]|\\PowerShell\\Modules') {
        $env:PSModulePath = (@(
                (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'),
                (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'),
                (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\Modules')
            ) -join ';')
    }
}

function Get-QkProp($Object, [string]$Name) {
    if ($null -eq $Object -or $Object -is [string]) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Set-QkProp($Object, [string]$Name, $Value) {
    if ($Object.PSObject.Properties[$Name]) { $Object.$Name = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Remove-QkProp($Object, [string]$Name) {
    if ($Object.PSObject.Properties[$Name]) { $Object.PSObject.Properties.Remove($Name) }
}

# Returns a List[object] (emitted as one object: assign it, foreach over it or pipe it). Never wrap a List in @():
# in both Windows PowerShell 5.1 and PowerShell 7, @($list) on a List[object] throws "Argument types do not match",
# and @(ConvertTo-QkList ...) would be an array holding the list.
function ConvertTo-QkList($Value) {
    $list = New-Object System.Collections.Generic.List[object]
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($item in $Value) { if ($null -ne $item) { $list.Add($item) } }
    }
    elseif ($null -ne $Value) { $list.Add($Value) }
    , $list
}

# ------------------------------------------------------------------ build / run
function Build-QuakeKey {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$OutFile)
    $csc = (Get-QkPaths).Csc
    if (-not (Test-Path -LiteralPath $csc)) { throw "The .NET Framework 4 compiler was not found at $csc." }
    New-Item -ItemType Directory -Force (Split-Path $OutFile) | Out-Null
    $manifest = Join-Path (Split-Path $Source) 'app.manifest'
    $args = @('/nologo', '/target:winexe', '/platform:anycpu', '/optimize+', "/out:$OutFile")
    if (Test-Path -LiteralPath $manifest) { $args += "/win32manifest:$manifest" }
    $output = & $csc @args $Source 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Compiling $Source failed:`n$($output -join "`n")" }
}

# Runs QuakeKey.exe (a GUI-subsystem exe, so PowerShell would not wait for it) and captures its output.
function Invoke-QkExe {
    param([Parameter(Mandatory)][string]$Exe, [string[]]$Arguments)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = (@($Arguments) | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    [pscustomobject]@{ ExitCode = $p.ExitCode; Out = $out.Trim(); Err = $err.Trim() }
}

# Parses `QuakeKey.exe --validate-key` output: "<text> vk=0xNN mods=0xN".
function Get-QkKeyInfo {
    param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string]$Key)
    $r = Invoke-QkExe -Exe $Exe -Arguments @('--validate-key', $Key)
    if ($r.ExitCode -ne 0) { throw "Key '$Key' is not usable: $($r.Err)" }
    if ($r.Out -notmatch '^(?<text>\S+) vk=0x(?<vk>[0-9A-F]+) mods=0x(?<mods>[0-9A-F]+)$') { throw "Unexpected key check output: $($r.Out)" }
    [pscustomobject]@{ Text = $Matches.text; Vk = [Convert]::ToInt32($Matches.vk, 16); Mods = [Convert]::ToInt32($Matches.mods, 16) }
}

# Windows keeps the debugger break key (HKLM ...\AeDebug UserDebuggerHotKey, 0 = F12) registered all the time, so a plain
# F12 global hotkey fails until it is moved. Returns the virtual-key code it currently uses.
function Get-QkDebuggerBreakVk {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $k = $base.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\AeDebug')
        $v = if ($k) { $k.GetValue('UserDebuggerHotKey', 0) } else { 0 }
        if ($k) { $k.Close() }
        if ([int]$v -eq 0) { return 0x7B }
        return [int]$v
    }
    finally { $base.Close() }
}

function Test-QkKeyNeedsDebuggerMove($KeyInfo) {
    ($KeyInfo.Vk -eq (Get-QkDebuggerBreakVk)) -and ($KeyInfo.Mods -eq 0 -or $KeyInfo.Mods -eq 4)
}

# ------------------------------------------------------------------ JSON with comments
# Terminal's settings.json may contain // and /* */ comments and trailing commas, which Windows PowerShell 5.1's
# ConvertFrom-Json rejects. Strips them outside strings. (Comments are not written back; a backup is kept.)
function ConvertFrom-QkJsonC {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $noComments = New-Object System.Text.StringBuilder $Text.Length
    $i = 0; $n = $Text.Length; $inString = $false
    while ($i -lt $n) {
        $c = $Text[$i]
        if ($inString) {
            [void]$noComments.Append($c)
            if ($c -eq [char]'\' -and $i + 1 -lt $n) { [void]$noComments.Append($Text[$i + 1]); $i += 2; continue }
            if ($c -eq [char]'"') { $inString = $false }
            $i++; continue
        }
        if ($c -eq [char]'"') { $inString = $true; [void]$noComments.Append($c); $i++; continue }
        if ($c -eq [char]'/' -and $i + 1 -lt $n -and $Text[$i + 1] -eq [char]'/') {
            while ($i -lt $n -and $Text[$i] -ne "`n") { $i++ }
            continue
        }
        if ($c -eq [char]'/' -and $i + 1 -lt $n -and $Text[$i + 1] -eq [char]'*') {
            $end = $Text.IndexOf('*/', $i + 2)
            if ($end -lt 0) { throw 'Unterminated /* comment in settings.json.' }
            $i = $end + 2; continue
        }
        [void]$noComments.Append($c); $i++
    }

    # Second pass: drop commas that are followed (after whitespace) by } or ], outside strings.
    $t = $noComments.ToString()
    $clean = New-Object System.Text.StringBuilder $t.Length
    $i = 0; $n = $t.Length; $inString = $false
    while ($i -lt $n) {
        $c = $t[$i]
        if ($inString) {
            [void]$clean.Append($c)
            if ($c -eq [char]'\' -and $i + 1 -lt $n) { [void]$clean.Append($t[$i + 1]); $i += 2; continue }
            if ($c -eq [char]'"') { $inString = $false }
            $i++; continue
        }
        if ($c -eq [char]'"') { $inString = $true; [void]$clean.Append($c); $i++; continue }
        if ($c -eq [char]',') {
            $j = $i + 1
            while ($j -lt $n -and [char]::IsWhiteSpace($t[$j])) { $j++ }
            if ($j -lt $n -and ($t[$j] -eq [char]'}' -or $t[$j] -eq [char]']')) { $i++; continue }
        }
        [void]$clean.Append($c); $i++
    }
    $clean.ToString() | ConvertFrom-Json
}

function Read-QkJsonFile([string]$Path) {
    ConvertFrom-QkJsonC -Text ([System.IO.File]::ReadAllText($Path))
}

# Writes UTF-8 without BOM via a temp file, re-parses it, then replaces the target in one step.
function Write-QkJsonFile([string]$Path, $Object) {
    $json = $Object | ConvertTo-Json -Depth 64
    $tmp = "$Path.quakekey-tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding $false))
    try { $null = ConvertFrom-QkJsonC -Text ([System.IO.File]::ReadAllText($tmp)) }
    catch { Remove-Item -LiteralPath $tmp -Force; throw "The new $Path did not parse back: $($_.Exception.Message)" }
    if (Test-Path -LiteralPath $Path) { [System.IO.File]::Replace($tmp, $Path, $null) }
    else { [System.IO.File]::Move($tmp, $Path) }
}

# ------------------------------------------------------------------ Windows Terminal key bindings
function ConvertTo-QkChord([string]$Keys) {
    $mods = @(); $key = $null
    foreach ($part in $Keys.ToLowerInvariant().Split('+')) {
        $p = $part.Trim()
        if ($p -eq 'ctrl' -or $p -eq 'alt' -or $p -eq 'shift' -or $p -eq 'win') { $mods += $p } else { $key = $p }
    }
    if ($key -eq '`') { $key = 'sc(41)' }   # same physical key as Terminal's default win+sc(41) on US layouts
    $ordered = @(@('ctrl', 'alt', 'shift', 'win') | Where-Object { $mods -contains $_ })
    (@($ordered) + @($key)) -join '+'
}

function Get-QkKeyList($Keys) {
    @(@($Keys) | Where-Object { $_ -is [string] -and $_ })
}

# The window a summon command targets: '_quake' for quakeMode, the name for globalSummon ('' = most recent window),
# $null if the command is not a summon at all.
function Get-QkSummonTarget($Command) {
    if ($null -eq $Command) { return $null }
    if ($Command -is [string]) {
        if ($Command -eq 'quakeMode') { return '_quake' }
        if ($Command -eq 'globalSummon') { return '' }
        return $null
    }
    $action = Get-QkProp $Command 'action'
    if ($action -eq 'quakeMode') { return '_quake' }
    if ($action -eq 'globalSummon') {
        $name = Get-QkProp $Command 'name'
        if ($name) { return [string]$name }
        return ''
    }
    return $null
}

# Every key Terminal would register as a global summon, from the user's keybindings, legacy inline "keys" on actions,
# and Terminal's default Win+` quakeMode (unless the user's settings bind or unbind that chord).
function Get-QkSummonBindings($Settings) {
    $actions = ConvertTo-QkList (Get-QkProp $Settings 'actions')
    $bindings = ConvertTo-QkList (Get-QkProp $Settings 'keybindings')
    $byId = @{}
    foreach ($a in $actions) { $id = Get-QkProp $a 'id'; if ($id) { $byId[[string]$id] = $a } }

    $found = New-Object System.Collections.Generic.List[object]
    $userChords = @{}
    foreach ($b in $bindings) {
        $id = Get-QkProp $b 'id'
        foreach ($k in Get-QkKeyList (Get-QkProp $b 'keys')) {
            $chord = ConvertTo-QkChord $k
            $userChords[$chord] = $true
            if (-not $id) { continue }   # "id": null unbinds the chord
            $target = $null; $isUser = $false
            if ($byId.ContainsKey([string]$id)) { $target = Get-QkSummonTarget (Get-QkProp $byId[[string]$id] 'command'); $isUser = $true }
            elseif ($id -eq 'Terminal.QuakeMode') { $target = '_quake' }
            if ($null -ne $target) {
                $found.Add([pscustomobject]@{ Kind = 'keybinding'; Binding = $b; Action = $null; ActionId = [string]$id; Keys = $k; Chord = $chord; Target = $target; UserAction = $isUser })
            }
        }
    }
    foreach ($a in $actions) {
        $keys = Get-QkKeyList (Get-QkProp $a 'keys')
        if (-not $keys) { continue }
        $target = Get-QkSummonTarget (Get-QkProp $a 'command')
        foreach ($k in $keys) {
            $chord = ConvertTo-QkChord $k
            $userChords[$chord] = $true
            if ($null -ne $target) {
                $found.Add([pscustomobject]@{ Kind = 'inline'; Binding = $null; Action = $a; ActionId = [string](Get-QkProp $a 'id'); Keys = $k; Chord = $chord; Target = $target; UserAction = $true })
            }
        }
    }
    if (-not $userChords.ContainsKey($QkWinBacktick)) {
        $found.Add([pscustomobject]@{ Kind = 'default'; Binding = $null; Action = $null; ActionId = 'Terminal.QuakeMode'; Keys = $QkWinBacktick; Chord = $QkWinBacktick; Target = '_quake'; UserAction = $false })
    }
    , $found
}

function New-QkSummonCommand([string]$Monitor, [int]$Animation) {
    [pscustomobject][ordered]@{ action = 'globalSummon'; dropdownDuration = $Animation; monitor = $Monitor; name = '_quake' }
}

function New-QkState {
    [pscustomobject][ordered]@{
        version            = 1
        actionId           = $null
        createdAction      = $false
        originalCommand    = $null
        removedKeybindings = @()
        removedInlineKeys  = @()
        assignedIds        = @()
        addedWinUnbind     = $false
    }
}

# Makes Terminal's settings fit QuakeKey: one global-summon action for the quake window, bound only to
# $QkTerminalChord, and no other global-summon key. Returns @{ Settings; State; Changes }. Throws when the user has
# global summons for other windows (QuakeKey fires hotkey index 0, so it must be the only one).
# -PreviousState: the state saved by an earlier install; its undo information is kept.
function Set-QkTerminalBinding {
    param(
        [Parameter(Mandatory)]$Settings,
        [string]$Monitor = 'any',
        [int]$Animation = 200,
        [switch]$SetMonitor,
        [switch]$SetAnimation,
        $PreviousState
    )
    $changes = New-Object System.Collections.Generic.List[string]
    $summons = Get-QkSummonBindings $Settings
    $others = @($summons | Where-Object { $_.Target -ne '_quake' })
    if ($others.Count) {
        $list = ($others | ForEach-Object { if ($_.Target) { "$($_.Keys) -> window '$($_.Target)'" } else { "$($_.Keys) -> most recent window" } }) -join ', '
        throw "Windows Terminal has global-summon keys for other windows ($list). QuakeKey triggers Terminal's first global-summon binding, so the quake toggle must be the only one. Remove those bindings in settings.json, then run the installer again."
    }

    $state = New-QkState
    if ($PreviousState) {
        foreach ($p in 'actionId', 'createdAction', 'originalCommand', 'removedKeybindings', 'removedInlineKeys', 'assignedIds', 'addedWinUnbind') {
            $v = Get-QkProp $PreviousState $p
            if ($null -ne $v) { $state.$p = $v }
        }
        $state.removedKeybindings = (ConvertTo-QkList $state.removedKeybindings).ToArray()
        $state.removedInlineKeys = (ConvertTo-QkList $state.removedInlineKeys).ToArray()
        $state.assignedIds = (ConvertTo-QkList $state.assignedIds).ToArray()
    }

    $actions = ConvertTo-QkList (Get-QkProp $Settings 'actions')
    $bindings = ConvertTo-QkList (Get-QkProp $Settings 'keybindings')
    $byId = @{}
    foreach ($a in $actions) { $id = Get-QkProp $a 'id'; if ($id) { $byId[[string]$id] = $a } }

    # 1. The action to bind: the one a previous install used, else the user's own quake action, else a new one.
    $action = $null
    if ($state.actionId -and $byId.ContainsKey([string]$state.actionId)) { $action = $byId[[string]$state.actionId] }
    if (-not $action) {
        $mine = @($summons | Where-Object { $_.Kind -eq 'keybinding' -and $_.UserAction }) | Select-Object -First 1
        if ($mine) { $action = $byId[$mine.ActionId] }
    }
    if (-not $action) {
        $inline = @($summons | Where-Object { $_.Kind -eq 'inline' }) | Select-Object -First 1
        if ($inline) { $action = $inline.Action }
    }
    if ($action) {
        if (-not (Get-QkProp $action 'id')) {
            $newId = $QkNewActionId; $n = 2
            while ($byId.ContainsKey($newId)) { $newId = "$QkNewActionId$n"; $n++ }
            Set-QkProp $action 'id' $newId
            $byId[$newId] = $action
            $state.assignedIds += $newId
            $changes.Add("gave the quake action the id '$newId'")
        }
    }
    else {
        $newId = $QkNewActionId; $n = 2
        while ($byId.ContainsKey($newId)) { $newId = "$QkNewActionId$n"; $n++ }
        $action = [pscustomobject][ordered]@{ command = (New-QkSummonCommand $Monitor $Animation); id = $newId }
        $actions.Add($action)
        $byId[$newId] = $action
        $state.createdAction = $true
        $changes.Add("added action '$newId' (globalSummon _quake, monitor $Monitor, dropdownDuration $Animation)")
    }
    $actionId = [string](Get-QkProp $action 'id')
    $state.actionId = $actionId

    # 2. Its command must be a globalSummon of the _quake window; apply -Monitor / -Animation when given explicitly.
    $cmd = Get-QkProp $action 'command'
    $isQuakeSummon = ($cmd -isnot [string]) -and ((Get-QkProp $cmd 'action') -eq 'globalSummon') -and ((Get-QkProp $cmd 'name') -eq '_quake')
    if (-not $isQuakeSummon) {
        if (-not $state.createdAction -and $null -eq $state.originalCommand) { $state.originalCommand = $cmd }
        $m = $Monitor; $d = $Animation
        if ($cmd -isnot [string] -and (Get-QkProp $cmd 'action') -eq 'quakeMode' -and -not $SetAnimation) { $d = 200 }   # quakeMode's own default
        Set-QkProp $action 'command' (New-QkSummonCommand $m $d)
        $changes.Add("made '$actionId' a globalSummon of the _quake window")
    }
    elseif ($SetMonitor -or $SetAnimation) {
        $before = $cmd | ConvertTo-Json -Depth 8 -Compress
        if (-not $state.createdAction -and $null -eq $state.originalCommand) { $state.originalCommand = ($before | ConvertFrom-Json) }
        if ($SetMonitor) { Set-QkProp $cmd 'monitor' $Monitor }
        if ($SetAnimation) { Set-QkProp $cmd 'dropdownDuration' $Animation }
        if (($cmd | ConvertTo-Json -Depth 8 -Compress) -ne $before) { $changes.Add("set '$actionId' monitor $Monitor, dropdownDuration $Animation") }
    }

    # 3. Remove every other global-summon key: Terminal must not register the real hotkey, and ours must be index 0.
    foreach ($s in $summons) {
        if ($s.Kind -eq 'keybinding') {
            if ($s.ActionId -eq $actionId -and $s.Chord -eq $QkTerminalChord) { continue }
            if ($bindings.Remove($s.Binding)) {
                $state.removedKeybindings += [pscustomobject][ordered]@{ id = $s.ActionId; keys = (Get-QkProp $s.Binding 'keys') }
                $changes.Add("removed the key binding $($s.Keys) -> $($s.ActionId)")
            }
        }
        elseif ($s.Kind -eq 'inline') {
            if (Get-QkProp $s.Action 'keys') {
                if (-not (Get-QkProp $s.Action 'id')) {
                    $newId = "$QkNewActionId.Inline"; $n = 2
                    while ($byId.ContainsKey($newId)) { $newId = "$QkNewActionId.Inline$n"; $n++ }
                    Set-QkProp $s.Action 'id' $newId
                    $byId[$newId] = $s.Action
                    $state.assignedIds += $newId
                }
                $state.removedInlineKeys += [pscustomobject][ordered]@{ actionId = [string](Get-QkProp $s.Action 'id'); keys = (Get-QkProp $s.Action 'keys') }
                Remove-QkProp $s.Action 'keys'
                $changes.Add("removed the inline key $($s.Keys) from action '$(Get-QkProp $s.Action 'id')'")
            }
        }
        elseif ($s.Kind -eq 'default') {
            $bindings.Add([pscustomobject][ordered]@{ id = $null; keys = $QkWinBacktick })
            $state.addedWinUnbind = $true
            $changes.Add("switched off Terminal's default Win+`` quake key ($QkWinBacktick)")
        }
    }

    # 4. Bind the action to the chord, and make sure nothing else claims that chord.
    $hasOurs = $false
    foreach ($b in $bindings.ToArray()) {
        $keys = Get-QkKeyList (Get-QkProp $b 'keys')
        if (-not ($keys | Where-Object { (ConvertTo-QkChord $_) -eq $QkTerminalChord })) { continue }
        if ((Get-QkProp $b 'id') -eq $actionId -and $keys.Count -eq 1) { $hasOurs = $true; continue }
        [void]$bindings.Remove($b)
        $state.removedKeybindings += [pscustomobject][ordered]@{ id = (Get-QkProp $b 'id'); keys = (Get-QkProp $b 'keys') }
        $changes.Add("removed another binding that used $QkTerminalChord")
    }
    if (-not $hasOurs) {
        $bindings.Add([pscustomobject][ordered]@{ id = $actionId; keys = $QkTerminalChord })
        $changes.Add("bound '$actionId' to $QkTerminalChord")
    }

    Set-QkProp $Settings 'actions' $actions.ToArray()
    Set-QkProp $Settings 'keybindings' $bindings.ToArray()
    [pscustomobject]@{ Settings = $Settings; State = $state; Changes = $changes.ToArray() }
}

# Reverses Set-QkTerminalBinding using its saved state. Without a state, removes QuakeKey's chord binding and the
# QuakeKey.Toggle action if present. Returns @{ Settings; Changes }.
function Undo-QkTerminalBinding {
    param([Parameter(Mandatory)]$Settings, $State)
    $changes = New-Object System.Collections.Generic.List[string]
    $actions = ConvertTo-QkList (Get-QkProp $Settings 'actions')
    $bindings = ConvertTo-QkList (Get-QkProp $Settings 'keybindings')
    $actionId = if ($State) { [string](Get-QkProp $State 'actionId') } else { $QkNewActionId }

    foreach ($b in $bindings.ToArray()) {
        $keys = Get-QkKeyList (Get-QkProp $b 'keys')
        if ((Get-QkProp $b 'id') -eq $actionId -and ($keys | Where-Object { (ConvertTo-QkChord $_) -eq $QkTerminalChord })) {
            [void]$bindings.Remove($b)
            $changes.Add("removed the binding $QkTerminalChord -> $actionId")
        }
    }

    $action = $actions | Where-Object { (Get-QkProp $_ 'id') -eq $actionId } | Select-Object -First 1
    $created = if ($State) { [bool](Get-QkProp $State 'createdAction') } else { $true }
    if ($action -and $created) {
        [void]$actions.Remove($action)
        $changes.Add("removed action '$actionId'")
    }
    elseif ($action -and $State -and $null -ne (Get-QkProp $State 'originalCommand')) {
        Set-QkProp $action 'command' (Get-QkProp $State 'originalCommand')
        $changes.Add("restored the original command of '$actionId'")
    }

    if ($State) {
        foreach ($r in (ConvertTo-QkList (Get-QkProp $State 'removedKeybindings'))) {
            $rKeys = Get-QkKeyList (Get-QkProp $r 'keys')
            $taken = $false
            foreach ($b in $bindings) {
                foreach ($k in Get-QkKeyList (Get-QkProp $b 'keys')) {
                    if ($rKeys | Where-Object { (ConvertTo-QkChord $_) -eq (ConvertTo-QkChord $k) }) { $taken = $true }
                }
            }
            if ($taken) { $changes.Add("kept the current binding for $($rKeys -join ', ') (not restoring $(Get-QkProp $r 'id'))"); continue }
            $bindings.Add([pscustomobject][ordered]@{ id = (Get-QkProp $r 'id'); keys = (Get-QkProp $r 'keys') })
            $changes.Add("restored the binding $($rKeys -join ', ') -> $(Get-QkProp $r 'id')")
        }
        foreach ($r in (ConvertTo-QkList (Get-QkProp $State 'removedInlineKeys'))) {
            $a = $actions | Where-Object { (Get-QkProp $_ 'id') -eq (Get-QkProp $r 'actionId') } | Select-Object -First 1
            if ($a) { Set-QkProp $a 'keys' (Get-QkProp $r 'keys'); $changes.Add("restored the inline key on '$(Get-QkProp $r 'actionId')'") }
        }
        foreach ($id in (ConvertTo-QkList (Get-QkProp $State 'assignedIds'))) {   # after the lookups above, which use them
            $a = $actions | Where-Object { (Get-QkProp $_ 'id') -eq $id } | Select-Object -First 1
            if ($a) { Remove-QkProp $a 'id'; $changes.Add("removed the id '$id' the installer had added") }
        }
        if (Get-QkProp $State 'addedWinUnbind') {
            foreach ($b in $bindings.ToArray()) {
                if ($null -eq (Get-QkProp $b 'id') -and @(Get-QkKeyList (Get-QkProp $b 'keys') | Where-Object { (ConvertTo-QkChord $_) -eq $QkWinBacktick }).Count) {
                    [void]$bindings.Remove($b)
                    $changes.Add("switched Terminal's default Win+`` quake key back on")
                }
            }
        }
    }

    Set-QkProp $Settings 'actions' $actions.ToArray()
    Set-QkProp $Settings 'keybindings' $bindings.ToArray()
    [pscustomobject]@{ Settings = $Settings; Changes = $changes.ToArray() }
}

# Counts used to check that rewriting settings.json kept everything else.
function Get-QkSettingsShape($Settings) {
    $profiles = Get-QkProp $Settings 'profiles'
    $list = if ($profiles -is [array]) { $profiles } else { Get-QkProp $profiles 'list' }
    '{0} profiles, {1} schemes, {2} themes, {3} top-level keys' -f (ConvertTo-QkList $list).Count, (ConvertTo-QkList (Get-QkProp $Settings 'schemes')).Count,
        (ConvertTo-QkList (Get-QkProp $Settings 'themes')).Count, @($Settings.PSObject.Properties | Where-Object { $_.Name -ne 'actions' -and $_.Name -ne 'keybindings' }).Count
}

# Runs scripts\Elevated.ps1 elevated (one UAC prompt) and returns its result object.
function Invoke-QkElevated {
    param([Parameter(Mandatory)][ValidateSet('Install', 'Uninstall')][string]$Mode, [hashtable]$Parameters = @{})
    $paths = Get-QkPaths
    New-Item -ItemType Directory -Force $paths.UserDir | Out-Null
    $resultFile = Join-Path $paths.UserDir ('elevated-' + [guid]::NewGuid().ToString('N') + '.json')
    $script = Join-Path $PSScriptRoot 'Elevated.ps1'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script + '"'), '-Mode', $Mode, '-ResultFile', ('"' + $resultFile + '"'))
    foreach ($k in $Parameters.Keys) {
        $v = $Parameters[$k]
        if ($v -is [bool] -or $v -is [switch]) { if ($v) { $argList += "-$k" } }
        elseif ($null -ne $v) { $argList += "-$k"; $argList += ('"' + [string]$v + '"') }
    }
    $shell = (Get-Process -Id $PID).Path
    try { $p = Start-Process -FilePath $shell -ArgumentList ($argList -join ' ') -Verb RunAs -WindowStyle Hidden -PassThru -Wait }
    catch { throw "Administrator permission is needed for this step and was not given ($($_.Exception.Message))." }
    if (-not (Test-Path -LiteralPath $resultFile)) { throw "The elevated step exited with code $($p.ExitCode) and left no result." }
    try { $result = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json }
    finally { Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue }
    $result
}
