<#
    Message Trace Report - console and log.

    What the administrator sees: title card, numbered steps, result lines, a live progress line during
    the collection, aligned tables and the final summary card. Every line written to the console is
    also written to the log file, without colours or icons.

    - Colours (ANSI) are disabled when the output is redirected (scheduled task, log capture) or when
      the NO_COLOR environment variable is set; MTR_FORCE_COLOR=1 forces them.
    - Icons: emoji in modern terminals (Windows Terminal, VS Code), simple symbols elsewhere. The emoji
      are chosen among those always two columns wide (no variation selector) so frames and columns stay
      aligned. The symbols used outside the modern terminals all exist in Consolas and Lucida Console
      (code page 437 or Latin-1 repertoire): the classic console has no font fallback.
      Force a style with the environment variable MTR_ICONS = Emoji | Symbols | Ascii.
    - Frames: rounded corners, square with the fonts that lack them (Lucida Console, raster font).
#>

$script:C = @{ Reset = ''; Bold = ''; Dim = ''; Accent = ''; AccentBg = ''; Cyan = ''; Green = ''; Yellow = ''; Red = ''; White = ''; Blue = '' }
if ($env:MTR_FORCE_COLOR -eq '1' -or (-not [Console]::IsOutputRedirected -and -not $env:NO_COLOR)) {
    $e = [char]27
    $script:C = @{
        Reset = "$e[0m"; Bold = "$e[1m"; Dim = "$e[90m"; White = "$e[97m"
        Accent = "$e[38;2;214;62;115m"; AccentBg = "$e[48;2;177;31;75m$e[97m"
        Cyan = "$e[38;2;97;214;214m"; Green = "$e[38;2;80;200;120m"; Yellow = "$e[38;2;240;200;90m"; Red = "$e[38;2;240;90;90m"
        Blue = "$e[38;2;110;170;255m"
    }
}
$script:IconStyle = if ($env:MTR_ICONS -in 'Emoji', 'Symbols', 'Ascii') { $env:MTR_ICONS }
    elseif ([Console]::IsOutputRedirected) { 'Symbols' }
    elseif ($env:WT_SESSION -or $env:TERM_PROGRAM -eq 'vscode') { 'Emoji' }
    else { 'Symbols' }

function Get-MtrIconSet {
    <# Icons of one console style. Symbols: only characters of the classic console fonts. #>
    param([Parameter(Mandatory)][ValidateSet('Emoji', 'Symbols', 'Ascii')][string]$Style)
    $u = { param([int]$Code) [char]::ConvertFromUtf32($Code) }
    switch ($Style) {
        'Emoji' { return @{
                Logo = & $u 0x1F4EE; Ok = & $u 0x2705; Warn = (& $u 0x26A0) + [char]0xFE0F; Fail = & $u 0x274C; Info = & $u 0x1F539; Skip = & $u 0x23E9
                Database = & $u 0x1F4BE; Plan = & $u 0x1F50E; Key = & $u 0x1F510; Download = & $u 0x1F4E5; Report = & $u 0x1F4CA; Calendar = & $u 0x1F4C5
                File = & $u 0x1F4C4; Folder = & $u 0x1F4C1; Clock = & $u 0x23F3; Mail = & $u 0x1F4E8; Target = & $u 0x1F3AF; Log = & $u 0x1F4DD
                Done = & $u 0x1F389; People = & $u 0x1F465; Chart = & $u 0x1F4C8; Filter = & $u 0x1F50D; Route = & $u 0x1F9ED; Broom = & $u 0x1F9F9
            } }
        'Symbols' { return @{
                Logo = & $u 0x2666; Ok = & $u 0x221A; Warn = & $u 0x25B2; Fail = & $u 0x00D7; Info = & $u 0x2022; Skip = & $u 0x00BB
                Database = & $u 0x25A0; Plan = & $u 0x25BA; Key = & $u 0x2194; Download = & $u 0x2193; Report = & $u 0x2261; Calendar = & $u 0x263C
                File = & $u 0x25AC; Folder = & $u 0x2302; Clock = & $u 0x25CB; Mail = '@'; Target = & $u 0x25D9; Log = & $u 0x00B6
                Done = & $u 0x221A; People = & $u 0x2192; Chart = & $u 0x2191; Filter = & $u 0x00F7; Route = & $u 0x00BB; Broom = & $u 0x00F7
            } }
        default { return @{
                Logo = '*'; Ok = '+'; Warn = '!'; Fail = 'x'; Info = '-'; Skip = '>'; Database = '#'; Plan = '?'; Key = '@'; Download = 'v'; Report = '='
                Calendar = ':'; File = '-'; Folder = '>'; Clock = '~'; Mail = '@'; Target = 'o'; Log = '='; Done = '*'; People = '&'; Chart = '^'
                Filter = '/'; Route = '>'; Broom = '/'
            } }
    }
}

