// =============================================================================
//  Message Trace Report - engine, part 6: message route
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 1.1.0
//
//  getDetailsByRecipient returns the events of one message for one recipient (Receive,
//  Submit, Deliver, Fail, Defer, Drop, Expand DL, DLP rule, Spam ...), each with a
//  description and an XML 'data' field:
//      <root><MEP Name="ServerHostName" String="..."/><MEP Name="TotalLatency" Integer="2"/> ...</root>
//  Measured in the lab (2026-10-02, lab\evidence\route-probes.json):
//    - the reason of Fail / Defer / Drop is in the description and in the RecipientStatus fact:
//        [{LED=554 5.2.2 mailbox full; STOREDRV.Deliver.Exception:...};{MSG=};{FQDN=};{IP=};{LRT=}]
//    - Drop "250 2.1.5 RESOLVER.GRP.Expanded" is the normal end of the copy of a distribution group;
//    - events of the same second are not always in order (Fail before the DLP rules): within a
//      second, the steps are ordered by their logical phase (receive, submit, rules, delivery, drop).
//  This file turns them into readable steps: kind, facts with labels, reason with its code and the
//  Microsoft Learn page, a signature to group the recipients that followed the same route.
// =============================================================================
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;

namespace MessageTraceReport
{
    /// <summary>Why a delivery failed, was deferred or ended (parsed from LED=... or RecipientStatus).</summary>
    public sealed class ReasonInfo
    {
        public string Raw = "";        // the whole reason as returned
        public string Smtp = "";       // 554
        public string Code = "";       // 5.2.2 (enhanced status code)
        public string Text = "";       // mailbox full
        public string Detail = "";     // STOREDRV.Deliver.Exception:QuotaExceededException...
        public string Severity = "";   // Permanent | Temporary | Information
        public string RemoteHost = ""; // FQDN=, LastAttemptedServerName=
        public string RemoteIp = "";   // IP=, LastAttemptedIP=
        public string RemoteMessage = ""; // MSG=
        public string Component = "";  // SourceContext of the event: DLP Policy Agent, Transport Rule Agent ...
        public string DocTitle = "";   // what Microsoft Learn says about the code
        public string DocUrl = "";

        /// <summary>One line: 554 5.2.2 mailbox full.</summary>
        public string Short
        {
            get
            {
                string head = (Smtp + " " + Code).Trim();
                if (string.IsNullOrEmpty(Text)) return string.IsNullOrEmpty(head) ? MessageTraceReport.Text.Shorten(Raw, 160) : head;
                return (head + " " + Text).Trim();
            }
        }

        public string Key { get { return (Code + "|" + Text + "|" + Component).ToLowerInvariant(); } }
    }

    /// <summary>One step of the route of a message for one recipient.</summary>
    public sealed class RouteEvent
    {
        public long TimeMs;
        public string Event = "", Action = "", Description = "";
        public string Kind = "other";   // received, submitted, sent, delivered, failed, deferred, dropped, expanded, redirected, rule, spam, malware, label, other
        public string Tone = "neutral"; // success, danger, warning, info, neutral
        public string Help = "";        // what the event means
        public string Folder = "";      // Deliver: folder of the mailbox (Inbox, Junk Email, Quarantine ...)
        public List<KeyValuePair<string, string>> Facts = new List<KeyValuePair<string, string>>();   // label -> value
        public ReasonInfo Reason;
        public string Data = "";        // raw XML
    }

    public sealed class RouteInfo
    {
        public List<RouteEvent> Events = new List<RouteEvent>();
        public string Signature = "";  // grouping key: kinds, actions and codes, no time or server
        public string Summary = "";    // Receive > Submit > Fail (554 5.2.2)
        public ReasonInfo Reason;      // the reason that decided the status of the delivery (or null)
        public string Outcome = "";    // Delivered | Delivered to Junk Email | Failed | Deferred | Expanded | ...
        public CauseInfo Cause;        // why the delivery did not end in the inbox (null when it did)
        public long FirstMs, LastMs;
        public string Server = "";     // last Exchange Online server that handled the message
    }

    /// <summary>
    /// Category of the reason, in plain words: Blocked by DLP, Blocked by mail flow rule (ETR), Recipient not
    /// found, Mailbox full, Quarantined ... with the rule that decided when the route names it.
    /// </summary>
    public sealed class CauseInfo
    {
        public string Id = "";         // dlp, etr, not-found ... (stable, for scripts)
        public string Label = "";      // Blocked by DLP
        public string Tone = "danger"; // danger (failed), warning (delayed, dropped), spam (quarantine, junk)
        public string Help = "";       // what it means and where to look
        public string Rule = "";       // rule 'Block credit cards' | rule ID f43f7263-...

        /// <summary>Label with the rule: Blocked by DLP (rule ID f43f7263-...).</summary>
        public string Text { get { return Rule.Length > 0 ? Label + " (" + Rule + ")" : Label; } }
    }

    public static class RouteAnalyzer
    {
        public const string NdrPage = "https://learn.microsoft.com/exchange/mail-flow-best-practices/non-delivery-reports-in-exchange-online/non-delivery-reports-in-exchange-online";
        const string NdrBase = "https://learn.microsoft.com/exchange/mail-flow-best-practices/non-delivery-reports-in-exchange-online/";

