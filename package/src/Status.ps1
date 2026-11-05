<#
    Message Trace Report - status and maintenance.

    Show-MtrStatus       what the database holds: totals, day by day coverage, last runs
    Invoke-MtrRetention  deletes what is older than Storage.RetentionDays, merges settled coverage rows
    Enter-MtrLock        one collection at a time on a database (scheduled task + administrator)
#>

function Show-MtrStatus {
    <#
    .SYNOPSIS
        Prints the content of the database and, day by day, the messages stored and how much of the day is
        collected for the collection scope (the whole tenant, or the Collect section of the configuration).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)]$Settings, [string[]]$Signatures = @(''), [string]$ScopeLabel = 'whole tenant', [int]$Days = 14)
    $zone = $Settings.Zone; $K = $script:C; $dot = $script:Dot
    $now = [DateTimeOffset]::UtcNow; $nowMs = $now.ToUnixTimeMilliseconds()
    $s = $Store.GetStatistics()
    Write-MtrItem Info ('{0}  ({1})' -f $Store.FilePath, (Format-MtrBytes $s.FileBytes)) -Icon Database
    Write-MtrItem Info ('{0} messages {5} {1} deliveries {5} {2} addresses {5} {3} distinct queries {5} {4} run(s)' -f (Format-MtrNumber $s.Messages), (Format-MtrNumber $s.Deliveries), (Format-MtrNumber $s.Addresses), (Format-MtrNumber $s.Signatures), (Format-MtrNumber $s.Runs), $dot) -Icon Chart
    if (-not $s.Messages) { Write-MtrItem Warn 'The database is empty. Run a trace (.\Invoke-MessageTraceReport.ps1 -Sender ...) or a collection (-Mode Collect).'; return }
    Write-MtrItem Info ('Messages received {0}' -f (Format-MtrRange $s.FirstReceivedMs $s.LastReceivedMs $zone)) -Icon Calendar
    if ($s.LastCollectMs) { Write-MtrItem Info ('Last collection {0}' -f (Format-MtrLocalTime $s.LastCollectMs $zone 'yyyy-MM-dd HH:mm:ss')) -Icon Clock }
    if ($s.DetailEvents) { Write-MtrItem Info ('{0} route events (getDetailsByRecipient)' -f (Format-MtrNumber $s.DetailEvents)) -Icon Route }

    # Day by day, for the collection scope.
    Write-Host ''
    Write-MtrItem Info "Collection scope: $ScopeLabel ($(@($Signatures).Count) quer$(if (@($Signatures).Count -gt 1) { 'ies' } else { 'y' }))" -Icon Target
    $today = [TimeZoneInfo]::ConvertTime($now, $zone).DateTime.Date
    $first = $today.AddDays( - ($Days - 1))
    $settling = [long]$Settings.Collection.SettlingHours * 3600000
    # No collection of the scope yet (traces of a few addresses only): neutral state, not a warning.
    $ranges = @($Signatures | ForEach-Object { $Store.GetCoverage($_, -1) } | Where-Object { $_ })
    $neverCollected = -not $ranges.Count
    if ($neverCollected) { Write-MtrItem Info 'This scope was never collected (-Mode Collect): the days show the messages stored by the traces.' }
    else {
        # The table starts on the first day collected (the days before are not "missing").
        $firstCollected = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::FromUnixTimeMilliseconds(($ranges | Measure-Object -Property Start -Minimum).Minimum), $zone).DateTime.Date
        if ($firstCollected -gt $first) { $first = $firstCollected; $Days = [int]($today - $first).TotalDays + 1 }
    }
    # @( ): with a single signature PowerShell would otherwise unroll the list of days.
    $perSignature = @(foreach ($sig in $Signatures) { , @($Store.GetDailyStatistics($first, $Days, $zone, $sig, $settling)) })
    $earliest = Get-MtrEarliestMs -Days $Settings.Collection.SourceHistoryDays -Now $now
    $rows = for ($i = 0; $i -lt $Days; $i++) {
        $base = $perSignature[0][$i]
        if ($base.StartMs -ge $nowMs) { continue }
        $length = [Math]::Max(1L, [Math]::Min([long]$base.EndMs, [long]$nowMs) - [long]$base.StartMs)
        $covered = ($perSignature | ForEach-Object { $_[$i].CoveredMs } | Measure-Object -Minimum).Minimum
        $settled = ($perSignature | ForEach-Object { $_[$i].SettledMs } | Measure-Object -Minimum).Minimum
        $percent = [int][Math]::Min(100, [Math]::Floor(100.0 * $covered / $length))
        if ($neverCollected) { $state = if ($base.Messages) { 'Traces only' } else { '-' }; $status = 'Skip' }
        elseif ($base.LocalDate -eq $today) { $state = if ($percent -ge 100) { 'Today, provisional' } else { 'Today, in progress' }; $status = 'Info' }
        elseif ($percent -ge 100 -and $settled -ge ($base.EndMs - $base.StartMs)) { $state = 'Complete'; $status = 'Ok' }
        elseif ($percent -ge 100) { $state = 'Complete, refreshed at the next run'; $status = 'Ok' }
        elseif ($base.EndMs -le $earliest) { $state = if ($percent -gt 0) { 'Partial, beyond the Graph history' } else { 'Not collected, beyond the Graph history' }; $status = 'Fail' }
        else { $state = if ($percent -gt 0) { 'Partial' } else { 'Not collected' }; $status = 'Warn' }
        $filled = [int][Math]::Round(12 * $percent / 100.0)
        $color = @{ Ok = $K.Green; Warn = $K.Yellow; Fail = $K.Red; Info = $K.Cyan; Skip = $K.Dim }[$status]
        [pscustomobject]@{
            Status = $status; Day = $base.LocalDate.ToString('ddd yyyy-MM-dd', [Globalization.CultureInfo]::GetCultureInfo('en-US'))
            Messages = Format-MtrNumber $base.Messages
            Collected = ('{0}{1}{2}{3}{4} {5,3}%' -f $color, [string]::new([char]0x2588, $filled), $K.Dim, [string]::new([char]0x2591, 12 - $filled), $K.Reset, $percent)
            State = $state
        }
    }
    Write-MtrTable -Columns @(
        @{ Name = 'Day'; Property = 'Day'; Width = 15 }
        @{ Name = 'Messages'; Property = 'Messages'; Width = 10; Align = 'Right' }
        @{ Name = 'Collected'; Property = 'Collected'; Width = 18; Raw = $true }
        @{ Name = 'State'; Property = 'State'; Width = 0 }
    ) -Rows @($rows)

    $runs = @($Store.GetRecentRuns(8))
    if ($runs.Count) {
        Write-Host ''
        Write-MtrItem Info 'Last runs' -Icon Log
        $table = foreach ($r in $runs) {
            [pscustomobject]@{
                Status   = switch ($r.Status) { 'Succeeded' { 'Ok' } 'Incomplete' { 'Warn' } 'Running' { 'Info' } default { 'Fail' } }
                Started  = Format-MtrLocalTime $r.StartedMs $zone
                Mode     = $r.Mode
                Duration = if ($r.EndedMs -gt $r.StartedMs) { Format-MtrDuration (($r.EndedMs - $r.StartedMs) / 1000.0) } else { '' }
                Requests = Format-MtrNumber $r.Requests
                Rows     = Format-MtrNumber $r.Rows
                Filter   = if ($r.Error) { "$($r.Status): $($r.Error)" } else { $r.Filter }
            }
        }
        Write-MtrTable -Columns @(
            @{ Name = 'Started'; Property = 'Started'; Width = 16 }
            @{ Name = 'Mode'; Property = 'Mode'; Width = 7 }
            @{ Name = 'Duration'; Property = 'Duration'; Width = 10 }
            @{ Name = 'Requests'; Property = 'Requests'; Width = 8; Align = 'Right' }
            @{ Name = 'Rows'; Property = 'Rows'; Width = 10; Align = 'Right' }
            @{ Name = 'Filter / result'; Property = 'Filter'; Width = 0 }
        ) -Rows @($table)
    }
}

