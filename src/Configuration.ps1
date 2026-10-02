<#
    Message Trace Report - configuration.

    Import-MtrConfiguration reads config\MessageTraceReport.config.psd1, applies the default of every
    missing value, checks everything and reports ALL the problems at once, so that the administrator can
    fix the file in one go. Relative paths are relative to the tool folder.
#>

$script:GuidPattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
$script:Ranges = @('Last24Hours', 'Last48Hours', 'Last7Days', 'Last10Days', 'Last30Days', 'Last90Days', 'Today', 'Yesterday')
$script:ReportFiles = @('Messages', 'Deliveries', 'Senders', 'Recipients')

function Resolve-MtrPath {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ([IO.Path]::IsPathRooted($expanded)) { return [IO.Path]::GetFullPath($expanded) }
    return [IO.Path]::GetFullPath((Join-Path $Root $expanded))
}

function Get-MtrTimeZone {
    <# Accepts an IANA name (Europe/Paris) or a Windows name (Romance Standard Time). #>
    param([Parameter(Mandatory)][string]$Id)
    try { return [TimeZoneInfo]::FindSystemTimeZoneById($Id) } catch { }
    $windowsId = $null
    if ([TimeZoneInfo]::TryConvertIanaIdToWindowsId($Id, [ref]$windowsId)) { try { return [TimeZoneInfo]::FindSystemTimeZoneById($windowsId) } catch { } }
    throw "Unknown time zone '$Id' (Report.TimeZone). Use a name such as 'Europe/Paris' or 'Romance Standard Time'."
}

