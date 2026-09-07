using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("Universal Basis Keeper UBK")]
[assembly: AssemblyProduct("Universal Basis Keeper UBK")]
[assembly: AssemblyVersion("1.6.1.1")]
[assembly: AssemblyFileVersion("1.6.1.1")]
[assembly: AssemblyInformationalVersion("1.6.1a")]

namespace UBKCompanionInstaller
{
    [DataContract]
    internal sealed class PayloadManifest
    {
        [DataMember(Name = "version", IsRequired = true)] public string Version;
        [DataMember(Name = "files", IsRequired = true)] public List<PayloadFile> Files;
        [DataMember(Name = "retire")] public List<PayloadFile> Retire;
        [DataMember] public TSMBridgeSpec TsmBridge;
    }

    [DataContract]
    internal sealed class PayloadFile
    {
        [DataMember(Name = "path", IsRequired = true)] public string Path;
        [DataMember(Name = "sha256", IsRequired = true)] public string Sha256;
        [DataMember(Name = "baselineSha256")] public List<string> BaselineSha256;
    }

    [DataContract]
    internal sealed class BackupIndex
    {
        [DataMember(Name = "format", IsRequired = true)] public int Format = 1;
        [DataMember(Name = "clientRoot", IsRequired = true)] public string ClientRoot;
        [DataMember(Name = "version", IsRequired = true)] public string Version;
        [DataMember(Name = "state", IsRequired = true)] public string State;
        [DataMember(Name = "files", IsRequired = true)] public List<BackupFile> Files;
        [DataMember] public List<LegacyDataSource> MigrationSources;
    }

    [DataContract]
    internal sealed class BackupFile
    {
        [DataMember(Name = "path", IsRequired = true)] public string Path;
        [DataMember(Name = "originalSha256")] public string OriginalSha256;
        [DataMember(Name = "installedSha256", IsRequired = true)] public string InstalledSha256;
        [DataMember] public bool MigratedData;
    }

    internal sealed class PlanFile
    {
        public PayloadFile File;
        public byte[] Payload;
        public string OriginalHash;
        public string AbsolutePath;
        public bool MigratedData;
    }

    internal sealed class Change
    {
        public string Path;
        public byte[] Before;
        public byte[] After;
    }

    internal static class Data
    {
        public static T Read<T>(byte[] bytes)
        {
            using (MemoryStream stream = new MemoryStream(bytes))
                return (T)new DataContractJsonSerializer(typeof(T)).ReadObject(stream);
        }

        public static byte[] Write<T>(T value)
        {
            using (MemoryStream stream = new MemoryStream())
            {
                new DataContractJsonSerializer(typeof(T)).WriteObject(stream, value);
                return stream.ToArray();
            }
        }

        public static string Hash(byte[] bytes)
        {
            if (bytes == null) return null;
            using (SHA256 sha = SHA256.Create())
                return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant();
        }