function Get-MtrFrameSet {
    <# Frame characters: rounded corners, square with the console fonts that have none (Lucida Console, raster 'Terminal'). #>
    param([Parameter(Mandatory)][ValidateSet('Emoji', 'Symbols', 'Ascii')][string]$Style, [AllowNull()][string]$FontName)
    if ($Style -eq 'Ascii') { return @{ TopLeft = [char]'+'; TopRight = [char]'+'; BottomLeft = [char]'+'; BottomRight = [char]'+'; Horizontal = [char]'-'; Vertical = [char]'|' } }
    if ($Style -eq 'Symbols' -and $FontName -in 'Lucida Console', 'Terminal') {
        return @{ TopLeft = [char]0x250C; TopRight = [char]0x2510; BottomLeft = [char]0x2514; BottomRight = [char]0x2518; Horizontal = [char]0x2500; Vertical = [char]0x2502 }
    }
    return @{ TopLeft = [char]0x256D; TopRight = [char]0x256E; BottomLeft = [char]0x2570; BottomRight = [char]0x256F; Horizontal = [char]0x2500; Vertical = [char]0x2502 }
}

function Get-MtrFrame {
    <# Frame characters for this console. In the classic console the font is read once, through the engine. #>
    if ($script:Frame) { return $script:Frame }
    $engine = [bool]('MessageTraceReport.ConsoleFont' -as [type])
    $font = if ($script:IconStyle -eq 'Symbols' -and $engine) { [MessageTraceReport.ConsoleFont]::FaceName() }
    $frame = Get-MtrFrameSet $script:IconStyle $font
    # Before the engine is loaded (error at start) the font is unknown: not kept, read again later.
    if ($script:IconStyle -ne 'Symbols' -or $engine) { $script:Frame = $frame }
    return $frame
}

$script:Icons = Get-MtrIconSet $script:IconStyle
$script:Frame = $null
# Emoji are two columns wide in the console; symbols are one: pad symbols so text stays aligned.
$script:IconPad = if ($script:IconStyle -eq 'Emoji') { ' ' } else { '  ' }
$script:IconWidth = if ($script:IconStyle -eq 'Emoji') { 2 } else { 1 }
$script:LogWriter = $null
$script:LogPath = $null
$script:Dot = [char]0x00B7
$script:Arrow = [char]0x2192
$script:ProgressShown = $false

function Get-MtrIcon {
    param([Parameter(Mandatory)][string]$Name)
    $icon = $script:Icons[$Name]
    if (-not $icon) { $icon = $script:Icons['Info'] }
    return $icon + $script:IconPad
}

function Format-MtrNumber {
    param([Parameter(Mandatory)][AllowNull()]$Value)
    if ($null -eq $Value) { return '-' }
    return ([long]$Value).ToString('N0', [Globalization.CultureInfo]::GetCultureInfo('en-US'))
}

