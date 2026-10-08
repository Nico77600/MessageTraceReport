<#
    Message Trace Report - collection.

    Invoke-MtrCollection runs the work items in the engine (Collector) and, while it runs, every 250 ms:
      - renews the access token when needed (Update-MtrToken),
      - prints the events of the engine (429, retries, failed windows),
      - rewrites the live progress line (share done, requests, rows, quota, time left).
    Ctrl+C stops the requests; what was already received stays in the database (coverage page by page),
    and the next run collects only the rest.

    Invoke-MtrDetails does the same for the route of a few deliveries (getDetailsByRecipient).
#>

function New-MtrCollectorOptions {
    param([Parameter(Mandatory)]$Settings)
    $o = [MessageTraceReport.CollectorOptions]::new()
    $o.GraphRoot = $script:GraphRoot
    $o.PageSize = $Settings.Collection.PageSize
    $o.MaxConcurrency = $Settings.Collection.MaxConcurrency
    $o.MaxRetries = $Settings.Collection.MaxRetries
    $o.TimeoutSeconds = $Settings.Collection.RequestTimeoutSeconds
    $o.UserAgent = "MessageTraceReport/$($script:ToolVersion)"
    return $o
}

function Write-MtrEngineEvents {
    <# Prints the events queued by the engine. Identical messages within 15 seconds are printed once. #>
    param([Parameter(Mandatory)]$Queue, [hashtable]$Seen = @{})
    $event = $null
    while ($Queue.TryDequeue([ref]$event)) {
        $key = $event.Text -replace '\d+', '#'
        $now = [Environment]::TickCount64
        if ($Seen.ContainsKey($key) -and $now - $Seen[$key] -lt 15000) { Write-MtrLog $(if ($event.Level -eq 'ERROR') { 'ERROR' } else { 'WARN' }) $event.Text; continue }
        $Seen[$key] = $now
        $status = switch ($event.Level) { 'ERROR' { 'Fail' } 'WARN' { 'Warn' } default { 'Info' } }
        Write-MtrItem $status $event.Text
    }
}

function Invoke-MtrCollection {
    <#
    .SYNOPSIS
        Collects the work items of a plan into the database. Returns the counters of the run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Store, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][MessageTraceReport.WorkPlan]$WorkPlan, [Parameter(Mandatory)][long]$RunId,
        [MessageTraceReport.CollectorOptions]$Options
    )
    $items = [Collections.Generic.List[MessageTraceReport.WorkItem]]::new()
    foreach ($i in $WorkPlan.Items) { $items.Add($i) }
    $slot = [MessageTraceReport.TokenSlot]::new()
    $slot.Set($Connection.Token, $Connection.ExpiresMs)
    $th = $Settings.Throttling
    $limiter = [MessageTraceReport.RateLimiter]::new($th.MaxRequests, [long]$th.PeriodSeconds * 1000, $Store.GetRequestStamps('graph_requests'))
    if ($limiter.InWindow -gt 0) { Write-MtrItem Info ("{0} request(s) of the last {1} min already counted (previous run): the quota is shared by the tenant." -f $limiter.InWindow, [int]($th.PeriodSeconds / 60)) -Icon Clock }
    if (-not $Options) { $Options = New-MtrCollectorOptions $Settings }
    $collector = [MessageTraceReport.Collector]::new($Store, $Options, $slot, $limiter, $RunId)
    $cts = [Threading.CancellationTokenSource]::new()
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $seen = @{}
    $lastLog = 0; $lastDraw = 0; $tokenWarned = $false
    $task = $collector.RunAsync($items, $cts.Token)
    try {
        while (-not $task.IsCompleted) {
            try { [void](Update-MtrToken -Connection $Connection -Slot $slot -Settings $Settings) }
            catch { if (-not $tokenWarned) { Write-MtrItem Warn "Access token not renewed: $($_.Exception.Message)"; $tokenWarned = $true } }
            Write-MtrEngineEvents $collector.Events $seen
            $elapsed = $clock.Elapsed.TotalSeconds
            if ($elapsed - $lastDraw -ge 0.5) {
                $lastDraw = $elapsed
                $progress = $collector.Progress
                $parts = [Collections.Generic.List[string]]::new()
                $parts.Add(('{0}/{1} windows' -f $collector.ItemsDone, $items.Count))
                $parts.Add(('{0} requests' -f (Format-MtrNumber $collector.Requests)))
                $parts.Add(('{0} rows' -f (Format-MtrNumber $collector.Rows)))
                $parts.Add(('quota {0}/{1}' -f $limiter.InWindow, $limiter.MaxRequests))
                $delay = $limiter.DelayMs()
                if ($limiter.PausedUntil -gt [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) { $parts.Add(('paused {0} s (429)' -f [int][Math]::Ceiling($delay / 1000))) }
                elseif ($delay -gt 1500 -and $collector.ItemsRunning -gt 0) { $parts.Add(('waiting for the quota {0} s' -f [int][Math]::Ceiling($delay / 1000))) }
                if ($progress -gt 0.02 -and $elapsed -gt 5) { $parts.Add(('~{0} left' -f (Format-MtrDuration ($elapsed / $progress * (1 - $progress))))) }
                Write-MtrProgress -Fraction $progress -Text ($parts -join " $($script:Dot) ")
            }
            if ($elapsed - $lastLog -ge 60) {
                $lastLog = $elapsed
                Write-MtrLog 'INFO' ("Progress {0:P0}: {1}/{2} windows, {3} requests, {4} rows, {5} new deliveries, {6} throttled" -f $collector.Progress, $collector.ItemsDone, $items.Count, $collector.Requests, $collector.Rows, $collector.NewDeliveries, $collector.Throttled)
            }
            [void]$task.Wait(250)
        }
    }
    finally {
        if (-not $task.IsCompleted) {
            # Ctrl+C: stop the requests, let the writer store what was received.
            Clear-MtrProgress
            Write-Host '      Stopping: the pages already received are being saved...'
            $cts.Cancel()
            try { [void]$task.Wait(120000) } catch { }
            Write-MtrLog 'WARN' 'Collection interrupted by the user (Ctrl+C).'
        }
        Clear-MtrProgress
        Write-MtrEngineEvents $collector.Events $seen
        try { $Store.SetRequestStamps('graph_requests', $limiter.Stamps()) } catch { }
    }
    if ($task.IsFaulted) { throw $task.Exception.GetBaseException() }
    $failed = @($items | Where-Object State -eq 'Failed')
    [pscustomobject]@{
        Items             = $items.Count
        Done              = [int]$collector.ItemsDone
        Failed            = $failed
        Cancelled         = @($items | Where-Object State -eq 'Cancelled').Count
        Requests          = $collector.Requests
        Pages             = $collector.Pages
        Rows              = $collector.Rows
        NewMessages       = $collector.NewMessages
        NewDeliveries     = $collector.NewDeliveries
        UpdatedDeliveries = $collector.UpdatedDeliveries
        Throttled         = $collector.Throttled
        Retries           = $collector.Retries
        Bytes             = $collector.Bytes
        WaitedSeconds     = $limiter.WaitedMs / 1000.0
        Seconds           = $clock.Elapsed.TotalSeconds
        Fatal             = $collector.Fatal
        FatalStatus       = $collector.FatalStatus
    }
}

