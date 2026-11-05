<#
    Message Trace Report - engine loading.

    Initialize-MtrEngine loads SQLite (lib\sqlite, unmodified binaries from nuget.org) and the C# engine.
    The engine is compiled in memory from src\Engine.*.cs, after the package integrity check. Nothing is installed on
    the computer and no compiled file is loaded from the disk.
#>

function Initialize-MtrEngine {
    [CmdletBinding()]
    param([string]$Root = $script:ToolRoot)
    if ('MessageTraceReport.Store' -as [type]) { return }
    Assert-MtrPackageIntegrity -Root $Root
    $lib = Join-Path $Root 'lib\sqlite'
    $arch = if ([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq 'Arm64') { 'win-arm64' } else { 'win-x64' }
    $native = Join-Path $lib "runtimes\$arch\e_sqlite3.dll"
    if (-not (Test-Path -LiteralPath $native)) { throw "SQLite native library not found: $native" }
    [void][Runtime.InteropServices.NativeLibrary]::Load($native)
    foreach ($name in 'SQLitePCLRaw.core', 'SQLitePCLRaw.provider.e_sqlite3', 'SQLitePCLRaw.batteries_v2', 'Microsoft.Data.Sqlite') {
        Add-Type -LiteralPath (Join-Path $lib "$name.dll")
    }
    [SQLitePCL.Batteries_V2]::Init()

    $sources = @(Get-ChildItem -LiteralPath (Join-Path $Root 'src') -Filter 'Engine.*.cs' -File | Sort-Object Name)
    if (-not $sources.Count) { throw "Engine source files not found in $(Join-Path $Root 'src')." }
    # The engine is compiled in memory from the verified sources: no compiled file is loaded from the disk.
    $references = @(
        (Join-Path $lib 'Microsoft.Data.Sqlite.dll'), 'System.IO.Compression', 'System.Text.Json', 'System.Text.Encodings.Web', 'System.Data.Common', 'System.Linq',
        'System.Collections', 'System.Collections.Concurrent', 'System.Text.RegularExpressions', 'System.Runtime', 'System.Memory', 'System.ComponentModel.Primitives',
        'System.ComponentModel', 'System.Transactions.Local', 'System.Text.Encoding.Extensions', 'System.Runtime.Extensions', 'System.IO', 'System.Runtime.InteropServices',
        'System.Console', 'System.Net.Http', 'System.Net.Primitives', 'System.Threading', 'System.Threading.Tasks', 'System.Private.Uri', 'netstandard')
    Add-Type -LiteralPath $sources.FullName -ReferencedAssemblies $references -IgnoreWarnings -WarningAction SilentlyContinue
}

function Open-MtrStore {
    <# Opens the database (created on first use). -ReadOnly: Report and Status modes. #>
    param([Parameter(Mandatory)]$Settings, [switch]$ReadOnly)
    $path = $Settings.Storage.DatabasePath
    if ($ReadOnly -and -not (Test-Path -LiteralPath $path)) { throw "The database does not exist yet: $path. Run a trace first (-Mode Trace) or a collection (-Mode Collect)." }
    return [MessageTraceReport.Store]::new($path, [bool]$ReadOnly, $script:ToolVersion)
}
