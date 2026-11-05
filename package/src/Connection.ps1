<#
    Message Trace Report - Microsoft Graph token.

    Three ways to obtain an access token for https://graph.microsoft.com with ExchangeMessageTrace.Read.All:

      Certificate   app-only, recommended for scheduled tasks. The client assertion (a JWT signed with the
                    private key of the certificate) is built here: no PowerShell module is needed.
      ClientSecret  app-only with a secret, read from an environment variable (Authentication.ClientSecretVariable)
                    or typed at the prompt (hidden). Never stored by the tool. Kept for compatibility:
                    Microsoft recommends a certificate.
      Interactive   an administrator signs in (browser, MFA). Uses MSAL from the Microsoft.Graph.Authentication
                    module. Delegated permission ExchangeMessageTrace.Read.All on the client application.

    The token is checked before any request: right tenant, permission present. The collection runs in the
    engine; Update-MtrToken is called by the progress loop and renews the token 5 minutes before it expires
    (or at once after a 401).
#>

function Get-MtrTokenClaims {
    <# Payload of a JWT (no signature check: only used to read tid, roles, scp, app name). #>
    param([Parameter(Mandatory)][string]$Token)
    $parts = $Token.Split('.')
    if ($parts.Count -lt 2) { throw 'The access token is not a JWT.' }
    $p = $parts[1].Replace('-', '+').Replace('_', '/')
    while ($p.Length % 4) { $p += '=' }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
}

function Get-MtrCertificate {
    <# Certificate with its private key, from Cert:\CurrentUser\My or Cert:\LocalMachine\My. #>
    param([Parameter(Mandatory)][string]$Thumbprint)
    $thumb = $Thumbprint.Trim().ToUpperInvariant()
    foreach ($store in 'Cert:\CurrentUser\My', 'Cert:\LocalMachine\My') {
        $cert = Get-Item -LiteralPath (Join-Path $store $thumb) -ErrorAction SilentlyContinue
        if ($cert) {
            if (-not $cert.HasPrivateKey) { throw "Certificate $thumb found in $store without its private key: import the .pfx (not the .cer) for the account that runs the tool." }
            if ($cert.NotAfter -lt (Get-Date)) { throw "Certificate $thumb expired on $($cert.NotAfter.ToString('yyyy-MM-dd')). Upload a new certificate to the application and update Authentication.CertificateThumbprint." }
            return $cert
        }
    }
    throw "Certificate $thumb not found in Cert:\CurrentUser\My nor Cert:\LocalMachine\My (account $([Environment]::UserName)). Guide, annex 'Certificate'."
}

