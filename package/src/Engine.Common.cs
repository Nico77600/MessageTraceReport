// =============================================================================
//  Message Trace Report - engine, part 1: common types
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 1.1.0
//
//  The engine (src\Engine.*.cs) is compiled by the module the first time it is
//  used, and again only when a source file changes (bin\MessageTraceReport.Engine.<hash>.dll).
//
//    Engine.Common.cs   time ranges, addresses, text helpers, console font
//    Engine.Plan.cs     user filter -> Microsoft Graph queries and time windows
//    Engine.Graph.cs    rate limiter, token, HTTP workers (collection)
//    Engine.Store.cs    SQLite database
//    Engine.Report.cs   CSV, JSON and HTML files
//
//  Conventions
//    - Every time is a Unix epoch in MILLISECONDS (UTC).
//    - Time ranges are [start, end): start included, end excluded.
//    - Addresses are compared without case (OrdinalIgnoreCase), as Exchange does.
// =============================================================================
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.RegularExpressions;

namespace MessageTraceReport
{
    /// <summary>
    /// Font of the classic Windows console (conhost). The console has no font fallback, so the
    /// module chooses the frame characters from it. Null when the output is not a classic console.
    /// </summary>
    public static class ConsoleFont
    {
        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        struct ConsoleFontInfoEx
        {
            public uint Size; public uint Font; public short Width; public short Height; public int Family; public int Weight;
            [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.ByValTStr, SizeConst = 32)] public string FaceName;
        }

        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr GetStdHandle(int handle);

        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetCurrentConsoleFontEx(IntPtr output, bool maximumWindow, ref ConsoleFontInfoEx info);

