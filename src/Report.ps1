<#
    Message Trace Report - report.

    Select-MtrMessages  applies the FULL user filter to the database for the period (temp table in the engine)
    New-MtrReport       writes the files of the selection (CSV, JSON, HTML) in one pass
    New-MtrRunDirectory reports\<date>_<time>_<mode>, never overwritten
#>

function New-MtrRunDirectory {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Mode, [Parameter(Mandatory)][TimeZoneInfo]$Zone)
    $stamp = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow, $Zone).ToString('yyyy-MM-dd_HHmmss', [Globalization.CultureInfo]::InvariantCulture)
    $path = Join-Path $Root "${stamp}_$Mode"
    $n = 1
    while (Test-Path -LiteralPath $path) { $n++; $path = Join-Path $Root "${stamp}_${Mode}_$n" }
    [void][IO.Directory]::CreateDirectory($path)
    return $path
}

function Select-MtrMessages {
    <# Builds the selection of the report in the database. Returns @{ Messages; Deliveries }. #>
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)][MessageTraceReport.FilterSpec]$Filter, [Parameter(Mandatory)]$Period)
    return $Store.Select($Filter, $Period.StartMs, $Period.EndMs)
}

function New-MtrReport {
    <#
    .SYNOPSIS
        Writes the report files of the current selection (Select-MtrMessages first).
    .OUTPUTS
        [MessageTraceReport.ReportResult]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Store, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][MessageTraceReport.FilterSpec]$Filter,
        [Parameter(Mandatory)]$Period, [Parameter(Mandatory)][string]$OutputDirectory, $QueryPlan,
        [double]$CoveragePercent = 100, [string]$CoverageNote = '', [string[]]$Formats
    )
    $r = $Settings.Report
    if (-not $Formats) { $Formats = $r.Formats }
    $q = [MessageTraceReport.ReportRequest]::new()
    $q.OutputDirectory = $OutputDirectory
    $q.FilePrefix = $r.FilePrefix
    $q.CsvDelimiter = $r.CsvDelimiter
    $q.Title = $r.Title
    $q.Zone = $Settings.Zone
    $q.TimeZoneLabel = $r.TimeZone
    $q.ToolVersion = $script:ToolVersion
    $q.Tenant = if ($Settings.Tenant.Organization) { $Settings.Tenant.Organization } else { $Settings.Tenant.TenantId }
    $q.RangeName = $Period.Range
    $q.StartMs = $Period.StartMs
    $q.EndMs = $Period.EndMs
    $q.Csv = $Formats -contains 'Csv'
    $q.Json = $Formats -contains 'Json'
    $q.Html = $Formats -contains 'Html'
    $q.Messages = $r.Files -contains 'Messages'
    $q.Deliveries = $r.Files -contains 'Deliveries'
    $q.Senders = $r.Files -contains 'Senders'
    $q.Recipients = $r.Files -contains 'Recipients'
    $q.CountsPerDay = $r.CountsPerDay -and ($Period.EndMs - $Period.StartMs) -gt 86400000
    $q.MaxRowsPerFile = $r.MaxRowsPerFile
    $q.HtmlMaxMessages = $r.HtmlMaxMessages
    $q.HtmlRecipientsPerMessage = $r.HtmlRecipientsPerMessage
    $q.TemplatePath = $r.TemplatePath
    foreach ($line in $Filter.Describe()) { $q.FilterLines.Add($line) }
    if ($QueryPlan) { foreach ($line in $QueryPlan.Strategy) { $q.Strategy.Add($line) } }
    $q.CoveragePercent = $CoveragePercent
    $q.CoverageNote = $CoverageNote
    $q.Details = $Store.GetSelectionDetails()
    return [MessageTraceReport.ReportWriter]::Write($Store.ReadSelection(), $q)
}