function ConvertTo-MtrBase64Url { param([byte[]]$Bytes) [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_') }

function New-MtrClientAssertion {
    <# Client assertion (RFC 7523) signed with the certificate: RS256, header x5t = SHA-1 thumbprint, valid 10 minutes. #>
    param([Parameter(Mandatory)][Security.Cryptography.X509Certificates.X509Certificate2]$Certificate, [Parameter(Mandatory)][string]$TenantId, [Parameter(Mandatory)][string]$AppId)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $header = [ordered]@{ alg = 'RS256'; typ = 'JWT'; x5t = (ConvertTo-MtrBase64Url $Certificate.GetCertHash()) } | ConvertTo-Json -Compress
    $claims = [ordered]@{ aud = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"; iss = $AppId; sub = $AppId; jti = [guid]::NewGuid().ToString(); nbf = $now - 60; iat = $now; exp = $now + 600 } | ConvertTo-Json -Compress
    $unsigned = (ConvertTo-MtrBase64Url ([Text.Encoding]::UTF8.GetBytes($header))) + '.' + (ConvertTo-MtrBase64Url ([Text.Encoding]::UTF8.GetBytes($claims)))
    $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    if (-not $rsa) { throw "Certificate $($Certificate.Thumbprint): the private key is not an RSA key, or it cannot be used by this account." }
    try { $signature = $rsa.SignData([Text.Encoding]::ASCII.GetBytes($unsigned), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1) }
    finally { $rsa.Dispose() }
    return "$unsigned.$(ConvertTo-MtrBase64Url $signature)"
}

function Get-MtrEntraErrorHint {
    <# A sentence for the most frequent Microsoft Entra sign-in errors. #>
    param([string]$Message)
    $hints = [ordered]@{
        'AADSTS700016' = 'the application ID is not found in this tenant (Authentication.AppId, Tenant.TenantId).'
        'AADSTS90002'  = 'the tenant ID is not found (Tenant.TenantId).'
        'AADSTS700027' = 'the certificate is not registered on the application, or not the right one (thumbprint).'
        'AADSTS7000215' = 'the client secret is not valid for this application.'
        'AADSTS7000222' = 'the client secret has expired: create a new one, or move to a certificate.'
        'AADSTS700024' = 'the clock of this computer is not on time (the assertion is outside its validity).'
        'AADSTS65001'  = 'admin consent is missing for ExchangeMessageTrace.Read.All.'
        'AADSTS50105'  = 'the account is not assigned to the application.'
        'AADSTS53003'  = 'blocked by Conditional Access.'
    }
    foreach ($code in $hints.Keys) { if ($Message -match $code) { return "$code - $($hints[$code])" } }
    return $null
}

function Get-MtrAppToken {
    <# App-only token (client credentials): certificate or secret. Returns @{ Token; ExpiresMs }. #>
    param([Parameter(Mandatory)]$Settings, $Certificate, [Security.SecureString]$Secret)
    $tenant = $Settings.Tenant.TenantId; $appId = $Settings.Authentication.AppId
    $body = @{ client_id = $appId; scope = 'https://graph.microsoft.com/.default'; grant_type = 'client_credentials' }
    if ($Certificate) {
        $body['client_assertion_type'] = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        $body['client_assertion'] = New-MtrClientAssertion -Certificate $Certificate -TenantId $tenant -AppId $appId
    } else {
        $body['client_secret'] = [Net.NetworkCredential]::new('', $Secret).Password
    }
    try { $r = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token" -Body $body -ErrorAction Stop }
    catch {
        $detail = $_.ErrorDetails.Message
        $text = try { ($detail | ConvertFrom-Json).error_description } catch { $_.Exception.Message }
        if (-not $text) { $text = $_.Exception.Message }
        $hint = Get-MtrEntraErrorHint $text
        throw ("Microsoft Entra sign-in failed{0}: {1}" -f $(if ($hint) { " ($hint)" } else { '' }), ($text -split "`r?`n")[0])
    }
    finally { $body.Clear() }
    return @{ Token = $r.access_token; ExpiresMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 1000L * [int]$r.expires_in }
}

function Import-MtrMsal {
    <# MSAL (Microsoft.Identity.Client) from the Microsoft.Graph.Authentication module: Interactive mode only. #>
    if ('Microsoft.Identity.Client.PublicClientApplicationBuilder' -as [type]) { return }
    $source = Get-Module -ListAvailable Microsoft.Graph.Authentication | Sort-Object Version -Descending |
        ForEach-Object { Join-Path $_.ModuleBase 'Dependencies' } |
        Where-Object { Test-Path -LiteralPath (Join-Path $_ 'Core\Microsoft.Identity.Client.dll') } | Select-Object -First 1
    if (-not $source) { throw 'Interactive mode needs the Microsoft.Graph.Authentication module (Install-Module Microsoft.Graph.Authentication -Scope CurrentUser), or use Certificate mode.' }
    Add-Type -LiteralPath (Join-Path $source 'Microsoft.IdentityModel.Abstractions.dll')
    Add-Type -LiteralPath (Join-Path $source 'Core\Microsoft.Identity.Client.dll')
}

function Connect-MtrGraph {
    <#
    .SYNOPSIS
        Obtains the first access token and checks it. Returns the connection used by Update-MtrToken.
    .OUTPUTS
        @{ Mode; Account; AppName; TenantId; Token; ExpiresMs; Renew (scriptblock) }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings)
    $auth = $Settings.Authentication
    $connection = [ordered]@{ Mode = $auth.Mode; Account = ''; AppName = ''; TenantId = $Settings.Tenant.TenantId; Token = $null; ExpiresMs = 0; Renew = $null; Certificate = $null }
    switch ($auth.Mode) {
        'Certificate' {
            $cert = Get-MtrCertificate $auth.CertificateThumbprint
            if ($cert.NotAfter -lt (Get-Date).AddDays(30)) { Write-MtrItem Warn ("Certificate {0} expires on {1}: renew it." -f $cert.Thumbprint, $cert.NotAfter.ToString('yyyy-MM-dd')) }
            $connection.Certificate = $cert
            $connection.Renew = { param($s, $c) Get-MtrAppToken -Settings $s -Certificate $c.Certificate }
        }
        'ClientSecret' {
            $value = [Environment]::GetEnvironmentVariable($auth.ClientSecretVariable)
            if ($value) { $secret = ConvertTo-SecureString $value -AsPlainText -Force; $value = $null }
            elseif ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) { $secret = Read-Host -AsSecureString "      Client secret of application $($auth.AppId)" }
            else { throw "ClientSecret mode: the environment variable $($auth.ClientSecretVariable) is empty and the session is not interactive." }
            if (-not $secret -or $secret.Length -eq 0) { throw 'No client secret given.' }
            $connection['Secret'] = $secret
            $connection.Renew = { param($s, $c) Get-MtrAppToken -Settings $s -Secret $c.Secret }
        }
        'Interactive' {
            Import-MtrMsal
            $clientId = if ($auth.AppId) { $auth.AppId } else { '14d82eec-204b-4c2f-b7e8-296a70dab67e' }   # Microsoft Graph Command Line Tools
            $app = [Microsoft.Identity.Client.PublicClientApplicationBuilder]::Create($clientId).WithTenantId($Settings.Tenant.TenantId).WithRedirectUri('http://localhost').Build()
            $scopes = [string[]]@("https://graph.microsoft.com/$($script:Permission)")
            $cts = [Threading.CancellationTokenSource]::new([TimeSpan]::FromMinutes(5))
            $request = $app.AcquireTokenInteractive($scopes).WithUseEmbeddedWebView($false).WithPrompt([Microsoft.Identity.Client.Prompt]::SelectAccount)
            if ($auth.UserPrincipalName) { $request = $request.WithLoginHint($auth.UserPrincipalName) }
            Write-MtrItem Info 'Sign in in the browser window (Microsoft Entra).' -Icon Key
            try { $result = $request.ExecuteAsync($cts.Token).GetAwaiter().GetResult() }
            catch { $hint = Get-MtrEntraErrorHint $_.Exception.Message; throw ("Interactive sign-in failed{0}: {1}" -f $(if ($hint) { " ($hint)" } else { '' }), $_.Exception.Message) }
            $connection['Msal'] = $app; $connection['MsalAccount'] = $result.Account; $connection['Scopes'] = $scopes
            $connection.Token = $result.AccessToken; $connection.ExpiresMs = $result.ExpiresOn.ToUnixTimeMilliseconds()
            $connection.Renew = { param($s, $c)
                $r = $c.Msal.AcquireTokenSilent($c.Scopes, $c.MsalAccount).WithForceRefresh($true).ExecuteAsync().GetAwaiter().GetResult()
                @{ Token = $r.AccessToken; ExpiresMs = $r.ExpiresOn.ToUnixTimeMilliseconds() } }
        }
    }
    if (-not $connection.Token) {
        $t = & $connection.Renew $Settings $connection
        $connection.Token = $t.Token; $connection.ExpiresMs = $t.ExpiresMs
    }

    # Checks before the first request: right tenant, permission granted.
    $claims = Get-MtrTokenClaims $connection.Token
    if ($claims.tid -ne $Settings.Tenant.TenantId) { throw "Connected to tenant $($claims.tid), but Tenant.TenantId is $($Settings.Tenant.TenantId). Nothing was read." }
    if ($auth.Mode -eq 'Interactive') {
        $connection.Account = [string]$claims.upn
        if (-not $connection.Account) { $connection.Account = [string]$claims.unique_name }
        if ($auth.UserPrincipalName -and $connection.Account -ne $auth.UserPrincipalName) { throw "Signed in as $($connection.Account), but Authentication.UserPrincipalName is $($auth.UserPrincipalName)." }
        $scopes = @("$($claims.scp)" -split ' ')
        if ($scopes -notcontains $script:Permission) { throw "The token has no delegated permission $($script:Permission) (scopes: $($claims.scp)). An administrator must consent to it for the client application." }
    } else {
        $roles = @($claims.roles)
        $connection.AppName = [string]$claims.app_displayname
        $connection.Account = if ($connection.AppName) { "$($connection.AppName) ($($Settings.Authentication.AppId))" } else { "application $($Settings.Authentication.AppId)" }
        if ($roles -notcontains $script:Permission) {
            throw "The application has no application permission $($script:Permission) with admin consent (roles in the token: $(if ($roles.Count) { $roles -join ', ' } else { 'none' })). Entra admin center > App registrations > API permissions > Microsoft Graph > Application permissions, then 'Grant admin consent'."
        }
    }
    return $connection
}

function Update-MtrToken {
    <# Renews the token held by the engine when it expires within 5 minutes or after a 401. Returns $true when renewed. #>
    param([Parameter(Mandatory)]$Connection, [Parameter(Mandatory)][MessageTraceReport.TokenSlot]$Slot, [Parameter(Mandatory)]$Settings, [switch]$Force)
    if (-not $Force -and -not $Slot.NeedsRefresh(300000)) { return $false }
    $t = & $Connection.Renew $Settings $Connection
    $Connection.Token = $t.Token; $Connection.ExpiresMs = $t.ExpiresMs
    $Slot.Set($t.Token, $t.ExpiresMs)
    Write-MtrLog 'INFO' ("Access token renewed, valid until {0:HH:mm:ss}." -f [DateTimeOffset]::FromUnixTimeMilliseconds($t.ExpiresMs).ToLocalTime())
    return $true
}

# SIG # Begin signature block
# MIImJAYJKoZIhvcNAQcCoIImFTCCJhECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAf7zBCq26AKJgc
# DrQyPL9Gs2R4wdLr8HFegF85S3Fwx6CCDW8wggZyMIIEWqADAgECAghkM1HTxzif
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
# wZislcdCZuS6MYIYCzCCGAcCAQEwgYwweDELMAkGA1UEBhMCVVMxDjAMBgNVBAgM
# BVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDE0MDIG
# A1UEAwwrU1NMLmNvbSBDb2RlIFNpZ25pbmcgSW50ZXJtZWRpYXRlIENBIFJTQSBS
# MQIQBof4ljXihJpmCqqt2mhAWzANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3
# AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDcYes+CNnt
# 4eHv6fhf08So6VcEjoAVgqr7MrtSy5PmlDANBgkqhkiG9w0BAQEFAASCAgAmCh8m
# nbHEpe5+q6F3Fq+aoXDlS0ylbPhFE42BNXr2B9xIV1/gnA1j9EsA8pbUbNnybAS3
# 2/GTpwk9KWBUx1YBKO4pJieUcMDga8zgWOkCO09GvPl7TjEH1XN/hLQsBPZ1Xa9Z
# gb5T6nezxYTZErgIn1Gfp2yO0E8ahOvz4y0IBaqbn4BHx60xT8aLhfJb4P5hTijK
# CMKbkEGQ61m56a2AnuA6wlUFa0xokgN9xeNjGhC9BQBthmNADP65M2EJngB2BFeP
# aUY8yXm6o/LHGeWqeyI98eI13ySGNxlkFE93ZvF3wTiUqHp3CFzHExr4mapn+DCy
# /AROXPEKB5WZJFyk+gqgdS1Dzj3dsUG9xUjKll4cbnIrT5Xgr129qS/K/KFjePH7
# rn+zIC7pZVN9ozgkVEVvbYA7IAC5kMgIfBVFMAv2g6SJgur8OzlQt0rQ4QlAdQD2
# wbqqYrVBNFDGJLpQ9i6D8pZSWBOsAGaQN8l/vtmJeuoqPvVOOMXRRpySqHXtMP/+
# t/S80zPI8sYziC68RuQqlummbABZWqPpYCLM2t6JFace4pv56S4JVWnk/vh0+OdJ
# nLinKYqeHEghA1Gkyv4bK1iMiJ2bA8304CGIKC/A9X6LQUhrZT998X2Gg0WPOOdM
# fni1nESoMwCaWsGESHPBmzgXBDRb6wxZ6RvWDaGCFMgwghTEBgorBgEEAYI3AwMB
# MYIUtDCCFLAGCSqGSIb3DQEHAqCCFKEwghSdAgEDMQ0wCwYJYIZIAWUDBAIBMIGC
# BgsqhkiG9w0BCRABBKBzBHEwbwIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEIGji/smjsT+UZhPiKldRfR+RGJ8coIAxsO7u5L2Pxg8pAgh0S0F3hkAM
# rBgPMjAyNjExMDUxODAwNThaMAMCAQECCQC5kjha4EY65aCCEacwggTzMIIC26AD
# AgECAhBUQ/g3vVruGAGEcrhc2o7jMA0GCSqGSIb3DQEBCwUAMHIxCzAJBgNVBAYT
# AlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjERMA8GA1UECgwI
# U1NMIENvcnAxLjAsBgNVBAMMJVNTTC5jb20gVGltZXN0YW1waW5nIElzc3Vpbmcg
# UlNBIENBIDIwHhcNMjYwNjEyMTcyMjQ2WhcNMzYwNjA5MTcyMjQ1WjBuMQswCQYD
# VQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24xETAPBgNV
# BAoMCFNTTCBDb3JwMSowKAYDVQQDDCFTU0wuY29tIFRpbWVzdGFtcGluZyBVbml0
# IDIwMjYgRTEwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAToJYu4ZhMuSJI48ws2
# yQ4G2FewiFFIDjp945DC9ItwNo2Hq/FTMEoTHUp0UFEWzs4eucf8rRUDoxsNAgWl
# SDQ9o4IBUjCCAU4wHwYDVR0jBBgwFoAUcJplwUOAo/zpsWSJbvEwnAkhyXwwTQYI
# KwYBBQUHAQEEQTA/MD0GCCsGAQUFBzAChjFodHRwOi8vY2VydC5zc2wuY29tL1NT
# TC5jb20tdGltZVN0YW1waW5nLUktUjIuY2VyMFEGA1UdIARKMEgwPAYMKwYBBAGC
# qTABAwYBMCwwKgYIKwYBBQUHAgEWHmh0dHBzOi8vd3d3LnNzbC5jb20vcmVwb3Np
# dG9yeTAIBgZngQwBBAIwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwQgYDVR0fBDsw
# OTA3oDWgM4YxaHR0cDovL2NybHMuc3NsLmNvbS9TU0wuY29tLXRpbWVTdGFtcGlu
# Zy1JLVIyLmNybDAdBgNVHQ4EFgQUJ6wDVrooaroXO4M9QH95qCTswzwwDgYDVR0P
# AQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQBPdm7O/AOewhlNcGf6GOa4FeDM
# HXZ9tjFP25h7pm+G+ltlYpzINCBpwROQ/DyTrJ6qdgJjIVnTreUw8SoCEAPacwbr
# XhmHs+0db0Nap+yCK/Fs9gF4363tTGCRhPd7GltYx08SoG1ZXIc68twq8zGAlZ8m
# MA3BWTBUN+TL+Ptx/bz6KKY3w8pztL+7z8t6dFGdXZbZh+dxGeTP0J+zmdEPNpmC
# 6IeuunYbHCCc1BIfgYGMc6Xc/MuydVsahkqLhkSOBe6mziYYY4rv4YHYcCVCf45L
# 3jhweqWQfSASW3ZZ7OgI1GkQumH2prG4GeNISpdZZ+ATrIYHA7S7Eo2qlZVMeYDC
# vpK8E+h/G5tci4Sf2K9HgIs64DFRKsnjVkGD+qobSgmMXoaREpvGrtzJZKQRlgmG
# YoKDYeDl9cdqA7GLBuafkk9nW+FYKtuTe/91PHaC9Mrn56sLkf3+tNyWNQjvvrJ3
# at+GN+Sm/ICxu1ezgPueufDyL3Civn5921FIkFXGrMubKQV+2gvRSnZD763IoJR2
# uJt1yesHgcpLez63cCN1xsDToMIvwaJ9CL18vTJEFE2UDijoE/5KvvnkxoI2NRFh
# kO8PLEkcEFPtyqNkjCyJHyz7rzrSegVsEG12B7YjDsI8L/VDfUjbuFWiVLsHTJqj
# e/xfYy1bLeaxmVdNwTCCBd0wggPFoAMCAQICCHssm9MWgDKZMA0GCSqGSIb3DQEB
# CwUAMHwxCzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91
# c3RvbjEYMBYGA1UECgwPU1NMIENvcnBvcmF0aW9uMTEwLwYDVQQDDChTU0wuY29t
# IFJvb3QgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkgUlNBMB4XDTE2MDIxMjE3Mzkz
# OVoXDTQxMDIxMjE3MzkzOVowfDELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFz
# MRAwDgYDVQQHDAdIb3VzdG9uMRgwFgYDVQQKDA9TU0wgQ29ycG9yYXRpb24xMTAv
# BgNVBAMMKFNTTC5jb20gUm9vdCBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eSBSU0Ew
# ggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQD5D92jK33L0Cr+7GeFpucu
# G7p34eP1r6Ts+kpdkcRXR2sYd2t28v2T5D0PwhaeC2bDVpSeF4OFzlbv8hb9AGL1
# IglU6GUXTkG54E9Gl6obyLhuYl5psV/bKgJ+/GzK80HY7dDo/D9hSO2wAxQdEA5L
# GeC7TuyGZf82815nAgudhlVh/Xo47f7iGQC3b6FQYnV0PKD6yCWStG56Isf4HqHj
# st2RMasrHQT/pUoEN+mFpDMr/eLWVTR8GaRKaMeyqNO3yqGTiOvBl7yM+R3ZIoQk
# dMcEPWqpKZPM67hb4f5fJao0WMjBI1SdG5gRwzicfj2GbKUPQIZ8AvRcAk8oy65x
# nw86yDP+ESU16vy6xWA92XwY1bKp03V4A3IiyjrDH+8s5S6p+p4stlFG/a8D1upg
# aOqFFjZrhekewLPdxCTcgCqBQW2UPsjgyYFBAJ5ev3/FCJiiGCxCQLP5bzgnS06A
# 9D2BR+CIfOoczrV1XFEuHCt/GnIo5wC10XTG1+SfrQeTtlM1Nfw35MP2XRa+IXPe
# kgr4oGNqvJaSaj74vGVVm971DYkmBPwlGqYlacvCbcp84llfl6zr7y7IvNcbWTwr
# zPIZyJNrJ2MZz/zpJvjKcZt/k/40Z4ROmev8s3gJM3C6ZqZ27Rtz6xqlDcQiEyCU
# VgpOLGxOsf3PnAm6ojPthwIDAQABo2MwYTAdBgNVHQ4EFgQU3QQJB6L1en1SUxKS
# le44gCUNplkwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTdBAkHovV6fVJT
# EpKV7jiAJQ2mWTAOBgNVHQ8BAf8EBAMCAYYwDQYJKoZIhvcNAQELBQADggIBACAY
# EZQp+yadHB4ecGHxlXKTcSStaJNYjjKvG7NwA/wlK3SFkD14avS5i6WXO7UYkbse
# p/lAW5H5VZmvHhHQXB2nZuOxlAcMMjmm6huwedgdnHBE44rdxPmVH4o4Qz8BhaVH
# pz1GsrzlImj3e5zYLD4KIcgtM6y/xYGZMXTBdXHFvrHwI0X0nWv8GWOdo7wExhgL
# JbtTiQ+zgFDeRe5Ef6uUeGSY0/Yo3YfYcGV0+w65E+unD2GpMpbM3rvtY0wYu6lA
# 96BUbiCIcXUY6nq0NHLgIyd3XLaQ6oYlQKvvMw/Ln4K+oiD79rUtGubChbF0D/vI
# ZQKkUgFH3Ukiwb/Y62usft7sYzMVtyMIj8YPjUFa3Y7FuY/lRT9427rSG0Cx/nFN
# P+CBorpetOwV4JPdCB9+4VWZCyHek54K++ajSb02MP7nd7KgdZe1LYGIF2Ug99qQ
# AJ/JUswyyjV89T0P2CvX9SZsyQY0lhbqcFkaMnl5C7aIfw9SSD2/bNiiRC7RTrdy
# WNOJE5X+RKv414sbbpy8LKBb1WoAr1834dX6EAuYnIbnJo/O8OxuilcLgONOssCg
# Y2GQulVoN3RqtpLbn6GGIrZlJw7stp9CYORnwrXaQQvE04thG7z6H5Er10QHXrop
# rNnF6e9TSFrrgPEoWCHNsAZV+yc/U5BwqQQeVye5MIIGyzCCBLOgAwIBAgIQUp27
# wriJh/WDgOCw66IGNjANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzEOMAwG
# A1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24xGDAWBgNVBAoMD1NTTCBDb3Jw
# b3JhdGlvbjExMC8GA1UEAwwoU1NMLmNvbSBSb290IENlcnRpZmljYXRpb24gQXV0
# aG9yaXR5IFJTQTAeFw0yNjA2MTIxNjQyMTVaFw00MTAyMTIxNzM5MzlaMHIxCzAJ
# BgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjERMA8G
# A1UECgwIU1NMIENvcnAxLjAsBgNVBAMMJVNTTC5jb20gVGltZXN0YW1waW5nIElz
# c3VpbmcgUlNBIENBIDIwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCf
# L6vmc02QvDFGmzYHeVpQY1T3Lu9aInnTXfJ/SJfPrltB3Br1uOPyX9KR5eocap9K
# HYWhp77zQTyYMR/3egjCOzLYJfZxeYrGq0XwckZgHh/rJGEoQPnTCRs7KwvTYhd/
# 78RmdrjiN9+GFXPg5T+TnbFD8+ciD+4WFzZaT5Jz8IeoCv6VhWQ/PsvLlGoH1/VE
# oav0kLftbUuBV0cLnR00h2xrdBc+GW1hm5tHeekTgFt+LSOhRbmfk7RrLB43jlH9
# hUvEDRgaWnU4dV9WeyperxuGfDUtziSMnpc6BeU6XD9rzN7ntO9t25mXd6F7BOa8
# 7QCTL+eo5YNL0g8/F3F0bq+msFtK4eXE0A0EBsdOIWCR9mZ/R1liVP8CdkigXECr
# Qcgs+iV/g6BaARPvpKJZKWbZdhEhfBWOl6obSmW9fBEhAHNKIQmPtB5AWcK8fHiB
# Awg283f7Ib/WvGERtqMa97S1M/eVfg884dUATRAmnhnM8jVhgmSFVGuJVXFVFTgW
# yDgE/A/oj5guYdvW1nhEvA4U0uH+AlgOA+UKEKjE6iAXFeDA9lmsPIRFgHRp457F
# bQ4ppw3hFG71yoXYoq78BvkAvt5gMtUZQ+sQTJhsgwClUqql5tzT+MNCeIL7euRq
# 5ECOBVzybWKn8JCAbUPDhn26VVEBj1VHplrbouxNtQIDAQABo4IBUTCCAU0wEgYD
# VR0TAQH/BAgwBgEB/wIBADAfBgNVHSMEGDAWgBTdBAkHovV6fVJTEpKV7jiAJQ2m
# WTBNBggrBgEFBQcBAQRBMD8wPQYIKwYBBQUHMAKGMWh0dHA6Ly9jZXJ0LnNzbC5j
# b20vU1NMY29tLVJvb3RDQS1SU0EtNDA5Ni1SMS5jZXIwPwYDVR0gBDgwNjA0BgRV
# HSAAMCwwKgYIKwYBBQUHAgEWHmh0dHBzOi8vd3d3LnNzbC5jb20vcmVwb3NpdG9y
# eTATBgNVHSUEDDAKBggrBgEFBQcDCDBCBgNVHR8EOzA5MDegNaAzhjFodHRwOi8v
# Y3Jscy5zc2wuY29tL1NTTGNvbS1Sb290Q0EtUlNBLTQwOTYtUjEuY3JsMB0GA1Ud
# DgQWBBRwmmXBQ4Cj/OmxZIlu8TCcCSHJfDAOBgNVHQ8BAf8EBAMCAYYwDQYJKoZI
# hvcNAQELBQADggIBAGUUW80x6YDqIGIFijnogpCNaFa5Bpgq6jiql/Qok0REC3WD
# P4ewDZIvfED9X4QDxJE80/1K9fSKz7mYOymli+krJgapg/fpgVbSZsXUXRm1fG6Y
# JRQ79lXmYE0oN/lDg9jtBvR5YB6lRzSs0mv8y+flmJd8k/ENvbGZyDxpEPrnb+ev
# 46uTZQE/QTjeIl0jgsXtWzb1HdIZEthk7EzXkMjhB5uwpGXQoOV/g6ZgYIpzu6ZP
# GJuRm03ULUpaCd/2Np1T8nCfJJpgQGDHr+/4VULpIY43OJjtNy8j0xX6pjEdQ+U6
# boBpA/Z1LhuNZeebzqV0JtSTG04AK6ZJ9P3vTvsk2JVrs9nUgGR3/Y8TUALyCztT
# 79iTUE31dE8iLXmT+4DXEX2h557koaPKIYqSohPtbxCSBRPnN4KKcUqRwpp9kxxE
# 5JVile2a1CoYZHaDi49ionQrWGazqAlese3/finwz0+tXyg1Z7RmXUSsMy1ed1SD
# eqEkvikDdlSWjvDmUzmaX4DuKOv/caTa/hBGgN4TZKGZNd0eC2qjwv99PXX2ZhwR
# PJwTY1gZFewGXc3SvMOwdGvw/dOumuqFGtfTiJLQ/t5D6UPGBLfKEafc7NYaEO30
# Z/bHWp7T+p2EUBU6RfHMxnPhRq3rGwB/NfT7+bwYQpbk6PD8dj6Qu9XDNI87MYIC
# VzCCAlMCAQEwgYYwcjELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYD
# VQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDEuMCwGA1UEAwwlU1NMLmNv
# bSBUaW1lc3RhbXBpbmcgSXNzdWluZyBSU0EgQ0EgMgIQVEP4N71a7hgBhHK4XNqO
# 4zALBglghkgBZQMEAgGgggFgMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAc
# BgkqhkiG9w0BCQUxDxcNMjYxMTA1MTgwMDU4WjAoBgkqhkiG9w0BCTQxGzAZMAsG
# CWCGSAFlAwQCAaEKBggqhkjOPQQDAjAvBgkqhkiG9w0BCQQxIgQgg3ke0BoTi+LP
# 6lHz8L227Gz2lreCCaAN17m7V2xw38YwgcgGCyqGSIb3DQEJEAIvMYG4MIG1MIGy
# MIGvBCBXT+oXqvpefGormwjJmLFzXkULOHPKROaiTKCTDmPzsDCBijB2pHQwcjEL
# MAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREw
# DwYDVQQKDAhTU0wgQ29ycDEuMCwGA1UEAwwlU1NMLmNvbSBUaW1lc3RhbXBpbmcg
# SXNzdWluZyBSU0EgQ0EgMgIQVEP4N71a7hgBhHK4XNqO4zAKBggqhkjOPQQDAgRI
# MEYCIQCKX3eEWpT4sRvf7fyBChTPnEK6eoqNQIvkKU+Y6Gb0JQIhANx9q+8uNbgN
# W0pxEo8BZUWzqfErk+FnFjtkZFO+vUgt
# SIG # End signature block
