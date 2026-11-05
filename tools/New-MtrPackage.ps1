#Requires -Version 7.4

<#
.SYNOPSIS
    Builds the Message Trace Report release package in three phases, so that the owner signs between them.

.DESCRIPTION
    Build (default): copies the files needed at run time into a separate folder and refuses to continue unless the
    PowerShell files of package\ carry the timestamped owner signature. No manifest is written.
        Invoke-MessageTraceReport.ps1, MessageTraceReport.psd1, MessageTraceReport.psm1, src\ (PowerShell and
        the C# engine sources, compiled in memory), lib\sqlite\, templates\, config\,
        docs\MessageTraceReport-UserGuide.html, docs\MessageTraceReport-Guide.html, README.md, CHANGELOG.md,
        LICENSE, THIRD-PARTY-NOTICES.md
    It never copies data\, reports\, logs\, bin\, the tests or the tools: no tenant data is in the package.
    The configuration file is copied with the tenant values emptied (TenantId, Organization, AppId,
    CertificateThumbprint, UserPrincipalName) and the Collect lists reset. The script then checks that none of
    the emptied values appears in the package and that every local link of README.md leads to a file of the package.

    -Unsigned (continuous integration): the same build without the signature requirement. The committed
    package\PackageIntegrity.psd1 is copied when it exists. The folder is verified with -DevelopmentMode.
    With -Zip, an '-unsigned-ci' ZIP is written; it is never a release.

    -Manifest <package folder>: hashes the built folder and writes an unsigned PackageIntegrity.psd1 there.
    The owner signs it.

    -Seal <package folder>: verifies the signed manifest (copied from package\PackageIntegrity.psd1) on the built
    folder and on package\, compares the bytes of every protected file with the repository, then writes the release
    ZIP MessageTraceReport-<version>.zip, with the single root folder MessageTraceReport-<version>\, next to the
    package folder, and prints its SHA-256.

    Signing key material is never read by this script.

.PARAMETER Destination
    Package folder. Default: package\MessageTraceReport-<version>, next to the repository folder.

.PARAMETER Force
    Replace the destination folder if it already contains a package. A folder with a data\ or reports\
    sub-folder (a package that has been run) is never replaced.

.PARAMETER Unsigned
    Continuous-integration build of an unsigned tree.

.PARAMETER Zip
    With -Unsigned: also writes the '-unsigned-ci' ZIP.

.PARAMETER Manifest
    Package folder to hash.

.PARAMETER Seal
    Package folder, with the signed manifest, to verify and zip.

.EXAMPLE
    .\tools\New-MtrPackage.ps1 -Destination C:\work\package-out\MessageTraceReport -Unsigned -Zip

.NOTES
    Author  : Nicolas Fabert
    Version : 1.1.1
#>
[CmdletBinding(DefaultParameterSetName = 'Build')]
param(
    [Parameter(ParameterSetName = 'Build')][string]$Destination,
    [Parameter(ParameterSetName = 'Build')][switch]$Force,
    [Parameter(ParameterSetName = 'Build')][switch]$Unsigned,
    [Parameter(ParameterSetName = 'Build')][switch]$Zip,
    [Parameter(ParameterSetName = 'Manifest', Mandatory)][string]$Manifest,
    [Parameter(ParameterSetName = 'Seal', Mandatory)][string]$Seal
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$packageRoot = Join-Path $root 'package'
$version = (Import-PowerShellDataFile (Join-Path $packageRoot 'MessageTraceReport.psd1')).ModuleVersion
$signer = '0F28E442889F17B5F4D251E8F96E7CC6E2C9C6D6'
$rootFolderName = "MessageTraceReport-$version"
$signedScripts = @('Invoke-MessageTraceReport.ps1', 'MessageTraceReport.psm1', 'MessageTraceReport.psd1',
    'src\Collection.ps1', 'src\Configuration.ps1', 'src\Connection.ps1', 'src\Console.ps1', 'src\Engine.ps1', 'src\Filter.ps1',
    'src\Report.ps1', 'src\Route.ps1', 'src\Status.ps1', 'src\Test-PackageIntegrity.ps1')
$configRelative = 'config\MessageTraceReport.config.psd1'

function Get-RelativeFile([string]$Base) {
    Get-ChildItem -LiteralPath $Base -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($Base.Length + 1) } | Sort-Object { $_ } -CaseSensitive
}
function Assert-OwnerSigned([string]$Path) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ([string]$signature.Status -cne 'Valid' -or $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Thumbprint -cne $signer -or $null -eq $signature.TimeStamperCertificate) {
        throw "Not signed with the trusted, timestamped owner certificate ($($signature.Status)): $Path"
    }
}
function Write-Manifest([string]$Package) {
    $text = [Text.StringBuilder]::new()
    [void]$text.AppendLine('@{')
    [void]$text.AppendLine('    SchemaVersion = 1')
    [void]$text.AppendLine("    Algorithm = 'SHA256'")
    [void]$text.AppendLine("    SignerThumbprint = '$signer'")
    [void]$text.AppendLine("    Version = '$version'")
    [void]$text.AppendLine('    Files = @(')
    foreach ($relative in Get-RelativeFile $Package) {
        if ($relative -ceq 'PackageIntegrity.psd1' -or $relative -ceq $configRelative) { continue }
        if ($relative.Contains("'")) { throw "A packaged path contains a quote: $relative" }
        $hash = (Get-FileHash -LiteralPath (Join-Path $Package $relative) -Algorithm SHA256).Hash
        [void]$text.AppendLine("        @{ Path = '$relative'; Sha256 = '$hash' }")
    }
    [void]$text.AppendLine('    )')
    [void]$text.AppendLine('}')
    $target = Join-Path $Package 'PackageIntegrity.psd1'
    [IO.File]::WriteAllText($target, ($text.ToString() -replace "`r?`n", "`r`n"), [Text.UTF8Encoding]::new($false))
    $target
}
function Test-ReadmeLink([string]$Package) {
    # Every local link of the packaged README must lead to a file of the package.
    $readme = [IO.File]::ReadAllText((Join-Path $Package 'README.md'))
    $bad = [Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($readme, '\]\(([^)\s]+)\)')) {
        $target = $m.Groups[1].Value
        if ($target -match '^(https?:|mailto:|#)') { continue }
        $file = ($target -split '#')[0]
        if (-not $file) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $Package $file) -PathType Leaf)) { $bad.Add($target) }
    }
    $bad
}
function New-RootedZip([string]$Package, [string]$ZipPath) {
    if (Test-Path -LiteralPath $ZipPath) { throw "The ZIP already exists: $ZipPath" }
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::Open($ZipPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($relative in Get-RelativeFile $Package) {
            $entry = "$rootFolderName/" + $relative.Replace('\', '/')
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, (Join-Path $Package $relative), $entry, [IO.Compression.CompressionLevel]::Optimal)
        }
    } finally { $archive.Dispose() }
}