function Invoke-MtrRetention {
    <# Deletes database content older than Storage.RetentionDays (0 = keep everything) and merges settled coverage. #>
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)]$Settings)
    $merged = $Store.CompactCoverage([long]$Settings.Collection.SettlingHours * 3600000)
    $purge = $null
    if ($Settings.Storage.RetentionDays -gt 0) {
        $cutoff = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [long]$Settings.Storage.RetentionDays * 86400000
        $purge = $Store.PurgeBefore($cutoff)
    }
    [pscustomobject]@{ MergedCoverage = $merged; Purge = $purge }
}

function Enter-MtrLock {
    <#
    .SYNOPSIS
        One collection at a time on a database (for example the scheduled task and an administrator).
        Returns the lock, to be released with Exit-MtrLock.
    #>
    param([Parameter(Mandatory)][string]$Path, [int]$TimeoutSeconds = 30)
    [void][IO.Directory]::CreateDirectory((Split-Path $Path -Parent))
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        try {
            $stream = [IO.FileStream]::new($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
            $stream.SetLength(0)
            $bytes = [Text.Encoding]::UTF8.GetBytes(("{0} pid {1} since {2:o}" -f [Environment]::MachineName, $PID, (Get-Date)))
            $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
            return $stream
        } catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) {
                $owner = try { [IO.File]::ReadAllText($Path) } catch { 'unknown' }
                throw "Another execution is already collecting into this database ($owner). Wait for it to finish, or use -Mode Report to build a report from the data already collected."
            }
            Start-Sleep -Seconds 2
        }
    }
}

