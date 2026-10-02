// =============================================================================
//  Message Trace Report - engine, part 4: SQLite store
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 1.0.0
//
//  Tables (times in Unix ms, UTC)
//    run           one row per execution
//    address       every sender / recipient address, once (case-insensitive)
//    status        delivery status names (delivered, failed ...)
//    message       one row per message trace ID: Message-ID, sender, subject, received, source IP
//    delivery      one row per message and recipient: status, size, destination IP
//                  (what Graph returns: one exchangeMessageTrace per recipient)
//    signature     one row per distinct Graph query (its conditions, '' = the whole tenant)
//    coverage      [start, end) of a signature collected completely at collected_ms
//    detail        route events of a delivery (getDetailsByRecipient), optional
//    detail_fetch  when the route of a delivery was read
//
//  A message seen again (another query, a later run) is updated, never duplicated. The
//  coverage table is what lets a run skip the periods already collected.
// =============================================================================
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using Microsoft.Data.Sqlite;

namespace MessageTraceReport
{
    public sealed class IngestResult { public long NewMessages, NewDeliveries, UpdatedDeliveries; }

    /// <summary>One delivery of the report selection (a message for one recipient).</summary>
    public sealed class DeliveryView
    {
        public long MessageRowId, RecipientId, ReceivedMs, Size;
        public string TraceId, Sender, Subject, MessageId, FromIP, Recipient, Status, ToIP;
    }

    public sealed class SelectionResult { public long Deliveries, Messages; }

    public sealed class StoreStatistics
    {
        public long Messages, Deliveries, Addresses, Signatures, CoverageRows, Runs, DetailEvents, FileBytes;
        public long? FirstReceivedMs, LastReceivedMs, LastCollectMs;
    }

    public sealed class DayStatistics
    {
        public DateTime LocalDate;
        public long StartMs, EndMs, Messages, CoveredMs, SettledMs;
    }

    public sealed class RunRow
    {
        public long Id, StartedMs, EndedMs, Requests, Pages, Rows, NewDeliveries, Throttled;
        public string Mode, Status, Account, Filter, Error;
    }

    public sealed class PurgeResult { public long Messages, Deliveries, Coverage, Details, Addresses; }

    public sealed class Store : IDisposable
    {
        public const string SchemaVersion = "1";
        readonly SqliteConnection _db;
        readonly Dictionary<string, long> _addresses = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        readonly Dictionary<string, long> _statuses = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        public string FilePath { get; private set; }
        public bool ReadOnly { get; private set; }

        public Store(string path, bool readOnly, string toolVersion)
        {
            FilePath = Path.GetFullPath(path);
            ReadOnly = readOnly;
            if (!readOnly) Directory.CreateDirectory(Path.GetDirectoryName(FilePath));
            var builder = new SqliteConnectionStringBuilder
            {
                DataSource = FilePath,
                Mode = readOnly ? SqliteOpenMode.ReadOnly : SqliteOpenMode.ReadWriteCreate,
                Cache = SqliteCacheMode.Private,
                Pooling = false
            };
            _db = new SqliteConnection(builder.ToString());
            _db.Open();
            Exec("PRAGMA busy_timeout=30000;");
            Exec("PRAGMA temp_store=MEMORY;");
            // Case-insensitive text match used by the subject filter (SQLite lower() only knows ASCII).
            _db.CreateFunction("mtr_match", (string value, string op, string pattern) => Match(value, op, pattern), true);
            if (readOnly) return;
            Exec("PRAGMA auto_vacuum=INCREMENTAL;");   // effective on a new database only
            Exec("PRAGMA journal_mode=WAL;");
            Exec("PRAGMA synchronous=NORMAL;");
            Exec(Schema);
            SetMetadata("schema_version", SchemaVersion);
            SetMetadata("tool_version", toolVersion ?? "");
        }

