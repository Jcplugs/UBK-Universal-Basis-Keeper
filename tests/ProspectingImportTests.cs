// Run only against a separately supplied local TSM source fixture.
// Compile with installer/ProspectingImport.cs; no TSM data is embedded here.
using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

public static class ProspectingImportTests
{
    private static int checks;
    private static void Check(bool ok, string message) { checks++; if (!ok) throw new Exception(message); }
    private static string ChangeBCC(string input, string expression, string replacement)
    {
        int start = input.IndexOf("DATA.BCC", StringComparison.Ordinal);
        string before = input.Substring(0, start), after = input.Substring(start);
        Regex re = new Regex(expression);
        return before + re.Replace(after, replacement, 1);
    }
    private static void Reject(string source, string label)
    {
        bool rejected = false;
        try { ProspectingImport.GenerateFromSource(source, "test"); }
        catch (InvalidDataException) { rejected = true; }
        Check(rejected, "Parser should reject " + label);
    }
    public static int Main(string[] args)
    {
        try
        {
            if (args.Length < 1) throw new Exception("Pass the local TSM Prospect.lua path. Optional second argument is TEMP output Lua fixture path.");
            string source = File.ReadAllText(args[0], Encoding.UTF8);
            string generated = ProspectingImport.GenerateFromSource(source, "test installed version");
            Check(generated.Contains("_G.UBKProspectingData ="), "Missing data assignment");
            Check(generated.Contains("client=\"BCC\""), "Wrong era");
            Check(generated.Contains("sourceHash="), "No source fingerprint");
            Check(!generated.Contains("function"), "Executable source was copied");
            foreach (int id in new[] {2770,2771,2772,3858,10620,23424,23425}) Check(generated.Contains("[" + id + "]={skill="), "Missing supported ore");
            Check(generated.Contains("warning="), "Baseline material yield contradiction should be visible");
            Reject("DATA.BCC = {}", "empty dataset");
            Reject(source.Replace("DATA.BCC", "DATA.Unrecognized"), "missing BCC block");
            Reject(ChangeBCC(source, @"amountOfMats\s*=\s*[^,}]+", "amountOfMats = os.execute(\"must never execute\")"), "executable call");
            Reject(ChangeBCC(source, @"amountOfMats\s*=\s*[^,}]+", "amountOfMats = 1 + 1"), "expression");
            Reject(ChangeBCC(source, @"amountOfMats\s*=\s*[^,}]+", "amountOfMats = 1e309"), "infinity");
            Reject(ChangeBCC(source, @"amountOfMats\s*=\s*[^,}]+", "amountOfMats = -1"), "negative rate");
            Reject(ChangeBCC(source, @"amountOfMats\s*=\s*[^,}]+", "amountOfMats = 0"), "zero rate");
            Reject(ChangeBCC(source, @"requiredSkill\s*=\s*[^,}]+", "requiredSkill = 1000"), "out-of-era skill");
            Reject(ChangeBCC(source, @"requiredSkill\s*=\s*[^,}]+", "requiredSkill = 20.5"), "fractional skill");
            Reject(ChangeBCC(source, @"matRate\s*=\s*[^,}]+,", ""), "missing numeric field");
            Reject(ChangeBCC(source, @"matRate\s*=", "newField = 1, matRate ="), "additional numeric field");
            Reject(ChangeBCC(source, @"matRate\s*=", "matRate = 1, matRate ="), "duplicate field");
            Reject(ChangeBCC(source, "i:2770", "i:36909"), "unsupported expansion ore");
            Reject(ChangeBCC(source, "i:774", "i:999999"), "unsupported output item");
            Reject(ChangeBCC(source, "i:818", "i:774"), "duplicate output key");
            Reject("DATA.BCC = {[\"i:774\"] = {", "truncated table");
            Reject(new String(' ', 2000001), "oversized source");
            string withComments = ChangeBCC(source, @"amountOfMats\s*=", "--[=[ parser comment ]=]\n amountOfMats =");
            Check(ProspectingImport.GenerateFromSource(withComments, "test").Contains("sourceHash="), "Valid long comment not accepted");
            string withOutsideCode = source + "\nos.execute(\"never executed by importer\")\n";
            Check(ProspectingImport.GenerateFromSource(withOutsideCode, "test").Contains("sourceHash="), "Non-table Lua should remain inert");
            string hostileVersion = ProspectingImport.GenerateFromSource(source, "bad\"\\\nversion");
            Check(hostileVersion.Contains("sourceVersion=\"bad\\\"\\\\\\nversion\""), "Version string is not safely escaped");
            if (args.Length > 1) File.WriteAllText(args[1], generated, new UTF8Encoding(false));
            Console.WriteLine("PASS: " + checks + " real C# importer validation checks");
            return 0;
        }
        catch (Exception e) { Console.Error.WriteLine(e.ToString()); return 1; }
    }
}
