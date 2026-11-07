# QuakeKey tests. Installs nothing: builds QuakeKey.exe into tests\out, checks its key parser, and runs the Windows
# Terminal settings logic (scripts\QuakeKey.Common.ps1) on the files in tests\fixtures.
# Runs in Windows PowerShell 5.1 and PowerShell 7. Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
. (Join-Path $root 'scripts\QuakeKey.Common.ps1')
Reset-QkModulePathFor51
$script:failed = 0
$script:passed = 0

function Assert([bool]$Condition, [string]$What) {
    if ($Condition) { $script:passed++ }
    else { $script:failed++; Write-Host "  FAIL: $What" -ForegroundColor Red }
}

function Get-Fixture([string]$Name) { Read-QkJsonFile (Join-Path $PSScriptRoot "fixtures\$Name.json") }

# Canonical JSON for comparisons: empty actions/keybindings dropped, keybindings in a fixed order.
function Get-Normalized($Settings) {
    $copy = ($Settings | ConvertTo-Json -Depth 64) | ConvertFrom-Json
    foreach ($p in 'actions', 'keybindings') { if ((ConvertTo-QkList (Get-QkProp $copy $p)).Count -eq 0) { Remove-QkProp $copy $p } }
    $kb = Get-QkProp $copy 'keybindings'
    if ($kb) { Set-QkProp $copy 'keybindings' @(@($kb) | Sort-Object { "$(Get-QkProp $_ 'id')|$(@(Get-QkProp $_ 'keys') -join ',')" }) }
    $copy | ConvertTo-Json -Depth 64 -Compress
}

function Get-Action($Settings, [string]$Id) { (ConvertTo-QkList (Get-QkProp $Settings 'actions')) | Where-Object { (Get-QkProp $_ 'id') -eq $Id } | Select-Object -First 1 }

function Get-Binding($Settings, [string]$Keys) {
    (ConvertTo-QkList (Get-QkProp $Settings 'keybindings')) | Where-Object { @(Get-QkKeyList (Get-QkProp $_ 'keys')) -contains $Keys } | Select-Object -First 1
}

function Save-AndReload($Settings) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('quakekey-test-' + [guid]::NewGuid().ToString('N') + '.json')
    try { Write-QkJsonFile $tmp $Settings; Read-QkJsonFile $tmp } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

# Install, re-install, save, uninstall. $Check sees the install result; -SkipRestoreCheck for fixtures whose undo
# is not expected to give back the original.
function Test-Fixture([string]$Name, [scriptblock]$Check, [switch]$SkipRestoreCheck) {
    Write-Host "settings: $Name"
    $before = Get-Normalized (Get-Fixture $Name)
    $r = Set-QkTerminalBinding -Settings (Get-Fixture $Name)
    & $Check $r

    $summons = Get-QkSummonBindings $r.Settings
    Assert ($summons.Count -eq 1 -and $summons[0].Kind -eq 'keybinding' -and $summons[0].Chord -eq $QkTerminalChord -and $summons[0].Target -eq '_quake') `
        "$Name`: exactly one global summon, on $QkTerminalChord, for _quake (got: $(($summons | ForEach-Object { "$($_.Kind) $($_.Keys) -> '$($_.Target)'" }) -join '; '))"

    $state = ($r.State | ConvertTo-Json -Depth 32) | ConvertFrom-Json   # as saved to terminal-state.json
    $again = Set-QkTerminalBinding -Settings $r.Settings -PreviousState $state
    Assert ($again.Changes.Count -eq 0) "$Name`: running the install again changes nothing (got: $($again.Changes -join '; '))"

    $reloaded = Save-AndReload $r.Settings
    Assert ((Get-Normalized $reloaded) -eq (Get-Normalized $r.Settings)) "$Name`: the written settings.json reads back the same"

    if (-not $SkipRestoreCheck) {
        $after = Get-Normalized (Undo-QkTerminalBinding -Settings $reloaded -State $state).Settings
        Assert ($after -eq $before) "$Name`: uninstall restores the original`n    before: $before`n    after:  $after"
    }
}

# ------------------------------------------------------------------ build + key parser
Write-Host 'build'
$exe = Join-Path $PSScriptRoot 'out\QuakeKey.exe'
Build-QuakeKey -Source (Join-Path $root 'src\QuakeKey.cs') -OutFile $exe
Assert (Test-Path $exe) 'QuakeKey.exe builds'

