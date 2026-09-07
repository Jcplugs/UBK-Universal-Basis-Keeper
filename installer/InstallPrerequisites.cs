using System;
using System.IO;

namespace UBKCompanionInstaller
{
    internal sealed class TsmFolderCheck
    {
        public bool Found;
        public string Message;
    }

    internal static class InstallPrerequisites
    {
        internal const string AddonUrl = "https://www.curseforge.com/wow/addons/tradeskill-master/files/all?page=1&pageSize=20&gameVersionTypeId=73246&showAlphaFiles=hide";
        internal const string DesktopSetupUrl = "https://support.tradeskillmaster.com/tsm-desktop-application/how-do-i-set-up-the-tsm-desktop-application?from_search=238849512";
        internal const string MissingMessage = "TradeSkillMaster was not found in this WoW directory.\r\nInstall the TSM addon using the link above, then click Check again.";

        // The presence check is deliberately directory-only. It never reads a
        // version, account data, desktop-app installation or another game folder.
        public static TsmFolderCheck Check(string selectedRoot)
        {
            if (String.IsNullOrWhiteSpace(selectedRoot))
                return new TsmFolderCheck { Message = "Choose your TBC Anniversary WoW directory to check for TSM." };
            try
            {
                string root = Path.GetFullPath(selectedRoot);
                if (!InstallerEngine.LooksLikeClient(root))
                    return new TsmFolderCheck { Message = "Choose the _anniversary_ folder containing WowClassic.exe and Interface.\r\nOther game branches and renamed client folders are not supported." };
                bool found = Directory.Exists(Path.Combine(root, "Interface", "AddOns", "TradeSkillMaster"));
                return new TsmFolderCheck { Found = found, Message = found
                    ? "TradeSkillMaster addon folder found in this WoW directory.\r\nClose WoW before installing UBK."
                    : MissingMessage };
            }
            catch (ArgumentException) { }
            catch (NotSupportedException) { }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            catch (System.Security.SecurityException) { }
            return new TsmFolderCheck { Message = "This directory could not be checked. Choose an accessible TBC Anniversary client folder." };
        }

        public static void RequireFolder(string root)
        {
            if (!Check(root).Found)
                throw new InvalidOperationException("UBK requires the TradeSkillMaster addon in the selected WoW directory. Install TSM for TBC Anniversary from the installer link, then click Check again. Nothing was installed.");
        }
    }
}
