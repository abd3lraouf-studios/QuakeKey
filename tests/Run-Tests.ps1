# QuakeKey tests. Builds QuakeKey.exe into tests\out, then checks:
#  * the exe: Win32 constants against the SDK, key parser, --check-settings (the crash guard), the watchdog policy,
#    session-end handling and the Terminal process filter, called through reflection on the built assembly;
#  * scripts\QuakeKey.Common.ps1: the settings.json logic on tests\fixtures, file writes over existing files and
#    links, the verified exe copy, link-safe deletes, the log-folder ACLs, task definitions, install checks;
#  * on GitHub Actions only (elevated, throwaway machine): scripts\Elevated.ps1 install + uninstall for real.
# Installs nothing outside a temp folder anywhere else. Runs in Windows PowerShell 5.1 and PowerShell 7.
# Exit code = number of failed checks. Slow, timing-based proofs live in tests\manual.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
. (Join-Path $root 'scripts\QuakeKey.Common.ps1')
Reset-QkModulePathFor51
$script:failed = 0
$script:passed = 0
$script:skipped = 0

function Assert([bool]$Condition, [string]$What) {
    if ($Condition) { $script:passed++ }
    else { $script:failed++; Write-Host "  FAIL: $What" -ForegroundColor Red }
}

function Skip([string]$What) { $script:skipped++; Write-Host "  SKIP: $What" -ForegroundColor DarkYellow }

# Runs one group of checks; an exception counts as a failure of the group instead of ending the run.
# (Parameter names are unusual on purpose: the body runs in a child scope and would see a $Name of this function
# instead of its caller's.)
function Section([string]$SectionTitle, [scriptblock]$SectionBody) {
    Write-Host $SectionTitle
    try { & $SectionBody }
    catch { $script:failed++; Write-Host "  FAIL: '$SectionTitle' threw: $($_.Exception.Message)`n    $($_.InvocationInfo.PositionMessage)" -ForegroundColor Red }
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
    $tmp = Join-Path $script:work ('settings-' + [guid]::NewGuid().ToString('N') + '.json')
    Write-QkJsonFile $tmp $Settings
    Read-QkJsonFile $tmp
}

