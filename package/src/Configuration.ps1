<#
    Message Trace Report - configuration.

    Import-MtrConfiguration reads config\MessageTraceReport.config.psd1, applies the default of every
    missing value, checks everything and reports ALL the problems at once, so that the administrator can
    fix the file in one go. Relative paths are relative to the tool folder.
#>

$script:GuidPattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
$script:Ranges = @('Last24Hours', 'Last48Hours', 'Last7Days', 'Last10Days', 'Last30Days', 'Last90Days', 'Today', 'Yesterday')
$script:ReportFiles = @('Messages', 'Deliveries', 'Senders', 'Recipients', 'Routes')

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
            Enabled              = Test-Bool (Get-Value $d 'Details' 'Enabled' $false) 'Details.Enabled'
            MaxDeliveries        = Test-Int (Get-Value $d 'Details' 'MaxDeliveries' 100) 'Details.MaxDeliveries' 1 10000
            OnlyProblems         = Test-Bool (Get-Value $d 'Details' 'OnlyProblems' $true) 'Details.OnlyProblems'
            CompareWithDelivered = Test-Bool (Get-Value $d 'Details' 'CompareWithDelivered' $true) 'Details.CompareWithDelivered'
            ConsoleMessages      = Test-Int (Get-Value $d 'Details' 'ConsoleMessages' 3) 'Details.ConsoleMessages' 0 50
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

