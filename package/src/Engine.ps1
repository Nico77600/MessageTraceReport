<#
    Message Trace Report - engine loading.

    Initialize-MtrEngine loads SQLite (lib\sqlite, unmodified binaries from nuget.org) and the C# engine.
    The engine is compiled from src\Engine.*.cs into bin\ the first time, and again only when a source
    file changes (the DLL name contains a hash of the sources). Nothing is installed on the computer.
#>

function Initialize-MtrEngine {
    [CmdletBinding()]
    param([string]$Root = $script:ToolRoot)
    if ('MessageTraceReport.Store' -as [type]) { return }
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
    $all = [Text.StringBuilder]::new()
    foreach ($f in $sources) { [void]$all.Append($f.Name).Append((Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash) }
    $hasher = [Security.Cryptography.SHA256]::Create()
    $hash = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($all.ToString()))).Replace('-', '').Substring(0, 16)
    $hasher.Dispose()
    $bin = Join-Path $Root 'bin'
    $dll = Join-Path $bin "MessageTraceReport.Engine.$hash.dll"
    if (-not (Test-Path -LiteralPath $dll)) {
        [void][IO.Directory]::CreateDirectory($bin)
        $references = @(
            (Join-Path $lib 'Microsoft.Data.Sqlite.dll'), 'System.IO.Compression', 'System.Text.Json', 'System.Text.Encodings.Web', 'System.Data.Common', 'System.Linq',
            'System.Collections', 'System.Collections.Concurrent', 'System.Text.RegularExpressions', 'System.Runtime', 'System.Memory', 'System.ComponentModel.Primitives',
            'System.ComponentModel', 'System.Transactions.Local', 'System.Text.Encoding.Extensions', 'System.Runtime.Extensions', 'System.IO', 'System.Runtime.InteropServices',
            'System.Console', 'System.Net.Http', 'System.Net.Primitives', 'System.Threading', 'System.Threading.Tasks', 'System.Private.Uri', 'netstandard')
        # Compiled to a unique name first: two consoles starting at the same time never write the same file.
        $staging = Join-Path $bin ("compile-{0}.dll" -f [guid]::NewGuid().ToString('N'))
        Add-Type -LiteralPath $sources.FullName -ReferencedAssemblies $references -OutputAssembly $staging -OutputType Library -IgnoreWarnings -WarningAction SilentlyContinue
        try { Move-Item -LiteralPath $staging -Destination $dll -Force -ErrorAction Stop } catch { if (-not (Test-Path -LiteralPath $dll)) { throw } }
        Get-ChildItem -LiteralPath $bin -Filter 'MessageTraceReport.Engine.*.dll' | Where-Object FullName -ne $dll | Remove-Item -Force -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $bin -Filter 'compile-*.dll' | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    if (-not ('MessageTraceReport.Store' -as [type])) { Add-Type -LiteralPath $dll }
}

function Open-MtrStore {
    <# Opens the database (created on first use). -ReadOnly: Report and Status modes. #>
    param([Parameter(Mandatory)]$Settings, [switch]$ReadOnly)
    $path = $Settings.Storage.DatabasePath
    if ($ReadOnly -and -not (Test-Path -LiteralPath $path)) { throw "The database does not exist yet: $path. Run a trace first (-Mode Trace) or a collection (-Mode Collect)." }
    return [MessageTraceReport.Store]::new($path, [bool]$ReadOnly, $script:ToolVersion)
}