        const string Schema = @"
CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS run(
  id INTEGER PRIMARY KEY, mode TEXT, started_ms INTEGER, ended_ms INTEGER, status TEXT, host TEXT, account TEXT, version TEXT,
  filter TEXT, queries INTEGER NOT NULL DEFAULT 0, items INTEGER NOT NULL DEFAULT 0, requests INTEGER NOT NULL DEFAULT 0,
  pages INTEGER NOT NULL DEFAULT 0, rows INTEGER NOT NULL DEFAULT 0, new_deliveries INTEGER NOT NULL DEFAULT 0,
  throttled INTEGER NOT NULL DEFAULT 0, error TEXT);
CREATE TABLE IF NOT EXISTS address(id INTEGER PRIMARY KEY, address TEXT NOT NULL UNIQUE COLLATE NOCASE);
CREATE TABLE IF NOT EXISTS status(id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE COLLATE NOCASE);
CREATE TABLE IF NOT EXISTS message(
  id INTEGER PRIMARY KEY, trace_id BLOB NOT NULL UNIQUE, message_id TEXT, sender INTEGER, subject TEXT,
  received_ms INTEGER NOT NULL, from_ip TEXT, first_seen_ms INTEGER);
CREATE INDEX IF NOT EXISTS ix_message_received ON message(received_ms);
CREATE INDEX IF NOT EXISTS ix_message_sender ON message(sender, received_ms);
CREATE INDEX IF NOT EXISTS ix_message_mid ON message(message_id COLLATE NOCASE);
CREATE TABLE IF NOT EXISTS delivery(
  message INTEGER NOT NULL, recipient INTEGER NOT NULL, status INTEGER, size INTEGER, to_ip TEXT, updated_ms INTEGER,
  PRIMARY KEY(message, recipient)) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS ix_delivery_recipient ON delivery(recipient);
CREATE TABLE IF NOT EXISTS signature(id INTEGER PRIMARY KEY, text TEXT NOT NULL UNIQUE, label TEXT, created_ms INTEGER, last_used_ms INTEGER);
CREATE TABLE IF NOT EXISTS coverage(
  id INTEGER PRIMARY KEY, signature INTEGER NOT NULL, start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL,
  collected_ms INTEGER NOT NULL, run_id INTEGER);
CREATE INDEX IF NOT EXISTS ix_coverage_signature ON coverage(signature, end_ms);
CREATE TABLE IF NOT EXISTS detail(
  message INTEGER NOT NULL, recipient INTEGER NOT NULL, seq INTEGER NOT NULL, time_ms INTEGER, event TEXT, action TEXT,
  description TEXT, data TEXT, PRIMARY KEY(message, recipient, seq)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS detail_fetch(message INTEGER NOT NULL, recipient INTEGER NOT NULL, fetched_ms INTEGER, PRIMARY KEY(message, recipient)) WITHOUT ROWID;
";

        // ---- helpers ----------------------------------------------------------------------------

        void Exec(string sql)
        {
            using (var c = _db.CreateCommand()) { c.CommandText = sql; c.ExecuteNonQuery(); }
        }

        SqliteCommand Command(string sql, SqliteTransaction tx = null)
        {
            var c = _db.CreateCommand();
            c.CommandText = sql;
            c.Transaction = tx;
            return c;
        }

        static object Db(object value) { return value ?? DBNull.Value; }

        long Scalar(string sql, params object[] args)
        {
            using (var c = Command(sql))
            {
                for (int i = 0; i < args.Length; i++) c.Parameters.AddWithValue("@p" + i, Db(args[i]));
                object v = c.ExecuteScalar();
                return v == null || v is DBNull ? 0 : Convert.ToInt64(v, CultureInfo.InvariantCulture);
            }
        }

        static bool Match(string value, string op, string pattern)
        {
            if (pattern == null) return true;
            if (value == null) value = "";
            switch (op)
            {
                case "eq": return string.Equals(value, pattern, StringComparison.OrdinalIgnoreCase);
                case "startswith": return value.StartsWith(pattern, StringComparison.OrdinalIgnoreCase);
                case "endswith": return value.EndsWith(pattern, StringComparison.OrdinalIgnoreCase);
                default: return value.IndexOf(pattern, StringComparison.OrdinalIgnoreCase) >= 0;
            }
        }

        public static byte[] TraceKey(string traceId)
        {
            Guid g;
            if (Guid.TryParse(traceId, out g)) return g.ToByteArray();
            return Encoding.UTF8.GetBytes(traceId ?? "");
        }

        public static string TraceText(byte[] key)
        {
            if (key == null) return "";
            return key.Length == 16 ? new Guid(key).ToString() : Encoding.UTF8.GetString(key);
        }

        public long FileBytes
        {
            get
            {
                long total = 0;
                foreach (string suffix in new[] { "", "-wal" }) { var f = new FileInfo(FilePath + suffix); if (f.Exists) total += f.Length; }
                return total;
            }
        }

        public string GetMetadata(string key)
        {
            using (var c = Command("SELECT value FROM metadata WHERE key=@k"))
            {
                c.Parameters.AddWithValue("@k", key);
                object v = c.ExecuteScalar();
                return v == null || v is DBNull ? null : (string)v;
            }
        }

        public void SetMetadata(string key, string value)
        {
            using (var c = Command("INSERT INTO metadata(key,value) VALUES(@k,@v) ON CONFLICT(key) DO UPDATE SET value=excluded.value"))
            {
                c.Parameters.AddWithValue("@k", key);
                c.Parameters.AddWithValue("@v", Db(value));
                c.ExecuteNonQuery();
            }
        }

        /// <summary>Request times of the last quota window (saved by the previous run on this database).</summary>
        public long[] GetRequestStamps(string key)
        {
            string text = GetMetadata(key);
            if (string.IsNullOrEmpty(text)) return new long[0];
            var list = new List<long>();
            foreach (string part in text.Split(',')) { long v; if (long.TryParse(part, NumberStyles.Integer, CultureInfo.InvariantCulture, out v)) list.Add(v); }
            return list.ToArray();
        }

        public void SetRequestStamps(string key, long[] stamps)
        {
            SetMetadata(key, string.Join(",", stamps.Select(s => s.ToString(CultureInfo.InvariantCulture))));
        }

        // ---- runs -------------------------------------------------------------------------------

        public long StartRun(string mode, string account, string host, string toolVersion, string filter)
        {
            using (var c = Command("INSERT INTO run(mode, started_ms, status, host, account, version, filter) VALUES(@m,@s,'Running',@h,@a,@v,@f) RETURNING id"))
            {
                c.Parameters.AddWithValue("@m", mode); c.Parameters.AddWithValue("@s", Time.NowMs());
                c.Parameters.AddWithValue("@h", Db(host)); c.Parameters.AddWithValue("@a", Db(account));
                c.Parameters.AddWithValue("@v", Db(toolVersion)); c.Parameters.AddWithValue("@f", Db(filter));
                return Convert.ToInt64(c.ExecuteScalar(), CultureInfo.InvariantCulture);
            }
        }

        public void UpdateRunAccount(long runId, string account)
        {
            using (var c = Command("UPDATE run SET account=@a WHERE id=@id")) { c.Parameters.AddWithValue("@a", Db(account)); c.Parameters.AddWithValue("@id", runId); c.ExecuteNonQuery(); }
        }

        public void FinishRun(long runId, string status, long queries, long items, long requests, long pages, long rows, long newDeliveries, long throttled, string error)
        {
            using (var c = Command("UPDATE run SET ended_ms=@e, status=@st, queries=@q, items=@i, requests=@r, pages=@p, rows=@rw, new_deliveries=@n, throttled=@t, error=@err WHERE id=@id"))
            {
                c.Parameters.AddWithValue("@e", Time.NowMs()); c.Parameters.AddWithValue("@st", status);
                c.Parameters.AddWithValue("@q", queries); c.Parameters.AddWithValue("@i", items); c.Parameters.AddWithValue("@r", requests);
                c.Parameters.AddWithValue("@p", pages); c.Parameters.AddWithValue("@rw", rows); c.Parameters.AddWithValue("@n", newDeliveries);
                c.Parameters.AddWithValue("@t", throttled); c.Parameters.AddWithValue("@err", Db(error)); c.Parameters.AddWithValue("@id", runId);
                c.ExecuteNonQuery();
            }
        }

        /// <summary>Runs left 'Running' by an interrupted execution (closed window, crash).</summary>
        public int CloseAbandonedRuns()
        {
            using (var c = Command("UPDATE run SET status='Interrupted', ended_ms=coalesce(ended_ms, started_ms) WHERE status='Running'")) return c.ExecuteNonQuery();
        }

        public List<RunRow> GetRecentRuns(int count)
        {
            var list = new List<RunRow>();
            using (var c = Command("SELECT id, mode, started_ms, coalesce(ended_ms,0), status, account, filter, requests, pages, rows, new_deliveries, throttled, error FROM run ORDER BY id DESC LIMIT @n"))
            {
                c.Parameters.AddWithValue("@n", count);
                using (var r = c.ExecuteReader())
                    while (r.Read())
                        list.Add(new RunRow
                        {
                            Id = r.GetInt64(0), Mode = r.IsDBNull(1) ? "" : r.GetString(1), StartedMs = r.GetInt64(2), EndedMs = r.GetInt64(3),
                            Status = r.IsDBNull(4) ? "" : r.GetString(4), Account = r.IsDBNull(5) ? "" : r.GetString(5), Filter = r.IsDBNull(6) ? "" : r.GetString(6),
                            Requests = r.GetInt64(7), Pages = r.GetInt64(8), Rows = r.GetInt64(9), NewDeliveries = r.GetInt64(10), Throttled = r.GetInt64(11),
                            Error = r.IsDBNull(12) ? "" : r.GetString(12)
                        });
            }
            return list;
        }

        // ---- signatures and coverage ------------------------------------------------------------------

        public long GetSignatureId(string signature, string label)
        {
            using (var c = Command("INSERT INTO signature(text, label, created_ms, last_used_ms) VALUES(@t,@l,@n,@n) ON CONFLICT(text) DO UPDATE SET last_used_ms=excluded.last_used_ms RETURNING id"))
            {
                c.Parameters.AddWithValue("@t", signature ?? ""); c.Parameters.AddWithValue("@l", Db(label)); c.Parameters.AddWithValue("@n", Time.NowMs());
                return Convert.ToInt64(c.ExecuteScalar(), CultureInfo.InvariantCulture);
            }
        }

        /// <summary>
        /// Settled coverage of every signature overlapping [fromMs, toMs): each range is cut at
        /// collected_ms - settlingMs (what may still change is collected again).
        /// </summary>
        public List<KnownCoverage> GetKnownCoverage(long settlingMs, long fromMs, long toMs)
        {
            var map = new Dictionary<long, KnownCoverage>();
            using (var c = Command("SELECT s.id, s.text, c.start_ms, c.end_ms, c.collected_ms FROM coverage c JOIN signature s ON s.id = c.signature WHERE c.end_ms > @f AND c.start_ms < @t"))
            {
                c.Parameters.AddWithValue("@f", fromMs); c.Parameters.AddWithValue("@t", toMs);
                using (var r = c.ExecuteReader())
                {
                    while (r.Read())
                    {
                        long id = r.GetInt64(0);
                        long start = r.GetInt64(2), end = Math.Min(r.GetInt64(3), r.GetInt64(4) - settlingMs);
                        KnownCoverage k;
                        if (!map.TryGetValue(id, out k)) { k = new KnownCoverage { SignatureId = id, Signature = r.GetString(1), Conditions = QuerySpec.ParseSignature(r.GetString(1)) }; map[id] = k; }
                        if (end > start) k.Ranges.Add(new TimeRange(start, end));
                    }
                }
            }
            foreach (KnownCoverage k in map.Values) k.Ranges = Coverage.Merge(k.Ranges);
            return map.Values.ToList();
        }

        /// <summary>Coverage of one signature (settled or not), merged.</summary>
        public List<TimeRange> GetCoverage(string signature, long settlingMs)
        {
            var list = new List<TimeRange>();
            using (var c = Command("SELECT c.start_ms, c.end_ms, c.collected_ms FROM coverage c JOIN signature s ON s.id = c.signature WHERE s.text = @t"))
            {
                c.Parameters.AddWithValue("@t", signature ?? "");
                using (var r = c.ExecuteReader())
                    while (r.Read())
                    {
                        long end = settlingMs < 0 ? r.GetInt64(1) : Math.Min(r.GetInt64(1), r.GetInt64(2) - settlingMs);
                        if (end > r.GetInt64(0)) list.Add(new TimeRange(r.GetInt64(0), end));
                    }
            }
            return Coverage.Merge(list);
        }

        /// <summary>Merges the fully settled coverage rows of each signature (keeps the table small).</summary>
        public int CompactCoverage(long settlingMs)
        {
            var rows = new List<long[]>();
            using (var c = Command("SELECT id, signature, start_ms, end_ms, collected_ms FROM coverage WHERE end_ms <= collected_ms - @s ORDER BY signature, start_ms"))
            {
                c.Parameters.AddWithValue("@s", settlingMs);
                using (var r = c.ExecuteReader()) while (r.Read()) rows.Add(new[] { r.GetInt64(0), r.GetInt64(1), r.GetInt64(2), r.GetInt64(3), r.GetInt64(4) });
            }
            int removed = 0;
            using (var tx = _db.BeginTransaction())
            using (var del = Command("DELETE FROM coverage WHERE id=@id", tx))
            using (var upd = Command("UPDATE coverage SET start_ms=@s, end_ms=@e, collected_ms=@c WHERE id=@id", tx))
            {
                var pId = del.Parameters.Add("@id", SqliteType.Integer);
                var uS = upd.Parameters.Add("@s", SqliteType.Integer); var uE = upd.Parameters.Add("@e", SqliteType.Integer);
                var uC = upd.Parameters.Add("@c", SqliteType.Integer); var uId = upd.Parameters.Add("@id", SqliteType.Integer);
                long[] keep = null;
                Action flush = () => { if (keep != null) { uS.Value = keep[2]; uE.Value = keep[3]; uC.Value = keep[4]; uId.Value = keep[0]; upd.ExecuteNonQuery(); } };
                foreach (long[] row in rows)
                {
                    if (keep != null && row[1] == keep[1] && row[2] <= keep[3])
                    {
                        keep[3] = Math.Max(keep[3], row[3]); keep[4] = Math.Max(keep[4], row[4]);
                        pId.Value = row[0]; del.ExecuteNonQuery(); removed++;
                        continue;
                    }
                    flush();
                    keep = row;
                }
                flush();
                tx.Commit();
            }
            return removed;
        }

        // ---- ingestion ----------------------------------------------------------------------------

        long AddressId(string address, SqliteTransaction tx)
        {
            address = address ?? "";
            long id;
            if (_addresses.TryGetValue(address, out id)) return id;
            using (var c = Command("INSERT INTO address(address) VALUES(@a) ON CONFLICT(address) DO UPDATE SET address=address RETURNING id", tx))
            {
                c.Parameters.AddWithValue("@a", address);
                id = Convert.ToInt64(c.ExecuteScalar(), CultureInfo.InvariantCulture);
            }
            if (_addresses.Count > 500000) _addresses.Clear();
            _addresses[address] = id;
            return id;
        }

        long StatusId(string name, SqliteTransaction tx)
        {
            name = name ?? "";
            long id;
            if (_statuses.TryGetValue(name, out id)) return id;
            using (var c = Command("INSERT INTO status(name) VALUES(@n) ON CONFLICT(name) DO UPDATE SET name=name RETURNING id", tx))
            {
                c.Parameters.AddWithValue("@n", name);
                id = Convert.ToInt64(c.ExecuteScalar(), CultureInfo.InvariantCulture);
            }
            _statuses[name] = id;
            return id;
        }

        /// <summary>
        /// Stores one page and extends the coverage of its work item, in one transaction. The API returns
        /// the newest messages first: after a page, the window is complete from just after the oldest message
        /// of the page to its end. After the last page, the whole window is complete.
        /// </summary>
        public IngestResult CommitPage(WorkItem item, List<TraceRow> rows, bool last, bool ordered, long oldestMs, long fetchedMs, long runId)
        {
            var result = new IngestResult();
            long now = Time.NowMs();
            using (var tx = _db.BeginTransaction())
            {
                using (var insMsg = Command("INSERT INTO message(trace_id, message_id, sender, subject, received_ms, from_ip, first_seen_ms) VALUES(@t,@m,@s,@j,@r,@ip,@n) ON CONFLICT(trace_id) DO NOTHING RETURNING id", tx))
                using (var getMsg = Command("SELECT id FROM message WHERE trace_id=@t", tx))
                using (var insDel = Command("INSERT INTO delivery(message, recipient, status, size, to_ip, updated_ms) VALUES(@m,@r,@s,@z,@ip,@n) ON CONFLICT(message, recipient) DO NOTHING", tx))
                using (var updDel = Command("UPDATE delivery SET status=@s, size=@z, to_ip=@ip, updated_ms=@n WHERE message=@m AND recipient=@r AND (status IS NOT @s OR size IS NOT @z OR to_ip IS NOT @ip)", tx))
                {
                    var mT = insMsg.Parameters.Add("@t", SqliteType.Blob); var mM = insMsg.Parameters.Add("@m", SqliteType.Text);
                    var mS = insMsg.Parameters.Add("@s", SqliteType.Integer); var mJ = insMsg.Parameters.Add("@j", SqliteType.Text);
                    var mR = insMsg.Parameters.Add("@r", SqliteType.Integer); var mIp = insMsg.Parameters.Add("@ip", SqliteType.Text);
                    insMsg.Parameters.AddWithValue("@n", now);
                    var gT = getMsg.Parameters.Add("@t", SqliteType.Blob);
                    var dM = insDel.Parameters.Add("@m", SqliteType.Integer); var dR = insDel.Parameters.Add("@r", SqliteType.Integer);
                    var dS = insDel.Parameters.Add("@s", SqliteType.Integer); var dZ = insDel.Parameters.Add("@z", SqliteType.Integer);
                    var dIp = insDel.Parameters.Add("@ip", SqliteType.Text); insDel.Parameters.AddWithValue("@n", now);
                    var uM = updDel.Parameters.Add("@m", SqliteType.Integer); var uR = updDel.Parameters.Add("@r", SqliteType.Integer);
                    var uS = updDel.Parameters.Add("@s", SqliteType.Integer); var uZ = updDel.Parameters.Add("@z", SqliteType.Integer);
                    var uIp = updDel.Parameters.Add("@ip", SqliteType.Text); updDel.Parameters.AddWithValue("@n", now);
                    var messages = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);

                    foreach (TraceRow row in rows)
                    {
                        long messageRow;
                        if (!messages.TryGetValue(row.Id, out messageRow))
                        {
                            byte[] key = TraceKey(row.Id);
                            mT.Value = key; mM.Value = Db(row.MessageId); mS.Value = AddressId(row.Sender, tx); mJ.Value = Db(row.Subject);
                            mR.Value = row.ReceivedMs; mIp.Value = Db(row.FromIP);
                            object id = insMsg.ExecuteScalar();
                            if (id != null && !(id is DBNull)) { messageRow = Convert.ToInt64(id, CultureInfo.InvariantCulture); result.NewMessages++; }
                            else { gT.Value = key; messageRow = Convert.ToInt64(getMsg.ExecuteScalar(), CultureInfo.InvariantCulture); }
                            messages[row.Id] = messageRow;
                        }
                        long recipient = AddressId(row.Recipient, tx), status = StatusId(row.Status, tx);
                        dM.Value = messageRow; dR.Value = recipient; dS.Value = status; dZ.Value = row.Size; dIp.Value = Db(row.ToIP);
                        if (insDel.ExecuteNonQuery() == 1) { result.NewDeliveries++; continue; }
                        uM.Value = messageRow; uR.Value = recipient; uS.Value = status; uZ.Value = row.Size; uIp.Value = Db(row.ToIP);
                        if (updDel.ExecuteNonQuery() == 1) result.UpdatedDeliveries++;
                    }
                }

                if (item.CoverageId == 0)
                {
                    using (var c = Command("INSERT INTO coverage(signature, start_ms, end_ms, collected_ms, run_id) VALUES(@s,@e,@e,@c,@r) RETURNING id", tx))
                    {
                        c.Parameters.AddWithValue("@s", item.SignatureId); c.Parameters.AddWithValue("@e", item.EndMs);
                        c.Parameters.AddWithValue("@c", fetchedMs); c.Parameters.AddWithValue("@r", runId);
                        item.CoverageId = Convert.ToInt64(c.ExecuteScalar(), CultureInfo.InvariantCulture);
                    }
                    item.CoveredFromMs = item.EndMs;
                }
                long from = item.CoveredFromMs;
                if (last) from = item.StartMs;
                else if (ordered && rows.Count > 0) from = Math.Min(from, Math.Max(item.StartMs, Math.Min(item.EndMs, oldestMs + 1)));
                if (from < item.CoveredFromMs)
                {
                    using (var c = Command("UPDATE coverage SET start_ms=@s WHERE id=@id", tx))
                    {
                        c.Parameters.AddWithValue("@s", from); c.Parameters.AddWithValue("@id", item.CoverageId);
                        c.ExecuteNonQuery();
                    }
                    item.CoveredFromMs = from;
                }
                tx.Commit();
            }
            return result;
        }

