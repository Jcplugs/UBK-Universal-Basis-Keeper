using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Text;
namespace UBKCompanionInstaller
{
    internal static class TSMBridgeImportTests
    {
        private static byte[] Bytes(string text) { return new UTF8Encoding(false).GetBytes(text); }
        private static void Require(bool ok,string message) { if(!ok) throw new Exception(message); }
        private static byte[] Zip(string path,byte[] bytes) { using(var stream=new MemoryStream()) { using(var zip=new ZipArchive(stream,ZipArchiveMode.Create,true)) { using(var output=zip.CreateEntry(path).Open()) output.Write(bytes,0,bytes.Length); } return stream.ToArray(); } }
        private static void Fails(Action action,string expected) { try { action(); } catch(Exception e) { if(e.Message.IndexOf(expected,StringComparison.OrdinalIgnoreCase)>=0) return; throw; } throw new Exception("Expected failure: "+expected); }
        public static void Run(string root,List<string> report)
        {
            string tocPath=Path.Combine(root,TSMBridgeImport.Toc.Replace('/',Path.DirectorySeparatorChar));
            string bridgePath=Path.Combine(root,TSMBridgeImport.Bridge.Replace('/',Path.DirectorySeparatorChar));
            string sourcePath=Path.Combine(root,TSMBridgeImport.Source.Replace('/',Path.DirectorySeparatorChar));
            byte[] toc=Bytes("## Interface: 20506\r\n## Version: v4.14.76\r\n## SavedVariables: TradeSkillMasterDB\r\n# original loader fixture\r\n");
            byte[] source=Bytes("-- own bridge fixture\r\n");File.WriteAllBytes(tocPath,toc);
            var manifest=new PayloadManifest{Version="bridge-test",Files=new List<PayloadFile>{new PayloadFile{Path=TSMBridgeImport.Source,Sha256=Data.Hash(source)}},TsmBridge=new TSMBridgeSpec{Source=TSMBridgeImport.Source,Version="v4.14.76",TocHashes=new List<string>{Data.Hash(toc)}}};
            var engine=new InstallerEngine(Data.Write(manifest),Zip(TSMBridgeImport.Source,source),root);
            Action<string> log=delegate(string text) { report.Add(text); };
            File.AppendAllText(tocPath,"# custom edit\r\n");Fails(delegate {engine.Install(root,log);},"unrecognized");Require(!File.Exists(sourcePath),"Loader preflight changed addon files.");File.WriteAllBytes(tocPath,toc);
            engine.Install(root,log);
            Require(File.ReadAllText(tocPath).Contains("TradeSkillMasterDB, UBKBasisSaleJournal") && File.ReadAllText(tocPath).EndsWith("# UBK END GROUP BRIDGE\r\n",StringComparison.Ordinal),"Loader or same-file journal declaration missing.");
            Require(Data.SameHash(Data.FileHash(bridgePath),Data.Hash(source)),"Bridge bytes changed.");
            Require(engine.Install(root,log).Contains("already installed"),"Bridge repeat installation is not idempotent.");
            string backup=null;
            foreach(string folder in Directory.GetDirectories(Path.Combine(root,InstallerEngine.BackupDirectory))) { var index=Data.Read<BackupIndex>(File.ReadAllBytes(Path.Combine(folder,"backup.json")));if(index.Version=="bridge-test" && index.State=="installed") backup=folder; }
            Require(backup!=null,"Bridge backup missing.");
            string saved=Path.Combine(root,"WTF","Account","Fixture","SavedVariables","TradeSkillMaster.lua");
            File.WriteAllText(saved,"TradeSkillMasterDB = { groups = 'sentinel' }\nUBKBasisSaleJournal = { [\"session\"] = {phase='active'} }\n");
            string current=Data.FileHash(tocPath);Fails(delegate {engine.Restore(root,backup,log);},"return journal");Require(Data.SameHash(current,Data.FileHash(tocPath)) && File.Exists(bridgePath),"Pending-session restore changed files.");
            string completed="TradeSkillMasterDB = { groups = 'sentinel' }\nUBKBasisSaleJournal = { lastSession={message='session = { is text only'}, profiles={} }\n";
            File.WriteAllText(saved,completed);engine.Restore(root,backup,log);
            Require(Data.SameHash(Data.FileHash(tocPath),Data.Hash(toc)) && !File.Exists(bridgePath) && !File.Exists(sourcePath),"Bridge restore was not byte-exact.");
            Require(File.ReadAllText(saved)==completed,"Bridge restore wrote TSM saved data.");
            engine.AfterWriteForTest=delegate(int n) {if(n==2) throw new IOException("Injected bridge failure");};
            Fails(delegate {engine.Install(root,log);},"rolled back");
            Require(Data.SameHash(Data.FileHash(tocPath),Data.Hash(toc)) && !File.Exists(bridgePath) && !File.Exists(sourcePath),"Bridge write failure did not restore original loader.");
            engine.AfterWriteForTest=null;
            byte[] patchBridge=Bytes("-- previously distributed source-patch bridge fixture\r\n");
            File.WriteAllBytes(bridgePath,patchBridge);
            manifest.TsmBridge.BridgeHashes=new List<string>{Data.Hash(patchBridge)};
            engine=new InstallerEngine(Data.Write(manifest),Zip(TSMBridgeImport.Source,source),root);
            engine.Install(root,log);
            Require(Data.SameHash(Data.FileHash(bridgePath),Data.Hash(source)),"Known source-patch bridge was not upgraded.");
            backup=null;
            foreach(string folder in Directory.GetDirectories(Path.Combine(root,InstallerEngine.BackupDirectory)))
            {
                var index=Data.Read<BackupIndex>(File.ReadAllBytes(Path.Combine(folder,"backup.json")));
                foreach(var file in index.Files)
                    if(index.State=="installed" && file.Path==TSMBridgeImport.Bridge && Data.SameHash(file.OriginalSha256,Data.Hash(patchBridge))) backup=folder;
            }
            Require(backup!=null,"Source-patch bridge original was not backed up.");
            engine.Restore(root,backup,log);
            Require(Data.SameHash(Data.FileHash(bridgePath),Data.Hash(patchBridge)),"Source-patch bridge restore changed original bytes.");
            File.WriteAllText(bridgePath,"-- unknown user edit\r\n");
            Fails(delegate {engine.Install(root,log);},"unrecognized edits");
            Require(!File.Exists(sourcePath) && Data.SameHash(Data.FileHash(tocPath),Data.Hash(toc)),"Unknown bridge rejection changed other files.");
            File.Delete(bridgePath);
            report.Add("PASS: known source-patch integration upgrades without an older installer receipt; original bridge backup and restoration; unknown integration edits still rejected before mutation.");
            report.Add("PASS: checked TSM loader and separate UBK bridge, same-file group journal declaration, loader-edit refusal before mutation, idempotent repeat, pending-session restore block, no false journal detection in strings, byte-exact loader restoration, TSM saved data preserved, rollback after bridge write.");
        }
    }
}