function New-TestDir([string]$Name) {
    $d = Join-Path $script:work ($Name + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory $d | Out-Null
    $d
}

# Install, re-install, save, uninstall. $Check sees the install result; -SkipRestoreCheck for fixtures whose undo
# is not expected to give back the original.
function Test-Fixture([string]$Name, [scriptblock]$Check, [switch]$SkipRestoreCheck) {
    Section "settings: $Name" {
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

        # The C# crash guard must accept what the PowerShell installer writes.
        $file = Join-Path $script:work "$Name-installed.json"
        Write-QkJsonFile $file $r.Settings
        $check = Invoke-QkExe -Exe $script:exe -Arguments @('--check-settings', $file)
        Assert ($check.ExitCode -eq 0) "$Name`: QuakeKey.exe --check-settings accepts the installed settings (got exit $($check.ExitCode): $($check.Out)$($check.Err))"

        if (-not $SkipRestoreCheck) {
            $after = Get-Normalized (Undo-QkTerminalBinding -Settings $reloaded -State $state).Settings
            Assert ($after -eq $before) "$Name`: uninstall restores the original`n    before: $before`n    after:  $after"
        }
    }
}

# Calls a non-public static method of the built QuakeKey.exe. Out parameters come back in $Arguments.
function Invoke-QkMethod([string]$Type, [string]$Method, [object[]]$Arguments) {
    $m = $script:asm.GetType($Type, $true).GetMethod($Method, [Reflection.BindingFlags]'NonPublic,Public,Static')
    if (-not $m) { throw "$Type.$Method not found" }
    $m.Invoke($null, $Arguments)
}

$script:work = Join-Path ([IO.Path]::GetTempPath()) ('quakekey-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $script:work | Out-Null
$script:mySid = Get-QkUserSid
$script:elevated = Test-QkElevated

try {
    # ------------------------------------------------------------------ build
    Section 'build' {
        $script:exe = Join-Path $PSScriptRoot 'out\QuakeKey.exe'
        Build-QuakeKey -Source (Join-Path $root 'src\QuakeKey.cs') -OutFile $script:exe
        Assert (Test-Path -LiteralPath $script:exe) 'QuakeKey.exe builds'
        # Loaded from bytes so the file is not locked; works in PowerShell 5.1 (.NET Framework) and 7 (.NET).
        $script:asm = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($script:exe))
        Assert ($null -ne $script:asm.GetType('QuakeKey')) 'the built assembly loads for reflection'
    }

    Section 'sources are ASCII (Windows PowerShell 5.1 reads BOM-less UTF-8 scripts as ANSI)' {
        # (Filtered by extension here: Windows PowerShell 5.1 ignores -Include together with -LiteralPath.)
        $files = @(Get-ChildItem -LiteralPath $root -Recurse -File |
                Where-Object { $_.Extension -in '.ps1', '.cs', '.manifest', '.psd1' -and $_.FullName -notmatch '\\(bin|out|\.git)\\' })
        Assert ($files.Count -ge 6) "found the source files (got $($files.Count))"
        foreach ($f in $files) {
            $bad = @([IO.File]::ReadAllBytes($f.FullName) | Where-Object { $_ -gt 0x7F }).Count
            Assert ($bad -eq 0) "$($f.Name) has $bad non-ASCII bytes"
        }
    }

    # ------------------------------------------------------------------ the exe
    Section 'win32 constants match the Windows SDK' {
        # Values from the Windows SDK headers (WinUser.h, WinBase.h, WinNT.h, dwmapi.h, winerror.h). SWP_* and the
        # HWND_* insert-after values are listed because QuakeKey 1.0 had SWP_NOACTIVATE = 0x0800 (real: 0x0010) and
        # passed (HWND)-1, which is HWND_TOPMOST, while meaning HWND_TOP: tests\manual\Prove-SetWindowPosFlags.ps1.
        $sdk = @{
            WM_NULL = 0x0; WM_QUERYENDSESSION = 0x11; WM_ENDSESSION = 0x16; WM_TIMER = 0x113; WM_HOTKEY = 0x312; WM_CLOSE = 0x10
            PM_REMOVE = 0x1; MOD_ALT = 0x1; MOD_CONTROL = 0x2; MOD_SHIFT = 0x4; MOD_WIN = 0x8; MOD_NOREPEAT = 0x4000
            VK_F12 = 0x7B; VK_F24 = 0x87; SW_SHOW = 5; SW_MINIMIZE = 6; SW_RESTORE = 9; GWL_EXSTYLE = -20; WS_EX_TOOLWINDOW = 0x80
            MONITOR_DEFAULTTONULL = 0; MONITOR_DEFAULTTOPRIMARY = 1; MONITOR_DEFAULTTONEAREST = 2; ASFW_ANY = [int64]4294967295
            SMTO_BLOCK = 0x1; SMTO_ABORTIFHUNG = 0x2; NORMAL_PRIORITY_CLASS = 0x20; CREATE_NO_WINDOW = 0x08000000
            PROCESS_QUERY_LIMITED_INFORMATION = 0x1000; TOKEN_QUERY = 0x8; TokenUser = 1; TokenElevation = 20; DWMWA_CLOAKED = 14
            WAIT_TIMEOUT = 0x102; STILL_ACTIVE = 259; ERROR_HOTKEY_ALREADY_REGISTERED = 1409
            SWP_NOSIZE = 0x1; SWP_NOMOVE = 0x2; SWP_NOZORDER = 0x4; SWP_NOACTIVATE = 0x10; SWP_SHOWWINDOW = 0x40; SWP_ASYNCWINDOWPOS = 0x4000
            HWND_TOP = 0; HWND_BOTTOM = 1; HWND_TOPMOST = -1; HWND_NOTOPMOST = -2; HWND_MESSAGE = -3
        }
        $appConstants = @('HOTKEY_ID', 'PROBE_ID', 'QuakeClass', 'TerminalChord')
        $fields = @($script:asm.GetType('QuakeKey').GetFields([Reflection.BindingFlags]'NonPublic,Public,Static') | Where-Object { $_.IsLiteral })
        Assert ($fields.Count -ge 30) "found QuakeKey's constants (got $($fields.Count))"
        foreach ($f in $fields) {
            if ($appConstants -contains $f.Name) { continue }
            if (-not $sdk.ContainsKey($f.Name)) { Assert $false "constant $($f.Name) is not in this test's SDK table: add its documented value"; continue }
            $value = [int64]$f.GetRawConstantValue()
            Assert ($value -eq [int64]$sdk[$f.Name]) ("{0} = 0x{1:X} but the SDK value is 0x{2:X}" -f $f.Name, $value, [int64]$sdk[$f.Name])
        }
        $source = Get-Content -Raw -LiteralPath (Join-Path $root 'src\QuakeKey.cs')
        Assert ($source -notmatch 'new IntPtr\(-1\)') 'no (HWND)-1 / HWND_TOPMOST in QuakeKey.cs'
    }

    Section 'key parser' {
        $keyCases = @(
            @('F12', 0, 'F12'), @('f1', 0, 'F1'), @('ctrl+alt+t', 0, 'ctrl+alt+T'), @('Win+`', 0, 'win+backtick'), @('shift+F12', 0, 'shift+F12'),
            @('alt+shift+ctrl+q', 0, 'ctrl+alt+shift+Q'), @('ctrl+shift+vk:0xC0', 0, 'ctrl+shift+vk:0xC0'), @('pause', 0, 'pause'), @('scrolllock', 0, 'scrolllock'),
            @('insert', 0, 'insert'), @('alt+numpad5', 0, 'alt+numpad5'), @('win+space', 0, 'win+space'),
            @('A', 2, $null), @('space', 2, $null), @('numpad5', 2, $null), @('vk:0x41', 2, $null), @('ctrl+alt+shift+f24', 2, $null),
            @('ctrl+', 2, $null), @('f25', 2, $null), @('ctrl+a+b', 2, $null), @('ctrl+shift', 2, $null), @('', 2, $null), @('vk:0x100', 2, $null),
            @('f+1', 2, $null), @('f-1', 2, $null)
        )
        foreach ($c in $keyCases) {
            $r = Invoke-QkExe -Exe $script:exe -Arguments @('--validate-key', $c[0])
            if ($c[1] -eq 0) { Assert ($r.ExitCode -eq 0 -and $r.Out -like "$($c[2]) vk=*") "key '$($c[0])' -> '$($c[2])' (got exit $($r.ExitCode): $($r.Out)$($r.Err))" }
            else { Assert ($r.ExitCode -eq 2 -and $r.Err) "key '$($c[0])' is rejected with a reason (got exit $($r.ExitCode): $($r.Out)$($r.Err))" }
        }
        $info = Get-QkKeyInfo -Exe $script:exe -Key 'ctrl+alt+F12'
        Assert ($info.Vk -eq 0x7B -and $info.Mods -eq 3 -and $info.Text -eq 'ctrl+alt+F12') 'Get-QkKeyInfo parses the exe output'
    }

    Section 'crash guard: --check-settings (Terminal crashes on WM_HOTKEY(0) when the chord is not a quake summon)' {
        $cases = @(
            @('bound', 0), @('bound-reordered', 0), @('bound-builtin', 0), @('bound-inline', 0),
            @('in-comment-only', 3), @('in-profile-name-only', 3), @('bound-to-copy', 3), @('bound-other-window', 3), @('unbound-later', 3),
            @('broken', 2)
        )
        foreach ($c in $cases) {
            $file = Join-Path $PSScriptRoot "fixtures\check-settings\$($c[0]).json"
            $r = Invoke-QkExe -Exe $script:exe -Arguments @('--check-settings', $file)
            Assert ($r.ExitCode -eq $c[1]) "$($c[0]): exit $($c[1]) (got $($r.ExitCode): $($r.Out)$($r.Err))"
        }
        $missing = Invoke-QkExe -Exe $script:exe -Arguments @('--check-settings', (Join-Path $script:work 'nope.json'))
        Assert ($missing.ExitCode -eq 2) "a missing file is exit 2 (got $($missing.ExitCode))"
    }

    Section 'JSON-with-comments parser in the exe (JsonC)' {
        $j = Invoke-QkMethod 'JsonC' 'Parse' @("// c`n{ /* b */ `"a`": `"x\\\`"y // z ,}`", `"b`": [1, 2, ], `"c`": { `"d`": null, }, `"e`": `"\u00e9`" }")
        Assert ($j['a'] -eq 'x\"y // z ,}') "strings keep //, escaped quotes and ,} (got '$($j['a'])')"
        Assert ($j['b'].Count -eq 2 -and $null -eq $j['c']['d']) 'trailing commas and null are handled'
        Assert ($j['e'] -eq [string][char]0xE9) '\u escapes are decoded'
        foreach ($bad in '{ "a": 1 } x', '{ /* open', '{ "a" 1 }', '[1,,2]', '"abc') {
            $threw = $false
            try { $null = Invoke-QkMethod 'JsonC' 'Parse' @($bad) } catch { $threw = $true }
            Assert $threw "invalid JSON is rejected: $bad"
        }
        foreach ($k in 'ctrl+alt+shift+f24', 'Shift+Ctrl+Alt+F24', 'win+`', ' alt + f4 ', 'win+shift+a') {
            $cs = Invoke-QkMethod 'Logic' 'NormalizeChord' @($k)
            Assert ($cs -eq (ConvertTo-QkChord $k)) "C# and PowerShell normalize '$k' the same (C# '$cs', PS '$(ConvertTo-QkChord $k)')"
        }
    }

    Section 'watchdog policy (fake clock)' {
        $type = $script:asm.GetType('WatchdogPolicy', $true)
        $decide = $type.GetMethod('Decide', [Reflection.BindingFlags]'NonPublic,Instance')
        $postpone = $type.GetMethod('Postpone', [Reflection.BindingFlags]'NonPublic,Instance')
        $t0 = [datetime]::new(2026, 11, 7, 12, 0, 0)   # a plain DateTime: Get-Date's PSObject wrapper does not cross Invoke()
        # Runs the policy every 3 s like the timer does; returns "second:step" for every non-Wait step.
        function Invoke-Watchdog($Policy, [int]$From, [int]$To, [scriptblock]$Running) {
            $steps = @()
            for ($s = $From; $s -le $To; $s += 3) {
                $step = [string]$decide.Invoke($Policy, @($t0.AddSeconds($s), [bool](& $Running $s)))
                if ($step -ne 'Wait') { $steps += "${s}:$step" }
            }
            , $steps
        }

        # 1.0 logged "waiting 2 minutes" five times and started at 660 s (tests\manual\Prove-WatchdogGrace.ps1).
        $p = [Activator]::CreateInstance($type, $true)
        $steps = Invoke-Watchdog $p 0 900 { param($s) $s -lt 60 }
        Assert (($steps -join ' ') -eq '60:Grace 180:Start 195:Start 225:Start 285:Start 405:Start 645:Start') "a Terminal that exits gets one 2-minute grace, then backoff (got: $($steps -join ' '))"

        $p = [Activator]::CreateInstance($type, $true)
        $steps = Invoke-Watchdog $p 0 800 { $false }
        Assert (($steps -join ' ') -eq '0:Start 15:Start 45:Start 105:Start 225:Start 465:Start 765:Start') "no Terminal at logon: start now, back off 15 s .. 5 min (got: $($steps -join ' '))"

        $p = [Activator]::CreateInstance($type, $true)
        $steps = Invoke-Watchdog $p 0 300 { param($s) $s -lt 9 -or ($s -gt 129 -and $s -lt 240) }   # the start at 129 s comes up
        Assert (($steps -join ' ') -eq '9:Grace 129:Start 240:Grace') "the grace is given again after a Terminal ran again (got: $($steps -join ' '))"

        $p = [Activator]::CreateInstance($type, $true)
        $null = $decide.Invoke($p, @($t0, $false))   # Start at 0; the next would be at 15 s
        $null = $postpone.Invoke($p, @($t0.AddSeconds(60)))   # a key press started Terminal: no other start for 60 s
        $steps = Invoke-Watchdog $p 3 87 { $false }
        Assert (($steps -join ' ') -eq '60:Start') "Postpone holds the next start back (got: $($steps -join ' '))"
    }

    Section 'session end: a cancelled shutdown turns the watchdog back on' {
        $type = $script:asm.GetType('QuakeKey', $true)
        $proc = $type.GetMethod('WindowProc', [Reflection.BindingFlags]'NonPublic,Static')
        $flag = $type.GetField('sessionEnding', [Reflection.BindingFlags]'NonPublic,Static')
        $send = { param([uint32]$Message, [int64]$WParam) $proc.Invoke($null, @([IntPtr]::Zero, $Message, [IntPtr]$WParam, [IntPtr]::Zero)) }
        $answer = & $send 0x11 0
        Assert ([bool]$flag.GetValue($null) -and $answer -eq [IntPtr]1) 'WM_QUERYENDSESSION: watchdog paused, shutdown allowed'
        $null = & $send 0x16 0
        Assert (-not [bool]$flag.GetValue($null)) 'WM_ENDSESSION(FALSE), the shutdown was cancelled: watchdog runs again'
        $null = & $send 0x11 0
        $null = & $send 0x16 1
        Assert ([bool]$flag.GetValue($null)) 'WM_ENDSESSION(TRUE): watchdog stays paused'
    }

    Section 'Terminal process filter and runtime-hook tripwire' {
        $cases = @(
            @('C:\Program Files\WindowsApps\Microsoft.WindowsTerminal_1.24.12741.0_x64__8wekyb3d8bbwe\WindowsTerminal.exe', $true),
            @('C:\Program Files\WindowsApps\Microsoft.WindowsTerminal_1.24.12741.0_arm64__8wekyb3d8bbwe\WindowsTerminal.exe', $true),
            @('C:\Program Files\WindowsApps\Microsoft.WindowsTerminalPreview_1.25.1.0_x64__8wekyb3d8bbwe\WindowsTerminal.exe', $false),
            @('C:\Program Files\WindowsApps\Microsoft.WindowsTerminalCanary_1.26.1.0_x64__8wekyb3d8bbwe\WindowsTerminal.exe', $false),
            @('C:\Tools\terminal-1.24\WindowsTerminal.exe', $false), @('', $false), @($null, $false))
        foreach ($c in $cases) {
            Assert ((Invoke-QkMethod 'Logic' 'IsReleaseTerminalImage' @(, $c[0])) -eq $c[1]) "release Terminal image '$($c[0])' -> $($c[1])"
        }
        $hook = { param($vars) Invoke-QkMethod 'Logic' 'RuntimeHookVariable' @([hashtable]$vars) }
        Assert ((& $hook @{ PATH = 'x'; COR_ENABLE_PROFILING = '1'; COR_PROFILER = '{x}' }) -eq 'COR_ENABLE_PROFILING') 'COR_* variables are refused'
        Assert ((& $hook @{ COMPlus_AltJit = '*' }) -eq 'COMPlus_AltJit') 'COMPlus_* variables are refused'
        Assert ($null -eq (& $hook @{ COR_PROFILER = ''; PATH = 'x' })) 'empty values and other variables are fine'
    }

    # ------------------------------------------------------------------ JSON with comments (PowerShell)
    Section 'jsonc parser (PowerShell)' {
        $j = ConvertFrom-QkJsonC -Text "// c`n{ /* b */ `"a`": `"x\\\`"y // z ,}`", `"b`": [1, 2, ], `"c`": { `"d`": null, }, }"
        Assert ($j.a -eq 'x\"y // z ,}') "strings keep //, escaped quotes and ,} (got '$($j.a)')"
        Assert (@($j.b).Count -eq 2 -and $null -eq $j.c.d) 'trailing commas and null are handled'
        $threw = $false
        try { $null = ConvertFrom-QkJsonC -Text '{ "a": 1 /* open' } catch { $threw = $true }
        Assert $threw 'an unterminated /* comment is an error'
    }

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
        Assert ((Get-QkProp (@($r.Settings.profiles.list)[0]) 'icon') -eq [string]([char]0xD83D) + [char]0xDEE1) 'f12: keeps non-ASCII text'
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

    Test-Fixture 'quakemode-string' {
        param($r)
        Assert ($r.State.originalCommand -eq 'quakeMode') 'quakeMode string: the original string command is recorded for uninstall'
        Assert ((Get-Action $r.Settings 'User.quakeMode').command.action -eq 'globalSummon') 'quakeMode string: becomes a globalSummon of _quake'
    }

    Test-Fixture 'chord-taken' {
        param($r)
        Assert ((Get-Binding $r.Settings 'ctrl+alt+shift+f24').id -eq 'User.quake') 'chord-taken: the chord now belongs to the quake action'
        Assert (@($r.State.removedKeybindings | Where-Object { $_.id -eq 'User.copy' }).Count -eq 1) 'chord-taken: the other binding on the chord is recorded for uninstall'
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

    Section 'settings: refusals and undo edge cases' {
        $threw = $null
        try { $null = Set-QkTerminalBinding -Settings (Get-Fixture 'other-window') } catch { $threw = $_.Exception.Message }
        Assert ($threw -and $threw -match "window 'notes'") "other-window: refuses, naming the conflicting binding (got: $threw)"

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

        # The user bound f12 to something else after the install: uninstall must not take it away.
        $r = Set-QkTerminalBinding -Settings (Get-Fixture 'f12-globalsummon')
        $state = ($r.State | ConvertTo-Json -Depth 32) | ConvertFrom-Json
        $kb = ConvertTo-QkList $r.Settings.keybindings
        $kb.Add([pscustomobject]@{ id = 'User.toggleFocusMode'; keys = 'f12' })
        Set-QkProp $r.Settings 'keybindings' $kb.ToArray()
        $u = Undo-QkTerminalBinding -Settings $r.Settings -State $state
        Assert ((Get-Binding $u.Settings 'f12').id -eq 'User.toggleFocusMode' -and ($u.Changes -match 'kept the current binding for f12')) 'uninstall keeps a binding the user made on the freed key'
    }

    # ------------------------------------------------------------------ writing files
    Section 'Write-QkJsonFile over an existing file (1.0 failed here: File.Replace($tmp, $path, $null))' {
        $d = New-TestDir 'write'
        $f = Join-Path $d 'settings.json'
        Write-QkJsonFile $f ([pscustomobject]@{ a = 1 })
        Assert ((Read-QkJsonFile $f).a -eq 1) 'writes a new file'
        Write-QkJsonFile $f ([pscustomobject]@{ a = 2 })
        Assert ((Read-QkJsonFile $f).a -eq 2) 'replaces an existing file'
        Assert (-not (Test-Path -LiteralPath "$f.quakekey-tmp")) 'leaves no temp file'

        [IO.File]::SetAttributes($f, [IO.FileAttributes]::ReadOnly)
        $threw = $false
        try { Write-QkJsonFile $f ([pscustomobject]@{ a = 3 }) } catch { $threw = $true }
        [IO.File]::SetAttributes($f, [IO.FileAttributes]::Normal)
        Assert ($threw -and (Read-QkJsonFile $f).a -eq 2 -and -not (Test-Path -LiteralPath "$f.quakekey-tmp")) 'a failed write keeps the old file and removes its temp file'
    }

    Section 'settings.json behind links (dotfiles setups)' {
        $d = New-TestDir 'links'
        $real = Join-Path $d 'dotfiles-settings.json'
        Write-QkJsonFile $real ([pscustomobject]@{ v = 1 })
        $hard = Join-Path $d 'settings-hard.json'
        New-Item -ItemType HardLink -Path $hard -Target $real | Out-Null
        Write-QkJsonFile $hard ([pscustomobject]@{ v = 2 })
        Assert ((Read-QkJsonFile $real).v -eq 2 -and (Get-Item -LiteralPath $hard).LinkType -eq 'HardLink') 'a hard-linked settings.json is written in place and stays linked'

        $sym = Join-Path $d 'settings-sym.json'
        $null = & cmd.exe /c mklink "$sym" "$real" 2>&1
        if ($LASTEXITCODE -ne 0) { Skip 'symbolic links cannot be created here (needs Developer Mode or admin)' }
        else {
            Write-QkJsonFile $sym ([pscustomobject]@{ v = 3 })
            Assert ((Get-Item -LiteralPath $sym -Force).LinkType -eq 'SymbolicLink' -and (Read-QkJsonFile $real).v -eq 3) 'a symlinked settings.json stays a link and its target gets the change'
        }
    }

    Section 'settings write: shape guard and rollback' {
        $d = New-TestDir 'save'
        $f = Join-Path $d 'settings.json'
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\fresh.json') -Destination $f
        $original = Get-QkSha256 -Path $f
        $s = Read-QkJsonFile $f
        $threw = $null
        try { $null = Save-QkTerminalSettings -Path $f -Settings $s -BackupDir (Join-Path $d 'backups') -ShapeBefore 'not the real shape' } catch { $threw = $_.Exception.Message }
        Assert ($threw -match 'changed more than its key bindings' -and (Get-QkSha256 -Path $f) -eq $original) 'a write that changes more than key bindings is undone'

        $plan = Set-QkTerminalBinding -Settings (Read-QkJsonFile $f)
        $record = Save-QkTerminalSettings -Path $f -Settings $plan.Settings -BackupDir (Join-Path $d 'backups') -ShapeBefore (Get-QkSettingsShape (Read-QkJsonFile $f))
        Assert ((Get-QkSha256 -Path $f) -ne $original) 'the planned change is written'
        $msg = Restore-QkSettingsBackup $record
        Assert ((Get-QkSha256 -Path $f) -eq $original -and $msg -match 'put settings.json back') 'a failed elevated step puts settings.json back'

        $record = Save-QkTerminalSettings -Path $f -Settings $plan.Settings -BackupDir (Join-Path $d 'backups') -ShapeBefore (Get-QkSettingsShape (Read-QkJsonFile $f))
        Add-Content -LiteralPath $f -Value ' '
        $changed = Get-QkSha256 -Path $f
        $msg = Restore-QkSettingsBackup $record
        Assert ((Get-QkSha256 -Path $f) -eq $changed -and $msg -match 'left it as it is|left as it is') 'a settings.json changed meanwhile (by Terminal) is not overwritten'
    }

    Section 'verified exe copy' {
        $d = New-TestDir 'copy'
        $src = Join-Path $d 'built.exe'
        $dst = Join-Path $d 'installed.exe'
        [IO.File]::WriteAllBytes($src, [byte[]](1, 2, 3))
        $sha = Get-QkSha256 -Path $src
        $threw = $null
        try { $null = Copy-QkVerifiedFile -Source $src -Destination $dst -Sha256 ('00' * 32) } catch { $threw = $_.Exception.Message }
        Assert ($threw -match 'changed after it was built' -and -not (Test-Path -LiteralPath $dst)) 'a file that does not match the hash taken before UAC is not installed'
        Assert ((Copy-QkVerifiedFile -Source $src -Destination $dst -Sha256 $sha) -eq 'installed') 'installs the verified file'
        Assert ((Copy-QkVerifiedFile -Source $src -Destination $dst -Sha256 $sha.ToLowerInvariant()) -eq 'unchanged') 'an identical file is left alone'
        [IO.File]::WriteAllBytes($src, [byte[]](4, 5, 6))
        $sha = Get-QkSha256 -Path $src
        $held = [IO.File]::Open($dst, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'Read, Delete')   # like a running exe
        try { $how = Copy-QkVerifiedFile -Source $src -Destination $dst -Sha256 $sha }
        finally { $held.Close() }
        Assert ($how -like 'replaced*' -and (Get-QkSha256 -Path $dst) -eq $sha) "replaces a copy that is in use (got: $how)"
        $null = Copy-QkVerifiedFile -Source $src -Destination $dst -Sha256 $sha
        $left = @(Get-ChildItem -LiteralPath $d -Force | Where-Object { $_.Name -like 'installed.exe?*' } | ForEach-Object { $_.Name })
        Assert ($left.Count -eq 0) "leftover old copies are cleaned up (left: $($left -join ', '))"
    }

    Section 'link-safe delete' {
        $d = New-TestDir 'tree'
        $outside = New-TestDir 'outside'
        $canary = Join-Path $outside 'canary.txt'
        Set-Content -LiteralPath $canary -Value 'keep me'
        $tree = Join-Path $d 'tree'
        New-Item -ItemType Directory (Join-Path $tree 'sub') | Out-Null
        Set-Content -LiteralPath (Join-Path $tree 'sub\file.txt') -Value 'x'
        New-Item -ItemType Junction -Path (Join-Path $tree 'sub\junction') -Target $outside | Out-Null
        New-Item -ItemType HardLink -Path (Join-Path $tree 'hard.txt') -Target $canary | Out-Null
        Remove-QkTreeSafely $tree
        Assert (-not (Test-Path -LiteralPath $tree)) 'removes the tree'
        Assert ((Test-Path -LiteralPath $canary) -and (Get-Content -LiteralPath $canary) -eq 'keep me') 'never follows a junction or deletes a hard link''s other name'
    }

    Section 'log folders: exact ACLs, created atomically, foreign folders moved aside' {
        $admin = if ($script:elevated) { 'BA' } else { $script:mySid }   # only an admin token can act as Administrators
        $d = New-TestDir 'acl'
        $logRoot = Join-Path $d 'QuakeKey'
        $outside = New-TestDir 'acl-outside'
        $canary = Join-Path $outside 'canary.txt'
        Set-Content -LiteralPath $canary -Value 'keep me'
        # What a normal user can plant in %ProgramData% before the first install.
        New-Item -ItemType Directory $logRoot | Out-Null
        $null = & icacls.exe $logRoot /grant '*S-1-1-0:(OI)(CI)M' /Q
        New-Item -ItemType Junction -Path (Join-Path $logRoot $script:mySid) -Target $outside | Out-Null
        Set-Content -LiteralPath (Join-Path $logRoot 'quakekey.log') -Value 'planted'

        $messages = Initialize-QkLogFolders -Root $logRoot -Sid $script:mySid -Admin $admin
        $userDir = Join-Path $logRoot $script:mySid
        Assert (@($messages | Where-Object { $_ -match 'moved the previous' }).Count -eq 1) "a root with foreign permissions is moved aside (got: $($messages -join '; '))"
        Assert (Test-QkAclMatches $logRoot (New-QkLogSddl -Admin $admin -Root)) 'the new root has exactly SYSTEM/Administrators full, Users list'
        Assert (Test-QkAclMatches $userDir (New-QkLogSddl -Admin $admin -ReaderSid $script:mySid)) 'the user folder has exactly SYSTEM/Administrators full, the user read'
        Assert (-not (Test-QkLink $userDir) -and @(Get-ChildItem -LiteralPath $userDir -Force).Count -eq 0) 'the user folder is a new, empty real folder'
        Assert ((Get-Content -LiteralPath $canary) -eq 'keep me') 'the planted junction''s target is untouched'
        $acl = (Get-Acl -LiteralPath $logRoot).Access | Where-Object { $_.IdentityReference.Value -match 'Everyone' -or $_.IdentityReference.Value -eq 'S-1-1-0' }
        Assert (-not $acl) 'the planted Everyone entry is gone from the folder in use (1.0 kept it: icacls /grant:r only replaces the SIDs it names)'

        # Second install: the root is trusted and kept; other users' folders stay; this user's folder starts empty.
        $other = Join-Path $logRoot 'S-1-5-21-1-2-3-1001'
        [QuakeKeyNative]::CreateDirectory($other, (New-QkLogSddl -Admin $admin -ReaderSid 'S-1-5-21-1-2-3-1001'))
        Set-Content -LiteralPath (Join-Path $userDir 'quakekey.log') -Value 'old'
        $messages = Initialize-QkLogFolders -Root $logRoot -Sid $script:mySid -Admin $admin
        Assert (@($messages | Where-Object { $_ -match 'moved the previous' }).Count -eq 0) 'a root this version created is kept'
        Assert ((Test-Path -LiteralPath $other) -and @(Get-ChildItem -LiteralPath $userDir -Force).Count -eq 0) 'other users'' folders stay; this user''s starts empty'
    }

    # ------------------------------------------------------------------ install checks
    Section 'scheduled task definitions' {
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $defs = New-QkTaskDefinitions -Exe 'C:\Program Files\QuakeKey\QuakeKey.exe' -Key 'F12' -User $user -WorkingDirectory 'C:\Program Files\QuakeKey'
        Assert ((@($defs.Keys) -join ',') -eq 'Hotkey,StartShown,StartHidden') 'three tasks'
        $h = $defs['Hotkey']
        Assert ($h.Principal.RunLevel -eq 'Highest' -and $h.Principal.LogonType -eq 'Interactive') 'Hotkey runs elevated in the user''s session'
        Assert ($h.Settings.MultipleInstances -eq 'IgnoreNew' -and $h.Settings.ExecutionTimeLimit -eq 'PT0S') 'Hotkey: one instance, no time limit'
        Assert ($h.Settings.RestartCount -eq 0) 'Hotkey does not rely on restart-on-failure (it never fires on an exit code)'
        $triggers = @($h.Trigger)
        Assert ($triggers.Count -eq 2) 'Hotkey has a logon trigger and a supervisor trigger'
        $rep = $triggers[1].Repetition
        Assert ($rep.Interval -eq 'PT5M' -and -not $rep.Duration) "the supervisor repeats every 5 minutes, indefinitely (got interval '$($rep.Interval)', duration '$($rep.Duration)')"
        foreach ($n in 'StartShown', 'StartHidden') {
            Assert ($defs[$n].Principal.RunLevel -eq 'Limited' -and -not $defs[$n].ContainsKey('Trigger')) "$n runs on demand, without admin rights"
        }
        $p = Get-QkPaths -Sid 'S-1-5-21-1-2-3-1001'
        Assert ($p.TaskFolder -eq '\QuakeKey\S-1-5-21-1-2-3-1001\' -and $p.LogDir -like '*\QuakeKey\S-1-5-21-1-2-3-1001') 'tasks and logs are per user'
    }

    Section 'install prerequisites' {
        $good = @{ UacEnabled = $true; Integrity = 'Medium'; InAdministrators = $true; BuiltinAdministrator = $false; BuiltinAdminApprovalMode = $false; WtAlias = $true }
        function Get-Problems([hashtable]$Change) { $f = $good.Clone(); foreach ($k in $Change.Keys) { $f[$k] = $Change[$k] }; Test-QkPrerequisites ([pscustomobject]$f) }
        Assert (@(Get-Problems @{}).Count -eq 0) 'an admin account with UAC passes'
        Assert ((@(Get-Problems @{ UacEnabled = $false }) -match 'UAC is turned off').Count -eq 1) 'UAC off is refused'
        Assert ((@(Get-Problems @{ InAdministrators = $false }) -match 'not an administrator').Count -eq 1) 'a standard account is refused'
        Assert ((@(Get-Problems @{ BuiltinAdministrator = $true }) -match 'built-in Administrator').Count -eq 1) 'the built-in Administrator is refused'
        Assert (@(Get-Problems @{ BuiltinAdministrator = $true; BuiltinAdminApprovalMode = $true }).Count -eq 0) 'the built-in Administrator with Admin Approval Mode passes'
        Assert ((@(Get-Problems @{ WtAlias = $false }) -match 'alias').Count -eq 1) 'a disabled wt.exe alias is refused'
        $facts = Get-QkAccountFacts
        Assert ($facts.Integrity -in 'Medium', 'High' -and $facts.UacEnabled -is [bool] -and $facts.InAdministrators -is [bool]) 'Get-QkAccountFacts reads this machine'
    }

    Section 'install log check' {
        $since = Get-Date '2026-11-07 12:00:00'
        $lines = @(
            '2026-11-07 11:59:00.000  F12 registered',
            '2026-11-07 12:00:01.000  started, pid 1, key F12, elevated',
            '2026-11-07 12:00:01.010  F12 could not be registered (error 1409): another program holds it; retrying every second')
        Assert ((Get-QkStartStatus -Lines $lines -Since $since).State -eq 'failed') 'a fresh failure counts; older lines do not'
        $lines += '2026-11-07 12:00:02.020  F12 registered'
        $s = Get-QkStartStatus -Lines $lines -Since $since
        Assert ($s.State -eq 'ok' -and $s.Elevated) 'a first 1409 followed by "registered" is a success (1.0 reported the 1409)'
        $s = Get-QkStartStatus -Lines @('2026-11-07 12:00:01.000  started, pid 1, key F12, NOT elevated: the key will not arrive while an admin window has focus', '2026-11-07 12:00:01.010  F12 registered') -Since $since
        Assert ($s.State -eq 'ok' -and $s.Elevated -eq $false) 'a start without admin rights is noticed'
        Assert ((Get-QkStartStatus -Lines @('2026-11-07 12:00:01.000  not starting elevated: the environment variable COR_PROFILER is set.') -Since $since).State -eq 'stopped') 'a refusal to start is reported'
        Assert ((Get-QkStartStatus -Lines @() -Since $since).State -eq 'none') 'no lines: no status'
    }

    Section 'README quotes real log lines' {
        $source = Get-Content -Raw -LiteralPath (Join-Path $root 'src\QuakeKey.cs')
        $readme = Get-Content -LiteralPath (Join-Path $root 'README.md')
        $start = [array]::IndexOf($readme, '## Troubleshooting')
        $rows = @($readme[$start..($readme.Count - 1)] | Where-Object { $_ -match '^\| `([^`]+)`' } | ForEach-Object { $Matches[1] })
        Assert ($rows.Count -ge 6) "found the troubleshooting table (got $($rows.Count) rows)"
        foreach ($row in $rows) {
            foreach ($piece in ($row -replace '^F12\b', '' -split '\.\.\.')) {
                $text = ($piece -replace '\(error \d+\)', '').Trim()
                if ($text) { Assert ($source.Contains($text)) "README log text '$text' appears in QuakeKey.cs" }
            }
        }
    }

    # ------------------------------------------------------------------ elevated half, for real (CI only)
    Section 'Elevated.ps1 install + uninstall (GitHub Actions only)' {
        if ($env:GITHUB_ACTIONS -ne 'true' -or -not $script:elevated) {
            Skip 'runs only on an elevated GitHub Actions runner: it installs into Program Files and Task Scheduler'
            return
        }
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $paths = Get-QkPaths
        $shell = (Get-Process -Id $PID).Path
        $elevatedScript = Join-Path $root 'scripts\Elevated.ps1'
        function Invoke-Elevated([string[]]$Arguments) {
            $result = Join-Path $script:work ('result-' + [guid]::NewGuid().ToString('N') + '.json')
            & $shell -NoProfile -ExecutionPolicy Bypass -File $elevatedScript -ResultFile $result @Arguments | Out-Null
            Get-Content -LiteralPath $result -Raw | ConvertFrom-Json
        }
        $sha = Get-QkSha256 -Path $script:exe

        $r = Invoke-Elevated @('-Mode', 'Install', '-User', $user, '-Source', $script:exe, '-SourceSha256', ('0' * 64), '-Key', 'ctrl+alt+F11')
        Assert (-not $r.ok -and ($r.messages -match 'changed after it was built')) "a wrong hash stops the install (got: $($r.messages -join '; '))"

        $r = Invoke-Elevated @('-Mode', 'Install', '-User', $user, '-Source', $script:exe, '-SourceSha256', $sha, '-Key', 'ctrl+alt+F11')
        Assert $r.ok "install succeeds (got: $($r.messages -join '; '))"
        $tasks = @(Get-ScheduledTask -TaskPath $paths.TaskFolder -ErrorAction SilentlyContinue)
        Assert ((@($tasks.TaskName | Sort-Object) -join ',') -eq 'Hotkey,StartHidden,StartShown') "the user's three tasks exist (got: $(@($tasks.TaskName) -join ','))"
        $hotkey = $tasks | Where-Object TaskName -eq 'Hotkey'
        Assert (@($hotkey.Triggers).Count -eq 2 -and $hotkey.Principal.RunLevel -eq 'Highest') 'Hotkey: elevated, logon + supervisor triggers'
        Assert ((Get-QkSha256 -Path (Join-Path $paths.InstallDir 'QuakeKey.exe')) -eq $sha) 'the installed exe is the built one'
        Assert (Test-QkAclMatches $paths.LogRoot (New-QkLogSddl -Owner 'BA' -Root)) 'ProgramData\QuakeKey has the exact ACL'
        Assert (Test-QkAclMatches $paths.LogDir (New-QkLogSddl -Owner 'BA' -ReaderSid $script:mySid)) 'the user log folder has the exact ACL'

        $r = Invoke-Elevated @('-Mode', 'Uninstall', '-User', $user)
        Assert $r.ok "uninstall succeeds (got: $($r.messages -join '; '))"
        Assert (@(Get-ScheduledTask -TaskPath '\QuakeKey\*' -ErrorAction SilentlyContinue).Count -eq 0) 'no QuakeKey tasks are left'
        Assert (-not (Test-Path -LiteralPath $paths.InstallDir) -and -not (Test-Path -LiteralPath $paths.LogRoot)) 'Program Files\QuakeKey and ProgramData\QuakeKey are gone'
    }
}
finally {
    try { Remove-QkTreeSafely $script:work } catch { Write-Host "  (could not remove $($script:work): $($_.Exception.Message))" -ForegroundColor DarkYellow }
}

Write-Host ''
$color = if ($script:failed) { 'Red' } else { 'Green' }
Write-Host ("{0} passed, {1} failed, {2} skipped (PowerShell {3})" -f $script:passed, $script:failed, $script:skipped, $PSVersionTable.PSVersion) -ForegroundColor $color
exit $script:failed
