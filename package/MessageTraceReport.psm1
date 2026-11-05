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
        Route.ps1          Route of a message and reasons of the failures, in the console
        Status.ps1         Database status, retention, lock

    Performance-critical work (HTTP, JSON, database, files) is done by the C# engine, compiled in
    memory, after the package integrity check.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.1.1
    History : see CHANGELOG.md
#>
# Strict mode 1.0: uninitialized variables are errors. Not 'Latest': configuration hashtables and token
# claims have optional keys, and strict mode 3.0 throws on a missing property.
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$script:ToolName = 'Message Trace Report'
$script:ToolVersion = '1.1.1'
$script:ToolAuthor = 'Nicolas Fabert'
$script:ToolRoot = $PSScriptRoot
$script:GraphRoot = 'https://graph.microsoft.com/v1.0'
# Microsoft first-party application that serves the message trace API: its service principal must exist in the tenant.
$script:TraceServiceAppId = '8bd644d1-64a1-4d4b-ae52-2e0cbf64e373'
$script:Permission = 'ExchangeMessageTrace.Read.All'

# Package integrity. A package carries the owner-signed PackageIntegrity.psd1 manifest; when it is present, the signed
# verifier (src\Test-PackageIntegrity.ps1) must accept the tree before any code of src\ is loaded or compiled. A source
# tree without a manifest is an unverified development tree: the entry script refuses it unless -DevelopmentMode is given.
function Assert-MtrPackageIntegrity {
    [CmdletBinding()]
    param([string]$Root = $script:ToolRoot, [switch]$Distribution, [switch]$DevelopmentMode)
    $packageRoot = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Root))
    $manifest = Join-Path $packageRoot 'PackageIntegrity.psd1'
    if ((Test-Path -LiteralPath $manifest) -and -not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        throw 'Package integrity: PackageIntegrity.psd1 must be a file.'
    }
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        # Without a manifest nothing is verified: say so once per process (an unverified source tree).
        if (-not [AppDomain]::CurrentDomain.GetData('MessageTraceReport.UnverifiedTreeWarned')) {
            [AppDomain]::CurrentDomain.SetData('MessageTraceReport.UnverifiedTreeWarned', $true)
            Write-Warning 'Package integrity: no PackageIntegrity.psd1; this is an unverified source tree (package byte integrity and publisher authentication are not established).'
        }
        return
    }
    $verifier = Join-Path $packageRoot 'src\Test-PackageIntegrity.ps1'
    $cursor = [IO.Path]::GetFullPath($verifier)
    while ($cursor) {
        if (-not (Test-Path -LiteralPath $cursor)) { throw 'Package integrity: the verifier is missing; nothing was loaded.' }
        $item = Microsoft.PowerShell.Management\Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Package integrity: reparse point: $cursor" }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    $signature = Microsoft.PowerShell.Security\Get-AuthenticodeSignature -LiteralPath $verifier -ErrorAction Stop
    if ([string]$signature.Status -cne 'Valid' -or $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Thumbprint -cne '0F28E442889F17B5F4D251E8F96E7CC6E2C9C6D6' -or
        $null -eq $signature.TimeStamperCertificate) {
        throw 'Package integrity: the verifier must have the trusted, timestamped owner signature. Download the release ZIP again from https://github.com/Nico77600/MessageTraceReport/releases/latest, extract it and unblock it. A developer or CI copy is started from its folder with -DevelopmentMode.'
    }
    $arguments = @{ Root = $packageRoot }
    if ($Distribution) { $arguments.Distribution = $true }
    if ($DevelopmentMode) { $arguments.DevelopmentMode = $true }
    $result = @(& $verifier @arguments)
    if ($result.Count -ne 1 -or -not $result[0].PSObject.Properties['Status'] -or $result[0].Status -notlike 'Valid*') {
        throw 'Package integrity: the verifier did not return an explicit Valid result; nothing was loaded.'
    }
}
Assert-MtrPackageIntegrity
foreach ($file in 'Console', 'Configuration', 'Engine', 'Filter', 'Connection', 'Collection', 'Report', 'Route', 'Status') {
    . (Join-Path $PSScriptRoot "src\$file.ps1")
}
