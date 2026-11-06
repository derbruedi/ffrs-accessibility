// Liest Karten-Daten aus den unverschluesselten Spielcontainern. Schreibt nichts ins Spiel.
using System.Text.RegularExpressions;
using CUE4Parse.Compression;
using CUE4Parse.FileProvider;
using CUE4Parse.MappingsProvider.Usmap;
using CUE4Parse.UE4.Assets.Exports;
using CUE4Parse.UE4.Assets.Exports.Component.StaticMesh;
using CUE4Parse.UE4.Assets.Exports.StaticMesh;
using CUE4Parse.UE4.Objects.Core.Math;
using CUE4Parse.UE4.Objects.UObject;
using CUE4Parse.UE4.Versions;
using Newtonsoft.Json;

// Standard ist die Vollversion; FFRS_PAKS, FFRS_USMAP und FFRS_OUT stellen auf andere Ordner um (etwa die Demo).
var paks = Environment.GetEnvironmentVariable("FFRS_PAKS") ?? @"k:\steamlibrary\steamapps\common\FINAL FANTASY RESONANCE\FFRS\Content\Paks";
var usmap = Environment.GetEnvironmentVariable("FFRS_USMAP") ?? @"H:\ff\research\dumps\FFRS-5.6.1-0+UE5-1ceefac8.usmap";
var outDir = Environment.GetEnvironmentVariable("FFRS_OUT") ?? @"H:\ff\research\extract\out_full";
Directory.CreateDirectory(outDir);

OodleHelper.DownloadOodleDll();
OodleHelper.Initialize();
var provider = new DefaultFileProvider(paks, SearchOption.TopDirectoryOnly, new VersionContainer(EGame.GAME_UE5_6));
provider.MappingsContainer = new FileUsmapTypeMappingsProvider(usmap);
provider.Initialize();
provider.Mount();
//provider.LoadLocalization("de");
Console.WriteLine($"Dateien: {provider.Files.Count}");

