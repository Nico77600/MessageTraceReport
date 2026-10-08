#Requires -Version 7.4

<#
.SYNOPSIS
    Copies the files needed to run Message Trace Report into a separate folder, ready to be zipped.

.DESCRIPTION
    The package contains what Invoke-MessageTraceReport.ps1 needs at run time, the HTML guide, the short
    README, the changelog, the licence and the third-party notices:
        Invoke-MessageTraceReport.ps1, MessageTraceReport.psd1, MessageTraceReport.psm1, src\ (PowerShell and
        the C# engine sources, compiled on first use), lib\sqlite\, templates\, config\,
        docs\MessageTraceReport-Guide.html, README.md, CHANGELOG.md, LICENSE, THIRD-PARTY-NOTICES.md
    It never copies data\, reports\, logs\, bin\, the tests or the tools: no tenant data is in the package.

    The configuration file is copied with the tenant values emptied (TenantId, Organization, AppId,
    CertificateThumbprint, UserPrincipalName) and the Collect lists reset. The script then checks that none of
    the emptied values appears in the package, and that the SQLite binaries match THIRD-PARTY-NOTICES.md.

.PARAMETER Destination
    Package folder. Default: package\MessageTraceReport-<version>, next to the repository folder.

.PARAMETER Zip
    Also writes <Destination>.zip.

.PARAMETER Force
    Replace the destination folder if it already contains a package. A folder with a data\ or reports\
    sub-folder (a package that has been run) is never replaced.

.EXAMPLE
    .\tools\New-MtrPackage.ps1 -Zip

.NOTES
    Author  : Nicolas Fabert
    Version : 1.0.0
#>
[CmdletBinding()]
param(
    [string]$Destination,
    [switch]$Zip,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$packageRoot = Join-Path $root 'package'
$version = (Import-PowerShellDataFile (Join-Path $packageRoot 'MessageTraceReport.psd1')).ModuleVersion
if (-not $Destination) { $Destination = Join-Path (Split-Path $root -Parent) "package\MessageTraceReport-$version" }
$Destination = [IO.Path]::GetFullPath($Destination, (Get-Location).Path).TrimEnd('\')

$repoPrefix = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
if (($Destination + '\').StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase) -or $repoPrefix.StartsWith($Destination + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "The destination must be outside the tool folder: $Destination"
}
if (Test-Path -LiteralPath $Destination) {
    if (-not $Force) { throw "The destination already exists: $Destination. Use -Force to replace it." }
    if (-not (Test-Path -LiteralPath (Join-Path $Destination 'Invoke-MessageTraceReport.ps1'))) { throw "The destination is not a Message Trace Report package, it is not replaced: $Destination" }
    foreach ($name in 'data', 'reports') { if (Test-Path -LiteralPath (Join-Path $Destination $name)) { throw "The destination contains a $name folder (tenant data), it is not replaced: $Destination" } }
    Remove-Item -LiteralPath $Destination -Recurse -Force
}

# ---- Files needed at run time ---------------------------------------------------------------------------
$files = [Collections.Generic.List[string]]::new()
foreach ($f in 'Invoke-MessageTraceReport.ps1', 'MessageTraceReport.psd1', 'MessageTraceReport.psm1', 'README.md', 'CHANGELOG.md', 'LICENSE', 'THIRD-PARTY-NOTICES.md',
    'templates\Report.template.html', 'docs\MessageTraceReport-Guide.html') { $files.Add($f) }
Get-ChildItem -LiteralPath (Join-Path $packageRoot 'src') -File | Where-Object Extension -in '.ps1', '.cs' | ForEach-Object { $files.Add("src\$($_.Name)") }
Get-ChildItem -LiteralPath (Join-Path $packageRoot 'lib\sqlite') -Recurse -File | ForEach-Object { $files.Add($_.FullName.Substring($packageRoot.Length + 1)) }

foreach ($f in $files) {
    $source = if ($f -eq 'CHANGELOG.md') { Join-Path $root $f } else { Join-Path $packageRoot $f }
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing file in the tool folder: $f" }
    $target = Join-Path $Destination $f
    [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
    Copy-Item -LiteralPath $source -Destination $target
}

# ---- Configuration with the tenant values emptied -------------------------------------------------------
$configRelative = 'config\MessageTraceReport.config.psd1'
$config = [IO.File]::ReadAllText((Join-Path $packageRoot $configRelative))
$emptied = [Collections.Generic.List[string]]::new()
foreach ($key in 'TenantId', 'Organization', 'AppId', 'CertificateThumbprint', 'UserPrincipalName', 'SenderFile', 'RecipientFile') {
    $pattern = "(?m)^(\s*$key\s*=\s*)'([^']*)'"
    $found = [regex]::Matches($config, $pattern)
    if ($found.Count -ne 1) { throw "The key $key must appear exactly once in $configRelative (found $($found.Count))." }
    if ($found[0].Groups[2].Value) { $emptied.Add($found[0].Groups[2].Value) }
    $config = [regex]::Replace($config, $pattern, '$1''''')
}
foreach ($key in 'Senders', 'Recipients') {
    $pattern = "(?m)^(\s*$key\s*=\s*)@\(([^)]*)\)"
    $found = [regex]::Matches($config, $pattern)
    if ($found.Count -ne 1) { throw "The key $key must appear exactly once in $configRelative (found $($found.Count))." }
    foreach ($v in [regex]::Matches($found[0].Groups[2].Value, "'([^']+)'")) { $emptied.Add($v.Groups[1].Value) }
    $config = [regex]::Replace($config, $pattern, '$1@()')
}
$configTarget = Join-Path $Destination $configRelative
[void][IO.Directory]::CreateDirectory((Split-Path $configTarget -Parent))
[IO.File]::WriteAllText($configTarget, $config, [Text.UTF8Encoding]::new($true))
$files.Add($configRelative)

# ---- Checks ---------------------------------------------------------------------------------------------
$problems = [Collections.Generic.List[string]]::new()
foreach ($name in 'data', 'reports', 'logs', 'bin', 'tests', 'tools', 'lab') {
    if (Test-Path -LiteralPath (Join-Path $Destination $name)) { $problems.Add("Folder $name\ must not be in the package.") }
}
$textFiles = Get-ChildItem -LiteralPath $Destination -Recurse -File | Where-Object Extension -in '.ps1', '.psm1', '.psd1', '.cs', '.html', '.md', ''
foreach ($value in $emptied) {
    foreach ($file in $textFiles) {
        if ([IO.File]::ReadAllText($file.FullName).IndexOf($value, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $problems.Add("A tenant value of the configuration appears in $($file.FullName.Substring($Destination.Length + 1)).")
        }
    }
}
# The package must import and load its configuration format.
try { [void](Import-PowerShellDataFile -LiteralPath $configTarget) } catch { $problems.Add("The packaged configuration is not valid: $($_.Exception.Message)") }
if ($problems.Count) { throw ("Package not valid ($Destination):`n - " + ($problems -join "`n - ")) }

$all = Get-ChildItem -LiteralPath $Destination -Recurse -File
if ($Zip) {
    $zipPath = "$Destination.zip"
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Compress-Archive -Path (Join-Path $Destination '*') -DestinationPath $zipPath -CompressionLevel Optimal
}
Write-Host ''
Write-Host "  Message Trace Report $version - package ready" -ForegroundColor Green
Write-Host "  Folder   : $Destination"
Write-Host ("  Content  : {0} files, {1:N1} MB" -f $all.Count, (($all | Measure-Object Length -Sum).Sum / 1MB))
if ($Zip) { Write-Host ("  Zip      : {0} ({1:N1} MB)" -f $zipPath, ((Get-Item $zipPath).Length / 1MB)) }
Write-Host "  Config   : tenant values emptied ($($emptied.Count)) - fill in Tenant and Authentication (guide, chapter 7)"
Write-Host ''
$all | Sort-Object FullName | ForEach-Object { '    {0,12:N0}  {1}' -f $_.Length, $_.FullName.Substring($Destination.Length + 1) }