function Exit-MtrLock {
    param($Lock)
    if ($Lock) { $Lock.Dispose() }
}

# SIG # Begin signature block
# MIImIgYJKoZIhvcNAQcCoIImEzCCJg8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAQDvbKhgwKeN2x
# 5Dq0oNT6P0lQMCK4W+NXeMj65xYP+6CCDW8wggZyMIIEWqADAgECAghkM1HTxzif
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
# wZislcdCZuS6MYIYCTCCGAUCAQEwgYwweDELMAkGA1UEBhMCVVMxDjAMBgNVBAgM
# BVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDE0MDIG
# A1UEAwwrU1NMLmNvbSBDb2RlIFNpZ25pbmcgSW50ZXJtZWRpYXRlIENBIFJTQSBS
# MQIQBof4ljXihJpmCqqt2mhAWzANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3
# AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCBKpPRvtkoZ
# tB5VkBttIsktsv50xSNSHNuC6g1j5r7aCjANBgkqhkiG9w0BAQEFAASCAgAwmSBf
# tKuFWGcz85dbIXyI0SoWiJ5IY5fJo/7Dmm0wseqptqYHNV7wNKvMI011bEIOhpSb
# rJzvjIXjqg76GKfSugjLDsJixxhsZObXY0lablYJCjY14ueb/mxo39ZMSc7vaLrk
# I2L74cEKdp7U3qJsSEeJyqN0NbEjzzq+w6r44xinxJ1/t/j31Swbl+hzhmba0rDC
# W+NqmrKVh95whOFTa8vpwT5eC4zHL1kzQWrI5RSN9pu5QjCjHjh6CtiAzbS9uMks
# PgICgKocdkQVPhBbzzbzyfe5iTwiKf1z0glSR2MRKYzdypIuRjPqYcKkLz2NrGJ8
# DCQwqp41zGkFJt75Sxb3SeARxgGBqGPCti53uTbr3qeRuHNxZdxsohhO/l3QqkjF
# SjZ/EC6cx1w/g6u0yrlln8mpUxdXUHL04dUs7lhIG2MATHNAib3kwV0ePaTiUU42
# nWNZ6iRrHQxbUxLwpwspwslrBO0NRn0SqKfbJvNQSLyA6UBhBUzPIvWPu1GnwARt
# l+1BE9Gj/8fcoKE7MHQrBXiZavvG87vkCAxplRB+Fug1RFuALonUimnb4NpzaSuZ
# 1n9CjX0maLS7xIWNHuDZLJrKjtoGN/5UrGTqc3Wr3cjXjyFeC18QaVh9qpaCof9i
# 2HYwqVcEZidC4fTQwez4PZbkez88N4glSG/qaaGCFMYwghTCBgorBgEEAYI3AwMB
# MYIUsjCCFK4GCSqGSIb3DQEHAqCCFJ8wghSbAgEDMQ0wCwYJYIZIAWUDBAIBMIGB
# BgsqhkiG9w0BCRABBKByBHAwbgIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEIG1wuL5cIMF/g7yzyiYblS3/VrXcF8BYYZvWja5izy5HAghRH/Z8c3D6
# AxgPMjAyNjExMDUxODAxMDJaMAMCAQECCDlxdQpoLPF/oIIRpzCCBPMwggLboAMC
# AQICEFRD+De9Wu4YAYRyuFzajuMwDQYJKoZIhvcNAQELBQAwcjELMAkGA1UEBhMC
# VVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhT
# U0wgQ29ycDEuMCwGA1UEAwwlU1NMLmNvbSBUaW1lc3RhbXBpbmcgSXNzdWluZyBS
# U0EgQ0EgMjAeFw0yNjA2MTIxNzIyNDZaFw0zNjA2MDkxNzIyNDVaMG4xCzAJBgNV
# BAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjERMA8GA1UE
# CgwIU1NMIENvcnAxKjAoBgNVBAMMIVNTTC5jb20gVGltZXN0YW1waW5nIFVuaXQg
# MjAyNiBFMTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABOgli7hmEy5IkjjzCzbJ
# DgbYV7CIUUgOOn3jkML0i3A2jYer8VMwShMdSnRQURbOzh65x/ytFQOjGw0CBaVI
# ND2jggFSMIIBTjAfBgNVHSMEGDAWgBRwmmXBQ4Cj/OmxZIlu8TCcCSHJfDBNBggr
# BgEFBQcBAQRBMD8wPQYIKwYBBQUHMAKGMWh0dHA6Ly9jZXJ0LnNzbC5jb20vU1NM
# LmNvbS10aW1lU3RhbXBpbmctSS1SMi5jZXIwUQYDVR0gBEowSDA8BgwrBgEEAYKp
# MAEDBgEwLDAqBggrBgEFBQcCARYeaHR0cHM6Ly93d3cuc3NsLmNvbS9yZXBvc2l0
# b3J5MAgGBmeBDAEEAjAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDBCBgNVHR8EOzA5
# MDegNaAzhjFodHRwOi8vY3Jscy5zc2wuY29tL1NTTC5jb20tdGltZVN0YW1waW5n
# LUktUjIuY3JsMB0GA1UdDgQWBBQnrANWuihquhc7gz1Af3moJOzDPDAOBgNVHQ8B
# Af8EBAMCB4AwDQYJKoZIhvcNAQELBQADggIBAE92bs78A57CGU1wZ/oY5rgV4Mwd
# dn22MU/bmHumb4b6W2VinMg0IGnBE5D8PJOsnqp2AmMhWdOt5TDxKgIQA9pzBute
# GYez7R1vQ1qn7IIr8Wz2AXjfre1MYJGE93saW1jHTxKgbVlchzry3CrzMYCVnyYw
# DcFZMFQ35Mv4+3H9vPoopjfDynO0v7vPy3p0UZ1dltmH53EZ5M/Qn7OZ0Q82mYLo
# h666dhscIJzUEh+BgYxzpdz8y7J1WxqGSouGRI4F7qbOJhhjiu/hgdhwJUJ/jkve
# OHB6pZB9IBJbdlns6AjUaRC6YfamsbgZ40hKl1ln4BOshgcDtLsSjaqVlUx5gMK+
# krwT6H8bm1yLhJ/Yr0eAizrgMVEqyeNWQYP6qhtKCYxehpESm8au3MlkpBGWCYZi
# goNh4OX1x2oDsYsG5p+ST2db4Vgq25N7/3U8doL0yufnqwuR/f603JY1CO++sndq
# 34Y35Kb8gLG7V7OA+5658PIvcKK+fn3bUUiQVcasy5spBX7aC9FKdkPvrciglHa4
# m3XJ6weBykt7PrdwI3XGwNOgwi/Bon0IvXy9MkQUTZQOKOgT/kq++eTGgjY1EWGQ
# 7w8sSRwQU+3Ko2SMLIkfLPuvOtJ6BWwQbXYHtiMOwjwv9UN9SNu4VaJUuwdMmqN7
# /F9jLVst5rGZV03BMIIF3TCCA8WgAwIBAgIIeyyb0xaAMpkwDQYJKoZIhvcNAQEL
# BQAwfDELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3Vz
# dG9uMRgwFgYDVQQKDA9TU0wgQ29ycG9yYXRpb24xMTAvBgNVBAMMKFNTTC5jb20g
# Um9vdCBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eSBSU0EwHhcNMTYwMjEyMTczOTM5
# WhcNNDEwMjEyMTczOTM5WjB8MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMx
# EDAOBgNVBAcMB0hvdXN0b24xGDAWBgNVBAoMD1NTTCBDb3Jwb3JhdGlvbjExMC8G
# A1UEAwwoU1NMLmNvbSBSb290IENlcnRpZmljYXRpb24gQXV0aG9yaXR5IFJTQTCC
# AiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAPkP3aMrfcvQKv7sZ4Wm5y4b
# unfh4/WvpOz6Sl2RxFdHaxh3a3by/ZPkPQ/CFp4LZsNWlJ4Xg4XOVu/yFv0AYvUi
# CVToZRdOQbngT0aXqhvIuG5iXmmxX9sqAn78bMrzQdjt0Oj8P2FI7bADFB0QDksZ
# 4LtO7IZl/zbzXmcCC52GVWH9ejjt/uIZALdvoVBidXQ8oPrIJZK0bnoix/geoeOy
# 3ZExqysdBP+lSgQ36YWkMyv94tZVNHwZpEpox7Ko07fKoZOI68GXvIz5HdkihCR0
# xwQ9aqkpk8zruFvh/l8lqjRYyMEjVJ0bmBHDOJx+PYZspQ9AhnwC9FwCTyjLrnGf
# DzrIM/4RJTXq/LrFYD3ZfBjVsqnTdXgDciLKOsMf7yzlLqn6niy2UUb9rwPW6mBo
# 6oUWNmuF6R7As93EJNyAKoFBbZQ+yODJgUEAnl6/f8UImKIYLEJAs/lvOCdLToD0
# PYFH4Ih86hzOtXVcUS4cK38acijnALXRdMbX5J+tB5O2UzU1/Dfkw/ZdFr4hc96S
# CvigY2q8lpJqPvi8ZVWb3vUNiSYE/CUapiVpy8JtynziWV+XrOvvLsi81xtZPCvM
# 8hnIk2snYxnP/Okm+Mpxm3+T/jRnhE6Z6/yzeAkzcLpmpnbtG3PrGqUNxCITIJRW
# Ck4sbE6x/c+cCbqiM+2HAgMBAAGjYzBhMB0GA1UdDgQWBBTdBAkHovV6fVJTEpKV
# 7jiAJQ2mWTAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFN0ECQei9Xp9UlMS
# kpXuOIAlDaZZMA4GA1UdDwEB/wQEAwIBhjANBgkqhkiG9w0BAQsFAAOCAgEAIBgR
# lCn7Jp0cHh5wYfGVcpNxJK1ok1iOMq8bs3AD/CUrdIWQPXhq9LmLpZc7tRiRux6n
# +UBbkflVma8eEdBcHadm47GUBwwyOabqG7B52B2ccETjit3E+ZUfijhDPwGFpUen
# PUayvOUiaPd7nNgsPgohyC0zrL/FgZkxdMF1ccW+sfAjRfSda/wZY52jvATGGAsl
# u1OJD7OAUN5F7kR/q5R4ZJjT9ijdh9hwZXT7DrkT66cPYakylszeu+1jTBi7qUD3
# oFRuIIhxdRjqerQ0cuAjJ3dctpDqhiVAq+8zD8ufgr6iIPv2tS0a5sKFsXQP+8hl
# AqRSAUfdSSLBv9jra6x+3uxjMxW3IwiPxg+NQVrdjsW5j+VFP3jbutIbQLH+cU0/
# 4IGiul607BXgk90IH37hVZkLId6Tngr75qNJvTYw/ud3sqB1l7UtgYgXZSD32pAA
# n8lSzDLKNXz1PQ/YK9f1JmzJBjSWFupwWRoyeXkLtoh/D1JIPb9s2KJELtFOt3JY
# 04kTlf5Eq/jXixtunLwsoFvVagCvXzfh1foQC5ichucmj87w7G6KVwuA406ywKBj
# YZC6VWg3dGq2ktufoYYitmUnDuy2n0Jg5GfCtdpBC8TTi2EbvPofkSvXRAdeuims
# 2cXp71NIWuuA8ShYIc2wBlX7Jz9TkHCpBB5XJ7kwggbLMIIEs6ADAgECAhBSnbvC
# uImH9YOA4LDrogY2MA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMQ4wDAYD
# VQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjEYMBYGA1UECgwPU1NMIENvcnBv
# cmF0aW9uMTEwLwYDVQQDDChTU0wuY29tIFJvb3QgQ2VydGlmaWNhdGlvbiBBdXRo
# b3JpdHkgUlNBMB4XDTI2MDYxMjE2NDIxNVoXDTQxMDIxMjE3MzkzOVowcjELMAkG
# A1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYD
# VQQKDAhTU0wgQ29ycDEuMCwGA1UEAwwlU1NMLmNvbSBUaW1lc3RhbXBpbmcgSXNz
# dWluZyBSU0EgQ0EgMjCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAJ8v
# q+ZzTZC8MUabNgd5WlBjVPcu71oiedNd8n9Il8+uW0HcGvW44/Jf0pHl6hxqn0od
# haGnvvNBPJgxH/d6CMI7Mtgl9nF5isarRfByRmAeH+skYShA+dMJGzsrC9NiF3/v
# xGZ2uOI334YVc+DlP5OdsUPz5yIP7hYXNlpPknPwh6gK/pWFZD8+y8uUagfX9USh
# q/SQt+1tS4FXRwudHTSHbGt0Fz4ZbWGbm0d56ROAW34tI6FFuZ+TtGssHjeOUf2F
# S8QNGBpadTh1X1Z7Kl6vG4Z8NS3OJIyelzoF5TpcP2vM3ue0723bmZd3oXsE5rzt
# AJMv56jlg0vSDz8XcXRur6awW0rh5cTQDQQGx04hYJH2Zn9HWWJU/wJ2SKBcQKtB
# yCz6JX+DoFoBE++kolkpZtl2ESF8FY6XqhtKZb18ESEAc0ohCY+0HkBZwrx8eIED
# CDbzd/shv9a8YRG2oxr3tLUz95V+Dzzh1QBNECaeGczyNWGCZIVUa4lVcVUVOBbI
# OAT8D+iPmC5h29bWeES8DhTS4f4CWA4D5QoQqMTqIBcV4MD2Waw8hEWAdGnjnsVt
# DimnDeEUbvXKhdiirvwG+QC+3mAy1RlD6xBMmGyDAKVSqqXm3NP4w0J4gvt65Grk
# QI4FXPJtYqfwkIBtQ8OGfbpVUQGPVUemWtui7E21AgMBAAGjggFRMIIBTTASBgNV
# HRMBAf8ECDAGAQH/AgEAMB8GA1UdIwQYMBaAFN0ECQei9Xp9UlMSkpXuOIAlDaZZ
# ME0GCCsGAQUFBwEBBEEwPzA9BggrBgEFBQcwAoYxaHR0cDovL2NlcnQuc3NsLmNv
# bS9TU0xjb20tUm9vdENBLVJTQS00MDk2LVIxLmNlcjA/BgNVHSAEODA2MDQGBFUd
# IAAwLDAqBggrBgEFBQcCARYeaHR0cHM6Ly93d3cuc3NsLmNvbS9yZXBvc2l0b3J5
# MBMGA1UdJQQMMAoGCCsGAQUFBwMIMEIGA1UdHwQ7MDkwN6A1oDOGMWh0dHA6Ly9j
# cmxzLnNzbC5jb20vU1NMY29tLVJvb3RDQS1SU0EtNDA5Ni1SMS5jcmwwHQYDVR0O
# BBYEFHCaZcFDgKP86bFkiW7xMJwJIcl8MA4GA1UdDwEB/wQEAwIBhjANBgkqhkiG
# 9w0BAQsFAAOCAgEAZRRbzTHpgOogYgWKOeiCkI1oVrkGmCrqOKqX9CiTREQLdYM/
# h7ANki98QP1fhAPEkTzT/Ur19IrPuZg7KaWL6SsmBqmD9+mBVtJmxdRdGbV8bpgl
# FDv2VeZgTSg3+UOD2O0G9HlgHqVHNKzSa/zL5+WYl3yT8Q29sZnIPGkQ+udv56/j
# q5NlAT9BON4iXSOCxe1bNvUd0hkS2GTsTNeQyOEHm7CkZdCg5X+DpmBginO7pk8Y
# m5GbTdQtSloJ3/Y2nVPycJ8kmmBAYMev7/hVQukhjjc4mO03LyPTFfqmMR1D5Tpu
# gGkD9nUuG41l55vOpXQm1JMbTgArpkn0/e9O+yTYlWuz2dSAZHf9jxNQAvILO1Pv
# 2JNQTfV0TyIteZP7gNcRfaHnnuSho8ohipKiE+1vEJIFE+c3gopxSpHCmn2THETk
# lWKV7ZrUKhhkdoOLj2KidCtYZrOoCV6x7f9+KfDPT61fKDVntGZdRKwzLV53VIN6
# oSS+KQN2VJaO8OZTOZpfgO4o6/9xpNr+EEaA3hNkoZk13R4LaqPC/309dfZmHBE8
# nBNjWBkV7AZdzdK8w7B0a/D9066a6oUa19OIktD+3kPpQ8YEt8oRp9zs1hoQ7fRn
# 9sdantP6nYRQFTpF8czGc+FGresbAH819Pv5vBhCluTo8Px2PpC71cM0jzsxggJW
# MIICUgIBATCBhjByMQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNV
# BAcMB0hvdXN0b24xETAPBgNVBAoMCFNTTCBDb3JwMS4wLAYDVQQDDCVTU0wuY29t
# IFRpbWVzdGFtcGluZyBJc3N1aW5nIFJTQSBDQSAyAhBUQ/g3vVruGAGEcrhc2o7j
# MAsGCWCGSAFlAwQCAaCCAWAwGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMBwG
# CSqGSIb3DQEJBTEPFw0yNjExMDUxODAxMDJaMCgGCSqGSIb3DQEJNDEbMBkwCwYJ
# YIZIAWUDBAIBoQoGCCqGSM49BAMCMC8GCSqGSIb3DQEJBDEiBCA3pCspBN/AdVle
# LuT0fUhOWEoGMIbgDz0Fx/mg6tPitDCByAYLKoZIhvcNAQkQAi8xgbgwgbUwgbIw
# ga8EIFdP6heq+l58aiubCMmYsXNeRQs4c8pE5qJMoJMOY/OwMIGKMHakdDByMQsw
# CQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24xETAP
# BgNVBAoMCFNTTCBDb3JwMS4wLAYDVQQDDCVTU0wuY29tIFRpbWVzdGFtcGluZyBJ
# c3N1aW5nIFJTQSBDQSAyAhBUQ/g3vVruGAGEcrhc2o7jMAoGCCqGSM49BAMCBEcw
# RQIhAL7RxuP5SYNSpHpIZoRT6+cDawLId8sI4nMz/sHVbs14AiA7M4sbKYEDiwR0
# Q4YCuw9iZ/gXmdfe3se+nvUqgQNPRQ==
# SIG # End signature block