        // Microsoft Learn, "Email nondelivery reports and SMTP errors in Exchange Online" (2026-10-02): code -> title, page.
        static readonly Dictionary<string, string[]> Codes = new Dictionary<string, string[]>(StringComparer.Ordinal)
        {
            { "2.1.5", new[] { "Distribution group expanded: each member gets its own copy (normal)", "" } },
            { "4.3.2", new[] { "Recipient thread limit exceeded: the mailbox receives too many messages too quickly", "" } },
            { "4.4.7", new[] { "Message expired in the queue", "fix-error-code-550-4-4-7-in-exchange-online" } },
            { "4.4.8", new[] { "MX hosts of the domain failed MTA-STS validation", "" } },
            { "4.4.316", new[] { "Connection refused by the destination server", "" } },
            { "4.4.317", new[] { "Cannot connect to the remote server (connection or TLS)", "" } },
            { "4.5.3", new[] { "Too many recipients", "" } },
            { "4.7.26", new[] { "A message sent over IPv6 must pass SPF or DKIM", "" } },
            { "5.0.350", new[] { "Generic error from the recipient's organization", "fix-error-code-550-5-0-350-in-exchange-online" } },
            { "5.1.0", new[] { "Sender denied", "fix-error-code-550-5-1-0-in-exchange-online" } },
            { "5.1.1", new[] { "Bad destination mailbox address", "fix-error-code-550-5-1-1-through-5-1-20-in-exchange-online" } },
            { "5.1.8", new[] { "Access denied, bad outbound sender (account blocked for spam)", "" } },
            { "5.1.10", new[] { "Recipient not found", "fix-error-code-550-5-1-10-in-exchange-online" } },
            { "5.1.20", new[] { "Multiple From addresses are not allowed without Sender address", "" } },
            { "5.2.2", new[] { "Mailbox full, or submission quota exceeded", "" } },
            { "5.2.121", new[] { "Recipient's per hour message receive limit from this sender exceeded", "" } },
            { "5.2.122", new[] { "Recipient's per hour message receive limit exceeded", "" } },
            { "5.4.1", new[] { "Relay access denied, or recipient address rejected", "" } },
            { "5.4.6", new[] { "Routing loop detected", "fix-error-code-5-4-6-through-5-4-20-in-exchange-online" } },
            { "5.4.14", new[] { "Routing loop detected", "fix-error-code-5-4-6-through-5-4-20-in-exchange-online" } },
            { "5.4.300", new[] { "Message expired", "" } },
            { "5.5.0", new[] { "Requested action not taken: mailbox unavailable", "" } },
            { "5.6.11", new[] { "Invalid characters", "fix-error-code-550-5-6-11-in-exchange-online" } },
            { "5.7.1", new[] { "Delivery not authorized, unable to relay, or client not authenticated", "fix-error-code-550-5-7-1-in-exchange-online" } },
            { "5.7.12", new[] { "Sender was not authenticated by organization", "fix-error-code-5-7-12-in-exchange-online" } },
            { "5.7.13", new[] { "Sender was not authenticated for public folder", "fix-error-code-5-7-13-or-5-7-135-in-exchange-online" } },
            { "5.7.23", new[] { "Rejected because of a Sender Policy Framework (SPF) violation", "fix-error-code-5-7-23-in-exchange-online" } },
            { "5.7.25", new[] { "The sending IPv6 address must have a reverse DNS record", "" } },
            { "5.7.57", new[] { "Client was not authenticated to send anonymous mail", "fix-error-code-5-7-57-in-exchange-online" } },
            { "5.7.64", new[] { "TenantAttribution; relay access denied", "fix-error-code-5-7-64-in-exchange-online" } },
            { "5.7.124", new[] { "Sender not in the allowed-senders list of the group", "fix-error-code-5-7-124-in-exchange-online" } },
            { "5.7.133", new[] { "Sender not authenticated for group", "fix-error-code-5-7-133-in-exchange-online" } },
            { "5.7.134", new[] { "Sender was not authenticated for mailbox", "fix-error-code-5-7-134-in-exchange-online" } },
            { "5.7.135", new[] { "Sender was not authenticated for public folder", "fix-error-code-5-7-13-or-5-7-135-in-exchange-online" } },
            { "5.7.136", new[] { "Sender was not authenticated", "fix-error-code-5-7-136-in-exchange-online" } },
            { "5.7.232", new[] { "Trial tenant exceeded its daily limit of external recipients", "" } },
            { "5.7.233", new[] { "Tenant exceeded its daily limit of external recipients", "" } },
            { "5.7.236", new[] { "Tenant exceeded its daily limit of external recipients from onmicrosoft.com domains", "" } },
            { "5.7.321", new[] { "Destination mail server must support TLS", "" } },
            { "5.7.322", new[] { "Destination mail server's certificate is expired", "" } },
            { "5.7.323", new[] { "The domain failed DANE validation", "" } },
            { "5.7.324", new[] { "Destination domain returned invalid DNSSEC records", "" } },
            { "5.7.325", new[] { "Remote certificate does not match the host name (DANE)", "" } },
            { "5.7.367", new[] { "Remote server returned not permitted to relay", "" } },
            { "5.7.501", new[] { "Access denied, spam abuse detected", "" } },
            { "5.7.502", new[] { "Access denied, banned sender", "" } },
            { "5.7.503", new[] { "Access denied, banned sender", "" } },
            { "5.7.504", new[] { "Recipient address rejected: access denied", "" } },
            { "5.7.505", new[] { "Access denied, banned recipient", "" } },
            { "5.7.506", new[] { "Access denied, bad HELO", "" } },
            { "5.7.507", new[] { "Access denied, rejected by recipient", "" } },
            { "5.7.508", new[] { "Access denied, the sending IP exceeded permitted limits", "" } },
            { "5.7.509", new[] { "Sending domain does not pass DMARC and has a reject policy", "" } },
            { "5.7.510", new[] { "The recipient domain does not accept email over IPv6", "" } },
            { "5.7.511", new[] { "Access denied, banned sender", "" } },
            { "5.7.512", new[] { "Message must be RFC 5322 section 3.6.2 compliant", "" } },
            { "5.7.513", new[] { "Client host blocked by the recipient domain (customer block list)", "" } },
            { "5.7.520", new[] { "Your organization does not allow external forwarding", "" } },
            { "5.7.703", new[] { "Blocked by your organization in the Tenant Allow/Block List", "" } },
            { "5.7.705", new[] { "Access denied, tenant has exceeded threshold", "fix-error-code-5-7-700-through-5-7-750" } },
            { "5.7.708", new[] { "Access denied, traffic not accepted from this IP", "fix-error-code-5-7-700-through-5-7-750" } },
            { "5.7.750", new[] { "Client blocked from sending from unregistered domains", "fix-error-code-5-7-700-through-5-7-750" } },
            { "5.7.800", new[] { "Access denied, banned sender", "" } }
        };