        public static string FaceName()
        {
            try
            {
                if (Console.IsOutputRedirected || !OperatingSystem.IsWindows()) return null;
                var info = new ConsoleFontInfoEx { Size = (uint)System.Runtime.InteropServices.Marshal.SizeOf<ConsoleFontInfoEx>() };
                return GetCurrentConsoleFontEx(GetStdHandle(-11), false, ref info) ? info.FaceName : null;
            }
            catch { return null; }
        }
    }

    // -------------------------------------------------------------------------
    // Time ranges
    // -------------------------------------------------------------------------

    public struct TimeRange
    {
        public long Start;   // Unix ms, included
        public long End;     // Unix ms, excluded
        public TimeRange(long start, long end) { Start = start; End = end; }
        public long Length { get { return End - Start; } }
        public override string ToString()
        {
            return Time.Iso(Start) + " -> " + Time.Iso(End);
        }
    }

    public static class Coverage
    {
        /// <summary>Merges overlapping or adjacent ranges.</summary>
        public static List<TimeRange> Merge(IEnumerable<TimeRange> ranges)
        {
            var result = new List<TimeRange>();
            foreach (TimeRange r in ranges.Where(x => x.End > x.Start).OrderBy(x => x.Start))
            {
                if (result.Count > 0 && r.Start <= result[result.Count - 1].End)
                {
                    TimeRange last = result[result.Count - 1];
                    if (r.End > last.End) result[result.Count - 1] = new TimeRange(last.Start, r.End);
                }
                else result.Add(r);
            }
            return result;
        }

        /// <summary>Parts of [start, end) NOT covered by the given ranges.</summary>
        public static List<TimeRange> Gaps(IEnumerable<TimeRange> covered, long start, long end)
        {
            var gaps = new List<TimeRange>();
            if (end <= start) return gaps;
            long cursor = start;
            foreach (TimeRange r in Merge(covered))
            {
                if (r.End <= cursor) continue;
                if (r.Start >= end) break;
                if (r.Start > cursor) gaps.Add(new TimeRange(cursor, Math.Min(r.Start, end)));
                cursor = Math.Max(cursor, r.End);
                if (cursor >= end) break;
            }
            if (cursor < end) gaps.Add(new TimeRange(cursor, end));
            return gaps;
        }

        /// <summary>Total length of the ranges, in milliseconds (overlaps counted once).</summary>
        public static long Length(IEnumerable<TimeRange> ranges)
        {
            long sum = 0;
            foreach (TimeRange r in Merge(ranges)) sum += r.Length;
            return sum;
        }

        /// <summary>
        /// Cuts ranges into windows of at most maxMs, the newest first. The Graph API returns the newest
        /// messages first: collecting the newest windows first gives the most useful data early.
        /// </summary>
        public static List<TimeRange> Split(IEnumerable<TimeRange> ranges, long maxMs)
        {
            var windows = new List<TimeRange>();
            maxMs = Math.Max(1000, maxMs);
            foreach (TimeRange range in Merge(ranges))
            {
                long cursor = range.End;
                while (cursor > range.Start)
                {
                    long start = Math.Max(range.Start, cursor - maxMs);
                    windows.Add(new TimeRange(start, cursor));
                    cursor = start;
                }
            }
            return windows.OrderByDescending(w => w.End).ToList();
        }
    }

    public static class Time
    {
        public static long NowMs() { return DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(); }

        public static string Iso(long unixMs)
        {
            return DateTimeOffset.FromUnixTimeMilliseconds(unixMs).UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", CultureInfo.InvariantCulture);
        }

        /// <summary>Graph filter value, whole seconds. floor for a start, ceiling for an end: the query never misses a message.</summary>
        public static string GraphTime(long unixMs, bool ceiling)
        {
            long s = unixMs / 1000;
            if (ceiling && unixMs % 1000 != 0) s++;
            return DateTimeOffset.FromUnixTimeSeconds(s).UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture);
        }

        public static bool TryParse(string text, out long unixMs)
        {
            unixMs = 0;
            if (string.IsNullOrEmpty(text)) return false;
            DateTimeOffset value;
            if (!DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out value)) return false;
            unixMs = value.ToUnixTimeMilliseconds();
            return true;
        }

        public static long LocalToUnixMs(DateTime local, TimeZoneInfo zone)
        {
            DateTime unspecified = DateTime.SpecifyKind(local, DateTimeKind.Unspecified);
            // A local time can be invalid (spring DST gap) in a few zones: move forward until valid.
            while (zone.IsInvalidTime(unspecified)) unspecified = unspecified.AddMinutes(30);
            TimeSpan offset = zone.IsAmbiguousTime(unspecified) ? zone.GetAmbiguousTimeOffsets(unspecified).Max() : zone.GetUtcOffset(unspecified);
            return new DateTimeOffset(unspecified, offset).ToUnixTimeMilliseconds();
        }

        public static DateTime ToLocal(long unixMs, TimeZoneInfo zone)
        {
            return TimeZoneInfo.ConvertTime(DateTimeOffset.FromUnixTimeMilliseconds(unixMs), zone).DateTime;
        }

        public static string FormatLocal(long unixMs, TimeZoneInfo zone)
        {
            return ToLocal(unixMs, zone).ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);
        }

        public static string LocalDay(long unixMs, TimeZoneInfo zone)
        {
            return ToLocal(unixMs, zone).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        }
    }

    // -------------------------------------------------------------------------
    // Addresses
    // -------------------------------------------------------------------------

    public static class Address
    {
        // Pragmatic SMTP address check: what Exchange Online accepts as a recipient or sender filter. '*' is
        // always read as a wildcard (Graph returns nothing for an address with * other than '*@domain').
        static readonly Regex Smtp = new Regex(@"^[^@\s'""<>(),;:\\\[\]*]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}[A-Za-z0-9])?)+$", RegexOptions.CultureInvariant);
        static readonly Regex Domain = new Regex(@"^\*@[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}[A-Za-z0-9])?)+$", RegexOptions.CultureInvariant);

        /// <summary>Trimmed, lower case, without the "smtp:" prefix or angle brackets.</summary>
        public static string Normalize(string value)
        {
            if (value == null) return "";
            string v = value.Trim().Trim('<', '>', '"', '\'').Trim();
            if (v.StartsWith("smtp:", StringComparison.OrdinalIgnoreCase)) v = v.Substring(5);
            return v.ToLowerInvariant();
        }

        public static bool IsAddress(string value) { return !string.IsNullOrEmpty(value) && Smtp.IsMatch(value); }

        /// <summary>*@contoso.com - the only wildcard the Graph API applies on the server.</summary>
        public static bool IsDomainWildcard(string value) { return !string.IsNullOrEmpty(value) && Domain.IsMatch(value); }

        /// <summary>Any other pattern with * (local filter only, -Mode Report).</summary>
        public static bool IsPattern(string value) { return !string.IsNullOrEmpty(value) && value.IndexOf('*') >= 0; }

        /// <summary>Case-insensitive match of an address against an address or a pattern with *.</summary>
        public static bool Matches(string address, string filter)
        {
            if (address == null) address = "";
            if (!IsPattern(filter)) return string.Equals(address, filter, StringComparison.OrdinalIgnoreCase);
            string regex = "^" + Regex.Escape(filter).Replace("\\*", ".*") + "$";
            return Regex.IsMatch(address, regex, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        }

        /// <summary>SQL LIKE pattern of a filter with * (escape character \).</summary>
        public static string ToLike(string filter)
        {
            return filter.Replace("\\", "\\\\").Replace("%", "\\%").Replace("_", "\\_").Replace('*', '%');
        }
    }

    // -------------------------------------------------------------------------
    // Text
    // -------------------------------------------------------------------------

    public static class Text
    {
        /// <summary>
        /// CSV cell for Excel: quoted when needed. Text starting with = + - @ (or a control character)
        /// is prefixed with an apostrophe so Excel never evaluates it as a formula.
        /// </summary>
        public static string SafeCsv(string value, string delimiter)
        {
            if (string.IsNullOrEmpty(value)) return "";
            string v = value;
            char first = v[0];
            if (first == '=' || first == '+' || first == '-' || first == '@' || first == '\t' || first == '\r') v = "'" + v;
            bool quote = v.Contains(delimiter) || v.IndexOf('"') >= 0 || v.IndexOf('\n') >= 0 || v.IndexOf('\r') >= 0;
            return quote ? "\"" + v.Replace("\"", "\"\"") + "\"" : v;
        }

        /// <summary>OData string literal: single quotes doubled.</summary>
        public static string ODataString(string value) { return "'" + (value ?? "").Replace("'", "''") + "'"; }

        /// <summary>Encodes what would break a URL query string, keeps the filter readable in the log.</summary>
        public static string EncodeQuery(string value)
        {
            return Uri.EscapeDataString(value ?? "");
        }

        public static string Shorten(string value, int max)
        {
            if (value == null) return "";
            return value.Length <= max ? value : value.Substring(0, Math.Max(0, max - 3)) + "...";
        }
    }
}
