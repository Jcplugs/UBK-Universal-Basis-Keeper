using System;
using System.Collections.Generic;
using System.IO;
namespace UBKCompanionInstaller
{
    internal static class LegacyAddonArchive
    {
        internal static bool IsFile(string path)
        {
            return path.StartsWith("Interface/AddOns/GoblinIntelligence/",StringComparison.Ordinal) || path.StartsWith("Interface/AddOns/UBK_Scanners/",StringComparison.Ordinal);
        }
        private static HashSet<string> Roots(List<PayloadFile> entries)
        {
            var result=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach(var entry in entries ?? new List<PayloadFile>())
            {
                if(entry.Path=="Interface/AddOns/GoblinIntelligence/GoblinIntelligence.toc") result.Add("Interface/AddOns/GoblinIntelligence");
                if(entry.Path=="Interface/AddOns/UBK_Scanners/UBK_Scanners.toc") result.Add("Interface/AddOns/UBK_Scanners");
            }
            return result;
        }
        public static void Prepare(string root,List<PayloadFile> entries,List<PlanFile> plan)
        {
            var planned=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach(var file in plan) planned.Add(file.File.Path);
            foreach(string relativeRoot in Roots(entries))
            {
                string directory=Path.Combine(root,relativeRoot.Replace('/',Path.DirectorySeparatorChar));
                var stack=new Stack<string>();stack.Push(directory);
                while(stack.Count>0)
                {
                    string current=stack.Pop();InstallerEngine.EnsureNoReparsePoints(root,current);
                    if(!Directory.Exists(current)) continue;
                    foreach(string child in Directory.GetDirectories(current)) stack.Push(child);
                    foreach(string file in Directory.GetFiles(current))
                    {
                        InstallerEngine.EnsureNoReparsePoints(root,file);
                        string relative=file.Substring(root.Length+1).Replace(Path.DirectorySeparatorChar,'/');
                        InstallerEngine.ValidateRelative(relative);
                        if(!IsFile(relative)) throw new InvalidDataException("A legacy addon archive path is invalid.");
                        if(!planned.Add(relative)) continue;
                        // Retain the exact current bytes in the normal verified backup.
                        // This includes loose old code and any files added locally.
                        plan.Add(new PlanFile { File=new PayloadFile{Path=relative,Sha256=null},Payload=null,OriginalHash=Data.FileHash(file),AbsolutePath=file });
                    }
                }
            }
        }
        public static void RemoveEmptyFolders(string root,List<PayloadFile> entries)
        {
            foreach(string relative in Roots(entries))
            {
                string directory=Path.Combine(root,relative.Replace('/',Path.DirectorySeparatorChar));
                try { RemoveEmpty(root,directory); } catch(IOException) { } catch(UnauthorizedAccessException) { }
            }
        }
        private static void RemoveEmpty(string root,string directory)
        {
            InstallerEngine.EnsureNoReparsePoints(root,directory);
            if(!Directory.Exists(directory)) return;
            foreach(string child in Directory.GetDirectories(directory)) RemoveEmpty(root,child);
            if(Directory.GetFileSystemEntries(directory).Length==0) Directory.Delete(directory,false);
        }
    }
}
