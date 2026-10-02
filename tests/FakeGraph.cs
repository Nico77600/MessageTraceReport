// =============================================================================
//  Message Trace Report - tests: in-memory Microsoft Graph message trace API
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 1.1.0
//
//  An HttpMessageHandler given to the engine (CollectorOptions.Handler). It answers like the real
//  API measured in the lab on 2026-10-02:
//    - $filter keeps ONE value per property (the last one), everything combined with AND;
//      'or' between two values of a property keeps the last value;
//    - '*@domain' matches a domain; subject: eq, contains, startswith, endswith (case-insensitive);
//    - newest first; $top 1-5000 (default 1000); @odata.nextLink with $skiptoken;
//    - receivedDateTime: both bounds required ('ge' and 'le'), at most 10 days, not older than 90 days;
//    - getDetailsByRecipient: the events of the real routes (Receive, Submit, Deliver, Fail, Defer, Spam,
//      Expand, Drop, DLP rule) with their XML data, per status (see Route).
//  Failures can be injected: 429 (Retry-After), 401, 500, 403, missing service principal.
// =============================================================================
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace MtrTests
{
    public sealed class FakeTrace
    {
        public string Id, MessageId, Sender, Recipient, Subject, Status = "delivered", FromIP = "", ToIP = "";
        public DateTimeOffset Received;
        public long Size = 1000;
    }

    public sealed class FakeGraph : HttpMessageHandler
    {
        public readonly List<FakeTrace> Rows = new List<FakeTrace>();
        public readonly List<string> Requests = new List<string>();
        public readonly List<string> Tokens = new List<string>();
        public int ThrottleNext, UnauthorizedNext, ServerErrorNext, RetryAfterSeconds = 1, DelayMs;
        public bool Forbidden, MissingServicePrincipal;
        public DateTimeOffset Now = DateTimeOffset.UtcNow;
        public int Served;

        static readonly Regex Cond = new Regex(@"(senderAddress|recipientAddress|status|messageId|fromIP|toIP|subject) eq '((?:[^']|'')*)'", RegexOptions.Compiled);
        static readonly Regex Func = new Regex(@"(contains|startswith|endswith)\(subject, '((?:[^']|'')*)'\)", RegexOptions.Compiled | RegexOptions.IgnoreCase);

        /// <summary>Adds one message to several recipients.</summary>
        public void AddMessage(string sender, string[] recipients, DateTimeOffset received, string subject, string status = "delivered", string[] statuses = null)
        {
            string id = Guid.NewGuid().ToString();
            string messageId = "<" + Guid.NewGuid().ToString("N") + "@contoso.com>";
            for (int i = 0; i < recipients.Length; i++)
                Rows.Add(new FakeTrace { Id = id, MessageId = messageId, Sender = sender, Recipient = recipients[i], Subject = subject, Received = received, Status = statuses != null ? statuses[i] : status, FromIP = "10.0.0.1", Size = 1000 + i });
        }

        static HttpResponseMessage Json(HttpStatusCode code, string json)
        {
            return new HttpResponseMessage(code) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
        }

        static string Mep(params string[] pairs)
        {
            var sb = new StringBuilder("<root>");
            for (int i = 0; i + 2 < pairs.Length; i += 3) sb.Append("<MEP Name=\"" + pairs[i] + "\" " + pairs[i + 1] + "=\"" + WebUtility.HtmlEncode(pairs[i + 2]) + "\" />");
            return sb.Append("</root>").ToString();
        }

        /// <summary>
        /// Route of one delivery, shaped like the real events (lab, 2026-10-02): delivered, failed (recipient
        /// 'dlp*' or sender 'payroll*': blocked by a DLP rule, the Fail returned BEFORE the rule within the same
        /// second, as the service does; 'all-staff*': delivery restrictions; 'etr*' or subject 'Contract':
        /// rejected by a mail flow rule; *@wingtiptoys.com: refused by the remote server; others: 5.1.10),
        /// pending (Defer 4.4.317), quarantined (Spam + Deliver to the quarantine), filtered as spam (Junk
        /// Email folder), expanded (Expand DL + Drop 2.1.5).
        /// </summary>
        public static List<object> Route(FakeTrace t)
        {
            var list = new List<object>();
            Action<int, string, string, string, string> add = (seconds, ev, action, description, data) =>
                list.Add(new { id = t.Id, messageId = t.MessageId, dateTime = t.Received.AddSeconds(seconds).UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", CultureInfo.InvariantCulture), @event = ev, action = action, description = description, data = data });
            add(0, "Receive", "", "Message received by: EXCH01.contoso.com", Mep("ConnectorId", "String", "EXCH01\\Default EXCH01", "ClientIP", "String", "10.0.0.1", "ServerHostName", "String", "EXCH01.contoso.com",
                "CustomData", "Blob", "S:ProxyHop1=EOP01.mail.protection.outlook.com(10.1.1.1);S:tlsversion=SP_PROT_TLS1_3_SERVER;S:tlscipher=CALG_AES_256", "SequenceNumber", "Long", "0"));
            switch (t.Status)
            {
                case "quarantined":
                    add(5, "Spam", "Quarantine", "Spam confidence level: 8", Mep("SourceContext", "String", "AgentDefer - Antispam Quarantine Agent", "DI", "String", "SQ", "SCL", "Integer", "8", "SFV", "String", "SPM", "CIP", "String", "192.0.2.25"));
                    add(6, "Deliver", "", "The message was successfully delivered to the folder: DefaultFolderType:QuarantinedEmailSecured", Mep("MailboxServer", "String", "MBX01.contoso.com", "RecipientStatus", "String", "DefaultFolderType:QuarantinedEmailSecured-Mailbox Delivery Filter Agent"));
                    return list;
                case "filteredAsSpam":
                    add(4, "Spam", "", "Spam confidence level: 6", Mep("DI", "String", "SJ", "SCL", "Integer", "6", "SFV", "String", "SPM", "CIP", "String", "192.0.2.25"));
                    add(5, "Deliver", "", "The message was successfully delivered to the folder: DefaultFolderType:JunkEmail", Mep("MailboxServer", "String", "MBX01.contoso.com"));
                    return list;
            }
            add(1, "Submit", "", "The message was submitted.", Mep("RcptCount", "Integer", "3", "ServerHostName", "String", "EXCH01.contoso.com"));
            switch (t.Status)
            {
                case "failed":
                    if (t.Recipient.StartsWith("dlp", StringComparison.OrdinalIgnoreCase) || t.Sender.StartsWith("payroll", StringComparison.OrdinalIgnoreCase))
                    {
                        add(2, "Fail", "", "Reason: [{LED=550 5.7.171 Delivery not authorized, message refused};{MSG=};{FQDN=};{IP=};{LRT=}]", Mep("ServerHostName", "String", "EXCH02.contoso.com", "SourceContext", "String", "DLP Policy Agent"));
                        add(2, "DLP rule", "BA", "DLP rule: 'Block credit cards', ID: ('f43f7263-2730-4217-aea6-e7a68a7951ec'), DLP policy: 'Financial data', ID: (0b6c9a2e-1d3f-4e5a-9b7c-8d6e5f4a3b2c).", Mep("RcptCount", "Integer", "1", "SourceContext", "String", "CatContentConversion"));
                    }
                    else if (t.Recipient.StartsWith("all-staff", StringComparison.OrdinalIgnoreCase))
                        add(2, "Fail", "", "Reason: [{LED=550 5.7.1 RESOLVER.RST.NotAuthorized; not authorized};{MSG=};{FQDN=};{IP=};{LRT=}]", Mep("ServerHostName", "String", "EXCH02.contoso.com"));
                    else if (t.Recipient.StartsWith("etr", StringComparison.OrdinalIgnoreCase) || (t.Subject ?? "").IndexOf("Contract", StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        add(2, "Transport rule", "", "Transport rule: 'Block external contracts', ID: ('9d0c4b1e-7a2f-4c3d-8e5b-6f1a2b3c4d5e'), DLP policy: '', ID: (00000000-0000-0000-0000-000000000000).", Mep("RcptCount", "Integer", "1", "SourceContext", "String", "Transport Rule Agent"));
                        add(2, "Fail", "", "Reason: [{LED=550 5.7.1 TRANSPORT.RULES.RejectMessage; the message was rejected by organization policy};{MSG=};{FQDN=};{IP=};{LRT=}]", Mep("ServerHostName", "String", "EXCH02.contoso.com", "SourceContext", "String", "Transport Rule Agent"));
                    }
                    else if (t.Recipient.EndsWith("@wingtiptoys.com", StringComparison.OrdinalIgnoreCase))
                    {
                        add(2, "Send external", "", "Message sent to mx.wingtiptoys.com at 203.0.113.5 using TLS1.2", Mep("ServerHostName", "String", "EXCH02.contoso.com"));
                        add(3, "Fail", "", "Reason: [{LED=550 5.1.1 <" + t.Recipient + ">: Recipient address rejected: User unknown in virtual mailbox table};{MSG=550 5.1.1 User unknown};{FQDN=mx.wingtiptoys.com};{IP=203.0.113.5};{LRT=}]", Mep("ServerHostName", "String", "EXCH02.contoso.com", "IsSmtpResponseFromExternalServer", "String", "True"));
                    }
                    else add(2, "Fail", "", "Reason: [{LED=550 5.1.10 RESOLVER.ADR.RecipientNotFound; Recipient not found by SMTP address lookup};{MSG=};{FQDN=};{IP=};{LRT=}]", Mep("ServerHostName", "String", "EXCH02.contoso.com"));
                    break;
                case "pending":
                    add(130, "Defer", "", "Reason: [{LED=450 4.4.317 Cannot connect to remote server [Message=SocketError: TimedOut] [LastAttemptedServerName=mx.fabrikam.com] [LastAttemptedIP=192.0.2.10:25]};{MSG=};{FQDN=mx.fabrikam.com};{IP=192.0.2.10};{LRT=}]", Mep("ServerHostName", "String", "EXCH02.contoso.com"));
                    break;
                case "expanded":
                    add(1, "Expand DL", "", "The message was sent to a distribution list (DL) that was expanded to the recipients of the DL.", Mep("RcptCount", "Integer", "4"));
                    add(1, "Drop", "", "Reason: [{LED=250 2.1.5 RESOLVER.GRP.Expanded; distribution list expanded};{MSG=};{FQDN=};{IP=};{LRT=}]", Mep("SourceContext", "String", "CatCleanup"));
                    break;
                default:
                    add(2, "Deliver", "", "The message was successfully delivered.", Mep("MailboxServer", "String", "MBX01.contoso.com", "TotalLatency", "Integer", "2"));
                    break;
            }
            return list;
        }

        static HttpResponseMessage Error(HttpStatusCode code, string message)
        {
            return Json(code, JsonSerializer.Serialize(new { error = new { code = code == HttpStatusCode.BadRequest ? "BadRequest" : "Error", message = message } }));
        }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            string url = Uri.UnescapeDataString(request.RequestUri.PathAndQuery);
            lock (Requests) { Requests.Add(url); Tokens.Add(request.Headers.Authorization == null ? "" : request.Headers.Authorization.Parameter); }
            if (DelayMs > 0) await Task.Delay(DelayMs, ct);
            if (Forbidden) return Error(HttpStatusCode.Forbidden, "Authorization_RequestDenied");
            if (MissingServicePrincipal) return Error(HttpStatusCode.Unauthorized, "Service principal-less authentication failed: The service principal for App ID 8bd644d1-64a1-4d4b-ae52-2e0cbf64e373 was not found.");
            if (Interlocked.Decrement(ref ThrottleNext) >= 0)
            {
                var r = Error((HttpStatusCode)429, "Your recent queries have surpassed the permitted limit, please try again later.");
                r.Headers.RetryAfter = new System.Net.Http.Headers.RetryConditionHeaderValue(TimeSpan.FromSeconds(RetryAfterSeconds));
                return r;
            }
            if (Interlocked.Decrement(ref UnauthorizedNext) >= 0) return Error(HttpStatusCode.Unauthorized, "InvalidAuthenticationToken: token expired");
            if (Interlocked.Decrement(ref ServerErrorNext) >= 0) return Error(HttpStatusCode.InternalServerError, "Transient failure");

            Match detail = Regex.Match(url, @"/messageTraces/([^/]+)/getDetailsByRecipient\(recipientAddress='((?:[^']|'')*)'\)");
            if (detail.Success)
            {
                string id = detail.Groups[1].Value, rcpt = detail.Groups[2].Value.Replace("''", "'");
                FakeTrace t = Rows.FirstOrDefault(x => x.Id == id && string.Equals(x.Recipient, rcpt, StringComparison.OrdinalIgnoreCase));
                if (t == null) return Json(HttpStatusCode.OK, "{\"value\":[]}");
                return Json(HttpStatusCode.OK, JsonSerializer.Serialize(new { value = Route(t) }));
            }

            string query = request.RequestUri.Query.TrimStart('?');
            var args = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (string part in query.Split('&')) { int eq = part.IndexOf('='); if (eq > 0) args[Uri.UnescapeDataString(part.Substring(0, eq))] = Uri.UnescapeDataString(part.Substring(eq + 1)); }
            string filter = args.ContainsKey("$filter") ? args["$filter"] : "";
            int top = args.ContainsKey("$top") ? int.Parse(args["$top"], CultureInfo.InvariantCulture) : 1000;
            if (top == 0) top = 1000;
            if (top < 1 || top > 5000) return Error(HttpStatusCode.BadRequest, "ResultSize is invalid");
            int skip = args.ContainsKey("$skiptoken") ? int.Parse(args["$skiptoken"], CultureInfo.InvariantCulture) : 0;

            Match ge = Regex.Match(filter, @"receivedDateTime ge (\S+)"), le = Regex.Match(filter, @"receivedDateTime le (\S+)");
            DateTimeOffset start = Now.AddDays(-2), end = Now;
            if (ge.Success && !le.Success) return Error(HttpStatusCode.BadRequest, "EndDate is required when a StartDate is entered.");
            if (ge.Success)
            {
                start = DateTimeOffset.Parse(ge.Groups[1].Value, CultureInfo.InvariantCulture);
                end = DateTimeOffset.Parse(le.Groups[1].Value, CultureInfo.InvariantCulture);
                if (end - start > TimeSpan.FromDays(10).Add(TimeSpan.FromSeconds(1))) return Error(HttpStatusCode.BadRequest, "|System.ArgumentException|The interval between StartDate and EndDate can't be longer than 10 days.");
                if (start.UtcDateTime.Date < Now.UtcDateTime.Date.AddDays(-90)) return Error(HttpStatusCode.BadRequest, "Invalid StartDate value. The StartDate can't be older than 90 days from today.");
            }
            // One value per property: the last one wins (like the real API).
            var values = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (Match m in Cond.Matches(filter)) values[m.Groups[1].Value] = m.Groups[2].Value.Replace("''", "'");
            string op = null, text = null;
            foreach (Match m in Func.Matches(filter)) { op = m.Groups[1].Value.ToLowerInvariant(); text = m.Groups[2].Value.Replace("''", "'"); }
            Func<string, string, bool> addr = (value, f) => f.StartsWith("*@") ? (value ?? "").EndsWith(f.Substring(1), StringComparison.OrdinalIgnoreCase) : string.Equals(value, f, StringComparison.OrdinalIgnoreCase);
            IEnumerable<FakeTrace> rows = Rows.Where(r => r.Received >= start && r.Received <= end);
            // One local per condition: the LINQ filters run later, a shared variable would hold the last value.
            string vs, vr, vst, vm, vf, vt, vj;
            if (values.TryGetValue("senderAddress", out vs)) rows = rows.Where(r => addr(r.Sender, vs));
            if (values.TryGetValue("recipientAddress", out vr)) rows = rows.Where(r => addr(r.Recipient, vr));
            if (values.TryGetValue("status", out vst)) rows = rows.Where(r => string.Equals(r.Status, vst, StringComparison.OrdinalIgnoreCase));
            if (values.TryGetValue("messageId", out vm)) rows = rows.Where(r => string.Equals(r.MessageId, vm, StringComparison.OrdinalIgnoreCase));
            if (values.TryGetValue("fromIP", out vf)) rows = rows.Where(r => r.FromIP == vf);
            if (values.TryGetValue("toIP", out vt)) rows = rows.Where(r => r.ToIP == vt);
            if (values.TryGetValue("subject", out vj)) rows = rows.Where(r => string.Equals(r.Subject, vj, StringComparison.OrdinalIgnoreCase));
            if (op == "contains") rows = rows.Where(r => (r.Subject ?? "").IndexOf(text, StringComparison.OrdinalIgnoreCase) >= 0);
            if (op == "startswith") rows = rows.Where(r => (r.Subject ?? "").StartsWith(text, StringComparison.OrdinalIgnoreCase));
            if (op == "endswith") rows = rows.Where(r => (r.Subject ?? "").EndsWith(text, StringComparison.OrdinalIgnoreCase));
            List<FakeTrace> all = rows.OrderByDescending(r => r.Received).ThenBy(r => r.Id, StringComparer.Ordinal).ThenBy(r => r.Recipient, StringComparer.Ordinal).ToList();
            List<FakeTrace> page = all.Skip(skip).Take(top).ToList();
            Interlocked.Increment(ref Served);
            var body = new Dictionary<string, object>
            {
                { "@odata.context", "https://graph.microsoft.com/v1.0/$metadata#admin/exchange/tracing/messageTraces" },
                { "value", page.Select(r => new Dictionary<string, object> {
                    { "id", r.Id }, { "messageId", r.MessageId }, { "status", r.Status }, { "receivedDateTime", r.Received.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", CultureInfo.InvariantCulture) },
                    { "recipientAddress", r.Recipient }, { "senderAddress", r.Sender }, { "subject", r.Subject }, { "size", r.Size }, { "fromIP", r.FromIP }, { "toIP", r.ToIP } }).ToList() }
            };
            if (skip + top < all.Count)
            {
                string baseUrl = request.RequestUri.GetLeftPart(UriPartial.Path);
                body["@odata.nextLink"] = baseUrl + "?$filter=" + Uri.EscapeDataString(filter) + "&$top=" + top + "&$skiptoken=" + (skip + top);
            }
            return Json(HttpStatusCode.OK, JsonSerializer.Serialize(body));
        }
    }
}