if (args[0] == "list")
{
    var regex = new Regex(args[1], RegexOptions.IgnoreCase);
    foreach (var key in provider.Files.Keys.Where(k => regex.IsMatch(k)).OrderBy(k => k))
        Console.WriteLine(key);
}
else if (args[0] == "actors")
{
    // Alle platzierten Objekte der Level: Klasse, Name, Position, Modell, Skalierung, dazu Einzelinstanzen (Baeume, Steine).
    using var writer = new StreamWriter(Path.Combine(outDir, args[1]));
    foreach (var path in args.Skip(2))
    {
        var level = Path.GetFileNameWithoutExtension(path);
        try
        {
            foreach (var export in provider.LoadPackage(path).GetExports())
            {
                if (export is UInstancedStaticMeshComponent instanced && instanced.PerInstanceSMData != null)
                {
                    var origin = instanced.GetOrDefault("RelativeLocation", FVector.ZeroVector);
                    var mesh = instanced.GetOrDefault<FPackageIndex?>("StaticMesh")?.Name ?? "";
                    foreach (var instance in instanced.PerInstanceSMData)
                    {
                        var at = instance.TransformData.Translation;
                        var size = instance.TransformData.Scale3D;
                        writer.WriteLine($"{level}\tInstanz\t{export.Name}\t{origin.X + at.X:F0}\t{origin.Y + at.Y:F0}\t{origin.Z + at.Z:F0}\t{mesh}\t{size.X:F2}\t{size.Y:F2}\t{size.Z:F2}");
                    }
                    continue;
                }
                var rootIndex = export.GetOrDefault<FPackageIndex?>("RootComponent");
                if (rootIndex == null || rootIndex.IsNull)
                    continue;
                var root = rootIndex.Load<UObject>();
                if (root == null)
                    continue;
                var location = root.GetOrDefault("RelativeLocation", FVector.ZeroVector);
                var scale = root.GetOrDefault("RelativeScale3D", FVector.OneVector);
                var meshName = root.GetOrDefault<FPackageIndex?>("StaticMesh")?.Name ?? "";
                writer.WriteLine($"{level}\t{export.ExportType}\t{export.Name}\t{location.X:F0}\t{location.Y:F0}\t{location.Z:F0}\t{meshName}\t{scale.X:F2}\t{scale.Y:F2}\t{scale.Z:F2}");
            }
            Console.WriteLine($"{level}: gelesen");
        }
        catch (Exception error)
        {
            Console.WriteLine($"{level}: Fehler {error.Message}");
        }
    }
}
else if (args[0] == "mesh")
{
    // Schreibt Eckpunkte und Dreiecke des ersten Detailgrads: int32 Anzahl Punkte, int32 Anzahl Indizes, float32 xyz..., uint32 Indizes...
    var mesh = provider.LoadPackage(args[1]).GetExports().OfType<UStaticMesh>().First();
    var lod = mesh.RenderData!.LODs!.First(l => !l.SkipLod);
    var verts = lod.PositionVertexBuffer!.Verts;
    var indices = lod.IndexBuffer!.Buffer!;
    using var output = new BinaryWriter(File.Create(Path.Combine(outDir, args[2])));
    output.Write(verts.Length);
    output.Write(indices.Length);
    foreach (var vert in verts)
    {
        output.Write(vert.X);
        output.Write(vert.Y);
        output.Write(vert.Z);
    }
    foreach (var index in indices)
        output.Write(index);
    Console.WriteLine($"{mesh.Name}: {verts.Length} Punkte, {indices.Length / 3} Dreiecke, BodySetup {mesh.BodySetup?.Name}");
}
else if (args[0] == "dump")
{
    foreach (var path in args.Skip(1))
    {
        var exports = provider.LoadPackage(path).GetExports();
        var name = Path.GetFileNameWithoutExtension(path);
        using var writer = new StreamWriter(Path.Combine(outDir, name + ".json"));
        new JsonSerializer { Formatting = Formatting.Indented, ReferenceLoopHandling = ReferenceLoopHandling.Ignore }.Serialize(writer, exports);
        Console.WriteLine($"{path}: {exports.Count()} Exporte");
    }
}
else if (args[0] == "dumpall")
{
    // Alle passenden Pakete als JSON in einen Unterordner: dumpall <ordner> <regex>
    var folder = Directory.CreateDirectory(Path.Combine(outDir, args[1])).FullName;
    var regex = new Regex(args[2], RegexOptions.IgnoreCase);
    var count = 0;
    foreach (var key in provider.Files.Keys.Where(k => regex.IsMatch(k)).OrderBy(k => k))
    {
        try
        {
            var exports = provider.LoadPackage(key).GetExports();
            using var writer = new StreamWriter(Path.Combine(folder, Path.GetFileNameWithoutExtension(key) + ".json"));
            new JsonSerializer { ReferenceLoopHandling = ReferenceLoopHandling.Ignore }.Serialize(writer, exports);
            count++;
        }
        catch (Exception error)
        {
            Console.WriteLine($"{key}: {error.Message}");
        }
    }
    Console.WriteLine($"{count} Pakete");
}
else if (args[0] == "locres")
{
    // Die Sprachdatei des Spiels als Tabelle: locres <sprache> <datei>, je Zeile Namensraum, Schluessel, Text.
    var file = provider.Files.First(f => f.Key.EndsWith($"Localization/Game/{args[1]}/Game.locres", StringComparison.OrdinalIgnoreCase)).Value;
    var resource = new CUE4Parse.UE4.Localization.FTextLocalizationResource(file.CreateReader());
    using var writer = new StreamWriter(Path.Combine(outDir, args[2]));
    foreach (var space in resource.Entries)
        foreach (var entry in space.Value)
            writer.WriteLine($"{space.Key.Str}\t{entry.Key.Str}\t{entry.Value.LocalizedString.Replace("\r", " ").Replace("\n", " ").Replace("\t", " ")}");
    Console.WriteLine($"Namensraeume: {resource.Entries.Count}");
}
