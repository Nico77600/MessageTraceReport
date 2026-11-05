# Message Trace Report

Exchange Online message trace at scale through the Microsoft Graph API, with a local SQLite history and CSV, JSON and HTML reports.

This folder contains everything needed to run the tool: `Invoke-MessageTraceReport.ps1`, the module and its C# engine, the configuration, the report template, the SQLite library and the guides.

> [!IMPORTANT]
> Files downloaded from the Internet may be blocked by Windows. Unblock them once, from this folder:
>
> ```powershell
> Get-ChildItem . -Recurse -File -Force | Unblock-File
> ```

## What you need

- A Windows computer with **PowerShell 7.4 or later** (the program is called `pwsh`; Windows PowerShell 5.1 is not enough).
- An **app registration** in Microsoft Entra ID with the Microsoft Graph permission `ExchangeMessageTrace.Read.All` and admin consent. It is the identity the tool uses to read message traces, read-only. The user guide explains each click.
- A **service principal** for the Microsoft message trace service in your tenant. It is a one-time entry that lets Microsoft Graph answer message trace requests for your tenant; the user guide gives the command.
- No module to install for certificate or secret sign-in; interactive sign-in uses `Microsoft.Graph.Authentication`. SQLite is bundled in `lib\sqlite`.

## Get started

1. **Check PowerShell.** Open a terminal and type `pwsh`, then `$PSVersionTable.PSVersion`. You should see a version that starts with 7 (7.4 or later). If `pwsh` is not found, install PowerShell 7, then open a new window. If the version starts with 5, you opened Windows PowerShell: use `pwsh`.
2. **Open this folder** in that window, for example `cd C:\Tools\MessageTraceReport-1.1.1`, then run the unblock command above. You should see no output. If a file is refused, close the programs that use the folder and run it again.
3. **Set up the application once and fill in the configuration**: follow chapter 2 of the user guide, `docs\MessageTraceReport-UserGuide.html` (double-click it, it opens in your browser). Then edit `config\MessageTraceReport.config.psd1`: `TenantId`, `AppId`, `CertificateThumbprint`. If the tool later lists a wrong value, fix it and run it again.
4. **Check without connecting:** `.\Invoke-MessageTraceReport.ps1 -Mode Status`. You should see the banner with your tenant, then *No database yet*, and no red error. If a message starts with `Package integrity:`, a file differs from the signed release: download the ZIP again from the Releases page (an unknown file of yours: move it out of this folder).
5. **First trace:** `.\Invoke-MessageTraceReport.ps1 -Sender john@contoso.com -Range Last7Days -Open`. You should see a progress line, then the HTML report opens in your browser. If you see `401` or `403`, the service principal or the admin consent is missing: the user guide, chapter 8, gives the cure.

Keep your own files (address lists, certificates, copies of the configuration) outside this folder, for example in `C:\Tools\MessageTraceReport-data\`: the tool refuses a folder that holds a file it does not know. Give list and credential paths as absolute paths.

More everyday commands:

```powershell
.\Invoke-MessageTraceReport.ps1 -Recipient *@fabrikam.com -Status Failed -Range Last7Days -Open
.\Invoke-MessageTraceReport.ps1 -MessageId '<CAJ1234@mail.contoso.com>' -Range Last10Days -IncludeDetails   # why each recipient got it or not
.\Invoke-MessageTraceReport.ps1 -Mode Collect                                     # scheduled task, whole tenant
.\Invoke-MessageTraceReport.ps1 -Mode Report -Range Last30Days -Sender 'sales-*@contoso.com'
```

## Content

| Item | Role |
|---|---|
| `config\` | Configuration file to fill in. |
| `docs\` | User guide and developer guide, each a single HTML file to open locally. |
| `lib\` | Bundled SQLite libraries. |
| `src\` | PowerShell code and C# engine sources, compiled in memory when the tool starts. |
| `templates\` | HTML report template. |
| `Invoke-MessageTraceReport.ps1` | Entry script. |
| `MessageTraceReport.psd1` | Module manifest. |
| `MessageTraceReport.psm1` | Module loader. |
| `README.md` | This readme. |
| `CHANGELOG.md` | What changed in each version. |
| `LICENSE` | MIT license. |
| `THIRD-PARTY-NOTICES.md` | Notices for bundled components. |

## Documentation

- [User guide](docs/MessageTraceReport-UserGuide.html): setup step by step, one command per everyday question, what to do when something goes wrong.
- [Developer guide](docs/MessageTraceReport-Guide.html): every setting, the internals and the Graph calls.
- [Change log](CHANGELOG.md)

Project page and releases: https://github.com/Nico77600/MessageTraceReport

License: [MIT](LICENSE). Third-party components: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Disclaimer

This Script is a Personal project.
It's provided "AS-IS". It's not an official Microsoft product so no support can be expected from Microsoft.

As any scripts you must read carefully the documentation and test it first in a Test environment before any run in Production.
