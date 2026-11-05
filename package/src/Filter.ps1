<#
    Message Trace Report - periods, filters and the query plan.

    Resolve-MtrPeriod      range name or dates -> [start, end) in Unix ms
    Read-MtrAddressFile    addresses from a CSV (column detected) or a text file (one per line)
    New-MtrFilter          the user's filter, checked -> [MessageTraceReport.FilterSpec]
    Get-MtrQueryPlan       filter -> Graph queries (engine: Planner.Plan)
    Get-MtrWorkPlan        queries x period, minus what the database holds -> work items (Planner.Windows)
#>

function ConvertTo-MtrUnixMs {
    <#
    .SYNOPSIS
        Text date -> Unix ms. Without an explicit offset (Z, +02:00) the date is read in the report time zone.
        Accepts yyyy-MM-dd, 'yyyy-MM-dd HH:mm[:ss]', ISO 8601, and the invariant text of a [datetime]
        ('10/02/2026 14:00:00', what PowerShell makes of (Get-Date) passed to a string parameter).
    #>
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][TimeZoneInfo]$Zone)
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $Text = $Text.Trim()
    if ($Text -match '(Z|[+-]\d{2}:?\d{2})$') { return [DateTimeOffset]::Parse($Text, $culture).ToUnixTimeMilliseconds() }
    $formats = [string[]]@('yyyy-MM-dd', 'yyyy-MM-dd HH:mm', 'yyyy-MM-ddTHH:mm', 'yyyy-MM-dd HH:mm:ss', 'yyyy-MM-ddTHH:mm:ss', 'yyyy-MM-ddTHH:mm:ss.fff', 'MM/dd/yyyy HH:mm:ss', 'MM/dd/yyyy')
    $local = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($Text, $formats, $culture, [Globalization.DateTimeStyles]::None, [ref]$local)) {
        throw "Invalid date '$Text'. Use yyyy-MM-dd, 'yyyy-MM-dd HH:mm' or an ISO 8601 value with an offset."
    }
    return [MessageTraceReport.Time]::LocalToUnixMs($local, $Zone)
}

function Resolve-MtrPeriod {
    <#
    .SYNOPSIS
        Converts a range name or dates into a [start, end) period in Unix milliseconds.
    .DESCRIPTION
        Last24Hours, Last48Hours, Last7Days, Last10Days, Last30Days, Last90Days : rolling windows ending now.
        Today, Yesterday, Day (-Date yyyy-MM-dd) : calendar days in the report time zone.
        Custom (-Start, and -End or now). The end is never later than now.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Last24Hours', 'Last48Hours', 'Last7Days', 'Last10Days', 'Last30Days', 'Last90Days', 'Today', 'Yesterday', 'Day', 'Custom')][string]$Range,
        [string]$Date, [string]$Start, [string]$End,
        [Parameter(Mandatory)][TimeZoneInfo]$Zone,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )
    if (-not $Range) { $Range = if ($Start) { 'Custom' } elseif ($Date) { 'Day' } else { 'Last48Hours' } }
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $nowMs = $Now.ToUnixTimeMilliseconds(); $nowMs -= $nowMs % 1000
    $hour = 3600000L; $day = 86400000L
    $today = [TimeZoneInfo]::ConvertTime($Now, $Zone).DateTime.Date
    switch ($Range) {
        'Last24Hours' { $s = $nowMs - $day; $e = $nowMs }
        'Last48Hours' { $s = $nowMs - 2 * $day; $e = $nowMs }
        'Last7Days' { $s = $nowMs - 7 * $day; $e = $nowMs }
        'Last10Days' { $s = $nowMs - 10 * $day; $e = $nowMs }
        'Last30Days' { $s = $nowMs - 30 * $day; $e = $nowMs }
        'Last90Days' { $s = $nowMs - 90 * $day + $hour; $e = $nowMs }
        'Today' { $s = [MessageTraceReport.Time]::LocalToUnixMs($today, $Zone); $e = $nowMs }
        'Yesterday' { $s = [MessageTraceReport.Time]::LocalToUnixMs($today.AddDays(-1), $Zone); $e = [MessageTraceReport.Time]::LocalToUnixMs($today, $Zone) }
        'Day' {
            $d = [datetime]::MinValue
            if (-not $Date -or -not [datetime]::TryParseExact($Date, 'yyyy-MM-dd', $culture, 'None', [ref]$d)) { throw '-Range Day requires -Date in the format yyyy-MM-dd.' }
            $s = [MessageTraceReport.Time]::LocalToUnixMs($d, $Zone); $e = [MessageTraceReport.Time]::LocalToUnixMs($d.AddDays(1), $Zone)
        }
        'Custom' {
            if (-not $Start) { throw '-Range Custom requires -Start (and -End, default: now).' }
            $s = ConvertTo-MtrUnixMs $Start $Zone
            $e = if ($End) { ConvertTo-MtrUnixMs $End $Zone } else { $nowMs }
        }
    }
    if ($e -gt $nowMs) { $e = $nowMs }
    if ($e -le $s) { throw "The requested period is empty or in the future ($Range)." }
    [pscustomobject]@{ Range = $Range; StartMs = [long]$s; EndMs = [long]$e }
}