Write-Host 'key parser'
$keyCases = @(
    @('F12', 0, 'F12'), @('f1', 0, 'F1'), @('ctrl+alt+t', 0, 'ctrl+alt+T'), @('Win+`', 0, 'win+backtick'), @('shift+F12', 0, 'shift+F12'),
    @('alt+shift+ctrl+q', 0, 'ctrl+alt+shift+Q'), @('ctrl+shift+vk:0xC0', 0, 'ctrl+shift+vk:0xC0'), @('pause', 0, 'pause'), @('scrolllock', 0, 'scrolllock'),
    @('insert', 0, 'insert'), @('alt+numpad5', 0, 'alt+numpad5'), @('win+space', 0, 'win+space'),
    @('A', 2, $null), @('space', 2, $null), @('numpad5', 2, $null), @('vk:0x41', 2, $null), @('ctrl+alt+shift+f24', 2, $null),
    @('ctrl+', 2, $null), @('f25', 2, $null), @('ctrl+a+b', 2, $null), @('ctrl+shift', 2, $null), @('', 2, $null), @('vk:0x100', 2, $null)
)
foreach ($c in $keyCases) {
    $r = Invoke-QkExe -Exe $exe -Arguments @('--validate-key', $c[0])
    if ($c[1] -eq 0) { Assert ($r.ExitCode -eq 0 -and $r.Out -like "$($c[2]) vk=*") "key '$($c[0])' -> '$($c[2])' (got exit $($r.ExitCode): $($r.Out)$($r.Err))" }
    else { Assert ($r.ExitCode -eq 2 -and $r.Err) "key '$($c[0])' is rejected with a reason (got exit $($r.ExitCode): $($r.Out)$($r.Err))" }
}
$info = Get-QkKeyInfo -Exe $exe -Key 'ctrl+alt+F12'
Assert ($info.Vk -eq 0x7B -and $info.Mods -eq 3 -and $info.Text -eq 'ctrl+alt+F12') 'Get-QkKeyInfo parses the exe output'

# ------------------------------------------------------------------ JSON with comments
Write-Host 'jsonc parser'
$j = ConvertFrom-QkJsonC -Text "// c`n{ /* b */ `"a`": `"x\\\`"y // z ,}`", `"b`": [1, 2, ], `"c`": { `"d`": null, }, }"
Assert ($j.a -eq 'x\"y // z ,}') "strings keep //, escaped quotes and ,} (got '$($j.a)')"
Assert (@($j.b).Count -eq 2 -and $null -eq $j.c.d) 'trailing commas and null are handled'

# ------------------------------------------------------------------ settings fixtures
Test-Fixture 'fresh' {
    param($r)
    $a = Get-Action $r.Settings 'QuakeKey.Toggle'
    Assert ([bool]$a -and $r.State.createdAction) 'fresh: creates QuakeKey.Toggle'
    Assert ($a.command.action -eq 'globalSummon' -and $a.command.name -eq '_quake' -and $a.command.monitor -eq 'any' -and $a.command.dropdownDuration -eq 200) 'fresh: the new action is globalSummon _quake, monitor any, 200 ms'
    Assert ($r.State.addedWinUnbind -and (Get-Binding $r.Settings 'win+sc(41)') -and $null -eq (Get-Binding $r.Settings 'win+sc(41)').id) 'fresh: switches off the default Win+` binding'
    Assert ((Get-Binding $r.Settings 'ctrl+c').id -eq 'User.copy.644BA8F2') 'fresh: leaves other bindings alone'
}

Test-Fixture 'f12-globalsummon' {
    param($r)
    Assert ($r.State.actionId -eq 'User.globalSummon' -and -not $r.State.createdAction) 'f12: reuses the existing User.globalSummon action'
    Assert (-not (Get-Binding $r.Settings 'f12')) 'f12: Terminal no longer binds f12'
    Assert (@($r.State.removedKeybindings | Where-Object { $_.keys -eq 'f12' }).Count -eq 1) 'f12: records the f12 binding for uninstall'
    Assert ((Get-Binding $r.Settings 'shift+f12').id -eq 'User.toggleFocusMode') 'f12: keeps shift+f12 (not a global summon)'
    Assert ((Get-QkProp (@($r.Settings.profiles.list)[0]) 'icon') -eq [char]0xD83D + [char]0xDEE1) 'f12: keeps non-ASCII text'
}

