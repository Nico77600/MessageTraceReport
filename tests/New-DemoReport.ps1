#Requires -Version 7.4
<#
.SYNOPSIS
    Builds a demonstration report from fictitious Contoso data, without any connection to Microsoft 365.

.DESCRIPTION
    The data goes through the real engine: the in-memory message trace API of the tests (tests\FakeGraph.cs)
    answers the collector, the messages are stored in a temporary SQLite database, the route of the failed
    deliveries is read, and the HTML / CSV files are written as in a real run. Used for the screenshots of the
    documentation; also a quick way to see the report without a tenant.

.PARAMETER OutputPath
    Folder of the report. Default: a new folder in the temporary directory.

.PARAMETER Messages
    Number of messages generated over the last 7 days (default 2400).

.EXAMPLE
    .\tests\New-DemoReport.ps1 -Open

.NOTES
    Author  : Nicolas Fabert
    Version : 1.0.0
#>
[CmdletBinding()]
param([string]$OutputPath, [int]$Messages = 2400, [switch]$Open)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'MessageTraceReport.psd1') -Force
Initialize-MtrEngine -Root $root
if (-not ('MtrTests.FakeGraph' -as [type])) {
    Add-Type -LiteralPath (Join-Path $PSScriptRoot 'FakeGraph.cs') -ReferencedAssemblies @(
        'System.Net.Http', 'System.Net.Primitives', 'System.Text.Json', 'System.Linq', 'System.Collections', 'System.Text.RegularExpressions',
        'System.Runtime', 'System.Threading', 'System.Threading.Tasks', 'System.Private.Uri', 'System.Memory', 'System.Text.Encodings.Web', 'netstandard')
}
$work = Join-Path ([IO.Path]::GetTempPath()) ('MtrDemo-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
if (-not $OutputPath) { $OutputPath = Join-Path $work 'report' }
[void][IO.Directory]::CreateDirectory($work)

# ---- Fictitious tenant ------------------------------------------------------------------------------------
$rand = [Random]::new(20261002)
$people = @('adele.vance', 'alex.wilber', 'allan.deyoung', 'christie.cline', 'debra.berger', 'diego.siciliani', 'grady.archie', 'henrietta.mueller',
    'isaiah.langer', 'johanna.lorenz', 'joni.sherman', 'lee.gu', 'lidia.holloway', 'lynne.robbins', 'megan.bowen', 'miriam.graham', 'nestor.wilke',
    'patti.fernandez', 'pradeep.gupta') | ForEach-Object { "$_@contoso.com" }
$external = @('orders@fabrikam.com', 'support@tailspintoys.com', 'j.smith@northwindtraders.com', 'billing@wingtiptoys.com', 'events@adventure-works.com', 'contact@litware.com')
$robots = @('noreply@contoso.com', 'alerts@contoso.com', 'payroll@contoso.com')
$subjects = @('Weekly sales review', 'Q3 forecast - final version', 'Invoice {0}', 'Order confirmation {0}', 'Project Mercury status', 'Meeting notes',
    'Your password expires in 7 days', 'Release plan v{0}', 'Customer escalation #{0}', 'Lunch on Friday?', 'Contract renewal - Fabrikam', 'Travel request {0}',
    'Daily backup report', 'Security alert: new sign-in', 'Welcome to the team!', 'Budget 2027 - draft')
$g = [MtrTests.FakeGraph]::new()
$now = [DateTimeOffset]::UtcNow
$g.Now = $now
for ($i = 0; $i -lt $Messages; $i++) {
    $roll = $rand.NextDouble()
    $sender = if ($roll -lt 0.18) { $robots[$rand.Next($robots.Count)] } elseif ($roll -lt 0.30) { $external[$rand.Next($external.Count)] } else { $people[[int][Math]::Floor([Math]::Pow($rand.NextDouble(), 1.6) * $people.Count)] }
    $count = if ($sender -in $robots) { 1 + $rand.Next(3) } elseif ($rand.NextDouble() -lt 0.07) { 15 + $rand.Next(40) } else { 1 + $rand.Next(5) }
    $recipients = [Collections.Generic.List[string]]::new()
    while ($recipients.Count -lt $count) {
        $r = if ($rand.NextDouble() -lt 0.2) { $external[$rand.Next($external.Count)] } else { $people[$rand.Next($people.Count)] }
        if ($r -ne $sender -and -not $recipients.Contains($r)) { $recipients.Add($r) }
        if ($recipients.Count -ge $people.Count + $external.Count - 2) { break }
    }
    $statuses = foreach ($r in $recipients) {
        $s = $rand.NextDouble()
        if ($r -like '*@wingtiptoys.com' -and $s -lt 0.6) { 'failed' } elseif ($s -lt 0.025) { 'failed' } elseif ($s -lt 0.035) { 'quarantined' } elseif ($s -lt 0.045) { 'filteredAsSpam' } elseif ($s -lt 0.05) { 'pending' } else { 'delivered' }
    }
    # Working hours, weekdays busier.
    $day = $rand.Next(7)
    $hour = [Math]::Min(23, [Math]::Max(0, [int](8 + $rand.NextDouble() * 10 + ($rand.NextDouble() - 0.5) * 4)))
    $received = [DateTimeOffset]::new($now.UtcDateTime.Date, [TimeSpan]::Zero).AddDays(-$day).AddHours($hour - 2).AddMinutes($rand.Next(60)).AddSeconds($rand.Next(60))
    if ($received -gt $now.AddMinutes(-5)) { $received = $now.AddMinutes(-5 - $rand.Next(600)) }
    $subject = $subjects[$rand.Next($subjects.Count)] -f (1000 + $rand.Next(9000))
    $g.AddMessage($sender, [string[]]$recipients, $received, $subject, 'delivered', [string[]]$statuses)
}
foreach ($t in $g.Rows) { $t.Size = 8000 + ($t.Subject.Length * 911) % 120000; $t.FromIP = if ($t.Sender -like '*@contoso.com') { '' } else { '40.92.' + ($t.Sender.Length % 200) + '.' + ($t.Subject.Length % 250) } }

# ---- Same pipeline as a run: plan, collect, route, report --------------------------------------------------
$config = Join-Path $work 'demo.config.psd1'
@"
@{
    Tenant = @{ TenantId = '00000000-0000-0000-0000-000000000000'; Organization = 'contoso.onmicrosoft.com' }
    Authentication = @{ Mode = 'Certificate'; AppId = '00000000-0000-0000-0000-000000000001'; CertificateThumbprint = '$('0' * 40)' }
    Storage = @{ DatabasePath = '$work\demo.sqlite' }
    Report = @{ TimeZone = 'Europe/Paris'; OutputPath = '$work\reports' }
    Logging = @{ Path = '$work\logs' }
}
"@ | Set-Content -LiteralPath $config -Encoding utf8
$settings = Import-MtrConfiguration -Path $config -Root $root
$store = Open-MtrStore -Settings $settings
try {
    $filter = New-MtrFilter   # whole tenant
    $period = Resolve-MtrPeriod -Range Last7Days -Zone $settings.Zone
    $plan = Get-MtrQueryPlan $filter
    $workPlan = Get-MtrWorkPlan -Store $store -QueryPlan $plan -Period $period -Settings $settings
    $options = [MessageTraceReport.CollectorOptions]::new(); $options.Handler = $g; $options.MaxConcurrency = 3
    $connection = [ordered]@{ Mode = 'Certificate'; Account = 'demo'; Token = 'demo'; ExpiresMs = $now.AddHours(1).ToUnixTimeMilliseconds(); Renew = { @{ Token = 'demo'; ExpiresMs = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeMilliseconds() } } }
    $run = $store.StartRun('Trace', 'demo', 'demo', '1.0.0', 'demo')
    $collect = Invoke-MtrCollection -Store $store -Settings $settings -Connection $connection -WorkPlan $workPlan -RunId $run -Options $options 6>$null
    $selection = Select-MtrMessages -Store $store -Filter $filter -Period $period
    $details = Invoke-MtrDetails -Store $store -Settings $settings -Connection $connection -Items ($store.GetDetailCandidates(60, $true)) -Options $options 6>$null
    [void][IO.Directory]::CreateDirectory($OutputPath)
    $settings.Report.Title = 'Exchange Online message trace'
    $report = New-MtrReport -Store $store -Settings $settings -Filter $filter -Period $period -OutputDirectory $OutputPath -QueryPlan $plan
    $store.FinishRun($run, 'Succeeded', 1, $workPlan.Items.Count, $collect.Requests, $collect.Pages, $collect.Rows, $collect.NewDeliveries, 0, $null)
} finally { $store.Dispose() }
Write-Host ("Demo report: {0} messages, {1} deliveries, {2} routes -> {3}" -f $report.Messages, $report.Deliveries, $details.Done, $OutputPath)
$html = Join-Path $OutputPath 'MessageTrace.html'
if ($Open) { Invoke-Item $html }
[pscustomobject]@{ Folder = $OutputPath; Html = $html; Messages = $report.Messages; Deliveries = $report.Deliveries; Work = $work }
