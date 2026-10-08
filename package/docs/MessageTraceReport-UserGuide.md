---
title: Message Trace Report
subtitle: User guide
version: 1.1.0
author: Nicolas Fabert
updated: 2026-10-08
---

# Message Trace Report — User guide

> What you need before the first trace, then one command per everyday question: **did this message leave, and who received it?**, **why was it not delivered?**, **every message of this list of people to that domain last month**, **what does the database already hold?** The Graph API itself, the planner, every setting and the internals are in the [developer guide](MessageTraceReport-Guide.md).

> [!IMPORTANT]
> Files downloaded from the Internet may be blocked by Windows and fail to run. Before using this project, unblock every file in the downloaded folder:
>
> ```powershell
> Get-ChildItem "C:\Chemin\Du\Dossier" -Recurse -File -Force | Unblock-File
> ```
>
> Replace the example path with the folder where you downloaded or extracted this project.

```cards
checklist | Prerequisites | PowerShell 7.4+, an application with a certificate, one Microsoft Graph permission.
terminal | Everyday use | One command per question: a sender, a domain, a message ID, a list of addresses.
search | Why it failed | `-IncludeDetails` reads the route of each recipient and names the cause.
file | Results | CSV, optional JSON and a self-contained HTML report under `reports\`.
```

# Part I · Start here

<!-- icon: checklist -->
## 1. Prerequisites

| Item | Requirement |
|---|---|
| Operating system | Windows 10 / 11 or Windows Server 2019 or later (x64 or ARM64) |
| PowerShell | **7.4 or later** (`pwsh`). Windows PowerShell 5.1 is not supported. |
| Console | Windows Terminal recommended (colours and emoji); the classic console works with simple symbols. |
| Modules | **None** in Certificate and ClientSecret modes. Interactive mode: `Microsoft.Graph.Authentication` (for MSAL only). |
| Permission | Microsoft Graph **`ExchangeMessageTrace.Read.All`** — application (certificate, secret) or delegated (interactive), with admin consent. |
| Tenant | Service principal of the application `8bd644d1-64a1-4d4b-ae52-2e0cbf64e373`. Global service only (not GCC High, DoD, 21Vianet). |
| Network | `https://login.microsoftonline.com` and `https://graph.microsoft.com` (system proxy used). |
| SQLite | Bundled in `lib\sqlite` — nothing to install. |

> [!IMPORTANT]
> The tool is **read-only** for Microsoft 365: it only calls the message trace API, and changes nothing in the tenant. The database, the reports and the logs stay on the local disk.