Test-Fixture 'legacy-inline' {
    param($r)
    $a = Get-Action $r.Settings 'QuakeKey.Toggle'
    Assert ([bool]$a -and -not (Get-QkProp $a 'keys')) 'legacy: the inline quake action gets an id and loses its inline key'
    Assert ($a.command.dropdownDuration -eq 150) 'legacy: keeps the user''s dropdownDuration when not given'
    $copy = @($r.Settings.actions) | Where-Object { $_.command -eq 'copy' }
    Assert ($copy.keys -eq 'ctrl+c') 'legacy: other inline keys stay'
}

Test-Fixture 'quakemode-builtin' {
    param($r)
    Assert ($r.State.createdAction -and (Get-Action $r.Settings 'QuakeKey.Toggle')) 'builtin: creates QuakeKey.Toggle (built-in actions cannot take options)'
    Assert (-not (Get-Binding $r.Settings 'f12')) 'builtin: removes f12 -> Terminal.QuakeMode'
}

Test-Fixture 'jsonc' {
    param($r)
    $p = @($r.Settings.profiles.list)[0]
    Assert ($p.name -eq 'Odd // not a comment, and ,} not a trailing comma' -and $p.commandline -eq 'cmd.exe /k echo "//" /*x*/') 'jsonc: string contents survive'
    Assert ($r.State.actionId -eq 'User.quake') 'jsonc: reuses User.quake'
}

Test-Fixture 'keys-array' {
    param($r)
    $removed = @($r.State.removedKeybindings)[0]
    Assert (@($removed.keys).Count -eq 2) 'keys-array: records both keys of the removed binding'
}

Test-Fixture 'already-configured' {
    param($r)
    Assert ($r.Changes.Count -eq 0) "configured: no changes (got: $($r.Changes -join '; '))"
} -SkipRestoreCheck

Write-Host 'settings: other-window'
$threw = $null
try { $null = Set-QkTerminalBinding -Settings (Get-Fixture 'other-window') } catch { $threw = $_.Exception.Message }
Assert ($threw -and $threw -match "window 'notes'") "other-window: refuses, naming the conflicting binding (got: $threw)"

Write-Host 'settings: explicit options and undo without a record'
$r = Set-QkTerminalBinding -Settings (Get-Fixture 'f12-globalsummon') -Monitor toMouse -Animation 0 -SetMonitor -SetAnimation
$a = Get-Action $r.Settings 'User.globalSummon'
Assert ($a.command.monitor -eq 'toMouse' -and $a.command.dropdownDuration -eq 0) 'explicit -Monitor/-Animation are applied to an existing action'
$u = Undo-QkTerminalBinding -Settings $r.Settings -State (($r.State | ConvertTo-Json -Depth 32) | ConvertFrom-Json)
$a = Get-Action $u.Settings 'User.globalSummon'
Assert (-not (Get-QkProp $a.command 'monitor') -and -not (Get-QkProp $a.command 'dropdownDuration')) 'uninstall restores the original command'

$r = Set-QkTerminalBinding -Settings (Get-Fixture 'fresh')
$u = Undo-QkTerminalBinding -Settings $r.Settings -State $null
Assert (-not (Get-Action $u.Settings 'QuakeKey.Toggle') -and -not (Get-Binding $u.Settings $QkTerminalChord)) 'without a record, uninstall removes QuakeKey.Toggle and its binding'

$r = Set-QkTerminalBinding -Settings (Get-Fixture 'already-configured')
$u = Undo-QkTerminalBinding -Settings $r.Settings -State (($r.State | ConvertTo-Json -Depth 32) | ConvertFrom-Json)
Assert (-not (Get-Binding $u.Settings $QkTerminalChord) -and (Get-Action $u.Settings 'User.globalSummon')) 'configured by hand: uninstall removes the chord binding, keeps the action'

Write-Host ''
$color = if ($script:failed) { 'Red' } else { 'Green' }
Write-Host ("{0} passed, {1} failed (PowerShell {2})" -f $script:passed, $script:failed, $PSVersionTable.PSVersion) -ForegroundColor $color
exit $script:failed
