# Changelog

All notable changes of Message Trace Report. Versions follow [semantic versioning](https://semver.org/).

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
