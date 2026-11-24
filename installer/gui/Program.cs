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
using System.Text;
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

    internal sealed class LanguagePack
    {
        public string Code;
        public string NativeName;
        public string Fallback;
        public readonly Dictionary<string, string> Installer = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        public string Text(string key)
        {
            string value;
            return Installer.TryGetValue(key, out value) ? value : null;
        }
    }

    internal static class LocaleCatalog
    {
        public const string Auto = "auto";
        private static readonly Dictionary<string, LanguagePack> Packs = LoadPacks();
        private static LanguagePack current;
        private static LanguagePack fallback;
        private static readonly HashSet<string> warned = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        static LocaleCatalog()
        {
            fallback = Find("de-DE");
            current = fallback;
        }

        public static string CurrentCode
        {
            get { return current != null ? current.Code : "de-DE"; }
        }

        public static string CurrentNativeName
        {
            get { return current != null ? current.NativeName : "Deutsch"; }
        }

        public static IEnumerable<LanguagePack> Available
        {
            get { return Packs.Values.OrderBy(p => p.NativeName, StringComparer.CurrentCultureIgnoreCase); }
        }

        public static void Initialize(string requested)
        {
            Select(requested);
        }

        public static void Select(string requested)
        {
            requested = (requested ?? "").Trim();
            if (requested.Length == 0 || string.Equals(requested, Auto, StringComparison.OrdinalIgnoreCase))
                requested = System.Globalization.CultureInfo.CurrentUICulture.Name;
            var resolvedCode = Resolve(requested);
            current = resolvedCode != null ? Find(resolvedCode) : null;
            if (current == null)
                current = fallback;
            if (current == null)
                throw new InvalidOperationException("de-DE.lang fehlt in dieser Setup-Exe.");
        }

        public static string T(string key, params object[] values)
        {
            var text = current != null ? current.Text(key) : null;
            if (text == null && fallback != null)
                text = fallback.Text(key);
            if (text == null)
            {
                var warning = CurrentCode + ":" + key;
                if (warned.Add(warning))
                    Installer.Log("Text fehlt: " + warning);
                return key;
            }
            for (int i = 0; values != null && i + 1 < values.Length; i += 2)
            {
                var name = Convert.ToString(values[i]);
                var value = values[i + 1];
                text = text.Replace("{" + name + "}", value == null ? "" : Convert.ToString(value));
            }
            return text;
        }

        public static string N(string key, long count, params object[] values)
        {
            var extra = new object[(values == null ? 0 : values.Length) + 2];
            extra[0] = "count";
            extra[1] = count;
            if (values != null)
                Array.Copy(values, 0, extra, 2, values.Length);
            return T(key + (count == 1 ? ".one" : ".other"), extra);
        }

        private static LanguagePack Find(string code)
        {
            LanguagePack pack;
            return code != null && Packs.TryGetValue(code, out pack) ? pack : null;
        }

        private static string Resolve(string requested)
        {
            requested = (requested ?? "").Trim().Replace('_', '-');
            if (requested.Length == 0)
                return fallback != null ? fallback.Code : null;
            var exact = Find(requested);
            if (exact != null)
                return exact.Code;
            var lower = requested.ToLowerInvariant();
            if (lower.StartsWith("zh"))
            {
                var chinese = Packs.Values.FirstOrDefault(p => p.Code.StartsWith("zh-", StringComparison.OrdinalIgnoreCase));
                if (chinese != null)
                    return chinese.Code;
            }
            if (lower.StartsWith("de"))
            {
                var german = Packs.Values.FirstOrDefault(p => p.Code.StartsWith("de-", StringComparison.OrdinalIgnoreCase));
                if (german != null)
                    return german.Code;
            }
            var baseName = lower.Split('-')[0];
            var matches = Packs.Values.Where(p => p.Code.StartsWith(baseName + "-", StringComparison.OrdinalIgnoreCase)).ToList();
            return matches.Count == 1 ? matches[0].Code : null;
        }

        private static Dictionary<string, LanguagePack> LoadPacks()
        {
            var result = new Dictionary<string, LanguagePack>(StringComparer.OrdinalIgnoreCase);
            var assembly = Assembly.GetExecutingAssembly();
            foreach (var resource in assembly.GetManifestResourceNames())
            {
                var normalized = resource.Replace('\\', '/');
                if (!normalized.StartsWith("locales/", StringComparison.OrdinalIgnoreCase) || !normalized.EndsWith(".lang", StringComparison.OrdinalIgnoreCase))
                    continue;
                using (var stream = assembly.GetManifestResourceStream(resource))
                using (var reader = new StreamReader(stream, new UTF8Encoding(false, true)))
                {
                    var pack = ParsePack(reader.ReadToEnd(), normalized.Substring(8, normalized.Length - 13));
                    result[pack.Code] = pack;
                }
            }
            return result;
        }

        private static LanguagePack ParsePack(string text, string fileNameCode)
        {
            var pack = new LanguagePack { Code = fileNameCode, NativeName = fileNameCode, Fallback = "de-DE" };
            string section = "meta";
            foreach (var rawLine in text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n'))
            {
                var line = rawLine.Trim();
                if (line.Length == 0 || line.StartsWith("#"))
                    continue;
                if (line.StartsWith("[") && line.EndsWith("]"))
                {
                    section = line.Substring(1, line.Length - 2);
                    continue;
                }
                var split = line.IndexOf('=');
                if (split <= 0)
                    continue;
                var key = line.Substring(0, split).Trim();
                var value = Unescape(line.Substring(split + 1).Trim());
                if (string.Equals(section, "meta", StringComparison.OrdinalIgnoreCase))
                {
                    if (key == "code") pack.Code = value;
                    else if (key == "native_name") pack.NativeName = value;
                    else if (key == "fallback") pack.Fallback = value;
                }
                else if (string.Equals(section, "installer", StringComparison.OrdinalIgnoreCase))
                {
                    pack.Installer[key] = value;
                }
            }
            return pack;
        }

        private static string Unescape(string value)
        {
            return value.Replace("\\n", "\n").Replace("\\r", "\r").Replace("\\t", "\t").Replace("\\\\", "\\");
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

        // Fuer Rueckfragen: Mit welchem Konto laeuft das Setup? Gibt man bei der Admin-Abfrage ein anderes Konto an,
        // landet das Protokoll in dessen TEMP-Ordner.
        public static string AccountInfo()
        {
            return LocaleCatalog.T("installer.account", "version", Updater.CurrentVersion,
                "account", Environment.UserDomainName + "\\" + Environment.UserName,
                "rights", LocaleCatalog.T(IsElevated() ? "installer.rights.admin" : "installer.rights.normal"), "log", LogPath);
        }

        // Eine schreibgeschuetzte Datei (etwa dwmapi.dll einer anderen Mod) laesst sich auch als Administrator nicht
        // ueberschreiben oder loeschen: Schreibschutz vorher entfernen.
        public static void MakeWritable(string path, Action<string> report)
        {
            if (!File.Exists(path))
                return;
            var attributes = File.GetAttributes(path);
            if ((attributes & FileAttributes.ReadOnly) == 0)
                return;
            File.SetAttributes(path, attributes & ~FileAttributes.ReadOnly);
            report(LocaleCatalog.T("installer.readonly_removed", "path", path));
        }

        public static void MakeTreeWritable(string directory, Action<string> report)
        {
            if (!Directory.Exists(directory))
                return;
            foreach (var file in Directory.GetFiles(directory, "*", SearchOption.AllDirectories))
                MakeWritable(file, report);
        }

        public static string DescribeFile(string path)
        {
            try
            {
                if (!File.Exists(path))
                    return LocaleCatalog.T("installer.file.missing");
                var info = new FileInfo(path);
                return LocaleCatalog.T("installer.file.present", "length", info.Length, "attributes", info.Attributes,
                    "changed", info.LastWriteTime.ToString("yyyy-MM-dd HH:mm"));
            }
            catch (Exception ex)
            {
                return LocaleCatalog.T("installer.file.unreadable", "error", ex.Message);
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
                throw new InvalidOperationException(LocaleCatalog.T("installer.payload_missing"));
            return new ZipArchive(stream, ZipArchiveMode.Read);
        }

        // Einstellungen und Mod-Liste eines vorhandenen UE4SS bleiben, gelernte Namen und Wegekarten der Mod auch,
        // weil sie nicht im Paket stecken.
        private static readonly string[] KeepIfPresent = { "ue4ss/UE4SS-settings.ini", "ue4ss/Mods/mods.txt" };

        // Gleicher Inhalt wie im Paket? Erst die Groesse, dann SHA-256. Ist die vorhandene Datei nicht lesbar,
        // gilt sie als verschieden und wird geschrieben wie bisher.
        private static bool SameContent(ZipArchiveEntry entry, string target)
        {
            try
            {
                var info = new FileInfo(target);
                if (!info.Exists || info.Length != entry.Length)
                    return false;
                using (var sha = System.Security.Cryptography.SHA256.Create())
                {
                    byte[] packaged, present;
                    using (var stream = entry.Open())
                        packaged = sha.ComputeHash(stream);
                    using (var stream = new FileStream(target, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                        present = sha.ComputeHash(stream);
                    return packaged.SequenceEqual(present);
                }
            }
            catch (Exception)
            {
                return false;
            }
        }

        private static bool IsProxy(string entryName)
        {
            return string.Equals(entryName, "dateien/Win64/dwmapi.dll", StringComparison.OrdinalIgnoreCase);
        }

        public static void Install(string game, string language, Action<string> report)
        {
            var win64 = Path.Combine(game, @"FFRS\Binaries\Win64");
            var modDir = Path.Combine(win64, @"ue4ss\Mods\FFRSAccess");
            bool hadUe4ss = File.Exists(Path.Combine(win64, @"ue4ss\UE4SS.dll"));
            int written = 0, unchanged = 0, ue4ssWritten = 0;
            Exception proxyError = null;
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
                    // Bei Updates nur Geaendertes schreiben: dwmapi.dll und UE4SS bleiben meist gleich, ein Virenscanner
                    // oder fehlende Rechte koennen sie dann nicht mehr stoeren.
                    if (SameContent(entry, target))
                    {
                        unchanged++;
                        continue;
                    }
                    Directory.CreateDirectory(Path.GetDirectoryName(target));
                    try
                    {
                        MakeWritable(target, report);
                        entry.ExtractToFile(target, true);
                    }
                    catch (Exception ex) when (IsProxy(name) && (ex is UnauthorizedAccessException || ex is IOException))
                    {
                        // Nur diese Datei macht Probleme (Virenscanner: sieht aus wie eine untergeschobene Systemdatei).
                        // Den Rest trotzdem installieren, am Ende gezielt melden.
                        report(LocaleCatalog.T("installer.proxy_write_failed", "type", ex.GetType().Name, "error", ex.Message, "file", DescribeFile(target)));
                        proxyError = ex;
                        continue;
                    }
                    catch (UnauthorizedAccessException)
                    {
                        report(LocaleCatalog.T("installer.write_denied", "path", target, "file", DescribeFile(target)));
                        throw;
                    }
                    catch (IOException ex)
                    {
                        // Virenscanner blockieren oft dwmapi.dll oder UE4SS.dll; Meldung soll die Datei nennen.
                        throw new IOException(LocaleCatalog.T("installer.write_failed", "path", target, "error", ex.Message), ex);
                    }
                    targets.Add(target);
                    written++;
                    if (!target.StartsWith(modDir, StringComparison.OrdinalIgnoreCase))
                        ue4ssWritten++;
                }
            }
            var enabled = Path.Combine(modDir, "enabled.txt");
            if (!File.Exists(enabled))
                File.WriteAllText(enabled, "");
            var languageFile = Path.Combine(modDir, "language.txt");
            File.WriteAllText(languageFile, (string.IsNullOrWhiteSpace(language) ? LocaleCatalog.CurrentCode : language.Trim()) + Environment.NewLine,
                new UTF8Encoding(false));
            // Ein Virenscanner kann Dateien gleich nach dem Schreiben wieder entfernen.
            System.Threading.Thread.Sleep(1500);
            var missing = targets.Where(t => !File.Exists(t)).ToList();
            var proxyPath = Path.Combine(win64, "dwmapi.dll");
            if (proxyError == null && missing.Remove(proxyPath))
                proxyError = new IOException(LocaleCatalog.T("installer.proxy_missing_after"));
            if (proxyError != null)
            {
                report(LocaleCatalog.T("installer.others_installed", "written", written,
                    "written_files", LocaleCatalog.N("installer.files", written), "unchanged", unchanged,
                    "unchanged_files", LocaleCatalog.N("installer.files", unchanged)));
                // Ohne Adminrechte zuerst den Neustart anbieten; der ueberspringt dann alles schon Geschriebene.
                if (proxyError is UnauthorizedAccessException && !IsElevated())
                    throw new UnauthorizedAccessException(LocaleCatalog.T("installer.proxy_unauthorized", "error", proxyError.Message), proxyError);
                throw new IOException(LocaleCatalog.T("installer.proxy_blocked", "path", win64), proxyError);
            }
            if (missing.Count > 0)
                throw new IOException(LocaleCatalog.T("installer.files_vanished", "files", string.Join(", ", missing.Select(Path.GetFileName))));
            if (!hadUe4ss)
                report(LocaleCatalog.T("installer.ue4ss_installed"));
            else if (ue4ssWritten > 0)
                report(LocaleCatalog.T("installer.ue4ss_updated"));
            else
                report(LocaleCatalog.T("installer.ue4ss_current"));
            report(written == 0
                ? LocaleCatalog.T("installer.mod_current", "unchanged", unchanged, "files", LocaleCatalog.N("installer.files", unchanged))
                : LocaleCatalog.T("installer.mod_installed", "written", written, "written_files", LocaleCatalog.N("installer.files", written),
                    "unchanged", unchanged, "unchanged_files", LocaleCatalog.N("installer.files", unchanged)));
        }

        public static void Uninstall(string game, bool removeUe4ss, Action<string> report)
        {
            var win64 = Path.Combine(game, @"FFRS\Binaries\Win64");
            var ue4ss = Path.Combine(win64, "ue4ss");
            var modDir = Path.Combine(ue4ss, @"Mods\FFRSAccess");
            if (Directory.Exists(modDir))
            {
                MakeTreeWritable(modDir, report);
                Directory.Delete(modDir, true);
                report(LocaleCatalog.T("installer.mod_removed"));
            }
            else
            {
                report(LocaleCatalog.T("installer.mod_not_installed"));
            }
            if (removeUe4ss && File.Exists(Path.Combine(ue4ss, "UE4SS.dll")))
            {
                var proxy = Path.Combine(win64, "dwmapi.dll");
                if (File.Exists(proxy))
                {
                    MakeWritable(proxy, report);
                    File.Delete(proxy);
                }
                MakeTreeWritable(ue4ss, report);
                Directory.Delete(ue4ss, true);
                report(LocaleCatalog.T("installer.ue4ss_removed"));
            }
        }
    }

    // Audiodeskription fuer Zwischensequenzen (aus Visions of Grandshelt, GPL-3, etwa 400 MB) liegt als eigene Datei
    // FFRSAccess-Audiodeskription-<Pruefwert>.zip im Release, damit Updates klein bleiben. Descriptions\stand.txt
    // merkt sich den installierten Pruefwert; geladen wird nur, wenn auf GitHub ein anderer liegt.
    internal static class Descriptions
    {
        private static readonly Regex AssetPattern = new Regex(@"^FFRSAccess-Audiodeskription-([0-9a-f]+)\.zip$", RegexOptions.IgnoreCase);
        private const string FolderName = "Descriptions";
        private const string StampName = "stand.txt";

        // Gibt null zurueck, wenn alles in Ordnung ist, sonst einen Hinweis fuer die Abschlussmeldung.
        // Die Mod laeuft auch ohne Audiodeskription, deshalb bricht ein Fehler hier die Installation nicht ab.
        public static async Task<string> UpdateAsync(string game, Action<string> report)
        {
            var modDir = Path.Combine(game, @"FFRS\Binaries\Win64\ue4ss\Mods\FFRSAccess");
            var folder = Path.Combine(modDir, FolderName);
            var stampPath = Path.Combine(folder, StampName);
            string installed = "";
            try
            {
                if (File.Exists(stampPath))
                    installed = File.ReadAllText(stampPath).Trim();
            }
            catch (Exception)
            {
            }
            Updater.Asset asset;
            try
            {
                report(LocaleCatalog.T("installer.descriptions.searching"));
                asset = await Updater.FindNewestAssetAsync(AssetPattern);
            }
            catch (Exception ex)
            {
                report(LocaleCatalog.T("installer.descriptions.search_failed", "error", ex.Message));
                return installed.Length > 0 ? null : LocaleCatalog.T("installer.descriptions.offline_note");
            }
            if (asset == null)
            {
                report(LocaleCatalog.T("installer.descriptions.none"));
                return null;
            }
            var stamp = AssetPattern.Match(asset.Name).Groups[1].Value.ToLowerInvariant();
            if (string.Equals(stamp, installed, StringComparison.OrdinalIgnoreCase) && File.Exists(Path.Combine(folder, "cues.tsv")))
            {
                report(LocaleCatalog.T("installer.descriptions.current"));
                return null;
            }
            report(LocaleCatalog.T("installer.descriptions.downloading", "mb", asset.Size / (1024 * 1024)));
            var zipPath = Path.Combine(Path.GetTempPath(), asset.Name);
            try
            {
                await Updater.DownloadFileAsync(asset, zipPath, report);
                report(LocaleCatalog.T("installer.descriptions.extracting"));
                await Task.Run(() => Extract(zipPath, folder, stamp, report));
                report(LocaleCatalog.T("installer.descriptions.installed"));
                return null;
            }
            catch (Exception ex)
            {
                report(LocaleCatalog.T("installer.descriptions.failed", "error", ex));
                return LocaleCatalog.T("installer.descriptions.install_failed", "error", ex.Message);
            }
            finally
            {
                try
                {
                    File.Delete(zipPath);
                }
                catch (Exception)
                {
                }
            }
        }

        // Erst in einen Nebenordner entpacken, dann tauschen: Bricht etwas ab, bleibt die alte Fassung ganz.
        private static void Extract(string zipPath, string folder, string stamp, Action<string> report)
        {
            var staging = folder + ".neu";
            if (Directory.Exists(staging))
            {
                Installer.MakeTreeWritable(staging, _ => { });
                Directory.Delete(staging, true);
            }
            var root = Path.GetFullPath(staging) + "\\";
            using (var zip = ZipFile.OpenRead(zipPath))
            {
                foreach (var entry in zip.Entries)
                {
                    var name = entry.FullName.Replace('\\', '/');
                    if (name.EndsWith("/") || !name.StartsWith(FolderName + "/", StringComparison.OrdinalIgnoreCase))
                        continue;
                    var target = Path.GetFullPath(Path.Combine(staging, name.Substring(FolderName.Length + 1).Replace('/', '\\')));
                    if (!target.StartsWith(root, StringComparison.OrdinalIgnoreCase))
                        throw new InvalidDataException(LocaleCatalog.T("installer.descriptions.invalid_path", "name", name));
                    Directory.CreateDirectory(Path.GetDirectoryName(target));
                    entry.ExtractToFile(target, true);
                }
            }
            if (!File.Exists(Path.Combine(staging, "cues.tsv")))
                throw new InvalidDataException(LocaleCatalog.T("installer.descriptions.missing_cues"));
            File.WriteAllText(Path.Combine(staging, StampName), stamp);
            if (Directory.Exists(folder))
            {
                Installer.MakeTreeWritable(folder, _ => { });
                Directory.Delete(folder, true);
            }
            Directory.Move(staging, folder);
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

        public sealed class Asset
        {
            public string Name;
            public string DownloadUrl;
            public long Size;
        }

        // Je Release (ohne Entwuerfe) die Version und ihre Dateien.
        private static async Task<List<(string Version, List<Asset> Assets)>> ListReleasesAsync()
        {
            string json;
            using (var client = NewClient())
                json = await client.GetStringAsync($"https://api.github.com/repos/{Repository}/releases?per_page=100");
            var result = new List<(string, List<Asset>)>();
            foreach (var item in (IEnumerable)new JavaScriptSerializer().DeserializeObject(json))
            {
                if (!(item is Dictionary<string, object> release) || (release.TryGetValue("draft", out var draft) && draft is bool isDraft && isDraft))
                    continue;
                var version = ((release.TryGetValue("tag_name", out var tag) ? tag as string : null) ?? "").TrimStart('v', 'V');
                var files = new List<Asset>();
                if (release.TryGetValue("assets", out var assets) && assets is IEnumerable list)
                {
                    foreach (var assetItem in list)
                    {
                        if (assetItem is Dictionary<string, object> asset && asset.TryGetValue("name", out var name)
                            && asset.TryGetValue("browser_download_url", out var url))
                        {
                            long size = asset.TryGetValue("size", out var sizeValue) && sizeValue != null ? Convert.ToInt64(sizeValue) : 0;
                            files.Add(new Asset { Name = name as string ?? "", DownloadUrl = url as string, Size = size });
                        }
                    }
                }
                result.Add((version, files));
            }
            return result;
        }

        public static async Task<Release> FindNewerAsync()
        {
            Release best = null;
            foreach (var (version, assets) in await ListReleasesAsync())
            {
                if (Compare(version, best?.Version ?? CurrentVersion) <= 0)
                    continue;
                var setup = assets.FirstOrDefault(a => string.Equals(a.Name, AssetName, StringComparison.OrdinalIgnoreCase));
                if (setup != null)
                    best = new Release { Version = version, DownloadUrl = setup.DownloadUrl };
            }
            return best;
        }

        // Die passende Datei aus dem neuesten Release, das eine hat.
        public static async Task<Asset> FindNewestAssetAsync(Regex pattern)
        {
            Asset best = null;
            string bestVersion = null;
            foreach (var (version, assets) in await ListReleasesAsync())
            {
                var match = assets.FirstOrDefault(a => pattern.IsMatch(a.Name));
                if (match != null && (bestVersion == null || Compare(version, bestVersion) > 0))
                {
                    best = match;
                    bestVersion = version;
                }
            }
            return best;
        }

        // Grosse Dateien in Stuecken auf die Platte statt in den Speicher, mit Fortschritt alle 10 Prozent.
        public static async Task DownloadFileAsync(Asset asset, string target, Action<string> report)
        {
            using (var client = NewClient())
            {
                client.Timeout = TimeSpan.FromMinutes(2);
                using (var response = await client.GetAsync(asset.DownloadUrl, HttpCompletionOption.ResponseHeadersRead))
                {
                    response.EnsureSuccessStatusCode();
                    long total = response.Content.Headers.ContentLength ?? asset.Size;
                    using (var input = await response.Content.ReadAsStreamAsync())
                    using (var output = new FileStream(target, FileMode.Create, FileAccess.Write, FileShare.None, 81920, true))
                    {
                        var buffer = new byte[81920];
                        long done = 0;
                        int nextPercent = 10;
                        int read;
                        while ((read = await input.ReadAsync(buffer, 0, buffer.Length)) > 0)
                        {
                            await output.WriteAsync(buffer, 0, read);
                            done += read;
                            if (total > 0 && done * 100 / total >= nextPercent && nextPercent < 100)
                            {
                                report(LocaleCatalog.T("installer.progress.percent", "percent", nextPercent));
                                nextPercent += 10;
                            }
                        }
                        if (total > 0 && done != total)
                            throw new IOException(LocaleCatalog.T("installer.download.incomplete", "done", done, "total", total));
                    }
                }
            }
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
        private readonly Label languageLabel = new Label();
        private readonly ComboBox languageBox = new ComboBox();
        private readonly Label introLabel = new Label();
        private readonly Label pathLabel = new Label();
        private readonly TextBox pathBox = new TextBox();
        private readonly Button browseButton = new Button();
        private readonly CheckBox removeUe4ssBox = new CheckBox();
        private readonly Button installButton = new Button();
        private readonly Button uninstallButton = new Button();
        private readonly Button readmeButton = new Button();
        private readonly Label statusLabel = new Label();
        private readonly TextBox statusBox = new TextBox();
        private readonly Button closeButton = new Button();
        private readonly string[] startArgs;
        private readonly bool explicitLanguage;
        private string selectedLanguage = LocaleCatalog.Auto;
        private bool changingLanguage;

        public SetupForm(string[] args)
        {
            startArgs = args ?? new string[0];
            string requestedLanguage;
            explicitLanguage = TryGetOption(startArgs, "--language", out requestedLanguage);
            LocaleCatalog.Initialize(explicitLanguage ? requestedLanguage : LocaleCatalog.Auto);
            if (explicitLanguage)
                selectedLanguage = requestedLanguage;

            Text = LocaleCatalog.T("installer.title", "version", Updater.CurrentVersion);
            AccessibleName = Text;
            Font = new Font("Segoe UI", 10f);
            AutoScaleMode = AutoScaleMode.Dpi;
            StartPosition = FormStartPosition.CenterScreen;
            MinimumSize = new Size(640, 500);
            Size = new Size(780, 560);

            var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, Padding = new Padding(12), AutoSize = false };
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            Controls.Add(layout);
            int tab = 0;

            languageLabel.AutoSize = true;
            languageLabel.TabIndex = tab++;
            layout.Controls.Add(languageLabel, 0, 0);
            layout.SetColumnSpan(languageLabel, 2);

            languageBox.DropDownStyle = ComboBoxStyle.DropDownList;
            languageBox.Dock = DockStyle.Fill;
            languageBox.TabIndex = tab++;
            languageBox.SelectedIndexChanged += (s, e) =>
            {
                if (changingLanguage)
                    return;
                var choice = languageBox.SelectedItem as LanguageChoice;
                if (choice == null)
                    return;
                selectedLanguage = choice.Code;
                LocaleCatalog.Select(choice.Code);
                ApplyLocale();
            };
            layout.Controls.Add(languageBox, 0, 1);
            layout.SetColumnSpan(languageBox, 2);

            introLabel.AutoSize = true;
            introLabel.MaximumSize = new Size(720, 0);
            introLabel.Margin = new Padding(0, 10, 0, 10);
            layout.Controls.Add(introLabel, 0, 2);
            layout.SetColumnSpan(introLabel, 2);

            // Ein Label direkt vor dem Feld in der Tab-Reihenfolge benennt das Feld fuer Screenreader.
            pathLabel.AutoSize = true;
            pathLabel.TabIndex = tab++;
            layout.Controls.Add(pathLabel, 0, 3);
            layout.SetColumnSpan(pathLabel, 2);
            pathBox.Dock = DockStyle.Fill;
            pathBox.TabIndex = tab++;
            layout.Controls.Add(pathBox, 0, 4);
            browseButton.AutoSize = true;
            browseButton.TabIndex = tab++;
            browseButton.Click += (s, e) => Browse();
            layout.Controls.Add(browseButton, 1, 4);

            removeUe4ssBox.AutoSize = true;
            removeUe4ssBox.Margin = new Padding(0, 10, 0, 10);
            removeUe4ssBox.TabIndex = tab++;
            layout.Controls.Add(removeUe4ssBox, 0, 5);
            layout.SetColumnSpan(removeUe4ssBox, 2);

            var buttons = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, TabIndex = tab++ };
            ConfigureButton(installButton, 0, (s, e) => RunInstall());
            ConfigureButton(uninstallButton, 1, (s, e) => RunUninstall());
            ConfigureButton(readmeButton, 2, (s, e) => ShowReadme());
            buttons.Controls.AddRange(new Control[] { installButton, uninstallButton, readmeButton });
            layout.Controls.Add(buttons, 0, 6);
            layout.SetColumnSpan(buttons, 2);

            statusLabel.AutoSize = true;
            statusLabel.Margin = new Padding(0, 10, 0, 0);
            statusLabel.TabIndex = tab++;
            layout.Controls.Add(statusLabel, 0, 7);
            layout.SetColumnSpan(statusLabel, 2);
            statusBox.Multiline = true;
            statusBox.ReadOnly = true;
            statusBox.ScrollBars = ScrollBars.Vertical;
            statusBox.Dock = DockStyle.Fill;
            statusBox.TabStop = true;
            statusBox.TabIndex = tab++;
            layout.Controls.Add(statusBox, 0, 8);
            layout.SetColumnSpan(statusBox, 2);
            layout.RowStyles.Clear();
            for (int row = 0; row < 8; row++)
                layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));

            ConfigureButton(closeButton, tab++, (s, e) => Close());
            closeButton.Anchor = AnchorStyles.Right;
            layout.Controls.Add(closeButton, 1, 9);

            AcceptButton = installButton;
            CancelButton = closeButton;
            ApplyLocale();
            Shown += (s, e) => OnStart();
        }

        private sealed class LanguageChoice
        {
            public readonly string Code;
            public readonly string Name;

            public LanguageChoice(string code, string name)
            {
                Code = code;
                Name = name;
            }

            public override string ToString()
            {
                return Name;
            }
        }

        private static void ConfigureButton(Button button, int tabIndex, EventHandler click)
        {
            button.AutoSize = true;
            button.MinimumSize = new Size(140, 34);
            button.TabIndex = tabIndex;
            button.Click += click;
        }

        private void ApplyLocale()
        {
            Text = LocaleCatalog.T("installer.title", "version", Updater.CurrentVersion);
            AccessibleName = Text;

            languageLabel.Text = LocaleCatalog.T("installer.language.label");
            languageBox.AccessibleName = LocaleCatalog.T("installer.language.name");
            languageBox.AccessibleDescription = LocaleCatalog.T("installer.language.description");
            introLabel.Text = LocaleCatalog.T("installer.intro");
            pathLabel.Text = LocaleCatalog.T("installer.game_path.label");
            pathBox.AccessibleName = LocaleCatalog.T("installer.game_path.name");
            pathBox.AccessibleDescription = LocaleCatalog.T("installer.game_path.description");
            browseButton.Text = LocaleCatalog.T("installer.browse");
            browseButton.AccessibleName = LocaleCatalog.T("installer.browse.name");
            removeUe4ssBox.Text = LocaleCatalog.T("installer.remove_ue4ss");
            installButton.Text = LocaleCatalog.T("installer.install");
            uninstallButton.Text = LocaleCatalog.T("installer.uninstall");
            readmeButton.Text = LocaleCatalog.T("installer.show_readme");
            statusLabel.Text = LocaleCatalog.T("installer.messages");
            statusBox.AccessibleName = LocaleCatalog.T("installer.messages.name");
            closeButton.Text = LocaleCatalog.T("installer.close");

            changingLanguage = true;
            var previous = selectedLanguage;
            languageBox.Items.Clear();
            languageBox.Items.Add(new LanguageChoice(LocaleCatalog.Auto, LocaleCatalog.T("installer.language.auto")));
            foreach (var pack in LocaleCatalog.Available)
                languageBox.Items.Add(new LanguageChoice(pack.Code, pack.NativeName));
            for (int i = 0; i < languageBox.Items.Count; i++)
            {
                var choice = (LanguageChoice)languageBox.Items[i];
                if (string.Equals(choice.Code, previous, StringComparison.OrdinalIgnoreCase))
                {
                    languageBox.SelectedIndex = i;
                    break;
                }
            }
            if (languageBox.SelectedIndex < 0)
                languageBox.SelectedIndex = 0;
            changingLanguage = false;
        }

        private static bool TryGetOption(string[] args, string name, out string value)
        {
            value = null;
            for (int i = 0; args != null && i + 1 < args.Length; i++)
            {
                if (string.Equals(args[i], name, StringComparison.OrdinalIgnoreCase))
                {
                    value = args[i + 1];
                    return true;
                }
            }
            return false;
        }

        private void SelectInstalledLanguage(string game)
        {
            if (explicitLanguage || string.IsNullOrWhiteSpace(game))
                return;
            var path = Path.Combine(game, @"FFRS\Binaries\Win64\ue4ss\Mods\FFRSAccess\language.txt");
            try
            {
                if (!File.Exists(path))
                    return;
                var code = File.ReadAllText(path, Encoding.UTF8).Trim();
                if (code.Length == 0)
                    return;
                LocaleCatalog.Select(code);
                selectedLanguage = code;
                ApplyLocale();
            }
            catch (Exception ex)
            {
                Installer.Log("language.txt nicht lesbar: " + ex.Message);
            }
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
            string commandMode = null, commandGame = null;
            for (int i = 0; i + 1 < startArgs.Length; i++)
            {
                if (startArgs[i] == "--install" || startArgs[i] == "--uninstall")
                {
                    commandMode = startArgs[i];
                    commandGame = startArgs[++i];
                }
                else if (startArgs[i] == "--language")
                {
                    i++;
                }
            }
            if (commandMode != null)
            {
                // Das Fenster nach der Admin-Abfrage kann hinter anderen Fenstern landen.
                Activate();
                pathBox.Text = commandGame;
                SelectInstalledLanguage(pathBox.Text);
                removeUe4ssBox.Checked = startArgs.Contains("--ue4ss");
                pathBox.Focus();
                if (commandMode == "--install")
                    RunInstall();
                else
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
                Report(LocaleCatalog.T("installer.search_failed", "error", ex.Message));
            }
            if (found.Count > 0)
            {
                pathBox.Text = found[0];
                SelectInstalledLanguage(found[0]);
                Report(LocaleCatalog.T("installer.found", "path", found[0]));
                foreach (var other in found.Skip(1))
                    Report(LocaleCatalog.T("installer.also_found", "path", other));
            }
            else
            {
                Report(LocaleCatalog.T("installer.none_found"));
            }
            pathBox.Focus();
            pathBox.SelectAll();
            CheckForUpdate();
        }

        private async void CheckForUpdate()
        {
            Report(LocaleCatalog.T("installer.update.checking", "version", Updater.CurrentVersion));
            Updater.Release release;
            try
            {
                release = await Updater.FindNewerAsync();
            }
            catch (Exception ex)
            {
                Report(LocaleCatalog.T("installer.update.failed", "error", ex.Message));
                return;
            }
            if (release == null)
            {
                Report(LocaleCatalog.T("installer.update.latest"));
                return;
            }
            Report(LocaleCatalog.T("installer.update.available", "version", release.Version));
            var answer = MessageBox.Show(this, LocaleCatalog.T("installer.update.prompt", "new", release.Version, "current", Updater.CurrentVersion),
                Text, MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (answer != DialogResult.Yes)
            {
                Report(LocaleCatalog.T("installer.update.skipped"));
                pathBox.Focus();
                return;
            }
            SetBusy(true);
            Report(LocaleCatalog.T("installer.update.downloading", "version", release.Version));
            try
            {
                var setup = await Updater.DownloadAsync(release);
                // Das neue Setup installiert gleich in den Ordner aus dem Feld, sonst startet es normal.
                var game = Installer.ResolveGameDir(pathBox.Text);
                var arguments = (game != null ? $"--install \"{game.TrimEnd('\\')}\" " : "")
                    + $"--language \"{LocaleCatalog.CurrentCode}\"";
                Process.Start(new ProcessStartInfo(setup, arguments) { UseShellExecute = true });
                Close();
            }
            catch (Exception ex)
            {
                Report(LocaleCatalog.T("installer.update.download_failed", "error", ex.Message));
                Tell(LocaleCatalog.T("installer.update.load_failed", "error", ex.Message), MessageBoxIcon.Error);
                SetBusy(false);
                pathBox.Focus();
            }
        }

        private void Browse()
        {
            using (var dialog = new FolderBrowserDialog { Description = LocaleCatalog.T("installer.browse.description"), ShowNewFolderButton = false })
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
                Tell(LocaleCatalog.T("installer.game.invalid", "file", Installer.ExeRelative), MessageBoxIcon.Warning);
                pathBox.Focus();
                return null;
            }
            pathBox.Text = game;
            if (Installer.IsGameRunning(Path.Combine(game, @"FFRS\Binaries\Win64")))
            {
                Tell(LocaleCatalog.T("installer.game.running"), MessageBoxIcon.Warning);
                return null;
            }
            return game;
        }

        private void RunInstall()
        {
            var game = CheckGameDir();
            if (game != null)
                Run("--install", game, async () =>
                {
                    Installer.Install(game, LocaleCatalog.CurrentCode, Report);
                    return await Descriptions.UpdateAsync(game, Report);
                }, LocaleCatalog.T("installer.install.done"));
        }

        private void RunUninstall()
        {
            var game = CheckGameDir();
            if (game != null)
                Run("--uninstall", game, () =>
                {
                    Installer.Uninstall(game, removeUe4ssBox.Checked, Report);
                    return Task.FromResult<string>(null);
                }, LocaleCatalog.T("installer.uninstall.done"));
        }

        // Laeuft gerade eine Installation (mit Download), darf das Fenster nicht zugehen.
        private bool running;

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (running && e.CloseReason == CloseReason.UserClosing)
            {
                e.Cancel = true;
                Report(LocaleCatalog.T("installer.busy"));
                return;
            }
            base.OnFormClosing(e);
        }

        // action gibt einen Hinweis zurueck, der an die Abschlussmeldung angehaengt wird, oder null.
        private async void Run(string mode, string game, Func<Task<string>> action, string doneMessage)
        {
            SetBusy(true);
            running = true;
            Report(Installer.AccountInfo());
            Report(LocaleCatalog.T("installer.game_path.status", "path", game));
            try
            {
                var note = await action();
                running = false;
                var message = string.IsNullOrEmpty(note) ? doneMessage : LocaleCatalog.T("installer.completion_with_note", "message", doneMessage, "note", note);
                Report(message);
                Tell(message, string.IsNullOrEmpty(note) ? MessageBoxIcon.Information : MessageBoxIcon.Warning);
            }
            catch (UnauthorizedAccessException ex)
            {
                running = false;
                Report(LocaleCatalog.T("installer.no_write_access", "error", ex.Message));
                if (Installer.IsElevated())
                {
                    // Schon mit Adminrechten: ein weiterer Neustart hilft nicht, sonst entsteht eine Schleife.
                    var message = LocaleCatalog.T("installer.admin_blocked", "error", ex.Message, "log", Installer.LogPath);
                    Report(message);
                    Tell(message, MessageBoxIcon.Error);
                    SetBusy(false);
                    statusBox.Focus();
                    return;
                }
                var answer = MessageBox.Show(this, LocaleCatalog.T("installer.admin_prompt"),
                    Text, MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                if (answer == DialogResult.Yes && RestartElevated(mode, game))
                {
                    Close();
                    return;
                }
            }
            catch (Exception ex)
            {
                running = false;
                Report(LocaleCatalog.T("installer.error", "error", ex));
                Tell(LocaleCatalog.T("installer.failed", "error", ex.Message, "log", Installer.LogPath), MessageBoxIcon.Error);
            }
            finally
            {
                running = false;
                SetBusy(false);
            }
            statusBox.Focus();
        }

        private bool RestartElevated(string mode, string game)
        {
            try
            {
                // Ein Backslash am Ende wuerde das schliessende Anfuehrungszeichen maskieren.
                var arguments = $"{mode} \"{game.TrimEnd('\\')}\"" + (removeUe4ssBox.Checked ? " --ue4ss" : "")
                    + $" --language \"{LocaleCatalog.CurrentCode}\"";
                Report(LocaleCatalog.T("installer.elevating", "arguments", arguments));
                Process.Start(new ProcessStartInfo(Application.ExecutablePath, arguments) { Verb = "runas", UseShellExecute = true });
                return true;
            }
            catch (Exception ex)
            {
                Report(LocaleCatalog.T("installer.elevation_cancelled", "error", ex.Message));
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
                    var localizedReadme = "Liesmich." + LocaleCatalog.CurrentCode + ".txt";
                    var entry = zip.Entries.FirstOrDefault(e => e.FullName.Replace('\\', '/') == localizedReadme)
                        ?? zip.Entries.FirstOrDefault(e => e.FullName.Replace('\\', '/') == "Liesmich.txt");
                    if (entry == null)
                        throw new FileNotFoundException(LocaleCatalog.T("installer.readme_missing"));
                    entry.ExtractToFile(target, true);
                }
                Process.Start(new ProcessStartInfo("notepad.exe", "\"" + target + "\"") { UseShellExecute = true });
            }
            catch (Exception ex)
            {
                Tell(LocaleCatalog.T("installer.readme_failed", "error", ex.Message), MessageBoxIcon.Error);
            }
        }

        private void SetBusy(bool busy)
        {
            UseWaitCursor = busy;
            languageBox.Enabled = installButton.Enabled = uninstallButton.Enabled = browseButton.Enabled = readmeButton.Enabled = !busy;
            Application.DoEvents();
        }

        private void Tell(string message, MessageBoxIcon icon)
        {
            MessageBox.Show(this, message, Text, MessageBoxButtons.OK, icon);
        }
    }
}
