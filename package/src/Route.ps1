<#
    Message Trace Report - routes in the console.

    Write-MtrJourney  the route of the first messages of a small selection (Details.ConsoleMessages),
                      recipients grouped by identical route, problems first, with the reason of each
                      failure and where the routes of the failed and the delivered recipients split
    Write-MtrReasons  why deliveries were not delivered: the reasons found in the routes read, most
                      frequent first
    The routes are analysed by the engine (RouteAnalyzer, src\Engine.Route.cs).
#>

function Format-MtrRouteStep {
    <# One step of a route: time, event (action), what it says. #>
    param([Parameter(Mandatory)][MessageTraceReport.RouteEvent]$Event, [Parameter(Mandatory)][TimeZoneInfo]$Zone, [int]$Width = 100)
    $C = $script:C
    $color = @{ success = $C.Green; danger = $C.Red; warning = $C.Yellow; info = $C.Blue }[$Event.Tone]
    $name = $Event.Event + $(if ($Event.Action) { " ($($Event.Action))" } else { '' })
    $text = if ($Event.Reason -and $Event.Reason.Code -and $Event.Reason.Code[0] -ne '2') { $Event.Reason.Short }
            elseif ($Event.Folder) { "Folder: $($Event.Folder)" }
            elseif ($Event.Help) { $Event.Help }
            else { $Event.Description }
    $time = Format-MtrLocalTime $Event.TimeMs $Zone 'HH:mm:ss'
    return ("{0}{1}{2}  {3}{4}{2}  {5}" -f $C.Dim, $time, $C.Reset, $color, (Format-MtrText $name 22), (Format-MtrText $text ([Math]::Max(20, $Width - 34))).TrimEnd())
}

function Write-MtrReasonBox {
    <# Why a route ended as it did: cause and rule, what it means, code, Learn title, component, remote server, Learn page. #>
    param([Parameter(Mandatory)][MessageTraceReport.RouteInfo]$Route, [string]$Pad = '             ')
    $C = $script:C
    $r = $Route.Reason
    $lines = [Collections.Generic.List[string]]::new()
    if ($Route.Cause) {
        $lines.Add("Cause     $($Route.Cause.Label)")
        if ($Route.Cause.Rule) { $lines.Add("Rule      $($Route.Cause.Rule)") }
        $lines.Add("Help      $(Format-MtrText $Route.Cause.Help 110)".TrimEnd())
    }
    if ($r -and $r.Code -and $r.Code[0] -ne '2') {
        $lines.Add("Why       $($r.Short)")
        if ($r.DocTitle) { $lines.Add("Meaning   $($r.DocTitle)") }
        if ($r.Component) { $lines.Add("Component $($r.Component)") }
        if ($r.RemoteHost -or $r.RemoteIp) { $lines.Add("Remote    $((@($r.RemoteHost, $r.RemoteIp) | Where-Object { $_ }) -join ' ')") }
        if ($r.Detail) { $lines.Add("Detail    $(Format-MtrText $r.Detail 90)".TrimEnd()) }
        if ($r.DocUrl) { $lines.Add("Learn     $($r.DocUrl)") }
    } elseif ($Route.Outcome -like 'Delivered to *' -or $Route.Outcome -eq 'Dropped') {
        $verdict = [MessageTraceReport.RouteAnalyzer]::Verdict($Route)
        $lines.Add("Why       $($Route.Outcome)$(if ($verdict) { " ($verdict)" })")
    }
    $first = $true
    foreach ($line in $lines) {
        $color = if ($first -and $Route.Cause) { @{ danger = $C.Red; warning = $C.Yellow; spam = $C.Blue }[$Route.Cause.Tone] + $C.Bold } else { $C.Dim }
        Write-Host ("{0}{1}{2}{3}" -f $Pad, $color, $line, $C.Reset)
        Write-MtrLog 'INFO' $line
        $first = $false
    }
}