function Get-MtrEarliestMs {
    <# Oldest instant the Graph API still returns: 00:00 UTC, SourceHistoryDays days ago (lab: today-90 days at 00:00 UTC is accepted). #>
    param([int]$Days = 90, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)
    return [DateTimeOffset]::new($Now.UtcDateTime.Date.AddDays(-$Days), [TimeSpan]::Zero).ToUnixTimeMilliseconds()
}

function Read-MtrAddressFile {
    <#
    .SYNOPSIS
        Addresses from a file.
          .txt (or any other extension): one address per line; empty lines and lines starting with # are ignored.
          .csv: delimiter ; or , detected; column -Column, else the first of Email, EmailAddress,
                PrimarySmtpAddress, WindowsEmailAddress, SmtpAddress, Address, Mail, UserPrincipalName,
                else the first column.
    #>
    param([Parameter(Mandatory)][string]$Path, [string]$Column)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Address file not found: $Path" }
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    if ([IO.Path]::GetExtension($full) -ne '.csv') {
        return @(Get-Content -LiteralPath $full -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    }
    $first = Get-Content -LiteralPath $full -TotalCount 1 -Encoding UTF8
    if (-not $first) { return @() }
    $delimiter = if (($first.Split(';').Count) -gt ($first.Split(',').Count)) { ';' } else { ',' }
    $rows = @(Import-Csv -LiteralPath $full -Delimiter $delimiter -Encoding UTF8)
    if (-not $rows.Count) { return @() }
    $names = @($rows[0].PSObject.Properties.Name)
    if ($Column) {
        $name = $names | Where-Object { $_ -ieq $Column } | Select-Object -First 1
        if (-not $name) { throw "Column '$Column' not found in $full (columns: $($names -join ', '))." }
    } else {
        $name = foreach ($candidate in 'Email', 'EmailAddress', 'PrimarySmtpAddress', 'WindowsEmailAddress', 'SmtpAddress', 'Address', 'Mail', 'UserPrincipalName') {
            $match = $names | Where-Object { $_ -ieq $candidate } | Select-Object -First 1
            if ($match) { $match; break }
        }
        if (-not $name) { $name = $names[0] }
    }
    return @($rows | ForEach-Object { "$($_.$name)".Trim() } | Where-Object { $_ })
}

function New-MtrFilter {
    <#
    .SYNOPSIS
        Checks the user's filter and returns a [MessageTraceReport.FilterSpec].
    .DESCRIPTION
        Addresses: exact SMTP addresses, or *@domain (applied by Graph). Other patterns with * (john*@...)
        are accepted with -AllowPatterns only (Report mode: the database is filtered locally).
        Status: Delivered, Failed, Pending, Expanded, Quarantined, FilteredAsSpam, GettingStatus.
        Message ID: with or without the angle brackets.
        All problems are reported together.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Sender, [string[]]$Recipient, [string]$SenderFile, [string]$RecipientFile, [string]$FileColumn,
        [ValidateSet('And', 'Or')][string]$Operator = 'And',
        [string]$Subject, [ValidateSet('Contains', 'StartsWith', 'EndsWith', 'Equals')][string]$SubjectMatch = 'Contains',
        [string[]]$Status, [string[]]$MessageId, [string]$FromIP, [string]$ToIP,
        [switch]$AllowPatterns
    )
    $errors = [Collections.Generic.List[string]]::new()
    $f = [MessageTraceReport.FilterSpec]::new()
    $split = { param($values) @($values | ForEach-Object { "$_" -split '[,;\s]+' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $addresses = {
        param([string]$Kind, $Values, [string]$File)
        $list = [Collections.Generic.List[string]]::new()
        $raw = @(& $split $Values)
        if ($File) { try { $raw += @(Read-MtrAddressFile -Path $File -Column $FileColumn) } catch { $errors.Add($_.Exception.Message) } }
        $bad = [Collections.Generic.List[string]]::new()
        foreach ($value in $raw) {
            $a = [MessageTraceReport.Address]::Normalize($value)
            if (-not $a) { continue }
            if ([MessageTraceReport.Address]::IsAddress($a) -or [MessageTraceReport.Address]::IsDomainWildcard($a) -or ($AllowPatterns -and [MessageTraceReport.Address]::IsPattern($a))) {
                if (-not $list.Contains($a)) { $list.Add($a) }
            } else { $bad.Add($value) }
        }
        if ($bad.Count) {
            $hint = if (@($bad | Where-Object { $_ -like '*`**' }).Count -and -not $AllowPatterns) { " Graph applies only *@domain; other patterns work with -Mode Report (local database)." } else { '' }
            $errors.Add(("{0}: {1} value(s) not valid: {2}{3}.{4}" -f $Kind, $bad.Count, (($bad | Select-Object -First 5) -join ', '), $(if ($bad.Count -gt 5) { ', ...' } else { '' }), $hint))
        }
        return , $list
    }
    foreach ($a in (& $addresses 'Sender' $Sender $SenderFile)) { $f.Senders.Add($a) }
    foreach ($a in (& $addresses 'Recipient' $Recipient $RecipientFile)) { $f.Recipients.Add($a) }
    $f.OrMode = $Operator -eq 'Or'
    if ($Subject) {
        if ($Subject.Contains('*')) { $errors.Add("Subject: no wildcard - use -SubjectMatch Contains, StartsWith, EndsWith or Equals.") }
        $f.Subject = $Subject; $f.SubjectMatch = $SubjectMatch
    }
    foreach ($s in (& $split $Status)) {
        $known = [MessageTraceReport.Planner]::KnownStatuses | Where-Object { $_ -ieq $s -or ($s -ieq 'Spam' -and $_ -eq 'filteredAsSpam') } | Select-Object -First 1
        if ($known) { if (-not $f.Statuses.Contains($known)) { $f.Statuses.Add($known) } }
        else { $errors.Add("Status '$s' unknown. Use: $([MessageTraceReport.Planner]::KnownStatuses -join ', ').") }
    }
    foreach ($m in @($MessageId | ForEach-Object { "$_".Trim() } | Where-Object { $_ })) {
        $v = if ($m.StartsWith('<')) { $m } else { "<$m>" }
        if (-not $f.MessageIds.Contains($v)) { $f.MessageIds.Add($v) }
    }
    foreach ($ip in @(@{ Name = 'FromIP'; Value = $FromIP }, @{ Name = 'ToIP'; Value = $ToIP })) {
        if (-not $ip.Value) { continue }
        $parsed = $null
        if (-not [Net.IPAddress]::TryParse($ip.Value.Trim(), [ref]$parsed)) { $errors.Add("$($ip.Name) '$($ip.Value)' is not an IP address.") }
    }
    if ($FromIP) { $f.FromIP = $FromIP.Trim() }
    if ($ToIP) { $f.ToIP = $ToIP.Trim() }
    if ($errors.Count) { throw ("Invalid filter:`n - " + ($errors -join "`n - ")) }
    return $f
}

function Get-MtrQueryPlan {
    <# Graph queries for a filter (see Engine.Plan.cs, Planner.Plan). #>
    param([Parameter(Mandatory)][MessageTraceReport.FilterSpec]$Filter)
    return [MessageTraceReport.Planner]::Plan($Filter)
}

function Get-MtrWorkPlan {
    <#
    .SYNOPSIS
        What must be collected: every query on the period, minus what the database already holds and has
        settled (Collection.SettlingHours), minus what is older than the Graph history; in windows of at
        most Collection.WindowHours, newest first. -Refresh ignores the database.
    #>
    param(
        [Parameter(Mandatory)]$Store, [Parameter(Mandatory)]$QueryPlan, [Parameter(Mandatory)]$Period, [Parameter(Mandatory)]$Settings,
        [switch]$Refresh, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )
    $c = $Settings.Collection
    # Not "$known = if (...)": PowerShell would unroll an empty list into $null.
    $known = [Collections.Generic.List[MessageTraceReport.KnownCoverage]]::new()
    if (-not $Refresh -and $Store) { $known = $Store.GetKnownCoverage([long]$c.SettlingHours * 3600000, $Period.StartMs, $Period.EndMs) }
    $earliest = Get-MtrEarliestMs -Days $c.SourceHistoryDays -Now $Now
    return [MessageTraceReport.Planner]::Windows($QueryPlan.Queries, $known, $Period.StartMs, $Period.EndMs, $earliest, [long]$c.WindowHours * 3600000, [long]$c.BroadWindowHours * 3600000, 2 * $c.MaxConcurrency)
}

# SIG # Begin signature block
# MIImIwYJKoZIhvcNAQcCoIImFDCCJhACAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAwbOq3+x0aw++i
# CJyWm4ujCZGDrfWdcxQDBW9Fb8h2daCCDW8wggZyMIIEWqADAgECAghkM1HTxzif
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
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCBpt9D0ygJQ
# yA8D82o/FIQa7M2/QYTIcJqVkMRyS35JFjANBgkqhkiG9w0BAQEFAASCAgCqlT7q
# yVOffeA33zjzYcsjTGcCjO9gYeOOoWkpIdGT2nSb8+ssMQrVixjEiWCgjTPDS2zQ
# iOVdFDXlPee3CtxlyVa1TWQuDEoN4HIyzYgM0615oyxHl56TvtmL5g1HBCMZK/Ps
# nQjuuTtS1H5WKa2nRfOTh+GYiJhGoH7eiFoaKXgG0eynneFjoa9EUTTE7e4B+hZj
# c70n1iZfb+PAn3cHcW7NstJ2rW8w1b0Pq5Fr/DwdfCRNhiUE+aNBsKraR5Vs1Zp8
# H3CEri+Sw49WpIna6t0wTXf/j3CXr4YTsr3IiqMYEU77Tg8uHUoB6Osmqe+G986+
# DMacVf1AmveQeqcazeFS4A06uY4+bdWujK7rDMzZhrdDeB31KiNLx7ja+wW/UT/C
# YTNo/oI9GxdS9UWsVjYU3ttUgPll7EuvjJRtrtDURL+mZpbeaxNo+sGcjc6/VMyO
# Xkf7wXvb2ml4vIvkEJ/n+OgiwfsKkZDMaW8ORbWduos5v8Rg1G2XyQF8wwFYV95f
# B8MF9nfEK4Pc1OCy9Qm4eSNyvoB+OXRk+QkmvCz10NuRhV4sPKjqbtUddVv+H9og
# XzQw2ZLSjxot1FDwDXkoS/jgoDGgD4gHjcNnGF4Qo/6MzPeN9D/fInu9/cw5qwfn
# u8DxpiTcNoKJcyqgvXtuSjALix8H9AlgXr9MqKGCFMcwghTDBgorBgEEAYI3AwMB
# MYIUszCCFK8GCSqGSIb3DQEHAqCCFKAwghScAgEDMQ0wCwYJYIZIAWUDBAIBMIGC
# BgsqhkiG9w0BCRABBKBzBHEwbwIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEIFEAitDb8IJLUQVAaHoDgh1/OH4uXhk7fGuCXw/oBZvdAgggGun10Wco
# 3RgPMjAyNjExMDUxODAxMDBaMAMCAQECCQChoiBkZA8OIaCCEacwggTzMIIC26AD
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
# BgkqhkiG9w0BCQUxDxcNMjYxMTA1MTgwMTAwWjAoBgkqhkiG9w0BCTQxGzAZMAsG
# CWCGSAFlAwQCAaEKBggqhkjOPQQDAjAvBgkqhkiG9w0BCQQxIgQgL/cdxuVMqp1V
# vVP9YXGsDXaCdEN7dCKHGP11V3FONyEwgcgGCyqGSIb3DQEJEAIvMYG4MIG1MIGy
# MIGvBCBXT+oXqvpefGormwjJmLFzXkULOHPKROaiTKCTDmPzsDCBijB2pHQwcjEL
# MAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREw
# DwYDVQQKDAhTU0wgQ29ycDEuMCwGA1UEAwwlU1NMLmNvbSBUaW1lc3RhbXBpbmcg
# SXNzdWluZyBSU0EgQ0EgMgIQVEP4N71a7hgBhHK4XNqO4zAKBggqhkjOPQQDAgRH
# MEUCIHPPbIoLRcgXkvtXQzoIAYG5wVbigrAj9iwNCw5Q4fLRAiEA4Z11oHTy8Th4
# 4JRRaidpscHjOUu+ich0w8dlBDTl4M4=
# SIG # End signature block
