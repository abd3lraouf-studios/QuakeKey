# Proof: Task Scheduler's "If the task fails, restart every ..." does NOT fire when the program exits with an error
# code. QuakeKey 1.0 relied on it (RestartCount 999); 1.1 uses a repeating trigger instead (Prove-Supervisor.ps1).
#
# Registers a temporary task for the current user (no admin rights needed) whose program records each run and exits
# with code 1, allows 3 restarts one minute apart, starts it, waits 200 s and counts the runs. Removes the task.
# Expected: 1 run, LastTaskResult 0x1. Takes about 3.5 minutes.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$dir = Join-Path ([IO.Path]::GetTempPath()) ('quakekey-proof-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $dir | Out-Null
$mark = Join-Path $dir 'runs.txt'
$name = 'QuakeKeyProof-RestartOnFailure-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
try {
    $action = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\cmd.exe" -Argument "/c echo run %TIME%>>`"$mark`" & exit /b 1"
    $settings = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskPath '\' -TaskName $name -Action $action -Settings $settings -Principal $principal | Out-Null
    Start-ScheduledTask -TaskPath '\' -TaskName $name
    Write-Host "started $(Get-Date -Format HH:mm:ss); waiting 200 s (restart interval 1 min, 3 restarts allowed)"
    Start-Sleep -Seconds 200
    $info = Get-ScheduledTaskInfo -TaskPath '\' -TaskName $name
    $runs = @(Get-Content -LiteralPath $mark)
    Write-Host ("runs: {0}   LastTaskResult: 0x{1:X}" -f $runs.Count, $info.LastTaskResult)
    $runs | ForEach-Object { Write-Host "  $_" }
    if ($runs.Count -eq 1 -and $info.LastTaskResult -eq 1) { Write-Host 'PROVEN: a non-zero exit code is not restarted.' -ForegroundColor Green; exit 0 }
    Write-Host 'NOT REPRODUCED: the task was restarted; restart-on-failure behaves differently on this Windows build.' -ForegroundColor Yellow
    exit 1
}
finally {
    Unregister-ScheduledTask -TaskPath '\' -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
