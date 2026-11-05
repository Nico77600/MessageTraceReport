# Changelog

All notable changes of Message Trace Report. Versions follow [semantic versioning](https://semver.org/).

## 1.1.1 — 2026-11-05

### Added

- The PowerShell files of the release carry the owner's timestamped signature, and a signed list of the other files is checked at every start.
- The user guide explains how to check the download.
- `-DevelopmentMode` starts a copy of the tool that has no signed list, for developers and CI.

### Changed

- **The tool refuses to start when its folder holds a file it does not know.** Keep address lists, certificates and copies of the configuration outside the tool folder, for example in `C:\Tools\MessageTraceReport-data\`, and give `Collect.SenderFile` and `Collect.RecipientFile` as absolute paths.
- The C# engine is compiled in memory at every start (a few seconds); the `bin\` folder is unused and can be deleted.
- The release ZIP holds one folder, `MessageTraceReport-1.1.1`, and its README links only files that are in the ZIP, including the HTML user guide.
- The user guide (everyday use) and the developer guide (internals) are separate; Get started begins from the ZIP of the Releases page, with the expected result and what to do if not at each step, and explains the app registration, the permission, the admin consent and the Microsoft message trace service.
- Run-time files live in the `package` folder of the repository; the source archive leaves out the tests and tools.

## 1.1.0 — 2026-10-02

Why a message was not delivered, for each recipient.

### Added

- **Cause of each failure** in plain words (*Blocked by DLP*, *Blocked by mail flow rule (ETR)*, *Recipient not found*, *Mailbox full*, *Quarantined*, *Rejected by remote server* and about 25 more), with the DLP or mail flow rule and what to check.
- **Route of each recipient**: the steps in order, with readable details, the reason with its status code and a link to its Microsoft Learn page.
- **Where the routes split**: recipients with the same route are grouped, and when some failed while others were delivered, the common steps and what happened next are shown side by side.
- **Smarter route reading** for large selections: the newest problems first, with one delivered recipient of the same message to compare.
- **Console**: the route of the messages of a small selection, the causes of the run and a *Causes* line in the summary.
- **HTML report**: a *Why deliveries were not delivered* section, a Cause column, filters by cause, and a message window with the route.
- **Files**: `MessageTrace_Routes.csv`, and Cause and Reason columns at the end of the Messages and Deliveries files.

### Changed

- `Details.MaxDeliveries` is 100 (was 50); `CompareWithDelivered` and `ConsoleMessages` are new configuration keys.

## 1.0.0 — 2026-10-02

First version, replacing `Invoke-MessageTraceGraph.ps1`.

### Added

- One entry point, `Invoke-MessageTraceReport.ps1`, with four modes: **Trace** (default), **Collect** (scheduled), **Report** (database only) and **Status**.
- Message trace through Microsoft Graph, planned around the limits of the service, for senders, recipients, `*@domain`, subject, status, message ID and IP addresses.
- **Local history** in a bundled SQLite database: a period already collected is not asked again, and a collection can be stopped and resumed.
- **Request quota** shared by all workers, with the live progress and time left.
- Sign-in with a **certificate**, a client secret or an interactive account; the tenant and the permission are checked before the first request.
- Reports: CSV files, optional JSON and a self-contained HTML report, with `-GridView` and `-Open`.
- Parameter names of the original script are kept as aliases.
- Administrator guide (Markdown and HTML), visual README and a demonstration report.