function Write-MtrJourney {
    <#
    .SYNOPSIS
        Route of the first messages of the selection, recipients grouped by identical route:

          📨  2026-09-28 20:01  Quarterly report
              From alice@contoso.com · 3 recipients: Failed 1, Delivered 2
              Route A  ❌  Failed · sydney@contoso.com
                 20:01:05  Receive    Received by Exchange Online
                 20:01:09  Fail       554 5.2.2 mailbox full
                           Why       554 5.2.2 mailbox full ...
              Route B  ✅  Delivered · 2 recipients: adele@contoso.com, alex@contoso.com
                 Receive > Submit > Deliver in 4 s
              Split     same route up to Submit (20:01:06), then Fail for route A, Deliver for route B
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[MessageTraceReport.MessageJourney]]$Journeys, [Parameter(Mandatory)][TimeZoneInfo]$Zone)
    $C = $script:C; $dot = $script:Dot
    $width = [Math]::Min(150, (Get-MtrConsoleWidth) - 1)
    foreach ($j in $Journeys) {
        if (-not $j.Groups.Count) { continue }
        Write-Host ''
        $head = "{0}  {1}" -f (Format-MtrLocalTime $j.ReceivedMs $Zone), $(if ($j.Subject) { $j.Subject } else { '(no subject)' })
        Write-MtrItem Info (Format-MtrText $head ($width - 10)).TrimEnd() -Icon Mail
        $statuses = ($j.Statuses.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ', '
        $line = "From {0} {1} {2} recipient{3}: {4}" -f $j.Sender, $dot, $j.Recipients, $(if ($j.Recipients -gt 1) { 's' } else { '' }), $statuses
        Write-Host ("          {0}{1}{2}" -f $C.Dim, $line, $C.Reset); Write-MtrLog 'INFO' $line
        $line = "Message-ID {0}" -f $j.MessageId
        Write-Host ("          {0}{1}{2}" -f $C.Dim, (Format-MtrText $line ($width - 12)).TrimEnd(), $C.Reset); Write-MtrLog 'INFO' $line

        $problems = @($j.Groups | Where-Object { $_.Status -notin 'Delivered', 'Expanded' })
        foreach ($g in $j.Groups) {
            $problem = $g.Status -notin 'Delivered', 'Expanded'
            $status = if ($g.Status -eq 'Failed') { 'Fail' } elseif ($problem) { 'Warn' } else { 'Ok' }
            $color = @{ Ok = $C.Green; Warn = $C.Yellow; Fail = $C.Red }[$status]
            $who = if ($g.Recipients.Count -eq 1) { $g.Recipients[0] }
                   else { "{0} recipients: {1}{2}" -f $g.Recipients.Count, (($g.Recipients | Select-Object -First 3) -join ', '), $(if ($g.Recipients.Count -gt 3) { " +$($g.Recipients.Count - 3)" } else { '' }) }
            $outcome = if ($g.Route.Cause) { "$($g.Status): $($g.Route.Cause.Label)" } elseif ($g.Route.Outcome -and $g.Route.Outcome -ne $g.Status) { "$($g.Status) ($($g.Route.Outcome))" } else { $g.Status }
            $title = "Route {0}  {1} {2} {3}" -f $g.Letter, $outcome, $dot, $who
            Write-Host ("          {0}{1}{2}{3}{4}" -f $color, (Get-MtrIcon $status), $C.Reset, $C.Bold, (Format-MtrText $title ($width - 14)).TrimEnd()) -NoNewline
            Write-Host $C.Reset
            Write-MtrLog 'INFO' $title
            $seconds = ($g.Route.LastMs - $g.Route.FirstMs) / 1000.0
            if ($problem -or -not $problems.Count) {
                foreach ($e in $g.Route.Events) {
                    $step = Format-MtrRouteStep -Event $e -Zone $Zone -Width ($width - 13)
                    Write-Host ("             {0}" -f $step)
                    Write-MtrLog 'INFO' ($step -replace "$([char]27)\[[0-9;]*m", '')
                }
                Write-MtrReasonBox -Route $g.Route
            } else {
                $line = "{0} in {1}" -f $g.Route.Summary, (Format-MtrDuration $seconds)
                Write-Host ("             {0}{1}{2}" -f $C.Dim, $line, $C.Reset); Write-MtrLog 'INFO' $line
            }
        }
        # Where the route of the first problem and the route of the first delivery split.
        $delivered = @($j.Groups | Where-Object { $_.Status -eq 'Delivered' })
        if ($problems.Count -and $delivered.Count) {
            $a = $problems[0]; $b = $delivered[0]
            $n = 0
            while ($n -lt $a.Route.Events.Count -and $n -lt $b.Route.Events.Count -and
                   $a.Route.Events[$n].Event -eq $b.Route.Events[$n].Event -and $a.Route.Events[$n].Action -eq $b.Route.Events[$n].Action) { $n++ }
            $next = { param($g, $i) if ($i -lt $g.Route.Events.Count) { $g.Route.Events[$i].Event + $(if ($g.Route.Reason -and $g.Route.Reason.Code -and $g.Route.Reason.Code[0] -ne '2' -and $g.Route.Events[$i].Kind -in 'failed', 'deferred') { " ($($g.Route.Reason.Smtp) $($g.Route.Reason.Code))".Replace('( ', '(') } else { '' }) } else { 'nothing more' } }
            $line = if ($n -gt 0) {
                $last = $a.Route.Events[$n - 1]
                "Split     same route up to {0} ({1}), then {2} for route {3}, {4} for route {5}" -f $last.Event, (Format-MtrLocalTime $last.TimeMs $Zone 'HH:mm:ss'), (& $next $a $n), $a.Letter, (& $next $b $n), $b.Letter
            } else { "Split     the routes differ from the first step" }
            Write-Host ("          {0}{1}{2}{3}" -f $C.Cyan, (Get-MtrIcon 'Route'), $C.Reset, (Format-MtrText $line ($width - 14)).TrimEnd())
            Write-MtrLog 'INFO' $line
        }
        if ($j.NotRead.Count) {
            $line = "Route not read for {0} recipient{1}: {2}{3}" -f $j.NotRead.Count, $(if ($j.NotRead.Count -gt 1) { 's' } else { '' }), (($j.NotRead | Select-Object -First 3) -join ', '), $(if ($j.NotRead.Count -gt 3) { " +$($j.NotRead.Count - 3)" } else { '' })
            Write-Host ("          {0}{1}{2}" -f $C.Dim, (Format-MtrText $line ($width - 12)).TrimEnd(), $C.Reset); Write-MtrLog 'INFO' $line
        }
    }
}

