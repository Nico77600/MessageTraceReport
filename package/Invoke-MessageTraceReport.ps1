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
    Also reads the route of the deliveries (getDetailsByRecipient: Receive, Submit, Deliver, Fail, Defer ...
    with the reason of each failure). A selection of at most Details.MaxDeliveries deliveries is read
    completely; a larger one: for each message with a problem, one recipient per problem status and one
    delivered recipient to compare with, then the other problems. Shown in the console (small selections),
    in the HTML report and in the Routes CSV file. Overrides Details.Enabled.

.PARAMETER MaxRoutes
    Number of routes to read in this run (overrides Details.MaxDeliveries); implies -IncludeDetails.

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

.PARAMETER DevelopmentMode
    Allows a developer or CI copy that has no PackageIntegrity.psd1 manifest. A present manifest is always verified.

.PARAMETER ConfigPath
    Configuration file. Default: config\MessageTraceReport.config.psd1 next to this script.

.EXAMPLE
    .\Invoke-MessageTraceReport.ps1 -Sender john@contoso.com
    Messages sent by John in the last 48 hours: CSV and HTML files in reports\.

.EXAMPLE
    .\Invoke-MessageTraceReport.ps1 -Recipient *@fabrikam.com -Range Last7Days -Status Failed
    Failed messages to Fabrikam over 7 days.

.EXAMPLE
    .\Invoke-MessageTraceReport.ps1 -SenderFile C:\Tools\MessageTraceReport-data\vip.csv -Recipient *@gmail.com -Start 2026-09-01 -End 2026-09-30
    Messages of the VIP list to Gmail in September: one query per VIP and per 10 days; the domain is checked locally.

.EXAMPLE
    .\Invoke-MessageTraceReport.ps1 -Sender alerts@contoso.com -Recipient helpdesk@contoso.com -Operator Or -IncludeDetails -Open
    Messages from OR to these addresses, with the route of the failed ones, report opened at the end.