# SIG # Begin signature block
# MIImIgYJKoZIhvcNAQcCoIImEzCCJg8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCEfLC2m5KS6tLH
# gMtENYgAgdkPg2/YbKGZCy7tvPn0laCCDW8wggZyMIIEWqADAgECAghkM1HTxzif
# CDANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMx
# EDAOBgNVBAcMB0hvdXN0b24xGDAWBgNVBAoMD1NTTCBDb3Jwb3JhdGlvbjExMC8G
# A1UEAwwoU1NMLmNvbSBSb290IENlcnRpZmljYXRpb24gQXV0aG9yaXR5IFJTQTAe
# Fw0xNjA2MjQyMDQ0MzBaFw0zMTA2MjQyMDQ0MzBaMHgxCzAJBgNVBAYTAlVTMQ4w
# DAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjERMA8GA1UECgwIU1NMIENv
# cnAxNDAyBgNVBAMMK1NTTC5jb20gQ29kZSBTaWduaW5nIEludGVybWVkaWF0ZSBD
# QSBSU0EgUjEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCfgxNzqrDG
# bSHL24t6h3TQcdyOl3Ka5LuINLTdgAPGL0WkdJq/Hg9Q6p5tePOf+lEmqT2d0bKU
# Vz77OYkbkStW72fL5gvjDjmMxjX0jD3dJekBrBdCfVgWQNz51ShEHZVkMGE6ZPKX
# 13NMfXsjAm3zdetVPW+qLcSvvnSsXf5qtvzqXHnpD0OctVIFD+8+sbGP0EmtpuNC
# GVQ/8y8Ooct8/hP5IznaJRy4PgBKOm8yMDdkHseudQfYVdIYyQ6KvKNc8HwKp4WB
# wg6vj5lc02AlvINaaRwlE81y9eucgJvcLGfE3ckJmNVz68Qho+Uyjj4vUpjGYDdk
# jLJvSlRyGMwnh/rNdaJjIUy1PWT9K6abVa8mTGC0uVz+q0O9rdATZlAfC9KJpv/X
# gAbxwxECMzNhF/dWH44vO2jnFfF3VkopngPawismYTJboFblSSmNNqf1x1KiVgMg
# Lzh4gL32Bq5BNMuURb2bx4kYHwu6/6muakCZE93vUN8BuvIE1tAx3zQ4XldbyDge
# VtSsSKbt//m4wTvtwiS+RGCnd83VPZhZtEPqqmB9zcLlL/Hr9dQg1Zc0bl0EawUR
# 0tOSjAknRO1PNTFGfnQZBWLsiePqI3CY5NEv1IoTGEaTZeVYc9NMPSd6Ij/D+KNV
# t/nmh4LsRR7Fbjp8sU65q2j3m2PVkUG8qQIDAQABo4H7MIH4MA8GA1UdEwEB/wQF
# MAMBAf8wHwYDVR0jBBgwFoAU3QQJB6L1en1SUxKSle44gCUNplkwMAYIKwYBBQUH
# AQEEJDAiMCAGCCsGAQUFBzABhhRodHRwOi8vb2NzcHMuc3NsLmNvbTARBgNVHSAE
# CjAIMAYGBFUdIAAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwOwYDVR0fBDQwMjAwoC6g
# LIYqaHR0cDovL2NybHMuc3NsLmNvbS9zc2wuY29tLXJzYS1Sb290Q0EuY3JsMB0G
# A1UdDgQWBBRUwv4QlQCTzWr158DX2bJLuI8M4zAOBgNVHQ8BAf8EBAMCAYYwDQYJ
# KoZIhvcNAQELBQADggIBAPUPJodwr5miyvXWyfCNZj05gtOII9iCv49UhCe204MH
# 154niU2EjlTRIO5gQ9tXQjzHsJX2vszqoz2OTwbGK1mGf+tzG8rlQCbgPW/M9r1x
# xs19DiBAOdYF0q+UCL9/wlG3K7V7gyHwY9rlnOFpLnUdTsthHvWlM98CnRXZ7WmT
# V7pGRS6AvGW+5xI+3kf/kJwQrfZWsqTU+tb8LryXIbN2g9KR+gZQ0bGAKID+260P
# Z+34fdzZcFt6umi1s0pmF4/n8OdX3Wn+vF7h1YyfE7uVmhX7eSuF1W0+Z0duGwdc
# +1RFDxYRLhHDsLy1bhwzV5Qe/kI0Ro4xUE7bM1eV+jjk5hLbq1guRbfZIsr0WkdJ
# LCjoT4xCPGRo6eZDrBmRqccTgl/8cQo3t51Qezxd96JSgjXktefTCm9r/o35pNfV
# HUvnfWII+NnXrJlJ27WEQRQu9i5gl1NLmv7xiHp0up516eDap8nMLDt7TAp4z5T3
# NmC2gzyKVMtODWgqlBF1JhTqIDfM63kXdlV4cW3iSTgzN9vkbFnHI2LmvM4uVEv9
# XgMqyN0eS3FE0HU+MWJliymm7STheh2ENH+kF3y0rH0/NVjLw78a3Z9UVm1F5VPz
# iIorMaPKPlDRADTsJwjDZ8Zc6Gi/zy4WZbg8Zv87spWrmo2dzJTw7XhQf+xkR6Od
# MIIG9TCCBN2gAwIBAgIQBof4ljXihJpmCqqt2mhAWzANBgkqhkiG9w0BAQsFADB4
# MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24x
# ETAPBgNVBAoMCFNTTCBDb3JwMTQwMgYDVQQDDCtTU0wuY29tIENvZGUgU2lnbmlu
# ZyBJbnRlcm1lZGlhdGUgQ0EgUlNBIFIxMB4XDTI2MTAxMzAyNDgwMloXDTI3MTAx
# MzAyNDgwMlowXDELMAkGA1UEBhMCRlIxGzAZBgNVBAcMEkNoYW50ZWxvdXAtRW4t
# QnJpZTEXMBUGA1UECgwOTmljb2xhcyBGYWJlcnQxFzAVBgNVBAMMDk5pY29sYXMg
# RmFiZXJ0MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAsg6CT0mFQ4jB
# V2plIS4uWFSoVqRHd82Y7XYZ4CUTe/7nPBRUlXXdKTZMMHzGgiG8dEXNE8K1Xe90
# Dgl/FnorzAFlrNWSwf6t27UAUw9xkqtRDVVpVgpixpWkAwjcQeLG+YMqBkGbFi35
# TGvS23lPFWvLp4DxARrv15MtZ/NjNTCAAGUlMP2hFVBknEmrnYjEGyeJ93sl20RS
# WXQQLNqlenBdkGCrQW4XjHtRjJAEqAC68hN6nWevopSQ8CLUV7A1RFfHFarDrzrL
# zr0/NjIdSyIfM9hShln31NDrktB6Ups2XIyrtPDNB7fjkW4jpLlOqQGfYKsU9ErE
# 4SnFsh0yOOjitegyh1RvZ9wH++3DF4CmJfTli5l/gEIm8xCCryxI+K5EogW3wu1y
# u8NT2hcvHjdh7OpRyPyFAuLZ8MfX7kPAJpnuCeOuktzY/20eVD8bDglj+4zgqzsn
# cR/t6T/7w1/HxpRyrVoKvEyRx+mphYh5jMdEa0BjxOL0vAJpdGZSfXGmPm/yPqRn
# 5STTkMtzkVQXPbcvgKM0luzFcQKPHk3qdHLEXa8gf93ktYDbLE5Wd2UHrXz3SZxN
# URHPdIXCr1qgrqQve7041kMpzrkDI5DnG2lvRG4108gp02bHG0muKyZlDdCOra7h
# Zonu2nO79sFallruzzNi0o994PoWksUCAwEAAaOCAZUwggGRMAwGA1UdEwEB/wQC
# MAAwHwYDVR0jBBgwFoAUVML+EJUAk81q9efA19myS7iPDOMwegYIKwYBBQUHAQEE
# bjBsMEgGCCsGAQUFBzAChjxodHRwOi8vY2VydC5zc2wuY29tL1NTTGNvbS1TdWJD
# QS1Db2RlU2lnbmluZy1SU0EtNDA5Ni1SMS5jZXIwIAYIKwYBBQUHMAGGFGh0dHA6
# Ly9vY3Nwcy5zc2wuY29tMFEGA1UdIARKMEgwCAYGZ4EMAQQBMDwGDCsGAQQBgqkw
# AQMDATAsMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5zc2wuY29tL3JlcG9zaXRv
# cnkwEwYDVR0lBAwwCgYIKwYBBQUHAwMwTQYDVR0fBEYwRDBCoECgPoY8aHR0cDov
# L2NybHMuc3NsLmNvbS9TU0xjb20tU3ViQ0EtQ29kZVNpZ25pbmctUlNBLTQwOTYt
# UjEuY3JsMB0GA1UdDgQWBBRoUx3630l9wA1fUpkKkw2GUIxl/jAOBgNVHQ8BAf8E
# BAMCB4AwDQYJKoZIhvcNAQELBQADggIBAE3oj6cNuwlDToi1BwjgsA5djfRN4DIi
# BYDFZIRYaIRe/rEdnItz3aqQQdFuwXnJA/MQEmi2WAGek8GeZF+R41s8FbcDxBUE
# BoSt98TuBE+0xgxQWDiPhhXaX1Aw9V0GF4ZnlfCSw1eu2KiASaKn7Bo0PLbEAXff
# vftRXof/kyqtw8iID6I4Rhrf5DI3WVZQodakUUmWnbnziWvEZOWbNOfzwP+7BwEt
# 7jQANfbmEfb4p75rfy5dQVwniTDSvdo6xkrbe1Cr93GS7cJta18IG5CoIVUmdK+s
# W38B1sLuy8Mi0MstMXV3004yaRuzLdNaAM0f9WAFerxemiQC0kdmA44/lWV3lVkM
# WJSwkHBkkSg8Eh0hxcGzTH2xmtDhLJHNNLRwkI9u2Ur+HbLCt50oBgSV8BcCs/1i
# qi884iC/yuX+HIv9YgTUNZ8c4lLaq4VuliJpXLu2buHIsTkO0v0+5oCM91zjTVZm
# ULeH38N0Vr83psiJVuBSxQyt5nRVrpYz7FACq5gtXELkyViq/rGOlJKaRrgQ6WWq
# eoIXqKhVFAdP/jAEm2M8ezoVYsUgPyKY2OcuecV9coulAcxUIUydx6qYiOfsGj5u
# Dy7l4aYjvB771wkUMzUQwxzcDYXJtMMTaWRe6n9EemR67jc73u5CJyFg3PfA5WR1
# wZislcdCZuS6MYIYCTCCGAUCAQEwgYwweDELMAkGA1UEBhMCVVMxDjAMBgNVBAgM
# BVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDE0MDIG
# A1UEAwwrU1NMLmNvbSBDb2RlIFNpZ25pbmcgSW50ZXJtZWRpYXRlIENBIFJTQSBS
# MQIQBof4ljXihJpmCqqt2mhAWzANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3
# AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDsmYxD3unX
# FUAltnEdrhqs5MnqVqOCC4/sjF4sR0n0sDANBgkqhkiG9w0BAQEFAASCAgBBixP8
# nRyOn4UJCxoKxLLZ/ppRW/69UZDzv54DpoFkwl5U5SVv2roeRe/Dg5nxDH87SIz8
# 3W7rW0m9gPifMnfn5fptmkiy1n2Yzvmu1S9dIRKGs6+10Nb4z36izmbCKVCOPk/D
# wMENIJOMwuI3wLi2XxEv+YYZyatS6mQr6rCqeeN3wqV7wtjpZhhw8+yzVPf0N3au
# VY0eRVMXHtMWda9Z2nw1dVFR2dV4n1HIipYvMPK86JTZ04dXoY7zCMfw/8sVm3L7
# DPc+yzCtgiIA56u+wJILiQfP5eaZZlJQAGMVsbZ1LgGr/zyuYSWYD1onjU1lqJnb
# q4OZvx0enuXqP2uh3aUtGziYai2s2MoIGXzboCGJz3XWMjZEUju93o4g+EWKreTp
# JkV0O7u0tqNtHhiN0SAfAdkFv6JGI0HOnrCt3ZERzWxtsHOb5/fZvO/PguAxXk3Z
# ZkLZj2MWm/bvDPQK2yTRDViJfnRBGSDIlKH8sV9qehP4LkktwoU4VNNXP/Mg0qoa
# 4VZx/w52MiQh0a9aFi9GbVj8z9FIWDmc646jhZUwyzWbUKR2pkPwuZGT6RsJ4qBZ
# PR1dzQf7Hs2h9O7JIXzLzKwPFPgkMkTi9rFiQ5nodyKB/3/Ia4XsaAgm7mT95OfQ
# YErmEmUwhQELeq78C8FOj/xaGSgJg+7UTbeyr6GCFMYwghTCBgorBgEEAYI3AwMB
# MYIUsjCCFK4GCSqGSIb3DQEHAqCCFJ8wghSbAgEDMQ0wCwYJYIZIAWUDBAIBMIGB
# BgsqhkiG9w0BCRABBKByBHAwbgIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEIEo6glQry6Otn0xKn/0J2RS+HeI9+hB5jJcPIzAcpzRnAgh2UIBvLn/o
# AhgPMjAyNjExMDUxODAwNThaMAMCAQECCFlRd4gHpgQJoIIRpzCCBPMwggLboAMC
# AQICEFRD+De9Wu4YAYRyuFzajuMwDQYJKoZIhvcNAQELBQAwcjELMAkGA1UEBhMC
# VVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhT
# U0wgQ29ycDEuMCwGA1UEAwwlU1NMLmNvbSBUaW1lc3RhbXBpbmcgSXNzdWluZyBS
# U0EgQ0EgMjAeFw0yNjA2MTIxNzIyNDZaFw0zNjA2MDkxNzIyNDVaMG4xCzAJBgNV
# BAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjERMA8GA1UE
# CgwIU1NMIENvcnAxKjAoBgNVBAMMIVNTTC5jb20gVGltZXN0YW1waW5nIFVuaXQg
# MjAyNiBFMTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABOgli7hmEy5IkjjzCzbJ
# DgbYV7CIUUgOOn3jkML0i3A2jYer8VMwShMdSnRQURbOzh65x/ytFQOjGw0CBaVI
# ND2jggFSMIIBTjAfBgNVHSMEGDAWgBRwmmXBQ4Cj/OmxZIlu8TCcCSHJfDBNBggr
# BgEFBQcBAQRBMD8wPQYIKwYBBQUHMAKGMWh0dHA6Ly9jZXJ0LnNzbC5jb20vU1NM
# LmNvbS10aW1lU3RhbXBpbmctSS1SMi5jZXIwUQYDVR0gBEowSDA8BgwrBgEEAYKp
# MAEDBgEwLDAqBggrBgEFBQcCARYeaHR0cHM6Ly93d3cuc3NsLmNvbS9yZXBvc2l0
# b3J5MAgGBmeBDAEEAjAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDBCBgNVHR8EOzA5
# MDegNaAzhjFodHRwOi8vY3Jscy5zc2wuY29tL1NTTC5jb20tdGltZVN0YW1waW5n
# LUktUjIuY3JsMB0GA1UdDgQWBBQnrANWuihquhc7gz1Af3moJOzDPDAOBgNVHQ8B
# Af8EBAMCB4AwDQYJKoZIhvcNAQELBQADggIBAE92bs78A57CGU1wZ/oY5rgV4Mwd
# dn22MU/bmHumb4b6W2VinMg0IGnBE5D8PJOsnqp2AmMhWdOt5TDxKgIQA9pzBute
# GYez7R1vQ1qn7IIr8Wz2AXjfre1MYJGE93saW1jHTxKgbVlchzry3CrzMYCVnyYw
# DcFZMFQ35Mv4+3H9vPoopjfDynO0v7vPy3p0UZ1dltmH53EZ5M/Qn7OZ0Q82mYLo
# h666dhscIJzUEh+BgYxzpdz8y7J1WxqGSouGRI4F7qbOJhhjiu/hgdhwJUJ/jkve
# OHB6pZB9IBJbdlns6AjUaRC6YfamsbgZ40hKl1ln4BOshgcDtLsSjaqVlUx5gMK+
# krwT6H8bm1yLhJ/Yr0eAizrgMVEqyeNWQYP6qhtKCYxehpESm8au3MlkpBGWCYZi
# goNh4OX1x2oDsYsG5p+ST2db4Vgq25N7/3U8doL0yufnqwuR/f603JY1CO++sndq
# 34Y35Kb8gLG7V7OA+5658PIvcKK+fn3bUUiQVcasy5spBX7aC9FKdkPvrciglHa4
# m3XJ6weBykt7PrdwI3XGwNOgwi/Bon0IvXy9MkQUTZQOKOgT/kq++eTGgjY1EWGQ
# 7w8sSRwQU+3Ko2SMLIkfLPuvOtJ6BWwQbXYHtiMOwjwv9UN9SNu4VaJUuwdMmqN7
# /F9jLVst5rGZV03BMIIF3TCCA8WgAwIBAgIIeyyb0xaAMpkwDQYJKoZIhvcNAQEL
# BQAwfDELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3Vz
# dG9uMRgwFgYDVQQKDA9TU0wgQ29ycG9yYXRpb24xMTAvBgNVBAMMKFNTTC5jb20g
# Um9vdCBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eSBSU0EwHhcNMTYwMjEyMTczOTM5
# WhcNNDEwMjEyMTczOTM5WjB8MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMx
# EDAOBgNVBAcMB0hvdXN0b24xGDAWBgNVBAoMD1NTTCBDb3Jwb3JhdGlvbjExMC8G
# A1UEAwwoU1NMLmNvbSBSb290IENlcnRpZmljYXRpb24gQXV0aG9yaXR5IFJTQTCC
# AiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAPkP3aMrfcvQKv7sZ4Wm5y4b
# unfh4/WvpOz6Sl2RxFdHaxh3a3by/ZPkPQ/CFp4LZsNWlJ4Xg4XOVu/yFv0AYvUi
# CVToZRdOQbngT0aXqhvIuG5iXmmxX9sqAn78bMrzQdjt0Oj8P2FI7bADFB0QDksZ
# 4LtO7IZl/zbzXmcCC52GVWH9ejjt/uIZALdvoVBidXQ8oPrIJZK0bnoix/geoeOy
# 3ZExqysdBP+lSgQ36YWkMyv94tZVNHwZpEpox7Ko07fKoZOI68GXvIz5HdkihCR0
# xwQ9aqkpk8zruFvh/l8lqjRYyMEjVJ0bmBHDOJx+PYZspQ9AhnwC9FwCTyjLrnGf
# DzrIM/4RJTXq/LrFYD3ZfBjVsqnTdXgDciLKOsMf7yzlLqn6niy2UUb9rwPW6mBo
# 6oUWNmuF6R7As93EJNyAKoFBbZQ+yODJgUEAnl6/f8UImKIYLEJAs/lvOCdLToD0
# PYFH4Ih86hzOtXVcUS4cK38acijnALXRdMbX5J+tB5O2UzU1/Dfkw/ZdFr4hc96S
# CvigY2q8lpJqPvi8ZVWb3vUNiSYE/CUapiVpy8JtynziWV+XrOvvLsi81xtZPCvM
# 8hnIk2snYxnP/Okm+Mpxm3+T/jRnhE6Z6/yzeAkzcLpmpnbtG3PrGqUNxCITIJRW
# Ck4sbE6x/c+cCbqiM+2HAgMBAAGjYzBhMB0GA1UdDgQWBBTdBAkHovV6fVJTEpKV
# 7jiAJQ2mWTAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFN0ECQei9Xp9UlMS
# kpXuOIAlDaZZMA4GA1UdDwEB/wQEAwIBhjANBgkqhkiG9w0BAQsFAAOCAgEAIBgR
# lCn7Jp0cHh5wYfGVcpNxJK1ok1iOMq8bs3AD/CUrdIWQPXhq9LmLpZc7tRiRux6n
# +UBbkflVma8eEdBcHadm47GUBwwyOabqG7B52B2ccETjit3E+ZUfijhDPwGFpUen
# PUayvOUiaPd7nNgsPgohyC0zrL/FgZkxdMF1ccW+sfAjRfSda/wZY52jvATGGAsl
# u1OJD7OAUN5F7kR/q5R4ZJjT9ijdh9hwZXT7DrkT66cPYakylszeu+1jTBi7qUD3
# oFRuIIhxdRjqerQ0cuAjJ3dctpDqhiVAq+8zD8ufgr6iIPv2tS0a5sKFsXQP+8hl
# AqRSAUfdSSLBv9jra6x+3uxjMxW3IwiPxg+NQVrdjsW5j+VFP3jbutIbQLH+cU0/
# 4IGiul607BXgk90IH37hVZkLId6Tngr75qNJvTYw/ud3sqB1l7UtgYgXZSD32pAA
# n8lSzDLKNXz1PQ/YK9f1JmzJBjSWFupwWRoyeXkLtoh/D1JIPb9s2KJELtFOt3JY
# 04kTlf5Eq/jXixtunLwsoFvVagCvXzfh1foQC5ichucmj87w7G6KVwuA406ywKBj
# YZC6VWg3dGq2ktufoYYitmUnDuy2n0Jg5GfCtdpBC8TTi2EbvPofkSvXRAdeuims
# 2cXp71NIWuuA8ShYIc2wBlX7Jz9TkHCpBB5XJ7kwggbLMIIEs6ADAgECAhBSnbvC
# uImH9YOA4LDrogY2MA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMQ4wDAYD
# VQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjEYMBYGA1UECgwPU1NMIENvcnBv
# cmF0aW9uMTEwLwYDVQQDDChTU0wuY29tIFJvb3QgQ2VydGlmaWNhdGlvbiBBdXRo
# b3JpdHkgUlNBMB4XDTI2MDYxMjE2NDIxNVoXDTQxMDIxMjE3MzkzOVowcjELMAkG
# A1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYD
# VQQKDAhTU0wgQ29ycDEuMCwGA1UEAwwlU1NMLmNvbSBUaW1lc3RhbXBpbmcgSXNz
# dWluZyBSU0EgQ0EgMjCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAJ8v
# q+ZzTZC8MUabNgd5WlBjVPcu71oiedNd8n9Il8+uW0HcGvW44/Jf0pHl6hxqn0od
# haGnvvNBPJgxH/d6CMI7Mtgl9nF5isarRfByRmAeH+skYShA+dMJGzsrC9NiF3/v
# xGZ2uOI334YVc+DlP5OdsUPz5yIP7hYXNlpPknPwh6gK/pWFZD8+y8uUagfX9USh
# q/SQt+1tS4FXRwudHTSHbGt0Fz4ZbWGbm0d56ROAW34tI6FFuZ+TtGssHjeOUf2F
# S8QNGBpadTh1X1Z7Kl6vG4Z8NS3OJIyelzoF5TpcP2vM3ue0723bmZd3oXsE5rzt
# AJMv56jlg0vSDz8XcXRur6awW0rh5cTQDQQGx04hYJH2Zn9HWWJU/wJ2SKBcQKtB
# yCz6JX+DoFoBE++kolkpZtl2ESF8FY6XqhtKZb18ESEAc0ohCY+0HkBZwrx8eIED
# CDbzd/shv9a8YRG2oxr3tLUz95V+Dzzh1QBNECaeGczyNWGCZIVUa4lVcVUVOBbI
# OAT8D+iPmC5h29bWeES8DhTS4f4CWA4D5QoQqMTqIBcV4MD2Waw8hEWAdGnjnsVt
# DimnDeEUbvXKhdiirvwG+QC+3mAy1RlD6xBMmGyDAKVSqqXm3NP4w0J4gvt65Grk
# QI4FXPJtYqfwkIBtQ8OGfbpVUQGPVUemWtui7E21AgMBAAGjggFRMIIBTTASBgNV
# HRMBAf8ECDAGAQH/AgEAMB8GA1UdIwQYMBaAFN0ECQei9Xp9UlMSkpXuOIAlDaZZ
# ME0GCCsGAQUFBwEBBEEwPzA9BggrBgEFBQcwAoYxaHR0cDovL2NlcnQuc3NsLmNv
# bS9TU0xjb20tUm9vdENBLVJTQS00MDk2LVIxLmNlcjA/BgNVHSAEODA2MDQGBFUd
# IAAwLDAqBggrBgEFBQcCARYeaHR0cHM6Ly93d3cuc3NsLmNvbS9yZXBvc2l0b3J5
# MBMGA1UdJQQMMAoGCCsGAQUFBwMIMEIGA1UdHwQ7MDkwN6A1oDOGMWh0dHA6Ly9j
# cmxzLnNzbC5jb20vU1NMY29tLVJvb3RDQS1SU0EtNDA5Ni1SMS5jcmwwHQYDVR0O
# BBYEFHCaZcFDgKP86bFkiW7xMJwJIcl8MA4GA1UdDwEB/wQEAwIBhjANBgkqhkiG
# 9w0BAQsFAAOCAgEAZRRbzTHpgOogYgWKOeiCkI1oVrkGmCrqOKqX9CiTREQLdYM/
# h7ANki98QP1fhAPEkTzT/Ur19IrPuZg7KaWL6SsmBqmD9+mBVtJmxdRdGbV8bpgl
# FDv2VeZgTSg3+UOD2O0G9HlgHqVHNKzSa/zL5+WYl3yT8Q29sZnIPGkQ+udv56/j
# q5NlAT9BON4iXSOCxe1bNvUd0hkS2GTsTNeQyOEHm7CkZdCg5X+DpmBginO7pk8Y
# m5GbTdQtSloJ3/Y2nVPycJ8kmmBAYMev7/hVQukhjjc4mO03LyPTFfqmMR1D5Tpu
# gGkD9nUuG41l55vOpXQm1JMbTgArpkn0/e9O+yTYlWuz2dSAZHf9jxNQAvILO1Pv
# 2JNQTfV0TyIteZP7gNcRfaHnnuSho8ohipKiE+1vEJIFE+c3gopxSpHCmn2THETk
# lWKV7ZrUKhhkdoOLj2KidCtYZrOoCV6x7f9+KfDPT61fKDVntGZdRKwzLV53VIN6
# oSS+KQN2VJaO8OZTOZpfgO4o6/9xpNr+EEaA3hNkoZk13R4LaqPC/309dfZmHBE8
# nBNjWBkV7AZdzdK8w7B0a/D9066a6oUa19OIktD+3kPpQ8YEt8oRp9zs1hoQ7fRn
# 9sdantP6nYRQFTpF8czGc+FGresbAH819Pv5vBhCluTo8Px2PpC71cM0jzsxggJW
# MIICUgIBATCBhjByMQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNV
# BAcMB0hvdXN0b24xETAPBgNVBAoMCFNTTCBDb3JwMS4wLAYDVQQDDCVTU0wuY29t
# IFRpbWVzdGFtcGluZyBJc3N1aW5nIFJTQSBDQSAyAhBUQ/g3vVruGAGEcrhc2o7j
# MAsGCWCGSAFlAwQCAaCCAWAwGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMBwG
# CSqGSIb3DQEJBTEPFw0yNjExMDUxODAwNThaMCgGCSqGSIb3DQEJNDEbMBkwCwYJ
# YIZIAWUDBAIBoQoGCCqGSM49BAMCMC8GCSqGSIb3DQEJBDEiBCBqaBrLwr7VK/dl
# N5FXS9FurBWdVvqJm+L7I3Z9QvuXljCByAYLKoZIhvcNAQkQAi8xgbgwgbUwgbIw
# ga8EIFdP6heq+l58aiubCMmYsXNeRQs4c8pE5qJMoJMOY/OwMIGKMHakdDByMQsw
# CQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24xETAP
# BgNVBAoMCFNTTCBDb3JwMS4wLAYDVQQDDCVTU0wuY29tIFRpbWVzdGFtcGluZyBJ
# c3N1aW5nIFJTQSBDQSAyAhBUQ/g3vVruGAGEcrhc2o7jMAoGCCqGSM49BAMCBEcw
# RQIhAKEsW6YIiS5n14+m6ZkSkti3NJZ4PLx4nURD9FOgEug6AiA5dgH2AT5C8hwO
# +S3Xtlxu2rg2mNRQqUqhM+dOOWgeWg==
# SIG # End signature block