        public static string FileHash(string path)
        {
            if (!File.Exists(path)) return null;
            using (FileStream file = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (SHA256 sha = SHA256.Create())
                return BitConverter.ToString(sha.ComputeHash(file)).Replace("-", "").ToLowerInvariant();
        }

        public static bool SameHash(string a, string b)
        {
            return String.Equals(a, b, StringComparison.OrdinalIgnoreCase);
        }

        public static bool IsHash(string hash)
        {
            if (hash == null || hash.Length != 64) return false;
            foreach (char ch in hash)
                if (!((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F'))) return false;
            return true;
        }
    }

    internal sealed class InstallerEngine
    {
        public const string BackupDirectory = "UBK-Companion-Backups";
        private const string ProspectingDataPath = "Interface/AddOns/UniversalBasisKeeper/UBK_ProspectingData.lua";
        private readonly PayloadManifest manifest;
        private readonly Dictionary<string, byte[]> payload;
        private readonly string fixtureRoot;
        internal Action<int> AfterWriteForTest;

        public string Version { get { return manifest.Version; } }

        public InstallerEngine(byte[] manifestBytes, byte[] zipBytes) : this(manifestBytes, zipBytes, null) { }

        // Only the in-process self-test supplies this root, after creating its own unique fixture.
        internal InstallerEngine(byte[] manifestBytes, byte[] zipBytes, string selfTestRoot)
        {
            manifest = Data.Read<PayloadManifest>(manifestBytes);
            if (manifest == null || String.IsNullOrWhiteSpace(manifest.Version) || manifest.Files == null || manifest.Files.Count == 0)
                throw new InvalidDataException("The installer manifest is empty or invalid.");
            TSMBridgeImport.Validate(manifest.TsmBridge);
            fixtureRoot = selfTestRoot == null ? null : FullRoot(selfTestRoot);
            if (fixtureRoot != null && !IsOwnTestFixture(fixtureRoot))
                throw new InvalidOperationException("Self-test access is restricted to this installer's temporary fixture.");
            HashSet<string> expected = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (PayloadFile file in manifest.Files)
            {
                ValidateRelative(file.Path);
                if (!file.Path.StartsWith("Interface/AddOns/UniversalBasisKeeper/", StringComparison.Ordinal)) throw new InvalidDataException("Only the unified UBK addon may be packaged.");
                if (!expected.Add(file.Path)) throw new InvalidDataException("Duplicate manifest path: " + file.Path);
                if (!Data.IsHash(file.Sha256)) throw new InvalidDataException("Invalid target hash: " + file.Path);
                if (file.BaselineSha256 != null)
                    foreach (string hash in file.BaselineSha256)
                        if (!Data.IsHash(hash)) throw new InvalidDataException("Invalid baseline hash: " + file.Path);
            }
            foreach (PayloadFile file in manifest.Retire ?? new List<PayloadFile>())
            {
                ValidateRelative(file.Path);
                if (!IsRetiredEntry(file.Path) || !expected.Add(file.Path) || file.Sha256 != null || file.BaselineSha256 == null || file.BaselineSha256.Count == 0)
                    throw new InvalidDataException("Invalid legacy UBK entry migration.");
                foreach (string hash in file.BaselineSha256) if (!Data.IsHash(hash)) throw new InvalidDataException("Invalid legacy entry hash.");
            }
            // Retired entries never have payload bytes.
            foreach (PayloadFile file in manifest.Retire ?? new List<PayloadFile>()) expected.Remove(file.Path);
            payload = new Dictionary<string, byte[]>(StringComparer.OrdinalIgnoreCase);
            long total = 0;
            using (MemoryStream buffer = new MemoryStream(zipBytes))
            using (ZipArchive zip = new ZipArchive(buffer, ZipArchiveMode.Read))
            {
                foreach (ZipArchiveEntry entry in zip.Entries)
                {
                    if (entry.FullName.EndsWith("/", StringComparison.Ordinal)) continue;
                    ValidateRelative(entry.FullName);
                    if (!expected.Contains(entry.FullName) || payload.ContainsKey(entry.FullName))
                        throw new InvalidDataException("Unexpected or duplicate payload file: " + entry.FullName);
                    if (entry.Length > 32 * 1024 * 1024 || (total += entry.Length) > 192 * 1024 * 1024)
                        throw new InvalidDataException("The addon payload exceeds the supported size.");
                    using (Stream input = entry.Open())
                    using (MemoryStream output = new MemoryStream())
                    {
                        input.CopyTo(output);
                        payload.Add(entry.FullName, output.ToArray());
                    }
                }
            }
            foreach (PayloadFile file in manifest.Files)
            {
                byte[] bytes;
                if (!payload.TryGetValue(file.Path, out bytes) || !Data.SameHash(Data.Hash(bytes), file.Sha256))
                    throw new InvalidDataException("Missing or damaged installer payload: " + file.Path);
            }
        }

        internal static string FullRoot(string root)
        {
            if (String.IsNullOrWhiteSpace(root)) throw new InvalidOperationException("Choose your WoW TBC Anniversary client folder.");
            return Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        }

        internal static bool IsRetiredEntry(string path)
        {
            return LegacyAddonArchive.IsFile(path);
        }

        internal static void ValidateRelative(string path)
        {
            if (String.IsNullOrEmpty(path) || path.IndexOf('\\') >= 0 || path.StartsWith("/", StringComparison.Ordinal))
                throw new InvalidDataException("Invalid addon path.");
            string[] parts = path.Split('/');
            if (!SavedDataMigration.IsDataPath(path) && !TSMBridgeImport.IsPath(path) && (parts.Length < 4 || parts[0] != "Interface" || parts[1] != "AddOns" ||
                (parts[2] != "UniversalBasisKeeper" && parts[2] != "GoblinIntelligence" && parts[2] != "UBK_Scanners")))
                throw new InvalidDataException("Only UBK companion addon files may be installed: " + path);
            foreach (string part in parts)
            {
                if (part.Length == 0 || part == "." || part == ".." || part.EndsWith(".") || part.EndsWith(" "))
                    throw new InvalidDataException("Unsafe path segment: " + path);
                foreach (char ch in part)
                    if (ch < 32 || "<>:\"|?*".IndexOf(ch) >= 0) throw new InvalidDataException("Unsafe path character: " + path);
                string stem = part.Split('.')[0].ToUpperInvariant();
                if (stem == "CON" || stem == "PRN" || stem == "AUX" || stem == "NUL" ||
                    (stem.Length == 4 && (stem.StartsWith("COM") || stem.StartsWith("LPT")) && stem[3] >= '1' && stem[3] <= '9'))
                    throw new InvalidDataException("Reserved device path: " + path);
            }
        }

        private static string TargetPath(string root, string relative)
        {
            ValidateRelative(relative);
            string result = Path.GetFullPath(Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar)));
            if (!result.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Addon path escapes the selected client.");
            EnsureNoReparsePoints(root, result);
            return result;
        }

        internal static void EnsureNoReparsePoints(string root, string path)
        {
            string current = Path.GetFullPath(path);
            string normalizedRoot = FullRoot(root);
            if (!String.Equals(current, normalizedRoot, StringComparison.OrdinalIgnoreCase) &&
                !current.StartsWith(normalizedRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("A file path is outside the selected client.");
            while (current.Length >= normalizedRoot.Length)
            {
                if ((File.Exists(current) || Directory.Exists(current)) &&
                    (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidOperationException("Linked addon or backup paths are not supported: " + current);
                if (String.Equals(current, normalizedRoot, StringComparison.OrdinalIgnoreCase)) break;
                current = Path.GetDirectoryName(current);
                if (current == null) break;
            }
        }

        internal static bool LooksLikeClient(string root)
        {
            try
            {
                return String.Equals(Path.GetFileName(FullRoot(root)), "_anniversary_", StringComparison.OrdinalIgnoreCase) &&
                    Directory.Exists(Path.Combine(root, "Interface")) &&
                    (File.Exists(Path.Combine(root, "WowClassic.exe")) || File.Exists(Path.Combine(root, "WowClassicT.exe")));
            }
            catch { return false; }
        }

        private void ValidateClient(string root, bool requireTSM)
        {
            if (!LooksLikeClient(root)) throw new InvalidOperationException("Select the _anniversary_ client folder containing WowClassic.exe and Interface. UBK supports TBC Anniversary only; other game branches and renamed client folders are not supported.");
            EnsureNoReparsePoints(root, root);
            if (fixtureRoot != null)
            {
                if (!String.Equals(root, fixtureRoot, StringComparison.OrdinalIgnoreCase) || !IsOwnTestFixture(root))
                    throw new InvalidOperationException("A self-test cannot access a live client.");
            }
            else EnsureWoWClosed();
            if (requireTSM) InstallPrerequisites.RequireFolder(root);
        }

        internal static void EnsureWoWClosed()
        {
            foreach (Process process in Process.GetProcesses())
            {
                using (process)
                {
                    string name;
                    try { name = process.ProcessName; }
                    catch (InvalidOperationException) { continue; }
                    if (String.Equals(name, "Wow", StringComparison.OrdinalIgnoreCase) ||
                        String.Equals(name, "WowClassic", StringComparison.OrdinalIgnoreCase) ||
                        String.Equals(name, "WowClassicT", StringComparison.OrdinalIgnoreCase) ||
                        String.Equals(name, "WowClassicB", StringComparison.OrdinalIgnoreCase) ||
                        String.Equals(name, "WowT", StringComparison.OrdinalIgnoreCase) ||
                        String.Equals(name, "WowB", StringComparison.OrdinalIgnoreCase))
                        throw new InvalidOperationException("Close World of Warcraft normally before installing or restoring. Let it finish saving, then try again.");
                }
            }
        }

        private static void CheckHash(string path, string expected, string message)
        {
            if (Directory.Exists(path) || !Data.SameHash(Data.FileHash(path), expected))
                throw new InvalidOperationException(message + ": " + path);
        }

        // Stage in the target directory, then commit atomically. Creation never overwrites a raced-in file.
        private static void WriteFile(string root, string path, byte[] bytes, string expected)
        {
            EnsureNoReparsePoints(root, path);
            CheckHash(path, expected, "A file changed while the installer was running");
            if (bytes == null)
            {
                if (expected != null) File.Delete(path);
                return;
            }
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            string staging = path + ".ubk-stage-" + Guid.NewGuid().ToString("N");
            try
            {
                using (FileStream output = new FileStream(staging, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    output.Write(bytes, 0, bytes.Length);
                    output.Flush(true);
                }
                EnsureNoReparsePoints(root, path);
                CheckHash(path, expected, "A file changed before its update could be committed");
                if (expected == null) File.Move(staging, path);
                else File.Replace(staging, path, null);
            }
            finally { if (File.Exists(staging)) File.Delete(staging); }
        }

        private static List<string> RollBack(string root, List<Change> changes, Action<string> log)
        {
            List<string> failures = new List<string>();
            for (int i = changes.Count - 1; i >= 0; i--)
            {
                Change change = changes[i];
                try
                {
                    string current = Data.FileHash(change.Path);
                    if (Data.SameHash(current, Data.Hash(change.Before))) continue;
                    if (!Data.SameHash(current, Data.Hash(change.After)))
                        throw new InvalidOperationException("It was changed by another program; that edit was preserved.");
                    WriteFile(root, change.Path, change.Before, Data.Hash(change.After));
                    log("Reverted: " + Path.GetFileName(change.Path));
                }
                catch (Exception error) { failures.Add(change.Path + " — " + error.Message); }
            }
            return failures;
        }

        private static void WriteIndex(string backup, BackupIndex index)
        {
            string path = Path.Combine(backup, "backup.json");
            string staging = path + "." + Guid.NewGuid().ToString("N");
            try
            {
                File.WriteAllBytes(staging, Data.Write(index));
                if (File.Exists(path)) File.Replace(staging, path, null);
                else File.Move(staging, path);
            }
            finally { if (File.Exists(staging)) File.Delete(staging); }
        }

        private bool IsRecordedGeneratedFile(string root, string relativePath, string currentHash)
        {
            if (currentHash == null) return false;
            string parent = Path.Combine(root, BackupDirectory);
            EnsureNoReparsePoints(root, parent);
            if (!Directory.Exists(parent)) return false;
            foreach (string backup in Directory.GetDirectories(parent))
            {
                string path = Path.Combine(backup, "backup.json");
                try
                {
                    EnsureNoReparsePoints(root, path);
                    if (!File.Exists(path) || new FileInfo(path).Length > 2 * 1024 * 1024) continue;
                    BackupIndex receipt = Data.Read<BackupIndex>(File.ReadAllBytes(path));
                    if (receipt == null || receipt.Format != 1 || receipt.Files == null ||
                        (receipt.State != "installed" && receipt.State != "restored") ||
                        !String.Equals(FullRoot(receipt.ClientRoot), root, StringComparison.OrdinalIgnoreCase)) continue;
                    foreach (BackupFile file in receipt.Files)
                        if (file.Path == relativePath && Data.SameHash(file.InstalledSha256, currentHash)) return true;
                }
                catch (IOException) { }
                catch (SerializationException) { }
                catch (InvalidOperationException) { }
                catch (UnauthorizedAccessException) { }
            }
            return false;
        }

        private byte[] PrepareGeneratedData(string root, Action<string> log)
        {
            try
            {
                string source = Path.Combine(root, "Interface", "AddOns", "TradeSkillMaster", "LibTSMData", "Destroy", "Prospect.lua");
                EnsureNoReparsePoints(root, source);
                string data = ProspectingImport.Generate(root);
                log("Imported prospecting yields from your installed TSM without changing its yield table.");
                return new UTF8Encoding(false).GetBytes(data);
            }
            catch (Exception error)
            {
                if (!(error is IOException || error is UnauthorizedAccessException || error is InvalidDataException || error is InvalidOperationException || error is ArgumentException)) throw;
                log("Prospecting yield import unavailable: " + error.Message + " Raw-gem profit estimates will remain unavailable until a supported local table can be imported.");
                // Keep the fallback deterministic so rerunning the installer is idempotent.
                return BytesForUnavailableProspecting();
            }
        }

        private static byte[] BytesForUnavailableProspecting()
        {
            return new UTF8Encoding(false).GetBytes("-- No compatible prospecting yield table was imported from locally installed TSM.\n_G.UBKProspectingData = { schema = 1, client = \"BCC\", ores = {}, source = \"Local yield import unavailable\" }\n");
        }

        public string Install(string selectedRoot, Action<string> log)
        {
            string root = FullRoot(selectedRoot);
            ValidateClient(root, true);
            List<PlanFile> plan = new List<PlanFile>();
            foreach (PayloadFile file in manifest.Files)
            {
                byte[] prepared = file.Path == ProspectingDataPath ? PrepareGeneratedData(root, log) : payload[file.Path];
                PayloadFile effective = new PayloadFile { Path = file.Path, Sha256 = Data.Hash(prepared), BaselineSha256 = file.BaselineSha256 };
                string target = TargetPath(root, file.Path);
                if (Directory.Exists(target)) throw new InvalidOperationException("An addon file path is a directory: " + target);
                string current = Data.FileHash(target);
                if (Data.SameHash(current, effective.Sha256)) continue;
                bool accepted = current == null;
                if (file.BaselineSha256 != null)
                    foreach (string baseline in file.BaselineSha256)
                        if (Data.SameHash(current, baseline)) accepted = true;
                if (file.Path == ProspectingDataPath && (Data.SameHash(current, file.Sha256) || IsRecordedGeneratedFile(root, ProspectingDataPath, current))) accepted = true;
                if (!accepted)
                    throw new InvalidOperationException("This file has newer or unrecognized edits: " + file.Path + ". Nothing was installed. Keep this file and obtain a package that supports its version.");
                plan.Add(new PlanFile { File = effective, Payload = prepared, OriginalHash = current, AbsolutePath = target });
            }
            foreach (PayloadFile file in manifest.Retire ?? new List<PayloadFile>())
            {
                string target = TargetPath(root, file.Path);
                if (Directory.Exists(target)) throw new InvalidOperationException("A legacy UBK addon entry is a directory.");
                string current = Data.FileHash(target);
                if (current == null) continue;
                bool accepted = false;
                foreach (string baseline in file.BaselineSha256) if (Data.SameHash(current, baseline)) accepted = true;
                if (!accepted) throw new InvalidOperationException("A legacy UBK addon entry has newer or unrecognized edits. Nothing was installed.");
                plan.Add(new PlanFile { File = file, Payload = null, OriginalHash = current, AbsolutePath = target });
            }
            LegacyAddonArchive.Prepare(root, manifest.Retire, plan);
            if (manifest.TsmBridge != null) TSMBridgeImport.Prepare(root, manifest.TsmBridge, payload[manifest.TsmBridge.Source], plan,
                delegate(string path, string hash) { return IsRecordedGeneratedFile(root, path, hash); });
            List<LegacyDataSource> migrationSources = SavedDataMigration.Prepare(root, plan);
            if (plan.Count == 0) return "UBK " + manifest.Version + " is already installed. No files changed."
                + (manifest.TsmBridge != null ? "\r\nUBK's TSM Integration is installed." : String.Empty);

            string backupParent = Path.Combine(root, BackupDirectory);
            EnsureNoReparsePoints(root, backupParent);
            string backup = Path.Combine(backupParent, DateTime.UtcNow.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N").Substring(0, 8));
            Directory.CreateDirectory(backup);
            BackupIndex index = new BackupIndex { ClientRoot = root, Version = manifest.Version, State = "prepared", Files = new List<BackupFile>(), MigrationSources = migrationSources };
            // All backup copies and hashes are verified before the first addon file changes.
            foreach (PlanFile file in plan)
            {
                EnsureNoReparsePoints(root, file.AbsolutePath);
                CheckHash(file.AbsolutePath, file.OriginalHash, "A file changed during preparation; nothing was installed");
                if (file.OriginalHash != null)
                {
                    string copy = Path.Combine(backup, "files", file.File.Path.Replace('/', Path.DirectorySeparatorChar));
                    Directory.CreateDirectory(Path.GetDirectoryName(copy));
                    File.Copy(file.AbsolutePath, copy, false);
                    CheckHash(copy, file.OriginalHash, "A backup failed verification; nothing was installed");
                }
                index.Files.Add(new BackupFile { Path = file.File.Path, OriginalSha256 = file.OriginalHash, InstalledSha256 = file.File.Sha256, MigratedData = file.MigratedData });
            }
            WriteIndex(backup, index);
            log("Backup: " + backup);
            List<Change> changes = new List<Change>();
            try
            {
                ValidateClient(root, true);
                SavedDataMigration.CheckSources(root, migrationSources);
                for (int i = 0; i < plan.Count; i++)
                {
                    PlanFile file = plan[i];
                    byte[] before = file.OriginalHash == null ? null : File.ReadAllBytes(Path.Combine(backup, "files", file.File.Path.Replace('/', Path.DirectorySeparatorChar)));
                    if (!Data.SameHash(Data.Hash(before), file.OriginalHash)) throw new InvalidDataException("A backup was changed after verification: " + file.File.Path);
                    changes.Add(new Change { Path = file.AbsolutePath, Before = before, After = file.Payload });
                    WriteFile(root, file.AbsolutePath, file.Payload, file.OriginalHash);
                    CheckHash(file.AbsolutePath, file.File.Sha256, "An installed file failed verification");
                    log(file.MigratedData ? "Preserved account settings in the unified UBK save file." : file.Payload == null ? "Archived an obsolete addon file in the verified backup." : "Updated: " + file.File.Path);
                    if (AfterWriteForTest != null) AfterWriteForTest(i);
                }
                LegacyAddonArchive.RemoveEmptyFolders(root, manifest.Retire);
                index.State = "installed";
                WriteIndex(backup, index);
                return "Installed UBK " + manifest.Version + ". Updated " + plan.Count + " files.\r\nBackup: " + backup + "\r\nUBK settings were preserved."
                    + (manifest.TsmBridge != null ? "\r\nUBK's TSM Integration is installed." : String.Empty)
                    + "\r\nYour TSM groups and operations were not edited by this installer.";
            }
            catch (Exception error)
            {
                List<string> failures = RollBack(root, changes, log);
                index.State = failures.Count == 0 ? "rolled-back" : "rollback-incomplete";
                try { WriteIndex(backup, index); } catch { }
                string message = failures.Count == 0 ? "The update failed and its changes were rolled back." : "The update failed. Some files changed outside the installer and could not safely be rolled back:\r\n" + String.Join("\r\n", failures.ToArray());
                throw new InvalidOperationException(message + "\r\nBackup: " + backup + "\r\n" + error.Message, error);
            }
        }

        public string Restore(string selectedRoot, string selectedBackup, Action<string> log)
        {
            string root = FullRoot(selectedRoot);
            ValidateClient(root, false);
            string backup = FullRoot(selectedBackup);
            string parent = Path.Combine(root, BackupDirectory);
            if (!String.Equals(Path.GetDirectoryName(backup), parent, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Choose one timestamped backup inside this client's " + BackupDirectory + " folder.");
            EnsureNoReparsePoints(root, backup);
            string indexPath = Path.Combine(backup, "backup.json");
            EnsureNoReparsePoints(root, indexPath);
            BackupIndex index = Data.Read<BackupIndex>(File.ReadAllBytes(indexPath));
            if (index == null || index.Format != 1 || index.Files == null || index.Files.Count == 0 ||
                !String.Equals(FullRoot(index.ClientRoot), root, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("The backup does not belong to the selected client.");
            foreach (BackupFile entry in index.Files) if (TSMBridgeImport.IsPath(entry.Path)) { TSMBridgeImport.RequireReturnedSessions(root); break; }
            HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            List<Change> changes = new List<Change>();
            foreach (BackupFile file in index.Files)
            {
                ValidateRelative(file.Path);
                if (!seen.Add(file.Path) || (!Data.IsHash(file.InstalledSha256) && !(file.InstalledSha256 == null && IsRetiredEntry(file.Path))) || (file.OriginalSha256 != null && !Data.IsHash(file.OriginalSha256)))
                    throw new InvalidDataException("The backup index has an invalid file record.");
                if (file.MigratedData)
                {
                    if (!SavedDataMigration.IsDataPath(file.Path) || !file.Path.EndsWith("/UniversalBasisKeeper.lua", StringComparison.Ordinal)) throw new InvalidDataException("Invalid UBK migration target.");
                    // Preserve current basis and carry current interface state back below.
                    continue;
                }
                if (SavedDataMigration.IsDataPath(file.Path)) throw new InvalidDataException("Unexpected saved-data backup record.");
                string target = TargetPath(root, file.Path);
                if (Directory.Exists(target)) throw new InvalidOperationException("A restore target is a directory: " + file.Path);
                string current = Data.FileHash(target);
                byte[] original = null;
                if (file.OriginalSha256 != null)
                {
                    string source = Path.Combine(backup, "files", file.Path.Replace('/', Path.DirectorySeparatorChar));
                    EnsureNoReparsePoints(root, source);
                    original = File.ReadAllBytes(source);
                    if (!Data.SameHash(Data.Hash(original), file.OriginalSha256)) throw new InvalidDataException("A backup copy was changed or damaged: " + file.Path);
                }
                if (Data.SameHash(current, file.OriginalSha256)) continue;
                if (!Data.SameHash(current, file.InstalledSha256))
                    throw new InvalidOperationException("Restore stopped because this addon file has newer or unrecognized edits: " + file.Path + ". Nothing was restored.");
                byte[] installed = current == null ? null : File.ReadAllBytes(target);
                if (!Data.SameHash(Data.Hash(installed), file.InstalledSha256))
                    throw new InvalidOperationException("A file changed during restore preparation; nothing was restored: " + file.Path);
                changes.Add(new Change { Path = target, Before = installed, After = original });
            }
            if (index.State != "restored" && index.State != "rolled-back") SavedDataMigration.PrepareRestore(root, index.MigrationSources, changes);
            if (changes.Count == 0) return "This backup is already restored. No files changed.";
            List<Change> attempted = new List<Change>();
            try
            {
                ValidateClient(root, false);
                foreach (Change change in changes)
                {
                    attempted.Add(change);
                    WriteFile(root, change.Path, change.After, Data.Hash(change.Before));
                    CheckHash(change.Path, Data.Hash(change.After), "A restored file failed verification");
                    log("Restored a UBK file from this backup.");
                }
                index.State = "restored";
                WriteIndex(backup, index);
                return "Restored " + changes.Count + " files. Current UBK basis and interface settings were preserved. The selected backup determines whether the TSM bridge is restored or removed.";
            }
            catch (Exception error)
            {
                List<string> failures = RollBack(root, attempted, log);
                string message = failures.Count == 0 ? "Restore failed; its changes were rolled back." : "Restore failed; preserve the backup. Some external edits prevented rollback:\r\n" + String.Join("\r\n", failures.ToArray());
                throw new InvalidOperationException(message + "\r\n" + error.Message, error);
            }
        }

        private static bool IsOwnTestFixture(string root)
        {
            string parent = Path.GetDirectoryName(root);
            if (parent == null || !Path.GetFileName(parent).StartsWith("UBK-Installer-SelfTest-", StringComparison.Ordinal) ||
                !String.Equals(FullRoot(Path.GetDirectoryName(parent)), FullRoot(Path.GetTempPath()), StringComparison.OrdinalIgnoreCase) ||
                Path.GetFileName(root) != "_anniversary_") return false;
            string marker = Path.Combine(parent, "fixture-only.txt");
            return File.Exists(marker) && File.ReadAllText(marker) == "UBK self-test: inert temporary client only";
        }
    }

    internal sealed class InstallationCompleteDialog : Form
    {
        internal const string ConfirmationTitle = "UBK is installed";
        internal const string ConfirmationButton = "Let's go! Time to solo farm the AH!";

        public InstallationCompleteDialog(string details)
        {
            Text = ConfirmationTitle;
            ClientSize = new Size(600, 286);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.CenterParent;
            Font = new Font("Segoe UI", 10F);
            AutoScaleMode = AutoScaleMode.Dpi;
            Label title = new Label { Text = ConfirmationTitle, AutoSize = true,
                Font = new Font("Segoe UI", 18F, FontStyle.Bold), Location = new Point(24, 22) };
            Label next = new Label { Text = "Open WoW when you're ready. Type /ubk to open your workspace.",
                Location = new Point(26, 72), Size = new Size(548, 46) };
            TextBox result = new TextBox { Text = details ?? String.Empty, Multiline = true,
                ReadOnly = true, ScrollBars = ScrollBars.Vertical, BorderStyle = BorderStyle.None,
                BackColor = SystemColors.Control, Location = new Point(26, 121), Size = new Size(548, 82) };
            Button done = new Button { Text = ConfirmationButton, DialogResult = DialogResult.OK,
                Location = new Point(85, 221), Size = new Size(430, 40), TabIndex = 0 };
            AcceptButton = done;
            CancelButton = done;
            Controls.AddRange(new Control[] { title, next, result, done });
        }
    }

    internal sealed class InstallerForm : Form
    {
        private readonly InstallerEngine engine;
        private readonly TextBox folder = new TextBox();
        private readonly TextBox log = new TextBox();
        private readonly Button install = new Button();
        private readonly Button restore = new Button();
        private readonly Button browse = new Button();
        private readonly Button recheck = new Button();
        private readonly Label dependency = new Label();
        private readonly System.Windows.Forms.Timer folderCheckTimer = new System.Windows.Forms.Timer();
        private readonly BackgroundWorker worker = new BackgroundWorker();
        private bool restoringOperation;
        private bool tsmFolderFound;

        public InstallerForm(InstallerEngine installer)
        {
            engine = installer;
            Text = "Universal Basis Keeper UBK - V " + engine.Version;
            ClientSize = new Size(800, 724);
            MinimumSize = Size;
            StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Segoe UI", 10F);
            AutoScaleMode = AutoScaleMode.Dpi;
            Label heading = new Label { Text = Text, AutoSize = true, Font = new Font("Segoe UI", 17F, FontStyle.Bold), Location = new Point(24, 20) };
            Label description = new Label { Text = "TBC Anniversary realms only.\r\nTradeSkillMaster addon is required. UBK cannot work without it.", Location = new Point(26, 62), Size = new Size(748, 44), Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right };
            LinkLabel addonLink = HelpLink("Download TradeSkillMaster addon (CurseForge)", InstallPrerequisites.AddonUrl, 110);
            Label desktopInfo = new Label { Text = "TSM's Desktop Application is optional. UBK works without it.\r\nFor richer auctioning comparisons, use the Desktop App with AppHelper\r\nto keep market data refreshed.", Location = new Point(26, 145), Size = new Size(748, 58), Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right };
            LinkLabel desktopLink = HelpLink("How to set up the TSM Desktop Application (official guide)", InstallPrerequisites.DesktopSetupUrl, 211);
            Label folderLabel = new Label { Text = "TBC Anniversary WoW directory: World of Warcraft\\_anniversary_", Location = new Point(26, 250), AutoSize = true };
            folder.Name = "clientFolder";
            folder.Location = new Point(26, 279); folder.Size = new Size(635, 28); folder.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            browse.Text = "Browse..."; browse.Location = new Point(670, 277); browse.Size = new Size(104, 31); browse.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            browse.Click += delegate { using (FolderBrowserDialog picker = new FolderBrowserDialog()) { picker.Description = "Choose the _anniversary_ folder containing WowClassic.exe and Interface."; picker.SelectedPath = folder.Text; if (picker.ShowDialog(this) == DialogResult.OK) SelectClient(picker.SelectedPath); } };
            dependency.Name = "tsmStatus";
            dependency.Location = new Point(26, 323); dependency.Size = new Size(599, 57); dependency.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            dependency.Text = InstallPrerequisites.Check(null).Message;
            recheck.Name = "checkAgain";
            recheck.Text = "Check again"; recheck.Location = new Point(638, 321); recheck.Size = new Size(136, 31); recheck.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            recheck.Click += delegate { CheckTSMFolder(); };
            folderCheckTimer.Interval = 350;
            folderCheckTimer.Tick += delegate { CheckTSMFolder(); };
            folder.TextChanged += delegate
            {
                tsmFolderFound = false; install.Enabled = false;
                dependency.Text = "Checking the selected directory..."; dependency.ForeColor = SystemColors.ControlText;
                folderCheckTimer.Stop(); if (!worker.IsBusy) folderCheckTimer.Start();
            };
            folder.Leave += delegate { if (!worker.IsBusy) CheckTSMFolder(); };
            folder.KeyDown += delegate(object sender, KeyEventArgs args) { if (args.KeyCode == Keys.Enter) { args.SuppressKeyPress = true; CheckTSMFolder(); } };
            Label details = new Label { Text = "Close WoW first. Updates UBK code and preserves your settings and history.\r\nAdds the checked TSM integration and backs up its loader change.\r\nObsolete addon folders are archived; no groups move during installation.", Location = new Point(26, 389), Size = new Size(748, 57), Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right };
            install.Name = "installButton"; install.Enabled = false;
            install.Text = "Install UBK " + engine.Version; install.Location = new Point(26, 461); install.Size = new Size(212, 37);
            restore.Text = "Restore a backup..."; restore.Location = new Point(253, 461); restore.Size = new Size(184, 37);
            install.Click += delegate { StartOperation(false, null); };
            restore.Click += delegate
            {
                if (String.IsNullOrWhiteSpace(folder.Text)) { MessageBox.Show(this, "Choose your WoW client folder first."); return; }
                using (FolderBrowserDialog picker = new FolderBrowserDialog())
                {
                    picker.Description = "Choose the timestamped backup to restore. Restore stops if an addon file has unrecognized newer edits.";
                    picker.SelectedPath = Path.Combine(folder.Text, InstallerEngine.BackupDirectory);
                    if (picker.ShowDialog(this) == DialogResult.OK && MessageBox.Show(this, "Restore the addon code and checked loader changes from this backup?\r\n\r\n" + picker.SelectedPath + "\r\n\r\nCurrent basis history is preserved. Current interface settings are carried back when older addon code needs them. Resolve any pending Sell Above Basis returns first.", "Restore UBK backup", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes)
                        StartOperation(true, picker.SelectedPath);
                }
            };
            log.Location = new Point(26, 515); log.Size = new Size(748, 151); log.Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right;
            log.Multiline = true; log.ReadOnly = true; log.ScrollBars = ScrollBars.Vertical; log.BackColor = Color.White;
            log.Text = "Choose your WoW directory to check for the required TSM addon folder.\r\nOpening this window and checking the folder do not install anything.";
            Label signature = new Label { Name = "signature", Text = "-Jc", ForeColor = Color.FromArgb(139, 0, 0), Font = new Font("Segoe UI", 12F, FontStyle.Bold), TextAlign = ContentAlignment.MiddleRight, Location = new Point(706, 684), Size = new Size(68, 26), Anchor = AnchorStyles.Bottom | AnchorStyles.Right };
            Controls.AddRange(new Control[] { heading, description, addonLink, desktopInfo, desktopLink, folderLabel, folder, browse, dependency, recheck, details, install, restore, log, signature });
            worker.WorkerReportsProgress = true;
            worker.ProgressChanged += delegate(object sender, ProgressChangedEventArgs args) { log.AppendText("\r\n" + (string)args.UserState); };
            worker.RunWorkerCompleted += delegate(object sender, RunWorkerCompletedEventArgs args)
            {
                SetBusy(false);
                if (args.Error != null) { log.AppendText("\r\n\r\n" + args.Error.Message); MessageBox.Show(this, args.Error.Message, "UBK installer stopped", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
                else
                {
                    log.AppendText("\r\n\r\n" + (string)args.Result);
                    if (restoringOperation)
                        MessageBox.Show(this, (string)args.Result, "UBK backup restored", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    else
                        using (InstallationCompleteDialog confirmation = new InstallationCompleteDialog((string)args.Result))
                            confirmation.ShowDialog(this);
                }
            };
            FormClosing += delegate(object sender, FormClosingEventArgs args) { if (worker.IsBusy) { args.Cancel = true; MessageBox.Show(this, "Please let the file update or rollback finish before closing."); } };
            Disposed += delegate { folderCheckTimer.Dispose(); };
        }

        private LinkLabel HelpLink(string text, string url, int y)
        {
            LinkLabel link = new LinkLabel { Text = text, AutoSize = true, Location = new Point(26, y), TabStop = true };
            link.LinkClicked += delegate
            {
                try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
                catch (Exception) { MessageBox.Show(this, "Open this address in your browser:\r\n\r\n" + url, "TSM setup link", MessageBoxButtons.OK, MessageBoxIcon.Information); }
            };
            return link;
        }

        internal void SelectClient(string path)
        {
            folder.Text = path;
            CheckTSMFolder();
        }

        private void CheckTSMFolder()
        {
            folderCheckTimer.Stop();
            if (worker.IsBusy) return;
            TsmFolderCheck check = InstallPrerequisites.Check(folder.Text);
            tsmFolderFound = check.Found;
            dependency.Text = check.Message;
            dependency.ForeColor = check.Found ? Color.FromArgb(24, 100, 48) : SystemColors.ControlText;
            install.Enabled = check.Found;
        }

        private void SetBusy(bool busy)
        {
            folder.Enabled = browse.Enabled = recheck.Enabled = restore.Enabled = !busy;
            install.Enabled = !busy && tsmFolderFound;
            if (busy) folderCheckTimer.Stop(); else CheckTSMFolder();
            UseWaitCursor = busy;
        }

        private void StartOperation(bool restoring, string backup)
        {
            if (worker.IsBusy) return;
            if (!restoring) { CheckTSMFolder(); if (!tsmFolderFound) return; }
            string clientRoot = folder.Text;
            restoringOperation = restoring;
            log.Clear(); SetBusy(true);
            DoWorkEventHandler handler = null;
            handler = delegate(object sender, DoWorkEventArgs args)
            {
                worker.DoWork -= handler;
                Action<string> report = delegate(string message) { worker.ReportProgress(0, message); };
                args.Result = restoring ? engine.Restore(clientRoot, backup, report) : engine.Install(clientRoot, report);
            };
            worker.DoWork += handler;
            worker.RunWorkerAsync();
        }

    }

    internal static class Program
    {
        internal static byte[] Resource(string name)
        {
            using (Stream input = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
            {
                if (input == null) throw new InvalidDataException("Missing installer resource: " + name);
                using (MemoryStream output = new MemoryStream()) { input.CopyTo(output); return output.ToArray(); }
            }
        }

        [STAThread]
        private static int Main(string[] args)
        {
            if (args.Length == 1 && args[0] == "--self-test") return SelfTest.Run();
            if (args.Length != 0) return 2; // No unattended install or arbitrary destination argument.
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            try { Application.Run(new InstallerForm(new InstallerEngine(Resource("UBKManifest.json"), Resource("UBKPayload.zip")))); return 0; }
            catch (Exception error) { MessageBox.Show(error.Message, "UBK installer could not open", MessageBoxButtons.OK, MessageBoxIcon.Error); return 1; }
        }
    }

    internal static class SelfTest
    {
        private static void Require(bool condition, string message) { if (!condition) throw new Exception(message); }
        private static void ExpectFailure(Action action, string text)
        {
            try { action(); }
            catch (Exception error) { Require(error.Message.IndexOf(text, StringComparison.OrdinalIgnoreCase) >= 0, "Unexpected failure: " + error.Message); return; }
            throw new Exception("Expected rejection: " + text);
        }

        private static byte[] Bytes(string value) { return Encoding.UTF8.GetBytes(value); }

        private static string MakeFixture(string parent)
        {
            string root = Path.Combine(parent, "_anniversary_");
            Directory.CreateDirectory(Path.Combine(root, "Interface", "AddOns", "TradeSkillMaster"));
            File.WriteAllText(Path.Combine(root, "WowClassic.exe"), "INERT SELF-TEST FIXTURE — NEVER EXECUTE");
            File.WriteAllText(Path.Combine(root, "Interface", "AddOns", "TradeSkillMaster", "TradeSkillMaster.toc"), "fixture sentinel");
            File.WriteAllText(Path.Combine(parent, "fixture-only.txt"), "UBK self-test: inert temporary client only");
            return root;
        }

        private static byte[] Zip(Dictionary<string, byte[]> files)
        {
            using (MemoryStream buffer = new MemoryStream())
            {
                using (ZipArchive zip = new ZipArchive(buffer, ZipArchiveMode.Create, true))
                    foreach (KeyValuePair<string, byte[]> file in files)
                    {
                        ZipArchiveEntry entry = zip.CreateEntry(file.Key);
                        using (Stream output = entry.Open()) output.Write(file.Value, 0, file.Value.Length);
                    }
                return buffer.ToArray();
            }
        }

        public static int Run()
        {
            // This mode never takes a folder argument and never discovers or opens a real WoW client.
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            string parent = Path.Combine(Path.GetTempPath(), "UBK-Installer-SelfTest-" + Guid.NewGuid().ToString("N"));
            List<string> report = new List<string>();
            int result = 1;
            Directory.CreateDirectory(parent);
            try
            {
                InstallerEngine embedded = new InstallerEngine(Program.Resource("UBKManifest.json"), Program.Resource("UBKPayload.zip"));
                report.Add("PASS: embedded manifest, allowed paths and every payload hash validated (version " + embedded.Version + ").");
                string root = MakeFixture(parent);
                string existing = "Interface/AddOns/UniversalBasisKeeper/UniversalBasisKeeper.lua";
                string added = "Interface/AddOns/UniversalBasisKeeper/UniversalBasisKeeper.toc";
                string generated = "Interface/AddOns/UniversalBasisKeeper/UBK_ProspectingData.lua";
                byte[] original = Bytes("old addon\r\n");
                Dictionary<string, byte[]> files = new Dictionary<string, byte[]> { { existing, Bytes("new addon\r\n") }, { added, Bytes("new toc\r\n") }, { generated, Bytes("-- placeholder only\r\n") } };
                PayloadManifest manifest = new PayloadManifest { Version = embedded.Version, Files = new List<PayloadFile>() };
                foreach (KeyValuePair<string, byte[]> file in files)
                    manifest.Files.Add(new PayloadFile { Path = file.Key, Sha256 = Data.Hash(file.Value), BaselineSha256 = file.Key == existing ? new List<string> { Data.Hash(original) } : new List<string>() });
                InstallerEngine engine = new InstallerEngine(Data.Write(manifest), Zip(files), root);
                string existingPath = Path.Combine(root, existing.Replace('/', Path.DirectorySeparatorChar));
                string addedPath = Path.Combine(root, added.Replace('/', Path.DirectorySeparatorChar));
                string generatedPath = Path.Combine(root, generated.Replace('/', Path.DirectorySeparatorChar));
                string saved = Path.Combine(root, "WTF", "Account", "Fixture", "SavedVariables", "UniversalBasisKeeper.lua");
                Directory.CreateDirectory(Path.GetDirectoryName(saved)); File.WriteAllText(saved, "saved settings sentinel");
                Directory.CreateDirectory(Path.GetDirectoryName(existingPath)); File.WriteAllBytes(existingPath, original);
                Action<string> log = delegate(string text) { report.Add(text); };
                InstallPrerequisitesTests.Run(root, engine, report);
                engine.Install(root, log);
                Require(Data.SameHash(Data.FileHash(existingPath), Data.Hash(files[existing])), "Existing file not upgraded.");
                Require(Data.SameHash(Data.FileHash(addedPath), Data.Hash(files[added])), "Missing addon file not installed.");
                Require(File.ReadAllText(generatedPath).Contains("Local yield import unavailable") && !Data.SameHash(Data.FileHash(generatedPath), Data.Hash(files[generated])), "Dynamic fallback was not generated locally.");
                Require(File.ReadAllText(saved) == "saved settings sentinel", "SavedVariables changed.");
                Require(File.ReadAllText(Path.Combine(root, "Interface", "AddOns", "TradeSkillMaster", "TradeSkillMaster.toc")) == "fixture sentinel", "TSM changed.");
                Require(engine.Install(root, log).Contains("already installed"), "Repeat install not idempotent.");
                string backup = Directory.GetDirectories(Path.Combine(root, InstallerEngine.BackupDirectory))[0];
                BackupIndex receipt = Data.Read<BackupIndex>(File.ReadAllBytes(Path.Combine(backup, "backup.json")));
                foreach (BackupFile record in receipt.Files)
                    if (record.Path == generated) Require(Data.SameHash(record.InstalledSha256, Data.FileHash(generatedPath)), "Backup did not record the generated content hash.");
                File.WriteAllText(existingPath, "external edit");
                ExpectFailure(delegate { engine.Restore(root, backup, log); }, "newer or unrecognized");
                Require(File.Exists(addedPath), "Restore conflict modified another file.");
                ExpectFailure(delegate { engine.Install(root, log); }, "newer or unrecognized");
                File.WriteAllBytes(existingPath, files[existing]);
                engine.Restore(root, backup, log);
                Require(Data.SameHash(Data.FileHash(existingPath), Data.Hash(original)) && !File.Exists(addedPath) && !File.Exists(generatedPath), "Restore did not recover original state.");
                Require(engine.Restore(root, backup, log).Contains("already restored"), "Repeat restore not idempotent.");
                engine.AfterWriteForTest = delegate(int number) { if (number == 0) throw new IOException("Injected file failure"); };
                ExpectFailure(delegate { engine.Install(root, log); }, "rolled back");
                Require(Data.SameHash(Data.FileHash(existingPath), Data.Hash(original)) && !File.Exists(addedPath), "Failed install not rolled back.");
                engine.AfterWriteForTest = delegate(int number) { if (number == 0) { File.WriteAllText(existingPath, "external edit during update"); throw new IOException("Injected external edit"); } };
                ExpectFailure(delegate { engine.Install(root, log); }, "could not safely be rolled back");
                Require(File.ReadAllText(existingPath) == "external edit during update" && !File.Exists(addedPath), "Rollback overwrote an external edit.");
                File.WriteAllBytes(existingPath, original);
                engine.AfterWriteForTest = null;
                foreach (string path in new string[] { "WTF/Account/Fixture/SavedVariables/TradeSkillMaster.lua", "Interface/AddOns/TradeSkillMaster/TradeSkillMaster.lua", "Interface/AddOns/UniversalBasisKeeper/../escape.lua", "Interface/AddOns/UniversalBasisKeeper/CON.lua" })
                    ExpectFailure(delegate { InstallerEngine.ValidateRelative(path); }, path.Contains("CON") ? "Reserved" : path.Contains("..") ? "Unsafe" : "Only UBK");
                ExpectFailure(delegate { engine.Install(Path.GetTempPath(), log); }, "client folder");
                File.Delete(existingPath);
                engine.Install(root, log);
                Require(Data.SameHash(Data.FileHash(existingPath), Data.Hash(files[existing])), "Fresh installation failed.");
                report.Add("PASS: upgrade, missing addon, generated-data fallback and actual receipt hash, idempotence, intact SavedVariables/TSM sentinels, conflict rejection before mutation, reversible restore, failure rollback, preserving a concurrent external edit, forbidden paths, arbitrary fixture-path rejection, fresh install.");
                SavedDataMigrationTests.Run(root, report);
                TSMBridgeImportTests.Run(root, report);
                result = 0;
            }
            catch (Exception error) { report.Add("FAIL: " + error.ToString()); }
            finally
            {
                // Leave a uniquely named report beside the fixture for the build operator.
                File.WriteAllLines(Path.Combine(parent, "self-test-result.txt"), report.ToArray());
                try { Directory.Delete(Path.Combine(parent, "_anniversary_"), true); } catch { }
            }
            return result;
        }
    }
}
