#Requires -Version 7.4

<#
.SYNOPSIS
    Message Trace Report - Exchange Online message trace through Microsoft Graph, with a local SQLite
    history: ad hoc traces of a few addresses, scheduled collection of the whole tenant, CSV / JSON / HTML
    reports.

.DESCRIPTION
    Four modes:

      TRACE    (default) Messages of a period matching a filter (senders, recipients, subject, status,
               message ID, IP). The tool collects from Microsoft Graph ONLY what the local database does
               not hold yet, then writes the report. Running the same trace again is immediate.
      COLLECT  Scheduled task: collects the last days (Collect.Days) of the whole tenant - or of the scope
               set in the Collect section of the configuration - into the database. Missing and recent
               (not yet settled) periods only. Keeps the history beyond the 90 days of Graph.
      REPORT   Report from the database only (no connection). Accepts any address pattern (john*@contoso.com).
      STATUS   What the database holds, day by day, and the last runs. No connection.

    How the requests are planned (the Graph API keeps ONE value per property in $filter and ignores 'or'):
    one query per address of the shorter list, windows of up to 10 days, never more than the quota of
    100 requests per 5 minutes per tenant (Throttling.MaxRequests, 90 by default). The full filter is then
    applied to the database, so the report is exact.

    Everything is set in config\MessageTraceReport.config.psd1; the command line chooses what to trace.
    The tool is read-only for Microsoft 365: it only calls the message trace API.

.PARAMETER Mode
    Trace (default), Collect, Report or Status.

.PARAMETER Range
    Period: Last24Hours, Last48Hours, Last7Days, Last10Days, Last30Days, Last90Days, Today, Yesterday,
    Day (-Date), Custom (-Start / -End). Default: Report.DefaultRange (Last48Hours).

.PARAMETER Start
    Start of the period (Custom). yyyy-MM-dd, 'yyyy-MM-dd HH:mm' in the report time zone, or ISO 8601 with
    an offset. Alias -StartDate (name used by Invoke-MessageTraceGraph.ps1).

.PARAMETER End
    End of the period (Custom). Default: now. Alias -EndDate.

.PARAMETER Date
    Day (-Range Day), yyyy-MM-dd.

.PARAMETER Sender
    Sender addresses, or *@domain. Several values: -Sender a@contoso.com, b@contoso.com. Alias -Senders.

.PARAMETER Recipient
    Recipient addresses, or *@domain. Alias -Recipients.

.PARAMETER SenderFile
    File of sender addresses: .csv (column Email, PrimarySmtpAddress, ... detected, or -FileColumn) or .txt
    (one per line). Alias -SendersCsv.

.PARAMETER RecipientFile
    File of recipient addresses. Alias -RecipientsCsv.

.PARAMETER FileColumn
    Column of the CSV files holding the addresses. Alias -CsvEmailColumn.

.PARAMETER Operator
    And (default): sender in -Sender AND recipient in -Recipient. Or: sender in -Sender OR recipient in -Recipient.

.PARAMETER Subject
    Text of the subject (case-insensitive), compared with -SubjectMatch.

.PARAMETER SubjectMatch
    Contains (default), StartsWith, EndsWith or Equals.

.PARAMETER Status
    Delivery status: Delivered, Failed, Pending, Expanded, Quarantined, FilteredAsSpam, GettingStatus.

.PARAMETER MessageId
    Internet Message-ID(s), with or without < >.

.PARAMETER FromIP
    Source IP address (sending server).

.PARAMETER ToIP
    Destination IP address (outbound messages).

.PARAMETER IncludeDetails
    Also reads the route of the deliveries (getDetailsByRecipient): failed / pending / quarantined first,
    up to Details.MaxDeliveries. Shown in the HTML report. Overrides Details.Enabled.

.PARAMETER Format
    Overrides Report.Formats: Csv, Html, Json.

.PARAMETER OutputPath
    Overrides Report.OutputPath (a sub-folder is created per run).

.PARAMETER GridView
    Also shows the messages in Out-GridView (interactive session).

.PARAMETER Open
    Opens the HTML report at the end.

.PARAMETER Refresh
    Trace: collects the whole period again, even what the database already holds.

.PARAMETER Force
    Runs a plan above Collection.MaxQueries queries.

.PARAMETER ConfigPath
    Configuration file. Default: config\MessageTraceReport.config.psd1 next to this script.

