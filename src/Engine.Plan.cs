// =============================================================================
//  Message Trace Report - engine, part 2: query planning
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 1.0.0
//
//  What the Graph message trace API really does with $filter (lab, 2026-10-02):
//    - it keeps ONE value per property (the last one) and combines the properties with AND;
//      'or', 'in', 'ne' and 'not' are accepted but silently ignored;
//    - startswith/endswith/contains are ignored on addresses; '*@domain' works;
//    - subject supports eq, contains, startswith and endswith (case-insensitive);
//    - one window is at most 10 days, never older than 90 days.
//  So every value of a list needs its own query. The planner chooses the smallest set of
//  queries that returns every message of the user's filter, and the report applies the full
//  filter on the local database afterwards (Store.Select).
//
//  It also subtracts what the database already holds: a query is covered for a period when
//  a previous query at least as wide (same conditions or fewer, or a *@domain that includes
//  the address) collected it and the data has settled.
// =============================================================================
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace MessageTraceReport
{
    /// <summary>The user's filter, after the module has read the files and checked the values.</summary>
    public sealed class FilterSpec
    {
        public List<string> Senders = new List<string>();       // normalized addresses or *@domain (or patterns in Report mode)
        public List<string> Recipients = new List<string>();
        public bool OrMode;                                     // true: sender in Senders OR recipient in Recipients
        public string Subject;                                  // null = no subject filter
        public string SubjectMatch = "Contains";                // Contains | StartsWith | EndsWith | Equals
        public List<string> Statuses = new List<string>();     // Graph names: delivered, failed, ...
        public List<string> MessageIds = new List<string>();
        public string FromIP;
        public string ToIP;

        public bool IsEmpty
        {
            get
            {
                return Senders.Count == 0 && Recipients.Count == 0 && string.IsNullOrEmpty(Subject) && Statuses.Count == 0
                    && MessageIds.Count == 0 && string.IsNullOrEmpty(FromIP) && string.IsNullOrEmpty(ToIP);
            }
        }

        public bool HasPatterns
        {
            get { return Senders.Concat(Recipients).Any(a => Address.IsPattern(a) && !Address.IsDomainWildcard(a)); }
        }

        /// <summary>One line per filter, for the console, the log and the report.</summary>
        public List<string> Describe()
        {
            var lines = new List<string>();
            string join = OrMode && Senders.Count > 0 && Recipients.Count > 0 ? "OR" : "AND";
            if (Senders.Count > 0) lines.Add("Sender: " + List(Senders));
            if (Recipients.Count > 0) lines.Add((lines.Count > 0 ? join + " recipient: " : "Recipient: ") + List(Recipients));
            if (!string.IsNullOrEmpty(Subject)) lines.Add("Subject " + SubjectMatch.ToLowerInvariant() + " '" + Subject + "'");
            if (Statuses.Count > 0) lines.Add("Status: " + string.Join(", ", Statuses));
            if (MessageIds.Count > 0) lines.Add("Message ID: " + List(MessageIds));
            if (!string.IsNullOrEmpty(FromIP)) lines.Add("From IP: " + FromIP);
            if (!string.IsNullOrEmpty(ToIP)) lines.Add("To IP: " + ToIP);
            if (lines.Count == 0) lines.Add("All messages of the tenant");
            return lines;
        }

        static string List(List<string> values)
        {
            if (values.Count <= 3) return string.Join(", ", values);
            return string.Join(", ", values.Take(3)) + " (+" + (values.Count - 3) + ")";
        }
    }

    /// <summary>One server-side condition: field, operator, value.</summary>
    public sealed class Condition
    {
        public string Field;   // sender | recipient | subject | status | messageid | fromip | toip
        public string Op;      // eq | contains | startswith | endswith
        public string Value;   // as sent to Graph
        public string Norm;    // lower case, used to compare signatures

        public Condition(string field, string op, string value)
        {
            Field = field; Op = op; Value = value ?? ""; Norm = Value.ToLowerInvariant();
        }

        public string Token { get { return Field + "." + Op + "=" + Norm; } }

        public static Condition Parse(string token)
        {
            int dot = token.IndexOf('.'), eq = token.IndexOf('=');
            if (dot < 0 || eq < dot) throw new FormatException("Invalid condition: " + token);
            return new Condition(token.Substring(0, dot), token.Substring(dot + 1, eq - dot - 1), token.Substring(eq + 1));
        }

        static readonly Dictionary<string, string> Properties = new Dictionary<string, string>
        {
            { "sender", "senderAddress" }, { "recipient", "recipientAddress" }, { "subject", "subject" }, { "status", "status" },
            { "messageid", "messageId" }, { "fromip", "fromIP" }, { "toip", "toIP" }
        };

        public string ToOData()
        {
            string property = Properties[Field];
            if (Op == "eq") return property + " eq " + Text.ODataString(Value);
            return Op + "(" + property + ", " + Text.ODataString(Value) + ")";
        }

        public string Describe()
        {
            string name = Field == "messageid" ? "message ID" : Field == "fromip" ? "from IP" : Field == "toip" ? "to IP" : Field;
            return Op == "eq" ? name + " " + Value : name + " " + Op + " '" + Value + "'";
        }

        /// <summary>
        /// True when every message matching <paramref name="narrow"/> also matches this condition
        /// (same field). Used to reuse data collected by a wider query.
        /// </summary>
        public bool Covers(Condition narrow)
        {
            if (Field != narrow.Field) return false;
            if (Op == narrow.Op && Norm == narrow.Norm) return true;
            if ((Field == "sender" || Field == "recipient") && Op == "eq" && narrow.Op == "eq" && Address.IsDomainWildcard(Norm))
                return narrow.Norm.EndsWith(Norm.Substring(1), StringComparison.Ordinal);
            if (Field == "subject")
            {
                string v = narrow.Norm;
                if (Op == "contains") return v.Contains(Norm);    // any narrow operator: its value contains ours
                if (Op == "startswith") return (narrow.Op == "startswith" || narrow.Op == "eq") && v.StartsWith(Norm, StringComparison.Ordinal);
                if (Op == "endswith") return (narrow.Op == "endswith" || narrow.Op == "eq") && v.EndsWith(Norm, StringComparison.Ordinal);
            }
            return false;
        }
    }

    /// <summary>One Graph query (without its time window).</summary>
    public sealed class QuerySpec
    {
        public List<Condition> Conditions = new List<Condition>();
        public string Signature;       // canonical text, stored in the database ('' = the whole tenant)
        public string Label;           // short text for the console

        public static QuerySpec Create(IEnumerable<Condition> conditions)
        {
            var q = new QuerySpec();
            q.Conditions = conditions.GroupBy(c => c.Token).Select(g => g.First()).OrderBy(c => c.Field, StringComparer.Ordinal).ThenBy(c => c.Token, StringComparer.Ordinal).ToList();
            q.Signature = string.Join("\u001F", q.Conditions.Select(c => c.Token));
            q.Label = q.Conditions.Count == 0 ? "all messages" : string.Join(", ", q.Conditions.Select(c => c.Describe()));
            return q;
        }

        public static List<Condition> ParseSignature(string signature)
        {
            if (string.IsNullOrEmpty(signature)) return new List<Condition>();
            return signature.Split('\u001F').Select(Condition.Parse).ToList();
        }

        /// <summary>$filter of one window: received date (start floored, end rounded up) and the conditions.</summary>
        public string ODataFilter(long startMs, long endMs)
        {
            var sb = new StringBuilder();
            sb.Append("receivedDateTime ge ").Append(Time.GraphTime(startMs, false)).Append(" and receivedDateTime le ").Append(Time.GraphTime(endMs, true));
            foreach (Condition c in Conditions) sb.Append(" and ").Append(c.ToOData());
            return sb.ToString();
        }

        /// <summary>True when the data of a query with these conditions includes all the data of this query.</summary>
        public static bool IsCoveredBy(List<Condition> wide, List<Condition> narrow)
        {
            foreach (Condition w in wide)
            {
                bool implied = false;
                foreach (Condition n in narrow) { if (w.Covers(n)) { implied = true; break; } }
                if (!implied) return false;
            }
            return true;
        }
    }

    /// <summary>Settled coverage of one signature already in the database.</summary>
    public sealed class KnownCoverage
    {
        public long SignatureId;
        public string Signature;
        public List<Condition> Conditions;
        public List<TimeRange> Ranges = new List<TimeRange>();
    }

    /// <summary>One request series: a query on one window (several pages).</summary>
    public sealed class WorkItem
    {
        public int Index;
        public QuerySpec Query;
        public long SignatureId;
        public long StartMs;
        public long EndMs;
        // Progress, written by the collector.
        public long CoverageId;
        public long CoveredFromMs;     // the database holds this query for [CoveredFromMs, EndMs)
        public long OldestMs;          // oldest receivedDateTime seen so far (the API returns the newest first)
        public int Pages;
        public long Rows;
        public string State = "Pending";   // Pending | Running | Done | Failed | Cancelled
        public string Error;

        public double Fraction
        {
            get
            {
                if (State == "Done") return 1.0;
                if (OldestMs <= 0 || EndMs <= StartMs) return 0.0;
                return Math.Max(0.0, Math.Min(0.99, (double)(EndMs - OldestMs) / (EndMs - StartMs)));
            }
        }
    }

    public sealed class QueryPlan
    {
        public List<QuerySpec> Queries = new List<QuerySpec>();
        public List<string> Strategy = new List<string>();        // why these queries (console, guide)
        public List<string> LocalFilters = new List<string>();    // conditions applied on the database only
    }

    public sealed class WorkPlan
    {
        public List<WorkItem> Items = new List<WorkItem>();
        public long PeriodMs;
        public long CoveredMs;          // query x time already in the database (settled)
        public long MissingMs;          // query x time to collect
        public long UnrecoverableMs;    // query x time older than the API history and not in the database
        public List<TimeRange> Unrecoverable = new List<TimeRange>();
        public int QueriesComplete;     // queries whose whole period is already in the database
    }

    public static class Planner
    {
        public static readonly string[] KnownStatuses = { "delivered", "failed", "pending", "expanded", "quarantined", "filteredAsSpam", "gettingStatus" };

        /// <summary>
        /// Graph queries for a filter.
        ///   - Single values (subject, IP, one status, one message ID) are always sent to Graph.
        ///   - Senders AND recipients: one query per value of the SHORTER list; the other list is applied locally.
        ///   - Senders OR recipients: one query per sender plus one per recipient.
        ///   - Several statuses or message IDs: one query each when there is no address list, otherwise local.
        /// </summary>
        public static QueryPlan Plan(FilterSpec f)
        {
            var plan = new QueryPlan();
            var common = new List<Condition>();
            if (!string.IsNullOrEmpty(f.Subject))
            {
                string op = f.SubjectMatch.ToLowerInvariant();
                if (op == "equals") op = "eq";
                if (op != "eq" && op != "contains" && op != "startswith" && op != "endswith") throw new ArgumentException("SubjectMatch must be Contains, StartsWith, EndsWith or Equals.");
                common.Add(new Condition("subject", op, f.Subject));
            }
            if (!string.IsNullOrEmpty(f.FromIP)) common.Add(new Condition("fromip", "eq", f.FromIP));
            if (!string.IsNullOrEmpty(f.ToIP)) common.Add(new Condition("toip", "eq", f.ToIP));
            if (f.Statuses.Count == 1) common.Add(new Condition("status", "eq", f.Statuses[0]));
            if (f.MessageIds.Count == 1) common.Add(new Condition("messageid", "eq", f.MessageIds[0]));

            var units = new List<List<Condition>>();
            List<string> s = f.Senders.Distinct(StringComparer.OrdinalIgnoreCase).ToList();
            List<string> r = f.Recipients.Distinct(StringComparer.OrdinalIgnoreCase).ToList();
            bool addressUnits = s.Count > 0 || r.Count > 0;

            if (s.Count > 0 && r.Count > 0 && f.OrMode)
            {
                foreach (string a in s) units.Add(new List<Condition> { new Condition("sender", "eq", a) });
                foreach (string a in r) units.Add(new List<Condition> { new Condition("recipient", "eq", a) });
                plan.Strategy.Add(string.Format("Senders OR recipients: one query per sender ({0}) and per recipient ({1}).", s.Count, r.Count));
            }
            else if (s.Count > 0 && r.Count > 0)
            {
                if (s.Count == 1 && r.Count == 1)
                {
                    units.Add(new List<Condition> { new Condition("sender", "eq", s[0]), new Condition("recipient", "eq", r[0]) });
                    plan.Strategy.Add("One sender AND one recipient: one query with both.");
                }
                else if (s.Count <= r.Count)
                {
                    foreach (string a in s) units.Add(new List<Condition> { new Condition("sender", "eq", a) });
                    plan.LocalFilters.Add("recipient in the list of " + r.Count);
                    plan.Strategy.Add(string.Format("Senders AND recipients: one query per sender ({0}, the shorter list); the {1} recipients are filtered locally.", s.Count, r.Count));
                }
                else
                {
                    foreach (string a in r) units.Add(new List<Condition> { new Condition("recipient", "eq", a) });
                    plan.LocalFilters.Add("sender in the list of " + s.Count);
                    plan.Strategy.Add(string.Format("Senders AND recipients: one query per recipient ({0}, the shorter list); the {1} senders are filtered locally.", r.Count, s.Count));
                }
            }
            else if (s.Count > 0)
            {
                foreach (string a in s) units.Add(new List<Condition> { new Condition("sender", "eq", a) });
                if (s.Count > 1) plan.Strategy.Add(string.Format("One query per sender ({0}): Graph keeps only one value per property.", s.Count));
            }
            else if (r.Count > 0)
            {
                foreach (string a in r) units.Add(new List<Condition> { new Condition("recipient", "eq", a) });
                if (r.Count > 1) plan.Strategy.Add(string.Format("One query per recipient ({0}): Graph keeps only one value per property.", r.Count));
            }

            if (f.MessageIds.Count > 1)
            {
                if (!addressUnits && units.Count == 0)
                {
                    foreach (string m in f.MessageIds) units.Add(new List<Condition> { new Condition("messageid", "eq", m) });
                    plan.Strategy.Add(string.Format("One query per message ID ({0}).", f.MessageIds.Count));
                    addressUnits = true;
                }
                else plan.LocalFilters.Add("message ID in the list of " + f.MessageIds.Count);
            }
            if (f.Statuses.Count > 1)
            {
                if (!addressUnits && units.Count == 0)
                {
                    foreach (string st in f.Statuses) units.Add(new List<Condition> { new Condition("status", "eq", st) });
                    plan.Strategy.Add(string.Format("One query per status ({0}).", f.Statuses.Count));
                }
                else if (units.Count == 1)
                {
                    // One address: a query per status avoids downloading every message of a busy mailbox.
                    var product = new List<List<Condition>>();
                    foreach (string st in f.Statuses) product.Add(new List<Condition>(units[0]) { new Condition("status", "eq", st) });
                    units = product;
                    plan.Strategy.Add(string.Format("One address and {0} statuses: one query per status.", f.Statuses.Count));
                }
                else plan.LocalFilters.Add("status in (" + string.Join(", ", f.Statuses) + ")");
            }
            if (units.Count == 0) units.Add(new List<Condition>());

            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (var u in units)
            {
                QuerySpec q = QuerySpec.Create(common.Concat(u));
                if (seen.Add(q.Signature)) plan.Queries.Add(q);
            }
            if (plan.Strategy.Count == 0) plan.Strategy.Add(plan.Queries[0].Conditions.Count == 0 ? "No filter: every message of the tenant." : "One query.");
            return plan;
        }

        /// <summary>
        /// Windows to collect for every query: the period, minus what the database already holds (settled
        /// coverage of the same or a wider query), minus what is older than the API history (unrecoverable),
        /// cut into windows of at most windowMs, newest first. A query without any address or message ID
        /// (the whole tenant, a subject ...) returns many rows: it is cut into windows of broadWindowMs so that
        /// several windows are read in parallel (the pages of one window are sequential).
        /// </summary>
        public static WorkPlan Windows(List<QuerySpec> queries, List<KnownCoverage> known, long startMs, long endMs, long earliestMs, long windowMs, long broadWindowMs = 0, int parallelWindows = 1)
        {
            var plan = new WorkPlan { PeriodMs = Math.Max(0, endMs - startMs) };
            if (known == null) known = new List<KnownCoverage>();
            var lost = new List<TimeRange>();
            int index = 0;
            foreach (QuerySpec q in queries)
            {
                var covered = new List<TimeRange>();
                foreach (KnownCoverage k in known)
                {
                    if (k.Ranges.Count == 0) continue;
                    if (k.Signature == q.Signature || QuerySpec.IsCoveredBy(k.Conditions, q.Conditions)) covered.AddRange(k.Ranges);
                }
                List<TimeRange> gaps = Coverage.Gaps(covered, startMs, endMs);
                long gapMs = 0;
                foreach (TimeRange g in gaps) gapMs += g.Length;
                plan.CoveredMs += Math.Max(0, endMs - startMs) - gapMs;
                if (gaps.Count == 0) { plan.QueriesComplete++; continue; }
                var collectable = new List<TimeRange>();
                foreach (TimeRange g in gaps)
                {
                    if (g.End <= earliestMs) { lost.Add(g); plan.UnrecoverableMs += g.Length; continue; }
                    if (g.Start < earliestMs)
                    {
                        lost.Add(new TimeRange(g.Start, earliestMs)); plan.UnrecoverableMs += earliestMs - g.Start;
                        collectable.Add(new TimeRange(earliestMs, g.End));
                    }
                    else collectable.Add(g);
                }
                bool broad = !q.Conditions.Any(c => c.Field == "sender" || c.Field == "recipient" || c.Field == "messageid");
                long size = windowMs;
                if (broad && broadWindowMs > 0)
                {
                    // At least parallelWindows windows (15 minutes or more each), so that a short but busy period is read in parallel.
                    long total = collectable.Sum(r => r.Length);
                    long even = parallelWindows > 1 ? (total + parallelWindows - 1) / parallelWindows : total;
                    size = Math.Min(windowMs, Math.Min(broadWindowMs, Math.Max(15 * 60000L, even)));
                }
                foreach (TimeRange w in Coverage.Split(collectable, size))
                {
                    plan.MissingMs += w.Length;
                    plan.Items.Add(new WorkItem { Index = index++, Query = q, StartMs = w.Start, EndMs = w.End });
                }
            }
            plan.Unrecoverable = Coverage.Merge(lost);
            return plan;
        }
    }
}