> [!WARNING]
> `data\`, `reports\` and `logs\` contain e-mail addresses and subjects. Restrict the NTFS permissions of the tool folder to the administrators who run it.

<!-- icon: download -->
## 2. One-time setup

Everything you run is in the `package` folder of the repository, or in the folder where you extracted the zip of a [release](https://github.com/Nico77600/MessageTraceReport/releases). Work from that folder.

```steps
Get the files | `git clone https://github.com/Nico77600/MessageTraceReport.git`, then `cd MessageTraceReport\package` — or extract the release zip, for example to `C:\Tools\MessageTraceReport`.
Unblock the files | From that folder: `Get-ChildItem . -Recurse -File | Unblock-File`.
Register the application | A certificate, an app registration with the application permission `ExchangeMessageTrace.Read.All` and admin consent, and the message trace service principal — the six steps are in the [developer guide, chapter 7](MessageTraceReport-Guide.md#7-application-registration).
Fill in the configuration | `notepad .\config\MessageTraceReport.config.psd1`: `Tenant.TenantId`, `Authentication.AppId`, `Authentication.CertificateThumbprint`.
Check without connecting | `.\Invoke-MessageTraceReport.ps1 -Mode Status` checks the configuration and compiles the engine (a few seconds, once).
First trace | `.\Invoke-MessageTraceReport.ps1 -Sender john@contoso.com -Range Last7Days -Open`.
```

The settings you fill in once:

| Setting | Meaning |
|---|---|
| `Tenant.TenantId` | Tenant ID (GUID). The tool stops if the token belongs to another tenant. |
| `Authentication.Mode` | `Certificate` (recommended), `ClientSecret` or `Interactive`. |
| `Authentication.AppId` | Application (client) ID. Interactive: `''` = Microsoft Graph Command Line Tools. |
| `Authentication.CertificateThumbprint` | In `Cert:\CurrentUser\My` or `Cert:\LocalMachine\My`, with its private key. |
| `Report.TimeZone` | Dates and days of the reports (`Europe/Paris` by default). |
| `Report.DefaultRange` | Period used when none is given (`Last48Hours`). |

The tool creates, next to itself: `data\` (the SQLite database), `reports\` (one sub-folder per run), `logs\` (one file per day) and `bin\` (the engine, compiled on first use). The developer guide covers client secrets, interactive sign-in and every other key.

# Part II · Everyday use

<!-- icon: play -->
## 3. Trace messages

Run the commands from that same folder, in PowerShell 7. `-Mode Trace` is the default: the tool collects from Microsoft Graph only what the database does not hold yet, then writes the report.

```powershell
# One sender, last 48 hours (Report.DefaultRange)
.\Invoke-MessageTraceReport.ps1 -Sender john@contoso.com

# Failed messages to a partner domain over 7 days, report opened at the end
.\Invoke-MessageTraceReport.ps1 -Recipient *@fabrikam.com -Status Failed -Range Last7Days -Open

# A list of VIPs (CSV, column detected) to Gmail in September
.\Invoke-MessageTraceReport.ps1 -SenderFile .\vip.csv -Recipient *@gmail.com -Start 2026-09-01 -End 2026-10-01

# From OR to these addresses, with the route of the failed deliveries
.\Invoke-MessageTraceReport.ps1 -Sender alerts@contoso.com -Recipient helpdesk@contoso.com -Operator Or -IncludeDetails

# A subject, a message ID, a source IP
.\Invoke-MessageTraceReport.ps1 -Subject 'Invoice' -SubjectMatch StartsWith -Range Today
.\Invoke-MessageTraceReport.ps1 -MessageId '<CAJ1234@mail.contoso.com>' -Range Last30Days
.\Invoke-MessageTraceReport.ps1 -FromIP 203.0.113.25 -Range Yesterday
```

![Trace in the console](images/console-trace.png)

| I want… | Parameter |
|---|---|
| A period | `-Range Last24Hours \| Last48Hours \| Last7Days \| Last10Days \| Last30Days \| Last90Days \| Today \| Yesterday` |
| One day, or my own dates | `-Date 2026-09-28`, or `-Start` / `-End` (`yyyy-MM-dd`, `'yyyy-MM-dd HH:mm'` in the report time zone, or ISO 8601 with an offset; `-End` defaults to now) |
| Senders, recipients | `-Sender`, `-Recipient`: exact addresses or `*@domain`, several values separated by commas |
| A list of addresses | `-SenderFile` / `-RecipientFile`: `.csv` (column `Email`, `PrimarySmtpAddress`, `Address`, `Mail`… or `-FileColumn`) or `.txt`, one per line |
| Sender **or** recipient, instead of both | `-Operator Or` |
| A subject | `-Subject 'Invoice'` with `-SubjectMatch Contains` (default), `StartsWith`, `EndsWith` or `Equals` |
| One status | `-Status Delivered \| Failed \| Pending \| Expanded \| Quarantined \| FilteredAsSpam \| GettingStatus` |
| One message, or an IP address | `-MessageId '<…>'`, `-FromIP`, `-ToIP` |
| Other files, another folder | `-Format Csv,Html,Json`, `-OutputPath D:\Out` |
| The messages in a grid, the report opened | `-GridView`, `-Open` |
| To read the whole period again | `-Refresh` |

Before collecting, the tool prints its **plan**: the filter, which list is sent to Graph and which is applied locally, what the database already holds, and the number of windows left to read. A plan above `Collection.MaxQueries` (2,000 requests) stops unless `-Force` is given. Running the same trace again only reads the last `Collection.SettlingHours` (4 h):

![The same trace again](images/console-rerun.png)

> [!TIP]
> A long investigation over many addresses can be interrupted with <kbd>Ctrl</kbd>+<kbd>C</kbd>: the pages already received are kept. Run the same command again to continue.

<!-- icon: search -->
## 4. Why a message was not delivered

The message trace gives the **status** of each recipient. `-IncludeDetails` also reads the **route** of the deliveries and names, for each recipient not delivered, the cause, the status code, the rule or the component that decided, and where its route left the route of the recipients who received the message.

```powershell
# One message: every recipient, grouped by identical route, in the console and the report
.\Invoke-MessageTraceReport.ps1 -MessageId '<CAJ1234@mail.contoso.com>' -Range Last10Days -IncludeDetails

# Failures of a sender over 7 days: up to 300 routes (default 100, Details.MaxDeliveries)
.\Invoke-MessageTraceReport.ps1 -Sender payroll@contoso.com -Range Last7Days -MaxRoutes 300 -Open
```

![The route of one message: a recipient blocked, the others delivered](images/console-route.png)

The causes are given in plain words — *Blocked by DLP*, *Blocked by mail flow rule (ETR)*, *Recipient not found*, *Mailbox full*, *Quarantined: spam or phishing*, *Rejected by remote server*… — with the status code and a link to its Microsoft Learn page. A selection of at most `Details.MaxDeliveries` deliveries (100) is read completely; a larger one reads the problems first, with one delivered recipient of the same message to compare. A route is read once and kept in the database.

The full list of causes and how each one is decided: [developer guide, chapter 9](MessageTraceReport-Guide.md#9-tracing-messages).

<!-- icon: calendar -->
## 5. Collect every day

`-Mode Collect` reads the last `Collect.Days` days of the whole tenant — or of the scope set in the `Collect` section — into the database: only what is missing and the last hours. Run every day, it keeps the history **beyond the 90 days of Graph**, and every trace of that period is then answered from the database.

```powershell
$action  = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument '-NoProfile -File "C:\Tools\MessageTraceReport\Invoke-MessageTraceReport.ps1" -Mode Collect' -WorkingDirectory 'C:\Tools\MessageTraceReport'
$trigger = New-ScheduledTaskTrigger -Daily -At 02:30
Register-ScheduledTask -TaskName 'Message Trace Report - Collect' -Action $action -Trigger $trigger -User 'CONTOSO\svc-mtr' -Password (Read-Host 'Password') -RunLevel Limited
```

The account of the task must hold the certificate (in its `Cert:\CurrentUser\My`, or `Cert:\LocalMachine\My` with read access to the private key). A first collection of 10 days is ten times longer than a daily one: run it once by hand with `Collect.Days = 10`.

<!-- icon: database -->
## 6. Report from the database, and the status

```powershell
# No connection, no quota - and any pattern is accepted in an address
.\Invoke-MessageTraceReport.ps1 -Mode Report -Range Last30Days -Sender 'sales-*@contoso.com'

# What the database holds, day by day, and the last runs
.\Invoke-MessageTraceReport.ps1 -Mode Status
```

`-Mode Report` never connects. When the database does not hold the whole period for this filter, the console and the report say how much it holds (*coverage*), and the exit code is `2`. `-Mode Status` shows the size of the database, the messages, the deliveries, the distinct queries, the collection day by day and the last runs.

<!-- icon: chart -->
## 7. Read the results

Each run writes a folder `reports\<yyyy-MM-dd_HHmmss>_<Mode>\`:

| File | One row per |
|---|---|
| `MessageTrace_Messages.csv` | message: received time, sender, recipients, recipient count, status, subject, size, Message ID, From IP, cause and reason of the worst recipient whose route was read |
| `MessageTrace_Deliveries.csv` | message **and** recipient: what Graph returns, then the route, the cause and the reason when the route was read |
| `MessageTrace_Routes.csv` | step of a route read: event, action, detail, status code, reason, component, remote server, facts |
| `MessageTrace_Senders.csv` · `_Recipients.csv` | sender · recipient, and per day: messages, delivered, failed, other, last message |
| `MessageTrace.html` | — the self-contained report |

CSV files are UTF-8 with BOM, `;` by default, and a cell starting with `=`, `+`, `-` or `@` is prefixed with `'` so that Excel never runs it as a formula. `-Format Json` also writes the data with the Graph property names.

The HTML report is one file that can be sent alone: tiles, delivery status, messages over time (failures in red), top 10 senders and recipients (click to filter), **why deliveries were not delivered** (one card per cause, then the status codes), and a table that stays fast with 200,000 messages — search, filters, sort, export of the view. Click a message to open its recipients and, when it was read, its route.

| Exit code | Meaning |
|---|---|
| `0` | Success. |
| `1` | Failure: configuration, filter, sign-in, permission, database. The summary gives the error. |
| `2` | Finished but incomplete: a window failed, the run was interrupted, or part of the period is not available. |

The daily log is `logs\MessageTraceReport_<yyyyMMdd>.log`: one line per event, the progress of a long collection every 60 seconds, and the Graph errors with their message.

# Part III · Troubleshoot

<!-- icon: lifebuoy -->
## 8. Common situations

| Symptom | Cause | What to do |
|---|---|---|
| `401 … Service principal-less authentication failed … 8bd644d1-…` | The *Transport Data Platform* service principal is missing, or not provisioned yet | Create it (developer guide, chapter 7, step 5), then wait — up to several hours. |
| `The application has no application permission ExchangeMessageTrace.Read.All` | Permission not added, or admin consent not granted | Add it and grant admin consent; a new consent can take a few minutes to reach the token. |
| `403 Permission denied` | Same as above, or the delegated account has no right on message trace | Check the permission and the role of the account. |
| `AADSTS700027` · `AADSTS7000222` · `AADSTS700024` | Certificate not on the application, or another thumbprint · the client secret has expired · the clock of the computer is wrong | Upload the right `.cer` · move to a certificate · fix the time of the computer. |
| `Certificate … not found` | Imported for another account, or without its private key (`.cer` instead of `.pfx`) | Import the certificate with its private key for the account that runs the tool. |
| Many `Throttled by Microsoft Graph (429)` | Another tool uses the quota of the tenant (100 requests per 5 minutes) | Nothing: the tool waits and goes on. Lower `Throttling.MaxRequests` if it happens often. |
| `request refused (400) - … older than 90 days` | The window starts before the Graph history | Nothing to collect there; use the database (`-Mode Report`) for older periods. |
| `The plan needs N requests` | More than `Collection.MaxQueries` | Narrow the filter or the period, or add `-Force`. |
| `Another execution is already collecting` | The scheduled collection is running on the same database | Wait, or use `-Mode Report`. |
| Coverage below 100% in `-Mode Report` | The database does not hold the whole period for this filter | Run the same command without `-Mode Report`. |
| *Routes: nothing new to read* | The routes of the selection are already in the database, or the selection holds only delivered messages beyond `MaxDeliveries` | Nothing: routes are read once. Set `Details.OnlyProblems` to `$false` to read the delivered ones too. |
| Few routes read on a large selection | `Details.MaxDeliveries` (100) or `-MaxRoutes` | Raise `-MaxRoutes`; the problems of the newest messages are read first. |
| The HTML page stays on *Loading* | Old browser without `DecompressionStream` | Use a recent Edge, Chrome or Firefox, or the CSV files. |

For the behaviour of the Graph API, the performance figures, every configuration key, the migration from `Invoke-MessageTraceGraph.ps1` and the internals, continue with the [developer guide](MessageTraceReport-Guide.md).
