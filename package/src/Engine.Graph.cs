// =============================================================================
//  Message Trace Report - engine, part 3: Microsoft Graph collection
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 1.1.0
//
//  Throughput is bounded by Microsoft, not by the tool: 100 requests per 5 minutes and
//  per tenant (rolling window), 5,000 rows per request. A page of 5,000 rows takes
//  about 2 to 4 seconds, so two or three concurrent requests are enough to use the whole
//  quota. What matters is to send as few requests as possible (Engine.Plan.cs) and to
//  never waste one on a 429.
//
//    TokenSlot      access token shared by the workers; the module refreshes it
//    RateLimiter    rolling-window budget shared by the workers (and by the next run)
//    GraphClient    one GET with retries: 429 (Retry-After), 401, 5xx, timeouts
//    Collector      workers -> pages -> one writer thread -> SQLite (Store.CommitPage)
//    DetailCollector  getDetailsByRecipient (route of a message), its own quota
// =============================================================================
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace MessageTraceReport
{
    /// <summary>One row of the Graph answer (exchangeMessageTrace): one message for one recipient.</summary>
    public sealed class TraceRow
    {
        public string Id, MessageId, Sender, Recipient, Subject, Status, FromIP, ToIP;
        public long ReceivedMs, Size;
    }

    /// <summary>One event of getDetailsByRecipient.</summary>
    public sealed class DetailRow
    {
        public long TimeMs;
        public string Event, Action, Description, Data;
    }

    public sealed class TokenLease { public string Token; public int Version; }

    /// <summary>
    /// Access token shared by the workers. The module (PowerShell) owns the authentication: it reads
    /// <see cref="NeedsRefresh"/> while the collection runs and calls <see cref="Set"/>.
    /// </summary>
    public sealed class TokenSlot
    {
        readonly object _lock = new object();
        string _token;
        long _expiresMs;
        int _version;
        bool _refreshRequested;

        public long ExpiresMs { get { lock (_lock) return _expiresMs; } }
        public int Version { get { lock (_lock) return _version; } }

        public void Set(string token, long expiresMs)
        {
            lock (_lock) { _token = token; _expiresMs = expiresMs; _version++; _refreshRequested = false; }
        }

        /// <summary>True when the token is missing, expires within marginMs, or a worker got a 401.</summary>
        public bool NeedsRefresh(long marginMs)
        {
            lock (_lock) return _token == null || _refreshRequested || Time.NowMs() > _expiresMs - marginMs;
        }

        /// <summary>A worker got a 401 with this token version: ask the module for a new one (once per version).</summary>
        public void RequestRefresh(int version)
        {
            lock (_lock) { if (version == _version) _refreshRequested = true; }
        }

        public async Task<TokenLease> GetAsync(CancellationToken ct, int timeoutSeconds = 180)
        {
            long deadline = Time.NowMs() + timeoutSeconds * 1000L;
            while (true)
            {
                lock (_lock)
                {
                    if (_token != null && !_refreshRequested && Time.NowMs() < _expiresMs - 30000) return new TokenLease { Token = _token, Version = _version };
                }
                if (Time.NowMs() > deadline) throw new FatalCollectionException("No valid access token: the token could not be renewed in time.");
                await Task.Delay(200, ct).ConfigureAwait(false);
            }
        }
    }

    /// <summary>
    /// Rolling-window budget: at most MaxRequests requests in any PeriodMs, shared by every worker.
    /// The quota is per tenant: a 429 pauses every worker (Retry-After), and the timestamps of the last
    /// window are saved in the database so that the next run starts with what is already used.
    /// </summary>
    public sealed class RateLimiter
    {
        readonly object _lock = new object();
        readonly Queue<long> _stamps = new Queue<long>();
        long _pauseUntil;
        long _waitedMs;
        public readonly int MaxRequests;
        public readonly long PeriodMs;

        public RateLimiter(int maxRequests, long periodMs, IEnumerable<long> previousStamps = null)
        {
            MaxRequests = Math.Max(1, maxRequests);
            PeriodMs = Math.Max(1000, periodMs);
            if (previousStamps != null)
            {
                long now = Time.NowMs();
                foreach (long s in previousStamps.Where(x => x > now - PeriodMs && x <= now).OrderBy(x => x)) _stamps.Enqueue(s);
            }
        }

        public long WaitedMs { get { return Interlocked.Read(ref _waitedMs); } }

        public int InWindow
        {
            get { lock (_lock) { Purge(Time.NowMs()); return _stamps.Count; } }
        }

        public long PausedUntil { get { lock (_lock) return _pauseUntil; } }

        void Purge(long now) { while (_stamps.Count > 0 && _stamps.Peek() <= now - PeriodMs) _stamps.Dequeue(); }

        /// <summary>Time to wait before the next request could start (0 = now).</summary>
        public long DelayMs()
        {
            lock (_lock)
            {
                long now = Time.NowMs();
                Purge(now);
                if (now < _pauseUntil) return _pauseUntil - now;
                if (_stamps.Count < MaxRequests) return 0;
                return Math.Max(1, _stamps.Peek() + PeriodMs - now);
            }
        }

        public async Task WaitAsync(CancellationToken ct)
        {
            while (true)
            {
                long delay;
                lock (_lock)
                {
                    long now = Time.NowMs();
                    Purge(now);
                    if (now >= _pauseUntil && _stamps.Count < MaxRequests) { _stamps.Enqueue(now); return; }
                    delay = now < _pauseUntil ? _pauseUntil - now : _stamps.Peek() + PeriodMs - now + 20;
                }
                int step = (int)Math.Max(10, Math.Min(delay, 1000));
                Interlocked.Add(ref _waitedMs, step);
                await Task.Delay(step, ct).ConfigureAwait(false);
            }
        }

        /// <summary>Every worker waits until now + ms (429 from Graph).</summary>
        public void Pause(long ms)
        {
            lock (_lock) { _pauseUntil = Math.Max(_pauseUntil, Time.NowMs() + ms); }
        }

        public long[] Stamps()
        {
            lock (_lock) { Purge(Time.NowMs()); return _stamps.ToArray(); }
        }
    }

    public sealed class CollectorOptions
    {
        public string GraphRoot = "https://graph.microsoft.com/v1.0";
        public int PageSize = 5000;
        public int MaxConcurrency = 3;
        public int MaxRetries = 5;              // 5xx, timeouts, network errors
        public int MaxThrottleRetries = 20;     // 429
        public int TimeoutSeconds = 180;
        public int DefaultRetryAfterSeconds = 30;
        public string UserAgent = "MessageTraceReport/1.1.0";
        public HttpMessageHandler Handler;      // tests: a fake Graph
    }

    public sealed class CollectorEvent
    {
        public long Ms = Time.NowMs();
        public string Level;   // INFO | WARN | ERROR
        public string Text;
    }

    /// <summary>An error that stops the whole collection (permissions, service principal, token).</summary>
    public sealed class FatalCollectionException : Exception
    {
        public int Status;
        public FatalCollectionException(string message, int status = 0) : base(message) { Status = status; }
    }

    /// <summary>An error that fails one work item only (bad filter, too old ...).</summary>
    public sealed class ItemFailureException : Exception
    {
        public int Status;
        public bool Unrecoverable;
        public ItemFailureException(string message, int status, bool unrecoverable = false) : base(message) { Status = status; Unrecoverable = unrecoverable; }
    }

    /// <summary>One GET to Graph with the quota, the token and the retries.</summary>
    public sealed class GraphClient : IDisposable
    {
        readonly HttpClient _http;
        readonly CollectorOptions _o;
        readonly TokenSlot _token;
        readonly RateLimiter _limiter;
        readonly ConcurrentQueue<CollectorEvent> _events;
        public long Requests, Throttled, Retries, Bytes;

        public GraphClient(CollectorOptions o, TokenSlot token, RateLimiter limiter, ConcurrentQueue<CollectorEvent> events)
        {
            _o = o; _token = token; _limiter = limiter; _events = events;
            HttpMessageHandler handler = o.Handler ?? new SocketsHttpHandler
            {
                AutomaticDecompression = DecompressionMethods.All,
                PooledConnectionLifetime = TimeSpan.FromMinutes(5),
                MaxConnectionsPerServer = Math.Max(2, o.MaxConcurrency + 1)
            };
            _http = new HttpClient(handler, o.Handler == null) { Timeout = Timeout.InfiniteTimeSpan };
            _http.DefaultRequestHeaders.UserAgent.ParseAdd(o.UserAgent);
            _http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        }

        void Event(string level, string text) { _events.Enqueue(new CollectorEvent { Level = level, Text = text }); }

        public static string GraphError(string body)
        {
            if (string.IsNullOrEmpty(body)) return "";
            try
            {
                using (JsonDocument doc = JsonDocument.Parse(body))
                {
                    JsonElement e;
                    if (doc.RootElement.TryGetProperty("error", out e))
                    {
                        string code = e.TryGetProperty("code", out JsonElement c) ? c.GetString() : "";
                        string message = e.TryGetProperty("message", out JsonElement m) ? m.GetString() : "";
                        return (string.IsNullOrEmpty(code) ? "" : code + ": ") + message;
                    }
                }
            }
            catch { }
            return Text.Shorten(body.Replace("\r", " ").Replace("\n", " "), 300);
        }

        public async Task<string> GetAsync(string url, string what, CancellationToken ct)
        {
            int attempt = 0, throttles = 0, authRetries = 0;
            while (true)
            {
                ct.ThrowIfCancellationRequested();
                await _limiter.WaitAsync(ct).ConfigureAwait(false);
                TokenLease lease = await _token.GetAsync(ct).ConfigureAwait(false);
                var request = new HttpRequestMessage(HttpMethod.Get, url);
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", lease.Token);
                request.Headers.Add("client-request-id", Guid.NewGuid().ToString());
                HttpResponseMessage response = null;
                string body = null;
                string failure = null;
                using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct))
                {
                    timeout.CancelAfter(TimeSpan.FromSeconds(_o.TimeoutSeconds));
                    try
                    {
                        response = await _http.SendAsync(request, HttpCompletionOption.ResponseContentRead, timeout.Token).ConfigureAwait(false);
                        body = await response.Content.ReadAsStringAsync().ConfigureAwait(false);
                    }
                    catch (OperationCanceledException) when (!ct.IsCancellationRequested) { failure = "no answer after " + _o.TimeoutSeconds + " s"; }
                    catch (HttpRequestException ex) { failure = ex.Message; }
                    finally { request.Dispose(); }
                }
                Interlocked.Increment(ref Requests);
                if (failure != null)
                {
                    if (++attempt > _o.MaxRetries) throw new ItemFailureException(what + ": " + failure + " (after " + _o.MaxRetries + " retries)", 0);
                    Interlocked.Increment(ref Retries);
                    int wait = Math.Min(60, 1 << attempt);
                    Event("WARN", what + ": " + failure + " - retry " + attempt + "/" + _o.MaxRetries + " in " + wait + " s");
                    await Task.Delay(wait * 1000, ct).ConfigureAwait(false);
                    continue;
                }
                int status = (int)response.StatusCode;
                Interlocked.Add(ref Bytes, body == null ? 0 : body.Length);
                if (status == 200) { response.Dispose(); return body; }

                string error = GraphError(body);
                if (status == 429)
                {
                    Interlocked.Increment(ref Throttled);
                    long waitMs = _o.DefaultRetryAfterSeconds * 1000L * Math.Min(4, throttles + 1);
                    if (response.Headers.RetryAfter != null)
                    {
                        if (response.Headers.RetryAfter.Delta.HasValue) waitMs = (long)response.Headers.RetryAfter.Delta.Value.TotalMilliseconds + 1000;
                        else if (response.Headers.RetryAfter.Date.HasValue) waitMs = Math.Max(1000, (long)(response.Headers.RetryAfter.Date.Value - DateTimeOffset.UtcNow).TotalMilliseconds + 1000);
                    }
                    response.Dispose();
                    if (++throttles > _o.MaxThrottleRetries) throw new ItemFailureException(what + ": still throttled after " + _o.MaxThrottleRetries + " waits (429). Another tool may be using the message trace quota of the tenant.", 429);
                    _limiter.Pause(waitMs);
                    Event("WARN", "Throttled by Microsoft Graph (429): every request waits " + Math.Round(waitMs / 1000.0) + " s. " + error);
                    continue;
                }
                response.Dispose();
                if (status == 401)
                {
                    if (error.IndexOf("8bd644d1-64a1-4d4b-ae52-2e0cbf64e373", StringComparison.OrdinalIgnoreCase) >= 0 || error.IndexOf("service principal", StringComparison.OrdinalIgnoreCase) >= 0)
                        throw new FatalCollectionException("The service principal of the Microsoft message trace application (8bd644d1-64a1-4d4b-ae52-2e0cbf64e373) is missing or not provisioned yet in the tenant. Create it once (guide, chapter 'Application'); provisioning can take several hours. Graph: " + error, 401);
                    if (++authRetries > 2) throw new FatalCollectionException("Access denied (401) with a renewed token: " + error, 401);
                    _token.RequestRefresh(lease.Version);
                    Event("WARN", "401 from Microsoft Graph: renewing the access token. " + error);
                    continue;
                }
                if (status == 403)
                    throw new FatalCollectionException("Permission denied (403): the application or the account needs ExchangeMessageTrace.Read.All (with admin consent). Graph: " + error, 403);
                if (status == 400)
                {
                    bool tooOld = error.IndexOf("90 days", StringComparison.OrdinalIgnoreCase) >= 0;
                    throw new ItemFailureException(what + ": request refused (400) - " + error, 400, tooOld);
                }
                if (status == 408 || status >= 500)
                {
                    if (++attempt > _o.MaxRetries) throw new ItemFailureException(what + ": HTTP " + status + " after " + _o.MaxRetries + " retries - " + error, status);
                    Interlocked.Increment(ref Retries);
                    int wait = Math.Min(60, 1 << attempt);
                    Event("WARN", what + ": HTTP " + status + " - retry " + attempt + "/" + _o.MaxRetries + " in " + wait + " s. " + error);
                    await Task.Delay(wait * 1000, ct).ConfigureAwait(false);
                    continue;
                }
                if (status == 404) throw new ItemFailureException(what + ": HTTP 404 (the request may be too long) - " + error, 404);
                throw new ItemFailureException(what + ": HTTP " + status + " - " + error, status);
            }
        }

        public void Dispose() { _http.Dispose(); }
    }

    /// <summary>One page handed by a worker to the writer.</summary>
    sealed class PageResult
    {
        public WorkItem Item;
        public List<TraceRow> Rows;
        public bool Last;
        public bool Ordered;
        public long OldestMs;
        public long FetchedMs;
        public string Error;
        public bool Unrecoverable;
    }

    public static class TraceParser
    {
        static string Str(JsonElement e, string name)
        {
            JsonElement v;
            if (!e.TryGetProperty(name, out v) || v.ValueKind == JsonValueKind.Null) return "";
            return v.ValueKind == JsonValueKind.String ? v.GetString() : v.ToString();
        }

        /// <summary>Rows and @odata.nextLink of one page.</summary>
        public static List<TraceRow> Parse(string body, out string nextLink)
        {
            var rows = new List<TraceRow>();
            nextLink = null;
            using (JsonDocument doc = JsonDocument.Parse(body))
            {
                JsonElement root = doc.RootElement, value, next;
                if (root.TryGetProperty("@odata.nextLink", out next) && next.ValueKind == JsonValueKind.String) nextLink = next.GetString();
                if (!root.TryGetProperty("value", out value) || value.ValueKind != JsonValueKind.Array) throw new FormatException("The Graph answer has no 'value' array.");
                foreach (JsonElement e in value.EnumerateArray())
                {
                    var r = new TraceRow
                    {
                        Id = Str(e, "id"), MessageId = Str(e, "messageId"), Sender = Str(e, "senderAddress"), Recipient = Str(e, "recipientAddress"),
                        Subject = Str(e, "subject"), Status = Str(e, "status"), FromIP = Str(e, "fromIP"), ToIP = Str(e, "toIP")
                    };
                    long ms;
                    if (!Time.TryParse(Str(e, "receivedDateTime"), out ms)) throw new FormatException("receivedDateTime not readable for trace " + r.Id + ".");
                    r.ReceivedMs = ms;
                    JsonElement size;
                    if (e.TryGetProperty("size", out size) && size.ValueKind == JsonValueKind.Number) r.Size = size.GetInt64();
                    rows.Add(r);
                }
            }
            return rows;
        }

        public static List<DetailRow> ParseDetails(string body, out string nextLink)
        {
            var rows = new List<DetailRow>();
            nextLink = null;
            using (JsonDocument doc = JsonDocument.Parse(body))
            {
                JsonElement root = doc.RootElement, value, next;
                if (root.TryGetProperty("@odata.nextLink", out next) && next.ValueKind == JsonValueKind.String) nextLink = next.GetString();
                if (!root.TryGetProperty("value", out value) || value.ValueKind != JsonValueKind.Array) throw new FormatException("The Graph answer has no 'value' array.");
                foreach (JsonElement e in value.EnumerateArray())
                {
                    long ms;
                    Time.TryParse(Str(e, "dateTime"), out ms);
                    rows.Add(new DetailRow { TimeMs = ms, Event = Str(e, "event"), Action = Str(e, "action"), Description = Str(e, "description"), Data = Str(e, "data") });
                }
            }
            return rows;
        }
    }

    /// <summary>
    /// Runs the work items: MaxConcurrency workers send the requests, one writer thread stores the pages
    /// (the SQLite connection is never shared between threads). Cancelling keeps what was stored.
    /// </summary>
    public sealed class Collector
    {
        readonly Store _store;
        readonly CollectorOptions _o;
        readonly TokenSlot _token;
        readonly RateLimiter _limiter;
        readonly long _runId;
        List<WorkItem> _items = new List<WorkItem>();
        GraphClient _graph;
        CancellationTokenSource _stop;

        public readonly ConcurrentQueue<CollectorEvent> Events = new ConcurrentQueue<CollectorEvent>();
        public long Pages, Rows, NewMessages, NewDeliveries, UpdatedDeliveries, ItemsDone, ItemsFailed, ItemsRunning;
        public string Fatal;
        public int FatalStatus;
        public long StartedMs, EndedMs;

        public Collector(Store store, CollectorOptions options, TokenSlot token, RateLimiter limiter, long runId)
        {
            _store = store; _o = options; _token = token; _limiter = limiter; _runId = runId;
        }

        public long Requests { get { return _graph == null ? 0 : Interlocked.Read(ref _graph.Requests); } }
        public long Throttled { get { return _graph == null ? 0 : Interlocked.Read(ref _graph.Throttled); } }
        public long Retries { get { return _graph == null ? 0 : Interlocked.Read(ref _graph.Retries); } }
        public long Bytes { get { return _graph == null ? 0 : Interlocked.Read(ref _graph.Bytes); } }
        public int ItemCount { get { return _items.Count; } }

        /// <summary>Share of the planned work done, from the time already covered in every window.</summary>
        public double Progress
        {
            get
            {
                if (_items.Count == 0) return 1.0;
                double sum = 0;
                foreach (WorkItem i in _items) sum += i.State == "Failed" ? 1.0 : i.Fraction;
                return sum / _items.Count;
            }
        }

        void Event(string level, string text) { Events.Enqueue(new CollectorEvent { Level = level, Text = text }); }

        public Task RunAsync(List<WorkItem> items, CancellationToken ct)
        {
            _items = items;
            // Signatures are created on this (calling) thread, before the writer owns the connection.
            var ids = new Dictionary<string, long>(StringComparer.Ordinal);
            foreach (WorkItem i in items)
            {
                long id;
                if (!ids.TryGetValue(i.Query.Signature, out id)) { id = _store.GetSignatureId(i.Query.Signature, i.Query.Label); ids[i.Query.Signature] = id; }
                i.SignatureId = id;
            }
            return Task.Run(() => Run(ct));
        }

        async Task Run(CancellationToken ct)
        {
            StartedMs = Time.NowMs();
            using (var stop = CancellationTokenSource.CreateLinkedTokenSource(ct))
            using (_graph = new GraphClient(_o, _token, _limiter, Events))
            using (var pages = new BlockingCollection<PageResult>(Math.Max(2, _o.MaxConcurrency * 2)))
            {
                _stop = stop;
                var queue = new ConcurrentQueue<WorkItem>(_items);
                Task writer = Task.Factory.StartNew(() => Write(pages), CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
                var workers = new List<Task>();
                for (int w = 0; w < Math.Max(1, _o.MaxConcurrency); w++) workers.Add(Task.Run(() => Work(queue, pages, stop)));
                try { await Task.WhenAll(workers).ConfigureAwait(false); }
                catch { }
                pages.CompleteAdding();
                await writer.ConfigureAwait(false);
                foreach (WorkItem i in _items) if (i.State == "Pending" || i.State == "Running") i.State = "Cancelled";
            }
            EndedMs = Time.NowMs();
        }

        async Task Work(ConcurrentQueue<WorkItem> queue, BlockingCollection<PageResult> pages, CancellationTokenSource stop)
        {
            WorkItem item;
            while (!stop.IsCancellationRequested && queue.TryDequeue(out item))
            {
                item.State = "Running";
                Interlocked.Increment(ref ItemsRunning);
                string what = item.Query.Label + " [" + Time.GraphTime(item.StartMs, false) + " -> " + Time.GraphTime(item.EndMs, true) + "]";
                string url = _o.GraphRoot + "/admin/exchange/tracing/messageTraces?$filter=" + Text.EncodeQuery(item.Query.ODataFilter(item.StartMs, item.EndMs)) + "&$top=" + _o.PageSize.ToString(CultureInfo.InvariantCulture);
                long previousOldest = long.MaxValue;
                bool ordered = true;
                try
                {
                    while (url != null)
                    {
                        string body = await _graph.GetAsync(url, what, stop.Token).ConfigureAwait(false);
                        long fetched = Time.NowMs();
                        string next;
                        List<TraceRow> rows = TraceParser.Parse(body, out next);
                        long oldest = long.MaxValue;
                        foreach (TraceRow r in rows)
                        {
                            if (r.ReceivedMs > previousOldest) ordered = false;   // the API is expected to return the newest first
                            if (r.ReceivedMs < oldest) oldest = r.ReceivedMs;
                        }
                        if (rows.Count > 0) { previousOldest = Math.Min(previousOldest, oldest); item.OldestMs = Math.Max(item.StartMs, previousOldest); }
                        Interlocked.Increment(ref Pages);
                        Interlocked.Add(ref Rows, rows.Count);
                        pages.Add(new PageResult { Item = item, Rows = rows, Last = next == null, Ordered = ordered, OldestMs = rows.Count > 0 ? oldest : 0, FetchedMs = fetched });
                        url = next;
                    }
                }
                catch (FatalCollectionException ex)
                {
                    Fatal = ex.Message; FatalStatus = ex.Status;
                    Event("ERROR", ex.Message);
                    item.State = "Failed"; item.Error = ex.Message;
                    stop.Cancel();
                }
                catch (ItemFailureException ex)
                {
                    pages.Add(new PageResult { Item = item, Error = ex.Message, Unrecoverable = ex.Unrecoverable, Rows = new List<TraceRow>() });
                }
                catch (OperationCanceledException) { }
                catch (Exception ex)
                {
                    pages.Add(new PageResult { Item = item, Error = what + ": " + ex.Message, Rows = new List<TraceRow>() });
                }
                finally { Interlocked.Decrement(ref ItemsRunning); }
            }
        }

        void Write(BlockingCollection<PageResult> pages)
        {
            foreach (PageResult p in pages.GetConsumingEnumerable())
            {
                WorkItem item = p.Item;
                try
                {
                    if (p.Error != null)
                    {
                        item.State = "Failed"; item.Error = p.Error;
                        Interlocked.Increment(ref ItemsFailed);
                        Event(p.Unrecoverable ? "WARN" : "ERROR", p.Error);
                        continue;
                    }
                    IngestResult r = _store.CommitPage(item, p.Rows, p.Last, p.Ordered, p.OldestMs, p.FetchedMs, _runId);
                    Interlocked.Add(ref NewMessages, r.NewMessages);
                    Interlocked.Add(ref NewDeliveries, r.NewDeliveries);
                    Interlocked.Add(ref UpdatedDeliveries, r.UpdatedDeliveries);
                    item.Pages++;
                    item.Rows += p.Rows.Count;
                    if (p.Last) { item.State = "Done"; Interlocked.Increment(ref ItemsDone); }
                }
                catch (Exception ex)
                {
                    // A database error is fatal: nothing more can be stored.
                    Fatal = "Database error: " + ex.Message;
                    item.State = "Failed"; item.Error = Fatal;
                    Event("ERROR", Fatal);
                    try { _stop.Cancel(); } catch (ObjectDisposedException) { }
                    foreach (PageResult rest in pages.GetConsumingEnumerable()) { }
                    return;
                }
            }
        }

        public long[] LimiterStamps() { return _limiter.Stamps(); }
    }

    /// <summary>One delivery whose route is read with getDetailsByRecipient.</summary>
    public sealed class DetailItem
    {
        public long MessageRowId;
        public long RecipientId;
        public string TraceId;
        public string Recipient;
        public string Kind = "Problem";   // Problem | Comparison (a delivered recipient of a message with a problem) | Delivered
        public string State = "Pending";
        public string Error;
        public int Events;
    }

    /// <summary>Route events (Receive, Deliver, Fail ...) of a few deliveries. Separate quota of 100 requests / 5 min.</summary>
    public sealed class DetailCollector
    {
        readonly Store _store;
        readonly CollectorOptions _o;
        readonly TokenSlot _token;
        readonly RateLimiter _limiter;
        GraphClient _graph;
        List<DetailItem> _items = new List<DetailItem>();
        public readonly ConcurrentQueue<CollectorEvent> Events = new ConcurrentQueue<CollectorEvent>();
        public long Done, Failed, EventsStored;
        public string Fatal;

        public DetailCollector(Store store, CollectorOptions options, TokenSlot token, RateLimiter limiter)
        {
            _store = store; _o = options; _token = token; _limiter = limiter;
        }

        public long Requests { get { return _graph == null ? 0 : Interlocked.Read(ref _graph.Requests); } }
        public long Throttled { get { return _graph == null ? 0 : Interlocked.Read(ref _graph.Throttled); } }
        public double Progress { get { return _items.Count == 0 ? 1.0 : (double)(Interlocked.Read(ref Done) + Interlocked.Read(ref Failed)) / _items.Count; } }

        public Task RunAsync(List<DetailItem> items, CancellationToken ct)
        {
            _items = items;
            return Task.Run(() => Run(ct));
        }

        async Task Run(CancellationToken ct)
        {
            using (var stop = CancellationTokenSource.CreateLinkedTokenSource(ct))
            using (_graph = new GraphClient(_o, _token, _limiter, Events))
            using (var results = new BlockingCollection<Tuple<DetailItem, List<DetailRow>>>(Math.Max(2, _o.MaxConcurrency * 2)))
            {
                var queue = new ConcurrentQueue<DetailItem>(_items);
                Task writer = Task.Factory.StartNew(() =>
                {
                    foreach (var r in results.GetConsumingEnumerable())
                    {
                        try { _store.SaveDetails(r.Item1.MessageRowId, r.Item1.RecipientId, r.Item2); r.Item1.State = "Done"; r.Item1.Events = r.Item2.Count; Interlocked.Increment(ref Done); Interlocked.Add(ref EventsStored, r.Item2.Count); }
                        catch (Exception ex) { r.Item1.State = "Failed"; r.Item1.Error = ex.Message; Interlocked.Increment(ref Failed); }
                    }
                }, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
                var workers = new List<Task>();
                for (int w = 0; w < Math.Max(1, _o.MaxConcurrency); w++)
                {
                    workers.Add(Task.Run(async () =>
                    {
                        DetailItem item;
                        while (!stop.IsCancellationRequested && queue.TryDequeue(out item))
                        {
                            string url = _o.GraphRoot + "/admin/exchange/tracing/messageTraces/" + Uri.EscapeDataString(item.TraceId)
                                + "/getDetailsByRecipient(recipientAddress=" + Uri.EscapeDataString(Text.ODataString(item.Recipient)) + ")";
                            var rows = new List<DetailRow>();
                            try
                            {
                                while (url != null)
                                {
                                    string body = await _graph.GetAsync(url, "Route of " + item.Recipient, stop.Token).ConfigureAwait(false);
                                    string next;
                                    rows.AddRange(TraceParser.ParseDetails(body, out next));
                                    url = next;
                                }
                                results.Add(Tuple.Create(item, rows));
                            }
                            catch (FatalCollectionException ex) { Fatal = ex.Message; item.State = "Failed"; item.Error = ex.Message; Interlocked.Increment(ref Failed); Events.Enqueue(new CollectorEvent { Level = "ERROR", Text = ex.Message }); stop.Cancel(); }
                            catch (OperationCanceledException) { }
                            catch (Exception ex) { item.State = "Failed"; item.Error = ex.Message; Interlocked.Increment(ref Failed); Events.Enqueue(new CollectorEvent { Level = "WARN", Text = ex.Message }); }
                        }
                    }));
                }
                try { await Task.WhenAll(workers).ConfigureAwait(false); } catch { }
                results.CompleteAdding();
                await writer.ConfigureAwait(false);
            }
        }
    }
}