# ---- -Manifest ------------------------------------------------------------------------------------------
if ($PSCmdlet.ParameterSetName -eq 'Manifest') {
    $Manifest = [IO.Path]::GetFullPath($Manifest, (Get-Location).Path).TrimEnd('\')
    foreach ($relative in $signedScripts) { Assert-OwnerSigned (Join-Path $Manifest $relative) }
    $bad = @(Test-ReadmeLink $Manifest)
    if ($bad.Count) { throw "README.md links files that are not in the package: $($bad -join ', ')" }
    $path = Write-Manifest $Manifest
    Write-Output "Unsigned manifest written: $path"
    Write-Output "Sign it, then copy the signed file to $(Join-Path $packageRoot 'PackageIntegrity.psd1') and run: .\tools\New-MtrPackage.ps1 -Seal `"$Manifest`""
    return
}

# ---- -Seal ----------------------------------------------------------------------------------------------
if ($PSCmdlet.ParameterSetName -eq 'Seal') {
    $Seal = [IO.Path]::GetFullPath($Seal, (Get-Location).Path).TrimEnd('\')
    foreach ($name in 'data', 'reports', 'logs', 'bin') {
        if (Test-Path -LiteralPath (Join-Path $Seal $name)) { throw "The folder contains a $name\ folder (a package that has been run, or generated files): build a clean folder instead: $Seal" }
    }
    $signedManifest = Join-Path $packageRoot 'PackageIntegrity.psd1'
    if (-not (Test-Path -LiteralPath $signedManifest)) { throw "Copy the signed manifest to $signedManifest first." }
    $sealed = Join-Path $Seal 'PackageIntegrity.psd1'
    if (-not (Test-Path -LiteralPath $sealed) -or (Get-FileHash -LiteralPath $signedManifest -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $sealed -Algorithm SHA256).Hash) {
        Copy-Item -LiteralPath $signedManifest -Destination $sealed -Force
    }
    $result = & (Join-Path $Seal 'src\Test-PackageIntegrity.ps1') -Root $Seal -Distribution
    if ($result.Status -cne 'Valid') { throw 'The built package is not Valid.' }
    $sourceResult = & (Join-Path $packageRoot 'src\Test-PackageIntegrity.ps1') -Root $packageRoot
    if ($sourceResult.Status -notlike 'Valid*') { throw 'The repository package folder is not Valid.' }
    foreach ($relative in Get-RelativeFile $Seal) {
        $sourceFile = Join-Path $packageRoot $relative
        if ($relative -ceq $configRelative -or -not (Test-Path -LiteralPath $sourceFile)) { continue }
        if ((Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath (Join-Path $Seal $relative) -Algorithm SHA256).Hash) {
            throw "The packaged file differs from the repository file: $relative"
        }
    }
    if ((Get-FileHash -LiteralPath (Join-Path $root 'CHANGELOG.md') -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath (Join-Path $Seal 'CHANGELOG.md') -Algorithm SHA256).Hash) {
        throw 'The packaged CHANGELOG.md differs from the CHANGELOG.md of the repository.'
    }
    $bad = @(Test-ReadmeLink $Seal)
    if ($bad.Count) { throw "README.md links files that are not in the package: $($bad -join ', ')" }
    $zipPath = Join-Path (Split-Path $Seal -Parent) "$rootFolderName.zip"
    New-RootedZip $Seal $zipPath
    [pscustomobject]@{
        Package = $Seal; Zip = $zipPath; ZipBytes = (Get-Item -LiteralPath $zipPath).Length
        ZipSha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
        Files = $result.Files; RootFolder = $rootFolderName; Signed = $true; Published = $false
    } | ConvertTo-Json
    return
}

# ---- Build ----------------------------------------------------------------------------------------------
if ($Zip -and -not $Unsigned) { throw 'The release ZIP is written by -Seal, after the manifest is signed. -Zip is for -Unsigned builds.' }
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
if (-not $Unsigned) { foreach ($relative in $signedScripts) { Assert-OwnerSigned (Join-Path $packageRoot $relative) } }

# ---- Files needed at run time ---------------------------------------------------------------------------
$files = [Collections.Generic.List[string]]::new()
foreach ($f in 'Invoke-MessageTraceReport.ps1', 'MessageTraceReport.psd1', 'MessageTraceReport.psm1', 'README.md', 'CHANGELOG.md', 'LICENSE', 'THIRD-PARTY-NOTICES.md',
    'templates\Report.template.html', 'docs\MessageTraceReport-UserGuide.html', 'docs\MessageTraceReport-Guide.html') { $files.Add($f) }
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
foreach ($link in Test-ReadmeLink $Destination) { $problems.Add("README.md links a file that is not in the package: $link") }
# The package must import and load its configuration format.
try { [void](Import-PowerShellDataFile -LiteralPath $configTarget) } catch { $problems.Add("The packaged configuration is not valid: $($_.Exception.Message)") }
if ($problems.Count) { throw ("Package not valid ($Destination):`n - " + ($problems -join "`n - ")) }

if ($Unsigned) {
    $committed = Join-Path $packageRoot 'PackageIntegrity.psd1'
    if (Test-Path -LiteralPath $committed) {
        Copy-Item -LiteralPath $committed -Destination (Join-Path $Destination 'PackageIntegrity.psd1')
        & (Join-Path $Destination 'src\Test-PackageIntegrity.ps1') -Root $Destination -DevelopmentMode | Out-Null
    } else {
        Write-Warning 'package\PackageIntegrity.psd1 is not committed: this unsigned build carries no manifest.'
    }
}

$all = Get-ChildItem -LiteralPath $Destination -Recurse -File
if ($Zip) {
    $zipPath = Join-Path (Split-Path $Destination -Parent) "$rootFolderName-unsigned-ci.zip"
    New-RootedZip $Destination $zipPath
}
Write-Host ''
Write-Host "  Message Trace Report $version - package ready" -ForegroundColor Green
Write-Host "  Folder   : $Destination"
Write-Host ("  Content  : {0} files, {1:N1} MB" -f $all.Count, (($all | Measure-Object Length -Sum).Sum / 1MB))
if ($Zip) { Write-Host ("  Zip      : {0} ({1:N1} MB, root folder {2}\)" -f $zipPath, ((Get-Item $zipPath).Length / 1MB), $rootFolderName) }
Write-Host "  Config   : tenant values emptied ($($emptied.Count)) - fill in Tenant and Authentication (user guide, chapter 2)"
if (-not $Unsigned) { Write-Host "  Next     : .\tools\New-MtrPackage.ps1 -Manifest `"$Destination`"" }
Write-Host ''
$all | Sort-Object FullName | ForEach-Object { '    {0,12:N0}  {1}' -f $_.Length, $_.FullName.Substring($Destination.Length + 1) }
