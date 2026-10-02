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
