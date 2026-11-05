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

# SIG # Begin signature block
# MIImIwYJKoZIhvcNAQcCoIImFDCCJhACAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAsJCm6oA7voBLj
# fHMhWmRfPWFAHiM51g9vF+lCtHZf46CCDW8wggZyMIIEWqADAgECAghkM1HTxzif
# CDANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMx
# EDAOBgNVBAcMB0hvdXN0b24xGDAWBgNVBAoMD1NTTCBDb3Jwb3JhdGlvbjExMC8G
# A1UEAwwoU1NMLmNvbSBSb290IENlcnRpZmljYXRpb24gQXV0aG9yaXR5IFJTQTAe
# Fw0xNjA2MjQyMDQ0MzBaFw0zMTA2MjQyMDQ0MzBaMHgxCzAJBgNVBAYTAlVTMQ4w
# DAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjERMA8GA1UECgwIU1NMIENv
# cnAxNDAyBgNVBAMMK1NTTC5jb20gQ29kZSBTaWduaW5nIEludGVybWVkaWF0ZSBD
# QSBSU0EgUjEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCfgxNzqrDG
# bSHL24t6h3TQcdyOl3Ka5LuINLTdgAPGL0WkdJq/Hg9Q6p5tePOf+lEmqT2d0bKU
# Vz77OYkbkStW72fL5gvjDjmMxjX0jD3dJekBrBdCfVgWQNz51ShEHZVkMGE6ZPKX
# 13NMfXsjAm3zdetVPW+qLcSvvnSsXf5qtvzqXHnpD0OctVIFD+8+sbGP0EmtpuNC
# GVQ/8y8Ooct8/hP5IznaJRy4PgBKOm8yMDdkHseudQfYVdIYyQ6KvKNc8HwKp4WB
# wg6vj5lc02AlvINaaRwlE81y9eucgJvcLGfE3ckJmNVz68Qho+Uyjj4vUpjGYDdk
# jLJvSlRyGMwnh/rNdaJjIUy1PWT9K6abVa8mTGC0uVz+q0O9rdATZlAfC9KJpv/X
# gAbxwxECMzNhF/dWH44vO2jnFfF3VkopngPawismYTJboFblSSmNNqf1x1KiVgMg
# Lzh4gL32Bq5BNMuURb2bx4kYHwu6/6muakCZE93vUN8BuvIE1tAx3zQ4XldbyDge
# VtSsSKbt//m4wTvtwiS+RGCnd83VPZhZtEPqqmB9zcLlL/Hr9dQg1Zc0bl0EawUR
# 0tOSjAknRO1PNTFGfnQZBWLsiePqI3CY5NEv1IoTGEaTZeVYc9NMPSd6Ij/D+KNV
# t/nmh4LsRR7Fbjp8sU65q2j3m2PVkUG8qQIDAQABo4H7MIH4MA8GA1UdEwEB/wQF
# MAMBAf8wHwYDVR0jBBgwFoAU3QQJB6L1en1SUxKSle44gCUNplkwMAYIKwYBBQUH
# AQEEJDAiMCAGCCsGAQUFBzABhhRodHRwOi8vb2NzcHMuc3NsLmNvbTARBgNVHSAE
# CjAIMAYGBFUdIAAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwOwYDVR0fBDQwMjAwoC6g
# LIYqaHR0cDovL2NybHMuc3NsLmNvbS9zc2wuY29tLXJzYS1Sb290Q0EuY3JsMB0G
# A1UdDgQWBBRUwv4QlQCTzWr158DX2bJLuI8M4zAOBgNVHQ8BAf8EBAMCAYYwDQYJ
# KoZIhvcNAQELBQADggIBAPUPJodwr5miyvXWyfCNZj05gtOII9iCv49UhCe204MH
# 154niU2EjlTRIO5gQ9tXQjzHsJX2vszqoz2OTwbGK1mGf+tzG8rlQCbgPW/M9r1x
# xs19DiBAOdYF0q+UCL9/wlG3K7V7gyHwY9rlnOFpLnUdTsthHvWlM98CnRXZ7WmT
# V7pGRS6AvGW+5xI+3kf/kJwQrfZWsqTU+tb8LryXIbN2g9KR+gZQ0bGAKID+260P
# Z+34fdzZcFt6umi1s0pmF4/n8OdX3Wn+vF7h1YyfE7uVmhX7eSuF1W0+Z0duGwdc
# +1RFDxYRLhHDsLy1bhwzV5Qe/kI0Ro4xUE7bM1eV+jjk5hLbq1guRbfZIsr0WkdJ
# LCjoT4xCPGRo6eZDrBmRqccTgl/8cQo3t51Qezxd96JSgjXktefTCm9r/o35pNfV
# HUvnfWII+NnXrJlJ27WEQRQu9i5gl1NLmv7xiHp0up516eDap8nMLDt7TAp4z5T3
# NmC2gzyKVMtODWgqlBF1JhTqIDfM63kXdlV4cW3iSTgzN9vkbFnHI2LmvM4uVEv9
# XgMqyN0eS3FE0HU+MWJliymm7STheh2ENH+kF3y0rH0/NVjLw78a3Z9UVm1F5VPz
# iIorMaPKPlDRADTsJwjDZ8Zc6Gi/zy4WZbg8Zv87spWrmo2dzJTw7XhQf+xkR6Od
# MIIG9TCCBN2gAwIBAgIQBof4ljXihJpmCqqt2mhAWzANBgkqhkiG9w0BAQsFADB4
# MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24x
# ETAPBgNVBAoMCFNTTCBDb3JwMTQwMgYDVQQDDCtTU0wuY29tIENvZGUgU2lnbmlu
# ZyBJbnRlcm1lZGlhdGUgQ0EgUlNBIFIxMB4XDTI2MTAxMzAyNDgwMloXDTI3MTAx
# MzAyNDgwMlowXDELMAkGA1UEBhMCRlIxGzAZBgNVBAcMEkNoYW50ZWxvdXAtRW4t
# QnJpZTEXMBUGA1UECgwOTmljb2xhcyBGYWJlcnQxFzAVBgNVBAMMDk5pY29sYXMg
# RmFiZXJ0MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAsg6CT0mFQ4jB
# V2plIS4uWFSoVqRHd82Y7XYZ4CUTe/7nPBRUlXXdKTZMMHzGgiG8dEXNE8K1Xe90
# Dgl/FnorzAFlrNWSwf6t27UAUw9xkqtRDVVpVgpixpWkAwjcQeLG+YMqBkGbFi35
# TGvS23lPFWvLp4DxARrv15MtZ/NjNTCAAGUlMP2hFVBknEmrnYjEGyeJ93sl20RS
# WXQQLNqlenBdkGCrQW4XjHtRjJAEqAC68hN6nWevopSQ8CLUV7A1RFfHFarDrzrL
# zr0/NjIdSyIfM9hShln31NDrktB6Ups2XIyrtPDNB7fjkW4jpLlOqQGfYKsU9ErE
# 4SnFsh0yOOjitegyh1RvZ9wH++3DF4CmJfTli5l/gEIm8xCCryxI+K5EogW3wu1y
# u8NT2hcvHjdh7OpRyPyFAuLZ8MfX7kPAJpnuCeOuktzY/20eVD8bDglj+4zgqzsn
# cR/t6T/7w1/HxpRyrVoKvEyRx+mphYh5jMdEa0BjxOL0vAJpdGZSfXGmPm/yPqRn
# 5STTkMtzkVQXPbcvgKM0luzFcQKPHk3qdHLEXa8gf93ktYDbLE5Wd2UHrXz3SZxN
# URHPdIXCr1qgrqQve7041kMpzrkDI5DnG2lvRG4108gp02bHG0muKyZlDdCOra7h
# Zonu2nO79sFallruzzNi0o994PoWksUCAwEAAaOCAZUwggGRMAwGA1UdEwEB/wQC
# MAAwHwYDVR0jBBgwFoAUVML+EJUAk81q9efA19myS7iPDOMwegYIKwYBBQUHAQEE
# bjBsMEgGCCsGAQUFBzAChjxodHRwOi8vY2VydC5zc2wuY29tL1NTTGNvbS1TdWJD
# QS1Db2RlU2lnbmluZy1SU0EtNDA5Ni1SMS5jZXIwIAYIKwYBBQUHMAGGFGh0dHA6
# Ly9vY3Nwcy5zc2wuY29tMFEGA1UdIARKMEgwCAYGZ4EMAQQBMDwGDCsGAQQBgqkw
# AQMDATAsMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5zc2wuY29tL3JlcG9zaXRv
# cnkwEwYDVR0lBAwwCgYIKwYBBQUHAwMwTQYDVR0fBEYwRDBCoECgPoY8aHR0cDov
# L2NybHMuc3NsLmNvbS9TU0xjb20tU3ViQ0EtQ29kZVNpZ25pbmctUlNBLTQwOTYt
# UjEuY3JsMB0GA1UdDgQWBBRoUx3630l9wA1fUpkKkw2GUIxl/jAOBgNVHQ8BAf8E
# BAMCB4AwDQYJKoZIhvcNAQELBQADggIBAE3oj6cNuwlDToi1BwjgsA5djfRN4DIi
# BYDFZIRYaIRe/rEdnItz3aqQQdFuwXnJA/MQEmi2WAGek8GeZF+R41s8FbcDxBUE
# BoSt98TuBE+0xgxQWDiPhhXaX1Aw9V0GF4ZnlfCSw1eu2KiASaKn7Bo0PLbEAXff
# vftRXof/kyqtw8iID6I4Rhrf5DI3WVZQodakUUmWnbnziWvEZOWbNOfzwP+7BwEt
# 7jQANfbmEfb4p75rfy5dQVwniTDSvdo6xkrbe1Cr93GS7cJta18IG5CoIVUmdK+s
# W38B1sLuy8Mi0MstMXV3004yaRuzLdNaAM0f9WAFerxemiQC0kdmA44/lWV3lVkM
# WJSwkHBkkSg8Eh0hxcGzTH2xmtDhLJHNNLRwkI9u2Ur+HbLCt50oBgSV8BcCs/1i
# qi884iC/yuX+HIv9YgTUNZ8c4lLaq4VuliJpXLu2buHIsTkO0v0+5oCM91zjTVZm
# ULeH38N0Vr83psiJVuBSxQyt5nRVrpYz7FACq5gtXELkyViq/rGOlJKaRrgQ6WWq
# eoIXqKhVFAdP/jAEm2M8ezoVYsUgPyKY2OcuecV9coulAcxUIUydx6qYiOfsGj5u
# Dy7l4aYjvB771wkUMzUQwxzcDYXJtMMTaWRe6n9EemR67jc73u5CJyFg3PfA5WR1
# wZislcdCZuS6MYIYCjCCGAYCAQEwgYwweDELMAkGA1UEBhMCVVMxDjAMBgNVBAgM
# BVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDE0MDIG
# A1UEAwwrU1NMLmNvbSBDb2RlIFNpZ25pbmcgSW50ZXJtZWRpYXRlIENBIFJTQSBS
# MQIQBof4ljXihJpmCqqt2mhAWzANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3
# AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCCpR27Zc9vu
# MPU5y66KYRMbz1ivACArY65Nul64ZYCDVjANBgkqhkiG9w0BAQEFAASCAgCUMM1O
# gjJy/cu3r+yolaJ2nQS8h1LzoUg3P7hma64ksmjHAnAsrnbAELaA6O+8LoaGBDGE
# yN8A57VzTIai4lVLxGvyCafFzUwmS9XvHSERs8yiXkEIn0DYeJvDLFJzMPkrQx9t
# czDZDv690DZVLQb2Auov+es7dTpiKyBnIc20EmkXxcQ6uhOQ3mZLKSGMRw9gZ1uC
# t/XdbZz9j2cm8MdKQCEZWS0DNYRXD5QugCvPqDgpHSe1FMAhnzDP/h3ZkA2v73sF
# DwM04imX/GJ6hY2uNW4lSjZ4JIqVABiaBJzxfCYN6IP04tHdgsE5puMWgQlLBqaA
# mVpj1vZM4HegoQCW3i8d4vz7oU6xgzPqESmIqmsWraIu+zyUqehocUohbi2hN5MX
# ycBW3LlxddLKc2VH7xwVvNOYnXLyv520LRUwaEWFYWtNHTQoN+hql6iRLIiovbzt
# RqywkyilRW2ZJmaPeREB8B3VdomuaPevjkN7UKW4NuZwFhsFl8bVQfBXCR8eICfb
# CRweSv7RDs8rdXnqYMkfCQ/opsq4r6Y/bASOxqehQSsYjmgtw3XBa0+2FiO6ZYKs
# d/TtkqfdrrXGM4exarbQ861cckvX2E7VKdlBw1gwOuup+9SQkFyfQMb4x7Pgh6Hz
# 3YKVkZ/DYccr/zIgOAOIJL9ZK+yWgnaW61mzX6GCFMcwghTDBgorBgEEAYI3AwMB
# MYIUszCCFK8GCSqGSIb3DQEHAqCCFKAwghScAgEDMQ0wCwYJYIZIAWUDBAIBMIGC
# BgsqhkiG9w0BCRABBKBzBHEwbwIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEINlqwoHOB3l24CZCmpO/9ooPXaJ0z2k7In5fLfrCmVXeAggIO3XYnHzT
# 1xgPMjAyNjExMDUxODAwNTdaMAMCAQECCQDioLvwuz/z56CCEacwggTzMIIC26AD
# AgECAhBUQ/g3vVruGAGEcrhc2o7jMA0GCSqGSIb3DQEBCwUAMHIxCzAJBgNVBAYT
# AlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjERMA8GA1UECgwI
# U1NMIENvcnAxLjAsBgNVBAMMJVNTTC5jb20gVGltZXN0YW1waW5nIElzc3Vpbmcg
# UlNBIENBIDIwHhcNMjYwNjEyMTcyMjQ2WhcNMzYwNjA5MTcyMjQ1WjBuMQswCQYD
# VQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24xETAPBgNV
# BAoMCFNTTCBDb3JwMSowKAYDVQQDDCFTU0wuY29tIFRpbWVzdGFtcGluZyBVbml0
# IDIwMjYgRTEwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAToJYu4ZhMuSJI48ws2
# yQ4G2FewiFFIDjp945DC9ItwNo2Hq/FTMEoTHUp0UFEWzs4eucf8rRUDoxsNAgWl
# SDQ9o4IBUjCCAU4wHwYDVR0jBBgwFoAUcJplwUOAo/zpsWSJbvEwnAkhyXwwTQYI
# KwYBBQUHAQEEQTA/MD0GCCsGAQUFBzAChjFodHRwOi8vY2VydC5zc2wuY29tL1NT
# TC5jb20tdGltZVN0YW1waW5nLUktUjIuY2VyMFEGA1UdIARKMEgwPAYMKwYBBAGC
# qTABAwYBMCwwKgYIKwYBBQUHAgEWHmh0dHBzOi8vd3d3LnNzbC5jb20vcmVwb3Np
# dG9yeTAIBgZngQwBBAIwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwQgYDVR0fBDsw
# OTA3oDWgM4YxaHR0cDovL2NybHMuc3NsLmNvbS9TU0wuY29tLXRpbWVTdGFtcGlu
# Zy1JLVIyLmNybDAdBgNVHQ4EFgQUJ6wDVrooaroXO4M9QH95qCTswzwwDgYDVR0P
# AQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQBPdm7O/AOewhlNcGf6GOa4FeDM
# HXZ9tjFP25h7pm+G+ltlYpzINCBpwROQ/DyTrJ6qdgJjIVnTreUw8SoCEAPacwbr
# XhmHs+0db0Nap+yCK/Fs9gF4363tTGCRhPd7GltYx08SoG1ZXIc68twq8zGAlZ8m
# MA3BWTBUN+TL+Ptx/bz6KKY3w8pztL+7z8t6dFGdXZbZh+dxGeTP0J+zmdEPNpmC
# 6IeuunYbHCCc1BIfgYGMc6Xc/MuydVsahkqLhkSOBe6mziYYY4rv4YHYcCVCf45L
# 3jhweqWQfSASW3ZZ7OgI1GkQumH2prG4GeNISpdZZ+ATrIYHA7S7Eo2qlZVMeYDC
# vpK8E+h/G5tci4Sf2K9HgIs64DFRKsnjVkGD+qobSgmMXoaREpvGrtzJZKQRlgmG
# YoKDYeDl9cdqA7GLBuafkk9nW+FYKtuTe/91PHaC9Mrn56sLkf3+tNyWNQjvvrJ3
# at+GN+Sm/ICxu1ezgPueufDyL3Civn5921FIkFXGrMubKQV+2gvRSnZD763IoJR2
# uJt1yesHgcpLez63cCN1xsDToMIvwaJ9CL18vTJEFE2UDijoE/5KvvnkxoI2NRFh
# kO8PLEkcEFPtyqNkjCyJHyz7rzrSegVsEG12B7YjDsI8L/VDfUjbuFWiVLsHTJqj
# e/xfYy1bLeaxmVdNwTCCBd0wggPFoAMCAQICCHssm9MWgDKZMA0GCSqGSIb3DQEB
# CwUAMHwxCzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91
# c3RvbjEYMBYGA1UECgwPU1NMIENvcnBvcmF0aW9uMTEwLwYDVQQDDChTU0wuY29t
# IFJvb3QgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkgUlNBMB4XDTE2MDIxMjE3Mzkz
# OVoXDTQxMDIxMjE3MzkzOVowfDELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFz
# MRAwDgYDVQQHDAdIb3VzdG9uMRgwFgYDVQQKDA9TU0wgQ29ycG9yYXRpb24xMTAv
# BgNVBAMMKFNTTC5jb20gUm9vdCBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eSBSU0Ew
# ggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQD5D92jK33L0Cr+7GeFpucu
# G7p34eP1r6Ts+kpdkcRXR2sYd2t28v2T5D0PwhaeC2bDVpSeF4OFzlbv8hb9AGL1
# IglU6GUXTkG54E9Gl6obyLhuYl5psV/bKgJ+/GzK80HY7dDo/D9hSO2wAxQdEA5L
# GeC7TuyGZf82815nAgudhlVh/Xo47f7iGQC3b6FQYnV0PKD6yCWStG56Isf4HqHj
# st2RMasrHQT/pUoEN+mFpDMr/eLWVTR8GaRKaMeyqNO3yqGTiOvBl7yM+R3ZIoQk
# dMcEPWqpKZPM67hb4f5fJao0WMjBI1SdG5gRwzicfj2GbKUPQIZ8AvRcAk8oy65x
# nw86yDP+ESU16vy6xWA92XwY1bKp03V4A3IiyjrDH+8s5S6p+p4stlFG/a8D1upg
# aOqFFjZrhekewLPdxCTcgCqBQW2UPsjgyYFBAJ5ev3/FCJiiGCxCQLP5bzgnS06A
# 9D2BR+CIfOoczrV1XFEuHCt/GnIo5wC10XTG1+SfrQeTtlM1Nfw35MP2XRa+IXPe
# kgr4oGNqvJaSaj74vGVVm971DYkmBPwlGqYlacvCbcp84llfl6zr7y7IvNcbWTwr
# zPIZyJNrJ2MZz/zpJvjKcZt/k/40Z4ROmev8s3gJM3C6ZqZ27Rtz6xqlDcQiEyCU
# VgpOLGxOsf3PnAm6ojPthwIDAQABo2MwYTAdBgNVHQ4EFgQU3QQJB6L1en1SUxKS
# le44gCUNplkwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTdBAkHovV6fVJT
# EpKV7jiAJQ2mWTAOBgNVHQ8BAf8EBAMCAYYwDQYJKoZIhvcNAQELBQADggIBACAY
# EZQp+yadHB4ecGHxlXKTcSStaJNYjjKvG7NwA/wlK3SFkD14avS5i6WXO7UYkbse
# p/lAW5H5VZmvHhHQXB2nZuOxlAcMMjmm6huwedgdnHBE44rdxPmVH4o4Qz8BhaVH
# pz1GsrzlImj3e5zYLD4KIcgtM6y/xYGZMXTBdXHFvrHwI0X0nWv8GWOdo7wExhgL
# JbtTiQ+zgFDeRe5Ef6uUeGSY0/Yo3YfYcGV0+w65E+unD2GpMpbM3rvtY0wYu6lA
# 96BUbiCIcXUY6nq0NHLgIyd3XLaQ6oYlQKvvMw/Ln4K+oiD79rUtGubChbF0D/vI
# ZQKkUgFH3Ukiwb/Y62usft7sYzMVtyMIj8YPjUFa3Y7FuY/lRT9427rSG0Cx/nFN
# P+CBorpetOwV4JPdCB9+4VWZCyHek54K++ajSb02MP7nd7KgdZe1LYGIF2Ug99qQ
# AJ/JUswyyjV89T0P2CvX9SZsyQY0lhbqcFkaMnl5C7aIfw9SSD2/bNiiRC7RTrdy
# WNOJE5X+RKv414sbbpy8LKBb1WoAr1834dX6EAuYnIbnJo/O8OxuilcLgONOssCg
# Y2GQulVoN3RqtpLbn6GGIrZlJw7stp9CYORnwrXaQQvE04thG7z6H5Er10QHXrop
# rNnF6e9TSFrrgPEoWCHNsAZV+yc/U5BwqQQeVye5MIIGyzCCBLOgAwIBAgIQUp27
# wriJh/WDgOCw66IGNjANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzEOMAwG
# A1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24xGDAWBgNVBAoMD1NTTCBDb3Jw
# b3JhdGlvbjExMC8GA1UEAwwoU1NMLmNvbSBSb290IENlcnRpZmljYXRpb24gQXV0
# aG9yaXR5IFJTQTAeFw0yNjA2MTIxNjQyMTVaFw00MTAyMTIxNzM5MzlaMHIxCzAJ
# BgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjERMA8G
# A1UECgwIU1NMIENvcnAxLjAsBgNVBAMMJVNTTC5jb20gVGltZXN0YW1waW5nIElz
# c3VpbmcgUlNBIENBIDIwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCf
# L6vmc02QvDFGmzYHeVpQY1T3Lu9aInnTXfJ/SJfPrltB3Br1uOPyX9KR5eocap9K
# HYWhp77zQTyYMR/3egjCOzLYJfZxeYrGq0XwckZgHh/rJGEoQPnTCRs7KwvTYhd/
# 78RmdrjiN9+GFXPg5T+TnbFD8+ciD+4WFzZaT5Jz8IeoCv6VhWQ/PsvLlGoH1/VE
# oav0kLftbUuBV0cLnR00h2xrdBc+GW1hm5tHeekTgFt+LSOhRbmfk7RrLB43jlH9
# hUvEDRgaWnU4dV9WeyperxuGfDUtziSMnpc6BeU6XD9rzN7ntO9t25mXd6F7BOa8
# 7QCTL+eo5YNL0g8/F3F0bq+msFtK4eXE0A0EBsdOIWCR9mZ/R1liVP8CdkigXECr
# Qcgs+iV/g6BaARPvpKJZKWbZdhEhfBWOl6obSmW9fBEhAHNKIQmPtB5AWcK8fHiB
# Awg283f7Ib/WvGERtqMa97S1M/eVfg884dUATRAmnhnM8jVhgmSFVGuJVXFVFTgW
# yDgE/A/oj5guYdvW1nhEvA4U0uH+AlgOA+UKEKjE6iAXFeDA9lmsPIRFgHRp457F
# bQ4ppw3hFG71yoXYoq78BvkAvt5gMtUZQ+sQTJhsgwClUqql5tzT+MNCeIL7euRq
# 5ECOBVzybWKn8JCAbUPDhn26VVEBj1VHplrbouxNtQIDAQABo4IBUTCCAU0wEgYD
# VR0TAQH/BAgwBgEB/wIBADAfBgNVHSMEGDAWgBTdBAkHovV6fVJTEpKV7jiAJQ2m
# WTBNBggrBgEFBQcBAQRBMD8wPQYIKwYBBQUHMAKGMWh0dHA6Ly9jZXJ0LnNzbC5j
# b20vU1NMY29tLVJvb3RDQS1SU0EtNDA5Ni1SMS5jZXIwPwYDVR0gBDgwNjA0BgRV
# HSAAMCwwKgYIKwYBBQUHAgEWHmh0dHBzOi8vd3d3LnNzbC5jb20vcmVwb3NpdG9y
# eTATBgNVHSUEDDAKBggrBgEFBQcDCDBCBgNVHR8EOzA5MDegNaAzhjFodHRwOi8v
# Y3Jscy5zc2wuY29tL1NTTGNvbS1Sb290Q0EtUlNBLTQwOTYtUjEuY3JsMB0GA1Ud
# DgQWBBRwmmXBQ4Cj/OmxZIlu8TCcCSHJfDAOBgNVHQ8BAf8EBAMCAYYwDQYJKoZI
# hvcNAQELBQADggIBAGUUW80x6YDqIGIFijnogpCNaFa5Bpgq6jiql/Qok0REC3WD
# P4ewDZIvfED9X4QDxJE80/1K9fSKz7mYOymli+krJgapg/fpgVbSZsXUXRm1fG6Y
# JRQ79lXmYE0oN/lDg9jtBvR5YB6lRzSs0mv8y+flmJd8k/ENvbGZyDxpEPrnb+ev
# 46uTZQE/QTjeIl0jgsXtWzb1HdIZEthk7EzXkMjhB5uwpGXQoOV/g6ZgYIpzu6ZP
# GJuRm03ULUpaCd/2Np1T8nCfJJpgQGDHr+/4VULpIY43OJjtNy8j0xX6pjEdQ+U6
# boBpA/Z1LhuNZeebzqV0JtSTG04AK6ZJ9P3vTvsk2JVrs9nUgGR3/Y8TUALyCztT
# 79iTUE31dE8iLXmT+4DXEX2h557koaPKIYqSohPtbxCSBRPnN4KKcUqRwpp9kxxE
# 5JVile2a1CoYZHaDi49ionQrWGazqAlese3/finwz0+tXyg1Z7RmXUSsMy1ed1SD
# eqEkvikDdlSWjvDmUzmaX4DuKOv/caTa/hBGgN4TZKGZNd0eC2qjwv99PXX2ZhwR
# PJwTY1gZFewGXc3SvMOwdGvw/dOumuqFGtfTiJLQ/t5D6UPGBLfKEafc7NYaEO30
# Z/bHWp7T+p2EUBU6RfHMxnPhRq3rGwB/NfT7+bwYQpbk6PD8dj6Qu9XDNI87MYIC
# VjCCAlICAQEwgYYwcjELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYD
# VQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDEuMCwGA1UEAwwlU1NMLmNv
# bSBUaW1lc3RhbXBpbmcgSXNzdWluZyBSU0EgQ0EgMgIQVEP4N71a7hgBhHK4XNqO
# 4zALBglghkgBZQMEAgGgggFgMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAc
# BgkqhkiG9w0BCQUxDxcNMjYxMTA1MTgwMDU3WjAoBgkqhkiG9w0BCTQxGzAZMAsG
# CWCGSAFlAwQCAaEKBggqhkjOPQQDAjAvBgkqhkiG9w0BCQQxIgQg2Flcj6N+mXEw
# wdafFuFNqMkEz5x43QZHQVXE8iNay90wgcgGCyqGSIb3DQEJEAIvMYG4MIG1MIGy
# MIGvBCBXT+oXqvpefGormwjJmLFzXkULOHPKROaiTKCTDmPzsDCBijB2pHQwcjEL
# MAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREw
# DwYDVQQKDAhTU0wgQ29ycDEuMCwGA1UEAwwlU1NMLmNvbSBUaW1lc3RhbXBpbmcg
# SXNzdWluZyBSU0EgQ0EgMgIQVEP4N71a7hgBhHK4XNqO4zAKBggqhkjOPQQDAgRH
# MEUCIBBfZK8t0tLx9eKfAByeZuUHA0WJNd5A3NalKlnpqQEpAiEAwIJOlGrqY9ar
# 1hUtJtaftXHTao0JxwF/SAEn4j5lsNw=
# SIG # End signature block