        public void SaveDetails(long messageRowId, long recipientId, List<DetailRow> rows)
        {
            using (var tx = _db.BeginTransaction())
            {
                using (var del = Command("DELETE FROM detail WHERE message=@m AND recipient=@r", tx))
                {
                    del.Parameters.AddWithValue("@m", messageRowId); del.Parameters.AddWithValue("@r", recipientId);
                    del.ExecuteNonQuery();
                }
                using (var ins = Command("INSERT INTO detail(message, recipient, seq, time_ms, event, action, description, data) VALUES(@m,@r,@q,@t,@e,@a,@d,@x)", tx))
                {
                    ins.Parameters.AddWithValue("@m", messageRowId); ins.Parameters.AddWithValue("@r", recipientId);
                    var q = ins.Parameters.Add("@q", SqliteType.Integer); var t = ins.Parameters.Add("@t", SqliteType.Integer);
                    var e = ins.Parameters.Add("@e", SqliteType.Text); var a = ins.Parameters.Add("@a", SqliteType.Text);
                    var d = ins.Parameters.Add("@d", SqliteType.Text); var x = ins.Parameters.Add("@x", SqliteType.Text);
                    int seq = 0;
                    foreach (DetailRow row in rows)
                    {
                        q.Value = seq++; t.Value = row.TimeMs; e.Value = Db(row.Event); a.Value = Db(row.Action); d.Value = Db(row.Description); x.Value = Db(row.Data);
                        ins.ExecuteNonQuery();
                    }
                }
                using (var f = Command("INSERT INTO detail_fetch(message, recipient, fetched_ms) VALUES(@m,@r,@n) ON CONFLICT(message, recipient) DO UPDATE SET fetched_ms=excluded.fetched_ms", tx))
                {
                    f.Parameters.AddWithValue("@m", messageRowId); f.Parameters.AddWithValue("@r", recipientId); f.Parameters.AddWithValue("@n", Time.NowMs());
                    f.ExecuteNonQuery();
                }
                tx.Commit();
            }
        }

