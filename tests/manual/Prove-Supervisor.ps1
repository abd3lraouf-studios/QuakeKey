# Proof: the repeating trigger QuakeKey's Hotkey task uses (New-QkSupervisorTrigger, MultipleInstances IgnoreNew)
# starts the program again after it stops, and never runs a second copy while one is running.
#
# Registers a temporary task for the current user (no admin rights needed) with the same trigger and instance policy
# as the Hotkey task, but a 1-minute interval. Its program records its start and end times and lives 90 s. The task
# is started once by hand at t=0; nothing else starts it. After 200 s, expected: the trigger tick at ~60 s is ignored
# (the first run is still alive), a second run starts after the first ended, and the task XML repeats indefinitely.
# A console window shows while each run lives. Removes the task. About 3.5 minutes.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'scripts\QuakeKey.Common.ps1')
$dir = Join-Path ([IO.Path]::GetTempPath()) ('quakekey-proof-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $dir | Out-Null
$mark = Join-Path $dir 'runs.txt'
$name = 'QuakeKeyProof-Supervisor-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
try {
    # cmd /v:on with !TIME!: %TIME% would be expanded once, when cmd parses the whole line, giving start == end.
    $program = "echo start !TIME!>>`"$mark`" & ping -n 91 127.0.0.1 >nul & echo end !TIME!>>`"$mark`""
    $action = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\cmd.exe" -Argument "/v:on /c $program"
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    $trigger = New-QkSupervisorTrigger (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskPath '\' -TaskName $name -Action $action -Settings $settings -Principal $principal -Trigger $trigger | Out-Null

    [xml]$xml = Export-ScheduledTask -TaskPath '\' -TaskName $name
    $rep = $xml.Task.Triggers.TimeTrigger.Repetition
    $duration = if ($rep.PSObject.Properties['Duration']) { [string]$rep.Duration } else { '' }
    $indefinite = $rep.Interval -eq 'PT1M' -and -not $duration
    Write-Host "trigger XML: interval $($rep.Interval), duration '$duration' -> indefinite: $indefinite"

    Start-ScheduledTask -TaskPath '\' -TaskName $name
    Write-Host "started by hand at $(Get-Date -Format HH:mm:ss.ff); waiting 200 s"
    Start-Sleep -Seconds 200
    $events = @(Get-Content -LiteralPath $mark | ForEach-Object {
            if ($_ -match '^(?<kind>start|end) +(?<time>[0-9: .,]+)$') {
                [pscustomobject]@{ Kind = $Matches.kind; Time = [TimeSpan]::Parse($Matches.time.Trim().Replace(',', '.'), [Globalization.CultureInfo]::InvariantCulture) }
            }
        })
    $events | ForEach-Object { Write-Host ("  {0,-5} {1:hh\:mm\:ss\.ff}" -f $_.Kind, $_.Time) }
    $starts = @($events | Where-Object Kind -eq 'start')
    $ends = @($events | Where-Object Kind -eq 'end')
    # The second run must begin after the first one ended: no two copies at once, and it was the trigger that ran it.
    $restarted = $starts.Count -ge 2 -and $ends.Count -ge 1 -and $starts[1].Time -ge $ends[0].Time
    $firstLived = $ends.Count -ge 1 -and ($ends[0].Time - $starts[0].Time).TotalSeconds -ge 85
    Write-Host "runs started: $($starts.Count)   first run lived $([int]($(if ($ends.Count) { ($ends[0].Time - $starts[0].Time).TotalSeconds } else { 0 }))) s   second started after the first ended: $restarted"
    if ($indefinite -and $firstLived -and $restarted) { Write-Host 'PROVEN: the trigger restarts the program after it stops, one copy at a time, indefinitely.' -ForegroundColor Green; exit 0 }
    Write-Host 'NOT REPRODUCED: see the lines above.' -ForegroundColor Yellow
    exit 1
}
finally {
    Stop-ScheduledTask -TaskPath '\' -TaskName $name -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskPath '\' -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
