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
