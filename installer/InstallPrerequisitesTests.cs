using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

namespace UBKCompanionInstaller
{
    internal static class InstallPrerequisitesTests
    {
        private static void Require(bool value, string message) { if (!value) throw new Exception(message); }
        public static void Run(string root, InstallerEngine engine, List<string> report)
        {
            string tsm = Path.Combine(root, "Interface", "AddOns", "TradeSkillMaster");
            string toc = Path.Combine(tsm, "TradeSkillMaster.toc");
            string parked = tsm + ".fixture-parked";
            Require(!InstallPrerequisites.Check(null).Found && !InstallPrerequisites.Check(Path.GetTempPath()).Found, "Unselected/invalid client passed dependency check.");
            foreach(string branch in new string[]{"_classic_", "_classic_era_", "_retail_", "renamed-client"})
            {
                string other=Path.Combine(Path.GetDirectoryName(root),branch);
                Directory.CreateDirectory(Path.Combine(other,"Interface","AddOns","TradeSkillMaster"));
                File.WriteAllText(Path.Combine(other,"WowClassic.exe"),"inert unsupported-client fixture");
                try
                {
                    Require(!InstallerEngine.LooksLikeClient(other) && !InstallPrerequisites.Check(other).Found,"Unsupported client branch passed prerequisite check: "+branch);
                    bool blocked=false;
                    try { engine.Install(other,delegate(string text){}); }
                    catch(InvalidOperationException e) { blocked=e.Message.Contains("_anniversary_"); }
                    Require(blocked && !Directory.Exists(Path.Combine(other,InstallerEngine.BackupDirectory)),"Unsupported client rejection occurred after writes: "+branch);
                }
                finally { Directory.Delete(other,true); }
            }
            // Lock the loader against reads. Finding the folder must still work.
            using (var locked = new FileStream(toc, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
                Require(InstallPrerequisites.Check(root).Found, "Folder check tried to inspect TSM contents or its version.");
            Directory.Move(tsm, parked);
            try
            {
                Require(!InstallPrerequisites.Check(root).Found, "TSM in another folder incorrectly satisfied this client.");
                bool rejected = false;
                try { engine.Install(root, delegate(string text) { }); }
                catch (InvalidOperationException e) { rejected = e.Message.Contains("requires the TradeSkillMaster addon"); }
                Require(rejected && !Directory.Exists(Path.Combine(root, InstallerEngine.BackupDirectory)), "Missing TSM was not rejected before installation writes.");
                using (var form = new InstallerForm(engine))
                {
                    Require(!form.Controls["installButton"].Enabled, "Install enabled before choosing a directory.");
                    form.SelectClient(root);
                    Require(!form.Controls["installButton"].Enabled && form.Controls["tsmStatus"].Text.Contains("not found"), "Missing-folder UI did not block installation.");
                    // Adding the dependency while the installer stays open must
                    // be recoverable through the visible Check again button.
                    Directory.CreateDirectory(tsm);
                    // Deliver the button's click without displaying the form.
                    typeof(Button).GetMethod("OnClick", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(form.Controls["checkAgain"], new object[] { EventArgs.Empty });
                    Require(form.Controls["installButton"].Enabled, "Present folder did not enable installation.");
                    // An empty folder still passes this deliberately narrow
                    // presence check; the install engine handles a missing loader.
                    Require(InstallPrerequisites.Check(root).Found, "Presence check required version/loader content.");
                    Directory.Delete(tsm);
                    form.SelectClient(root);
                    Require(!form.Controls["installButton"].Enabled, "Previously found TSM stayed enabled after removal.");
                    form.ShowInTaskbar = false;
                    form.StartPosition = FormStartPosition.Manual;
                    form.Location = new Point(-32000, -32000);
                    form.Show();
                    form.PerformLayout();
                    Application.DoEvents();
                    using (var preview = new Bitmap(form.Width, form.Height))
                    {
                        // Draw the actual form off-screen. This never clicks
                        // Install, opens external links or accesses a live client.
                        form.DrawToBitmap(preview, new Rectangle(Point.Empty, form.Size));
                        preview.Save(Path.Combine(Path.GetDirectoryName(root), "installer-prerequisites-preview.png"), ImageFormat.Png);
                    }
                    form.Hide();
                }
            }
            finally
            {
                if (Directory.Exists(tsm)) Directory.Delete(tsm, true);
                Directory.Move(parked, tsm);
            }
            report.Add("PASS: TBC Anniversary folder required; other Classic/Retail branches and renamed client roots rejected before writes, even with a Classic executable and TSM folder present.");
            report.Add("PASS: dependency checked only in the selected client; no loader/version read for presence; missing TSM rejects before writes; Install blocked until present; rechecking a changed folder updates readiness; actual installer preview rendered off-screen.");
        }
    }
}
