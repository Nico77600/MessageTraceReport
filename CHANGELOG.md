# Changelog

All notable changes of Message Trace Report. Versions follow [semantic versioning](https://semver.org/).

## 1.1.0 — 2026-10-02

Why a message was not delivered — for each recipient.

### Added

- **Cause of each failure**, in plain words: *Blocked by DLP*, *Blocked by mail flow rule (ETR)*, *Blocked by organization policy*, *Blocked by Tenant Allow/Block List*, *Recipient not found*, *Mailbox full*, *Sender not allowed by recipient*, *Sender authentication failed*, *Quarantined*, *Junk Email folder*, *Destination server unreachable*, *Rejected by remote server*… (about 30), with the **DLP or mail flow rule** (name, or ID when the names are empty) and what to check. Decided from the component that rejected, the rule steps of the route, the codes reserved for mail flow rules (5.7.900–5.7.999), the enhanced status code and the answer of the remote server.
- **Route analysis** (`src\Engine.Route.cs`): steps in order (events of the same second come back unordered from the service), facts of the XML data with readable labels (server, connector, TLS, SCL / SFV…), reason with SMTP and enhanced code, text, diagnostic, remote server, component and its Microsoft Learn page.
- **Where the routes split**: the recipients of a message are grouped by identical route (*Route A*, *Route B*…); when some failed and others were delivered, the common steps and what happened next, side by side — in the HTML report and in the console.
- **Smarter route selection**: a selection of at most `Details.MaxDeliveries` (now 100) is read completely; a larger one reads, newest message first, one recipient per problem status and **one delivered recipient of the same message to compare** (`Details.CompareWithDelivered`), then the other problems. Routes are read once and reused. `-MaxRoutes` changes the number for one run.
- **Console**: the route of the messages of a small selection (`Details.ConsoleMessages`, 3), the causes and status codes of the run, a *Causes* line in the summary.
- **HTML report**: *Why deliveries were not delivered* (one card per cause, then the status codes with their Learn page, click to filter), a **Cause** column, filters by cause, *any recipient not delivered*, *partly delivered* and *route read*, search in the reasons, a new message dialog (routes, split, cause box, steps with times and details).
- **Files**: `MessageTrace_Routes.csv` (one row per step, `Report.Files` `Routes`); `Cause` and `Reason` columns at the end of the Messages and Deliveries CSV (and `Route` for Deliveries); `route`, `outcome`, `causeId`, `cause`, `reason` and `events` in the JSON files.

### Changed

- `Details.MaxDeliveries` 50 → 100; new keys `CompareWithDelivered` and `ConsoleMessages`.
- The demonstration data and the in-memory API of the tests return the real shape of the routes (DLP, mail flow rule, restrictions, remote rejection, delay, quarantine, junk, group expansion). 59 Pester tests.

## 1.0.0 — 2026-10-02

First version, replacing `Invoke-MessageTraceGraph.ps1`.

### Added

- One entry point, `Invoke-MessageTraceReport.ps1`, with four modes: **Trace** (default: collects what the database lacks, then writes the report), **Collect** (scheduled, whole tenant or a scope), **Report** (database only, any address pattern) and **Status**.
- Microsoft Graph **v1.0** message trace API (`/admin/exchange/tracing/messageTraces`) and `getDetailsByRecipient` (route of the failed deliveries, `-IncludeDetails`).
- **Query planner** built on the measured behaviour of the API (one value per property in `$filter`, `or` ignored): one query per address of the shorter list for senders AND recipients, per address for OR, single values added to every query, the full filter applied on the database. `*@domain`, subject (`Contains`, `StartsWith`, `EndsWith`, `Equals`), status, message ID, source and destination IP.
- **SQLite history** (bundled, nothing to install): one row per message, one per delivery, updated when the status changes; coverage per query so that a period already collected by the same or a wider query is not asked again; settling hours read again; retention.
- **Quota**: one rolling budget shared by the workers (90 requests per 5 minutes by default), `Retry-After` honoured with a global pause, requests of the last window remembered by the next run, live progress line with the quota and the time left.
- **Restartable**: every page stored at once, coverage extended page by page; Ctrl+C keeps what was received.
- Authentication: **certificate** (client assertion built by the tool, no module), client secret from an environment variable or a hidden prompt, interactive (MSAL). The token is checked for the tenant and the permission before the first request.
- Reports: `Messages`, `Deliveries`, `Senders`, `Recipients` CSV (parts above `MaxRowsPerFile`, Excel formula protection), optional JSON with the Graph property names, self-contained HTML report (tiles, status, timeline, top 10, search and filters for 200,000 messages, recipients and route of each message), `-GridView`, `-Open`.
- Aliases of the original parameters (`-StartDate`, `-EndDate`, `-Senders`, `-Recipients`, `-SendersCsv`, `-RecipientsCsv`, `-CsvEmailColumn`).
- Administrator guide (Markdown and HTML), visual README, 49 Pester tests with an in-memory message trace API, demonstration report.

### Fixed (compared with Invoke-MessageTraceGraph.ps1)

- Several recipients in AND mode, or several values with `-OperatorOr`, returned only the last value (Graph ignores `or`).
- One query per address and per day, and a fixed 9-second pause before every request: replaced by 10-day windows and a shared rolling budget.
- A network error lost the rest of a query; there is now a retry policy and a resume.
- Every row was kept in memory (`+=` on arrays, `Sort-Object -Unique`): rows are now streamed to SQLite and to the files.
- The beta endpoint, a client secret on the command line, a period limited to 10 days.
