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