function Import-MtrConfiguration {
    <#
    .SYNOPSIS
        Reads the configuration file, checks every value and returns it with absolute paths.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string]$Root = $script:ToolRoot)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Configuration file not found: $Path" }
    try { $config = Import-PowerShellDataFile -LiteralPath $Path }
    catch { throw "The configuration file is not valid PowerShell data ($Path): $($_.Exception.Message)" }

    $errors = [Collections.Generic.List[string]]::new()
    foreach ($section in 'Tenant', 'Authentication', 'Collection', 'Throttling', 'Details', 'Collect', 'Storage', 'Report', 'Logging') {
        if (-not $config.ContainsKey($section)) { $config[$section] = @{} }
        elseif ($config[$section] -isnot [hashtable]) { $errors.Add("Section '$section' must be a @{ } block.") }
    }
    if ($errors.Count) { throw ("Invalid configuration ($Path):`n - " + ($errors -join "`n - ")) }

    function Get-Value([hashtable]$Section, [string]$SectionName, [string]$Key, $Default, [switch]$Required) {
        if ($Section.ContainsKey($Key) -and $null -ne $Section[$Key] -and "$($Section[$Key])" -ne '') { return $Section[$Key] }
        if ($Required) { $errors.Add("$SectionName.$Key is required.") }
        return $Default
    }
    function Test-Int($Value, [string]$Name, [long]$Min, [long]$Max) {
        $n = 0L
        if (-not [long]::TryParse("$Value", [ref]$n) -or $n -lt $Min -or $n -gt $Max) { $errors.Add("$Name must be a whole number between $Min and $Max (current value: '$Value')."); return [int]$Min }
        return [int]$n
    }
    function Test-Bool($Value, [string]$Name) {
        if ($Value -isnot [bool]) { $errors.Add("$Name must be `$true or `$false (current value: '$Value')."); return $false }
        return $Value
    }
    function Get-List($Section, [string]$Key) { return @(Get-Value $Section '' $Key @() | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) }

    $t = $config.Tenant; $a = $config.Authentication; $c = $config.Collection; $th = $config.Throttling; $d = $config.Details
    $co = $config.Collect; $s = $config.Storage; $r = $config.Report; $l = $config.Logging
    $settings = [ordered]@{
        Path           = [IO.Path]::GetFullPath($Path)
        Tenant         = [ordered]@{
            TenantId     = [string](Get-Value $t 'Tenant' 'TenantId' '' -Required)
            Organization = [string](Get-Value $t 'Tenant' 'Organization' '')
        }
        Authentication = [ordered]@{
            Mode                  = [string](Get-Value $a 'Authentication' 'Mode' 'Certificate')
            AppId                 = [string](Get-Value $a 'Authentication' 'AppId' '')
            CertificateThumbprint = [string](Get-Value $a 'Authentication' 'CertificateThumbprint' '')
            ClientSecretVariable  = [string](Get-Value $a 'Authentication' 'ClientSecretVariable' 'MTR_CLIENT_SECRET')
            UserPrincipalName     = [string](Get-Value $a 'Authentication' 'UserPrincipalName' '')
        }
        Collection     = [ordered]@{
            PageSize              = Test-Int (Get-Value $c 'Collection' 'PageSize' 5000) 'Collection.PageSize' 1 5000
            MaxConcurrency        = Test-Int (Get-Value $c 'Collection' 'MaxConcurrency' 3) 'Collection.MaxConcurrency' 1 8
            WindowHours           = Test-Int (Get-Value $c 'Collection' 'WindowHours' 240) 'Collection.WindowHours' 1 240
            BroadWindowHours      = Test-Int (Get-Value $c 'Collection' 'BroadWindowHours' 24) 'Collection.BroadWindowHours' 1 240
            SettlingHours         = Test-Int (Get-Value $c 'Collection' 'SettlingHours' 4) 'Collection.SettlingHours' 0 72
            MaxQueries            = Test-Int (Get-Value $c 'Collection' 'MaxQueries' 2000) 'Collection.MaxQueries' 1 1000000
            RequestTimeoutSeconds = Test-Int (Get-Value $c 'Collection' 'RequestTimeoutSeconds' 180) 'Collection.RequestTimeoutSeconds' 30 600
            MaxRetries            = Test-Int (Get-Value $c 'Collection' 'MaxRetries' 5) 'Collection.MaxRetries' 0 10
            SourceHistoryDays     = Test-Int (Get-Value $c 'Collection' 'SourceHistoryDays' 90) 'Collection.SourceHistoryDays' 1 90
        }
        Throttling     = [ordered]@{
            MaxRequests   = Test-Int (Get-Value $th 'Throttling' 'MaxRequests' 90) 'Throttling.MaxRequests' 1 100
            PeriodSeconds = Test-Int (Get-Value $th 'Throttling' 'PeriodSeconds' 300) 'Throttling.PeriodSeconds' 60 3600
        }
        Details        = [ordered]@{
            Enabled       = Test-Bool (Get-Value $d 'Details' 'Enabled' $false) 'Details.Enabled'
            MaxDeliveries = Test-Int (Get-Value $d 'Details' 'MaxDeliveries' 50) 'Details.MaxDeliveries' 1 10000
            OnlyProblems  = Test-Bool (Get-Value $d 'Details' 'OnlyProblems' $true) 'Details.OnlyProblems'
        }
        Collect        = [ordered]@{
            Days          = Test-Int (Get-Value $co 'Collect' 'Days' 2) 'Collect.Days' 1 90
            Senders       = Get-List $co 'Senders'
            Recipients    = Get-List $co 'Recipients'
            SenderFile    = [string](Get-Value $co 'Collect' 'SenderFile' '')
            RecipientFile = [string](Get-Value $co 'Collect' 'RecipientFile' '')
            Operator      = [string](Get-Value $co 'Collect' 'Operator' 'Or')
        }
        Storage        = [ordered]@{
            DatabasePath  = Resolve-MtrPath ([string](Get-Value $s 'Storage' 'DatabasePath' '.\data\MessageTraceReport.sqlite')) $Root
            RetentionDays = Test-Int (Get-Value $s 'Storage' 'RetentionDays' 180) 'Storage.RetentionDays' 0 3650
        }
        Report         = [ordered]@{
            DefaultRange             = [string](Get-Value $r 'Report' 'DefaultRange' 'Last48Hours')
            TimeZone                 = [string](Get-Value $r 'Report' 'TimeZone' 'Europe/Paris')
            OutputPath               = Resolve-MtrPath ([string](Get-Value $r 'Report' 'OutputPath' '.\reports')) $Root
            FilePrefix               = [string](Get-Value $r 'Report' 'FilePrefix' 'MessageTrace')
            Formats                  = @(Get-Value $r 'Report' 'Formats' @('Csv', 'Html'))
            Files                    = @(Get-Value $r 'Report' 'Files' $script:ReportFiles)
            CountsPerDay             = Test-Bool (Get-Value $r 'Report' 'CountsPerDay' $true) 'Report.CountsPerDay'
            CsvDelimiter             = [string](Get-Value $r 'Report' 'CsvDelimiter' ';')
            MaxRowsPerFile           = Test-Int (Get-Value $r 'Report' 'MaxRowsPerFile' 1000000) 'Report.MaxRowsPerFile' 1000 1048575
            HtmlMaxMessages          = Test-Int (Get-Value $r 'Report' 'HtmlMaxMessages' 200000) 'Report.HtmlMaxMessages' 100 1000000
            HtmlRecipientsPerMessage = Test-Int (Get-Value $r 'Report' 'HtmlRecipientsPerMessage' 100) 'Report.HtmlRecipientsPerMessage' 1 5000
            Title                    = [string](Get-Value $r 'Report' 'Title' 'Exchange Online message trace')
            OpenReport               = Test-Bool (Get-Value $r 'Report' 'OpenReport' $false) 'Report.OpenReport'
            TemplatePath             = Join-Path $Root 'templates\Report.template.html'
        }
        Logging        = [ordered]@{
            Path          = Resolve-MtrPath ([string](Get-Value $l 'Logging' 'Path' '.\logs')) $Root
            RetentionDays = Test-Int (Get-Value $l 'Logging' 'RetentionDays' 30) 'Logging.RetentionDays' 1 3650
        }
    }
    if ($settings.Tenant.TenantId -and $settings.Tenant.TenantId -notmatch $script:GuidPattern) { $errors.Add('Tenant.TenantId must be the tenant ID (GUID): Entra admin center > Overview.') }
    $auth = $settings.Authentication
    if ($auth.Mode -notin 'Certificate', 'ClientSecret', 'Interactive') { $errors.Add("Authentication.Mode must be 'Certificate', 'ClientSecret' or 'Interactive'.") }
    if ($auth.Mode -in 'Certificate', 'ClientSecret' -and $auth.AppId -notmatch $script:GuidPattern) { $errors.Add("Authentication.AppId must be the application (client) ID (GUID) in $($auth.Mode) mode.") }
    if ($auth.Mode -eq 'Interactive' -and $auth.AppId -and $auth.AppId -notmatch $script:GuidPattern) { $errors.Add("Authentication.AppId must be empty or an application (client) ID (GUID) in Interactive mode.") }
    if ($auth.Mode -eq 'Certificate' -and $auth.CertificateThumbprint -notmatch '^[0-9a-fA-F]{40}$') { $errors.Add('Authentication.CertificateThumbprint must be the 40-character thumbprint of the certificate in Certificate mode.') }
    if ($auth.Mode -eq 'ClientSecret' -and $auth.ClientSecretVariable -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { $errors.Add('Authentication.ClientSecretVariable must be an environment variable name.') }
    if ($settings.Collect.Operator -notin 'And', 'Or') { $errors.Add("Collect.Operator must be 'And' or 'Or'.") }
    foreach ($key in 'SenderFile', 'RecipientFile') { if ($settings.Collect[$key]) { $settings.Collect[$key] = Resolve-MtrPath $settings.Collect[$key] $Root } }
    if ($settings.Report.DefaultRange -notin $script:Ranges) { $errors.Add("Report.DefaultRange must be one of: $($script:Ranges -join ', ').") }
    $badFormats = @($settings.Report.Formats | Where-Object { $_ -notin 'Csv', 'Html', 'Json' })
    if (-not $settings.Report.Formats.Count -or $badFormats.Count) { $errors.Add("Report.Formats must contain 'Csv', 'Html' and/or 'Json'.") }
    $badFiles = @($settings.Report.Files | Where-Object { $_ -notin $script:ReportFiles })
    if ($badFiles.Count) { $errors.Add("Report.Files may contain: $($script:ReportFiles -join ', ').") }
    if ($settings.Report.CsvDelimiter -notin ';', ',', "`t", '|') { $errors.Add("Report.CsvDelimiter must be ';', ',', '|' or a tab.") }
    if (-not $settings.Report.FilePrefix -or $settings.Report.FilePrefix.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { $errors.Add('Report.FilePrefix must be a valid file name part.') }
    try { $settings['Zone'] = Get-MtrTimeZone $settings.Report.TimeZone } catch { $errors.Add($_.Exception.Message) }
    if ($errors.Count) { throw ("Invalid configuration ($Path):`n - " + ($errors -join "`n - ")) }
    return $settings
}
