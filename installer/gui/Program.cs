// Barrierefreies Setup fuer den FINAL FANTASY RESONANCE Zugang: nur Standard-Steuerelemente mit Namen und
// Tastenkuerzeln, damit NVDA und andere Screenreader alles lesen. Die Dateien stecken als payload.zip in der Exe.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Reflection;
using System.Security.Principal;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

namespace FFRSSetup
{
    internal static class Program
    {
        [STAThread]
        private static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new SetupForm(args));
        }
    }

    internal static class Installer
    {
        public const string ExeRelative = @"FFRS\Binaries\Win64\FFRS-Win64-Shipping.exe";

        // Protokoll fuer Rueckfragen: jede Meldung landet auch hier, auch aus dem Neustart mit Adminrechten.
        public static readonly string LogPath = Path.Combine(Path.GetTempPath(), "FFRSAccess-Setup.log");

        public static void Log(string line)
        {
            try
            {
                File.AppendAllText(LogPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + (IsElevated() ? " [Admin] " : " ") + line + Environment.NewLine);
            }
            catch (Exception)
            {
            }
        }

        public static bool IsElevated()
        {
            try
            {
                using (var identity = WindowsIdentity.GetCurrent())
                    return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
            }
            catch (Exception)
            {
                return false;
            }
        }

        // Steam-Bibliotheken aus libraryfolders.vdf, darin jeder Ordner, der mit FINAL FANTASY RESONANCE beginnt.
        public static List<string> FindGameDirs()
        {
            var libraries = new List<string>();
            foreach (var key in new[] { @"HKEY_CURRENT_USER\Software\Valve\Steam", @"HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Valve\Steam" })
            {
                var steam = (Registry.GetValue(key, "SteamPath", null) ?? Registry.GetValue(key, "InstallPath", null)) as string;
                if (string.IsNullOrEmpty(steam))
                    continue;
                libraries.Add(steam.Replace('/', '\\'));
                var vdf = Path.Combine(steam, @"steamapps\libraryfolders.vdf");
                if (File.Exists(vdf))
                {
                    foreach (Match match in Regex.Matches(File.ReadAllText(vdf), "\"path\"\\s+\"([^\"]+)\""))
                        libraries.Add(match.Groups[1].Value.Replace(@"\\", @"\"));
                }
            }
            var found = new List<string>();
            foreach (var library in libraries.Distinct(StringComparer.OrdinalIgnoreCase))
            {
                var common = Path.Combine(library, @"steamapps\common");
                if (!Directory.Exists(common))
                    continue;
                foreach (var dir in Directory.GetDirectories(common, "FINAL FANTASY RESONANCE*"))
                {
                    if (File.Exists(Path.Combine(dir, ExeRelative)) && !found.Contains(dir, StringComparer.OrdinalIgnoreCase))
                        found.Add(dir);
                }
            }
            // Vollversion vor der Demo vorschlagen.
            return found.OrderBy(dir => dir.IndexOf("DEMO", StringComparison.OrdinalIgnoreCase) >= 0 ? 1 : 0).ToList();
        }

        // Akzeptiert den Spielordner selbst, aber auch FFRS oder Win64 darin.
        public static string ResolveGameDir(string path)
        {
            path = (path ?? "").Trim().Trim('"');
            if (path.Length == 0)
                return null;
            try
            {
                var candidate = Path.GetFullPath(path);
                for (int i = 0; i < 4 && candidate != null; i++)
                {
                    if (File.Exists(Path.Combine(candidate, ExeRelative)))
                        return candidate;
                    candidate = Path.GetDirectoryName(candidate);
                }
            }
            catch (Exception)
            {
            }
            return null;
        }

        public static bool IsGameRunning(string win64)
        {
            foreach (var process in Process.GetProcessesByName("FFRS-Win64-Shipping"))
            {
                try
                {
                    if (process.MainModule.FileName.StartsWith(win64, StringComparison.OrdinalIgnoreCase))
                        return true;
                }
                catch (Exception)
                {
                    // Kein Zugriff auf den Prozess: sicherheitshalber als laufend werten.
                    return true;
                }
            }
            return false;
        }

        public static ZipArchive OpenPayload()
        {
            var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip");
            if (stream == null)
                throw new InvalidOperationException("Die Installationsdateien fehlen in dieser Exe.");
            return new ZipArchive(stream, ZipArchiveMode.Read);
        }

        // Einstellungen und Mod-Liste eines vorhandenen UE4SS bleiben, gelernte Namen und Wegekarten der Mod auch,
        // weil sie nicht im Paket stecken.
        private static readonly string[] KeepIfPresent = { "ue4ss/UE4SS-settings.ini", "ue4ss/Mods/mods.txt" };

        public static void Install(string game, Action<string> report)
        {
            var win64 = Path.Combine(game, @"FFRS\Binaries\Win64");
            var modDir = Path.Combine(win64, @"ue4ss\Mods\FFRSAccess");
            bool hadUe4ss = File.Exists(Path.Combine(win64, @"ue4ss\UE4SS.dll"));
            int written = 0;
            var targets = new List<string>();
            using (var zip = OpenPayload())
            {
                foreach (var entry in zip.Entries)
                {
                    var name = entry.FullName.Replace('\\', '/');
                    if (name.EndsWith("/"))
                        continue;
                    string target;
                    if (name.StartsWith("dateien/Win64/"))
                    {
                        var relative = name.Substring("dateien/Win64/".Length);
                        target = Path.Combine(win64, relative.Replace('/', '\\'));
                        if (KeepIfPresent.Contains(relative) && File.Exists(target))
                            continue;
                    }
                    else
                    {
                        // Liesmich und Lizenzen kommen zur Mod.
                        target = Path.Combine(modDir, name.Replace('/', '\\'));
                    }
                    Directory.CreateDirectory(Path.GetDirectoryName(target));
                    try
                    {
                        entry.ExtractToFile(target, true);
                    }
                    catch (IOException ex)
                    {
                        // Virenscanner blockieren oft dwmapi.dll oder UE4SS.dll; Meldung soll die Datei nennen.
                        throw new IOException($"{target} konnte nicht geschrieben werden: {ex.Message}", ex);
                    }
                    targets.Add(target);
                    written++;
                }
            }
            File.WriteAllText(Path.Combine(modDir, "enabled.txt"), "");
            // Ein Virenscanner kann Dateien gleich nach dem Schreiben wieder entfernen.
            System.Threading.Thread.Sleep(1500);
            var missing = targets.Where(t => !File.Exists(t)).ToList();
            if (missing.Count > 0)
                throw new IOException("Diese Dateien wurden geschrieben, sind aber wieder verschwunden, vermutlich hat ein Virenscanner sie entfernt: "
                    + string.Join(", ", missing.Select(Path.GetFileName)));
            report(hadUe4ss ? "UE4SS aktualisiert, vorhandene Einstellungen behalten." : "UE4SS installiert.");
            report($"Mod FFRSAccess installiert, {written} Dateien.");
        }

        public static void Uninstall(string game, bool removeUe4ss, Action<string> report)
        {
            var win64 = Path.Combine(game, @"FFRS\Binaries\Win64");
            var ue4ss = Path.Combine(win64, "ue4ss");
            var modDir = Path.Combine(ue4ss, @"Mods\FFRSAccess");
            if (Directory.Exists(modDir))
            {
                Directory.Delete(modDir, true);
                report("Mod FFRSAccess entfernt.");
            }
            else
            {
                report("Die Mod FFRSAccess war nicht installiert.");
            }
            if (removeUe4ss && File.Exists(Path.Combine(ue4ss, "UE4SS.dll")))
            {
                var proxy = Path.Combine(win64, "dwmapi.dll");
                if (File.Exists(proxy))
                    File.Delete(proxy);
                Directory.Delete(ue4ss, true);
                report("UE4SS entfernt.");
            }
        }
    }

    // Neue Versionen liegen als Release auf GitHub, das Setup selbst ist die Datei darin. Betas (0.1.0b) sind als
    // Vorabversion markiert, deshalb die ganze Release-Liste statt /releases/latest.
    internal static class Updater
    {
        public const string Repository = "derbruedi/ffrs-accessibility";
        public const string AssetName = "FFRSAccess-Setup.exe";

        public sealed class Release
        {
            public string Version;
            public string DownloadUrl;
        }

        public static string CurrentVersion
        {
            get
            {
                var attribute = Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>();
                return attribute?.InformationalVersion ?? "0.0.0";
            }
        }

        private static HttpClient NewClient()
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            var client = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
            // Ohne User-Agent lehnt die GitHub-API ab.
            client.DefaultRequestHeaders.UserAgent.ParseAdd("FFRSAccess-Setup/" + Regex.Replace(CurrentVersion, "[^0-9A-Za-z.]", ""));
            return client;
        }

        public static async Task<Release> FindNewerAsync()
        {
            string json;
            using (var client = NewClient())
                json = await client.GetStringAsync($"https://api.github.com/repos/{Repository}/releases?per_page=30");
            Release best = null;
            foreach (var item in (IEnumerable)new JavaScriptSerializer().DeserializeObject(json))
            {
                if (!(item is Dictionary<string, object> release) || (release.TryGetValue("draft", out var draft) && draft is bool isDraft && isDraft))
                    continue;
                var version = ((release.TryGetValue("tag_name", out var tag) ? tag as string : null) ?? "").TrimStart('v', 'V');
                if (Compare(version, best?.Version ?? CurrentVersion) <= 0 || !release.TryGetValue("assets", out var assets))
                    continue;
                foreach (var assetItem in (IEnumerable)assets)
                {
                    if (assetItem is Dictionary<string, object> asset && asset.TryGetValue("name", out var name)
                        && string.Equals(name as string, AssetName, StringComparison.OrdinalIgnoreCase)
                        && asset.TryGetValue("browser_download_url", out var url))
                        best = new Release { Version = version, DownloadUrl = url as string };
                }
            }
            return best;
        }

        public static async Task<string> DownloadAsync(Release release)
        {
            var target = Path.Combine(Path.GetTempPath(), $"FFRSAccess-Setup-{Regex.Replace(release.Version, "[^0-9A-Za-z.]", "")}.exe");
            using (var client = NewClient())
            {
                client.Timeout = TimeSpan.FromMinutes(10);
                var bytes = await client.GetByteArrayAsync(release.DownloadUrl);
                File.WriteAllBytes(target, bytes);
            }
            return target;
        }

        // 0.1.0b < 0.1.0b2 < 0.1.0 < 0.1.1b: erst die Zahlen, dann gilt eine Version ohne Zusatz als neuer.
        public static int Compare(string a, string b)
        {
            var left = Parse(a);
            var right = Parse(b);
            for (int i = 0; i < Math.Max(left.Numbers.Length, right.Numbers.Length); i++)
            {
                int x = i < left.Numbers.Length ? left.Numbers[i] : 0;
                int y = i < right.Numbers.Length ? right.Numbers[i] : 0;
                if (x != y)
                    return x.CompareTo(y);
            }
            if (left.Suffix.Length == 0 && right.Suffix.Length == 0)
                return 0;
            if (left.Suffix.Length == 0)
                return 1;
            if (right.Suffix.Length == 0)
                return -1;
            int bySuffix = string.Compare(left.Suffix, right.Suffix, StringComparison.OrdinalIgnoreCase);
            return bySuffix != 0 ? bySuffix : left.SuffixNumber.CompareTo(right.SuffixNumber);
        }

        private static (int[] Numbers, string Suffix, int SuffixNumber) Parse(string version)
        {
            var match = Regex.Match(version ?? "", @"^\s*(\d+(?:\.\d+)*)([A-Za-z]*)(\d*)");
            if (!match.Success)
                return (new int[0], "", 0);
            var numbers = match.Groups[1].Value.Split('.').Select(int.Parse).ToArray();
            int suffixNumber = match.Groups[3].Value.Length > 0 ? int.Parse(match.Groups[3].Value) : 0;
            return (numbers, match.Groups[2].Value, suffixNumber);
        }
    }

    internal sealed class SetupForm : Form
    {
        private readonly TextBox pathBox = new TextBox();
        private readonly Button browseButton = new Button();
        private readonly CheckBox removeUe4ssBox = new CheckBox();
        private readonly Button installButton = new Button();
        private readonly Button uninstallButton = new Button();
        private readonly Button readmeButton = new Button();
        private readonly TextBox statusBox = new TextBox();
        private readonly Button closeButton = new Button();
        private readonly string[] startArgs;

        public SetupForm(string[] args)
        {
            startArgs = args;
            Text = "FINAL FANTASY RESONANCE Zugang " + Updater.CurrentVersion + " – Installation";
            AccessibleName = Text;
            Font = new Font("Segoe UI", 10f);
            AutoScaleMode = AutoScaleMode.Dpi;
            StartPosition = FormStartPosition.CenterScreen;
            MinimumSize = new Size(640, 460);
            Size = new Size(760, 520);

            var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, Padding = new Padding(12), AutoSize = false };
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            Controls.Add(layout);
            int tab = 0;

            var intro = new Label
            {
                Text = "Dieses Setup installiert UE4SS und die Mod, mit der FINAL FANTASY RESONANCE über einen Screenreader spielbar ist. Bitte das Spiel vorher beenden.",
                AutoSize = true, MaximumSize = new Size(700, 0), Margin = new Padding(0, 0, 0, 10), TabIndex = tab++,
            };
            layout.Controls.Add(intro, 0, 0);
            layout.SetColumnSpan(intro, 2);

            // Ein Label direkt vor dem Feld in der Tab-Reihenfolge benennt das Feld fuer Screenreader.
            var pathLabel = new Label { Text = "&Spielordner:", AutoSize = true, TabIndex = tab++ };
            layout.Controls.Add(pathLabel, 0, 1);
            layout.SetColumnSpan(pathLabel, 2);
            pathBox.AccessibleName = "Spielordner";
            pathBox.AccessibleDescription = "Ordner, in dem FINAL FANTASY RESONANCE installiert ist";
            pathBox.Dock = DockStyle.Fill;
            pathBox.TabIndex = tab++;
            layout.Controls.Add(pathBox, 0, 2);
            browseButton.Text = "&Durchsuchen …";
            browseButton.AccessibleName = "Spielordner durchsuchen";
            browseButton.AutoSize = true;
            browseButton.TabIndex = tab++;
            browseButton.Click += (s, e) => Browse();
            layout.Controls.Add(browseButton, 1, 2);

            removeUe4ssBox.Text = "Beim Deinstallieren auch &UE4SS entfernen (dann laufen auch andere UE4SS-Mods nicht mehr)";
            removeUe4ssBox.AutoSize = true;
            removeUe4ssBox.Margin = new Padding(0, 10, 0, 10);
            removeUe4ssBox.TabIndex = tab++;
            layout.Controls.Add(removeUe4ssBox, 0, 3);
            layout.SetColumnSpan(removeUe4ssBox, 2);

            var buttons = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, TabIndex = tab++ };
            ConfigureButton(installButton, "&Installieren", 0, (s, e) => RunInstall());
            ConfigureButton(uninstallButton, "D&einstallieren", 1, (s, e) => RunUninstall());
            ConfigureButton(readmeButton, "&Liesmich anzeigen", 2, (s, e) => ShowReadme());
            buttons.Controls.AddRange(new Control[] { installButton, uninstallButton, readmeButton });
            layout.Controls.Add(buttons, 0, 4);
            layout.SetColumnSpan(buttons, 2);

            var statusLabel = new Label { Text = "&Meldungen:", AutoSize = true, Margin = new Padding(0, 10, 0, 0), TabIndex = tab++ };
            layout.Controls.Add(statusLabel, 0, 5);
            layout.SetColumnSpan(statusLabel, 2);
            statusBox.Multiline = true;
            statusBox.ReadOnly = true;
            statusBox.ScrollBars = ScrollBars.Vertical;
            statusBox.Dock = DockStyle.Fill;
            statusBox.AccessibleName = "Meldungen";
            statusBox.TabStop = true;
            statusBox.TabIndex = tab++;
            layout.Controls.Add(statusBox, 0, 6);
            layout.SetColumnSpan(statusBox, 2);
            layout.RowStyles.Clear();
            for (int row = 0; row < 6; row++)
                layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));

            ConfigureButton(closeButton, "S&chließen", tab++, (s, e) => Close());
            closeButton.Anchor = AnchorStyles.Right;
            layout.Controls.Add(closeButton, 1, 7);

            AcceptButton = installButton;
            CancelButton = closeButton;
            Shown += (s, e) => OnStart();
        }

        private static void ConfigureButton(Button button, string text, int tabIndex, EventHandler click)
        {
            button.Text = text;
            button.AutoSize = true;
            button.MinimumSize = new Size(140, 34);
            button.TabIndex = tabIndex;
            button.Click += click;
        }

        private void Report(string line)
        {
            Installer.Log(line);
            statusBox.AppendText((statusBox.TextLength > 0 ? Environment.NewLine : "") + line);
        }

        private void OnStart()
        {
            // Nach dem Neustart mit Adminrechten: --install <Ordner> oder --uninstall <Ordner> [--ue4ss]
            Installer.Log($"Setup {Updater.CurrentVersion} gestartet: {Application.ExecutablePath} {string.Join(" ", startArgs)}");
            if (startArgs.Length >= 2)
            {
                // Das Fenster nach der Admin-Abfrage kann hinter anderen Fenstern landen.
                Activate();
                pathBox.Text = startArgs[1];
                removeUe4ssBox.Checked = startArgs.Contains("--ue4ss");
                pathBox.Focus();
                if (startArgs[0] == "--install")
                    RunInstall();
                else if (startArgs[0] == "--uninstall")
                    RunUninstall();
                return;
            }
            List<string> found;
            try
            {
                found = Installer.FindGameDirs();
            }
            catch (Exception ex)
            {
                found = new List<string>();
                Report("Steam-Suche fehlgeschlagen: " + ex.Message);
            }
            if (found.Count > 0)
            {
                pathBox.Text = found[0];
                Report("Gefundener Spielordner: " + found[0]);
                foreach (var other in found.Skip(1))
                    Report("Ebenfalls gefunden: " + other);
            }
            else
            {
                Report("Kein Spielordner gefunden. Bitte den Spielordner eingeben oder Durchsuchen wählen.");
            }
            pathBox.Focus();
            pathBox.SelectAll();
            CheckForUpdate();
        }

        private async void CheckForUpdate()
        {
            Report($"Installierte Setup-Version {Updater.CurrentVersion}, suche nach Updates …");
            Updater.Release release;
            try
            {
                release = await Updater.FindNewerAsync();
            }
            catch (Exception ex)
            {
                Report("Update-Suche fehlgeschlagen: " + ex.Message);
                return;
            }
            if (release == null)
            {
                Report("Dies ist die neueste Version.");
                return;
            }
            Report($"Neue Version {release.Version} gefunden.");
            var answer = MessageBox.Show(this, $"Version {release.Version} ist verfügbar, dieses Setup ist Version {Updater.CurrentVersion}. Jetzt herunterladen und installieren?",
                Text, MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (answer != DialogResult.Yes)
            {
                Report("Update übersprungen.");
                pathBox.Focus();
                return;
            }
            SetBusy(true);
            Report("Lade Version " + release.Version + " herunter …");
            try
            {
                var setup = await Updater.DownloadAsync(release);
                // Das neue Setup installiert gleich in den Ordner aus dem Feld, sonst startet es normal.
                var game = Installer.ResolveGameDir(pathBox.Text);
                var arguments = game != null ? $"--install \"{game.TrimEnd('\\')}\"" : "";
                Process.Start(new ProcessStartInfo(setup, arguments) { UseShellExecute = true });
                Close();
            }
            catch (Exception ex)
            {
                Report("Download fehlgeschlagen: " + ex.Message);
                Tell("Das Update konnte nicht geladen werden: " + ex.Message, MessageBoxIcon.Error);
                SetBusy(false);
                pathBox.Focus();
            }
        }

        private void Browse()
        {
            using (var dialog = new FolderBrowserDialog { Description = "Ordner von FINAL FANTASY RESONANCE wählen", ShowNewFolderButton = false })
            {
                if (Directory.Exists(pathBox.Text))
                    dialog.SelectedPath = pathBox.Text;
                if (dialog.ShowDialog(this) == DialogResult.OK)
                    pathBox.Text = dialog.SelectedPath;
            }
            pathBox.Focus();
        }

        private string CheckGameDir()
        {
            var game = Installer.ResolveGameDir(pathBox.Text);
            if (game == null)
            {
                Tell("In diesem Ordner liegt kein FINAL FANTASY RESONANCE. Erwartet wird darin die Datei " + Installer.ExeRelative + ".", MessageBoxIcon.Warning);
                pathBox.Focus();
                return null;
            }
            pathBox.Text = game;
            if (Installer.IsGameRunning(Path.Combine(game, @"FFRS\Binaries\Win64")))
            {
                Tell("Das Spiel läuft gerade. Bitte das Spiel beenden und es dann noch einmal versuchen.", MessageBoxIcon.Warning);
                return null;
            }
            return game;
        }

        private void RunInstall()
        {
            var game = CheckGameDir();
            if (game != null)
                Run("--install", game, () => Installer.Install(game, Report),
                    "Installation fertig. Beim nächsten Spielstart sagt die Mod: Final Fantasy Resonance Zugang geladen.");
        }

        private void RunUninstall()
        {
            var game = CheckGameDir();
            if (game != null)
                Run("--uninstall", game, () => Installer.Uninstall(game, removeUe4ssBox.Checked, Report), "Deinstallation fertig.");
        }

        private void Run(string mode, string game, Action action, string doneMessage)
        {
            SetBusy(true);
            Report("Spielordner: " + game);
            try
            {
                action();
                Report(doneMessage);
                Tell(doneMessage, MessageBoxIcon.Information);
            }
            catch (UnauthorizedAccessException ex)
            {
                Report("Keine Schreibrechte: " + ex.Message);
                if (Installer.IsElevated())
                {
                    // Schon mit Adminrechten: ein weiterer Neustart hilft nicht, sonst entsteht eine Schleife.
                    var message = "Auch mit Administratorrechten ist das Schreiben im Spielordner gesperrt: " + ex.Message
                        + " Häufige Ursache ist der Windows-Schutz „Überwachter Ordnerzugriff“ oder ein Virenscanner. Das Protokoll liegt unter " + Installer.LogPath + ".";
                    Report(message);
                    Tell(message, MessageBoxIcon.Error);
                    SetBusy(false);
                    statusBox.Focus();
                    return;
                }
                var answer = MessageBox.Show(this, "Für diesen Ordner braucht das Setup Administratorrechte. Mit Administratorrechten neu starten?",
                    Text, MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                if (answer == DialogResult.Yes && RestartElevated(mode, game))
                {
                    Close();
                    return;
                }
            }
            catch (Exception ex)
            {
                Report("Fehler: " + ex);
                Tell("Das hat nicht geklappt: " + ex.Message + " Das Protokoll liegt unter " + Installer.LogPath + ".", MessageBoxIcon.Error);
            }
            finally
            {
                SetBusy(false);
            }
            statusBox.Focus();
        }

        private bool RestartElevated(string mode, string game)
        {
            try
            {
                // Ein Backslash am Ende wuerde das schliessende Anfuehrungszeichen maskieren.
                var arguments = $"{mode} \"{game.TrimEnd('\\')}\"" + (removeUe4ssBox.Checked ? " --ue4ss" : "");
                Report("Starte mit Administratorrechten neu: " + arguments);
                Process.Start(new ProcessStartInfo(Application.ExecutablePath, arguments) { Verb = "runas", UseShellExecute = true });
                return true;
            }
            catch (Exception ex)
            {
                Report("Neustart mit Administratorrechten abgebrochen: " + ex.Message);
                return false;
            }
        }

        private void ShowReadme()
        {
            try
            {
                var target = Path.Combine(Path.GetTempPath(), "FFRSAccess-Liesmich.txt");
                using (var zip = Installer.OpenPayload())
                {
                    var entry = zip.Entries.FirstOrDefault(e => e.FullName.Replace('\\', '/') == "Liesmich.txt");
                    if (entry == null)
                        throw new FileNotFoundException("Liesmich.txt fehlt im Paket.");
                    entry.ExtractToFile(target, true);
                }
                Process.Start(new ProcessStartInfo("notepad.exe", "\"" + target + "\"") { UseShellExecute = true });
            }
            catch (Exception ex)
            {
                Tell("Liesmich konnte nicht geöffnet werden: " + ex.Message, MessageBoxIcon.Error);
            }
        }

        private void SetBusy(bool busy)
        {
            UseWaitCursor = busy;
            installButton.Enabled = uninstallButton.Enabled = browseButton.Enabled = readmeButton.Enabled = !busy;
            Application.DoEvents();
        }

        private void Tell(string message, MessageBoxIcon icon)
        {
            MessageBox.Show(this, message, Text, MessageBoxButtons.OK, icon);
        }
    }
}