function Write-MtrReasons {
    <# Why deliveries were not delivered: the causes and reasons found in the routes read, most frequent first. #>
    param([Parameter(Mandatory)][MessageTraceReport.ReportResult]$Report, [int]$Top = 8)
    if (-not $Report.Reasons.Count) { return }
    $rows = foreach ($r in ($Report.Reasons | Select-Object -First $Top)) {
        $rule = if ($r.Cause -match '^(?<label>.+?) \((?<rule>(rule|policy) .+)\)$') { $Matches.rule } else { '' }
        [pscustomobject]@{
            Status     = @{ danger = 'Fail'; warning = 'Warn'; spam = 'Warn' }[$r.Tone]
            Deliveries = Format-MtrNumber $r.Deliveries
            Messages   = Format-MtrNumber $r.Messages
            Cause      = if ($rule) { $Matches.label } else { $r.Cause }
            Reason     = $r.Reason + $(if ($r.Component) { " [$($r.Component)]" } else { '' }) + $(if ($rule) { " $($script:Dot) $rule" } else { '' })
        }
    }
    $causeWidth = [Math]::Min(36, [Math]::Max(14, ($rows | ForEach-Object { $_.Cause.Length } | Measure-Object -Maximum).Maximum))
    Write-MtrTable -Columns @(
        @{ Name = 'Deliveries'; Property = 'Deliveries'; Width = 10; Align = 'Right' }
        @{ Name = 'Messages'; Property = 'Messages'; Width = 8; Align = 'Right' }
        @{ Name = 'Cause'; Property = 'Cause'; Width = $causeWidth }
        @{ Name = 'Reason (status code)'; Property = 'Reason'; Width = 0 }
    ) -Rows @($rows)
    if ($Report.Reasons.Count -gt $Top) { Write-MtrItem Skip ("{0} other reasons: see the HTML report or the Deliveries CSV file (Cause and Reason columns)." -f ($Report.Reasons.Count - $Top)) }
}

