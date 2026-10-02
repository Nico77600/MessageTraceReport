#Requires -Version 7.4

<#
.SYNOPSIS
    Message Trace Report - PowerShell module.

.DESCRIPTION
    Helper functions used by Invoke-MessageTraceReport.ps1. The code is split into files in src\,
    loaded here in the order of an execution:

        Console.ps1        Write-Mtr* functions: what the administrator sees, and the log file
        Configuration.ps1  Import-MtrConfiguration: reads and checks the .psd1 file
        Engine.ps1         Initialize-MtrEngine: SQLite (lib\sqlite) + the C# engine (src\Engine.*.cs)
        Filter.ps1         Periods, address files, the user's filter and the query plan
        Connection.ps1     Microsoft Graph token: certificate, client secret or interactive sign-in
        Collection.ps1     Runs the Graph queries (engine) with a live progress line
        Report.ps1         SQLite -> CSV / JSON / HTML
        Status.ps1         Database status, retention, lock

    Performance-critical work (HTTP, JSON, database, files) is done by the C# engine, compiled on
    first use into bin\.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.0.0
    History : see CHANGELOG.md
#>
# Strict mode 1.0: uninitialized variables are errors. Not 'Latest': configuration hashtables and token
# claims have optional keys, and strict mode 3.0 throws on a missing property.
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$script:ToolName = 'Message Trace Report'
$script:ToolVersion = '1.0.0'
$script:ToolAuthor = 'Nicolas Fabert'
$script:ToolRoot = $PSScriptRoot
$script:GraphRoot = 'https://graph.microsoft.com/v1.0'
# Microsoft first-party application that serves the message trace API: its service principal must exist in the tenant.
$script:TraceServiceAppId = '8bd644d1-64a1-4d4b-ae52-2e0cbf64e373'
$script:Permission = 'ExchangeMessageTrace.Read.All'

foreach ($file in 'Console', 'Configuration', 'Engine', 'Filter', 'Connection', 'Collection', 'Report', 'Status') {
    . (Join-Path $PSScriptRoot "src\$file.ps1")
}
