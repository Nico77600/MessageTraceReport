#
#  Message Trace Report - module manifest
#  --------------------------------------------------------------------------
#  Author  : Nicolas Fabert
#  Version : see ModuleVersion
#
#  Loaded by Invoke-MessageTraceReport.ps1 (Import-Module by path).
#
@{
    RootModule        = 'MessageTraceReport.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '6c1f3b2a-8d4e-4f7a-9b5c-2e7d1a0f4c83'
    Author            = 'Nicolas Fabert'
    Description       = 'Message Trace Report: Exchange Online message trace through the Microsoft Graph API (v1.0), with a local SQLite history, a query planner that respects the API quota, and CSV / JSON / HTML reports.'
    PowerShellVersion = '7.4'

    # Functions called by Invoke-MessageTraceReport.ps1 and by the tests. The other functions stay internal.
    FunctionsToExport = @(
        'Write-MtrLog', 'Start-MtrLog', 'Stop-MtrLog', 'Write-MtrBanner', 'Write-MtrStep', 'Write-MtrItem', 'Write-MtrSummary', 'Write-MtrTable'
        'Format-MtrNumber', 'Format-MtrDuration', 'Format-MtrBytes', 'Format-MtrLocalTime', 'Format-MtrRange'
        'Import-MtrConfiguration', 'Get-MtrTimeZone'
        'Initialize-MtrEngine', 'Open-MtrStore'
        'Resolve-MtrPeriod', 'ConvertTo-MtrUnixMs', 'Read-MtrAddressFile', 'New-MtrFilter', 'Get-MtrQueryPlan', 'Get-MtrWorkPlan', 'Get-MtrEarliestMs'
        'Connect-MtrGraph', 'Update-MtrToken', 'Get-MtrCertificate', 'New-MtrClientAssertion', 'Get-MtrTokenClaims'
        'Invoke-MtrCollection', 'Invoke-MtrDetails', 'Select-MtrMessages', 'New-MtrReport', 'New-MtrRunDirectory'
        'Show-MtrStatus', 'Invoke-MtrRetention', 'Enter-MtrLock', 'Exit-MtrLock'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
