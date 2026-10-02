// =============================================================================
//  Message Trace Report - engine, part 5: report files
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 1.1.0
//
//  One pass over the selection (newest message first, the deliveries of a message
//  consecutive) writes every file at once:
//    <prefix>_Messages.csv     one row per message (recipients, status summary)
//    <prefix>_Deliveries.csv   one row per message and recipient (what Graph returns)
//    <prefix>_Senders.csv      per sender (and per day): messages, recipients, delivered, failed
//    <prefix>_Recipients.csv   per recipient (and per day)
//    <prefix>_Messages.json / _Deliveries.json (optional, Graph property names)
//    <prefix>.html             self-contained report: tiles, charts, searchable table, recipients
//                              and route of each message
//  CSV files are cut at MaxRowsPerFile rows (_part2, _part3 ...). Counters, top lists and the
//  timeline are computed on ALL the rows, even when the HTML table keeps only the newest messages.
// =============================================================================
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace MessageTraceReport
{
    public sealed class ReportRequest
    {
        public string OutputDirectory, FilePrefix = "MessageTrace", CsvDelimiter = ";", Title = "Exchange Online message trace";
        public string TimeZoneLabel = "UTC", ToolVersion = "", Tenant = "", RangeName = "", TemplatePath;
        public TimeZoneInfo Zone = TimeZoneInfo.Utc;
        public long StartMs, EndMs;
        public bool Csv = true, Json, Html = true;
        public bool Messages = true, Deliveries = true, Senders = true, Recipients = true;
        public bool CountsPerDay = true;
        public int MaxRowsPerFile = 1000000, HtmlMaxMessages = 200000, HtmlRecipientsPerMessage = 100, HtmlChunkRows = 4000;
        public List<string> FilterLines = new List<string>();
        public List<string> Strategy = new List<string>();
        public double CoveragePercent = 100;
        public string CoverageNote = "";
        public Dictionary<string, List<DetailRow>> Details = new Dictionary<string, List<DetailRow>>();
        public bool Routes = true;              // MessageTrace_Routes.csv (one row per step of the routes read)
        public bool DetailsRequested;           // -IncludeDetails was used (the page explains how to read routes otherwise)
    }

    public sealed class ReportFile { public string Path, Kind, Name; public long Rows, Bytes; }

    /// <summary>A reason why deliveries did not end normally, with how many deliveries and messages it explains.</summary>
    public sealed class ReasonCount
    {
        public string Reason = "", Component = "", Severity = "", DocTitle = "", DocUrl = "", Example = "", Cause = "", CauseId = "", Tone = "danger", Help = "";
        public long Deliveries, Messages;
        internal long LastMessage = long.MinValue;
    }

    public sealed class ReportResult
    {
        public List<ReportFile> Files = new List<ReportFile>();
        public long Messages, Deliveries, Senders, Recipients, HtmlMessages, TotalBytes;
        public long RoutesRead, ProblemDeliveries, ProblemRoutesRead;
        public bool HtmlTruncated;
        public SortedDictionary<string, long> Statuses = new SortedDictionary<string, long>(StringComparer.Ordinal);
        public List<ReasonCount> Reasons = new List<ReasonCount>();   // per status code, text and component
        public List<ReasonCount> Causes = new List<ReasonCount>();    // per cause (Blocked by DLP, Recipient not found ...)
    }

    sealed class Counter { public long Messages, Deliveries, Delivered, Failed, Other, LastMs; }

    public static class ReportWriter
    {
        static readonly JsonSerializerOptions JsonOptions = new JsonSerializerOptions { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

        public static string StatusLabel(string status)
        {
            switch ((status ?? "").ToLowerInvariant())
            {
                case "delivered": return "Delivered";
                case "failed": return "Failed";
                case "pending": return "Pending";
                case "expanded": return "Expanded";
                case "quarantined": return "Quarantined";
                case "filteredasspam": return "Filtered as spam";
                case "gettingstatus": return "Getting status";
                case "": return "Unknown";
                default: return status;
            }
        }

        static bool IsDelivered(string s) { return string.Equals(s, "delivered", StringComparison.OrdinalIgnoreCase) || string.Equals(s, "expanded", StringComparison.OrdinalIgnoreCase); }
        static bool IsFailed(string s) { return string.Equals(s, "failed", StringComparison.OrdinalIgnoreCase); }

        /// <summary>"Delivered" when every recipient has the same status, otherwise "Delivered 24, Failed 2".</summary>
        public static string StatusSummary(IEnumerable<string> statuses)
        {
            var groups = statuses.GroupBy(s => StatusLabel(s)).OrderByDescending(g => g.Count()).ThenBy(g => g.Key, StringComparer.Ordinal).ToList();
            if (groups.Count == 1) return groups[0].Key;
            return string.Join(", ", groups.Select(g => g.Key + " " + g.Count().ToString(CultureInfo.InvariantCulture)));
        }

        // ---- rotating CSV ----------------------------------------------------------------------------

        sealed class CsvOut : IDisposable
        {
            readonly ReportRequest _q;
            readonly string _name;
            readonly string[] _header;
            StreamWriter _w;
            int _part;
            long _rowsInPart;
            public readonly List<ReportFile> Files = new List<ReportFile>();
            public long Rows;

            public CsvOut(ReportRequest q, string name, string[] header) { _q = q; _name = name; _header = header; Open(); }

            string PathOf(int part) { return Path.Combine(_q.OutputDirectory, _q.FilePrefix + "_" + _name + (part > 1 ? "_part" + part : "") + ".csv"); }

            void Open()
            {
                Close();
                _part++;
                _rowsInPart = 0;
                string path = PathOf(_part);
                _w = new StreamWriter(new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read, 1 << 16), new UTF8Encoding(true));
                _w.WriteLine(string.Join(_q.CsvDelimiter, _header.Select(h => Text.SafeCsv(h, _q.CsvDelimiter))));
                Files.Add(new ReportFile { Path = path, Kind = "CSV", Name = _name });
            }

            public void Add(params string[] cells)
            {
                if (_rowsInPart >= _q.MaxRowsPerFile) Open();
                for (int i = 0; i < cells.Length; i++)
                {
                    if (i > 0) _w.Write(_q.CsvDelimiter);
                    _w.Write(Text.SafeCsv(cells[i], _q.CsvDelimiter));
                }
                _w.WriteLine();
                _rowsInPart++; Rows++;
                Files[Files.Count - 1].Rows = _rowsInPart;
            }

            void Close()
            {
                if (_w == null) return;
                _w.Flush(); _w.Dispose(); _w = null;
                ReportFile f = Files[Files.Count - 1];
                f.Bytes = new FileInfo(f.Path).Length;
            }

            public void Dispose() { Close(); }
        }

        // ---- JSON array ------------------------------------------------------------------------------

        sealed class JsonOut : IDisposable
        {
            readonly FileStream _stream;
            readonly Utf8JsonWriter _w;
            public readonly ReportFile File;

            public JsonOut(ReportRequest q, string name)
            {
                string path = Path.Combine(q.OutputDirectory, q.FilePrefix + "_" + name + ".json");
                _stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read, 1 << 16);
                _w = new Utf8JsonWriter(_stream, new JsonWriterOptions { Indented = false, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
                _w.WriteStartArray();
                File = new ReportFile { Path = path, Kind = "JSON", Name = name };
            }

            public Utf8JsonWriter Writer { get { File.Rows++; return _w; } }
            bool _closed;

            public void Dispose()
            {
                if (_closed) return;
                _closed = true;
                _w.WriteEndArray(); _w.Flush(); _w.Dispose(); _stream.Dispose();
                File.Bytes = new FileInfo(File.Path).Length;
            }
        }

        // ---- main ------------------------------------------------------------------------------------

        public static ReportResult Write(IEnumerable<DeliveryView> rows, ReportRequest q)
        {
            Directory.CreateDirectory(q.OutputDirectory);
            var result = new ReportResult();
            var senders = new Dictionary<string, Counter>(StringComparer.OrdinalIgnoreCase);
            var recipients = new Dictionary<string, Counter>(StringComparer.OrdinalIgnoreCase);
            var topSenders = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
            var topRecipients = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
            var timeline = new SortedDictionary<string, long[]>(StringComparer.Ordinal);   // bucket -> messages, failed
            bool hourly = q.EndMs - q.StartMs <= 2 * 86400000L;
            string tz = q.TimeZoneLabel;
            CsvOut mCsv = null, dCsv = null, rCsv = null;
            JsonOut mJson = null, dJson = null;
            HtmlOut html = null;
            var reasons = new Dictionary<string, ReasonCount>(StringComparer.Ordinal);
            var causes = new Dictionary<string, ReasonCount>(StringComparer.Ordinal);
            try
            {
                if (q.Csv && q.Messages) mCsv = new CsvOut(q, "Messages", new[] { "Received (" + tz + ")", "Sender", "Recipients", "Recipient count", "Status", "Subject", "Size (bytes)", "Message ID", "From IP", "Message trace ID", "Cause", "Reason" });
                if (q.Csv && q.Deliveries) dCsv = new CsvOut(q, "Deliveries", new[] { "Received (" + tz + ")", "Sender", "Recipient", "Status", "Subject", "Size (bytes)", "Message ID", "From IP", "To IP", "Message trace ID", "Route", "Cause", "Reason" });
                if (q.Csv && q.Routes && q.Details != null && q.Details.Count > 0)
                    rCsv = new CsvOut(q, "Routes", new[] { "Received (" + tz + ")", "Sender", "Recipient", "Status", "Cause", "Subject", "Step", "Time (" + tz + ")", "Elapsed (s)", "Event", "Action", "Detail", "Status code", "Reason", "Component", "Remote server", "Facts", "Message ID", "Message trace ID" });
                if (q.Json && q.Messages) mJson = new JsonOut(q, "Messages");
                if (q.Json && q.Deliveries) dJson = new JsonOut(q, "Deliveries");
                if (q.Html) html = new HtmlOut(q);

                var current = new List<DeliveryView>();
                var routes = new List<RouteInfo>();
                Action flush = () =>
                {
                    if (current.Count == 0) return;
                    current.Sort((a, b) => string.Compare(a.Recipient, b.Recipient, StringComparison.OrdinalIgnoreCase));
                    DeliveryView m = current[0];
                    string local = Time.FormatLocal(m.ReceivedMs, q.Zone);
                    string day = local.Substring(0, 10);
                    long size = current.Max(d => d.Size);
                    string summary = StatusSummary(current.Select(d => d.Status));
                    result.Messages++;
                    result.Deliveries += current.Count;
                    bool anyFailed = false;
                    string messageReason = "", messageCause = "";
                    int messageReasonRank = int.MaxValue;
                    routes.Clear();
                    foreach (DeliveryView d in current)
                    {
                        List<DetailRow> events;
                        RouteInfo route = null;
                        if (q.Details != null && q.Details.Count > 0 && q.Details.TryGetValue(DetailKey(d), out events) && events.Count > 0) route = RouteAnalyzer.Analyze(events);
                        routes.Add(route);
                    }
                    for (int i = 0; i < current.Count; i++)
                    {
                        DeliveryView d = current[i];
                        RouteInfo route = routes[i];
                        string label = StatusLabel(d.Status);
                        long n; result.Statuses.TryGetValue(label, out n); result.Statuses[label] = n + 1;
                        if (IsFailed(d.Status)) anyFailed = true;
                        bool problem = !IsDelivered(d.Status);
                        string explain = RouteAnalyzer.Explain(route);
                        CauseInfo cause = route != null ? route.Cause : null;
                        string causeText = cause != null ? cause.Text : "";
                        if (route != null) result.RoutesRead++;
                        if (problem)
                        {
                            result.ProblemDeliveries++;
                            if (route != null) result.ProblemRoutesRead++;
                        }
                        if (cause != null)
                        {
                            // The cause of the message: a failure first, then a delay, then anything else.
                            int rank = IsFailed(d.Status) ? 0 : problem ? 1 : 2;
                            if (rank < messageReasonRank) { messageReason = explain; messageCause = causeText; messageReasonRank = rank; }
                            string key = cause.Id + "|" + cause.Rule + "|" + RouteAnalyzer.ExplainKey(route);
                            ReasonCount rc0;
                            if (!reasons.TryGetValue(key, out rc0))
                            {
                                ReasonInfo r = route.Reason != null && route.Reason.Code.Length > 0 && route.Reason.Code[0] != '2' ? route.Reason : null;
                                rc0 = new ReasonCount { Reason = explain.Length > 0 ? (r != null ? r.Short : explain) : route.Outcome, Component = r != null ? r.Component : RouteAnalyzer.Verdict(route).Length > 0 ? "Anti-spam" : "",
                                    Severity = r != null ? r.Severity : "", DocTitle = r != null ? r.DocTitle : "", DocUrl = r != null ? r.DocUrl : "", Example = d.Recipient,
                                    Cause = causeText, CauseId = cause.Id, Tone = cause.Tone, Help = cause.Help };
                                reasons[key] = rc0;
                            }
                            rc0.Deliveries++;
                            if (rc0.LastMessage != d.MessageRowId) { rc0.Messages++; rc0.LastMessage = d.MessageRowId; }
                            ReasonCount cc;
                            if (!causes.TryGetValue(cause.Label, out cc)) { cc = new ReasonCount { Cause = cause.Label, CauseId = cause.Id, Tone = cause.Tone, Help = cause.Help, Example = d.Recipient }; causes[cause.Label] = cc; }
                            cc.Deliveries++;
                            if (cc.LastMessage != d.MessageRowId) { cc.Messages++; cc.LastMessage = d.MessageRowId; }
                        }
                        if (dCsv != null) dCsv.Add(local, d.Sender, d.Recipient, label, d.Subject, d.Size.ToString(CultureInfo.InvariantCulture), d.MessageId, d.FromIP, d.ToIP, d.TraceId, route != null ? route.Summary : "", causeText, explain);
                        if (rCsv != null && route != null) WriteRouteRows(rCsv, q, local, d, label, route);
                        if (dJson != null)
                        {
                            Utf8JsonWriter w = dJson.Writer;
                            w.WriteStartObject();
                            w.WriteString("id", d.TraceId); w.WriteString("messageId", d.MessageId); w.WriteString("status", d.Status);
                            w.WriteString("receivedDateTime", Time.Iso(d.ReceivedMs)); w.WriteString("recipientAddress", d.Recipient);
                            w.WriteString("senderAddress", d.Sender); w.WriteString("subject", d.Subject); w.WriteNumber("size", d.Size);
                            w.WriteString("fromIP", d.FromIP); w.WriteString("toIP", d.ToIP);
                            if (route != null)
                            {
                                w.WriteString("route", route.Summary); w.WriteString("outcome", route.Outcome);
                                if (cause != null) { w.WriteString("causeId", cause.Id); w.WriteString("cause", causeText); }
                                w.WriteString("reason", explain);
                                w.WriteStartArray("events");
                                foreach (RouteEvent e in route.Events)
                                {
                                    w.WriteStartObject();
                                    w.WriteString("dateTime", Time.Iso(e.TimeMs)); w.WriteString("event", e.Event); w.WriteString("action", e.Action);
                                    w.WriteString("description", e.Description); w.WriteString("data", e.Data);
                                    w.WriteEndObject();
                                }
                                w.WriteEndArray();
                            }
                            w.WriteEndObject();
                        }
                        // Per recipient (and day).
                        string rk = (q.CountsPerDay ? day + "|" : "|") + d.Recipient;
                        Counter rc; if (!recipients.TryGetValue(rk, out rc)) { rc = new Counter(); recipients[rk] = rc; }
                        rc.Messages++; rc.Deliveries++;
                        if (IsDelivered(d.Status)) rc.Delivered++; else if (IsFailed(d.Status)) rc.Failed++; else rc.Other++;
                        if (d.ReceivedMs > rc.LastMs) rc.LastMs = d.ReceivedMs;
                        long tr; topRecipients.TryGetValue(d.Recipient, out tr); topRecipients[d.Recipient] = tr + 1;
                    }
                    // Per sender (and day).
                    string sk = (q.CountsPerDay ? day + "|" : "|") + m.Sender;
                    Counter sc; if (!senders.TryGetValue(sk, out sc)) { sc = new Counter(); senders[sk] = sc; }
                    sc.Messages++; sc.Deliveries += current.Count;
                    foreach (DeliveryView d in current) { if (IsDelivered(d.Status)) sc.Delivered++; else if (IsFailed(d.Status)) sc.Failed++; else sc.Other++; }
                    if (m.ReceivedMs > sc.LastMs) sc.LastMs = m.ReceivedMs;
                    long ts; topSenders.TryGetValue(m.Sender, out ts); topSenders[m.Sender] = ts + 1;
                    string bucket = hourly ? local.Substring(0, 13) + ":00" : day;
                    long[] tl; if (!timeline.TryGetValue(bucket, out tl)) { tl = new long[2]; timeline[bucket] = tl; }
                    tl[0]++; if (anyFailed) tl[1]++;

                    string recipientList = string.Join("; ", current.Select(d => d.Recipient));
                    if (mCsv != null) mCsv.Add(local, m.Sender, recipientList, current.Count.ToString(CultureInfo.InvariantCulture), summary, m.Subject, size.ToString(CultureInfo.InvariantCulture), m.MessageId, m.FromIP, m.TraceId, messageCause, messageReason);
                    if (mJson != null)
                    {
                        Utf8JsonWriter w = mJson.Writer;
                        w.WriteStartObject();
                        w.WriteString("id", m.TraceId); w.WriteString("messageId", m.MessageId); w.WriteString("receivedDateTime", Time.Iso(m.ReceivedMs));
                        w.WriteString("received", local); w.WriteString("senderAddress", m.Sender); w.WriteString("subject", m.Subject);
                        w.WriteNumber("size", size); w.WriteString("fromIP", m.FromIP); w.WriteString("status", summary);
                        w.WriteNumber("recipientCount", current.Count);
                        if (messageReason.Length > 0) w.WriteString("reason", messageReason);
                        if (messageCause.Length > 0) w.WriteString("cause", messageCause);
                        w.WriteStartArray("recipients");
                        for (int i = 0; i < current.Count; i++)
                        {
                            DeliveryView d = current[i];
                            w.WriteStartObject(); w.WriteString("recipientAddress", d.Recipient); w.WriteString("status", d.Status); w.WriteString("toIP", d.ToIP); w.WriteNumber("size", d.Size);
                            if (routes[i] != null)
                            {
                                w.WriteString("route", routes[i].Summary);
                                if (routes[i].Cause != null) w.WriteString("cause", routes[i].Cause.Text);
                                w.WriteString("reason", RouteAnalyzer.Explain(routes[i]));
                            }
                            w.WriteEndObject();
                        }
                        w.WriteEndArray();
                        w.WriteEndObject();
                    }
                    if (html != null) html.Add(current, routes, size);
                    current.Clear();
                };

                long currentId = long.MinValue;
                foreach (DeliveryView d in rows)
                {
                    if (d.MessageRowId != currentId) { flush(); currentId = d.MessageRowId; }
                    current.Add(d);
                }
                flush();

                // Senders and recipients: most messages first (per day: newest day first).
                var counterFiles = new List<ReportFile>();
                if (q.Senders && (q.Csv || q.Json)) WriteCounters(q, "Senders", "Sender", senders, true, counterFiles);
                if (q.Recipients && (q.Csv || q.Json)) WriteCounters(q, "Recipients", "Recipient", recipients, false, counterFiles);
                result.Files.AddRange(counterFiles);
                result.Senders = topSenders.Count;
                result.Recipients = topRecipients.Count;
                result.Reasons = reasons.Values.OrderByDescending(r => r.Deliveries).ThenByDescending(r => r.Messages).ThenBy(r => r.Reason, StringComparer.OrdinalIgnoreCase).ToList();
                result.Causes = causes.Values.OrderByDescending(r => r.Deliveries).ThenByDescending(r => r.Messages).ThenBy(r => r.Cause, StringComparer.OrdinalIgnoreCase).ToList();
                if (rCsv != null) rCsv.Dispose();

                if (html != null)
                {
                    var meta = new Dictionary<string, object>
                    {
                        { "title", q.Title }, { "tenant", q.Tenant }, { "rangeName", q.RangeName }, { "timeZone", tz },
                        { "periodStart", Time.FormatLocal(q.StartMs, q.Zone) }, { "periodEnd", Time.FormatLocal(q.EndMs, q.Zone) },
                        { "filters", q.FilterLines }, { "strategy", q.Strategy },
                        { "generated", DateTimeOffset.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) }, { "toolVersion", q.ToolVersion },
                        { "messages", result.Messages }, { "deliveries", result.Deliveries }, { "senders", result.Senders }, { "recipients", result.Recipients },
                        { "statuses", result.Statuses },
                        { "topSenders", topSenders.OrderByDescending(p => p.Value).ThenBy(p => p.Key, StringComparer.OrdinalIgnoreCase).Take(10).Select(p => new object[] { p.Key, p.Value }).ToList() },
                        { "topRecipients", topRecipients.OrderByDescending(p => p.Value).ThenBy(p => p.Key, StringComparer.OrdinalIgnoreCase).Take(10).Select(p => new object[] { p.Key, p.Value }).ToList() },
                        { "timeline", timeline.Select(p => new object[] { p.Key, p.Value[0], p.Value[1] }).ToList() }, { "hourly", hourly },
                        { "coveragePercent", Math.Round(q.CoveragePercent, 2) }, { "coverageNote", q.CoverageNote },
                        { "routes", result.RoutesRead }, { "problemDeliveries", result.ProblemDeliveries }, { "problemRoutes", result.ProblemRoutesRead },
                        { "detailsRequested", q.DetailsRequested },
                        { "reasons", result.Reasons.Take(15).Select(r => new object[] { r.Reason, r.Component, r.Severity, r.DocTitle, r.DocUrl, r.Deliveries, r.Messages, r.Example, r.Cause, r.Tone }).ToList() },
                        { "causes", result.Causes.Select(r => new object[] { r.Cause, r.Tone, r.Deliveries, r.Messages, r.Help, r.CauseId }).ToList() },
                        { "csvFiles", (mCsv != null ? mCsv.Files : new List<ReportFile>()).Concat(dCsv != null ? dCsv.Files : new List<ReportFile>()).Concat(rCsv != null ? rCsv.Files : new List<ReportFile>()).Concat(counterFiles).Select(f => Path.GetFileName(f.Path)).ToList() }
                    };
                    html.Close(meta);
                    result.HtmlMessages = html.Rows;
                    result.HtmlTruncated = html.Truncated;
                }
            }
            finally
            {
                if (mCsv != null) mCsv.Dispose();
                if (dCsv != null) dCsv.Dispose();
                if (rCsv != null) rCsv.Dispose();
                if (mJson != null) mJson.Dispose();
                if (dJson != null) dJson.Dispose();
                if (html != null) html.Dispose();
            }
            var files = new List<ReportFile>();
            if (mCsv != null) files.AddRange(mCsv.Files);
            if (dCsv != null) files.AddRange(dCsv.Files);
            if (rCsv != null) files.AddRange(rCsv.Files);
            files.AddRange(result.Files);   // senders, recipients
            if (mJson != null) files.Add(mJson.File);
            if (dJson != null) files.Add(dJson.File);
            if (html != null) files.Add(html.File);
            result.Files = files;
            foreach (ReportFile f in result.Files) { if (f.Bytes == 0 && File.Exists(f.Path)) f.Bytes = new FileInfo(f.Path).Length; result.TotalBytes += f.Bytes; }
            return result;
        }

        static string DetailKey(DeliveryView d)
        {
            return d.MessageRowId.ToString(CultureInfo.InvariantCulture) + "|" + d.RecipientId.ToString(CultureInfo.InvariantCulture);
        }

        /// <summary>One row per step of a route (MessageTrace_Routes.csv).</summary>
        static void WriteRouteRows(CsvOut csv, ReportRequest q, string received, DeliveryView d, string status, RouteInfo route)
        {
            int step = 0;
            foreach (RouteEvent e in route.Events)
            {
                step++;
                ReasonInfo r = e.Reason;
                string facts = string.Join(" | ", e.Facts.Select(f => f.Key + "=" + f.Value));
                csv.Add(received, d.Sender, d.Recipient, status, route.Cause != null ? route.Cause.Text : "", d.Subject, step.ToString(CultureInfo.InvariantCulture), Time.FormatLocal(e.TimeMs, q.Zone),
                    ((e.TimeMs - route.FirstMs) / 1000.0).ToString("0.###", CultureInfo.InvariantCulture), e.Event, e.Action, e.Description,
                    r != null ? (r.Smtp + " " + r.Code).Trim() : "", r != null ? r.Text : "", r != null ? r.Component : "",
                    r != null ? string.Join(" ", new[] { r.RemoteHost, r.RemoteIp }.Where(x => !string.IsNullOrEmpty(x))) : "", facts, d.MessageId, d.TraceId);
            }
        }

        static void WriteCounters(ReportRequest q, string name, string label, Dictionary<string, Counter> counters, bool isSender, List<ReportFile> files)
        {
            var ordered = counters.Select(p => new { Day = p.Key.Substring(0, p.Key.IndexOf('|')), Address = p.Key.Substring(p.Key.IndexOf('|') + 1), C = p.Value })
                .OrderByDescending(x => x.Day, StringComparer.Ordinal).ThenByDescending(x => x.C.Messages).ThenBy(x => x.Address, StringComparer.OrdinalIgnoreCase).ToList();
            if (q.Csv)
            {
                var header = new List<string>();
                if (q.CountsPerDay) header.Add("Date");
                header.Add(label); header.Add("Messages");
                if (isSender) header.Add("Recipients");
                header.AddRange(new[] { "Delivered", "Failed", "Other", "Last message (" + q.TimeZoneLabel + ")" });
                using (var csv = new CsvOut(q, name, header.ToArray()))
                {
                    foreach (var x in ordered)
                    {
                        var cells = new List<string>();
                        if (q.CountsPerDay) cells.Add(x.Day);
                        cells.Add(x.Address); cells.Add(x.C.Messages.ToString(CultureInfo.InvariantCulture));
                        if (isSender) cells.Add(x.C.Deliveries.ToString(CultureInfo.InvariantCulture));
                        cells.Add(x.C.Delivered.ToString(CultureInfo.InvariantCulture)); cells.Add(x.C.Failed.ToString(CultureInfo.InvariantCulture));
                        cells.Add(x.C.Other.ToString(CultureInfo.InvariantCulture)); cells.Add(Time.FormatLocal(x.C.LastMs, q.Zone));
                        csv.Add(cells.ToArray());
                    }
                    csv.Dispose();
                    files.AddRange(csv.Files);
                }
            }
            if (q.Json)
            {
                using (var json = new JsonOut(q, name))
                {
                    foreach (var x in ordered)
                    {
                        Utf8JsonWriter w = json.Writer;
                        w.WriteStartObject();
                        if (q.CountsPerDay) w.WriteString("date", x.Day);
                        w.WriteString(isSender ? "senderAddress" : "recipientAddress", x.Address);
                        w.WriteNumber("messages", x.C.Messages);
                        if (isSender) w.WriteNumber("recipients", x.C.Deliveries);
                        w.WriteNumber("delivered", x.C.Delivered); w.WriteNumber("failed", x.C.Failed); w.WriteNumber("other", x.C.Other);
                        w.WriteString("lastMessage", Time.Iso(x.C.LastMs));
                        w.WriteEndObject();
                    }
                    json.Dispose();
                    files.Add(json.File);
                }
            }
        }

        // ---- HTML ------------------------------------------------------------------------------------
        // Self-contained page. Rows are written in compressed chunks (JSON -> gzip -> base64) inside
        // <script> blocks that the page decompresses in the browser. Addresses, subjects and statuses are
        // stored once per file in dictionaries and referenced by number, which keeps large reports small.

        sealed class HtmlOut : IDisposable
        {
            readonly ReportRequest _q;
            readonly StreamWriter _w;
            readonly string[] _template;
            public readonly ReportFile File;
            readonly Dictionary<string, int> _people = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            readonly Dictionary<string, int> _subjects = new Dictionary<string, int>(StringComparer.Ordinal);
            readonly Dictionary<string, int> _statuses = new Dictionary<string, int>(StringComparer.Ordinal);
            readonly List<string> _newPeople = new List<string>(), _newSubjects = new List<string>(), _newStatuses = new List<string>();
            readonly List<long> _t = new List<long>(), _z = new List<long>();
            readonly List<int> _s = new List<int>(), _j = new List<int>(), _n = new List<int>(), _rl = new List<int>(), _ri = new List<int>(), _rs = new List<int>();
            readonly List<string> _m = new List<string>(), _ip = new List<string>(), _id = new List<string>();
            readonly List<object> _x = new List<object>();
            public long Rows;
            public bool Truncated;
            long _chunks;

            public HtmlOut(ReportRequest q)
            {
                _q = q;
                string text = System.IO.File.ReadAllText(q.TemplatePath, Encoding.UTF8);
                int a = text.IndexOf("%%CHUNKS%%", StringComparison.Ordinal), b = text.IndexOf("%%META%%", StringComparison.Ordinal);
                if (a < 0 || b < a || a != text.LastIndexOf("%%CHUNKS%%", StringComparison.Ordinal) || b != text.LastIndexOf("%%META%%", StringComparison.Ordinal))
                    throw new InvalidDataException("The HTML template must contain %%CHUNKS%% then %%META%%, exactly once each: " + q.TemplatePath);
                _template = new[] { text.Substring(0, a), text.Substring(a + 10, b - a - 10), text.Substring(b + 8) };
                string path = Path.Combine(q.OutputDirectory, q.FilePrefix + ".html");
                _w = new StreamWriter(new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read, 1 << 16), new UTF8Encoding(false));
                _w.Write(_template[0]);
                File = new ReportFile { Path = path, Kind = "HTML", Name = "Report" };
            }

            static int Index(Dictionary<string, int> map, List<string> added, string value)
            {
                value = value ?? "";
                int i;
                if (!map.TryGetValue(value, out i)) { i = map.Count; map.Add(value, i); added.Add(value); }
                return i;
            }

            public void Add(List<DeliveryView> deliveries, List<RouteInfo> routes, long size)
            {
                if (Rows >= _q.HtmlMaxMessages) { Truncated = true; return; }
                DeliveryView m = deliveries[0];
                int position = _t.Count;
                Rows++;
                // Local wall-clock seconds: the page formats them as UTC, so the browser's own time zone never changes what is shown.
                _t.Add(LocalSeconds(m.ReceivedMs));
                _s.Add(Index(_people, _newPeople, m.Sender));
                _j.Add(Index(_subjects, _newSubjects, m.Subject));
                _n.Add(deliveries.Count);
                _z.Add(size);
                _m.Add(m.MessageId);
                _ip.Add(m.FromIP);
                _id.Add(m.TraceId);
                int kept = Math.Min(deliveries.Count, _q.HtmlRecipientsPerMessage);
                _rl.Add(kept);
                // Problems first, then the routes read, so that the recipients kept in the page include them.
                IEnumerable<int> order = Enumerable.Range(0, deliveries.Count);
                if (deliveries.Count > kept) order = order.OrderBy(i => IsDelivered(deliveries[i].Status) ? 1 : 0).ThenBy(i => routes[i] != null ? 0 : 1);
                foreach (int i in order.Take(kept))
                {
                    DeliveryView d = deliveries[i];
                    _ri.Add(Index(_people, _newPeople, d.Recipient));
                    _rs.Add(Index(_statuses, _newStatuses, StatusLabel(d.Status)));
                    if (routes[i] != null) _x.Add(new object[] { position, _people[d.Recipient ?? ""], Encode(routes[i]) });
                }
                if (_t.Count >= _q.HtmlChunkRows) Flush();
            }

            long LocalSeconds(long ms)
            {
                return (ms + (long)_q.Zone.GetUtcOffset(DateTimeOffset.FromUnixTimeMilliseconds(ms)).TotalMilliseconds) / 1000;
            }

            // Route of one recipient: o outcome, m summary, g signature, w explanation, sv server, r reason, c cause, e events.
            // Event: [time, event, action, description, kind, tone, help, folder, [label, value, ...], reason].
            // Reason: [smtp, code, text, detail, severity, remote host, remote IP, remote message, component, Learn title, Learn URL].
            // Cause: [id, label, tone, help, rule].
            Dictionary<string, object> Encode(RouteInfo route)
            {
                return new Dictionary<string, object>
                {
                    { "o", route.Outcome }, { "m", route.Summary }, { "g", route.Signature }, { "w", RouteAnalyzer.Explain(route) }, { "sv", route.Server },
                    { "r", EncodeReason(route.Reason) },
                    { "c", route.Cause == null ? null : new[] { route.Cause.Id, route.Cause.Label, route.Cause.Tone, route.Cause.Help, route.Cause.Rule } },
                    { "e", route.Events.Select(e => new object[] {
                        LocalSeconds(e.TimeMs), e.Event, e.Action, e.Description, e.Kind, e.Tone, e.Help, e.Folder,
                        e.Facts.SelectMany(f => new[] { f.Key, f.Value }).ToList(), EncodeReason(e.Reason) }).ToList() }
                };
            }

            static object EncodeReason(ReasonInfo r)
            {
                if (r == null) return null;
                return new[] { r.Smtp, r.Code, r.Text, r.Detail, r.Severity, r.RemoteHost, r.RemoteIp, r.RemoteMessage, r.Component, r.DocTitle, r.DocUrl };
            }

            void Flush()
            {
                if (_t.Count == 0) return;
                var chunk = new Dictionary<string, object>
                {
                    { "dp", _newPeople }, { "dj", _newSubjects }, { "dst", _newStatuses },
                    { "t", _t }, { "s", _s }, { "j", _j }, { "n", _n }, { "z", _z }, { "m", _m }, { "ip", _ip }, { "id", _id },
                    { "rl", _rl }, { "ri", _ri }, { "rs", _rs }, { "x", _x }
                };
                byte[] json = JsonSerializer.SerializeToUtf8Bytes(chunk, JsonOptions);
                using (var buffer = new MemoryStream())
                {
                    using (var gzip = new GZipStream(buffer, CompressionLevel.Optimal, true)) gzip.Write(json, 0, json.Length);
                    _w.Write("<script type=\"application/x-mtr-chunk\">");
                    _w.Write(Convert.ToBase64String(buffer.GetBuffer(), 0, (int)buffer.Length));
                    _w.Write("</script>\n");
                }
                _chunks++;
                _newPeople.Clear(); _newSubjects.Clear(); _newStatuses.Clear();
                _t.Clear(); _s.Clear(); _j.Clear(); _n.Clear(); _z.Clear(); _m.Clear(); _ip.Clear(); _id.Clear();
                _rl.Clear(); _ri.Clear(); _rs.Clear(); _x.Clear();
            }

            public void Close(Dictionary<string, object> meta)
            {
                Flush();
                meta["htmlMessages"] = Rows;
                meta["htmlTruncated"] = Truncated;
                meta["htmlMaxMessages"] = _q.HtmlMaxMessages;
                meta["recipientsPerMessage"] = _q.HtmlRecipientsPerMessage;
                meta["chunks"] = _chunks;
                string json = JsonSerializer.Serialize(meta, JsonOptions).Replace("</", "<\\/");
                _w.Write(_template[1]);
                _w.Write(json);
                _w.Write(_template[2]);
                _w.Flush();
                _w.Dispose();
                File.Rows = Rows;
                File.Bytes = new FileInfo(File.Path).Length;
            }

            public void Dispose() { _w.Dispose(); }
        }
    }
}
