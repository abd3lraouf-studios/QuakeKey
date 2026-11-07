# Proof: the repeating trigger QuakeKey's Hotkey task uses (New-QkSupervisorTrigger, MultipleInstances IgnoreNew)
# starts the program again after it stops, and never runs a second copy while one is running.
#
# Registers a temporary task for the current user (no admin rights needed) with the same trigger and instance policy
# as the Hotkey task, but a 1-minute interval. Its program records its start, lives 90 s and exits. The task is started
# once by hand at t=0; nothing else starts it. After 200 s: expected 2 runs, the second started by the trigger after
# the first ended, and no overlap. Also checks the task XML repeats indefinitely. Removes the task. About 3.5 minutes.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'scripts\QuakeKey.Common.ps1')
$dir = Join-Path ([IO.Path]::GetTempPath()) ('quakekey-proof-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $dir | Out-Null
$mark = Join-Path $dir 'runs.txt'
$name = 'QuakeKeyProof-Supervisor-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
try {
    $program = "echo start %DATE% %TIME%>>`"$mark`" & ping -n 91 127.0.0.1 >nul & echo end %DATE% %TIME%>>`"$mark`""
    $action = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\cmd.exe" -Argument "/c $program"
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    $trigger = New-QkSupervisorTrigger (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskPath '\' -TaskName $name -Action $action -Settings $settings -Principal $principal -Trigger $trigger | Out-Null

    [xml]$xml = Export-ScheduledTask -TaskPath '\' -TaskName $name
    $rep = $xml.Task.Triggers.TimeTrigger.Repetition
    $indefinite = $rep.Interval -eq 'PT1M' -and -not ($rep.PSObject.Properties['Duration'] -and $rep.Duration)
    Write-Host "trigger XML: interval $($rep.Interval), duration '$(if ($rep.PSObject.Properties['Duration']) { $rep.Duration })' -> indefinite: $indefinite"

    Start-ScheduledTask -TaskPath '\' -TaskName $name
    Write-Host "started by hand at $(Get-Date -Format HH:mm:ss); waiting 200 s"
    Start-Sleep -Seconds 200
    $lines = @(Get-Content -LiteralPath $mark)
    $lines | ForEach-Object { Write-Host "  $_" }
    $starts = @($lines | Where-Object { $_ -like 'start*' }).Count
    # In order, a start must always follow an end (or be the first line): no two copies at once.
    $overlap = $false; $open = $false
    foreach ($l in $lines) { if ($l -like 'start*') { if ($open) { $overlap = $true }; $open = $true } else { $open = $false } }
    Write-Host "starts: $starts   overlap: $overlap"
    if ($indefinite -and $starts -ge 2 -and -not $overlap) { Write-Host 'PROVEN: the trigger restarts the program after it stops, one copy at a time, indefinitely.' -ForegroundColor Green; exit 0 }
    Write-Host 'NOT REPRODUCED: see the lines above.' -ForegroundColor Yellow
    exit 1
}
finally {
    Stop-ScheduledTask -TaskPath '\' -TaskName $name -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskPath '\' -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
