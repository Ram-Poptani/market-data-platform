# Realistic full-stack traffic generator.
# Hits every service like real users would:
#   - past-data-service: REST candle queries (hot windows + random cold ranges)
#   - live-data:         persistent WebSocket subscribers (clients come and go)
#   - order-book-service: persistent WebSocket subscribers at varying depths
#   - all services:      occasional actuator/health pings (like a load balancer)
#
# Background jobs hold WS connections; the foreground loop drives REST + health checks.

param(
    [int]$DurationMinutes = 15,
    [int]$LiveSubscribers = 3,    # concurrent live-data WS connections
    [int]$BookSubscribers = 3     # concurrent order-book WS connections
)

$ErrorActionPreference = 'SilentlyContinue'
$endAt   = (Get-Date).AddMinutes($DurationMinutes)
$started = Get-Date

# ---------- WS subscriber job ----------
# Opens one persistent WebSocket and drains messages until told to stop.
$wsWorker = {
    param($url, $stopAt)
    try {
        $ws  = [System.Net.WebSockets.ClientWebSocket]::new()
        $cts = [System.Threading.CancellationTokenSource]::new()
        $ws.ConnectAsync([Uri]$url, $cts.Token).Wait()
        $buf = [byte[]]::new(8192)
        $seg = [System.ArraySegment[byte]]::new($buf)
        $msgs = 0
        while ((Get-Date) -lt $stopAt -and $ws.State -eq 'Open') {
            $task = $ws.ReceiveAsync($seg, [Threading.CancellationToken]::None)
            if ($task.Wait(2000)) { $msgs++ }
        }
        try { $ws.CloseAsync('NormalClosure', 'bye', [Threading.CancellationToken]::None).Wait(1000) } catch {}
        return $msgs
    } catch { return -1 }
}

# ---------- Spawn WS subscribers ----------
$jobs = @()
Write-Host "Opening $LiveSubscribers live-data subscribers + $BookSubscribers order-book subscribers..." -ForegroundColor Cyan
$symbolsWs = @('BTCUSDT','ETHUSDT','SOLUSDT')

for ($i = 0; $i -lt $LiveSubscribers; $i++) {
    $sym  = $symbolsWs[$i % $symbolsWs.Length]
    $url  = "ws://localhost:8080/ws/live@$sym"
    $jobs += Start-Job -ScriptBlock $wsWorker -ArgumentList $url, $endAt
}
for ($i = 0; $i -lt $BookSubscribers; $i++) {
    $levels = @(25,100,25)[$i % 3]
    $url    = "ws://localhost:8083/ws/orderbook?levels=$levels"
    $jobs += Start-Job -ScriptBlock $wsWorker -ArgumentList $url, $endAt
}
Start-Sleep -Seconds 2
Write-Host "Active background jobs: $($jobs.Count)" -ForegroundColor DarkGray
Write-Host ""

# ---------- REST traffic configuration ----------
$symbols    = @('BTCUSDT','BTCUSDT','BTCUSDT','ETHUSDT','SOLUSDT')
$ticks      = @('1m','5m','15m','1h','4h','1d')
$hotWindows = @(
    @{ from = '2026-05-29T00:00:00'; to = '2026-05-30T00:00:00' },
    @{ from = '2026-05-28T00:00:00'; to = '2026-05-29T00:00:00' },
    @{ from = '2026-05-22T00:00:00'; to = '2026-05-29T23:59:59' }
)

$healthUrls = @(
    'http://localhost:8080/actuator/health',
    'http://localhost:8081/actuator/health',
    'http://localhost:8082/actuator/health',
    'http://localhost:8083/actuator/health'
)

# ---------- Main loop ----------
Write-Host "Generating REST + health traffic for $DurationMinutes minutes..." -ForegroundColor Cyan
$rest = 0; $hot = 0; $cold = 0; $health = 0; $errors = 0
$nextHealthAt = (Get-Date).AddSeconds(30)

while ((Get-Date) -lt $endAt) {

    $sym  = Get-Random -InputObject $symbols
    $tick = Get-Random -InputObject $ticks
    if ((Get-Random -Min 0 -Max 100) -lt 80) {
        $w = Get-Random -InputObject $hotWindows
        $from = $w.from; $to = $w.to
        $hot++
    } else {
        $day  = Get-Random -Min 1  -Max 28
        $hour = Get-Random -Min 0  -Max 23
        $span = Get-Random -Min 1  -Max 12
        $from = '2026-05-{0:D2}T{1:D2}:00:00' -f $day, $hour
        $endH = [Math]::Min($hour + $span, 23)
        $to   = '2026-05-{0:D2}T{1:D2}:00:00' -f $day, $endH
        $cold++
    }
    try {
        $null = Invoke-WebRequest -Uri "http://localhost:8081/trades/$sym`?from=$from&to=$to&tickSize=$tick" -UseBasicParsing -TimeoutSec 5
        $rest++
    } catch { $errors++ }

    if ((Get-Date) -ge $nextHealthAt) {
        try {
            $null = Invoke-WebRequest -Uri (Get-Random -InputObject $healthUrls) -UseBasicParsing -TimeoutSec 3
            $health++
        } catch { $errors++ }
        $nextHealthAt = (Get-Date).AddSeconds((Get-Random -Min 20 -Max 45))
    }

    $r = Get-Random -Min 0 -Max 100
    if     ($r -lt 60) { Start-Sleep -Milliseconds (Get-Random -Min 100 -Max 600) }
    elseif ($r -lt 90) { Start-Sleep -Milliseconds (Get-Random -Min 800 -Max 2500) }
    else               { Start-Sleep -Seconds (Get-Random -Min 4 -Max 10) }

    if ($rest % 20 -eq 0 -and $rest -gt 0) {
        $mins = ((Get-Date) - $started).TotalMinutes
        $aliveJobs = ($jobs | Where-Object State -eq 'Running').Count
        Write-Host ("[{0,5:F1}m] rest={1} hot={2} cold={3} health={4} ws_jobs={5} errors={6}" -f $mins, $rest, $hot, $cold, $health, $aliveJobs, $errors)
    }
}

# ---------- Teardown ----------
Write-Host ""
Write-Host "Stopping WebSocket subscribers..." -ForegroundColor DarkGray
$wsTotals = @()
foreach ($j in $jobs) {
    $wsTotals += Receive-Job -Job $j -Wait -AutoRemoveJob -ErrorAction SilentlyContinue
}
$wsMsgs = ($wsTotals | Measure-Object -Sum).Sum

Write-Host ""
Write-Host ("Done. REST: {0} (hot={1}, cold={2})  Health: {3}  WS msgs received: {4}  Errors: {5}" -f $rest, $hot, $cold, $health, $wsMsgs, $errors) -ForegroundColor Green
Write-Host "Open http://localhost:3000 -> Market Data Platform -> Last 15 minutes -> screenshot."