# SIG # Begin signature block
# MIImIgYJKoZIhvcNAQcCoIImEzCCJg8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAhTKNKXS8rf9Lj
# aCO7aJEb2+YL3WOKM7ZFgxfTnWIlsaCCDW8wggZyMIIEWqADAgECAghkM1HTxzif
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
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCA62JQZfJjz
# SBIy1l3iQ0M++dCAgS9DF64nvFcU+qP2qzANBgkqhkiG9w0BAQEFAASCAgBMpdoi
# 8dTnsvZ8lEwVL8jFedDrmlXeriybUnZJ+4hXpVBtllyKd6ji1v4tGJwT2u41s1CR
# r3iPLzpmLjjcU/W2wALjeiq3EqDzyvJOHWoo/cXVSV/UpjfBnxWeD0hWZwhGG4cL
# l+uvZalen9lksmflm2nRmNpcXjq3JFnJrLeZ+fYjq7PsonN3qjQIqpNRf8jhQfE2
# MfowWM/cHAEd1DONGlFcVrfnTgYudbk6T2CwffHmPPEs16tfg/P4rvHouo/5tnd4
# EFbxNMhn1baGszk3R/LSJ8X8s3g/v/vSTRX0entJE7tBlT7M6e7V+l8f+1nX0WZW
# yNBiILZzz0MJYx5ez8g6BCjmGqdCHIySfvvq4nZ+h8lVEK2n5dV2XYPuGU9vDVwn
# LeWLVeedydiyKU1zz7NmCnon/t+YI4Ka7bjos70Nzbnh8NCTvVS/RWjj52tgwhyL
# KW9wJ8uNM4pY+8lWINTsM36aFHw9vX9seHvdn7P37FVJNyO0gkNRbpF97sw90nMr
# +OfjtLcu3r9eOgHw5Hl7U2XU4d/PcLH9Zkou/f67d2/oeuLNldTGhHygtwX3GJd5
# 66GC4D9tR3suKK5urLj7/vmyll5+9KpB/Fl1LuHDMJg9HC0ab2Awz9yRK7gXmX47
# WgKBWdSQI2P56ATA9RHe4wjfLtkRhFHmSAk4DqGCFMYwghTCBgorBgEEAYI3AwMB
# MYIUsjCCFK4GCSqGSIb3DQEHAqCCFJ8wghSbAgEDMQ0wCwYJYIZIAWUDBAIBMIGB
# BgsqhkiG9w0BCRABBKByBHAwbgIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEIODTL7DJSwxnUE/TINxwJ3AORkqHBoAV5W3X5zQvrouUAghEo/hhQuvA
# 9xgPMjAyNjExMDUxODAxMDFaMAMCAQECCBXZsG13jCftoIIRpzCCBPMwggLboAMC
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
# CSqGSIb3DQEJBTEPFw0yNjExMDUxODAxMDFaMCgGCSqGSIb3DQEJNDEbMBkwCwYJ
# YIZIAWUDBAIBoQoGCCqGSM49BAMCMC8GCSqGSIb3DQEJBDEiBCA1Fn9oCqcEAyDS
# kkrbzryY6B9kG8BjMC62ODKCFP63hjCByAYLKoZIhvcNAQkQAi8xgbgwgbUwgbIw
# ga8EIFdP6heq+l58aiubCMmYsXNeRQs4c8pE5qJMoJMOY/OwMIGKMHakdDByMQsw
# CQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24xETAP
# BgNVBAoMCFNTTCBDb3JwMS4wLAYDVQQDDCVTU0wuY29tIFRpbWVzdGFtcGluZyBJ
# c3N1aW5nIFJTQSBDQSAyAhBUQ/g3vVruGAGEcrhc2o7jMAoGCCqGSM49BAMCBEcw
# RQIgOGK9JIfDG48kWDc7M5quAr3yc21w/yDFvvbneKqcv5cCIQDwol2EA9JCkvFx
# feS79g1QgaBNhd5ADp4yimKl0YL33A==
# SIG # End signature block