function Format-MtrDuration {
    param([Parameter(Mandatory)][double]$Seconds)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    # 0.0 (not 0): with an integer first argument PowerShell picks Math.Max(int, int) and drops the decimals.
    $t = [TimeSpan]::FromTicks([long]([Math]::Max(0.0, $Seconds) * 10000000))
    if ($t.TotalDays -ge 2) { return [string]::Format($inv, '{0} d {1:00} h', [int][Math]::Floor($t.TotalDays), $t.Hours) }
    if ($t.TotalHours -ge 1) { return [string]::Format($inv, '{0} h {1:00} min', [int][Math]::Floor($t.TotalHours), $t.Minutes) }
    if ($t.TotalMinutes -ge 1) { return [string]::Format($inv, '{0} min {1:00} s', $t.Minutes, $t.Seconds) }
    return [string]::Format($inv, '{0:0.0} s', $t.TotalSeconds)
}

function Format-MtrBytes {
    param([Parameter(Mandatory)][double]$Bytes)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($Bytes -ge 1GB) { return [string]::Format($inv, '{0:0.00} GB', $Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return [string]::Format($inv, '{0:0.0} MB', $Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return [string]::Format($inv, '{0:0} KB', $Bytes / 1KB) }
    return [string]::Format($inv, '{0:0} B', $Bytes)
}

function Format-MtrLocalTime {
    param([Parameter(Mandatory)][long]$UnixMs, [Parameter(Mandatory)][TimeZoneInfo]$Zone, [string]$Format = 'yyyy-MM-dd HH:mm')
    return [TimeZoneInfo]::ConvertTime([DateTimeOffset]::FromUnixTimeMilliseconds($UnixMs), $Zone).ToString($Format, [Globalization.CultureInfo]::InvariantCulture)
}

function Format-MtrRange {
    param([long]$StartMs, [long]$EndMs, [TimeZoneInfo]$Zone)
    return '{0} {2} {1}' -f (Format-MtrLocalTime $StartMs $Zone), (Format-MtrLocalTime $EndMs $Zone), $script:Arrow
}

function Format-MtrText {
    <# Shortens a text to a column width, with an ellipsis, and pads it. #>
    param([AllowNull()][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][int]$Width)
    if ($null -eq $Text) { $Text = '' }
    $Text = $Text -replace '[\r\n\t]+', ' '
    if ($Text.Length -le $Width) { return $Text.PadRight($Width) }
    if ($Width -le 3) { return $Text.Substring(0, $Width) }
    # '~' and not an ellipsis: the classic console fonts (Consolas, Lucida Console) have no '…'.
    return $Text.Substring(0, $Width - 1) + '~'
}

function Start-MtrLog {
    <# Opens (or continues) today's log file and deletes log files older than the retention. #>
    param([Parameter(Mandatory)][string]$Directory, [int]$RetentionDays = 30)
    [void][IO.Directory]::CreateDirectory($Directory)
    $script:LogPath = Join-Path $Directory ('MessageTraceReport_{0:yyyyMMdd}.log' -f (Get-Date))
    $stream = [IO.FileStream]::new($script:LogPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    $script:LogWriter = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
    $script:LogWriter.AutoFlush = $true
    if ($RetentionDays -gt 0) {
        $limit = (Get-Date).AddDays(-$RetentionDays)
        Get-ChildItem -LiteralPath $Directory -Filter 'MessageTraceReport_*.log' -File -ErrorAction SilentlyContinue |
            Where-Object LastWriteTime -lt $limit | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    return $script:LogPath
}

function Stop-MtrLog {
    if ($script:LogWriter) { $script:LogWriter.Dispose(); $script:LogWriter = $null }
}

function Write-MtrLog {
    <# Writes one line to the log file only (never to the console). #>
    param([ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'STEP', 'DEBUG')][string]$Level = 'INFO', [Parameter(Mandatory)][AllowEmptyString()][string]$Message)
    if ($script:LogWriter) {
        $script:LogWriter.WriteLine(('{0:yyyy-MM-ddTHH:mm:ss.fffzzz} [{1,-5}] {2}' -f (Get-Date), $Level, $Message))
    }
}

function Clear-MtrProgress {
    <# Ends the live progress line (if any) so that the next line starts on a new row. #>
    if ($script:ProgressShown) {
        [Console]::Write("`r" + (' ' * [Math]::Max(10, (Get-MtrConsoleWidth) - 1)) + "`r")
        $script:ProgressShown = $false
    }
}

function Get-MtrConsoleWidth {
    try { $w = [Console]::WindowWidth; if ($w -ge 40) { return $w } } catch { }
    return 120
}

function Write-MtrBanner {
    <#
    .SYNOPSIS
        Title card at the start of an execution:

          ╭──────────────────────────────────────────────────────────────────────────────╮
          │  📮  Message Trace Report                          v1.0.0 · Nicolas Fabert   │
          │     Exchange Online message trace · Microsoft Graph · SQLite history         │
          ╰──────────────────────────────────────────────────────────────────────────────╯
             🎯  Mode        Trace
    .PARAMETER Details
        Ordered list of rows: key = label, value = @(IconName, Text) or plain text.
    #>
    param([Parameter(Mandatory)][string]$Title, [string]$Subtitle, [System.Collections.Specialized.OrderedDictionary]$Details)
    $C = $script:C; $F = Get-MtrFrame; $width = 78
    $right = "v$($script:ToolVersion) $($script:Dot) $($script:ToolAuthor)"
    $left = "  $($script:Icons.Logo)  $Title"
    $leftWidth = $left.Length - $script:Icons.Logo.Length + $script:IconWidth
    $gap = [Math]::Max(1, $width - $leftWidth - $right.Length - 2)
    Write-Host ''
    Write-Host ("  {0}{1}{2}{3}{4}" -f $C.Accent, $F.TopLeft, [string]::new($F.Horizontal, $width), $F.TopRight, $C.Reset)
    Write-Host ("  {0}{1}{2}{3}{4}{5}{6}{7}{8}{9}{10}{11}" -f $C.Accent, $F.Vertical, $C.Reset, $C.Bold, $left, $C.Reset, [string]::new(' ', $gap), $C.Dim, $right, '  ', ($C.Accent + $F.Vertical), $C.Reset)
    if ($Subtitle) {
        $sub = "     $Subtitle"
        Write-Host ("  {0}{1}{2}{3}{4}{5}{0}{6}{2}" -f $C.Accent, $F.Vertical, $C.Reset, $C.Dim, (Format-MtrText $sub $width), $C.Reset, $F.Vertical)
    }
    Write-Host ("  {0}{1}{2}{3}{4}" -f $C.Accent, $F.BottomLeft, [string]::new($F.Horizontal, $width), $F.BottomRight, $C.Reset)
    if ($Details) {
        foreach ($key in $Details.Keys) {
            $value = $Details[$key]
            $icon, $text = if ($value -is [array]) { (Get-MtrIcon $value[0]), $value[1] } else { '   ', $value }
            Write-Host ("     {0}{1}{2,-11}{3} {4}" -f $icon, $C.Dim, $key, $C.Reset, $text)
        }
    }
    Write-MtrLog 'STEP' "=== $Title v$($script:ToolVersion) ==="
    if ($Details) { foreach ($key in $Details.Keys) { $v = $Details[$key]; Write-MtrLog 'INFO' ("{0}: {1}" -f $key, $(if ($v -is [array]) { $v[1] } else { $v })) } }
}

function Write-MtrStep {
    <# Step header with a coloured number pill and an icon:   2/4  🔐  Microsoft Graph sign-in #>
    param([Parameter(Mandatory)][int]$Number, [Parameter(Mandatory)][int]$Total, [Parameter(Mandatory)][string]$Title, [string]$Icon = 'Info')
    Clear-MtrProgress
    $C = $script:C
    Write-Host ''
    Write-Host ("  {0} {1}/{2} {3} {4}{5}{6}{3}" -f $C.AccentBg, $Number, $Total, $C.Reset, (Get-MtrIcon $Icon), $C.Bold, $Title)
    Write-MtrLog 'STEP' "[$Number/$Total] $Title"
}

function Write-MtrItem {
    <# One indented result line with a status icon, also written to the log. #>
    param([ValidateSet('Ok', 'Warn', 'Fail', 'Info', 'Skip')][string]$Status = 'Info', [Parameter(Mandatory)][AllowEmptyString()][string]$Text, [string]$Icon, [int]$Indent = 6)
    Clear-MtrProgress
    $color = @{ Ok = $script:C.Green; Warn = $script:C.Yellow; Fail = $script:C.Red; Info = ''; Skip = $script:C.Dim }[$Status]
    $level = @{ Ok = 'OK'; Warn = 'WARN'; Fail = 'ERROR'; Info = 'INFO'; Skip = 'INFO' }[$Status]
    $symbol = Get-MtrIcon $(if ($Icon) { $Icon } else { $Status })
    $textColor = if ($Status -in 'Warn', 'Fail', 'Skip') { $color } else { '' }
    Write-Host ("{0}{1}{2}{3}{4}{5}{3}" -f (' ' * $Indent), $color, $symbol, $script:C.Reset, $textColor, $Text)
    Write-MtrLog $level $Text
}

function Write-MtrProgress {
    <#
    .SYNOPSIS
        Live progress line, rewritten in place (interactive console) or written to the log only
        (redirected output). Example:

              ⏳  ███████░░░░░  58%  52/90 queries · 61 requests · 245,312 rows · quota 61/90 · ~3 min left
    #>
    param([Parameter(Mandatory)][double]$Fraction, [Parameter(Mandatory)][string]$Text)
    $C = $script:C
    $percent = [int][Math]::Floor(100 * [Math]::Min(1.0, [Math]::Max(0.0, $Fraction)))
    if ([Console]::IsOutputRedirected) { return }
    $filled = [int][Math]::Round(12 * $percent / 100.0)
    $bar = $C.Accent + [string]::new([char]0x2588, $filled) + $C.Dim + [string]::new([char]0x2591, 12 - $filled) + $C.Reset
    $width = Get-MtrConsoleWidth
    $plain = Format-MtrText $Text ([Math]::Max(10, $width - 30))
    [Console]::Write(("`r      {0}{1} {2,3}%  {3}{4}{5}" -f (Get-MtrIcon 'Clock'), $bar, $percent, $C.Dim, $plain.TrimEnd(), $C.Reset))
    $script:ProgressShown = $true
}

function Write-MtrTable {
    <#
    .SYNOPSIS
        Aligned table, one row per object, with a status icon in front of each row.
    .PARAMETER Columns
        Array of @{ Name = 'Header'; Property = 'PropertyName'; Width = 20; Align = 'Right' }. Width 0 = the rest of the console.
    .PARAMETER StatusProperty
        Property holding Ok | Warn | Fail | Info | Skip (colour of the row).
    #>
    param(
        [Parameter(Mandatory)][object[]]$Columns,
        [AllowEmptyCollection()][AllowNull()][object[]]$Rows,
        [string]$StatusProperty = 'Status',
        [int]$Indent = 6,
        [int]$MaxWidth = 160
    )
    Clear-MtrProgress
    $C = $script:C
    if (-not $Rows -or -not $Rows.Count) { return }
    $consoleWidth = [Math]::Min($MaxWidth, (Get-MtrConsoleWidth) - 1)
    if ($consoleWidth -lt 80) { $consoleWidth = 120 }
    $fixed = [int](($Columns | ForEach-Object { [int]$_.Width } | Measure-Object -Sum).Sum) + 2 * $Columns.Count
    $last = [Math]::Max(20, $consoleWidth - $Indent - 3 - $fixed)
    $pad = ' ' * $Indent
    $widthOf = { param($col) if ([int]$col.Width) { [int]$col.Width } else { $last } }
    $cell = {
        param($col, $text)
        $w = & $widthOf $col
        # Raw: the text already holds colours (ANSI): padded on its visible length, never cut.
        if ($col.Raw) { $visible = ($text -replace "$([char]27)\[[0-9;]*m", '').Length; return $text + (' ' * [Math]::Max(0, $w - $visible)) }
        if ($col.Align -eq 'Right') { (Format-MtrText $text $w).Trim().PadLeft($w) } else { Format-MtrText $text $w }
    }
    $header = ($Columns | ForEach-Object { if ($_.Raw) { Format-MtrText $_.Name ([int]$_.Width) } else { & $cell $_ $_.Name } }) -join '  '
    Write-Host ("{0}{1}{2}{3}{4}" -f $pad, $C.Dim, (' ' * ($script:IconWidth + $script:IconPad.Length)), $header.TrimEnd(), $C.Reset)
    foreach ($row in $Rows) {
        $status = [string]$row.$StatusProperty
        if ($status -notin 'Ok', 'Warn', 'Fail', 'Info', 'Skip') { $status = 'Info' }
        $color = @{ Ok = $C.Green; Warn = $C.Yellow; Fail = $C.Red; Info = $C.Blue; Skip = $C.Dim }[$status]
        $cells = foreach ($col in $Columns) { & $cell $col ([string]$row.($col.Property)) }
        $textColor = if ($status -eq 'Skip') { $C.Dim } else { '' }
        Write-Host ("{0}{1}{2}{3}{4}{5}{3}" -f $pad, $color, (Get-MtrIcon $status), $C.Reset, $textColor, (($cells -join '  ').TrimEnd()))
        $logLevel = @{ Ok = 'OK'; Warn = 'WARN'; Fail = 'ERROR'; Info = 'INFO'; Skip = 'INFO' }[$status]
        Write-MtrLog $logLevel (($Columns | ForEach-Object { "$($_.Name)=$(([string]$row.($_.Property)) -replace "$([char]27)\[[0-9;]*m", '')" }) -join ' | ')
    }
}

function Write-MtrSummary {
    <#
    .SYNOPSIS
        Final summary card:

          ╭─ 🎉  Report ready ───────────────────────────────────────────────────────────╮
            ✉️  Messages    1,204 messages · 3,877 deliveries
          ╰──────────────────────────────────────────────────────────────────────────────╯
    .PARAMETER Values
        Ordered list: key = label, value = @(IconName, Text) or plain text.
    #>
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Values, [ValidateSet('Ok', 'Warn', 'Fail')][string]$Status = 'Ok')
    Clear-MtrProgress
    $C = $script:C; $F = Get-MtrFrame; $width = 78
    $color = @{ Ok = $C.Green; Warn = $C.Yellow; Fail = $C.Red }[$Status]
    $icon = $script:Icons[@{ Ok = 'Done'; Warn = 'Warn'; Fail = 'Fail' }[$Status]]
    $iconWidth = if ($Status -eq 'Warn' -and $script:IconStyle -eq 'Emoji') { 2 } else { $script:IconWidth }
    $head = " $icon  $Title "
    $rest = [Math]::Max(2, $width - 1 - ($head.Length - $icon.Length + $iconWidth))
    Write-Host ''
    Write-Host ("  {0}{1}{2}{3}{4}{0}{5}{6}{7}" -f $color, $F.TopLeft, $F.Horizontal, $C.Bold, $head, ($C.Reset + $color), ([string]::new($F.Horizontal, $rest) + $F.TopRight), $C.Reset)
    foreach ($key in $Values.Keys) {
        $value = $Values[$key]
        $rowIcon, $text = if ($value -is [array]) { (Get-MtrIcon $value[0]), $value[1] } else { '   ', $value }
        Write-Host ("    {0}{1}{2,-11}{3} {4}" -f $rowIcon, $C.Dim, $key, $C.Reset, $text)
        Write-MtrLog 'INFO' ("Summary - {0}: {1}" -f $key, $text)
    }
    Write-Host ("  {0}{1}{2}{3}{4}" -f $color, $F.BottomLeft, [string]::new($F.Horizontal, $width), $F.BottomRight, $C.Reset)
    Write-Host ''
}
