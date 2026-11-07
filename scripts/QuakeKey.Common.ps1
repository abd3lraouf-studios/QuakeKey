# Shared helpers for install.ps1, uninstall.ps1, scripts\Elevated.ps1 and tests\Run-Tests.ps1.
# Works in Windows PowerShell 5.1 and PowerShell 7+, under Set-StrictMode -Version Latest. Dot-source it; it defines
# functions and constants only.

# Terminal's globalSummon _quake action is bound to this chord. Nobody presses it: it keeps Terminal from owning the
# real hotkey and makes that action Terminal's only (index 0) global-summon binding. src\QuakeKey.cs uses the same chord.
$QkTerminalChord = 'ctrl+alt+shift+f24'
$QkNewActionId = 'QuakeKey.Toggle'
$QkWinBacktick = 'win+sc(41)'   # Terminal's default quakeMode key (Win+`)

# ------------------------------------------------------------------ paths and accounts
function Get-QkUserSid([string]$User) {
    if (-not $User) { return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
    if ($User -match '^S-1-[0-9-]+$') { return $User }
    ([Security.Principal.NTAccount]$User).Translate([Security.Principal.SecurityIdentifier]).Value
}

# Everything QuakeKey puts on the machine for one user (default: the current one).
function Get-QkPaths {
    param([string]$Sid)
    if (-not $Sid) { $Sid = Get-QkUserSid }
    $programFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }   # 64-bit folder even from a 32-bit shell
    $userDir = Join-Path $env:LOCALAPPDATA 'QuakeKey'
    $logRoot = Join-Path $env:ProgramData 'QuakeKey'
    [pscustomobject]@{
        Sid              = $Sid
        InstallDir       = Join-Path $programFiles 'QuakeKey'
        LogRoot          = $logRoot
        LogDir           = Join-Path $logRoot $Sid
        TaskFolder       = "\QuakeKey\$Sid\"
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

# What install.ps1 needs to know about the account and the machine. whoami prints SIDs, which are not localized;
# .NET's WindowsIdentity.Groups leaves out the deny-only Administrators group of a limited admin token.
function Get-QkAccountFacts {
    $sids = @(& "$env:WINDIR\System32\whoami.exe" /groups /fo csv /nh | ConvertFrom-Csv -Header Name, Type, Sid, Attributes | ForEach-Object { $_.Sid })
    $integrity = if ($sids -contains 'S-1-16-12288' -or $sids -contains 'S-1-16-16384') { 'High' } elseif ($sids -contains 'S-1-16-8192') { 'Medium' } else { 'Other' }
    $policy = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $lua = Get-ItemProperty -LiteralPath $policy -Name EnableLUA -ErrorAction SilentlyContinue
    $filter = Get-ItemProperty -LiteralPath $policy -Name FilterAdministratorToken -ErrorAction SilentlyContinue
    [pscustomobject]@{
        UacEnabled               = ($null -eq $lua) -or ([int]$lua.EnableLUA -ne 0)
        Integrity                = $integrity
        InAdministrators         = $sids -contains 'S-1-5-32-544'
        BuiltinAdministrator     = (Get-QkUserSid) -match '-500$'
        BuiltinAdminApprovalMode = ($null -ne $filter) -and ([int]$filter.FilterAdministratorToken -eq 1)
        WtAlias                  = [IO.File]::Exists((Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'))
    }
}

# Problems that stop an install, from Get-QkAccountFacts. QuakeKey tells your normal Terminal from an elevated one by
# the token's elevation, which needs UAC and a split admin token.
function Test-QkPrerequisites($Facts) {
    $problems = New-Object System.Collections.Generic.List[string]
    if (-not $Facts.UacEnabled) { $problems.Add('UAC is turned off (EnableLUA = 0). With UAC off every program runs as admin, so QuakeKey cannot keep your Terminal non-admin. Turn UAC on and reboot.') }
    if (-not $Facts.InAdministrators) { $problems.Add('This account is not an administrator. QuakeKey must run elevated to receive its key over admin windows; install it from an administrator account.') }
    if ($Facts.BuiltinAdministrator -and -not $Facts.BuiltinAdminApprovalMode) { $problems.Add('This is the built-in Administrator account, which runs every program elevated. Use a normal administrator account.') }
    if (-not $Facts.WtAlias) { $problems.Add('The wt.exe app execution alias is off. Turn on "Terminal" under Settings > Apps > Advanced app settings > App execution aliases.') }
    $problems.ToArray()   # unrolled: callers collect it with @()
}

function Get-QkProp($Object, [string]$Name) {
    if ($null -eq $Object -or $Object -is [string] -or $Object -is [ValueType]) { return $null }
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

function Get-QkSha256 {
    param([byte[]]$Bytes, [string]$Path)
    if ($Path) { $Bytes = [IO.File]::ReadAllBytes($Path) }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('X2') }) }
    finally { $sha.Dispose() }
}

# ------------------------------------------------------------------ build / run
function Build-QuakeKey {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$OutFile)
    $csc = (Get-QkPaths).Csc
    if (-not (Test-Path -LiteralPath $csc)) { throw "The .NET Framework 4 compiler was not found at $csc." }
    New-Item -ItemType Directory -Force (Split-Path $OutFile) | Out-Null
    $manifest = Join-Path (Split-Path $Source) 'app.manifest'
    $cscArgs = @('/nologo', '/target:winexe', '/platform:anycpu', '/optimize+', '/codepage:65001', "/out:$OutFile")
    if (Test-Path -LiteralPath $manifest) { $cscArgs += "/win32manifest:$manifest" }
    # A freshly written exe can be held for a moment (an antivirus scan, a test that just ran it): csc then fails with
    # CS0016 "could not write to output file". That one error is retried; any other fails at once.
    for ($attempt = 1; ; $attempt++) {
        $output = @(& $csc @cscArgs $Source 2>&1)
        if ($LASTEXITCODE -eq 0) { return }
        if ($attempt -ge 5 -or -not ($output -match 'CS0016')) { throw "Compiling $Source failed:`n$($output -join "`n")" }
        Start-Sleep -Milliseconds (500 * $attempt)
    }
}

# One command-line argument, quoted the way CommandLineToArgvW / the C runtime read it back.
function ConvertTo-QkArgument([string]$Value) {
    '"' + (($Value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

# Runs QuakeKey.exe (a GUI-subsystem exe, so PowerShell would not wait for it) and captures its output.
function Invoke-QkExe {
    param([Parameter(Mandatory)][string]$Exe, [string[]]$Arguments)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = (@($Arguments) | ForEach-Object { ConvertTo-QkArgument $_ }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()   # both at once: reading one to the end first can deadlock on the other
    $err = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    [pscustomobject]@{ ExitCode = $p.ExitCode; Out = $out.Result.Trim(); Err = $err.Result.Trim() }
}

# Parses `QuakeKey.exe --validate-key` output: "<text> vk=0xNN mods=0xN".
function Get-QkKeyInfo {
    param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string]$Key)
    $r = Invoke-QkExe -Exe $Exe -Arguments @('--validate-key', $Key)
    if ($r.ExitCode -ne 0) { throw "Key '$Key' is not usable: $($r.Err)" }
    if ($r.Out -notmatch '^(?<text>\S+) vk=0x(?<vk>[0-9A-F]+) mods=0x(?<mods>[0-9A-F]+)$') { throw "Unexpected key check output: $($r.Out)" }
    [pscustomobject]@{ Text = $Matches.text; Vk = [Convert]::ToInt32($Matches.vk, 16); Mods = [Convert]::ToInt32($Matches.mods, 16) }
}

# ------------------------------------------------------------------ the debugger break key
# Windows keeps the debugger break key (HKLM ...\AeDebug UserDebuggerHotKey, absent or 0 = F12) registered all the
# time, so a plain F12 global hotkey fails until it is moved.
$QkAeDebugKey = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\AeDebug'

# The raw UserDebuggerHotKey value, or $null when it is not set.
function Get-QkDebuggerKeyValue {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $k = $base.OpenSubKey($QkAeDebugKey)
        if (-not $k) { return $null }
        try {
            $v = $k.GetValue('UserDebuggerHotKey', $null)
            if ($null -eq $v) { return $null }
            return [int]$v
        }
        finally { $k.Close() }
    }
    finally { $base.Close() }
}

# Sets UserDebuggerHotKey, or removes it when $Value is $null. Needs admin rights; takes effect after a reboot.
function Set-QkDebuggerKeyValue($Value) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $k = $base.CreateSubKey($QkAeDebugKey)
        try {
            if ($null -eq $Value) { $k.DeleteValue('UserDebuggerHotKey', $false) }
            else { $k.SetValue('UserDebuggerHotKey', [int]$Value, [Microsoft.Win32.RegistryValueKind]::DWord) }
        }
        finally { $k.Close() }
    }
    finally { $base.Close() }
}

# The virtual-key code the debugger break key currently uses.
function Get-QkDebuggerBreakVk {
    $v = Get-QkDebuggerKeyValue
    if ($null -eq $v -or $v -eq 0) { return 0x7B }
    return $v
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

# ------------------------------------------------------------------ files and links
function Test-QkPathExists([string]$Path) {
    try { $null = [IO.File]::GetAttributes($Path); $true } catch { $false }   # also true for a dangling link
}

function Test-QkLink([string]$Path) {
    ([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -ne 0
}

# Deletes a symlink or junction itself, never what it points to.
function Remove-QkLink([string]$Path) {
    if ([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::Directory) { [IO.Directory]::Delete($Path) }
    else { [IO.File]::Delete($Path) }
}

# Recursive delete that never follows links. (Windows PowerShell 5.1's Remove-Item -Recurse can walk into a junction
# and delete what it points to.) A hard-linked file only loses this name.
function Remove-QkTreeSafely([string]$Path) {
    $attributes = [IO.File]::GetAttributes($Path)
    if ($attributes -band [IO.FileAttributes]::ReparsePoint) { Remove-QkLink $Path; return }
    if ($attributes -band [IO.FileAttributes]::Directory) {
        foreach ($entry in [IO.Directory]::GetFileSystemEntries($Path)) { Remove-QkTreeSafely $entry }
        [IO.Directory]::Delete($Path)
    }
    else { [IO.File]::Delete($Path) }
}

# The file a path finally names, following symbolic links (dotfiles setups link settings.json elsewhere).
function Resolve-QkFinalPath([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    for ($hop = 0; $hop -lt 16; $hop++) {
        if (-not (Test-QkPathExists $current)) { return $current }
        $item = Get-Item -LiteralPath $current -Force
        if ($item.LinkType -ne 'SymbolicLink') { return $current }
        $target = @($item.Target)[0]
        if (-not $target) { return $current }
        if (-not [IO.Path]::IsPathRooted($target)) { $target = Join-Path (Split-Path $current) $target }
        $current = [IO.Path]::GetFullPath($target)
    }
    throw "Too many symbolic links at $Path."
}

# Replaces a file's contents. Through a symbolic link the link's target is written, and a hard-linked file is
# rewritten in place, so links stay intact; otherwise a temp file next to it replaces it in one step.
function Write-QkFileBytes([string]$Path, [byte[]]$Bytes) {
    $target = Resolve-QkFinalPath $Path
    if ([IO.File]::Exists($target) -and (Get-Item -LiteralPath $target -Force).LinkType -eq 'HardLink') {
        [IO.File]::WriteAllBytes($target, $Bytes)
        return
    }
    $tmp = "$target.quakekey-tmp"
    try {
        [IO.File]::WriteAllBytes($tmp, $Bytes)
        # [NullString]::Value, not $null: PowerShell passes $null to a .NET string parameter as "", and File.Replace
        # rejects an empty backup path (tests: "Write-QkJsonFile over an existing file").
        if ([IO.File]::Exists($target)) { [IO.File]::Replace($tmp, $target, [NullString]::Value) }
        else { [IO.File]::Move($tmp, $target) }
    }
    finally {
        if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) }
    }
}

# Writes UTF-8 without BOM, after checking the text parses back.
function Write-QkJsonFile([string]$Path, $Object) {
    $json = $Object | ConvertTo-Json -Depth 64
    try { $null = ConvertFrom-QkJsonC -Text $json }
    catch { throw "The new $Path would not parse back: $($_.Exception.Message)" }
    Write-QkFileBytes $Path ((New-Object System.Text.UTF8Encoding $false).GetBytes($json))
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
        if ((Get-QkProp $b 'id') -eq $actionId -and @($keys).Count -eq 1) { $hasOurs = $true; continue }
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

# Writes new settings.json content with a backup first, and checks the result kept everything but key bindings.
# Returns the record Restore-QkSettingsBackup needs.
function Save-QkTerminalSettings {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$BackupDir, [Parameter(Mandatory)][string]$ShapeBefore, [string]$Suffix = '')
    New-Item -ItemType Directory -Force $BackupDir | Out-Null
    $backup = Join-Path $BackupDir ('settings-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + $Suffix + '.json')
    [IO.File]::WriteAllBytes($backup, [IO.File]::ReadAllBytes((Resolve-QkFinalPath $Path)))
    Write-QkJsonFile $Path $Settings
    $shapeAfter = Get-QkSettingsShape (Read-QkJsonFile $Path)
    if ($shapeAfter -ne $ShapeBefore) {
        Write-QkFileBytes $Path ([IO.File]::ReadAllBytes($backup))
        throw "Rewriting settings.json would have changed more than its key bindings ($ShapeBefore -> $shapeAfter). The original was put back."
    }
    [pscustomobject]@{ Path = $Path; Backup = $backup; WrittenSha256 = (Get-QkSha256 -Path (Resolve-QkFinalPath $Path)) }
}

# Puts settings.json back from Save-QkTerminalSettings' backup, unless something changed the file since.
function Restore-QkSettingsBackup($Record) {
    if ((Get-QkSha256 -Path (Resolve-QkFinalPath $Record.Path)) -ne $Record.WrittenSha256) {
        return "settings.json changed since the installer wrote it, so it was left as it is; the version before the install is $($Record.Backup)"
    }
    Write-QkFileBytes $Record.Path ([IO.File]::ReadAllBytes($Record.Backup))
    "put settings.json back as it was (backup: $($Record.Backup))"
}

# ------------------------------------------------------------------ install checks
# The newest QuakeKey start in log lines written since $Since: State none | started | ok | failed | stopped.
function Get-QkStartStatus {
    param([AllowEmptyCollection()][string[]]$Lines, [datetime]$Since)
    $state = 'none'; $elevated = $null; $text = $null
    foreach ($line in @($Lines)) {
        if ($null -eq $line -or $line.Length -lt 26) { continue }
        $stamp = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($line.Substring(0, 23), 'yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$stamp)) { continue }
        if ($stamp -lt $Since) { continue }
        $msg = $line.Substring(25)
        if ($msg -match '^started, pid \d+, key \S+, (?<how>.+)$') { $state = 'started'; $elevated = $Matches.how -eq 'elevated'; $text = $msg }
        elseif ($msg -match ' registered$') { $state = 'ok'; $text = $msg }
        elseif ($msg -match ' could not be registered ') { $state = 'failed'; $text = $msg }
        elseif ($msg -match '^(not starting elevated|bad --key|unknown arguments|FATAL|could not open|the single-instance lock|another QuakeKey)') { $state = 'stopped'; $text = $msg }
    }
    [pscustomobject]@{ State = $state; Elevated = $elevated; Text = $text }
}

# ------------------------------------------------------------------ elevated-side helpers (scripts\Elevated.ps1)
if (-not ('QuakeKeyNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class QuakeKeyNative
{
    [StructLayout(LayoutKind.Sequential)]
    struct SECURITY_ATTRIBUTES { public int nLength; public IntPtr lpSecurityDescriptor; public bool bInheritHandle; }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string sddl, uint revision, out IntPtr sd, IntPtr size);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateDirectoryW(string path, ref SECURITY_ATTRIBUTES sa);
    [DllImport("kernel32.dll")]
    static extern IntPtr LocalFree(IntPtr h);

    // Creates a new directory with exactly this security descriptor, in one step; fails if the path exists.
    public static void CreateDirectory(string path, string sddl)
    {
        IntPtr sd;
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, 1, out sd, IntPtr.Zero)) throw new Win32Exception();
        try
        {
            var sa = new SECURITY_ATTRIBUTES { nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES)), lpSecurityDescriptor = sd };
            if (!CreateDirectoryW(path, ref sa)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not create " + path);
        }
        finally { LocalFree(sd); }
    }
}
'@
}

# DACLs of the log folders. Root: SYSTEM and Administrators full control, Users may list it. Per-user folder:
# SYSTEM and Administrators full control, that user read. Protected (P): nothing inherited from ProgramData, where
# every user may create files. $Admin (owner and full control) is BA, Administrators, in real use; the tests pass
# their own SID when they do not run elevated, because only an admin token can act as Administrators.
function New-QkLogSddl {
    param([string]$Admin = 'BA', [string]$ReaderSid, [switch]$Root)
    $read = '0x1200a9'   # FILE_GENERIC_READ | FILE_GENERIC_EXECUTE
    if ($Root) { return "O:${Admin}G:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;$Admin)(A;;$read;;;BU)" }
    "O:${Admin}G:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;$Admin)(A;OICI;$read;;;$ReaderSid)"
}

function Get-QkAclSignature($Security) {
    $owner = $Security.GetOwner([Security.Principal.SecurityIdentifier]).Value
    $rules = @($Security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object {
            '{0}|{1}|{2}|{3}|{4}|{5}' -f $_.IdentityReference.Value, [int]$_.FileSystemRights, [int]$_.InheritanceFlags, [int]$_.PropagationFlags, $_.AccessControlType, $_.IsInherited
        } | Sort-Object)
    "owner=$owner protected=$($Security.AreAccessRulesProtected) " + ($rules -join ';')
}

# True when a directory's owner and DACL are exactly the SDDL's: no extra, missing or inherited entries.
function Test-QkAclMatches([string]$Path, [string]$Sddl) {
    $expected = New-Object System.Security.AccessControl.DirectorySecurity
    $expected.SetSecurityDescriptorSddlForm($Sddl)
    (Get-QkAclSignature (Get-Acl -LiteralPath $Path)) -eq (Get-QkAclSignature $expected)
}

# Prepares %ProgramData%\QuakeKey\<user SID> for the elevated QuakeKey's log. ProgramData lets every user create
# folders, so a root this version did not create (wrong owner or DACL) is moved aside, never re-permissioned: a
# re-ACL keeps entries it does not name and handles opened before it. New folders get their DACL at creation.
# The user's folder is always recreated empty. Returns messages.
function Initialize-QkLogFolders {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Sid, [string]$Admin = 'BA')
    $messages = New-Object System.Collections.Generic.List[string]
    $rootSddl = New-QkLogSddl -Admin $Admin -Root
    $userSddl = New-QkLogSddl -Admin $Admin -ReaderSid $Sid
    if (Test-QkPathExists $Root) {
        if (Test-QkLink $Root) { Remove-QkLink $Root; $messages.Add("removed a link that sat at $Root") }
        elseif (-not [IO.Directory]::Exists($Root)) { [IO.File]::Delete($Root); $messages.Add("removed a file that sat at $Root") }
        elseif (-not (Test-QkAclMatches $Root $rootSddl)) {
            $aside = "$Root.old-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
            try { [IO.Directory]::Move($Root, $aside) }
            catch { throw "$Root has permissions this installer did not set, and it could not be moved aside ($($_.Exception.Message)). Close programs using it, or delete it, and run the installer again." }
            $messages.Add("moved the previous $Root (permissions not set by this version) to $aside")
        }
    }
    if (-not [IO.Directory]::Exists($Root)) { [QuakeKeyNative]::CreateDirectory($Root, $rootSddl) }
    foreach ($entry in [IO.Directory]::GetFileSystemEntries($Root)) {
        # Only per-user folders belong here.
        if ((Test-QkLink $entry) -or -not [IO.Directory]::Exists($entry) -or (Split-Path -Leaf $entry) -notmatch '^S-1-[0-9-]+$') {
            Remove-QkTreeSafely $entry
            $messages.Add("removed $entry")
        }
    }
    $dir = Join-Path $Root $Sid
    if (Test-QkPathExists $dir) { Remove-QkTreeSafely $dir }
    [QuakeKeyNative]::CreateDirectory($dir, $userSddl)
    if (-not (Test-QkAclMatches $Root $rootSddl)) { throw "$Root does not have the expected permissions after setup." }
    if (-not (Test-QkAclMatches $dir $userSddl)) { throw "$dir does not have the expected permissions after setup." }
    , $messages.ToArray()
}

# Copies the built exe into place after checking it is the file install.ps1 built (its SHA-256 was taken before the
# UAC prompt). The bytes are read once, so what is checked is what is written. A running exe (another user's
# QuakeKey) cannot be overwritten but can be renamed, so the old copy is moved aside first.
function Copy-QkVerifiedFile {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination, [Parameter(Mandatory)][string]$Sha256)
    $bytes = [IO.File]::ReadAllBytes($Source)
    $actual = Get-QkSha256 -Bytes $bytes
    if ($actual -ne $Sha256.ToUpperInvariant()) { throw "$Source changed after it was built (SHA-256 $actual, expected $($Sha256.ToUpperInvariant())). Nothing was installed." }
    $dir = Split-Path $Destination
    $leaf = Split-Path -Leaf $Destination
    foreach ($old in [IO.Directory]::GetFiles($dir, "$leaf.old-*")) { try { [IO.File]::Delete($old) } catch { Write-Verbose "$old is still in use; removed by a later install" } }
    if ([IO.File]::Exists($Destination) -and (Get-QkSha256 -Path $Destination) -eq $actual) { return 'unchanged' }
    $new = "$Destination.new"
    if ([IO.File]::Exists($new)) { [IO.File]::Delete($new) }
    [IO.File]::WriteAllBytes($new, $bytes)
    if (-not [IO.File]::Exists($Destination)) { [IO.File]::Move($new, $Destination); return 'installed' }
    $aside = "$Destination.old-" + [DateTime]::UtcNow.Ticks
    [IO.File]::Move($Destination, $aside)
    try { [IO.File]::Move($new, $Destination) }
    catch { [IO.File]::Move($aside, $Destination); throw }
    try { [IO.File]::Delete($aside); return 'replaced' } catch { return 'replaced (the previous copy is still running; it is removed on the next install)' }
}

# Task Scheduler's "restart on failure" only covers a task that fails to launch, not a program that exits with an
# error code or crashes (tests\manual\Prove-RestartOnFailure.ps1). A trigger that repeats every $Interval, with
# MultipleInstances IgnoreNew, restarts QuakeKey instead: while it runs the repeats are ignored, and at most one
# interval after it stops it runs again (tests\manual\Prove-Supervisor.ps1).
function New-QkSupervisorTrigger([TimeSpan]$Interval) {
    New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval $Interval
}

# The three tasks of one user, as Register-ScheduledTask arguments.
function New-QkTaskDefinitions {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [TimeSpan]$SupervisorInterval = (New-TimeSpan -Minutes 5)
    )
    $common = @{ AllowStartIfOnBatteries = $true; DontStopIfGoingOnBatteries = $true; Priority = 4 }   # 4 = normal (default 7 is below normal)
    $hotkeySettings = New-ScheduledTaskSettingsSet @common -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable
    $launchSettings = New-ScheduledTaskSettingsSet @common -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -MultipleInstances Parallel
    $definitions = [ordered]@{}
    $definitions['Hotkey'] = @{
        Action      = New-ScheduledTaskAction -Execute $Exe -Argument ('--key "' + $Key + '"') -WorkingDirectory $WorkingDirectory
        Trigger     = @((New-ScheduledTaskTrigger -AtLogOn -User $User), (New-QkSupervisorTrigger $SupervisorInterval))
        Principal   = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Highest
        Settings    = $hotkeySettings
        Description = "QuakeKey: $Key toggles the Windows Terminal quake window. Runs elevated at logon; the repeating trigger restarts it if it stops (https://github.com/abd3lraouf-studios/QuakeKey)."
    }
    foreach ($which in 'Shown', 'Hidden') {
        $definitions["Start$which"] = @{
            Action      = New-ScheduledTaskAction -Execute $Exe -Argument "--start $($which.ToLowerInvariant())" -WorkingDirectory $WorkingDirectory
            Principal   = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
            Settings    = $launchSettings
            Description = "QuakeKey: starts Windows Terminal ($($which.ToLowerInvariant())) without admin rights."
        }
    }
    $definitions
}

# SIDs of the users with a QuakeKey task folder (\QuakeKey\<SID>\).
function Get-QkInstalledUserSids {
    @(Get-ScheduledTask -TaskPath '\QuakeKey\*' -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.TaskPath -match '^\\QuakeKey\\(S-1-[0-9-]+)\\$') { $Matches[1] }
        } | Sort-Object -Unique)
}

# Runs scripts\Elevated.ps1 elevated (one UAC prompt) and returns its result object.
function Invoke-QkElevated {
    param([Parameter(Mandatory)][ValidateSet('Install', 'Uninstall')][string]$Mode, [hashtable]$Parameters = @{})
    $paths = Get-QkPaths
    New-Item -ItemType Directory -Force $paths.UserDir | Out-Null
    $resultFile = Join-Path $paths.UserDir ('elevated-' + [guid]::NewGuid().ToString('N') + '.json')
    $script = Join-Path $PSScriptRoot 'Elevated.ps1'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-QkArgument $script), '-Mode', $Mode, '-ResultFile', (ConvertTo-QkArgument $resultFile))
    foreach ($k in $Parameters.Keys) {
        $v = $Parameters[$k]
        if ($v -is [bool] -or $v -is [switch]) { if ($v) { $argList += "-$k" } }
        elseif ($null -ne $v) { $argList += "-$k"; $argList += (ConvertTo-QkArgument ([string]$v)) }
    }
    $shell = (Get-Process -Id $PID).Path
    try { $p = Start-Process -FilePath $shell -ArgumentList ($argList -join ' ') -Verb RunAs -WindowStyle Hidden -PassThru -Wait }
    catch { throw "Administrator permission is needed for this step and was not given ($($_.Exception.Message))." }
    if (-not (Test-Path -LiteralPath $resultFile)) { throw "The elevated step exited with code $($p.ExitCode) and left no result." }
    try { $result = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json }
    finally { Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue }
    $result
}
