// This is UBK-owned integration code. No TSM implementation is redistributed.
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.Serialization;
using System.Text;
using System.Text.RegularExpressions;
namespace UBKCompanionInstaller
{
    [DataContract]
    internal sealed class TSMBridgeSpec
    {
        [DataMember] public string Source;
        [DataMember] public string Version;
        [DataMember] public List<string> TocHashes;
        [DataMember] public List<string> BridgeHashes;
    }
    internal static class TSMBridgeImport
    {
        public const string Toc="Interface/AddOns/TradeSkillMaster/TradeSkillMaster.toc";
        public const string Bridge="Interface/AddOns/TradeSkillMaster/UBK_GroupBridge.lua";
        public const string Source="Interface/AddOns/UniversalBasisKeeper/UBK_TSMBridge.lua";
        private const string Marker="\r\n# UBK BEGIN GROUP BRIDGE\r\nUBK_GroupBridge.lua\r\n# UBK END GROUP BRIDGE\r\n";
        private static readonly UTF8Encoding Encoding=new UTF8Encoding(false,true);
        public static bool IsPath(string path) { return path==Toc || path==Bridge; }
        public static void Validate(TSMBridgeSpec spec)
        {
            if(spec==null) return;
            if(spec.Source!=Source || spec.Version!="v4.14.76" || spec.TocHashes==null || spec.TocHashes.Count==0) throw new InvalidDataException("Invalid TSM bridge specification.");
            foreach(string hash in spec.TocHashes) if(!Data.IsHash(hash)) throw new InvalidDataException("Invalid TSM loader baseline.");
            foreach(string hash in spec.BridgeHashes ?? new List<string>()) if(!Data.IsHash(hash)) throw new InvalidDataException("Invalid UBK integration baseline.");
        }
        public static void Prepare(string root,TSMBridgeSpec spec,byte[] bridge,List<PlanFile> plan,Func<string,string,bool> recorded)
        {
            if(spec==null) return;
            Validate(spec);
            string tocPath=Path.Combine(root,Toc.Replace('/',Path.DirectorySeparatorChar));
            InstallerEngine.EnsureNoReparsePoints(root,tocPath);
            if(!File.Exists(tocPath)) throw new InvalidOperationException("The TradeSkillMaster folder is present, but its addon loader is missing. Reinstall the complete TSM addon for TBC Anniversary using the installer link, then try again. Nothing was installed.");
            byte[] before=File.ReadAllBytes(tocPath);
            string text=Encoding.GetString(before);
            string clean=text;
            if(text.Contains("# UBK BEGIN GROUP BRIDGE"))
            {
                if(!text.EndsWith(Marker,StringComparison.Ordinal)) throw new InvalidDataException("The UBK integration loader has unrecognized edits.");
                clean=text.Substring(0,text.Length-Marker.Length);
                var oldHeader=Regex.Match(clean,@"(?m)^## SavedVariables:([^\r\n]*)");
                if(!oldHeader.Success || !oldHeader.Groups[1].Value.EndsWith(", UBKBasisSaleJournal",StringComparison.Ordinal)) throw new InvalidDataException("The UBK return-journal loader has unrecognized edits.");
                clean=clean.Remove(oldHeader.Index+oldHeader.Length-", UBKBasisSaleJournal".Length,", UBKBasisSaleJournal".Length);
            }
            string cleanHash=Data.Hash(Encoding.GetBytes(clean)); bool accepted=false;
            foreach(string hash in spec.TocHashes) if(Data.SameHash(cleanHash,hash)) accepted=true;
            if(!accepted) throw new InvalidOperationException("This TSM loader does not match UBK's checked integration and may have unrecognized edits. No files were changed. A compatible UBK integration is needed before this loader can be updated.");
            var headers=Regex.Matches(clean,@"(?m)^## SavedVariables:([^\r\n]*)");
            if(headers.Count!=1 || headers[0].Value.Contains("UBKBasisSaleJournal")) throw new InvalidDataException("Unexpected TSM saved-data declaration.");
            var header=headers[0];
            byte[] next=Encoding.GetBytes(clean.Insert(header.Index+header.Length,", UBKBasisSaleJournal")+Marker);
            if(!Data.SameHash(Data.Hash(before),Data.Hash(next))) plan.Add(new PlanFile { File=new PayloadFile{Path=Toc,Sha256=Data.Hash(next)},Payload=next,OriginalHash=Data.Hash(before),AbsolutePath=tocPath });
            string target=Path.Combine(root,Bridge.Replace('/',Path.DirectorySeparatorChar));
            InstallerEngine.EnsureNoReparsePoints(root,target);
            if(Directory.Exists(target)) throw new InvalidOperationException("The UBK integration target is a directory. Nothing was installed.");
            string current=Data.FileHash(target), desired=Data.Hash(bridge);
            if(Data.SameHash(current,desired)) return;
            bool bridgeAccepted=current==null || recorded(Bridge,current);
            foreach(string hash in spec.BridgeHashes ?? new List<string>()) if(Data.SameHash(current,hash)) bridgeAccepted=true;
            if(!bridgeAccepted) throw new InvalidOperationException("The UBK TSM integration file has unrecognized edits. Nothing was installed.");
            plan.Add(new PlanFile { File=new PayloadFile{Path=Bridge,Sha256=desired},Payload=bridge,OriginalHash=current,AbsolutePath=target });
        }
        public static void RequireReturnedSessions(string root)
        {
            string accounts=Path.Combine(root,"WTF","Account"); InstallerEngine.EnsureNoReparsePoints(root,accounts);
            if(!Directory.Exists(accounts)) return;
            foreach(string account in Directory.GetDirectories(accounts))
            {
                string source=Path.Combine(account,"SavedVariables","TradeSkillMaster.lua"); InstallerEngine.EnsureNoReparsePoints(root,source);
                if(!File.Exists(source)) continue;
                if(new FileInfo(source).Length>64*1024*1024) throw new InvalidOperationException("TSM saved data is too large to verify pending group returns. Return all Sell Above Basis items in WoW before restoring an older version.");
                var globals=new SavedDataParser(Encoding.GetString(File.ReadAllBytes(source))).Read(); LuaAssignment journal;
                if(!globals.TryGetValue("UBKBasisSaleJournal",out journal) || journal.Value=="nil") continue;
                string session=new SavedDataParser(journal.Value).ReadTableField("session");
                if(session!=null && session!="nil") throw new InvalidOperationException("Sell Above Basis still has a return journal. Open WoW with the current UBK integration, return or resolve those items, and close WoW before restoring older addon code. No files were restored.");
            }
        }
    }
}