function Invoke-MtrDetails {
    <#
    .SYNOPSIS
        Reads the route (getDetailsByRecipient) of the deliveries returned by Store.GetDetailCandidates.
        Separate quota of the API (same size as the message trace quota).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Store, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][Collections.Generic.List[MessageTraceReport.DetailItem]]$Items,
        [MessageTraceReport.CollectorOptions]$Options
    )
    $slot = [MessageTraceReport.TokenSlot]::new()
    $slot.Set($Connection.Token, $Connection.ExpiresMs)
    $th = $Settings.Throttling
    $limiter = [MessageTraceReport.RateLimiter]::new($th.MaxRequests, [long]$th.PeriodSeconds * 1000, $Store.GetRequestStamps('graph_detail_requests'))
    if (-not $Options) { $Options = New-MtrCollectorOptions $Settings }
    $collector = [MessageTraceReport.DetailCollector]::new($Store, $Options, $slot, $limiter)
    $cts = [Threading.CancellationTokenSource]::new()
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $seen = @{}
    $task = $collector.RunAsync($Items, $cts.Token)
    try {
        while (-not $task.IsCompleted) {
            try { [void](Update-MtrToken -Connection $Connection -Slot $slot -Settings $Settings) } catch { }
            Write-MtrEngineEvents $collector.Events $seen
            Write-MtrProgress -Fraction $collector.Progress -Text ('{0}/{1} routes {2} {3} requests {2} quota {4}/{5}' -f ($collector.Done + $collector.Failed), $Items.Count, $script:Dot, $collector.Requests, $limiter.InWindow, $limiter.MaxRequests)
            [void]$task.Wait(250)
        }
    }
    finally {
        if (-not $task.IsCompleted) { $cts.Cancel(); try { [void]$task.Wait(60000) } catch { } }
        Clear-MtrProgress
        Write-MtrEngineEvents $collector.Events $seen
        try { $Store.SetRequestStamps('graph_detail_requests', $limiter.Stamps()) } catch { }
    }
    [pscustomobject]@{ Items = $Items.Count; Done = [int]$collector.Done; Failed = [int]$collector.Failed; Events = [long]$collector.EventsStored; Requests = $collector.Requests; Seconds = $clock.Elapsed.TotalSeconds; Fatal = $collector.Fatal }
}
