# watch_load.ps1 - log other processes that use CPU during a benchmark, so that a bad run
# can be checked for outside interference instead of guessed at.
#   powershell -File bench/watch_load.ps1 <seconds> <log file> [threshold, % of one core]
param([int]$Seconds = 600, [string]$Log = 'load.log', [int]$Threshold = 100)

# python is ignored because the benchmark scripts themselves use it.
$ignore = 'mmoserver', 'mmoserver_trace', 'mmoserver_sendto', 'loadgen', 'python', 'Idle'
$end = (Get-Date).AddSeconds($Seconds)
Set-Content $Log "started $(Get-Date -Format HH:mm:ss); logging processes above $Threshold% of a core"
while ((Get-Date) -lt $end) {
    $before = @{}
    Get-Process | ForEach-Object { try { $before[$_.Id] = $_.TotalProcessorTime.TotalMilliseconds } catch {} }
    Start-Sleep -Seconds 5
    $busy = Get-Process | ForEach-Object {
        $t = $null
        try { $t = $_.TotalProcessorTime.TotalMilliseconds } catch {}
        if ($t -ne $null -and $before.ContainsKey($_.Id) -and $ignore -notcontains $_.ProcessName) {
            $pct = [math]::Round(($t - $before[$_.Id]) / 50)
            if ($pct -ge $Threshold) { "$($_.ProcessName)=$pct%" }
        }
    }
    if ($busy) { Add-Content $Log "$(Get-Date -Format HH:mm:ss) $($busy -join ' ')" }
}
Add-Content $Log "finished $(Get-Date -Format HH:mm:ss)"