.EXAMPLE
    .\Invoke-MessageTraceReport.ps1 -Sender john@contoso.com
    Messages sent by John in the last 48 hours: CSV and HTML files in reports\.

.EXAMPLE
    .\Invoke-MessageTraceReport.ps1 -Recipient *@fabrikam.com -Range Last7Days -Status Failed
    Failed messages to Fabrikam over 7 days.

.EXAMPLE
    .\Invoke-MessageTraceReport.ps1 -SenderFile .\vip.csv -Recipient *@gmail.com -Start 2026-09-01 -End 2026-09-30
    Messages of the VIP list to Gmail in September: one query per VIP and per 10 days; the domain is checked locally.

.EXAMPLE
    .\Invoke-MessageTraceReport.ps1 -Sender alerts@contoso.com -Recipient helpdesk@contoso.com -Operator Or -IncludeDetails -Open
    Messages from OR to these addresses, with the route of the failed ones, report opened at the end.

.EXAMPLE
    .\Invoke-MessageTraceReport.ps1 -Mode Collect
    Scheduled task: collects the last days of the tenant into the database (incremental).

.EXAMPLE
    .\Invoke-MessageTraceReport.ps1 -Mode Report -Range Last30Days -Sender 'sales-*@contoso.com'
    Report from the database only, with a pattern (no connection to Microsoft 365).

.EXAMPLE
    .\Invoke-MessageTraceReport.ps1 -Mode Status
    What the database holds, day by day, and the last runs.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.0.0
    Exit codes : 0 = success, 1 = failure, 2 = finished but incomplete (see the summary).
    Documentation : docs\MessageTraceReport-Guide.md (or .html)
