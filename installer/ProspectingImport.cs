// UBK-owned data-only importer. No TSM source or yield dataset is distributed here.
// Generates local configuration from the user's separately installed TSM addon.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

public static class ProspectingImport
{
    private static readonly int[] OreIds = { 2770, 2771, 2772, 3858, 10620, 23424, 23425 };
    private static readonly int[] GemIds = { 774, 818, 1206, 1210, 1529, 1705, 3864, 7909, 7910, 12361, 12364, 12799, 12800, 21929, 23077, 23079, 23107, 23112, 23117, 23436, 23437, 23438, 23439, 23440, 23441 };
    private static readonly string[] Fields = { "requiredSkill", "matRate", "minAmount", "maxAmount", "amountOfMats" };
    private sealed class Ore
    {
        public int Skill = -1;
        public readonly SortedDictionary<int, double> Outputs = new SortedDictionary<int, double>();
        public readonly List<string> Warnings = new List<string>();
    }

    // Contract for Installer.cs: call before installation writes; back up and write
    // returned text as UniversalBasisKeeper/UBK_ProspectingData.lua using UTF-8.
    // Original TSM files are read only. Invalid or unavailable input throws.
    public static string Generate(string wowRoot)
    {
        if (String.IsNullOrWhiteSpace(wowRoot)) throw new ArgumentException("A WoW client folder is required.", "wowRoot");
        string root = Path.GetFullPath(wowRoot);
        string tsm = Path.Combine(root, "Interface", "AddOns", "TradeSkillMaster");
        string sourcePath = Path.Combine(tsm, "LibTSMData", "Destroy", "Prospect.lua");
        if (!File.Exists(sourcePath)) throw new FileNotFoundException("Install TradeSkillMaster for TBC Anniversary before importing its local prospecting data.", sourcePath);
        if (new FileInfo(sourcePath).Length > 2000000) throw new InvalidDataException("Installed TSM prospecting data is unexpectedly large.");
        string source = File.ReadAllText(sourcePath, Encoding.UTF8);
        // Validate the table itself; do not identify the user's installed TSM version.
        return GenerateFromSource(source, "not inspected");
    }

