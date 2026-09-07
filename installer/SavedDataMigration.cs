// Data-only migration of UBK's own legacy settings. Never executes SavedVariables.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.Serialization;
using System.Text;
using System.Text.RegularExpressions;

namespace UBKCompanionInstaller
{
    [DataContract]
    internal sealed class LegacyDataSource
    {
        [DataMember] public string Path;
        [DataMember] public string Hash;
        [DataMember] public string OldVariable;
        [DataMember] public string NewVariable;
        [DataMember] public string UnifiedPath;
    }
    internal sealed class LuaAssignment
    {
        public int Start, End;
        public string Value;
    }
    internal sealed class SavedDataParser
    {
        private static readonly Regex Number = new Regex(@"\G-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?", RegexOptions.CultureInvariant);
        private readonly string text;
        private int pos, depth, values;
        public SavedDataParser(string value) { text = value ?? String.Empty; if (text.Length > 64 * 1024 * 1024) throw new InvalidDataException("UBK saved data is too large for this importer."); }
        private void Error() { throw new InvalidDataException("UBK saved data is not a supported data-only table near character " + pos + ". Nothing was installed."); }
        private bool At(string token) { return pos + token.Length <= text.Length && String.CompareOrdinal(text, pos, token, 0, token.Length) == 0; }
        private bool LongString()
        {
            if (!At("[")) return false;
            int start = pos, cursor = pos + 1;
            while (cursor < text.Length && text[cursor] == '=') cursor++;
            if (cursor >= text.Length || text[cursor] != '[') return false;
            string close = "]" + new String('=', cursor - start - 1) + "]";
            int end = text.IndexOf(close, cursor + 1, StringComparison.Ordinal);
            if (end < 0) Error();
            pos = end + close.Length; return true;
        }
        private void Space()
        {
            for (;;)
            {
                while (pos < text.Length && (Char.IsWhiteSpace(text[pos]) || (pos == 0 && text[pos] == '\ufeff'))) pos++;
                if (!At("--")) return;
                pos += 2;
                if (LongString()) continue;
                while (pos < text.Length && text[pos] != '\n') pos++;
            }
        }
        private void Need(char c) { Space(); if (pos >= text.Length || text[pos] != c) Error(); pos++; }
        private string Identifier()
        {
            Space(); int start = pos;
            if (pos >= text.Length || !(Char.IsLetter(text[pos]) || text[pos] == '_')) Error();
            while (pos < text.Length && (Char.IsLetterOrDigit(text[pos]) || text[pos] == '_')) pos++;
            return text.Substring(start, pos - start);
        }
        private void Quoted()
        {
            char quote = text[pos++];
            while (pos < text.Length)
            {
                char c = text[pos++];
                if (c == quote) return;
                if (c == '\n' || c == '\r') Error();
                if (c == '\\')
                {
                    if (pos >= text.Length) Error();
                    char escaped = text[pos++];
                    if (escaped == '\r' && pos < text.Length && text[pos] == '\n') pos++;
                }
            }
            Error();
        }
        private void Value()
        {
            Space(); if (++values > 4000000 || ++depth > 128 || pos >= text.Length) Error();
            char c = text[pos];
            if (c == '{')
            {
                pos++; Space();
                while (pos < text.Length && text[pos] != '}')
                {
                    if (text[pos] == '[')
                    {
                        int mark = pos;
                        if (LongString()) { pos = mark; Value(); }
                        else { pos++; Value(); Need(']'); Need('='); Value(); }
                    }
                    else if (Char.IsLetter(text[pos]) || text[pos] == '_')
                    {
                        int mark = pos; Identifier(); Space();
                        if (At("=")) { pos++; Value(); }
                        else { pos = mark; Value(); }
                    }
                    else Value();
                    Space();
                    if (At(",") || At(";")) { pos++; Space(); }
                    else if (!At("}")) Error();
                }
                Need('}');
            }
            else if (c == '\'' || c == '"') Quoted();
            else if (LongString()) { }
            else if (Char.IsLetter(c) || c == '_')
            {
                string literal = Identifier();
                if (literal != "nil" && literal != "true" && literal != "false") Error();
            }
            else
            {
                Match number = Number.Match(text, pos);
                double value;
                if (!number.Success || !Double.TryParse(number.Value, NumberStyles.Float, CultureInfo.InvariantCulture, out value) || Double.IsInfinity(value) || Double.IsNaN(value)) Error();
                pos += number.Length;
            }
            depth--;
        }
        public Dictionary<string, LuaAssignment> Read()
        {
            Dictionary<string, LuaAssignment> result = new Dictionary<string, LuaAssignment>(StringComparer.Ordinal);
            Space();
            while (pos < text.Length)
            {
                string name = Identifier(); Need('='); Space(); int start = pos; Value();
                if (result.ContainsKey(name)) Error();
                result.Add(name, new LuaAssignment { Start = start, End = pos, Value = text.Substring(start, pos - start) });
                Space(); if (At(";")) { pos++; Space(); }
            }
            return result;
        }
        public string ReadTableField(string field)
        {
            Need('{'); Space(); string result=null;
            while(pos<text.Length && text[pos]!='}')
            {
                string key=null;
                if(At("["))
                {
                    pos++; Space(); int keyStart=pos; Value(); string raw=text.Substring(keyStart,pos-keyStart);
                    if(raw=="\""+field+"\"" || raw=="'"+field+"'") key=field;
                    Need(']'); Need('=');
                }
                else if(Char.IsLetter(text[pos]) || text[pos]=='_') { key=Identifier(); Need('='); }
                Space(); int start=pos; Value();
                if(key==field) { if(result!=null) Error(); result=text.Substring(start,pos-start); }
                Space(); if(At(",") || At(";")) { pos++; Space(); } else if(!At("}")) Error();
            }
            Need('}'); Space(); if(pos!=text.Length) Error(); return result;
        }
        public static string Put(string text, string name, string value)
        {
            Dictionary<string, LuaAssignment> data = new SavedDataParser(text).Read();
            LuaAssignment old;
            return data.TryGetValue(name, out old) ? text.Substring(0, old.Start) + value + text.Substring(old.End) : text + "\r\n" + name + " = " + value + "\r\n";
        }
    }
    internal static class SavedDataMigration
    {
        private static readonly UTF8Encoding Encoding = new UTF8Encoding(false, true);
        private static readonly string[,] Specs = {
            { "GoblinIntelligence.lua", "GoblinIntelligenceDB", "UBKInterfaceDB" },
            { "UBK_Scanners.lua", "UBKScannersDB", "UBKScannersDB" }
        };
        public static bool IsDataPath(string path)
        {
            string[] parts = path.Split('/');
            if (parts.Length != 5 || parts[0] != "WTF" || parts[1] != "Account" || parts[3] != "SavedVariables") return false;
            return parts[4] == "UniversalBasisKeeper.lua" || parts[4] == Specs[0,0] || parts[4] == Specs[1,0];
        }
        private static byte[] Read(string root, string relative)
        {
            string path = System.IO.Path.Combine(root, relative.Replace('/', System.IO.Path.DirectorySeparatorChar));
            InstallerEngine.EnsureNoReparsePoints(root, path);
            if (!File.Exists(path)) return null;
            if (new FileInfo(path).Length > 64 * 1024 * 1024) throw new InvalidDataException("UBK saved data exceeds the supported migration size.");
            return File.ReadAllBytes(path);
        }
        public static List<LegacyDataSource> Prepare(string root, List<PlanFile> plans)
        {
            var sources = new List<LegacyDataSource>();
            string accounts = System.IO.Path.Combine(root,"WTF","Account");
            InstallerEngine.EnsureNoReparsePoints(root, accounts);
            if (!Directory.Exists(accounts)) return sources;
            foreach (string account in Directory.GetDirectories(accounts))
            {
                InstallerEngine.EnsureNoReparsePoints(root, account);
                string prefix = "WTF/Account/" + System.IO.Path.GetFileName(account) + "/SavedVariables/";
                string target = prefix + "UniversalBasisKeeper.lua";
                InstallerEngine.ValidateRelative(target);
                byte[] before = Read(root, target);
                string text = before == null ? String.Empty : Encoding.GetString(before);
                bool changed = false;
                Dictionary<string,LuaAssignment> current = null;
                for (int i=0;i<Specs.GetLength(0);i++)
                {
                    string sourcePath = prefix + Specs[i,0];
                    byte[] bytes = Read(root,sourcePath);
                    if (bytes == null) continue;
                    var legacy = new SavedDataParser(Encoding.GetString(bytes)).Read();
                    LuaAssignment old;
                    if (!legacy.TryGetValue(Specs[i,1],out old) || old.Value == "nil") continue;
                    if (current == null) current = new SavedDataParser(text).Read();
                    sources.Add(new LegacyDataSource { Path=sourcePath,Hash=Data.Hash(bytes),OldVariable=Specs[i,1],NewVariable=Specs[i,2],UnifiedPath=target });
                    LuaAssignment existing;
                    if (!current.TryGetValue(Specs[i,2],out existing) || existing.Value == "nil")
                    {
                        text = SavedDataParser.Put(text,Specs[i,2],old.Value);
                        current = new SavedDataParser(text).Read(); changed = true;
                    }
                }
                if (changed)
                {
                    byte[] after=Encoding.GetBytes(text);
                    plans.Add(new PlanFile { File=new PayloadFile { Path=target,Sha256=Data.Hash(after) },Payload=after,OriginalHash=Data.Hash(before),AbsolutePath=System.IO.Path.Combine(root,target.Replace('/',System.IO.Path.DirectorySeparatorChar)),MigratedData=true });
                }
            }
            return sources;
        }
        public static void CheckSources(string root,List<LegacyDataSource> sources)
        {
            foreach (var source in sources ?? new List<LegacyDataSource>())
            {
                InstallerEngine.ValidateRelative(source.Path);
                if (!IsDataPath(source.Path) || !Data.SameHash(Data.Hash(Read(root,source.Path)),source.Hash))
                    throw new InvalidOperationException("Legacy UBK saved data changed during migration. No newer edits will be overwritten.");
            }
        }
        // Carry the newest consolidated settings back when restoring older addon code.
        public static void PrepareRestore(string root,List<LegacyDataSource> sources,List<Change> changes)
        {
            CheckSources(root,sources);
            foreach (var source in sources ?? new List<LegacyDataSource>())
            {
                InstallerEngine.ValidateRelative(source.UnifiedPath);
                bool valid = false;
                for(int i=0;i<Specs.GetLength(0);i++) if(source.Path.EndsWith("/"+Specs[i,0],StringComparison.Ordinal) && source.OldVariable==Specs[i,1] && source.NewVariable==Specs[i,2]) valid=true;
                if(!valid || !source.UnifiedPath.EndsWith("/UniversalBasisKeeper.lua",StringComparison.Ordinal) || System.IO.Path.GetDirectoryName(source.Path)!=System.IO.Path.GetDirectoryName(source.UnifiedPath))
                    throw new InvalidDataException("Invalid UBK migration receipt.");
                byte[] unified=Read(root,source.UnifiedPath);
                if(unified==null) continue;
                LuaAssignment latest;
                if(!new SavedDataParser(Encoding.GetString(unified)).Read().TryGetValue(source.NewVariable,out latest)) continue;
                byte[] old=Read(root,source.Path);
                byte[] next=Encoding.GetBytes(SavedDataParser.Put(old==null?String.Empty:Encoding.GetString(old),source.OldVariable,latest.Value));
                if(!Data.SameHash(Data.Hash(old),Data.Hash(next))) changes.Add(new Change { Path=System.IO.Path.Combine(root,source.Path.Replace('/',System.IO.Path.DirectorySeparatorChar)),Before=old,After=next });
            }
        }
    }
}