#>
[CmdletBinding()]
param(
    [ValidateSet('Trace', 'Collect', 'Report', 'Status')]
    [string]$Mode = 'Trace',

    [ValidateSet('Last24Hours', 'Last48Hours', 'Last7Days', 'Last10Days', 'Last30Days', 'Last90Days', 'Today', 'Yesterday', 'Day', 'Custom')]
    [string]$Range,
    [Alias('StartDate')][string]$Start,
    [Alias('EndDate')][string]$End,
    [string]$Date,

    [Alias('Senders')][string[]]$Sender,
    [Alias('Recipients')][string[]]$Recipient,
    [Alias('SendersCsv')][string]$SenderFile,
    [Alias('RecipientsCsv')][string]$RecipientFile,
    [Alias('CsvEmailColumn')][string]$FileColumn,
    [ValidateSet('And', 'Or')][string]$Operator = 'And',
    [string]$Subject,
    [ValidateSet('Contains', 'StartsWith', 'EndsWith', 'Equals')][string]$SubjectMatch = 'Contains',
    [ArgumentCompletions('Delivered', 'Failed', 'Pending', 'Expanded', 'Quarantined', 'FilteredAsSpam', 'GettingStatus')]
    [string[]]$Status,
    [string[]]$MessageId,
    [string]$FromIP,
    [string]$ToIP,

    [switch]$IncludeDetails,
    [ValidateSet('Csv', 'Html', 'Json')][string[]]$Format,
    [string]$OutputPath,
    [switch]$GridView,
    [switch]$Open,
    [switch]$Refresh,
    [switch]$Force,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config\MessageTraceReport.config.psd1')
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
# Numbers and dates are displayed the same way on every computer (1,234.5), whatever the regional settings.
$previousCulture = [Threading.Thread]::CurrentThread.CurrentCulture
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
$clock = [Diagnostics.Stopwatch]::StartNew()
$exitCode = 1
$runStatus = 'Failed'
$store = $null; $lock = $null; $runId = $null; $runError = $null
$collect = $null; $workPlan = $null; $queryPlan = $null

try {
    # do { } while ($false): 'break' ends the execution early; the finally block always runs.
    do {
        Import-Module (Join-Path $PSScriptRoot 'MessageTraceReport.psd1') -Force
        $settings = Import-MtrConfiguration -Path $ConfigPath -Root $PSScriptRoot
        if ($OutputPath) { $settings.Report.OutputPath = [IO.Path]::GetFullPath($OutputPath, (Get-Location).Path) }
        if ($Format) { $settings.Report.Formats = @($Format) }
        if ($PSBoundParameters.ContainsKey('IncludeDetails')) { $settings.Details.Enabled = [bool]$IncludeDetails }
        $zone = $settings.Zone
        $dot = [char]0x00B7; $arrow = [char]0x2192
        $logPath = Start-MtrLog -Directory $settings.Logging.Path -RetentionDays $settings.Logging.RetentionDays
        Initialize-MtrEngine -Root $PSScriptRoot
        $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

        # ---------------------------------------------------------------------------------------------
        # Filter and period
        # ---------------------------------------------------------------------------------------------
        if ($Mode -in 'Collect', 'Status') {
            $co = $settings.Collect
            $filter = New-MtrFilter -Sender $co.Senders -Recipient $co.Recipients -SenderFile $co.SenderFile -RecipientFile $co.RecipientFile -Operator $co.Operator
            $period = [pscustomobject]@{ Range = "Last $($co.Days) day(s)"; StartMs = ($nowMs - $nowMs % 1000) - [long]$co.Days * 86400000; EndMs = $nowMs - $nowMs % 1000 }
        } else {
            $filter = New-MtrFilter -Sender $Sender -Recipient $Recipient -SenderFile $SenderFile -RecipientFile $RecipientFile -FileColumn $FileColumn -Operator $Operator `
                -Subject $Subject -SubjectMatch $SubjectMatch -Status $Status -MessageId $MessageId -FromIP $FromIP -ToIP $ToIP -AllowPatterns:($Mode -eq 'Report')
            if (-not $Range -and -not $Start -and -not $Date) { $Range = $settings.Report.DefaultRange }
            $periodArgs = @{ Date = $Date; Start = $Start; End = $End; Zone = $zone }
            if ($Range) { $periodArgs['Range'] = $Range }
            $period = Resolve-MtrPeriod @periodArgs
        }
        $queryPlan = Get-MtrQueryPlan $filter
        $filterLines = @($filter.Describe())
        $tenantText = if ($settings.Tenant.Organization) { "$($settings.Tenant.Organization)  ($($settings.Tenant.TenantId))" } else { $settings.Tenant.TenantId }
        $banner = [ordered]@{ Mode = @('Target', $(switch ($Mode) {
                        'Trace' { "Trace $dot collects what the database lacks, then the report" }
                        'Collect' { "Collect $dot scheduled collection into the database" }
                        'Report' { "Report $dot database only, no connection" }
                        'Status' { "Status $dot database content" } }))
        }
        $banner['Tenant'] = @('People', $tenantText)
        if ($Mode -ne 'Status') { $banner['Period'] = @('Calendar', "$(Format-MtrRange $period.StartMs $period.EndMs $zone)  ($($settings.Report.TimeZone))") }
        $banner['Database'] = @('Database', $settings.Storage.DatabasePath)
        $banner['Log'] = @('Log', $logPath)
        Write-MtrBanner -Title 'Message Trace Report' -Subtitle "Exchange Online message trace $dot Microsoft Graph $dot SQLite history" -Details $banner

        # ---------------------------------------------------------------------------------------------
        # STATUS
        # ---------------------------------------------------------------------------------------------
        if ($Mode -eq 'Status') {
            Write-MtrStep 1 1 'Database' -Icon Database
            if (-not (Test-Path -LiteralPath $settings.Storage.DatabasePath)) { Write-MtrItem Warn "No database yet: $($settings.Storage.DatabasePath). Run a trace or a collection first."; $exitCode = 0; $runStatus = 'Succeeded'; break }
            $store = Open-MtrStore -Settings $settings -ReadOnly
            $scope = if ($filter.IsEmpty) { 'whole tenant' } else { ($filterLines -join '; ') }
            Show-MtrStatus -Store $store -Settings $settings -Signatures @($queryPlan.Queries | ForEach-Object Signature) -ScopeLabel $scope
            $exitCode = 0; $runStatus = 'Succeeded'
            break
        }

        $total = switch ($Mode) { 'Trace' { 4 } 'Collect' { 4 } 'Report' { 2 } }
        $step = 0

        # ---------------------------------------------------------------------------------------------
        # 1. Filter and plan
        # ---------------------------------------------------------------------------------------------
        Write-MtrStep (++$step) $total 'Filter and plan' -Icon Filter
        foreach ($line in $filterLines) { Write-MtrItem Info $line -Icon Target }
        foreach ($line in $queryPlan.Strategy) { Write-MtrItem Info $line -Icon Plan }
        foreach ($line in $queryPlan.LocalFilters) { Write-MtrItem Info "Applied on the database: $line" -Icon Database }
        $queryCount = $queryPlan.Queries.Count

        if ($Mode -eq 'Report') {
            $store = Open-MtrStore -Settings $settings -ReadOnly:(-not $settings.Details.Enabled)
            $coveragePlan = [MessageTraceReport.Planner]::Windows($queryPlan.Queries, $store.GetKnownCoverage(0, $period.StartMs, $period.EndMs), $period.StartMs, $period.EndMs, 0, [long]$settings.Collection.WindowHours * 3600000)
        } else {
            $store = Open-MtrStore -Settings $settings
            $lock = Enter-MtrLock -Path ([IO.Path]::ChangeExtension($settings.Storage.DatabasePath, '.lock')) -TimeoutSeconds 30
            [void]$store.CloseAbandonedRuns()
            $runId = $store.StartRun($Mode, '', [Environment]::MachineName, (Get-Module MessageTraceReport).Version.ToString(), ($filterLines -join '; '))
            $workPlan = Get-MtrWorkPlan -Store $store -QueryPlan $queryPlan -Period $period -Settings $settings -Refresh:$Refresh
            $periodText = Format-MtrDuration (($period.EndMs - $period.StartMs) / 1000.0)
            Write-MtrItem Info ("{0} quer{1} x {2}{3}" -f $queryCount, $(if ($queryCount -gt 1) { 'ies' } else { 'y' }), $periodText, $(if ($Refresh) { "  $dot -Refresh: the database is ignored" } else { '' })) -Icon Calendar
            if ($workPlan.CoveredMs -gt 0) {
                $share = 100.0 * $workPlan.CoveredMs / [Math]::Max(1L, [long]$workPlan.PeriodMs * $queryCount)
                Write-MtrItem Ok ("Already in the database: {0:0.#}% of the period{1}" -f $share, $(if ($workPlan.QueriesComplete) { " $dot $($workPlan.QueriesComplete) quer$(if ($workPlan.QueriesComplete -gt 1) { 'ies' } else { 'y' }) complete" } else { '' })) -Icon Database
            }
            if ($workPlan.UnrecoverableMs -gt 0) {
                Write-MtrItem Warn ("Older than the {0}-day history of Graph and not in the database: {1} {2} not available." -f $settings.Collection.SourceHistoryDays, (($workPlan.Unrecoverable | ForEach-Object { Format-MtrRange $_.Start $_.End $zone }) -join ', '), $(if ($workPlan.Unrecoverable.Count -gt 1) { 'are' } else { 'is' }))
            }
            $items = $workPlan.Items.Count
            if ($items) {
                $estimate = ''
                $budget = $settings.Throttling.MaxRequests
                if ($items -gt $budget) { $estimate = "  $dot at least {0} with the quota ({1} requests / {2} min)" -f (Format-MtrDuration ([Math]::Ceiling(($items - $budget) / $budget) * $settings.Throttling.PeriodSeconds)), $budget, [int]($settings.Throttling.PeriodSeconds / 60) }
                Write-MtrItem Info ("To collect: {0} window{1} (at least {0} request{1}){2}" -f $items, $(if ($items -gt 1) { 's' } else { '' }), $estimate) -Icon Download
                if ($items -gt $settings.Collection.MaxQueries -and -not $Force) {
                    throw ("The plan needs {0} requests (Collection.MaxQueries = {1}). Narrow the period or the filter, raise Collection.MaxQueries, or run again with -Force." -f $items, $settings.Collection.MaxQueries)
                }
            } else {
                Write-MtrItem Ok 'Nothing to collect: the database already holds the whole period for this filter.' -Icon Database
            }
        }

        # ---------------------------------------------------------------------------------------------
        # 2. Microsoft Graph and 3. collection (Trace, Collect)
        # ---------------------------------------------------------------------------------------------
        $connection = $null
        if ($Mode -in 'Trace', 'Collect') {
            Write-MtrStep (++$step) $total 'Microsoft Graph' -Icon Key
            if ($workPlan.Items.Count -or ($Mode -eq 'Trace' -and $settings.Details.Enabled)) {
                $connection = Connect-MtrGraph -Settings $settings
                $store.UpdateRunAccount($runId, $connection.Account)
                Write-MtrItem Ok ("{0}  $dot tenant verified  $dot {1}  $dot token valid until {2}" -f $connection.Account, $(if ($settings.Authentication.Mode -eq 'Interactive') { 'delegated' } else { $settings.Authentication.Mode.ToLowerInvariant() }), [DateTimeOffset]::FromUnixTimeMilliseconds($connection.ExpiresMs).ToLocalTime().ToString('HH:mm'))
            } else { Write-MtrItem Skip 'No connection needed.' }

            Write-MtrStep (++$step) $total 'Collection' -Icon Download
            if ($workPlan.Items.Count) {
                $collect = Invoke-MtrCollection -Store $store -Settings $settings -Connection $connection -WorkPlan $workPlan -RunId $runId
                $level = if ($collect.Fatal -or $collect.Failed.Count -or $collect.Cancelled) { 'Warn' } else { 'Ok' }
                Write-MtrItem $level ("{0}/{1} windows {2} {3} requests {2} {4} rows {2} {5} new deliveries {2} {6}" -f $collect.Done, $collect.Items, $dot, (Format-MtrNumber $collect.Requests), (Format-MtrNumber $collect.Rows), (Format-MtrNumber $collect.NewDeliveries), (Format-MtrDuration $collect.Seconds))
                if ($collect.Throttled -or $collect.WaitedSeconds -gt 1) { Write-MtrItem Info ("Quota: {0} throttled request(s) (429), {1} waited for the quota" -f $collect.Throttled, (Format-MtrDuration $collect.WaitedSeconds)) -Icon Clock }
                if ($collect.UpdatedDeliveries) { Write-MtrItem Info ("{0} deliveries updated (status changed since the previous collection)" -f (Format-MtrNumber $collect.UpdatedDeliveries)) }
                foreach ($f in @($collect.Failed | Select-Object -First 10)) { Write-MtrItem Fail $f.Error }
                if ($collect.Failed.Count -gt 10) { Write-MtrItem Fail ("... and {0} more failed window(s): see the log." -f ($collect.Failed.Count - 10)) }
                if ($collect.Cancelled) { Write-MtrItem Warn "$($collect.Cancelled) window(s) not collected (interrupted). The next run collects them." }
                if ($collect.Fatal) { throw $collect.Fatal }
            } else { Write-MtrItem Skip 'Nothing to collect.' }
        }

        # ---------------------------------------------------------------------------------------------
        # 4. Maintenance (Collect)
        # ---------------------------------------------------------------------------------------------
        if ($Mode -eq 'Collect') {
            Write-MtrStep (++$step) $total 'Maintenance' -Icon Broom
            $retention = Invoke-MtrRetention -Store $store -Settings $settings
            if ($retention.Purge -and $retention.Purge.Messages) { Write-MtrItem Ok ("Retention {0} days: {1} messages and {2} deliveries deleted" -f $settings.Storage.RetentionDays, (Format-MtrNumber $retention.Purge.Messages), (Format-MtrNumber $retention.Purge.Deliveries)) }
            else { Write-MtrItem Ok ("Retention {0}: nothing to delete" -f $(if ($settings.Storage.RetentionDays) { "$($settings.Storage.RetentionDays) days" } else { 'disabled' })) }
            $stats = $store.GetStatistics()
            Write-MtrItem Info ("{0} messages {1} {2} deliveries {1} {3}" -f (Format-MtrNumber $stats.Messages), $dot, (Format-MtrNumber $stats.Deliveries), (Format-MtrBytes $stats.FileBytes)) -Icon Database
            $incomplete = ($collect -and ($collect.Failed.Count -or $collect.Cancelled)) -or $workPlan.UnrecoverableMs -gt 0
            $runStatus = if ($incomplete) { 'Incomplete' } else { 'Succeeded' }
            $exitCode = if ($incomplete) { 2 } else { 0 }
            Write-MtrSummary -Title $(if ($incomplete) { 'Collection incomplete' } else { 'Collection done' }) -Status $(if ($incomplete) { 'Warn' } else { 'Ok' }) -Values ([ordered]@{
                    Period   = @('Calendar', (Format-MtrRange $period.StartMs $period.EndMs $zone))
                    Graph    = @('Download', $(if ($collect) { "{0} requests {1} {2} rows {1} {3} new deliveries" -f (Format-MtrNumber $collect.Requests), $dot, (Format-MtrNumber $collect.Rows), (Format-MtrNumber $collect.NewDeliveries) } else { 'nothing to collect' }))
                    Database = @('Database', ("{0} messages {1} {2}" -f (Format-MtrNumber $stats.Messages), $dot, (Format-MtrBytes $stats.FileBytes)))
                    Duration = @('Clock', (Format-MtrDuration $clock.Elapsed.TotalSeconds))
                })
            break
        }

        # ---------------------------------------------------------------------------------------------
        # Report (Trace, Report)
        # ---------------------------------------------------------------------------------------------
        Write-MtrStep (++$step) $total 'Report' -Icon Report
        if ($Mode -eq 'Trace') {
            $coveragePlan = [MessageTraceReport.Planner]::Windows($queryPlan.Queries, $store.GetKnownCoverage(0, $period.StartMs, $period.EndMs), $period.StartMs, $period.EndMs, 0, [long]$settings.Collection.WindowHours * 3600000)
        }
        $coverage = 100.0 * (1 - $coveragePlan.MissingMs / [Math]::Max(1.0, [double]$coveragePlan.PeriodMs * $queryCount))
        $coverageNote = ''
        if ($coverage -lt 99.95) {
            $coverageNote = "{0:0.#}% of the period is in the database for this filter: the report may miss messages." -f $coverage
            Write-MtrItem Warn ($coverageNote + $(if ($Mode -eq 'Report') { ' Run it in Trace mode (without -Mode Report) to collect the rest.' } else { '' }))
        }
        $selection = Select-MtrMessages -Store $store -Filter $filter -Period $period
        Write-MtrItem Info ("{0} messages {1} {2} deliveries match the filter" -f (Format-MtrNumber $selection.Messages), $dot, (Format-MtrNumber $selection.Deliveries)) -Icon Mail

        if ($settings.Details.Enabled -and $selection.Deliveries) {
            $candidates = $store.GetDetailCandidates($settings.Details.MaxDeliveries, $settings.Details.OnlyProblems)
            if ($candidates.Count) {
                if (-not $connection) {
                    $connection = Connect-MtrGraph -Settings $settings
                    Write-MtrItem Ok "$($connection.Account)  $dot tenant verified" -Icon Key
                }
                $details = Invoke-MtrDetails -Store $store -Settings $settings -Connection $connection -Items $candidates
                Write-MtrItem $(if ($details.Failed) { 'Warn' } else { 'Ok' }) ("Routes: {0}/{1} deliveries read {2} {3} events{4}" -f $details.Done, $details.Items, $dot, (Format-MtrNumber $details.Events), $(if ($details.Failed) { " $dot $($details.Failed) failed" } else { '' })) -Icon Route
            } else {
                Write-MtrItem Skip ("Routes: nothing new to read{0}." -f $(if ($settings.Details.OnlyProblems) { ' (only deliveries not delivered: Details.OnlyProblems)' } else { '' }))
            }
        }

        $runDir = New-MtrRunDirectory -Root $settings.Report.OutputPath -Mode $Mode -Zone $zone
        $report = New-MtrReport -Store $store -Settings $settings -Filter $filter -Period $period -OutputDirectory $runDir -QueryPlan $queryPlan -CoveragePercent $coverage -CoverageNote $coverageNote
        $files = foreach ($f in $report.Files) {
            [pscustomobject]@{ Status = 'Ok'; Kind = $f.Kind; Rows = Format-MtrNumber $f.Rows; Size = Format-MtrBytes $f.Bytes; File = Split-Path $f.Path -Leaf }
        }
        Write-MtrTable -Columns @(
            @{ Name = 'Kind'; Property = 'Kind'; Width = 5 }
            @{ Name = 'Rows'; Property = 'Rows'; Width = 10; Align = 'Right' }
            @{ Name = 'Size'; Property = 'Size'; Width = 9; Align = 'Right' }
            @{ Name = 'File'; Property = 'File'; Width = 0 }
        ) -Rows @($files)
        if ($report.HtmlTruncated) { Write-MtrItem Info ("HTML: the {0} newest messages (Report.HtmlMaxMessages); the CSV files hold all of them." -f (Format-MtrNumber $report.HtmlMessages)) }

        $incomplete = ($collect -and ($collect.Failed.Count -or $collect.Cancelled)) -or ($workPlan -and $workPlan.UnrecoverableMs -gt 0) -or $coverage -lt 99.95
        $runStatus = if ($incomplete) { 'Incomplete' } else { 'Succeeded' }
        $exitCode = if ($incomplete) { 2 } else { 0 }
        $statusText = ($report.Statuses.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Key) $(Format-MtrNumber $_.Value)" }) -join ', '
        $graphText = if ($Mode -eq 'Report') { 'not used (database only)' }
                     elseif ($collect) { "{0} requests {1} {2} rows {1} {3}" -f (Format-MtrNumber $collect.Requests), $dot, (Format-MtrNumber $collect.Rows), (Format-MtrDuration $collect.Seconds) }
                     else { 'not used: everything was in the database' }
        $values = [ordered]@{
            Period   = @('Calendar', (Format-MtrRange $period.StartMs $period.EndMs $zone))
            Messages = @('Mail', ("{0} messages {1} {2} deliveries{3}" -f (Format-MtrNumber $report.Messages), $dot, (Format-MtrNumber $report.Deliveries), $(if ($statusText) { "  ($statusText)" } else { '' })))
            Graph    = @('Download', $graphText)
            Folder   = @('Folder', $runDir)
            Duration = @('Clock', (Format-MtrDuration $clock.Elapsed.TotalSeconds))
        }
        Write-MtrSummary -Title $(if ($incomplete) { 'Report ready, incomplete' } else { 'Report ready' }) -Status $(if ($incomplete) { 'Warn' } else { 'Ok' }) -Values $values

        $html = $report.Files | Where-Object Kind -eq 'HTML' | Select-Object -First 1
        if (($Open -or $settings.Report.OpenReport) -and $html -and [Environment]::UserInteractive) { Invoke-Item -LiteralPath $html.Path }
        if ($GridView) {
            $csv = $report.Files | Where-Object { $_.Kind -eq 'CSV' -and $_.Name -eq 'Messages' } | Select-Object -First 1
            if ($csv) { Import-Csv -LiteralPath $csv.Path -Delimiter $settings.Report.CsvDelimiter -Encoding UTF8 | Out-GridView -Title "Message trace - $(Format-MtrRange $period.StartMs $period.EndMs $zone) - $(Format-MtrNumber $report.Messages) messages" }
            else { Write-MtrItem Warn '-GridView needs the Messages CSV file (Report.Formats Csv, Report.Files Messages).' }
        }
    } while ($false)
}
catch {
    $runError = $_.Exception.Message
    $exitCode = 1
    $runStatus = 'Failed'
    if (Get-Command Write-MtrSummary -ErrorAction SilentlyContinue) {
        Write-MtrLog 'ERROR' ($_ | Out-String)
        Write-MtrSummary -Title 'Failed' -Status Fail -Values ([ordered]@{ Error = @('Fail', $runError); Log = @('Log', "$logPath") })
    } else {
        Write-Host "Message Trace Report failed: $runError" -ForegroundColor Red
    }
}
finally {
    if ($store -and $runId) {
        try {
            $store.FinishRun($runId, $runStatus, $(if ($queryPlan) { $queryPlan.Queries.Count } else { 0 }), $(if ($workPlan) { $workPlan.Items.Count } else { 0 }),
                $(if ($collect) { $collect.Requests } else { 0 }), $(if ($collect) { $collect.Pages } else { 0 }), $(if ($collect) { $collect.Rows } else { 0 }),
                $(if ($collect) { $collect.NewDeliveries } else { 0 }), $(if ($collect) { $collect.Throttled } else { 0 }), $runError)
        } catch { }
    }
    if ($store) { try { $store.Dispose() } catch { } }
    if (Get-Command Exit-MtrLock -ErrorAction SilentlyContinue) { Exit-MtrLock $lock }
    if (Get-Command Stop-MtrLog -ErrorAction SilentlyContinue) { Write-MtrLog 'INFO' "Exit code $exitCode ($runStatus), $([Math]::Round($clock.Elapsed.TotalSeconds, 1)) s"; Stop-MtrLog }
    [Threading.Thread]::CurrentThread.CurrentCulture = $previousCulture
}
exit $exitCode