    // Public for a data-only test harness; no source execution or client writes.
    public static string GenerateFromSource(string source, string version)
    {
        if (source == null || source.Length > 2000000) throw new InvalidDataException("Invalid installed prospecting data.");
        MatchCollection markers = Regex.Matches(source, @"(?m)^\s*DATA\.BCC\s*=\s*\{");
        if (markers.Count != 1) throw new InvalidDataException("Installed TSM does not contain one recognizable Burning Crusade prospecting table.");
        Match marker = markers[0];
        int brace = source.IndexOf('{', marker.Index);
        Parser parser = new Parser(source, brace);
        Dictionary<int, Dictionary<int, Dictionary<string, double>>> data = parser.Root();
        var oreIds = new HashSet<int>(OreIds);
        var gemIds = new HashSet<int>(GemIds);
        var fieldNames = new HashSet<string>(Fields);
        var ores = new SortedDictionary<int, Ore>();
        int pairs = 0;
        foreach (KeyValuePair<int, Dictionary<int, Dictionary<string, double>>> gem in data)
        {
            if (!gemIds.Contains(gem.Key)) throw new InvalidDataException("Installed BCC table includes an unsupported raw gem ID: " + gem.Key);
            if (gem.Value.Count == 0) throw new InvalidDataException("An installed prospecting gem has no source ore.");
            foreach (KeyValuePair<int, Dictionary<string, double>> entry in gem.Value)
            {
                if (!oreIds.Contains(entry.Key)) throw new InvalidDataException("Installed BCC table includes an unsupported ore ID: " + entry.Key);
                Dictionary<string, double> f = entry.Value;
                if (f.Count != Fields.Length) throw new InvalidDataException("An installed prospecting row has missing or additional fields.");
                foreach (string key in f.Keys) if (!fieldNames.Contains(key)) throw new InvalidDataException("Unsupported prospecting field: " + key);
                foreach (string key in Fields) if (!f.ContainsKey(key)) throw new InvalidDataException("Missing prospecting field: " + key);
                double skill = f["requiredSkill"], probability = f["matRate"], min = f["minAmount"], max = f["maxAmount"], perOre = f["amountOfMats"];
                if (skill != Math.Floor(skill) || skill < 1 || skill > 375 || probability <= 0 || probability > 1 || min != Math.Floor(min) || max != Math.Floor(max) || min < 1 || max < min || max > 10 || perOre <= 0 || perOre > 2)
                    throw new InvalidDataException("An installed BCC prospecting row contains out-of-range numeric data.");
                Ore ore;
                if (!ores.TryGetValue(entry.Key, out ore)) { ore = new Ore(); ores.Add(entry.Key, ore); }
                if (ore.Skill >= 0 && ore.Skill != (int)skill) throw new InvalidDataException("Inconsistent skill requirements for one ore.");
                ore.Skill = (int)skill;
                ore.Outputs.Add(gem.Key, perOre);
                pairs++;
                // TSM's probability and average estimates have small differences.
                // Permit 0.005 gems plus 10% approximation; larger disagreements
                // are exposed and their ore is withheld from EV/profit ranking.
                double expected = 5 * perOre, lower = probability * min, upper = probability * max;
                if (expected > upper + 0.005 + upper * 0.10 || expected < lower - 0.005 - lower * 0.10)
                    ore.Warnings.Add("gem i:" + gem.Key + ": average " + Num(expected) + " versus probability range " + Num(lower) + "-" + Num(upper) + " per five ores");
            }
        }
        if (ores.Count != OreIds.Length || data.Count != GemIds.Length || pairs < 40 || pairs > 100)
            throw new InvalidDataException("Installed BCC prospecting data is incomplete or has an unexpected structure.");
        foreach (int id in OreIds) if (!ores.ContainsKey(id)) throw new InvalidDataException("A supported ore is missing from installed BCC data.");
        // Reject missing result rows; a partial yield basket would misstate profit.
        int[] requiredCounts = {3, 6, 5, 7, 11, 12, 12};
        for (int i = 0; i < OreIds.Length; i++)
            if (ores[OreIds[i]].Outputs.Count != requiredCounts[i]) throw new InvalidDataException("The installed yield structure changed for ore " + OreIds[i] + ". Update the UBK importer before valuing it.");
        string digest;
        using (SHA256 sha = SHA256.Create()) digest = BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(source))).Replace("-", "").ToLowerInvariant();
        StringBuilder output = new StringBuilder();
        output.Append("-- Generated locally from this PC's installed TSM data. Do not include in public UBK packages.\n");
        output.Append("_G.UBKProspectingData = {schema=1,client=\"BCC\",source=\"Locally imported TSM BCC data\",sourceVersion=").Append(LuaString(version ?? "installed version"));
        output.Append(",sourceHash=").Append(LuaString(digest)).Append(",ores={\n");
        foreach (KeyValuePair<int, Ore> entry in ores)
        {
            output.Append("[").Append(entry.Key).Append("]={skill=").Append(entry.Value.Skill).Append(",outputs={");
            foreach (KeyValuePair<int, double> gem in entry.Value.Outputs) output.Append("[").Append(gem.Key).Append("]=").Append(Num(gem.Value)).Append(",");
            output.Append("}");
            if (entry.Value.Warnings.Count > 0)
                output.Append(",warning=").Append(LuaString("Installed TSM yield estimates disagree substantially: " + String.Join("; ", entry.Value.Warnings.ToArray()) + ". Full revenue and profit are withheld until verified."));
            output.Append("},\n");
        }
        output.Append("}}\n");
        return output.ToString();
    }

    private static string Num(double n) { return n.ToString("G17", CultureInfo.InvariantCulture); }
    private static string LuaString(string s)
    {
        StringBuilder b = new StringBuilder("\"");
        foreach (char c in s)
        {
            if (c == '\\' || c == '"') b.Append('\\').Append(c);
            else if (c == '\n') b.Append("\\n");
            else if (c == '\r') b.Append("\\r");
            else if (c < 32 || c > 126) b.Append('?');
            else b.Append(c);
        }
        return b.Append('"').ToString();
    }

    // Deliberately accepts only nested tables, item-string keys, bare field
    // names and finite numbers. Functions, calls, expressions and escapes fail.
    private sealed class Parser
    {
        private readonly string text;
        private int pos;
        private int tokens;
        public Parser(string text, int start) { this.text = text; pos = start; }
        private void Skip()
        {
            while (pos < text.Length)
            {
                if (Char.IsWhiteSpace(text[pos])) { pos++; continue; }
                if (pos + 1 < text.Length && text[pos] == '-' && text[pos + 1] == '-')
                {
                    pos += 2;
                    if (pos < text.Length && text[pos] == '[')
                    {
                        int n = pos + 1; while (n < text.Length && text[n] == '=') n++;
                        if (n < text.Length && text[n] == '[')
                        {
                            string close = "]" + new string('=', n - pos - 1) + "]";
                            int end = text.IndexOf(close, n + 1, StringComparison.Ordinal);
                            if (end < 0) Fail("Unterminated comment");
                            pos = end + close.Length; continue;
                        }
                    }
                    while (pos < text.Length && text[pos] != '\n') pos++;
                    continue;
                }
                break;
            }
        }
        private void Fail(string reason) { throw new InvalidDataException(reason + " in installed BCC data at character " + pos + "."); }
        private bool Take(char c) { Skip(); if (pos < text.Length && text[pos] == c) { pos++; return true; } return false; }
        private void Need(char c) { if (++tokens > 10000) Fail("Too many tokens"); if (!Take(c)) Fail("Expected " + c); }
        private int ItemKey()
        {
            Need('['); Skip(); Need('"'); int start = pos;
            while (pos < text.Length && text[pos] != '"') { if (text[pos] == '\\' || text[pos] == '\n') Fail("Escaped item keys are unsupported"); pos++; }
            if (pos >= text.Length) Fail("Unterminated item key");
            string value = text.Substring(start, pos - start); Need('"'); Need(']'); Need('=');
            Match m = Regex.Match(value, @"^i:([1-9][0-9]{0,6})$");
            if (!m.Success) Fail("Expected a plain numeric item ID");
            return Int32.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture);
        }
        private string Field()
        {
            Skip(); int start = pos;
            while (pos < text.Length && ((text[pos] >= 'a' && text[pos] <= 'z') || (text[pos] >= 'A' && text[pos] <= 'Z'))) pos++;
            if (pos == start) Fail("Expected numeric field name");
            string field = text.Substring(start, pos - start); Need('='); return field;
        }
        private double Number()
        {
            Skip(); Match m = Regex.Match(text.Substring(pos), @"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?");
            double value;
            if (!m.Success || !Double.TryParse(m.Value, NumberStyles.Float, CultureInfo.InvariantCulture, out value) || Double.IsNaN(value) || Double.IsInfinity(value)) { Fail("Expected finite numeric data"); return 0; }
            pos += m.Length; return value;
        }
        private bool EndOrComma()
        {
            if (Take('}')) return true;
            Need(','); return Take('}');
        }
        public Dictionary<int, Dictionary<int, Dictionary<string, double>>> Root()
        {
            var result = new Dictionary<int, Dictionary<int, Dictionary<string, double>>>(); Need('{');
            if (Take('}')) return result;
            do
            {
                int gem = ItemKey(); if (result.ContainsKey(gem)) Fail("Duplicate gem key");
                var ores = new Dictionary<int, Dictionary<string, double>>(); Need('{');
                if (!Take('}'))
                {
                    do
                    {
                        int ore = ItemKey(); if (ores.ContainsKey(ore)) Fail("Duplicate ore key");
                        var fields = new Dictionary<string, double>(); Need('{');
                        if (!Take('}'))
                        {
                            do { string name = Field(); if (fields.ContainsKey(name)) Fail("Duplicate numeric field"); fields.Add(name, Number()); } while (!EndOrComma());
                        }
                        ores.Add(ore, fields);
                    } while (!EndOrComma());
                }
                result.Add(gem, ores);
            } while (!EndOrComma());
            return result;
        }
    }
}