        static readonly Dictionary<string, string> Labels = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            { "ServerHostName", "Server" }, { "ClientIP", "Client IP" }, { "ClientName", "Previous server" }, { "ConnectorId", "Connector" },
            { "FirstForestHop", "First server" }, { "DeliveryPriority", "Priority" }, { "ReturnPath", "Return path" }, { "RcptCount", "Recipients at this step" },
            { "TotalLatency", "Latency since received (s)" }, { "MailboxServer", "Mailbox server" }, { "SourceContext", "Component" }, { "RecipientStatus", "Status" },
            { "RelatedRecipient", "Group" }, { "RecipientReference", "Recipient reference" }, { "RcptDomainMailSvr", "Destination mail server" },
            { "OutboundProxyTargetIPAddress", "Destination IP" }, { "OutboundProxyTargetHostName", "Destination host" }, { "SCL", "Spam confidence level (SCL)" },
            { "SFV", "Spam filter verdict (SFV)" }, { "Score", "Spam score" }, { "CIP", "Connecting IP" }, { "H", "HELO / EHLO" }, { "RD", "Reverse DNS of the sender" },
            { "DI", "Spam action (DI)" }, { "Language", "Language" }, { "ComponentCost", "Component cost" }, { "tlsversion", "TLS version" }, { "tlscipher", "TLS cipher" },
            { "ProxyHop1", "Proxy hop 1" }, { "ProxyHop2", "Proxy hop 2" }, { "ProxiedClientIPAddress", "Original client IP" }, { "ProxiedClientHostname", "Original client host" },
            { "PrioritizationReason", "Prioritization reason" }, { "TransportTrafficSubType", "Traffic type" }, { "OutboundIpPoolName", "Outbound IP pool" },
            { "OutboundProxyFrontEndName", "Outbound proxy" }, { "IsSmtpResponseFromExternalServer", "Response from the remote server" },
            { "RequiredTlsAuthLevel", "Required TLS level" }, { "TenantOutboundConnectorCustomData", "Outbound connector" }, { "List", "Spam list" }
        };
        static readonly HashSet<string> Hidden = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "SequenceNumber", "OutboundIpPool" };

        static readonly Dictionary<string, string> Verdicts = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            { "BLK", "blocked sender" }, { "NSPM", "not spam" }, { "SFE", "allowed by the recipient's safe senders" }, { "SKA", "allowed sender of the anti-spam policy" },
            { "SKB", "blocked sender of the anti-spam policy" }, { "SKI", "intra-organization, not filtered" }, { "SKN", "marked not spam before filtering (mail flow rule)" },
            { "SKQ", "released from quarantine" }, { "SKS", "marked spam before filtering (mail flow rule)" }, { "SPM", "spam" }
        };

        static readonly Regex Mep = new Regex("<MEP\\s+Name=\"([^\"]*)\"\\s+(?:String|Integer|Long|Blob|Double|Bool|DateTime)=\"([^\"]*)\"", RegexOptions.Compiled);
        static readonly Regex Led = new Regex(@"LED=(.*?)\};\{MSG=(.*?)\};\{FQDN=(.*?)\};\{IP=(.*?)\};\{LRT=(.*?)\}", RegexOptions.Compiled | RegexOptions.Singleline);
        static readonly Regex Status = new Regex(@"^\s*(?<smtp>[245]\d\d)?\s*(?<code>[245]\.\d{1,3}\.\d{1,3})\s*(?<rest>.*)$", RegexOptions.Compiled | RegexOptions.Singleline);
        static readonly Regex Bracket = new Regex(@"\[(LastAttemptedServerName|LastAttemptedIP|Message)=([^\]]*)\]", RegexOptions.Compiled);
        static readonly Regex Token = new Regex(@"^[A-Za-z]+(\.[A-Za-z0-9:]+)+$", RegexOptions.Compiled);

        // ---- data ------------------------------------------------------------------------------------

        /// <summary>Facts of the XML data field, with readable labels. CustomData is split into its own facts.</summary>
        public static List<KeyValuePair<string, string>> ParseData(string xml)
        {
            var facts = new List<KeyValuePair<string, string>>();
            if (string.IsNullOrEmpty(xml)) return facts;
            foreach (Match m in Mep.Matches(xml))
            {
                string name = m.Groups[1].Value, value = WebUtility.HtmlDecode(m.Groups[2].Value);
                if (Hidden.Contains(name)) continue;
                if (string.Equals(name, "CustomData", StringComparison.OrdinalIgnoreCase)) { foreach (var kv in ParseCustomData(value)) facts.Add(kv); continue; }
                if (string.Equals(name, "SourceContext", StringComparison.OrdinalIgnoreCase))
                {
                    if (value.Equals("Unknown", StringComparison.OrdinalIgnoreCase)) continue;
                    // Deliver: "<id>;<time>;ClientSubmitTime:<time>" is a context, not a component.
                    if (value.IndexOf(';') >= 0) { facts.Add(new KeyValuePair<string, string>("Context", value)); continue; }
                }
                facts.Add(new KeyValuePair<string, string>(Label(name), FormatValue(name, value)));
            }
            return facts;
        }

        static string Label(string name)
        {
            string label;
            return Labels.TryGetValue(name, out label) ? label : name;
        }

        static string FormatValue(string name, string value)
        {
            if (string.Equals(name, "SFV", StringComparison.OrdinalIgnoreCase))
            {
                string v;
                if (Verdicts.TryGetValue(value, out v)) return value + " (" + v + ")";
            }
            if (string.Equals(name, "DI", StringComparison.OrdinalIgnoreCase))
            {
                if (value == "SQ") return "SQ (quarantine)";
                if (value == "SJ") return "SJ (junk email folder)";
                if (value == "SN") return "SN (normal delivery)";
            }
            return value;
        }

        /// <summary>"S:k=v;S:k2=v2;'S:k3=a=b;c=d'" -> facts. Long .NET names keep their last part.</summary>
        static IEnumerable<KeyValuePair<string, string>> ParseCustomData(string blob)
        {
            var parts = new List<string>();
            var sb = new StringBuilder();
            bool quoted = false;
            foreach (char ch in blob)
            {
                if (ch == '\'') { quoted = !quoted; continue; }
                if (ch == ';' && !quoted) { parts.Add(sb.ToString()); sb.Clear(); continue; }
                sb.Append(ch);
            }
            parts.Add(sb.ToString());
            foreach (string raw in parts)
            {
                string p = raw.Trim();
                if (p.Length == 0) continue;
                if (p.Length > 2 && p[1] == ':') p = p.Substring(2);
                int eq = p.IndexOf('=');
                if (eq <= 0) { yield return new KeyValuePair<string, string>("Custom data", p); continue; }
                string key = p.Substring(0, eq), value = p.Substring(eq + 1);
                int dot = key.LastIndexOf('.');
                if (dot >= 0) key = key.Substring(dot + 1);
                if (Hidden.Contains(key)) continue;
                yield return new KeyValuePair<string, string>(Label(key), value);
            }
        }

        static string Fact(string xml, string name)
        {
            if (string.IsNullOrEmpty(xml)) return "";
            foreach (Match m in Mep.Matches(xml)) if (string.Equals(m.Groups[1].Value, name, StringComparison.OrdinalIgnoreCase)) return WebUtility.HtmlDecode(m.Groups[2].Value);
            return "";
        }

        // ---- reason ----------------------------------------------------------------------------------

        /// <summary>
        /// Reason of an event: "Reason: [{LED=550 5.7.1 text};{MSG=..};{FQDN=..};{IP=..};{LRT=..}]", a bare
        /// "250 2.1.5 text", or a Defer reason cut by the service. Null when there is no status code.
        /// </summary>
        public static ReasonInfo ParseReason(string text, string component = "")
        {
            if (string.IsNullOrWhiteSpace(text)) return null;
            string body = text.Trim();
            if (body.StartsWith("Reason:", StringComparison.OrdinalIgnoreCase)) body = body.Substring(7).Trim();
            var r = new ReasonInfo { Raw = body, Component = component ?? "" };
            string status = body;
            Match led = Led.Match(body);
            if (led.Success)
            {
                status = led.Groups[1].Value;
                r.RemoteMessage = led.Groups[2].Value.Trim();
                r.RemoteHost = led.Groups[3].Value.Trim();
                r.RemoteIp = led.Groups[4].Value.Trim();
            }
            else
            {
                int i = body.IndexOf("LED=", StringComparison.OrdinalIgnoreCase);
                if (i >= 0) status = body.Substring(i + 4);   // cut by the service (long Defer reasons)
            }
            status = status.Trim().TrimStart('[', '{').Trim();
            Match s = Status.Match(status);
            if (!s.Success) return null;
            r.Smtp = s.Groups["smtp"].Value;
            r.Code = s.Groups["code"].Value;
            string rest = s.Groups["rest"].Value.Trim();
            // "<user@domain>: Recipient address rejected": the address is the recipient's, not part of the reason.
            rest = Regex.Replace(rest, @"^<[^<>\s]+@[^<>\s]+>:?\s*", "");
            foreach (Match b in Bracket.Matches(rest))
            {
                if (b.Groups[1].Value == "LastAttemptedServerName" && r.RemoteHost.Length == 0) r.RemoteHost = b.Groups[2].Value.Trim();
                if (b.Groups[1].Value == "LastAttemptedIP" && r.RemoteIp.Length == 0) r.RemoteIp = b.Groups[2].Value.Trim();
                if (b.Groups[1].Value == "Message" && r.RemoteMessage.Length == 0) r.RemoteMessage = b.Groups[2].Value.Trim();
            }
            // Text: up to the first ';' or '[' (the rest is diagnostic detail).
            int cut = rest.IndexOfAny(new[] { ';', '[' });
            r.Text = (cut > 0 ? rest.Substring(0, cut) : rest).Trim().TrimEnd('.', ',', '}', ']').Trim();
            r.Detail = cut > 0 ? rest.Substring(cut).Trim().TrimStart(';').Trim().TrimEnd('}', ']', ',').Trim() : "";
            // "RESOLVER.ADR.RecipientNotFound; Recipient not found by SMTP address lookup": the readable part comes second.
            if (Token.IsMatch(r.Text) && r.Detail.Length > 0)
            {
                int end = r.Detail.IndexOfAny(new[] { ';', '[' });
                string next = (end > 0 ? r.Detail.Substring(0, end) : r.Detail).Trim().TrimEnd('.', ',', '}', ']').Trim();
                if (next.IndexOf(' ') > 0)
                {
                    string token = r.Text;
                    r.Text = next;
                    r.Detail = (token + (end > 0 ? "; " + r.Detail.Substring(end).TrimStart(';').Trim() : "")).Trim();
                }
            }
            if (r.Text.Length > 200) { r.Detail = r.Text + " " + r.Detail; r.Text = Text.Shorten(r.Text, 200); }
            r.Severity = r.Code[0] == '5' ? "Permanent" : r.Code[0] == '4' ? "Temporary" : "Information";
            string[] doc;
            if (Codes.TryGetValue(r.Code, out doc))
            {
                r.DocTitle = doc[0];
                r.DocUrl = string.IsNullOrEmpty(doc[1]) ? (r.Code[0] == '2' ? "" : NdrPage) : NdrBase + doc[1];
            }
            else if (IsRange(r.Code, "5.1.", 1, 20)) { r.DocUrl = NdrBase + "fix-error-code-550-5-1-1-through-5-1-20-in-exchange-online"; }
            else if (IsRange(r.Code, "4.7.", 500, 699)) { r.DocTitle = "Access denied, please try again later (suspicious activity)"; r.DocUrl = NdrBase + "fix-error-code-451-4-7-500-699-asxxx-in-exchange-online"; }
            else if (IsRange(r.Code, "5.7.", 606, 649)) { r.DocTitle = "Access denied, banned sending IP"; r.DocUrl = NdrPage; }
            else if (IsRange(r.Code, "5.7.", 700, 750)) { r.DocUrl = NdrBase + "fix-error-code-5-7-700-through-5-7-750"; }
            else if (r.Code[0] != '2') r.DocUrl = NdrPage;
            return r;
        }

        static bool IsRange(string code, string prefix, int min, int max)
        {
            if (!code.StartsWith(prefix, StringComparison.Ordinal)) return false;
            int n;
            return int.TryParse(code.Substring(prefix.Length), NumberStyles.Integer, CultureInfo.InvariantCulture, out n) && n >= min && n <= max;
        }

        // ---- events --------------------------------------------------------------------------------------

        static void Classify(RouteEvent e)
        {
            string ev = e.Event.ToLowerInvariant();
            string act = e.Action.ToLowerInvariant();
            if (ev.StartsWith("receive")) { e.Kind = "received"; e.Help = "Received by Exchange Online"; }
            else if (ev.StartsWith("submit")) { e.Kind = "submitted"; e.Help = "Submitted to transport (recipients resolved, rules and policies applied)"; }
            else if (ev.StartsWith("deliver")) { e.Kind = "delivered"; e.Tone = "success"; e.Help = "Delivered to the mailbox"; }
            else if (ev.StartsWith("fail") || ev.Contains("badmail") || ev.Contains("poison")) { e.Kind = "failed"; e.Tone = "danger"; e.Help = "Delivery failed: the sender receives a non-delivery report (NDR)"; }
            else if (ev.StartsWith("defer")) { e.Kind = "deferred"; e.Tone = "warning"; e.Help = "Delivery delayed: Exchange Online retries later"; }
            else if (ev.StartsWith("drop")) { e.Kind = "dropped"; e.Tone = "warning"; e.Help = "Dropped without a non-delivery report"; }
            else if (ev.StartsWith("expand")) { e.Kind = "expanded"; e.Tone = "info"; e.Help = "Distribution group expanded to its members"; }
            else if (ev.StartsWith("resolve") || ev.StartsWith("redirect")) { e.Kind = "redirected"; e.Tone = "info"; e.Help = "Redirected to another address"; }
            else if (ev.StartsWith("transfer")) { e.Kind = "other"; e.Help = "Recipients moved to a separate copy of the message (bifurcation)"; }
            else if (ev.StartsWith("send")) { e.Kind = "sent"; e.Help = "Sent to the next server"; }
            else if (ev.Contains("dlp")) { e.Kind = "rule"; e.Tone = "info"; e.Help = "A DLP rule matched the message"; }
            else if (ev.Contains("transport rule") || ev.Contains("mail flow rule") || ev == "etr" || ev.StartsWith("etr ")) { e.Kind = "rule"; e.Tone = "info"; e.Help = "A mail flow (transport) rule matched the message"; }
            else if (ev.Contains("spam")) { e.Kind = "spam"; e.Tone = act.Contains("quarantine") || act.Contains("reject") ? "warning" : "info"; e.Help = "Anti-spam verdict" + (act.Length > 0 ? " (" + e.Action + ")" : ""); }
            else if (ev.Contains("malware")) { e.Kind = "malware"; e.Tone = "danger"; e.Help = "Anti-malware verdict"; }
            else if (ev.Contains("sensitivity label")) { e.Kind = "label"; e.Tone = "info"; e.Help = "A sensitivity label was applied by the service"; }
            if (e.Kind == "dropped" && e.Reason != null && e.Reason.Code == "2.1.5") { e.Tone = "info"; e.Help = "End of the copy addressed to the group: its members receive their own copy (normal)"; }
            if (e.Kind == "delivered")
            {
                int i = e.Description.IndexOf("folder:", StringComparison.OrdinalIgnoreCase);
                if (i >= 0)
                {
                    string folder = e.Description.Substring(i + 7).Trim().TrimEnd('.');
                    if (folder.StartsWith("DefaultFolderType:", StringComparison.OrdinalIgnoreCase)) folder = folder.Substring(18);
                    e.Folder = folder.IndexOf("Quarantine", StringComparison.OrdinalIgnoreCase) >= 0 ? "Quarantine" : Regex.Replace(folder, "(?<=[a-z])(?=[A-Z])", " ");
                    if (folder.IndexOf("Quarantine", StringComparison.OrdinalIgnoreCase) >= 0) { e.Tone = "warning"; e.Help = "Delivered to the quarantine"; }
                    else if (folder.IndexOf("Junk", StringComparison.OrdinalIgnoreCase) >= 0) { e.Tone = "warning"; e.Help = "Delivered to the Junk Email folder"; }
                    else e.Help = "Delivered to the folder " + e.Folder;
                }
            }
        }

        // Order of the steps within one second: the service returns events of the same second in no
        // particular order (a Fail before the DLP rule that caused it); its logical phase decides.
        static int Phase(string kind)
        {
            switch (kind)
            {
                case "received": return 0;
                case "submitted": return 1;
                case "expanded": case "redirected": return 2;
                case "rule": case "spam": case "malware": case "label": return 3;
                case "other": return 4;
                case "sent": return 5;
                case "deferred": return 6;
                case "delivered": case "failed": return 7;
                case "dropped": return 8;
                default: return 4;
            }
        }

        /// <summary>Steps of one route: in time order (within a second: logical phase, then the order of the service), classified, with facts and reasons.</summary>
        public static RouteInfo Analyze(IList<DetailRow> rows)
        {
            var info = new RouteInfo();
            if (rows == null || rows.Count == 0) return info;
            var events = new List<RouteEvent>(rows.Count);
            foreach (DetailRow r in rows)
            {
                var e = new RouteEvent { TimeMs = r.TimeMs, Event = r.Event ?? "", Action = r.Action ?? "", Description = r.Description ?? "", Data = r.Data ?? "" };
                e.Facts = ParseData(e.Data);
                string component = Fact(e.Data, "SourceContext");
                if (component.IndexOf(';') >= 0 || component.Equals("Unknown", StringComparison.OrdinalIgnoreCase) || component.Equals("CatCleanup", StringComparison.OrdinalIgnoreCase)) component = "";
                e.Reason = ParseReason(e.Description, component);
                if (e.Reason == null) e.Reason = ParseReason(Fact(e.Data, "RecipientStatus"), component);
                Classify(e);
                events.Add(e);
            }
            info.Events = events.Select((e, i) => new { e, i }).OrderBy(x => x.e.TimeMs / 1000).ThenBy(x => Phase(x.e.Kind)).ThenBy(x => x.i).Select(x => x.e).ToList();
            bool failedBefore = false;
            foreach (RouteEvent e in info.Events)
            {
                if (e.Kind == "dropped" && failedBefore) { e.Tone = "neutral"; e.Help = "Copy removed after the failure (the non-delivery report comes from the Fail step)"; }
                if (e.Kind == "failed") failedBefore = true;
            }
            info.FirstMs = info.Events[0].TimeMs;
            info.LastMs = info.Events[info.Events.Count - 1].TimeMs;
            foreach (RouteEvent e in info.Events)
            {
                string server = Fact(e.Data, "ServerHostName");
                if (server.Length == 0) server = Fact(e.Data, "MailboxServer");
                if (server.Length > 0) info.Server = server;
            }
            // The decisive event: a failure first, then a delay, a delivery, an expansion, a drop.
            RouteEvent decisive = Pick(info.Events, "failed") ?? Pick(info.Events, "deferred") ?? Pick(info.Events, "delivered") ?? Pick(info.Events, "expanded") ?? Pick(info.Events, "dropped");
            if (decisive != null)
            {
                info.Reason = decisive.Reason;
                if (decisive.Kind == "expanded" && info.Reason == null) info.Reason = info.Events.Where(x => x.Reason != null && x.Reason.Code == "2.1.5").Select(x => x.Reason).FirstOrDefault();
                switch (decisive.Kind)
                {
                    case "failed": info.Outcome = "Failed"; break;
                    case "deferred": info.Outcome = "Deferred"; break;
                    case "delivered": info.Outcome = string.IsNullOrEmpty(decisive.Folder) || decisive.Folder.Equals("Inbox", StringComparison.OrdinalIgnoreCase) ? "Delivered" : "Delivered to " + decisive.Folder; break;
                    case "expanded": info.Outcome = "Expanded"; break;
                    default: info.Outcome = "Dropped"; break;
                }
            }
            var steps = new List<string>();
            foreach (RouteEvent e in info.Events)
            {
                string step = e.Event + (e.Action.Length > 0 ? ":" + e.Action : "");
                if (steps.Count == 0 || steps[steps.Count - 1] != step) steps.Add(step);
            }
            info.Signature = string.Join(">", steps) + (info.Reason != null ? "|" + info.Reason.Code + "|" + info.Reason.Text.ToLowerInvariant() : "") + "|" + info.Outcome;
            var shown = new List<string>();
            foreach (RouteEvent e in info.Events)
            {
                string label = e.Event;
                if (shown.Count == 0 || shown[shown.Count - 1] != label) shown.Add(label);
            }
            info.Summary = string.Join(" > ", shown) + (info.Reason != null && info.Reason.Code.Length > 0 && info.Reason.Code[0] != '2' ? " (" + (info.Reason.Smtp + " " + info.Reason.Code).Trim() + ")" : "");
            info.Cause = FindCause(info, decisive);
            if (info.Cause != null && info.Cause.Id == "dlp" || info.Cause != null && info.Cause.Id.StartsWith("etr", StringComparison.Ordinal))
            {
                // The rule step that blocked the message is the decisive one: it shows in red.
                foreach (RouteEvent e in info.Events) if (e.Kind == "rule" && Blocking(e.Action)) { e.Tone = "danger"; e.Help = e.Help.Replace("matched the message", "blocked the message"); }
            }
            return info;
        }

        // ---- cause ---------------------------------------------------------------------------------------

        // id -> label, tone, help. Labels are short (table column); help says what it means and where to look.
        static readonly Dictionary<string, string[]> Causes = new Dictionary<string, string[]>(StringComparer.Ordinal)
        {
            { "dlp", new[] { "Blocked by DLP", "danger", "A Microsoft Purview data loss prevention (DLP) policy blocked the message for this recipient. Look for the rule in the Purview portal (Data loss prevention > Policies, or the DLP alerts)." } },
            { "etr", new[] { "Blocked by mail flow rule (ETR)", "danger", "A mail flow rule (transport rule) of the organization rejected the message. Look for the rule in the Exchange admin center > Mail flow > Rules." } },
            { "etr-deleted", new[] { "Deleted by mail flow rule (ETR)", "warning", "A mail flow rule deleted the message without notifying anyone (no non-delivery report)." } },
            { "etr-quarantine", new[] { "Quarantined by mail flow rule (ETR)", "spam", "A mail flow rule sent the message to the hosted quarantine. It can be released from the Microsoft Defender portal." } },
            { "policy", new[] { "Blocked by organization policy", "danger", "Rejected by a policy of the organization (mail flow rule or DLP) with the default text 'Delivery not authorized, message refused'; the route does not say which rule." } },
            { "tabl", new[] { "Blocked by Tenant Allow/Block List", "danger", "The sender, domain, IP or URL is blocked in the Tenant Allow/Block List (Microsoft Defender portal)." } },
            { "malware", new[] { "Blocked: malware", "danger", "Anti-malware found malicious content: the message was not delivered." } },
            { "malware-quarantine", new[] { "Quarantined: malware", "spam", "Anti-malware found malicious content and quarantined the message (Microsoft Defender portal)." } },
            { "spam-quarantine", new[] { "Quarantined: spam or phishing", "spam", "The anti-spam / anti-phishing verdict sent the message to quarantine. It can be released from the Microsoft Defender portal (or by the recipient if the quarantine policy allows it)." } },
            { "spam-blocked", new[] { "Blocked as spam or phishing", "danger", "Rejected or deleted by the anti-spam / anti-phishing filters." } },
            { "junk", new[] { "Junk Email folder", "spam", "Delivered, but to the Junk Email folder: anti-spam verdict or the recipient's own junk email settings." } },
            { "not-found", new[] { "Recipient not found", "danger", "The recipient address does not exist in the organization (deleted mailbox, typo, missing proxy address or accepted domain)." } },
            { "remote-not-found", new[] { "Recipient not found (remote server)", "danger", "The recipient's mail server says the address does not exist." } },
            { "mailbox-full", new[] { "Mailbox full", "danger", "The recipient's mailbox is over its quota: it receives nothing until it is cleaned or its quota raised." } },
            { "remote-mailbox-full", new[] { "Mailbox full (remote server)", "danger", "The recipient's mail server says the mailbox is full." } },
            { "restricted", new[] { "Sender not allowed by recipient", "danger", "The recipient (mailbox, group or moderated group) does not accept messages from this sender: delivery restrictions, allowed senders, authenticated senders only, moderation." } },
            { "auth", new[] { "Sender authentication failed", "danger", "The sending domain failed SPF, DKIM or DMARC checks." } },
            { "limits", new[] { "Sending limit exceeded", "danger", "A sending or receiving limit was exceeded: messages per hour to a recipient, external recipients per day, submission quota." } },
            { "sender-blocked", new[] { "Sender or IP blocked", "danger", "The sender or the sending IP is blocked: restricted user (outbound spam), banned sender, IP reputation, unregistered domain." } },
            { "forwarding", new[] { "External forwarding blocked", "danger", "Automatic forwarding to an external address is not allowed by the outbound spam policy." } },
            { "relay", new[] { "Relay denied", "danger", "The message was not allowed to relay: connector, authentication or tenant attribution problem." } },
            { "loop", new[] { "Routing loop", "danger", "The message looped between servers (connectors, MX records, forwarding)." } },
            { "network", new[] { "Destination server unreachable", "danger", "Exchange Online cannot connect to the destination server: DNS, firewall, server down or refusing connections." } },
            { "tls", new[] { "TLS or certificate problem", "danger", "Secure connection with the destination failed: TLS required, DANE / MTA-STS, expired or wrong certificate." } },
            { "expired", new[] { "Expired in queue", "danger", "The message could not be delivered before it expired (after repeated delays)." } },
            { "format", new[] { "Message size or format", "danger", "The message is too large or not valid (size limit, invalid characters, headers)." } },
            { "remote", new[] { "Rejected by remote server", "danger", "The recipient's mail server refused the message: its answer is the reason." } },
            { "deferred", new[] { "Delayed, retrying", "warning", "Delivery is delayed: Exchange Online keeps retrying." } },
            { "dropped", new[] { "Dropped without NDR", "warning", "The message was removed without a non-delivery report." } },
            { "other", new[] { "Other failure", "danger", "See the status code and text of the failure." } }
        };

        /// <summary>The causes the tool can report: id, label, tone, help (documentation, HTML legend).</summary>
        public static IEnumerable<string[]> AllCauses() { return Causes.Select(p => new[] { p.Key, p.Value[0], p.Value[1], p.Value[2] }); }

        static CauseInfo Make(string id, string rule = "")
        {
            string[] c = Causes[id];
            return new CauseInfo { Id = id, Label = c[0], Tone = c[1], Help = c[2], Rule = rule ?? "" };
        }

        static readonly Regex RuleName = new Regex(@"rule:\s*'([^']*)'\s*,\s*ID:\s*\(\s*'?([0-9A-Fa-f-]{36})?", RegexOptions.Compiled | RegexOptions.IgnoreCase);
        static readonly Regex PolicyName = new Regex(@"policy:\s*'([^']*)'", RegexOptions.Compiled | RegexOptions.IgnoreCase);

        /// <summary>Name of the rule of a DLP / transport rule step ("rule 'X' of policy 'Y'", or its ID when the names are empty).</summary>
        public static string RuleOf(RouteEvent e)
        {
            if (e == null) return "";
            Match m = RuleName.Match(e.Description ?? "");
            string name = m.Success ? m.Groups[1].Value.Trim() : "", id = m.Success ? m.Groups[2].Value : "";
            Match p = PolicyName.Match(e.Description ?? "");
            string policy = p.Success ? p.Groups[1].Value.Trim() : "";
            if (name.Length > 0) return "rule '" + name + "'" + (policy.Length > 0 ? " of policy '" + policy + "'" : "");
            if (policy.Length > 0) return "policy '" + policy + "'";
            return id.Length > 0 ? "rule ID " + id.ToLowerInvariant() : "";
        }

        /// <summary>Action of a rule step that stops the message: BA (block access), reject, delete, quarantine.</summary>
        static bool Blocking(string action)
        {
            string a = (action ?? "").Trim().ToLowerInvariant();
            return a == "ba" || a.Contains("block") || a.Contains("reject") || a.Contains("delete") || a.Contains("quarantine");
        }

        static bool In(string code, params string[] codes) { return Array.IndexOf(codes, code) >= 0; }

        static bool Has(string text, params string[] parts)
        {
            foreach (string p in parts) if (text.IndexOf(p, StringComparison.Ordinal) >= 0) return true;
            return false;
        }

        static CauseInfo FindCause(RouteInfo info, RouteEvent decisive)
        {
            string outcome = info.Outcome;
            if (decisive == null || outcome.Length == 0 || outcome == "Delivered" || outcome == "Expanded") return null;
            var dlpSteps = info.Events.Where(e => e.Kind == "rule" && e.Event.IndexOf("dlp", StringComparison.OrdinalIgnoreCase) >= 0).ToList();
            var etrSteps = info.Events.Where(e => e.Kind == "rule" && e.Event.IndexOf("dlp", StringComparison.OrdinalIgnoreCase) < 0).ToList();
            RouteEvent dlpBlock = dlpSteps.LastOrDefault(e => Blocking(e.Action)), etrBlock = etrSteps.LastOrDefault(e => Blocking(e.Action));
            RouteEvent spam = info.Events.LastOrDefault(e => e.Kind == "spam");
            bool malware = info.Events.Any(e => e.Kind == "malware" && Blocking(e.Action) || e.Kind == "malware" && e.Action.Length == 0);

            if (outcome.StartsWith("Delivered to ", StringComparison.Ordinal))
            {
                if (outcome.EndsWith("Quarantine", StringComparison.Ordinal))
                {
                    if (malware) return Make("malware-quarantine");
                    if (etrBlock != null || spam == null && etrSteps.Count > 0) return Make("etr-quarantine", RuleOf(etrBlock ?? etrSteps.Last()));
                    return Make("spam-quarantine");
                }
                return outcome.IndexOf("Junk", StringComparison.OrdinalIgnoreCase) >= 0 ? Make("junk") : null;
            }

            ReasonInfo r = info.Reason != null && info.Reason.Code.Length > 0 && info.Reason.Code[0] != '2' ? info.Reason : null;
            bool deferred = outcome == "Deferred";
            CauseInfo cause;
            if (r == null)
            {
                if (outcome == "Dropped")
                {
                    if (malware) cause = Make("malware");
                    else if (etrBlock != null) cause = Make("etr-deleted", RuleOf(etrBlock));
                    else if (dlpBlock != null) cause = Make("dlp", RuleOf(dlpBlock));
                    else if (spam != null && Blocking(spam.Action)) cause = Make("spam-blocked");
                    else cause = Make("dropped");
                }
                else cause = Make(deferred ? "deferred" : "other");
            }
            else cause = ByReason(r, decisive, dlpSteps, etrSteps, dlpBlock, etrBlock, malware, spam);
            if (deferred && cause.Tone == "danger") cause.Tone = "warning";
            return cause;
        }

        static CauseInfo ByReason(ReasonInfo r, RouteEvent decisive, List<RouteEvent> dlpSteps, List<RouteEvent> etrSteps, RouteEvent dlpBlock, RouteEvent etrBlock, bool malware, RouteEvent spam)
        {
            string code = r.Code, comp = r.Component.ToLowerInvariant();
            string all = (r.Raw + " " + r.Text + " " + r.Detail + " " + r.RemoteMessage).ToLowerInvariant();
            bool sevenX = code.StartsWith("5.7.", StringComparison.Ordinal) || code.StartsWith("4.7.", StringComparison.Ordinal);

            // Policies first: the component that rejected, the rule step that blocked, the codes reserved for them.
            if (comp.Contains("dlp") || Has(all, "dlp") || dlpBlock != null && sevenX || code == "5.7.171")
                return Make("dlp", RuleOf(dlpBlock ?? dlpSteps.LastOrDefault()));
            if (comp.Contains("transport rule") || Has(all, "transport.rules") || IsRange(code, "5.7.", 900, 999) || etrBlock != null && sevenX)
                return Make(Has(all, "deletemessage") ? "etr-deleted" : "etr", RuleOf(etrBlock ?? etrSteps.LastOrDefault()));
            if (malware || Has(all, "malware", "virus")) return Make("malware");
            if (code == "5.7.703" || Has(all, "tenant allow/block", "tenantallowblock")) return Make("tabl");

            // Network and TLS: the remote server never answered (its name and IP are known though).
            if (IsRange(code, "5.7.", 321, 325) || code == "4.4.8" || Has(all, "starttls", "tls negotiation", "certificate")) return Make("tls");
            if (In(code, "4.4.7", "5.4.7", "5.4.300") || Has(all, "expired")) return Make("expired");
            if (code.StartsWith("4.4.", StringComparison.Ordinal) || In(code, "5.4.4", "5.4.310", "5.4.312", "5.4.316", "5.4.317", "5.7.510")) return Make("network");

            bool notFound = In(code, "5.1.1", "5.1.2", "5.1.3", "5.1.6", "5.1.10", "5.5.0") || code == "5.4.1" && !Has(all, "relay")
                || Has(all, "recipientnotfound", "user unknown", "unknown user", "does not exist", "no such user", "not found");
            bool full = In(code, "5.2.2", "4.2.2") && !Has(all, "submission quota") || Has(all, "mailbox full", "quotaexceeded", "over quota");

            // The answer of the recipient's server (outbound): its code means what it says.
            bool external = string.Equals(Fact(decisive.Data, "IsSmtpResponseFromExternalServer"), "True", StringComparison.OrdinalIgnoreCase);
            if (external) return Make(notFound ? "remote-not-found" : full ? "remote-mailbox-full" : "remote");

            if (In(code, "5.7.12", "5.7.13", "5.7.124", "5.7.133", "5.7.134", "5.7.135", "5.7.136") || Has(all, "resolver.rst", "restrict", "not authorized to send", "moderat", "allowed senders"))
                return Make("restricted");
            if (notFound) return Make("not-found");
            if (full) return Make("mailbox-full");
            if (In(code, "5.7.23", "5.7.509", "5.7.26", "4.7.26", "5.7.25") || Has(all, "spf", "dmarc", "dkim")) return Make("auth");
            if (code == "5.7.520" || Has(all, "forwarding")) return Make("forwarding");
            if (In(code, "5.2.121", "5.2.122", "4.3.2", "5.7.232", "5.7.233", "5.7.236", "5.7.705") || Has(all, "submission quota", "rate limit", "exceeded the limit")) return Make("limits");
            if (In(code, "5.1.8", "5.7.800") || IsRange(code, "5.7.", 501, 513) && !In(code, "5.7.509", "5.7.510", "5.7.512") || IsRange(code, "5.7.", 606, 649)
                || IsRange(code, "5.7.", 700, 750) || IsRange(code, "4.7.", 500, 699)) return Make("sender-blocked");
            if (In(code, "5.7.64", "5.7.57", "5.7.367") || Has(all, "relay")) return Make("relay");
            if (IsRange(code, "5.4.", 6, 20)) return Make("loop");
            if (In(code, "5.3.4", "5.2.3", "5.1.20", "5.7.512") || code.StartsWith("5.6.", StringComparison.Ordinal) || Has(all, "too large", "size limit")) return Make("format");
            if (spam != null && (Blocking(spam.Action) || Has(all, "spam", "phish")) || Has(all, "spam", "phish")) return Make("spam-blocked");
            // Default rejection text of mail flow rules and DLP: the rule steps of the route tell which one.
            if (sevenX && Has(all, "delivery not authorized", "message refused", "organization policy"))
            {
                if (etrSteps.Count > 0 && dlpSteps.Count == 0) return Make("etr", RuleOf(etrSteps.Last()));
                if (dlpSteps.Count > 0 && etrSteps.Count == 0) return Make("dlp", RuleOf(dlpSteps.Last()));
                return Make("policy");
            }
            return Make("other");
        }

        static RouteEvent Pick(List<RouteEvent> events, string kind)
        {
            for (int i = events.Count - 1; i >= 0; i--) if (events[i].Kind == kind) return events[i];
            return null;
        }

        /// <summary>
        /// One line explaining why a route did not end normally ("" when it did): the status code and text of
        /// the decisive event with the component that produced it, or the folder / verdict of a filtered message.
        /// </summary>
        public static string Explain(RouteInfo route)
        {
            if (route == null || route.Events.Count == 0) return "";
            ReasonInfo r = route.Reason;
            if (r != null && r.Code.Length > 0 && r.Code[0] != '2') return r.Short + (r.Component.Length > 0 ? " [" + r.Component + "]" : "");
            if (route.Outcome.StartsWith("Delivered to ", StringComparison.Ordinal) || route.Outcome == "Dropped")
            {
                string verdict = Verdict(route);
                return route.Outcome + (verdict.Length > 0 ? " (" + verdict + ")" : "");
            }
            return "";
        }

        /// <summary>Grouping key of <see cref="Explain"/>: same code, text and component, or same outcome.</summary>
        public static string ExplainKey(RouteInfo route)
        {
            if (route == null || route.Events.Count == 0) return "";
            ReasonInfo r = route.Reason;
            if (r != null && r.Code.Length > 0 && r.Code[0] != '2') return r.Key;
            if (route.Outcome.StartsWith("Delivered to ", StringComparison.Ordinal) || route.Outcome == "Dropped") return "outcome|" + route.Outcome.ToLowerInvariant();
            return "";
        }

        /// <summary>Anti-spam verdict of the route: "SCL 8, SFV SPM" ("" without a Spam event).</summary>
        public static string Verdict(RouteInfo route)
        {
            var parts = new List<string>();
            foreach (RouteEvent e in route.Events)
            {
                if (e.Kind != "spam") continue;
                foreach (var f in e.Facts)
                {
                    string v = f.Value.Split(' ')[0];
                    if (f.Key == Label("SCL") && !parts.Contains("SCL " + v)) parts.Add("SCL " + v);
                    if (f.Key == Label("SFV") && !parts.Contains("SFV " + v)) parts.Add("SFV " + v);
                }
            }
            return string.Join(", ", parts);
        }
    }

    // -------------------------------------------------------------------------
    // Journeys: one message, its recipients grouped by route (console of small traces)
    // -------------------------------------------------------------------------

    public sealed class RouteGroup
    {
        public string Letter = "";
        public string Status = "";
        public RouteInfo Route;
        public List<string> Recipients = new List<string>();
    }

    public sealed class MessageJourney
    {
        public long ReceivedMs, Size;
        public string Sender, Subject, MessageId, TraceId, FromIP;
        public SortedDictionary<string, int> Statuses = new SortedDictionary<string, int>(StringComparer.Ordinal);
        public List<RouteGroup> Groups = new List<RouteGroup>();
        public List<string> NotRead = new List<string>();
        public int Recipients;
    }

    public static class Journeys
    {
        /// <summary>The first messages of the selection, with their recipients grouped by identical route.</summary>
        public static List<MessageJourney> Build(IEnumerable<DeliveryView> rows, Dictionary<string, List<DetailRow>> details, int maxMessages)
        {
            var list = new List<MessageJourney>();
            MessageJourney current = null;
            long currentId = long.MinValue;
            var groups = new Dictionary<string, RouteGroup>(StringComparer.Ordinal);
            foreach (DeliveryView d in rows)
            {
                if (d.MessageRowId != currentId)
                {
                    if (list.Count >= maxMessages) break;
                    currentId = d.MessageRowId;
                    current = new MessageJourney { ReceivedMs = d.ReceivedMs, Sender = d.Sender, Subject = d.Subject, MessageId = d.MessageId, TraceId = d.TraceId, FromIP = d.FromIP, Size = d.Size };
                    groups = new Dictionary<string, RouteGroup>(StringComparer.Ordinal);
                    list.Add(current);
                }
                current.Recipients++;
                string label = ReportWriter.StatusLabel(d.Status);
                int n; current.Statuses.TryGetValue(label, out n); current.Statuses[label] = n + 1;
                List<DetailRow> events;
                string key = d.MessageRowId.ToString(CultureInfo.InvariantCulture) + "|" + d.RecipientId.ToString(CultureInfo.InvariantCulture);
                if (details == null || !details.TryGetValue(key, out events) || events.Count == 0) { current.NotRead.Add(d.Recipient + " (" + label + ")"); continue; }
                RouteInfo route = RouteAnalyzer.Analyze(events);
                string sig = label + "|" + route.Signature;
                RouteGroup g;
                if (!groups.TryGetValue(sig, out g)) { g = new RouteGroup { Status = label, Route = route }; groups[sig] = g; current.Groups.Add(g); }
                g.Recipients.Add(d.Recipient);
            }
            foreach (MessageJourney j in list)
            {
                // Failures first, then the other problems, then the largest groups.
                j.Groups = j.Groups.OrderBy(g => g.Status == "Failed" ? 0 : g.Status == "Delivered" || g.Status == "Expanded" ? 2 : 1).ThenByDescending(g => g.Recipients.Count).ToList();
                for (int i = 0; i < j.Groups.Count; i++) j.Groups[i].Letter = ((char)('A' + Math.Min(i, 25))).ToString();
            }
            return list;
        }
    }
}
