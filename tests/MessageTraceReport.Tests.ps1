#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Message Trace Report - automated tests (Pester 5 or later).
    Author  : Nicolas Fabert
    Version : 1.0.0

    Run:  Invoke-Pester -Path .\tests -Output Detailed

    No connection to Microsoft 365 is made. Microsoft Graph is replaced by an in-memory message trace API
    (tests\FakeGraph.cs) that behaves like the real one measured in the lab: one value per property in
    $filter, newest first, paging, 10-day windows, 90-day history, and failures on demand (429, 401, 500, 403).
#>

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:Root 'MessageTraceReport.psd1') -Force
    Initialize-MtrEngine -Root $script:Root
    if (-not ('MtrTests.FakeGraph' -as [type])) {
        Add-Type -LiteralPath (Join-Path $PSScriptRoot 'FakeGraph.cs') -ReferencedAssemblies @(
            'System.Net.Http', 'System.Net.Primitives', 'System.Text.Json', 'System.Linq', 'System.Collections', 'System.Text.RegularExpressions',
            'System.Runtime', 'System.Threading', 'System.Threading.Tasks', 'System.Private.Uri', 'System.Memory', 'System.Text.Encodings.Web', 'netstandard')
    }
    $script:Work = Join-Path ([IO.Path]::GetTempPath()) ('MtrTests-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($script:Work)
    $script:Paris = Get-MtrTimeZone 'Europe/Paris'

    function New-TestConfiguration {
        <# A valid configuration (fictitious tenant), with its own database (absolute paths: relative ones are relative to the tool folder). #>
        param([string]$Name = ([guid]::NewGuid().ToString('N')), [hashtable]$Report = @{})
        $dir = Join-Path $script:Work $Name
        [void][IO.Directory]::CreateDirectory($dir)
        $path = Join-Path $dir 'test.config.psd1'
        $reportText = ($Report.GetEnumerator() | ForEach-Object { "        $($_.Key) = $($_.Value)" }) -join "`n"
        @"
@{
    Tenant = @{ TenantId = '11111111-1111-1111-1111-111111111111'; Organization = 'contoso.onmicrosoft.com' }
    Authentication = @{ Mode = 'Certificate'; AppId = '22222222-2222-2222-2222-222222222222'; CertificateThumbprint = '$('A' * 40)' }
    Collection = @{ MaxConcurrency = 2; MaxRetries = 2; RequestTimeoutSeconds = 30 }
    Storage = @{ DatabasePath = '$dir\data\test.sqlite'; RetentionDays = 30 }
    Report = @{
        TimeZone = 'Europe/Paris'; OutputPath = '$dir\reports'
$reportText
    }
    Logging = @{ Path = '$dir\logs' }
}
"@ | Set-Content -LiteralPath $path -Encoding utf8
        $s = Import-MtrConfiguration -Path $path -Root $dir
        $s.Report.TemplatePath = Join-Path $script:Root 'templates\Report.template.html'
        return $s
    }

    function New-TestCollector {
        param([MtrTests.FakeGraph]$Graph, $Store, [int]$Concurrency = 2, [int]$PageSize = 5000)
        $o = [MessageTraceReport.CollectorOptions]::new()
        $o.Handler = $Graph; $o.MaxConcurrency = $Concurrency; $o.PageSize = $PageSize; $o.MaxRetries = 2; $o.TimeoutSeconds = 30; $o.DefaultRetryAfterSeconds = 1
        $slot = [MessageTraceReport.TokenSlot]::new(); $slot.Set('token-1', [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeMilliseconds())
        $limiter = [MessageTraceReport.RateLimiter]::new(100, 300000, $null)
        $run = $Store.StartRun('Trace', 'test', 'test', '1.0.0', 'test')
        [pscustomobject]@{ Collector = [MessageTraceReport.Collector]::new($Store, $o, $slot, $limiter, $run); Slot = $slot; Options = $o; RunId = $run }
    }

    function New-FakeConnection {
        [ordered]@{ Mode = 'Certificate'; Account = 'test'; Token = 'token-1'; ExpiresMs = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeMilliseconds()
            Renew = { param($s, $c) @{ Token = 'token-2'; ExpiresMs = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeMilliseconds() } } }
    }

    function Invoke-TestCollection {
        <# Plans and collects a filter on a period with the fake Graph (Invoke-MtrCollection, the real progress loop). #>
        param($Settings, $Store, [MtrTests.FakeGraph]$Graph, $Filter, $Period, [switch]$Refresh, [int]$PageSize = 5000)
        $plan = Get-MtrQueryPlan $Filter
        $work = Get-MtrWorkPlan -Store $Store -QueryPlan $plan -Period $Period -Settings $Settings -Refresh:$Refresh
        $o = [MessageTraceReport.CollectorOptions]::new()
        $o.Handler = $Graph; $o.MaxConcurrency = 2; $o.PageSize = $PageSize; $o.MaxRetries = 2; $o.TimeoutSeconds = 30; $o.DefaultRetryAfterSeconds = 1
        $run = $Store.StartRun('Trace', 'test', 'test', '1.0.0', 'test')
        $result = Invoke-MtrCollection -Store $Store -Settings $Settings -Connection (New-FakeConnection) -WorkPlan $work -RunId $run -Options $o 6>$null
        [pscustomobject]@{ Plan = $plan; Work = $work; Result = $result }
    }

    function New-Period([DateTimeOffset]$Start, [DateTimeOffset]$End) {
        [pscustomobject]@{ Range = 'Custom'; StartMs = $Start.ToUnixTimeMilliseconds(); EndMs = $End.ToUnixTimeMilliseconds() }
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Configuration' {
    It 'reports every missing value of the delivered configuration at once' {
        $path = Join-Path $script:Root 'config\MessageTraceReport.config.psd1'
        { Import-MtrConfiguration -Path $path -Root $script:Root } | Should -Throw -ExpectedMessage '*Tenant.TenantId is required*Authentication.AppId*CertificateThumbprint*'
    }
    It 'applies the defaults and resolves the paths' {
        $s = New-TestConfiguration
        $s.Collection.PageSize | Should -Be 5000
        $s.Collection.WindowHours | Should -Be 240
        $s.Throttling.MaxRequests | Should -Be 90
        $s.Report.Formats | Should -Be @('Csv', 'Html')
        [IO.Path]::IsPathRooted($s.Storage.DatabasePath) | Should -BeTrue
        $s.Zone.BaseUtcOffset.TotalHours | Should -Be 1
    }
    It 'refuses values out of range and unknown modes' {
        $path = Join-Path $script:Work 'bad.config.psd1'
        "@{ Tenant = @{ TenantId = 'x' }; Authentication = @{ Mode = 'Password' }; Collection = @{ PageSize = 9000; WindowHours = 300 }; Throttling = @{ MaxRequests = 150 }; Report = @{ Formats = @('Pdf'); CsvDelimiter = '#' } }" | Set-Content $path
        { Import-MtrConfiguration -Path $path -Root $script:Work } | Should -Throw -ExpectedMessage '*PageSize*WindowHours*MaxRequests*GUID*Mode must be*Formats*CsvDelimiter*'
    }
}

Describe 'Periods' {
    It 'resolves rolling ranges ending now, on whole seconds' {
        $now = [DateTimeOffset]::new(2026, 10, 2, 14, 30, 15, 500, [TimeSpan]::Zero)
        $p = Resolve-MtrPeriod -Range Last48Hours -Zone $script:Paris -Now $now
        $p.EndMs | Should -Be ($now.ToUnixTimeMilliseconds() - 500)
        ($p.EndMs - $p.StartMs) | Should -Be (2 * 86400000)
    }
    It 'resolves a calendar day in the report time zone, across a DST change' {
        $p = Resolve-MtrPeriod -Range Day -Date '2026-10-25' -Zone $script:Paris -Now ([DateTimeOffset]::new(2026, 11, 1, 0, 0, 0, [TimeSpan]::Zero))
        ($p.EndMs - $p.StartMs) / 3600000 | Should -Be 25
        [DateTimeOffset]::FromUnixTimeMilliseconds($p.StartMs).UtcDateTime | Should -Be ([datetime]'2026-10-24T22:00:00')
    }
    It 'reads -Start alone as Custom up to now, and accepts the text of a [datetime]' {
        $now = [DateTimeOffset]::new(2026, 10, 2, 12, 0, 0, [TimeSpan]::Zero)
        $p = Resolve-MtrPeriod -Start '10/01/2026 08:00:00' -Zone $script:Paris -Now $now
        $p.Range | Should -Be 'Custom'
        [DateTimeOffset]::FromUnixTimeMilliseconds($p.StartMs).UtcDateTime | Should -Be ([datetime]'2026-10-01T06:00:00')
        $p.EndMs | Should -Be $now.ToUnixTimeMilliseconds()
    }
    It 'keeps an explicit offset and refuses an empty period' {
        $p = Resolve-MtrPeriod -Start '2026-09-01T00:00:00Z' -End '2026-09-02T00:00:00+02:00' -Zone $script:Paris -Now ([DateTimeOffset]::new(2026, 10, 2, 0, 0, 0, [TimeSpan]::Zero))
        ($p.EndMs - $p.StartMs) / 3600000 | Should -Be 22
        { Resolve-MtrPeriod -Start '2026-09-02' -End '2026-09-01' -Zone $script:Paris } | Should -Throw '*empty*'
    }
    It 'computes the oldest date of the Graph history at 00:00 UTC' {
        $e = Get-MtrEarliestMs -Days 90 -Now ([DateTimeOffset]::new(2026, 10, 2, 15, 0, 0, [TimeSpan]::Zero))
        [DateTimeOffset]::FromUnixTimeMilliseconds($e).UtcDateTime | Should -Be ([datetime]'2026-07-04T00:00:00')
    }
}

Describe 'Filter' {
    It 'normalizes addresses and accepts *@domain' {
        $f = New-MtrFilter -Sender ' <John@Contoso.com> ', 'smtp:Mary@contoso.com;*@Fabrikam.com' -Recipient 'a@b.com'
        @($f.Senders) | Should -Be @('john@contoso.com', 'mary@contoso.com', '*@fabrikam.com')
        $f.OrMode | Should -BeFalse
    }
    It 'reports every invalid value at once' {
        { New-MtrFilter -Sender 'not-an-address', 'john*@contoso.com' -Status 'Lost' -FromIP '999.1.1.1' -Subject 'a*b' } |
            Should -Throw -ExpectedMessage '*Sender: 2 value(s)*Graph applies only*@domain*Subject*Status*Lost*FromIP*'
    }
    It 'accepts patterns in Report mode only' {
        $f = New-MtrFilter -Sender 'sales-*@contoso.com' -AllowPatterns
        $f.Senders[0] | Should -Be 'sales-*@contoso.com'
        $f.HasPatterns | Should -BeTrue
    }
    It 'canonicalizes statuses and message IDs' {
        $f = New-MtrFilter -Status 'FAILED', 'spam', 'Quarantined' -MessageId 'abc@contoso.com', '<def@contoso.com>'
        @($f.Statuses) | Should -Be @('failed', 'filteredAsSpam', 'quarantined')
        @($f.MessageIds) | Should -Be @('<abc@contoso.com>', '<def@contoso.com>')
    }
    It 'reads addresses from a CSV (column detected, ; delimiter) and from a text file' {
        $csv = Join-Path $script:Work 'vip.csv'
        "DisplayName;PrimarySmtpAddress`nJohn;john@contoso.com`nMary;MARY@contoso.com`n;" | Set-Content $csv -Encoding utf8
        $txt = Join-Path $script:Work 'list.txt'
        "# VIP`nanne@contoso.com`n`n bob@contoso.com " | Set-Content $txt -Encoding utf8
        @(Read-MtrAddressFile $csv) | Should -Be @('john@contoso.com', 'MARY@contoso.com')
        @(Read-MtrAddressFile $txt) | Should -Be @('anne@contoso.com', 'bob@contoso.com')
        $f = New-MtrFilter -SenderFile $csv -RecipientFile $txt
        $f.Senders.Count | Should -Be 2; $f.Recipients.Count | Should -Be 2
        { Read-MtrAddressFile $csv -Column 'Mail' } | Should -Throw "*Column 'Mail' not found*"
    }
}

Describe 'Query planner' {
    It 'sends one query per sender: Graph keeps only one value per property' {
        $p = Get-MtrQueryPlan (New-MtrFilter -Sender 'a@contoso.com', 'b@contoso.com', 'c@contoso.com')
        $p.Queries.Count | Should -Be 3
        $p.Queries | ForEach-Object { $_.ODataFilter(0, 1000) } | Should -Not -Match ' or '
    }
    It 'pushes the shorter list for senders AND recipients and filters the other one locally' {
        $p = Get-MtrQueryPlan (New-MtrFilter -Sender 'admin@contoso.com' -Recipient 'a@x.com', 'b@x.com', 'c@x.com')
        $p.Queries.Count | Should -Be 1
        $p.Queries[0].Signature | Should -Be 'sender.eq=admin@contoso.com'
        $p.LocalFilters | Should -Match 'recipient in the list of 3'
        $p = Get-MtrQueryPlan (New-MtrFilter -Sender 'a@x.com', 'b@x.com', 'c@x.com' -Recipient 'boss@contoso.com', 'cfo@contoso.com')
        $p.Queries.Count | Should -Be 2
        @($p.Queries | ForEach-Object { $_.Conditions[0].Field }) | Should -Be @('recipient', 'recipient')
    }
    It 'puts one sender and one recipient in the same query' {
        $p = Get-MtrQueryPlan (New-MtrFilter -Sender 'a@x.com' -Recipient 'b@x.com')
        $p.Queries.Count | Should -Be 1
        $p.Queries[0].ODataFilter(0, 1000) | Should -Match "recipientAddress eq 'b@x.com' and senderAddress eq 'a@x.com'"
    }
    It 'sends one query per sender and per recipient with -Operator Or' {
        $p = Get-MtrQueryPlan (New-MtrFilter -Sender 'a@x.com', 'b@x.com' -Recipient 'c@x.com' -Operator Or)
        $p.Queries.Count | Should -Be 3
    }
    It 'adds the single-value conditions to every query, with quotes doubled' {
        $p = Get-MtrQueryPlan (New-MtrFilter -Sender 'a@x.com', 'b@x.com' -Subject "O'Brien report" -SubjectMatch StartsWith -FromIP '10.1.2.3' -Status Failed)
        foreach ($q in $p.Queries) { $q.ODataFilter(0, 1000) | Should -Match "and fromIP eq '10.1.2.3' and senderAddress eq '[ab]@x.com' and status eq 'failed' and startswith\(subject, 'O''Brien report'\)$" }
    }
    It 'splits several statuses only when they reduce the volume' {
        (Get-MtrQueryPlan (New-MtrFilter -Status Failed, Quarantined)).Queries.Count | Should -Be 2
        (Get-MtrQueryPlan (New-MtrFilter -Sender 'a@x.com' -Status Failed, Quarantined)).Queries.Count | Should -Be 2
        $p = Get-MtrQueryPlan (New-MtrFilter -Sender 'a@x.com', 'b@x.com', 'c@x.com' -Status Failed, Quarantined)
        $p.Queries.Count | Should -Be 3
        $p.LocalFilters | Should -Match 'status in'
    }
    It 'writes the time bounds on whole seconds: start floored, end rounded up, le (never lt)' {
        $q = [MessageTraceReport.QuerySpec]::Create([MessageTraceReport.Condition[]]@())
        $q.ODataFilter(1759400000500, 1759400060001) | Should -Be 'receivedDateTime ge 2025-10-02T10:13:20Z and receivedDateTime le 2025-10-02T10:14:21Z'
    }
}

Describe 'Coverage and windows' {
    BeforeAll {
        $script:Day = 86400000L
        $script:Now = [DateTimeOffset]::new(2026, 10, 2, 12, 0, 0, [TimeSpan]::Zero).ToUnixTimeMilliseconds()
        function Known([string]$Signature, [long]$Start, [long]$End) {
            $k = [MessageTraceReport.KnownCoverage]::new(); $k.Signature = $Signature; $k.Conditions = [MessageTraceReport.QuerySpec]::ParseSignature($Signature)
            $k.Ranges.Add([MessageTraceReport.TimeRange]::new($Start, $End)); return $k
        }
        function Plan([string[]]$Sender, $Known, [long]$Start, [long]$End, [long]$Earliest = 0) {
            $q = Get-MtrQueryPlan (New-MtrFilter -Sender $Sender)
            $list = [Collections.Generic.List[MessageTraceReport.KnownCoverage]]::new(); foreach ($k in @($Known)) { if ($k) { $list.Add($k) } }
            [MessageTraceReport.Planner]::Windows($q.Queries, $list, $Start, $End, $Earliest, 240 * 3600000L, 24 * 3600000L, 4)
        }
    }
    It 'cuts a long period into windows of at most 10 days, newest first' {
        $w = Plan @('a@x.com') $null ($script:Now - 25 * $script:Day) $script:Now
        $w.Items.Count | Should -Be 3
        ($w.Items | ForEach-Object { $_.EndMs - $_.StartMs } | Measure-Object -Maximum).Maximum | Should -Be (10 * $script:Day)
        $w.Items[0].EndMs | Should -Be $script:Now
    }
    It 'skips what the same query already collected' {
        $w = Plan @('a@x.com') (Known 'sender.eq=a@x.com' ($script:Now - 5 * $script:Day) $script:Now) ($script:Now - 7 * $script:Day) $script:Now
        $w.Items.Count | Should -Be 1
        ($w.Items[0].EndMs - $w.Items[0].StartMs) | Should -Be (2 * $script:Day)
    }
    It 'reuses a wider collection: the whole tenant, or a *@domain' {
        (Plan @('a@x.com') (Known '' ($script:Now - 7 * $script:Day) $script:Now) ($script:Now - 7 * $script:Day) $script:Now).Items.Count | Should -Be 0
        (Plan @('a@x.com') (Known 'sender.eq=*@x.com' ($script:Now - 7 * $script:Day) $script:Now) ($script:Now - 7 * $script:Day) $script:Now).Items.Count | Should -Be 0
        (Plan @('a@x.com') (Known 'sender.eq=b@x.com' ($script:Now - 7 * $script:Day) $script:Now) ($script:Now - 7 * $script:Day) $script:Now).Items.Count | Should -Be 1
        (Plan @('a@y.com') (Known 'sender.eq=*@x.com' ($script:Now - 7 * $script:Day) $script:Now) ($script:Now - 7 * $script:Day) $script:Now).Items.Count | Should -Be 1
    }
    It 'knows which subject conditions include another one' {
        $wide = [MessageTraceReport.Condition]::new('subject', 'contains', 'invoice')
        $wide.Covers([MessageTraceReport.Condition]::new('subject', 'eq', 'Your INVOICE 42')) | Should -BeTrue
        $wide.Covers([MessageTraceReport.Condition]::new('subject', 'startswith', 'Invoices')) | Should -BeTrue
        [MessageTraceReport.Condition]::new('subject', 'startswith', 'inv').Covers([MessageTraceReport.Condition]::new('subject', 'contains', 'invoice')) | Should -BeFalse
        [MessageTraceReport.Condition]::new('sender', 'eq', 'a@x.com').Covers([MessageTraceReport.Condition]::new('recipient', 'eq', 'a@x.com')) | Should -BeFalse
    }
    It 'reports what is older than the Graph history and not in the database as unrecoverable' {
        $w = Plan @('a@x.com') $null ($script:Now - 100 * $script:Day) $script:Now ($script:Now - 90 * $script:Day)
        $w.UnrecoverableMs | Should -Be (10 * $script:Day)
        $w.Unrecoverable.Count | Should -Be 1
        ($w.Items | ForEach-Object { $_.StartMs } | Measure-Object -Minimum).Minimum | Should -Be ($script:Now - 90 * $script:Day)
    }
    It 'reads a whole-tenant period in several windows, so that they run in parallel' {
        $q = Get-MtrQueryPlan (New-MtrFilter)
        $w = [MessageTraceReport.Planner]::Windows($q.Queries, $null, $script:Now - 2 * 3600000, $script:Now, 0, 240 * 3600000L, 24 * 3600000L, 4)
        $w.Items.Count | Should -Be 4
        $w = [MessageTraceReport.Planner]::Windows($q.Queries, $null, $script:Now - 3 * $script:Day, $script:Now, 0, 240 * 3600000L, 24 * 3600000L, 4)
        ($w.Items | ForEach-Object { $_.EndMs - $_.StartMs } | Measure-Object -Maximum).Maximum | Should -BeLessOrEqual $script:Day
    }
}

Describe 'Rate limiter' {
    It 'lets MaxRequests requests through, then waits for the oldest to leave the window' {
        $l = [MessageTraceReport.RateLimiter]::new(3, 1500, $null)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        1..3 | ForEach-Object { $l.WaitAsync([Threading.CancellationToken]::None).Wait() }
        $sw.ElapsedMilliseconds | Should -BeLessThan 500
        $l.InWindow | Should -Be 3
        $l.WaitAsync([Threading.CancellationToken]::None).Wait()
        $sw.ElapsedMilliseconds | Should -BeGreaterOrEqual 1400
    }
    It 'counts the requests of the previous run and honours a pause (429)' {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $l = [MessageTraceReport.RateLimiter]::new(2, 60000, [long[]]@(($now - 1000), ($now - 2000), ($now - 120000)))
        $l.InWindow | Should -Be 2
        $l.DelayMs() | Should -BeGreaterThan 50000
        $l2 = [MessageTraceReport.RateLimiter]::new(10, 60000, $null)
        $l2.Pause(1200)
        $sw = [Diagnostics.Stopwatch]::StartNew(); $l2.WaitAsync([Threading.CancellationToken]::None).Wait()
        $sw.ElapsedMilliseconds | Should -BeGreaterOrEqual 1100
    }
}

Describe 'Collection with the fake Graph' {
    BeforeAll {
        $script:S = New-TestConfiguration -Name 'collect'
        $script:Store = Open-MtrStore -Settings $script:S
        $script:G = [MtrTests.FakeGraph]::new()
        $now = [DateTimeOffset]::UtcNow
        $script:G.Now = $now
        # 30 messages of alice to 3 recipients (one failed), 12 of bob, 2 hours apart, over the last 4 days.
        for ($i = 0; $i -lt 30; $i++) { $script:G.AddMessage('alice@contoso.com', [string[]]@('x@fabrikam.com', 'y@fabrikam.com', 'z@contoso.com'), $now.AddHours(-2 * $i - 1), "Report $i", 'delivered', [string[]]@('delivered', 'failed', 'delivered')) }
        for ($i = 0; $i -lt 12; $i++) { $script:G.AddMessage('bob@contoso.com', [string[]]@('x@fabrikam.com'), $now.AddHours(-3 * $i - 1), "=SUM(A1) $i") }
        $script:Period = New-Period $now.AddDays(-4) $now.AddMinutes(-1)
    }
    AfterAll { $script:Store.Dispose() }

    It 'collects every page and stores each message and delivery once' {
        $r = Invoke-TestCollection -Settings $script:S -Store $script:Store -Graph $script:G -Filter (New-MtrFilter -Sender 'alice@contoso.com', 'bob@contoso.com') -Period $script:Period -PageSize 7
        $r.Result.Done | Should -Be 2
        $r.Result.Failed.Count | Should -Be 0
        $r.Result.Rows | Should -Be 102
        $r.Result.NewDeliveries | Should -Be 102
        $r.Result.NewMessages | Should -Be 42
        $r.Result.Pages | Should -Be (13 + 2)
        $s = $script:Store.GetStatistics()
        $s.Messages | Should -Be 42; $s.Deliveries | Should -Be 102
    }
    It 'collects nothing the second time, except the recent hours that are not settled' {
        $plan = Get-MtrQueryPlan (New-MtrFilter -Sender 'alice@contoso.com', 'bob@contoso.com')
        $work = Get-MtrWorkPlan -Store $script:Store -QueryPlan $plan -Period $script:Period -Settings $script:S
        $work.Items.Count | Should -Be 2
        ($work.Items | ForEach-Object { $_.EndMs - $_.StartMs } | Measure-Object -Maximum).Maximum | Should -BeLessOrEqual (4 * 3600000 + 1000)
        $r = Invoke-TestCollection -Settings $script:S -Store $script:Store -Graph $script:G -Filter (New-MtrFilter -Sender 'alice@contoso.com', 'bob@contoso.com') -Period $script:Period
        $r.Result.NewDeliveries | Should -Be 0
    }
    It 'updates a delivery whose status changed' {
        $row = $script:G.Rows | Where-Object { $_.Sender -eq 'bob@contoso.com' } | Select-Object -First 1
        $row.Status = 'failed'
        $r = Invoke-TestCollection -Settings $script:S -Store $script:Store -Graph $script:G -Filter (New-MtrFilter -Sender 'bob@contoso.com') -Period $script:Period -Refresh
        $r.Result.UpdatedDeliveries | Should -Be 1
        $r.Result.NewDeliveries | Should -Be 0
    }
    It 'applies the FULL filter on the database: recipients AND sender, Or, patterns, status, subject' {
        $count = { param($f) $script:Store.Select($f, $script:Period.StartMs, $script:Period.EndMs) }
        (& $count (New-MtrFilter -Sender 'alice@contoso.com' -Recipient 'y@fabrikam.com')).Deliveries | Should -Be 30
        (& $count (New-MtrFilter -Sender 'alice@contoso.com' -Recipient '*@fabrikam.com')).Deliveries | Should -Be 60
        (& $count (New-MtrFilter -Sender 'bob@contoso.com' -Recipient 'z@contoso.com' -Operator Or)).Deliveries | Should -Be 42
        (& $count (New-MtrFilter -Sender 'al*@contoso.com' -AllowPatterns)).Messages | Should -Be 30
        (& $count (New-MtrFilter -Status Failed)).Deliveries | Should -Be 31
        (& $count (New-MtrFilter -Subject 'REPORT 1' -SubjectMatch StartsWith)).Messages | Should -Be 11
        (& $count (New-MtrFilter -Subject 'report 7' -SubjectMatch Equals)).Messages | Should -Be 1
    }
    It 'never sends or / in / ne to Graph' {
        $script:G.Requests | Where-Object { $_ -match '\$filter=' } | Should -Not -Match ' (or|in|ne) '
    }
}

Describe 'Collection failures' {
    BeforeAll {
        $script:S2 = New-TestConfiguration -Name 'failures'
        $now = [DateTimeOffset]::UtcNow
        $script:P2 = New-Period $now.AddDays(-2) $now.AddMinutes(-1)
        function New-Graph {
            $g = [MtrTests.FakeGraph]::new(); $g.Now = [DateTimeOffset]::UtcNow
            for ($i = 0; $i -lt 40; $i++) { $g.AddMessage('alice@contoso.com', [string[]]@('x@fabrikam.com'), $g.Now.AddMinutes(-30 * $i - 5), "M $i") }
            return $g
        }
    }
    It 'waits on 429 (Retry-After) and finishes' {
        $store = Open-MtrStore -Settings $script:S2
        try {
            $g = New-Graph; $g.ThrottleNext = 1; $g.RetryAfterSeconds = 1
            $r = Invoke-TestCollection -Settings $script:S2 -Store $store -Graph $g -Filter (New-MtrFilter -Sender 'alice@contoso.com') -Period $script:P2 -Refresh
            $r.Result.Throttled | Should -Be 1
            $r.Result.Done | Should -Be 1
            $r.Result.Rows | Should -Be 40
        } finally { $store.Dispose() }
    }
    It 'renews the token after a 401 and retries 5xx errors' {
        $store = Open-MtrStore -Settings $script:S2
        try {
            $g = New-Graph; $g.UnauthorizedNext = 1; $g.ServerErrorNext = 1
            $r = Invoke-TestCollection -Settings $script:S2 -Store $store -Graph $g -Filter (New-MtrFilter -Sender 'alice@contoso.com') -Period $script:P2 -Refresh
            $r.Result.Done | Should -Be 1
            $r.Result.Retries | Should -Be 1
            $g.Tokens | Should -Contain 'token-2'
        } finally { $store.Dispose() }
    }
    It 'stops at once on 403 and explains the missing service principal' {
        $store = Open-MtrStore -Settings $script:S2
        try {
            $g = New-Graph; $g.Forbidden = $true
            $r = Invoke-TestCollection -Settings $script:S2 -Store $store -Graph $g -Filter (New-MtrFilter -Sender 'alice@contoso.com', 'bob@contoso.com') -Period $script:P2 -Refresh
            $r.Result.Fatal | Should -Match 'ExchangeMessageTrace.Read.All'
            $g.Requests.Count | Should -BeLessOrEqual 2
            $g = New-Graph; $g.MissingServicePrincipal = $true
            $r = Invoke-TestCollection -Settings $script:S2 -Store $store -Graph $g -Filter (New-MtrFilter -Sender 'alice@contoso.com') -Period $script:P2 -Refresh
            $r.Result.Fatal | Should -Match '8bd644d1-64a1-4d4b-ae52-2e0cbf64e373'
        } finally { $store.Dispose() }
    }
    It 'keeps the pages already received when interrupted, and collects only the rest next time' {
        $cfg = New-TestConfiguration -Name 'interrupt'
        $cfg.Collection.SettlingHours = 0
        $store = Open-MtrStore -Settings $cfg
        try {
            $g = New-Graph; $g.DelayMs = 150
            $plan = Get-MtrQueryPlan (New-MtrFilter -Sender 'alice@contoso.com')
            $work = Get-MtrWorkPlan -Store $store -QueryPlan $plan -Period $script:P2 -Settings $cfg -Refresh
            $t = New-TestCollector -Graph $g -Store $store -PageSize 4
            $cts = [Threading.CancellationTokenSource]::new(); $cts.CancelAfter(700)
            $task = $t.Collector.RunAsync($work.Items, $cts.Token); [void]$task.Wait(30000)
            $stats = $store.GetStatistics()
            $stats.Deliveries | Should -BeGreaterThan 0
            $stats.Deliveries | Should -BeLessThan 40
            # The newest messages are stored; the next plan asks only for what is older than the oldest stored message.
            $after = Get-MtrWorkPlan -Store $store -QueryPlan $plan -Period $script:P2 -Settings $cfg
            $after.Items.Count | Should -Be 1
            $after.Items[0].StartMs | Should -Be $script:P2.StartMs
            $after.Items[0].EndMs | Should -Be ($stats.FirstReceivedMs + 1)
        } finally { $store.Dispose() }
    }
    It 'fails one window with a 400 and goes on with the others' {
        $store = Open-MtrStore -Settings $script:S2
        try {
            $g = New-Graph
            $old = New-Period ([DateTimeOffset]::UtcNow.AddDays(-12)) ([DateTimeOffset]::UtcNow.AddMinutes(-1))
            $plan = Get-MtrQueryPlan (New-MtrFilter -Sender 'alice@contoso.com')
            $work = [MessageTraceReport.Planner]::Windows($plan.Queries, $null, $old.StartMs, $old.EndMs, 0, 15 * 86400000L, 0, 1)   # 12 days in one window: refused by Graph
            $t = New-TestCollector -Graph $g -Store $store
            $t.Collector.RunAsync($work.Items, [Threading.CancellationToken]::None).Wait()
            $work.Items[0].State | Should -Be 'Failed'
            $work.Items[0].Error | Should -Match '10 days'
        } finally { $store.Dispose() }
    }
}

Describe 'Report files' {
    BeforeAll {
        $script:S3 = New-TestConfiguration -Name 'report' -Report @{ MaxRowsPerFile = 1000; HtmlMaxMessages = 300; Formats = "@('Csv', 'Html', 'Json')" }
        $script:Store3 = Open-MtrStore -Settings $script:S3
        $g = [MtrTests.FakeGraph]::new(); $now = [DateTimeOffset]::UtcNow; $g.Now = $now
        for ($i = 0; $i -lt 400; $i++) { $g.AddMessage('alice@contoso.com', [string[]]@('x@fabrikam.com', 'y@fabrikam.com', 'z@contoso.com'), $now.AddMinutes(-10 * $i - 5), "=HYPERLINK(""http://x"") $i", 'delivered', [string[]]@('delivered', $(if ($i % 10) { 'delivered' } else { 'failed' }), 'delivered')) }
        $script:P3 = New-Period $now.AddDays(-3) $now.AddMinutes(-1)
        $script:F3 = New-MtrFilter -Sender 'alice@contoso.com'
        [void](Invoke-TestCollection -Settings $script:S3 -Store $script:Store3 -Graph $g -Filter $script:F3 -Period $script:P3)
        $sel = Select-MtrMessages -Store $script:Store3 -Filter $script:F3 -Period $script:P3
        $items = $script:Store3.GetDetailCandidates(5, $true)
        $script:DetailItems = $items
        $script:Details = Invoke-MtrDetails -Store $script:Store3 -Settings $script:S3 -Connection (New-FakeConnection) -Items $items -Options ([MessageTraceReport.CollectorOptions]@{ Handler = $g; MaxConcurrency = 2; MaxRetries = 1; TimeoutSeconds = 30 }) 6>$null
        $script:Dir3 = New-MtrRunDirectory -Root $script:S3.Report.OutputPath -Mode Trace -Zone $script:Paris
        $script:R3 = New-MtrReport -Store $script:Store3 -Settings $script:S3 -Filter $script:F3 -Period $script:P3 -OutputDirectory $script:Dir3 -QueryPlan (Get-MtrQueryPlan $script:F3)
    }
    AfterAll { $script:Store3.Dispose() }

    It 'reads the route of the failed deliveries first' {
        $script:DetailItems.Count | Should -Be 5
        $script:Details.Done | Should -Be 5
        $script:Details.Events | Should -Be 10
    }
    It 'counts messages, deliveries and statuses of the whole selection' {
        $script:R3.Messages | Should -Be 400
        $script:R3.Deliveries | Should -Be 1200
        $script:R3.Statuses['Failed'] | Should -Be 40
        $script:R3.Statuses['Delivered'] | Should -Be 1160
    }
    It 'cuts the CSV files at MaxRowsPerFile and protects Excel from formulas' {
        $names = $script:R3.Files | ForEach-Object { Split-Path $_.Path -Leaf }
        $names | Should -Contain 'MessageTrace_Deliveries.csv'
        $names | Should -Contain 'MessageTrace_Deliveries_part2.csv'
        ($script:R3.Files | Where-Object { $_.Name -eq 'Deliveries' -and $_.Kind -eq 'CSV' } | Measure-Object -Property Rows -Sum).Sum | Should -Be 1200
        $first = (Get-Content (Join-Path $script:Dir3 'MessageTrace_Messages.csv') -TotalCount 2)[1]
        $first | Should -Match ";""'=HYPERLINK\(""""http://x""""\) 0"";"
    }
    It 'writes the Messages and Deliveries JSON files with the Graph property names' {
        $d = Get-Content (Join-Path $script:Dir3 'MessageTrace_Deliveries.json') -Raw | ConvertFrom-Json
        $d.Count | Should -Be 1200
        $d[0].PSObject.Properties.Name | Should -Be @('id', 'messageId', 'status', 'receivedDateTime', 'recipientAddress', 'senderAddress', 'subject', 'size', 'fromIP', 'toIP')
        $m = Get-Content (Join-Path $script:Dir3 'MessageTrace_Messages.json') -Raw | ConvertFrom-Json
        $m[0].recipientCount | Should -Be 3
        $m[0].status | Should -Be 'Delivered 2, Failed 1'
    }
    It 'limits the HTML table but keeps the totals of every message, with the routes' {
        $script:R3.HtmlTruncated | Should -BeTrue
        $script:R3.HtmlMessages | Should -Be 300
        $html = Get-Content (Join-Path $script:Dir3 'MessageTrace.html') -Raw
        $html | Should -Not -Match '%%(CHUNKS|META)%%'
        $meta = [regex]::Match($html, '<script id="report-meta" type="application/json">(.+?)</script>').Groups[1].Value | ConvertFrom-Json
        $meta.messages | Should -Be 400
        $meta.htmlMessages | Should -Be 300
        $meta.topSenders[0][0] | Should -Be 'alice@contoso.com'
        $chunks = [regex]::Matches($html, '<script type="application/x-mtr-chunk">([^<]+)</script>')
        $routes = 0
        foreach ($c in $chunks) {
            $gz = [IO.Compression.GZipStream]::new([IO.MemoryStream]::new([Convert]::FromBase64String($c.Groups[1].Value)), [IO.Compression.CompressionMode]::Decompress)
            $json = [IO.StreamReader]::new($gz).ReadToEnd() | ConvertFrom-Json
            $routes += @($json.x).Count
        }
        $routes | Should -Be 5
    }
    It 'counts senders and recipients per day' {
        $rows = Import-Csv (Join-Path $script:Dir3 'MessageTrace_Recipients.csv') -Delimiter ';'
        ($rows | Measure-Object -Property Messages -Sum).Sum | Should -Be 1200
        $rows[0].PSObject.Properties.Name[0] | Should -Be 'Date'
    }
}

Describe 'Entry script without connection' {
    BeforeAll {
        $script:S4 = New-TestConfiguration -Name 'entry'
        $store = Open-MtrStore -Settings $script:S4
        $g = [MtrTests.FakeGraph]::new(); $now = [DateTimeOffset]::UtcNow; $g.Now = $now
        for ($i = 0; $i -lt 20; $i++) { $g.AddMessage('sales-01@contoso.com', [string[]]@('x@fabrikam.com'), $now.AddHours(-1 * $i - 1), "Offer $i") }
        [void](Invoke-TestCollection -Settings $script:S4 -Store $store -Graph $g -Filter (New-MtrFilter -Sender 'sales-01@contoso.com') -Period (New-Period $now.AddDays(-2) $now.AddMinutes(-1)))
        $store.Dispose()
        $script:Entry = Join-Path $script:Root 'Invoke-MessageTraceReport.ps1'
    }
    It 'builds a report from the database only (-Mode Report, pattern)' {
        $out = pwsh -NoProfile -File $script:Entry -Mode Report -ConfigPath $script:S4.Path -Sender 'sales-*@contoso.com' -Range Last24Hours -Format Csv 2>&1
        $LASTEXITCODE | Should -BeIn 0, 2 -Because ($out -join "`n")
        ($out -join "`n") | Should -Match '2[0-4] messages'
        ($out -join "`n") | Should -Match 'not used \(database only\)'
    }
    It 'shows the database status (-Mode Status)' {
        $out = pwsh -NoProfile -File $script:Entry -Mode Status -ConfigPath $script:S4.Path 2>&1
        $LASTEXITCODE | Should -Be 0
        ($out -join "`n") | Should -Match '20 messages'
        ($out -join "`n") | Should -Match 'Last runs'
    }
    It 'fails with exit code 1 and a clear message on an invalid filter' {
        $out = pwsh -NoProfile -File $script:Entry -ConfigPath $script:S4.Path -Sender 'not-an-address' 2>&1
        $LASTEXITCODE | Should -Be 1
        ($out -join "`n") | Should -Match 'not valid'
    }
}

Describe 'Console' {
    It 'uses only characters of Consolas and Lucida Console outside modern terminals' {
        # Repertoire of Consolas and Lucida Console (checked glyph by glyph): code page 437 and Latin-1.
        # The classic console has no font fallback: any other character is shown as an empty box.
        $safe = [Collections.Generic.HashSet[int]]::new()
        foreach ($c in (0x20..0x7E) + (0xA0..0xFF)) { [void]$safe.Add($c) }
        foreach ($c in '☺☻♥♦♣♠•◘○◙♂♀♪♫☼►◄↕‼¶§▬↨↑↓→←∟↔▲▼⌂₧ƒ⌐░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀αΓπΣστΦΘΩδ∞φε∩≡≥≤⌠⌡≈∙√ⁿ■'.ToCharArray()) { [void]$safe.Add([int]$c) }
        $module = Get-Module MessageTraceReport
        $used = [Collections.Generic.List[string]]::new()
        $sets = & $module { (Get-MtrIconSet 'Symbols'), (Get-MtrIconSet 'Ascii'), (Get-MtrFrameSet 'Symbols' 'Lucida Console'), (Get-MtrFrameSet 'Symbols' 'Terminal'), (Get-MtrFrameSet 'Ascii' $null) }
        foreach ($set in $sets) { foreach ($key in $set.Keys) { $used.Add("set.$key=$($set[$key])") } }
        # Rounded corners: only for the fonts that have them (Consolas).
        $rounded = & $module { (Get-MtrFrameSet 'Symbols' 'Consolas') }
        $rounded.TopLeft | Should -Be ([char]0x256D)
        $sets[2].TopLeft | Should -Be ([char]0x250C)
        # Characters written directly by the module and the script (the two style functions excluded).
        foreach ($file in @(Get-ChildItem (Join-Path $script:Root 'src') -Filter *.ps1) + @(Get-Item (Join-Path $script:Root 'Invoke-MessageTraceReport.ps1'))) {
            $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            $text = $ast.Extent.Text
            $skip = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in 'Get-MtrIconSet', 'Get-MtrFrameSet' }, $true)
            foreach ($f in @($skip) | Sort-Object { $_.Extent.StartOffset } -Descending) { $text = $text.Remove($f.Extent.StartOffset, $f.Extent.EndOffset - $f.Extent.StartOffset) }
            foreach ($m in [regex]::Matches($text, '\[char\]0x([0-9A-Fa-f]{4})')) { $used.Add("$($file.Name)=$([char][Convert]::ToInt32($m.Groups[1].Value, 16))") }
        }
        $bad = @($used | Where-Object { $v = $_.Substring($_.IndexOf('=') + 1); @($v.ToCharArray() | Where-Object { -not $safe.Contains([int]$_) }).Count -gt 0 })
        $used.Count | Should -BeGreaterThan 40
        $bad | Should -BeNullOrEmpty
    }
    It 'formats durations and sizes' {
        Format-MtrDuration 0.4 | Should -Be '0.4 s'
        Format-MtrDuration 75 | Should -Be '1 min 15 s'
        Format-MtrDuration 7300 | Should -Be '2 h 01 min'
        Format-MtrBytes 1536 | Should -Be '2 KB'
    }
}
