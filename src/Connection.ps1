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