.EXAMPLE
    .\Invoke-MessageTraceReport.ps1 -MessageId '<abc123@contoso.com>' -Range Last10Days -IncludeDetails
    Traces one message: the route of every recipient, grouped by identical route, with the reason of each
    failure and where the routes of the failed and the delivered recipients split.

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
    Version : 1.1.1
    Exit codes : 0 = success, 1 = failure, 2 = finished but incomplete (see the summary).
    Documentation : docs\MessageTraceReport-Guide.md (or .html)

    Disclaimer:
    This Script is a Personal project.
    It's provided "AS-IS". It's not an official Microsoft product so no support can be expected from Microsoft.

    As any scripts you must read carefully the documentation and test it first in a Test environment before any run in Production.
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
    [ValidateRange(1, 10000)][int]$MaxRoutes,
    [ValidateSet('Csv', 'Html', 'Json')][string[]]$Format,
    [string]$OutputPath,
    [switch]$GridView,
    [switch]$Open,
    [switch]$Refresh,
    [switch]$Force,
    [switch]$DevelopmentMode,
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
        # The package is verified before any of its code runs: the verifier must carry the owner signature, then it
        # checks the signed manifest. A tree without a manifest is accepted only with -DevelopmentMode.
        $integrityManifest = Join-Path $PSScriptRoot 'PackageIntegrity.psd1'
        if (Microsoft.PowerShell.Management\Test-Path -LiteralPath $integrityManifest) {
            $integrityVerifier = Join-Path $PSScriptRoot 'src\Test-PackageIntegrity.ps1'
            $integrityCursor = [IO.Path]::GetFullPath($integrityVerifier)
            while ($integrityCursor) {
                $integrityItem = Microsoft.PowerShell.Management\Get-Item -LiteralPath $integrityCursor -Force -ErrorAction Stop
                if ($integrityItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    throw "Package integrity: reparse point: $integrityCursor"
                }
                $integrityCursor = [IO.Path]::GetDirectoryName($integrityCursor)
            }
            $integritySignature = Microsoft.PowerShell.Security\Get-AuthenticodeSignature -LiteralPath $integrityVerifier -ErrorAction Stop
            if ([string]$integritySignature.Status -cne 'Valid' -or $null -eq $integritySignature.SignerCertificate -or
                $integritySignature.SignerCertificate.Thumbprint -cne '0F28E442889F17B5F4D251E8F96E7CC6E2C9C6D6' -or
                $null -eq $integritySignature.TimeStamperCertificate) {
                throw 'Package integrity: the verifier must have the trusted, timestamped owner signature. Download the release ZIP again from https://github.com/Nico77600/MessageTraceReport/releases/latest, extract it and unblock it. A developer or CI copy is started from its folder with -DevelopmentMode.'
            }
            if ($DevelopmentMode) { & $integrityVerifier -Root $PSScriptRoot -DevelopmentMode | Out-Null } else { & $integrityVerifier -Root $PSScriptRoot -Distribution | Out-Null }
        } elseif (-not $DevelopmentMode) {
            throw 'Package integrity: PackageIntegrity.psd1 is missing. Download the release ZIP again from https://github.com/Nico77600/MessageTraceReport/releases/latest, extract it and unblock it. A developer or CI copy is started from its folder with -DevelopmentMode.'
        } else {
            Write-Warning 'DevelopmentMode: no package manifest; package byte integrity and publisher authentication are not established.'
            # The module does not repeat this warning in the same process.
            [AppDomain]::CurrentDomain.SetData('MessageTraceReport.UnverifiedTreeWarned', $true)
        }
        Import-Module (Join-Path $PSScriptRoot 'MessageTraceReport.psd1') -Force
        $settings = Import-MtrConfiguration -Path $ConfigPath -Root $PSScriptRoot
        if ($OutputPath) { $settings.Report.OutputPath = [IO.Path]::GetFullPath($OutputPath, (Get-Location).Path) }
        if ($Format) { $settings.Report.Formats = @($Format) }
        if ($PSBoundParameters.ContainsKey('IncludeDetails')) { $settings.Details.Enabled = [bool]$IncludeDetails }
        if ($MaxRoutes) { $settings.Details.Enabled = $true; $settings.Details.MaxDeliveries = $MaxRoutes }
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
            $d = $settings.Details
            $candidates = $store.GetDetailCandidates($d.MaxDeliveries, $d.OnlyProblems, $d.CompareWithDelivered)
            if ($candidates.Count) {
                $kinds = $candidates | Group-Object Kind -NoElement | Sort-Object { @{ Problem = 0; Comparison = 1; Delivered = 2 }[$_.Name] }
                $kindText = ($kinds | ForEach-Object { '{0} {1}' -f $_.Count, @{ Problem = 'not delivered'; Comparison = 'delivered, to compare'; Delivered = 'delivered or expanded' }[$_.Name] }) -join " $dot "
                Write-MtrItem Info ("Routes to read: {0} ({1})" -f $candidates.Count, $kindText) -Icon Route
                if (-not $connection) {
                    $connection = Connect-MtrGraph -Settings $settings
                    Write-MtrItem Ok "$($connection.Account)  $dot tenant verified" -Icon Key
                }
                $details = Invoke-MtrDetails -Store $store -Settings $settings -Connection $connection -Items $candidates
                Write-MtrItem $(if ($details.Failed) { 'Warn' } else { 'Ok' }) ("Routes: {0}/{1} deliveries read {2} {3} events{4}" -f $details.Done, $details.Items, $dot, (Format-MtrNumber $details.Events), $(if ($details.Failed) { " $dot $($details.Failed) failed" } else { '' })) -Icon Route
            } else {
                Write-MtrItem Skip ("Routes: nothing new to read{0}." -f $(if ($d.OnlyProblems -and $selection.Deliveries -gt $d.MaxDeliveries) { ' (beyond Details.MaxDeliveries, only the deliveries not delivered: Details.OnlyProblems)' } else { '' }))
            }
        }
        # Small selection: the route of each message, recipients grouped by identical route.
        if ($selection.Messages -and $selection.Messages -le $settings.Details.ConsoleMessages -and $store.CountSelectionRoutes() -gt 0) {
            $journeys = [MessageTraceReport.Journeys]::Build($store.ReadSelection(), $store.GetSelectionDetails(), $settings.Details.ConsoleMessages)
            Write-MtrJourney -Journeys $journeys -Zone $zone
            Write-Host ''
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
        if ($report.Reasons.Count) {
            Write-Host ''
            Write-MtrItem Info ("Why deliveries were not delivered: {0} of {1} explained by the routes read" -f (Format-MtrNumber $report.ProblemRoutesRead), (Format-MtrNumber $report.ProblemDeliveries)) -Icon Route
            Write-MtrReasons -Report $report
        } elseif ($report.ProblemDeliveries -and -not $settings.Details.Enabled -and $Mode -eq 'Trace') {
            Write-MtrItem Skip ("{0} deliveries were not delivered: add -IncludeDetails to read why (route of each delivery)." -f (Format-MtrNumber $report.ProblemDeliveries))
        }

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
            Routes   = @('Route', $(if ($report.RoutesRead) { "{0} routes in the report {1} {2} of {3} problems explained" -f (Format-MtrNumber $report.RoutesRead), $dot, (Format-MtrNumber $report.ProblemRoutesRead), (Format-MtrNumber $report.ProblemDeliveries) } elseif ($settings.Details.Enabled) { 'none read' } else { 'not read (-IncludeDetails)' }))
            Graph    = @('Download', $graphText)
            Folder   = @('Folder', $runDir)
            Duration = @('Clock', (Format-MtrDuration $clock.Elapsed.TotalSeconds))
        }
        if ($report.Causes.Count) {
            $values.Insert(3, 'Causes', @('Target', ((($report.Causes | Select-Object -First 3) | ForEach-Object { "$($_.Cause) $(Format-MtrNumber $_.Deliveries)" }) -join ', ') + $(if ($report.Causes.Count -gt 3) { " +$($report.Causes.Count - 3)" } else { '' })))
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

# SIG # Begin signature block
# MIImIQYJKoZIhvcNAQcCoIImEjCCJg4CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDyK5c251a7mqdu
# AnfSDGxuCfsPwrFXFYgh3SxI7Fr8v6CCDW8wggZyMIIEWqADAgECAghkM1HTxzif
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
# wZislcdCZuS6MYIYCDCCGAQCAQEwgYwweDELMAkGA1UEBhMCVVMxDjAMBgNVBAgM
# BVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDE0MDIG
# A1UEAwwrU1NMLmNvbSBDb2RlIFNpZ25pbmcgSW50ZXJtZWRpYXRlIENBIFJTQSBS
# MQIQBof4ljXihJpmCqqt2mhAWzANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3
# AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCAGX6GqqF7R
# tn+G9jorQFZUcU7ZAQR+ViaG5ADL+bfe8TANBgkqhkiG9w0BAQEFAASCAgAz2WV2
# yB8WnizRWKroihRT9UOY+S3plRuhFFtegGKrLxvFJ52Mz05v96bD5je+LowrFnHL
# WN6loQyrau0o/pIIMkVAjJUzzcxp5oTG5NU2ZrXEVpY+frrF6jfysf+H5FvECJz/
# 6atnYIOGSZqs8Db/CoNOnbAhA7PAArcVTyNBEMqHUImtUms03kw8UERmvpf0my+X
# mynojCqbgMhphYOPxwv1NPI9bz/1uyK/5ZZAQgJhm9DipLO8koGQCTe5uTZhoR1r
# 4+MlLqfJIC0sZ18+u4BJdRAVYTjjtIyQ3Tzem/1zTMFS9k8SLAd2gJWSLTg1gAq/
# RZUt6Vu48C6Sh120wd6EULQ/kP7RgsgK7CZNKN2uQ3WnYn4EL4Vbkb76clgkMked
# hgfamGZs+QzCOziTJSsBKqwoSOP0MC9dfmM61518XotFeDLgP041Uyp0mU8S3SOL
# o+SVGyDD+BywsB+QrhixUwpR9vJryBLLFQeU6uxfiTXiCObYpD0RorwFPVDmM20L
# MWlWBVF6yTBEFrkoyd6xB9moM5y078dKCSTmI3V+DjrrXTLCA+42Iei1Bov1vN1m
# 14ngGySkXorwqq4XYdzV6pcfWn5xsl+DNwUwXmtxQs6+Ys2+QK2MB0jSbN4mGJhr
# /kEXqSqeMR/+f68mjxUFqJbUBWeUZv/m+hrTtqGCFMUwghTBBgorBgEEAYI3AwMB
# MYIUsTCCFK0GCSqGSIb3DQEHAqCCFJ4wghSaAgEDMQ0wCwYJYIZIAWUDBAIBMIGB
# BgsqhkiG9w0BCRABBKByBHAwbgIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEIPSUOnEXE/535OD0whYrlaTYFSP0auzfpX99HTYBicRlAghv5n+FoIoL
# 0xgPMjAyNjExMDUxODAwNTRaMAMCAQECCEHcf7a3MNoaoIIRpzCCBPMwggLboAMC
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
# 9sdantP6nYRQFTpF8czGc+FGresbAH819Pv5vBhCluTo8Px2PpC71cM0jzsxggJV
# MIICUQIBATCBhjByMQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNV
# BAcMB0hvdXN0b24xETAPBgNVBAoMCFNTTCBDb3JwMS4wLAYDVQQDDCVTU0wuY29t
# IFRpbWVzdGFtcGluZyBJc3N1aW5nIFJTQSBDQSAyAhBUQ/g3vVruGAGEcrhc2o7j
# MAsGCWCGSAFlAwQCAaCCAWAwGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMBwG
# CSqGSIb3DQEJBTEPFw0yNjExMDUxODAwNTRaMCgGCSqGSIb3DQEJNDEbMBkwCwYJ
# YIZIAWUDBAIBoQoGCCqGSM49BAMCMC8GCSqGSIb3DQEJBDEiBCDV0h8fDcRBAROE
# YZsMW+2ZYCGrnlT1HnHDJXsMQroGxDCByAYLKoZIhvcNAQkQAi8xgbgwgbUwgbIw
# ga8EIFdP6heq+l58aiubCMmYsXNeRQs4c8pE5qJMoJMOY/OwMIGKMHakdDByMQsw
# CQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24xETAP
# BgNVBAoMCFNTTCBDb3JwMS4wLAYDVQQDDCVTU0wuY29tIFRpbWVzdGFtcGluZyBJ
# c3N1aW5nIFJTQSBDQSAyAhBUQ/g3vVruGAGEcrhc2o7jMAoGCCqGSM49BAMCBEYw
# RAIgPonOb8eoIXnhc43atKMPdCtNVAiCHXiQmpytRrkYg3gCIEYb3vRbe14cM/uF
# COus0KK7sDkmcmfpPBT+N5XRUXFB
# SIG # End signature block