        // ---- report selection ------------------------------------------------------------------------

        /// <summary>
        /// Builds temp.sel: every delivery of [startMs, endMs) matching the FULL user filter (the Graph queries
        /// may have returned more, for instance every message of a sender when the recipients are filtered here).
        /// </summary>
        public SelectionResult Select(FilterSpec f, long startMs, long endMs)
        {
            Exec("DROP TABLE IF EXISTS temp.sel; CREATE TEMP TABLE sel(message INTEGER NOT NULL, recipient INTEGER NOT NULL, PRIMARY KEY(message, recipient)) WITHOUT ROWID;");
            Exec("DROP TABLE IF EXISTS temp.f_sender; CREATE TEMP TABLE f_sender(id INTEGER PRIMARY KEY);");
            Exec("DROP TABLE IF EXISTS temp.f_recipient; CREATE TEMP TABLE f_recipient(id INTEGER PRIMARY KEY);");
            Exec("DROP TABLE IF EXISTS temp.f_sender_like; CREATE TEMP TABLE f_sender_like(p TEXT);");
            Exec("DROP TABLE IF EXISTS temp.f_recipient_like; CREATE TEMP TABLE f_recipient_like(p TEXT);");
            Exec("DROP TABLE IF EXISTS temp.f_status; CREATE TEMP TABLE f_status(id INTEGER PRIMARY KEY);");
            Exec("DROP TABLE IF EXISTS temp.f_mid; CREATE TEMP TABLE f_mid(v TEXT PRIMARY KEY COLLATE NOCASE);");
            FillAddresses("f_sender", f.Senders);
            FillAddresses("f_recipient", f.Recipients);
            if (f.Statuses.Count > 0)
                using (var c = Command("INSERT OR IGNORE INTO f_status(id) SELECT id FROM status WHERE name=@n"))
                {
                    var n = c.Parameters.Add("@n", SqliteType.Text);
                    foreach (string s in f.Statuses) { n.Value = s; c.ExecuteNonQuery(); }
                }
            if (f.MessageIds.Count > 0)
                using (var c = Command("INSERT OR IGNORE INTO f_mid(v) VALUES(@v)"))
                {
                    var v = c.Parameters.Add("@v", SqliteType.Text);
                    foreach (string s in f.MessageIds) { v.Value = s; c.ExecuteNonQuery(); }
                }

            var where = new List<string> { "m.received_ms >= @s", "m.received_ms < @e" };
            string senderCond = "(m.sender IN (SELECT id FROM f_sender) OR EXISTS (SELECT 1 FROM f_sender_like p JOIN address a ON a.id = m.sender WHERE a.address LIKE p.p ESCAPE '\\'))";
            string recipientCond = "(d.recipient IN (SELECT id FROM f_recipient) OR EXISTS (SELECT 1 FROM f_recipient_like p JOIN address a ON a.id = d.recipient WHERE a.address LIKE p.p ESCAPE '\\'))";
            if (f.Senders.Count > 0 && f.Recipients.Count > 0) where.Add(f.OrMode ? "(" + senderCond + " OR " + recipientCond + ")" : senderCond + " AND " + recipientCond);
            else if (f.Senders.Count > 0) where.Add(senderCond);
            else if (f.Recipients.Count > 0) where.Add(recipientCond);
            if (f.Statuses.Count > 0) where.Add("d.status IN (SELECT id FROM f_status)");
            if (f.MessageIds.Count > 0) where.Add("m.message_id IN (SELECT v FROM f_mid)");
            if (!string.IsNullOrEmpty(f.Subject)) where.Add("mtr_match(m.subject, @op, @subject)");
            if (!string.IsNullOrEmpty(f.FromIP)) where.Add("m.from_ip = @fromip COLLATE NOCASE");
            if (!string.IsNullOrEmpty(f.ToIP)) where.Add("d.to_ip = @toip COLLATE NOCASE");

            using (var c = Command("INSERT OR IGNORE INTO sel(message, recipient) SELECT d.message, d.recipient FROM message m JOIN delivery d ON d.message = m.id WHERE " + string.Join(" AND ", where)))
            {
                c.CommandTimeout = 0;
                c.Parameters.AddWithValue("@s", startMs); c.Parameters.AddWithValue("@e", endMs);
                if (!string.IsNullOrEmpty(f.Subject))
                {
                    string op = (f.SubjectMatch ?? "Contains").ToLowerInvariant();
                    c.Parameters.AddWithValue("@op", op == "equals" ? "eq" : op);
                    c.Parameters.AddWithValue("@subject", f.Subject);
                }
                if (!string.IsNullOrEmpty(f.FromIP)) c.Parameters.AddWithValue("@fromip", f.FromIP);
                if (!string.IsNullOrEmpty(f.ToIP)) c.Parameters.AddWithValue("@toip", f.ToIP);
                c.ExecuteNonQuery();
            }
            return new SelectionResult { Deliveries = Scalar("SELECT count(*) FROM sel"), Messages = Scalar("SELECT count(DISTINCT message) FROM sel") };
        }

