using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Text;

namespace UBKCompanionInstaller
{
    internal static class SavedDataMigrationTests
    {
        private static byte[] Bytes(string text) { return new UTF8Encoding(false).GetBytes(text); }
        private static void Require(bool ok,string message) { if(!ok) throw new Exception(message); }
        private static void Fails(Action action,string text)
        {
            try { action(); } catch(Exception e) { if(e.Message.IndexOf(text,StringComparison.OrdinalIgnoreCase)>=0) return; throw; }
            throw new Exception("Expected failure: "+text);
        }
        private static byte[] Zip(string path,byte[] bytes)
        {
            using(var buffer=new MemoryStream()) { using(var zip=new ZipArchive(buffer,ZipArchiveMode.Create,true)) { using(var output=zip.CreateEntry(path).Open()) output.Write(bytes,0,bytes.Length); } return buffer.ToArray(); }
        }
        private static void Put(string path,string text) { Directory.CreateDirectory(Path.GetDirectoryName(path)); File.WriteAllBytes(path,Bytes(text)); }
        public static void Run(string root,List<string> report)
        {
            // root is the engine's already-validated, internally-created inert TEMP fixture.
            var parsed=new SavedDataParser("A = { [\"x\"] = \"quote \\\" and slash \\\\ end\", [2] = -1.25e3, name = true, [=[line\ntext]=], nil }; -- tail\nB = {false}").Read();
            Require(parsed.Count==2 && parsed["A"].Value.Contains("-1.25e3"),"Data parser lost strings or numbers.");
            foreach(string input in new[]{"A = os.execute('x')","A = {function() end}","A = {} A = {}","A = 1+2","A = {", "A = 1e9999"})
                Fails(delegate { new SavedDataParser(input).Read(); },"data-only");
            string huge="Large = {"+String.Join(",",new string[40000]).Replace(",", "1,")+"1}";
            Require(new SavedDataParser(huge).Read().Count==1,"Large numeric table failed.");
            string corePrefix="UniversalBasisKeeperDB = { realms = { Test = { qty = 12, value = 432100 } } }\r\n";
            string save=Path.Combine(root,"WTF","Account","Fixture","SavedVariables","UniversalBasisKeeper.lua");
            string legacy=Path.Combine(Path.GetDirectoryName(save),"GoblinIntelligence.lua");
            string scanner=Path.Combine(Path.GetDirectoryName(save),"UBK_Scanners.lua");
            string legacyText="GoblinIntelligenceDB = { watchlist = { [\"i:123\"] = { addedAt = 1234, name = \"Test\\\"Item\" } } }\n";
            string scannerText="UBKScannersDB = { settings = { margin = 1.25 } }\n";
            Put(save,corePrefix); Put(legacy,legacyText); Put(scanner,scannerText);
            string second=Path.Combine(root,"WTF","Account","Second","SavedVariables","UniversalBasisKeeper.lua");
            string secondLegacy=Path.Combine(Path.GetDirectoryName(second),"GoblinIntelligence.lua");
            string secondCore="UniversalBasisKeeperDB = {}\nUBKInterfaceDB = { keep = \"newer unified state\" }\n";
            Put(second,secondCore); Put(secondLegacy,"GoblinIntelligenceDB = { keep = \"stale\" }\n");
            string code="Interface/AddOns/UniversalBasisKeeper/MigrationFixture.lua";
            string codePath=Path.Combine(root,code.Replace('/',Path.DirectorySeparatorChar));
            string retire="Interface/AddOns/GoblinIntelligence/GoblinIntelligence.toc";
            string retirePath=Path.Combine(root,retire.Replace('/',Path.DirectorySeparatorChar));
            string oldToc="## Title: legacy fixture\n"; Put(retirePath,oldToc);
            string loose=Path.Combine(Path.GetDirectoryName(retirePath),"local-notes.txt"); Put(loose,"preserve loose old data too");
            byte[] target=Bytes("-- unified fixture\n");
            var manifest=new PayloadManifest { Version="migration-test", Files=new List<PayloadFile>{new PayloadFile{Path=code,Sha256=Data.Hash(target)}},Retire=new List<PayloadFile>{new PayloadFile{Path=retire,BaselineSha256=new List<string>{Data.Hash(Bytes(oldToc))}}} };
            var engine=new InstallerEngine(Data.Write(manifest),Zip(code,target),root);
            Action<string> log=delegate(string text){ report.Add(text); };
            // An unknown legacy entry blocks all file mutations.
            Put(retirePath,"custom entry"); Fails(delegate { engine.Install(root,log); },"unrecognized");
            Require(!File.Exists(codePath) && File.ReadAllText(save)==corePrefix,"Retire preflight changed files."); Put(retirePath,oldToc);
            // Unsupported data aborts before any addon or data writes.
            Put(legacy,"GoblinIntelligenceDB = loadstring('anything')()"); Fails(delegate { engine.Install(root,log); },"data-only");
            Require(!File.Exists(codePath) && File.Exists(retirePath) && File.ReadAllText(save)==corePrefix,"Malformed migration changed files."); Put(legacy,legacyText);
            engine.Install(root,log);
            string unified=File.ReadAllText(save);
            var merged=new SavedDataParser(unified).Read();
            Require(unified.StartsWith(corePrefix,StringComparison.Ordinal) && merged.ContainsKey("UBKInterfaceDB") && merged.ContainsKey("UBKScannersDB"),"Own basis or migrated settings were lost.");
            Require(File.ReadAllText(legacy)==legacyText && File.ReadAllText(scanner)==scannerText,"Legacy source changed during install.");
            Require(File.ReadAllText(second)==secondCore,"Existing unified settings overwritten by stale legacy settings.");
            Require(!Directory.Exists(Path.GetDirectoryName(retirePath)) && File.Exists(codePath),"Legacy addon folder was not archived.");
            Require(engine.Install(root,log).Contains("already installed"),"Migration repeat was not idempotent.");
            string backup=null;
            foreach(string folder in Directory.GetDirectories(Path.Combine(root,InstallerEngine.BackupDirectory)))
            {
                var receipt=Data.Read<BackupIndex>(File.ReadAllBytes(Path.Combine(folder,"backup.json")));
                if(receipt.Version=="migration-test" && receipt.State=="installed") backup=folder;
            }
            Require(backup!=null,"Migration backup missing.");
            string latest=SavedDataParser.Put(unified,"UBKInterfaceDB","{ watchlist = { updatedAfterPlay = true } }");
            latest=SavedDataParser.Put(latest,"UniversalBasisKeeperDB","{ qty = 99, value = 876543 }"); Put(save,latest);
            engine.Restore(root,backup,log);
            Require(File.ReadAllText(save)==latest,"Restore rolled back current acquisition data.");
            Require(File.ReadAllText(legacy).Contains("updatedAfterPlay"),"Restore lost settings made after install.");
            Require(File.Exists(retirePath) && !File.Exists(codePath) && File.ReadAllText(loose)=="preserve loose old data too","Restore failed to recover old addon files/data.");
            Require(engine.Restore(root,backup,log).Contains("already restored"),"Migration restore repeat not idempotent.");
            // Rollback includes a completed data write and a retired entry.
            File.Delete(save); Put(legacy,legacyText); Put(scanner,scannerText);
            engine.AfterWriteForTest=delegate(int n){ if(n==3) throw new IOException("Injected migration write failure"); };
            Fails(delegate { engine.Install(root,log); },"rolled back");
            Require(!File.Exists(save) && !File.Exists(codePath) && File.ReadAllText(retirePath)==oldToc && File.ReadAllText(legacy)==legacyText,"Migration failure rollback lost a file.");
            Require(InstallationCompleteDialog.ConfirmationTitle=="UBK is installed" && InstallationCompleteDialog.ConfirmationButton=="Let's go! Time to solo farm the AH!","Confirmation copy mismatch.");
            report.Add("PASS: data-only parser including escaped/long strings and large numeric tables; malformed/executable data rejected; two-account migration; existing unified state wins; basis preserved; legacy folder/code archive with loose local data preserved; idempotence; restore carries newer interface settings back while preserving newer basis; failure after data write rolls back; success wording.");
        }
    }
}
