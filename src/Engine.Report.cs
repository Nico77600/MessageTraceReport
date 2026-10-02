// =============================================================================
//  Message Trace Report - engine, part 5: report files
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 1.0.0
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
    }

    public sealed class ReportFile { public string Path, Kind, Name; public long Rows, Bytes; }

    public sealed class ReportResult
    {
        public List<ReportFile> Files = new List<ReportFile>();
        public long Messages, Deliveries, Senders, Recipients, HtmlMessages, TotalBytes;
        public bool HtmlTruncated;
        public SortedDictionary<string, long> Statuses = new SortedDictionary<string, long>(StringComparer.Ordinal);
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
            CsvOut mCsv = null, dCsv = null;
            JsonOut mJson = null, dJson = null;
            HtmlOut html = null;
            try
            {
                if (q.Csv && q.Messages) mCsv = new CsvOut(q, "Messages", new[] { "Received (" + tz + ")", "Sender", "Recipients", "Recipient count", "Status", "Subject", "Size (bytes)", "Message ID", "From IP", "Message trace ID" });
                if (q.Csv && q.Deliveries) dCsv = new CsvOut(q, "Deliveries", new[] { "Received (" + tz + ")", "Sender", "Recipient", "Status", "Subject", "Size (bytes)", "Message ID", "From IP", "To IP", "Message trace ID" });
                if (q.Json && q.Messages) mJson = new JsonOut(q, "Messages");
                if (q.Json && q.Deliveries) dJson = new JsonOut(q, "Deliveries");
                if (q.Html) html = new HtmlOut(q);

                var current = new List<DeliveryView>();
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
                    foreach (DeliveryView d in current)
                    {
                        string label = StatusLabel(d.Status);
                        long n; result.Statuses.TryGetValue(label, out n); result.Statuses[label] = n + 1;
                        if (IsFailed(d.Status)) anyFailed = true;
                        if (dCsv != null) dCsv.Add(local, d.Sender, d.Recipient, label, d.Subject, d.Size.ToString(CultureInfo.InvariantCulture), d.MessageId, d.FromIP, d.ToIP, d.TraceId);
                        if (dJson != null)
                        {
                            Utf8JsonWriter w = dJson.Writer;
                            w.WriteStartObject();
                            w.WriteString("id", d.TraceId); w.WriteString("messageId", d.MessageId); w.WriteString("status", d.Status);
                            w.WriteString("receivedDateTime", Time.Iso(d.ReceivedMs)); w.WriteString("recipientAddress", d.Recipient);
                            w.WriteString("senderAddress", d.Sender); w.WriteString("subject", d.Subject); w.WriteNumber("size", d.Size);
                            w.WriteString("fromIP", d.FromIP); w.WriteString("toIP", d.ToIP);
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
                    if (mCsv != null) mCsv.Add(local, m.Sender, recipientList, current.Count.ToString(CultureInfo.InvariantCulture), summary, m.Subject, size.ToString(CultureInfo.InvariantCulture), m.MessageId, m.FromIP, m.TraceId);
                    if (mJson != null)
                    {
                        Utf8JsonWriter w = mJson.Writer;
                        w.WriteStartObject();
                        w.WriteString("id", m.TraceId); w.WriteString("messageId", m.MessageId); w.WriteString("receivedDateTime", Time.Iso(m.ReceivedMs));
                        w.WriteString("received", local); w.WriteString("senderAddress", m.Sender); w.WriteString("subject", m.Subject);
                        w.WriteNumber("size", size); w.WriteString("fromIP", m.FromIP); w.WriteString("status", summary);
                        w.WriteNumber("recipientCount", current.Count);
                        w.WriteStartArray("recipients");
                        foreach (DeliveryView d in current) { w.WriteStartObject(); w.WriteString("recipientAddress", d.Recipient); w.WriteString("status", d.Status); w.WriteString("toIP", d.ToIP); w.WriteNumber("size", d.Size); w.WriteEndObject(); }
                        w.WriteEndArray();
                        w.WriteEndObject();
                    }
                    if (html != null) html.Add(current, size);
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
                        { "csvFiles", (mCsv != null ? mCsv.Files : new List<ReportFile>()).Concat(dCsv != null ? dCsv.Files : new List<ReportFile>()).Concat(counterFiles).Select(f => Path.GetFileName(f.Path)).ToList() }
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
                if (mJson != null) mJson.Dispose();
                if (dJson != null) dJson.Dispose();
                if (html != null) html.Dispose();
            }
            var files = new List<ReportFile>();
            if (mCsv != null) files.AddRange(mCsv.Files);
            if (dCsv != null) files.AddRange(dCsv.Files);
            files.AddRange(result.Files);   // senders, recipients
            if (mJson != null) files.Add(mJson.File);
            if (dJson != null) files.Add(dJson.File);
            if (html != null) files.Add(html.File);
            result.Files = files;
            foreach (ReportFile f in result.Files) { if (f.Bytes == 0 && File.Exists(f.Path)) f.Bytes = new FileInfo(f.Path).Length; result.TotalBytes += f.Bytes; }
            return result;
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

            public void Add(List<DeliveryView> deliveries, long size)
            {
                if (Rows >= _q.HtmlMaxMessages) { Truncated = true; return; }
                DeliveryView m = deliveries[0];
                int position = _t.Count;
                Rows++;
                // Local wall-clock seconds: the page formats them as UTC, so the browser's own time zone never changes what is shown.
                _t.Add((m.ReceivedMs + (long)_q.Zone.GetUtcOffset(DateTimeOffset.FromUnixTimeMilliseconds(m.ReceivedMs)).TotalMilliseconds) / 1000);
                _s.Add(Index(_people, _newPeople, m.Sender));
                _j.Add(Index(_subjects, _newSubjects, m.Subject));
                _n.Add(deliveries.Count);
                _z.Add(size);
                _m.Add(m.MessageId);
                _ip.Add(m.FromIP);
                _id.Add(m.TraceId);
                int kept = Math.Min(deliveries.Count, _q.HtmlRecipientsPerMessage);
                _rl.Add(kept);
                // Problems first, so that the recipients kept in the page include them.
                IEnumerable<DeliveryView> order = deliveries.Count > kept ? deliveries.OrderBy(d => IsDelivered(d.Status) ? 1 : 0) : (IEnumerable<DeliveryView>)deliveries;
                foreach (DeliveryView d in order.Take(kept))
                {
                    _ri.Add(Index(_people, _newPeople, d.Recipient));
                    _rs.Add(Index(_statuses, _newStatuses, StatusLabel(d.Status)));
                    List<DetailRow> events;
                    if (_q.Details != null && _q.Details.TryGetValue(d.MessageRowId.ToString(CultureInfo.InvariantCulture) + "|" + d.RecipientId.ToString(CultureInfo.InvariantCulture), out events))
                    {
                        _x.Add(new object[] { position, _people[d.Recipient ?? ""], events.Select(e => new object[] {
                            (e.TimeMs + (long)_q.Zone.GetUtcOffset(DateTimeOffset.FromUnixTimeMilliseconds(e.TimeMs)).TotalMilliseconds) / 1000,
                            e.Event, e.Action, e.Description, e.Data }).ToList() });
                    }
                }
                if (_t.Count >= _q.HtmlChunkRows) Flush();
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
