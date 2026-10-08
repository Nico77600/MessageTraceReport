# Message Trace Report

Exchange Online message trace at scale through the Microsoft Graph API, with a local SQLite history and CSV, JSON and HTML reports.

This folder contains everything needed to run the tool: `Invoke-MessageTraceReport.ps1`, the module and its C# engine, the configuration, the report template, the SQLite library and the guides. Tests and build tools stay outside it, in the repository.

> [!IMPORTANT]
> Files downloaded from the Internet may be blocked by Windows. Unblock them once, from this folder:
>
> ```powershell
> Get-ChildItem . -Recurse -File | Unblock-File
> ```

## Requirements

- PowerShell 7.4 or later, on Windows.
- Microsoft Graph `ExchangeMessageTrace.Read.All` with admin consent.
- The service principal of the Microsoft application `8bd644d1-64a1-4d4b-ae52-2e0cbf64e373`.
- No module is needed for certificate or secret authentication; interactive sign-in uses `Microsoft.Graph.Authentication`.
- SQLite is bundled in `lib\sqlite`.

## Quick start

```powershell
notepad .\config\MessageTraceReport.config.psd1        # TenantId, AppId, CertificateThumbprint

.\Invoke-MessageTraceReport.ps1 -Sender john@contoso.com                          # last 48 hours
.\Invoke-MessageTraceReport.ps1 -Recipient *@fabrikam.com -Status Failed -Range Last7Days -Open
.\Invoke-MessageTraceReport.ps1 -SenderFile .\vip.csv -Recipient *@gmail.com -Start 2026-09-01 -End 2026-10-01
.\Invoke-MessageTraceReport.ps1 -Sender alerts@contoso.com -Recipient helpdesk@contoso.com -Operator Or -IncludeDetails
.\Invoke-MessageTraceReport.ps1 -MessageId '<CAJ1234@mail.contoso.com>' -Range Last10Days -IncludeDetails   # why each recipient got it or not
.\Invoke-MessageTraceReport.ps1 -Mode Collect                                     # scheduled task, whole tenant
.\Invoke-MessageTraceReport.ps1 -Mode Report -Range Last30Days -Sender 'sales-*@contoso.com'
.\Invoke-MessageTraceReport.ps1 -Mode Status
```

## Content

| Item | Role |
|---|---|
| `config\` | Configuration file to fill in. |
| `docs\` | User and developer guides, Markdown and self-contained HTML. |
| `lib\` | Bundled SQLite libraries. |
| `src\` | PowerShell code and C# engine sources, compiled on first use. |
| `templates\` | HTML report template. |
| `Invoke-MessageTraceReport.ps1` | Entry script. |
| `MessageTraceReport.psd1` | Module manifest. |
| `MessageTraceReport.psm1` | Module loader. |
| `README.md` | This package readme. |
| `LICENSE` | MIT license. |
| `THIRD-PARTY-NOTICES.md` | Notices for bundled components. |

## Documentation

- [User guide](docs/MessageTraceReport-UserGuide.md) - also `docs/MessageTraceReport-UserGuide.html`, a single file to open locally
- [Developer guide](docs/MessageTraceReport-Guide.md) - also `docs/MessageTraceReport-Guide.html`

Project page, releases and change log: https://github.com/Nico77600/MessageTraceReport

License: [MIT](LICENSE). Third-party components: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
