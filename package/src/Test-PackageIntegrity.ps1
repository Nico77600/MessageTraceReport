#Requires -Version 7.4
<#
.SYNOPSIS
    Verifies the authenticated Message Trace Report package before any of its code runs.

.DESCRIPTION
    Invoked by Invoke-MessageTraceReport.ps1, by the module (import and engine initialization) and by the package
    builder. It requires a valid, timestamped owner signature on this script, on PackageIntegrity.psd1 and on every
    PowerShell file of the inventory, then compares the SHA256 of every inventory file (C# sources, SQLite libraries,
    report template, HTML guides, README, notices) with the signed manifest. Missing, changed, unknown or
    reparse-point files fail closed.

    Not protected, by design: config\MessageTraceReport.config.psd1 (edited by the administrator) and the generated
    folders bin\, data\, logs\ and reports\ (never executed: the engine is compiled in memory from the verified
    sources).

.PARAMETER Root
    Package folder to verify, not its src subfolder. This script must belong to that package's src folder.

.PARAMETER Distribution
    Verifies a release package: the files added by the package builder (CHANGELOG.md) are required and hashed.
    Refused together with -DevelopmentMode.

.PARAMETER DevelopmentMode
    For an unsigned continuous-integration build or a developer package: the files and the PowerShell signatures are
    still enforced.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.1.1
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Root, [switch]$Distribution, [switch]$DevelopmentMode)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Distribution -and $DevelopmentMode) { throw 'Package integrity: -Distribution and -DevelopmentMode cannot be combined.' }
$signer = '0F28E442889F17B5F4D251E8F96E7CC6E2C9C6D6'
# What to do, at the end of the refusals an unsigned or re-saved package meets first.
$releaseHint = 'Download the release ZIP again from https://github.com/Nico77600/MessageTraceReport/releases/latest, extract it and unblock it. A modified, re-saved or unsigned file cannot be started. A developer or CI copy is started from its folder with -DevelopmentMode.'
$rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\')
$signed = @(
    'Invoke-MessageTraceReport.ps1'
    'MessageTraceReport.psm1'
    'MessageTraceReport.psd1'
    'src\Collection.ps1'
    'src\Configuration.ps1'
    'src\Connection.ps1'
    'src\Console.ps1'
    'src\Engine.ps1'
    'src\Filter.ps1'
    'src\Report.ps1'
    'src\Route.ps1'
    'src\Status.ps1'
    'src\Test-PackageIntegrity.ps1'
)
$required = @($signed) + @(
    'src\Engine.Common.cs'
    'src\Engine.Graph.cs'
    'src\Engine.Plan.cs'
    'src\Engine.Report.cs'
    'src\Engine.Route.cs'
    'src\Engine.Store.cs'
    'lib\sqlite\Microsoft.Data.Sqlite.dll'
    'lib\sqlite\SQLitePCLRaw.core.dll'
    'lib\sqlite\SQLitePCLRaw.provider.e_sqlite3.dll'
    'lib\sqlite\SQLitePCLRaw.batteries_v2.dll'
    'lib\sqlite\runtimes\win-x64\e_sqlite3.dll'
    'lib\sqlite\runtimes\win-arm64\e_sqlite3.dll'
    'templates\Report.template.html'
    'docs\MessageTraceReport-Guide.html'
    'docs\MessageTraceReport-UserGuide.html'
    'README.md'
    'LICENSE'
    'THIRD-PARTY-NOTICES.md'
)
# Copied from the repository root by the package builder: hashed, required only in a distribution.
$distributionOnly = @(
    'CHANGELOG.md'
)
# Repository-only documents are not loaded by the engine or copied into the distribution.
# These exact names (not an extension or directory wildcard) are the only unhashed source extras.
$sourceDocuments = @(
    'docs\MessageTraceReport-Guide.md'
    'docs\MessageTraceReport-UserGuide.md'
    'docs\images\console-collect.png'
    'docs\images\console-rerun.png'
    'docs\images\console-route.png'
    'docs\images\console-status.png'
    'docs\images\console-trace.png'
    'docs\images\readme-banner-dark.png'
    'docs\images\readme-banner-light.png'
    'docs\images\readme-benchmark-dark.png'
    'docs\images\readme-benchmark-light.png'
    'docs\images\readme-how-it-works-dark.png'
    'docs\images\readme-how-it-works-light.png'
    'docs\images\readme-principles-dark.png'
    'docs\images\readme-principles-light.png'
    'docs\images\report-message.png'
    'docs\images\report-messages.png'
    'docs\images\report-overview-dark.png'
    'docs\images\report-overview-light.png'
)
# Edited by the administrator; data, never executed.
$editableFiles = @(
    'config\MessageTraceReport.config.psd1'
)
$inventory = @($required) + @($distributionOnly)
function Assert-PlainPath([string]$Path, [bool]$Directory = $false) {
    $item = Microsoft.PowerShell.Management\Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint -or $item.PSIsContainer -ne $Directory) {
        throw "Package integrity: unsafe path or unexpected type: $Path"
    }
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    while ($parent) {
        $ancestor = Microsoft.PowerShell.Management\Get-Item -LiteralPath $parent -Force -ErrorAction Stop
        if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Package integrity: reparse-point ancestor: $parent"
        }
        $parent = [IO.Path]::GetDirectoryName($parent)
    }
}
function Assert-OwnerSignature([string]$Path) {
    $signature = Microsoft.PowerShell.Security\Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    if ([string]$signature.Status -cne 'Valid' -or $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Thumbprint -cne $signer -or $null -eq $signature.TimeStamperCertificate) {
        throw "Package integrity: expected trusted, timestamped owner signature: $Path. $releaseHint"
    }
}
function Test-Entry($Entry) {
    $Entry -is [hashtable] -and $Entry.Count -eq 2 -and $Entry.ContainsKey('Path') -and $Entry.ContainsKey('Sha256') -and
        $Entry.Path -is [string] -and $Entry.Sha256 -is [string] -and $Entry.Sha256 -cmatch '^[0-9A-F]{64}$'
}
Assert-PlainPath $rootPath $true
if (-not [string]::Equals([IO.Path]::GetFullPath($PSCommandPath),
    [IO.Path]::Combine($rootPath, 'src', 'Test-PackageIntegrity.ps1'), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Package integrity: verifier must belong to this package root.'
}
Assert-PlainPath $PSCommandPath
Assert-OwnerSignature $PSCommandPath
$manifestPath = [IO.Path]::Combine($rootPath, 'PackageIntegrity.psd1')
if (-not [IO.File]::Exists($manifestPath)) { throw "Package integrity: PackageIntegrity.psd1 is missing. $releaseHint" }
Assert-PlainPath $manifestPath
Assert-OwnerSignature $manifestPath
# Authenticate the raw PSD1 before parsing its restricted data language.
$manifest = Microsoft.PowerShell.Utility\Import-PowerShellDataFile -LiteralPath $manifestPath -ErrorAction Stop
if ($manifest.Count -ne 5 -or -not $manifest.ContainsKey('SchemaVersion') -or
    -not $manifest.ContainsKey('Algorithm') -or -not $manifest.ContainsKey('SignerThumbprint') -or
    -not $manifest.ContainsKey('Version') -or -not $manifest.ContainsKey('Files') -or
    $manifest.SchemaVersion -isnot [int] -or
    $manifest.SchemaVersion -ne 1 -or $manifest.Algorithm -cne 'SHA256' -or
    $manifest.SignerThumbprint -cne $signer -or $manifest.Version -isnot [string] -or
    $manifest.Files -isnot [array]) {
    throw 'Package integrity: unsupported or incomplete manifest schema.'
}
if ($manifest.Files.Count -ne $inventory.Count) {
    throw "Package integrity: the manifest lists $($manifest.Files.Count) files, $($inventory.Count) expected."
}
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($entry in $manifest.Files) {
    if (-not (Test-Entry $entry) -or $entry.Path -cnotin $inventory -or -not $seen.Add($entry.Path)) {
        throw 'Package integrity: invalid, duplicate or unapproved inventory path/hash.'
    }
    $path = [IO.Path]::Combine($rootPath, $entry.Path)
    if ($entry.Path -cin $distributionOnly -and -not $Distribution -and
        -not (Microsoft.PowerShell.Management\Test-Path -LiteralPath $path)) { continue }
    Assert-PlainPath $path
    $hash = (Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash
    if ($hash -cne $entry.Sha256) { throw "Package integrity: SHA256 mismatch: $($entry.Path)" }
    if ($entry.Path -cmatch '\.ps(m1|d1|1)$') { Assert-OwnerSignature $path }
}
foreach ($path in $inventory) {
    if (-not $seen.Contains($path)) { throw "Package integrity: missing inventory path: $path" }
}
$status = 'Valid (files only)'
if ($Distribution) {
    $status = 'Valid'
} elseif ($DevelopmentMode) {
    Write-Warning 'Package integrity: DevelopmentMode: the files and the PowerShell signatures are verified; the distribution-only files are not required.'
    $status = 'Valid (DevelopmentMode)'
}
$queue = [Collections.Generic.Queue[string]]::new()
$queue.Enqueue($rootPath)
while ($queue.Count) {
    $directory = $queue.Dequeue()
    foreach ($item in Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) {
        $relative = [IO.Path]::GetRelativePath($rootPath, $item.FullName)
        if ($directory -ceq $rootPath -and $item.PSIsContainer -and $item.Name -cin @('bin', 'data', 'logs', 'reports')) {
            continue
        }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Package integrity: protected reparse point: $relative"
        }
        if ($item.PSIsContainer) { $queue.Enqueue($item.FullName); continue }
        # The owner-signed manifest itself (authenticated above, before it was parsed).
        if ($relative -ceq 'PackageIntegrity.psd1') { continue }
        if ($relative -cin $editableFiles -or $relative -cin $sourceDocuments) { continue }
        if ($relative -cin $inventory) { continue }
        throw "Package integrity: unexpected stable file: $relative"
    }
}
[pscustomobject]@{
    Name    = 'MessageTraceReport'
    Version = $manifest.Version
    Files   = $manifest.Files.Count
    Status  = $status
    Signer  = $signer
}