        void FillAddresses(string table, List<string> filters)
        {
            using (var exact = Command("INSERT OR IGNORE INTO " + table + "(id) SELECT id FROM address WHERE address=@a"))
            using (var like = Command("INSERT INTO " + table + "_like(p) VALUES(@p)"))
            {
                var a = exact.Parameters.Add("@a", SqliteType.Text);
                var p = like.Parameters.Add("@p", SqliteType.Text);
                foreach (string filter in filters)
                {
                    if (Address.IsPattern(filter)) { p.Value = Address.ToLike(filter); like.ExecuteNonQuery(); }
                    else { a.Value = filter; exact.ExecuteNonQuery(); }
                }
            }
        }

        /// <summary>The selection, newest message first; the deliveries of a message are consecutive.</summary>
        public IEnumerable<DeliveryView> ReadSelection()
        {
            using (var c = Command(@"SELECT m.id, m.trace_id, m.received_ms, sa.address, m.subject, m.message_id, m.from_ip, d.recipient, ra.address, st.name, d.size, d.to_ip
FROM sel s JOIN message m ON m.id = s.message JOIN delivery d ON d.message = s.message AND d.recipient = s.recipient
LEFT JOIN address sa ON sa.id = m.sender LEFT JOIN address ra ON ra.id = d.recipient LEFT JOIN status st ON st.id = d.status
ORDER BY m.received_ms DESC, m.id DESC"))
            {
                c.CommandTimeout = 0;
                using (var r = c.ExecuteReader())
                {
                    while (r.Read())
                    {
                        yield return new DeliveryView
                        {
                            MessageRowId = r.GetInt64(0), TraceId = TraceText(r.IsDBNull(1) ? null : (byte[])r.GetValue(1)), ReceivedMs = r.GetInt64(2),
                            Sender = r.IsDBNull(3) ? "" : r.GetString(3), Subject = r.IsDBNull(4) ? "" : r.GetString(4), MessageId = r.IsDBNull(5) ? "" : r.GetString(5),
                            FromIP = r.IsDBNull(6) ? "" : r.GetString(6), RecipientId = r.GetInt64(7), Recipient = r.IsDBNull(8) ? "" : r.GetString(8),
                            Status = r.IsDBNull(9) ? "" : r.GetString(9), Size = r.IsDBNull(10) ? 0 : r.GetInt64(10), ToIP = r.IsDBNull(11) ? "" : r.GetString(11)
                        };
                    }
                }
            }
        }

        /// <summary>
        /// Deliveries of the selection whose route should be read: not delivered first, then the newest; the
        /// routes already read since the last change of the delivery are skipped.
        /// </summary>
        public List<DetailItem> GetDetailCandidates(int max, bool onlyProblems)
        {
            var list = new List<DetailItem>();
            if (max <= 0) return list;
            string sql = @"SELECT m.id, d.recipient, m.trace_id, ra.address
FROM sel s JOIN message m ON m.id = s.message JOIN delivery d ON d.message = s.message AND d.recipient = s.recipient
JOIN address ra ON ra.id = d.recipient LEFT JOIN status st ON st.id = d.status
LEFT JOIN detail_fetch f ON f.message = d.message AND f.recipient = d.recipient
WHERE (f.fetched_ms IS NULL OR f.fetched_ms < d.updated_ms) AND ra.address <> ''" + (onlyProblems ? " AND coalesce(st.name,'') NOT IN ('delivered','expanded')" : "") + @"
ORDER BY CASE WHEN coalesce(st.name,'') IN ('delivered','expanded') THEN 1 ELSE 0 END, m.received_ms DESC LIMIT @n";
            using (var c = Command(sql))
            {
                c.Parameters.AddWithValue("@n", max);
                using (var r = c.ExecuteReader())
                    while (r.Read())
                        list.Add(new DetailItem { MessageRowId = r.GetInt64(0), RecipientId = r.GetInt64(1), TraceId = TraceText((byte[])r.GetValue(2)), Recipient = r.GetString(3) });
            }
            return list;
        }

        /// <summary>Route events of the selection, by "message|recipient" row ids.</summary>
        public Dictionary<string, List<DetailRow>> GetSelectionDetails()
        {
            var map = new Dictionary<string, List<DetailRow>>(StringComparer.Ordinal);
            using (var c = Command("SELECT x.message, x.recipient, x.time_ms, x.event, x.action, x.description, x.data FROM detail x JOIN sel s ON s.message = x.message AND s.recipient = x.recipient ORDER BY x.message, x.recipient, x.seq"))
            using (var r = c.ExecuteReader())
            {
                while (r.Read())
                {
                    string key = r.GetInt64(0).ToString(CultureInfo.InvariantCulture) + "|" + r.GetInt64(1).ToString(CultureInfo.InvariantCulture);
                    List<DetailRow> rows;
                    if (!map.TryGetValue(key, out rows)) { rows = new List<DetailRow>(); map[key] = rows; }
                    rows.Add(new DetailRow
                    {
                        TimeMs = r.IsDBNull(2) ? 0 : r.GetInt64(2), Event = r.IsDBNull(3) ? "" : r.GetString(3), Action = r.IsDBNull(4) ? "" : r.GetString(4),
                        Description = r.IsDBNull(5) ? "" : r.GetString(5), Data = r.IsDBNull(6) ? "" : r.GetString(6)
                    });
                }
            }
            return map;
        }

        // ---- status ---------------------------------------------------------------------------------

        public StoreStatistics GetStatistics()
        {
            var s = new StoreStatistics
            {
                Messages = Scalar("SELECT count(*) FROM message"),
                Deliveries = Scalar("SELECT count(*) FROM delivery"),
                Addresses = Scalar("SELECT count(*) FROM address"),
                Signatures = Scalar("SELECT count(*) FROM signature WHERE EXISTS (SELECT 1 FROM coverage c WHERE c.signature = signature.id)"),
                CoverageRows = Scalar("SELECT count(*) FROM coverage"),
                Runs = Scalar("SELECT count(*) FROM run"),
                DetailEvents = Scalar("SELECT count(*) FROM detail"),
                FileBytes = FileBytes
            };
            if (s.Messages > 0)
            {
                s.FirstReceivedMs = Scalar("SELECT min(received_ms) FROM message");
                s.LastReceivedMs = Scalar("SELECT max(received_ms) FROM message");
            }
            long last = Scalar("SELECT coalesce(max(ended_ms),0) FROM run WHERE mode IN ('Collect','Trace') AND status IN ('Succeeded','Incomplete')");
            if (last > 0) s.LastCollectMs = last;
            return s;
        }

        /// <summary>Per local day: messages in the database and coverage of one signature ('' = the whole tenant).</summary>
        public List<DayStatistics> GetDailyStatistics(DateTime firstLocalDate, int days, TimeZoneInfo zone, string signature, long settlingMs)
        {
            var list = new List<DayStatistics>();
            for (int i = 0; i < days; i++)
            {
                DateTime d = firstLocalDate.Date.AddDays(i);
                list.Add(new DayStatistics { LocalDate = d, StartMs = Time.LocalToUnixMs(d, zone), EndMs = Time.LocalToUnixMs(d.AddDays(1), zone) });
            }
            if (list.Count == 0) return list;
            long from = list[0].StartMs, to = list[list.Count - 1].EndMs;
            // 15-minute buckets: every real time zone offset is a multiple of 15 minutes.
            using (var c = Command("SELECT received_ms / 900000, count(*) FROM message WHERE received_ms >= @f AND received_ms < @t GROUP BY 1"))
            {
                c.Parameters.AddWithValue("@f", from); c.Parameters.AddWithValue("@t", to);
                using (var r = c.ExecuteReader())
                    while (r.Read())
                    {
                        long ms = r.GetInt64(0) * 900000;
                        foreach (DayStatistics d in list) if (ms >= d.StartMs && ms < d.EndMs) { d.Messages += r.GetInt64(1); break; }
                    }
            }
            List<TimeRange> all = GetCoverage(signature, -1), settled = GetCoverage(signature, settlingMs);
            foreach (DayStatistics d in list)
            {
                d.CoveredMs = (d.EndMs - d.StartMs) - Coverage.Gaps(all, d.StartMs, d.EndMs).Sum(g => g.Length);
                d.SettledMs = (d.EndMs - d.StartMs) - Coverage.Gaps(settled, d.StartMs, d.EndMs).Sum(g => g.Length);
            }
            return list;
        }

        // ---- maintenance -----------------------------------------------------------------------------

        /// <summary>Deletes what was received before cutoffMs, and the coverage before it.</summary>
        public PurgeResult PurgeBefore(long cutoffMs)
        {
            var p = new PurgeResult();
            using (var tx = _db.BeginTransaction())
            {
                Func<string, long> run = sql => { using (var c = Command(sql, tx)) { c.CommandTimeout = 0; c.Parameters.AddWithValue("@c", cutoffMs); return c.ExecuteNonQuery(); } };
                p.Details = run("DELETE FROM detail WHERE message IN (SELECT id FROM message WHERE received_ms < @c)");
                run("DELETE FROM detail_fetch WHERE message IN (SELECT id FROM message WHERE received_ms < @c)");
                p.Deliveries = run("DELETE FROM delivery WHERE message IN (SELECT id FROM message WHERE received_ms < @c)");
                p.Messages = run("DELETE FROM message WHERE received_ms < @c");
                p.Coverage = run("DELETE FROM coverage WHERE end_ms <= @c");
                run("UPDATE coverage SET start_ms = @c WHERE start_ms < @c");
                run("DELETE FROM run WHERE started_ms < @c - 0");
                if (p.Messages > 0)
                    p.Addresses = run("DELETE FROM address WHERE NOT EXISTS (SELECT 1 FROM message WHERE sender = address.id) AND NOT EXISTS (SELECT 1 FROM delivery WHERE recipient = address.id)");
                tx.Commit();
            }
            if (p.Messages > 0)
            {
                _addresses.Clear();
                Exec("PRAGMA incremental_vacuum;");
            }
            return p;
        }

        public void Dispose()
        {
            try { if (!ReadOnly) Exec("PRAGMA optimize;"); } catch { }
            _db.Dispose();
        }
    }
}
