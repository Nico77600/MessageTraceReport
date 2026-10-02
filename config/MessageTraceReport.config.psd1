#
#  Message Trace Report - configuration file
#  --------------------------------------------------------------------------
#  Author  : Nicolas Fabert
#  Version : 1.0.0
#
#  Read by Invoke-MessageTraceReport.ps1. It is a PowerShell data file: text between quotes,
#  $true / $false, numbers, @( ) for lists and @{ } for groups of settings. Lines starting with #
#  are comments. Relative paths (.\data, .\reports) are relative to the tool folder.
#
#  The guide (docs\MessageTraceReport-Guide.md, chapter 6) explains every setting.
#
@{
    # ---------------------------------------------------------------------
    # Tenant. Safety check: the tool stops if the token belongs to another tenant.
    # ---------------------------------------------------------------------
    Tenant = @{
        TenantId     = ''      # Microsoft Entra tenant ID (GUID)
        Organization = ''      # optional, shown in the console and the report (contoso.onmicrosoft.com)
    }

    # ---------------------------------------------------------------------
    # Authentication to Microsoft Graph. Permission: ExchangeMessageTrace.Read.All.
    #   Certificate  : app-only, recommended (scheduled task). Application permission + admin consent.
    #   ClientSecret : app-only with a secret read from the environment variable ClientSecretVariable,
    #                  or typed at the prompt (hidden). The secret is never written anywhere.
    #   Interactive  : an administrator signs in (browser, MFA). Delegated permission. Needs the
    #                  Microsoft.Graph.Authentication module (MSAL).
    # The tenant must hold the service principal of the Microsoft application 8bd644d1-64a1-4d4b-ae52-2e0cbf64e373
    # (guide, chapter 4).
    # ---------------------------------------------------------------------
    Authentication = @{
        Mode                  = 'Certificate'
        AppId                 = ''                    # application (client) ID; Interactive: '' = Microsoft Graph Command Line Tools
        CertificateThumbprint = ''                    # Certificate: in Cert:\CurrentUser\My or Cert:\LocalMachine\My
        ClientSecretVariable  = 'MTR_CLIENT_SECRET'   # ClientSecret: name of the environment variable
        UserPrincipalName     = ''                    # Interactive: expected account ('' = any account of the tenant)
    }

    # ---------------------------------------------------------------------
    # Requests to Microsoft Graph.
    # ---------------------------------------------------------------------
    Collection = @{
        PageSize              = 5000   # rows per request (1-5000): 5000 = fewest requests
        MaxConcurrency        = 3      # requests in flight. 2-3 use the whole quota; more does not go faster
        WindowHours           = 240    # length of one query window (Graph maximum: 240 hours = 10 days)
        BroadWindowHours      = 24     # window of a query without address (whole tenant, subject only ...): read in parallel
        SettlingHours         = 4      # the last N hours are collected again by the next run (status changes, late rows)
        MaxQueries            = 2000   # safety: a plan above this number of requests stops (-Force to run it)
        RequestTimeoutSeconds = 180
        MaxRetries            = 5      # per request, for 5xx / timeouts / network errors (429 waits are separate)
        SourceHistoryDays     = 90     # Graph keeps 90 days
    }

    # ---------------------------------------------------------------------
    # Quota of the message trace API: 100 requests per 5 minutes for the WHOLE tenant (rolling window).
    # Keep a margin for the other tools and administrators. The route API (getDetailsByRecipient)
    # has its own quota of the same size.
    # ---------------------------------------------------------------------
    Throttling = @{
        MaxRequests   = 90
        PeriodSeconds = 300
    }

    # ---------------------------------------------------------------------
    # Route of the deliveries (Receive, Deliver, Fail ... events), shown in the HTML report.
    # One request per delivery: keep MaxDeliveries small. -IncludeDetails enables it for one run.
    # ---------------------------------------------------------------------
    Details = @{
        Enabled       = $false
        MaxDeliveries = 50
        OnlyProblems  = $true    # only deliveries not delivered (failed, pending, quarantined ...)
    }

    # ---------------------------------------------------------------------
    # -Mode Collect (scheduled task). Every run checks the last Days days and reads only what the
    # database lacks (plus the last SettlingHours). Empty lists = the whole tenant.
    # A scope (addresses or *@domain) costs one request per address and per 10 days.
    # ---------------------------------------------------------------------
    Collect = @{
        Days          = 2
        Senders       = @()
        Recipients    = @()
        SenderFile    = ''
        RecipientFile = ''
        Operator      = 'Or'     # Or: messages from the senders OR to the recipients
    }

    # ---------------------------------------------------------------------
    # Local database (SQLite, bundled in lib\sqlite). About 60 bytes per delivery, messages included:
    # 1.7 GB per month for one million deliveries a day (guide, chapter 4).
    # ---------------------------------------------------------------------
    Storage = @{
        DatabasePath  = '.\data\MessageTraceReport.sqlite'
        RetentionDays = 180      # messages older than this are deleted by -Mode Collect (0 = keep everything)
    }

    # ---------------------------------------------------------------------
    # Report files, written locally only (one sub-folder per run).
    # ---------------------------------------------------------------------
    Report = @{
        DefaultRange             = 'Last48Hours'   # Last24Hours | Last48Hours | Last7Days | Last10Days | Last30Days | Last90Days | Today | Yesterday
        TimeZone                 = 'Europe/Paris'  # dates and days of the report
        OutputPath               = '.\reports'
        FilePrefix               = 'MessageTrace'
        Formats                  = @('Csv', 'Html')   # Csv, Html, Json
        Files                    = @('Messages', 'Deliveries', 'Senders', 'Recipients')
        CountsPerDay             = $true           # Senders / Recipients counted per day when the period is longer than one day
        CsvDelimiter             = ';'             # ';' opens directly in Excel with French regional settings
        MaxRowsPerFile           = 1000000         # a CSV file above this is continued in _part2, _part3 (Excel: 1,048,575 at most)
        HtmlMaxMessages          = 200000          # the HTML table keeps the newest messages; totals and charts count all of them
        HtmlRecipientsPerMessage = 100             # recipients listed per message in the HTML (all of them in the CSV)
        Title                    = 'Exchange Online message trace'
        OpenReport               = $false          # open the HTML report at the end (interactive runs)
    }

    # ---------------------------------------------------------------------
    # Log files (one per day, deleted after RetentionDays).
    # ---------------------------------------------------------------------
    Logging = @{
        Path          = '.\logs'
        RetentionDays = 30
    }
}
