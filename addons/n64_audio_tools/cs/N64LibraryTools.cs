#if TOOLS
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using Godot;

namespace m3d3.Audio.Tools;

/// <summary>
/// Editor-only operations on the instrument library (<see cref="N64Library"/>, a folder:
/// Project Settings > n64/audio/library_path) and its bank sets / areas:
///  - Load / Save: the index plus one file per instrument and per processed sample; Save
///    moves recordings into _source/&lt;hash&gt;.wav (once per content), merges samples that are
///    the same recording with the same processing and the same data, deletes the files of
///    instruments / samples no longer in the library (and their bank-set entries);
///  - ImportCd64: a CD64 export into the library, ADPCM carried over as is (bit-for-bit).
///    Samples are matched against the library by recording content + canonical settings
///    (and must hold the same data to be shared). Instruments are tagged with the export's
///    name (cd64_export, plus their sidecar name in cd64_name): re-importing the export
///    updates its own instruments in place (a rename in the library survives), removes the
///    ones it no longer has, never touches others. An instrument named like a library one
///    and identical to it (a library instrument CD64 exported unchanged) is that instrument;
///    a different one of a taken name gets " (&lt;export&gt;)". Song, sfx and plain exports also make / update a bank set named after
///    the export (programs and channels as in the sidecar, so a CD64 song plays unchanged);
///    "kind": "library" (the library's own export) updates instruments by name, no set;
///  - ExportCd64: instruments (and their samples, sources, settings) as a CD64 export folder
///    (sidecar "kind": "library"), sample ids = the sample files' names (stable);
///  - ConvertBank: a legacy N64SoundBank's samples / instruments into the library (shared
///    where they already are) plus a bank set with the bank's programs. The bank is untouched;
///  - DuplicateVariant, Fork (a copy of a shared sample for one instrument).
/// </summary>
[GlobalClass, Tool]
public partial class N64LibraryTools : RefCounted
{
	public const string TagMeta = N64Cd64Importer.TagMeta;
	/// <summary>Metadata on imported instruments: their name in the sidecar (re-import matches it).</summary>
	public const string NameMeta = "cd64_name";
	/// <summary>Metadata on variants: the instrument they were made from (informational).</summary>
	public const string VariantMeta = "variant_of";
	public const string SamplesDir = "samples", InstrumentsDir = "instruments", SetsDir = "sets", AreasDir = "areas", SourceDir = "_source";

	/// <summary>The library folder (default: the project setting).</summary>
	public string Root = N64Library.Root();
	/// <summary>What the last operation did (for the output panel).</summary>
	public string Summary = "";
	/// <summary>The bank set the last import / conversion made or updated ("" if none).</summary>
	public string LastSetPath = "";

	static readonly Godot.Collections.Dictionary ProcessorDefaults = new()
	{
		["start"] = 0, ["end"] = -1, ["fade_ms"] = 0, ["rate"] = 16000, ["lowpass"] = 0, ["trim"] = true, ["trim_db"] = -50,
		["normalize"] = true, ["gain_db"] = 0, ["bits"] = 16, ["predictors"] = 4, ["loop"] = "none", ["loop_start"] = -1,
		["loop_end"] = -1, ["crossfade_ms"] = 0, ["root_key"] = -1, ["tune_cents"] = 0,
	};

	public string IndexPath => Dir(N64Library.IndexFile);

	string Dir(string sub) => $"{Root}/{sub}";

	// --- Load / save -----------------------------------------------------------------------------

	/// <summary>The library (an empty one if there's none yet). Instrument / sample files in
	/// the folders but not in the index (copied in by hand) are picked up too.</summary>
	public N64Library Load()
	{
		var lib = ResourceLoader.Exists(IndexPath) ? ResourceLoader.Load(IndexPath) as N64Library : null;
		lib ??= new N64Library { Name = "library" };
		var have = new HashSet<string>();
		foreach (var s in lib.Samples) if (s != null) have.Add(s.ResourcePath);
		foreach (var i in lib.Instruments) if (i != null) have.Add(i.ResourcePath);
		Prune(lib);
		foreach (var f in Files(SamplesDir))
			if (!have.Contains(f) && ResourceLoader.Load(f) is N64Sample s) lib.Samples.Add(s);
		foreach (var f in Files(InstrumentsDir))
			if (!have.Contains(f) && ResourceLoader.Load(f) is N64Instrument i) lib.Instruments.Add(i);
		return lib;
	}

	static void Prune(N64Library lib)
	{
		var s = new Godot.Collections.Array<N64Sample>();
		foreach (var x in lib.Samples) if (x != null) s.Add(x);
		var i = new Godot.Collections.Array<N64Instrument>();
		foreach (var x in lib.Instruments) if (x != null) i.Add(x);
		lib.Samples = s;
		lib.Instruments = i;
	}

	List<string> Files(string sub)
	{
		var outL = new List<string>();
		string d = Dir(sub);
		if (!DirAccess.DirExistsAbsolute(d)) return outL;
		foreach (var f in DirAccess.GetFilesAt(d))
			if (f.EndsWith(".tres")) outL.Add($"{d}/{f}");
		outL.Sort(StringComparer.Ordinal);
		return outL;
	}

	/// <summary>Saves the library: recordings into _source, identical samples merged, one file
	/// per sample / instrument, the index; deletes files of what was removed (and drops removed
	/// instruments from the bank sets). Returns "" or an error message.</summary>
	public string Save(N64Library lib)
	{
		try
		{
			Prune(lib);
			foreach (var sub in new[] { SamplesDir, InstrumentsDir, SourceDir })
				Directory.CreateDirectory(ProjectSettings.GlobalizePath(Dir(sub)));
			string ignore = ProjectSettings.GlobalizePath(Dir(SourceDir) + "/.gdignore");
			if (!File.Exists(ignore)) File.WriteAllText(ignore, "");
			foreach (var s in lib.Samples) EnsureSource(s);
			int merged = Dedup(lib);
			// Samples first: instruments reference their files.
			var stems = new HashSet<string>();
			foreach (var s in lib.Samples)
				if (Owned(s, SamplesDir)) stems.Add(s.ResourcePath);
			foreach (var s in lib.Samples)
			{
				string path = Owned(s, SamplesDir) ? s.ResourcePath
					: FreePath(SamplesDir, s.HasMeta(N64Cd64Importer.IdMeta) ? s.GetMeta(N64Cd64Importer.IdMeta).AsString() : s.Name, stems);
				var err = ResourceSaver.Save(s, path);
				if (err != Error.Ok) return $"saving {path} failed ({err})";
				s.TakeOverPath(path);
			}
			stems.Clear();
			foreach (var i in lib.Instruments)
				if (Owned(i, InstrumentsDir)) stems.Add(i.ResourcePath);
			foreach (var i in lib.Instruments)
			{
				string path = Owned(i, InstrumentsDir) ? i.ResourcePath : FreePath(InstrumentsDir, i.Name, stems);
				var err = ResourceSaver.Save(i, path);
				if (err != Error.Ok) return $"saving {path} failed ({err})";
				i.TakeOverPath(path);
			}
			// What the library no longer has: its files, its bank-set entries, unused recordings.
			var sets = LoadSets();  // before files go (sets reference instrument files)
			var keep = new HashSet<string>();
			foreach (var s in lib.Samples) keep.Add(s.ResourcePath);
			foreach (var i in lib.Instruments) keep.Add(i.ResourcePath);
			var goneInst = new HashSet<string>();
			foreach (var sub in new[] { SamplesDir, InstrumentsDir })
				foreach (var f in Files(sub))
					if (!keep.Contains(f))
					{
						if (sub == InstrumentsDir) goneInst.Add(f);
						File.Delete(ProjectSettings.GlobalizePath(f));
					}
			var libInst = new HashSet<N64Instrument>(lib.Instruments);
			foreach (var set in sets)
			{
				int before = set.Entries.Count;
				for (int k = set.Entries.Count - 1; k >= 0; k--)
				{
					var ins = N64BankSet.Ins(set.Entries[k]);
					if (ins == null || goneInst.Contains(ins.ResourcePath) || (ins.ResourcePath.StartsWith(Dir(InstrumentsDir) + "/") && !libInst.Contains(ins)))
						set.Entries.RemoveAt(k);
				}
				if (set.Entries.Count != before) SaveSet(set);
			}
			var sources = new HashSet<string>();
			foreach (var s in lib.Samples) sources.Add(s.SourcePath);
			string srcDir = ProjectSettings.GlobalizePath(Dir(SourceDir));
			foreach (var f in Directory.GetFiles(srcDir, "*.wav"))
				if (!sources.Contains($"{Dir(SourceDir)}/{Path.GetFileName(f)}")) File.Delete(f);
			var saved = ResourceSaver.Save(lib, IndexPath);
			if (saved != Error.Ok) return $"saving {IndexPath} failed ({saved})";
			lib.TakeOverPath(IndexPath);
			if (merged > 0) Summary += $"{(Summary == "" ? "" : "; ")}merged {merged} identical sample{(merged == 1 ? "" : "s")}";
			return "";
		}
		catch (Exception e) { return e.Message; }
	}

	bool Owned(Resource r, string sub) => r.ResourcePath.StartsWith(Dir(sub) + "/") && !r.ResourcePath.Contains("::");

	string FreePath(string sub, string name, HashSet<string> taken)
	{
		string stem = N64Cd64Importer.FileStem(name);
		string p = $"{Dir(sub)}/{stem}.tres";
		for (int n = 2; taken.Contains(p) || File.Exists(ProjectSettings.GlobalizePath(p)); n++)
			p = $"{Dir(sub)}/{stem}_{n}.tres";
		taken.Add(p);
		return p;
	}

	/// <summary>The sample's recording as _source/&lt;hash&gt;.wav (copied there once), and its
	/// SourceHash. Without a recording the hash is of the ADPCM ("adpcm-...").</summary>
	public void EnsureSource(N64Sample s)
	{
		string inLib = Dir(SourceDir) + "/";
		string abs = s.SourcePath != "" ? ProjectSettings.GlobalizePath(s.SourcePath) : "";
		if (s.SourcePath.StartsWith(inLib) && s.SourceHash != "" && File.Exists(abs)) return;
		if (abs != "" && File.Exists(abs))
		{
			string hash = HashFile(abs);
			string dest = $"{inLib}{hash}.wav";
			string destAbs = ProjectSettings.GlobalizePath(dest);
			if (!File.Exists(destAbs))
			{
				Directory.CreateDirectory(Path.GetDirectoryName(destAbs));
				File.Copy(abs, destAbs);
			}
			s.SourcePath = dest;
			s.SourceHash = hash;
		}
		else if (s.SourceHash == "")
			s.SourceHash = "adpcm-" + Hash(s.Adpcm);
	}

	/// <summary>Merges samples with the same key (recording + settings) and the same data:
	/// zones of the library's instruments are moved to the first. Returns how many went.</summary>
	public int Dedup(N64Library lib)
	{
		var first = new Dictionary<string, List<N64Sample>>();
		var drop = new Dictionary<N64Sample, N64Sample>();
		foreach (var s in lib.Samples)
		{
			string k = SampleKey(s);
			if (!first.TryGetValue(k, out var l)) first[k] = l = new List<N64Sample>();
			var same = l.Find(o => SameData(o, s));
			if (same != null) drop[s] = same;
			else l.Add(s);
		}
		if (drop.Count == 0) return 0;
		foreach (var ins in lib.Instruments)
			foreach (var z in ins.Zones)
				if (ZoneSample(z) is N64Sample s && drop.TryGetValue(s, out var to))
					z["sample"] = to;
		var keep = new Godot.Collections.Array<N64Sample>();
		foreach (var s in lib.Samples) if (!drop.ContainsKey(s)) keep.Add(s);
		lib.Samples = keep;
		return drop.Count;
	}

	/// <summary>What tells processed samples apart: the recording's content hash + the
	/// processing settings in canonical form (processor defaults filled in, numbers as the
	/// processor reads them).</summary>
	public string SampleKey(N64Sample s)
	{
		if (s.SourceHash == "") EnsureSource(s);
		return s.SourceHash + "|" + CanonicalSettings(s.Settings);
	}

	public static string CanonicalSettings(Godot.Collections.Dictionary settings)
	{
		var all = new SortedDictionary<string, Variant>(StringComparer.Ordinal);
		foreach (var k in ProcessorDefaults.Keys) all[k.AsString()] = ProcessorDefaults[k];
		if (settings != null)
			foreach (var k in settings.Keys) all[k.AsString()] = settings[k];
		var b = new StringBuilder("{");
		foreach (var (k, v) in all)
			b.Append(JsonSerializer.Serialize(k)).Append(':').Append(Canon(v)).Append(',');
		return b.Append('}').ToString();
	}

	static string Canon(Variant v) => v.VariantType switch
	{
		Variant.Type.Bool => v.AsBool() ? "true" : "false",
		Variant.Type.Int or Variant.Type.Float => ((float)v.AsDouble()).ToString("R", System.Globalization.CultureInfo.InvariantCulture),
		Variant.Type.String or Variant.Type.StringName => JsonSerializer.Serialize(v.AsString()),
		_ => JsonSerializer.Serialize(Json.Stringify(v)),
	};

	/// <summary>Same processed data (what the synth plays).</summary>
	public static bool SameData(N64Sample a, N64Sample b) =>
		a.Adpcm.AsSpan().SequenceEqual(b.Adpcm) && a.Book.AsSpan().SequenceEqual(b.Book) && a.SampleCount == b.SampleCount
		&& a.SampleRate == b.SampleRate && a.Loop == b.Loop && a.LoopStart == b.LoopStart && a.LoopEnd == b.LoopEnd
		&& a.RootKey == b.RootKey && a.TuneCents == b.TuneCents;

	public static string HashFile(string abs)
	{
		using var f = File.OpenRead(abs);
		return Convert.ToHexString(SHA256.HashData(f))[..32].ToLowerInvariant();
	}

	static string Hash(byte[] data) => Convert.ToHexString(SHA256.HashData(data))[..32].ToLowerInvariant();

	static N64Sample ZoneSample(Godot.Collections.Dictionary z) => z.ContainsKey("sample") ? z["sample"].As<N64Sample>() : null;

	// --- Bank sets / areas -------------------------------------------------------------------

	public Godot.Collections.Array<N64BankSet> LoadSets()
	{
		var outA = new Godot.Collections.Array<N64BankSet>();
		foreach (var f in Files(SetsDir))
			if (ResourceLoader.Load(f) is N64BankSet s) outA.Add(s);
		return outA;
	}

	public Godot.Collections.Array<N64AudioArea> LoadAreas()
	{
		var outA = new Godot.Collections.Array<N64AudioArea>();
		foreach (var f in Files(AreasDir))
			if (ResourceLoader.Load(f) is N64AudioArea a) outA.Add(a);
		return outA;
	}

	/// <summary>Saves a bank set into sets/ (a new one gets a file named after it). Its
	/// instruments must be saved library files. Returns "" or an error message.</summary>
	public string SaveSet(N64BankSet set) => SaveIn(set, SetsDir, set.Name);

	public string SaveArea(N64AudioArea area) => SaveIn(area, AreasDir, area.Name);

	string SaveIn(Resource r, string sub, string name)
	{
		Directory.CreateDirectory(ProjectSettings.GlobalizePath(Dir(sub)));
		string path = Owned(r, sub) ? r.ResourcePath : FreePath(sub, name, new HashSet<string>());
		var err = ResourceSaver.Save(r, path);
		if (err != Error.Ok) return $"saving {path} failed ({err})";
		r.TakeOverPath(path);
		if (r is N64BankSet set) set.Invalidate();
		return "";
	}

	/// <summary>Deletes a bank set's or area's file (areas drop the set).</summary>
	public string DeleteFile(Resource r)
	{
		if (r is N64BankSet set)
			foreach (var a in LoadAreas())
				if (a.MusicSets.Remove(set) | a.SfxSets.Remove(set)) SaveArea(a);
		if (r.ResourcePath != "" && File.Exists(ProjectSettings.GlobalizePath(r.ResourcePath)))
			File.Delete(ProjectSettings.GlobalizePath(r.ResourcePath));
		return "";
	}

	public string UniqueSetName(string name, N64BankSet except = null)
	{
		var taken = new HashSet<string>();
		foreach (var s in LoadSets()) if (s != except) taken.Add(s.Name);
		if (!taken.Contains(name)) return name;
		for (int i = 2; ; i++)
			if (!taken.Contains($"{name} {i}")) return $"{name} {i}";
	}

	// --- Variants / forks ---------------------------------------------------------------------

	/// <summary>A new library instrument with `ins`'s settings and zones (same samples: no
	/// extra RAM until its samples are re-processed), named `name` (default "&lt;name&gt; variant").</summary>
	public N64Instrument DuplicateVariant(N64Library lib, N64Instrument ins, string name = "")
	{
		var v = new N64Instrument
		{
			Name = lib.UniqueName(name != "" ? name : ins.Name + " variant"), Program = ins.Program, Bank = ins.Bank,
			IsDrumKit = ins.IsDrumKit, Envelope = ins.Envelope, Volume = ins.Volume, Pan = ins.Pan, Vibrato = ins.Vibrato,
		};
		foreach (var z in ins.Zones) v.Zones.Add(z.Duplicate());
		v.SetMeta(VariantMeta, ins.Name);
		lib.Instruments.Insert(lib.Instruments.IndexOf(ins) + 1, v);
		return v;
	}

	/// <summary>A copy of `sample` (same recording and settings) for `ins` alone: its zones
	/// playing `sample` play the copy, other instruments keep the original. Re-process the
	/// copy afterwards (an unchanged copy merges back into the original on Save).</summary>
	public N64Sample Fork(N64Library lib, N64Sample sample, N64Instrument ins)
	{
		var f = new N64Sample
		{
			Name = $"{sample.Name} ({ins.Name})", Adpcm = sample.Adpcm, Book = sample.Book, SampleCount = sample.SampleCount,
			SampleRate = sample.SampleRate, Loop = sample.Loop, LoopStart = sample.LoopStart, LoopEnd = sample.LoopEnd,
			RootKey = sample.RootKey, TuneCents = sample.TuneCents, SourcePath = sample.SourcePath, SourceHash = sample.SourceHash,
			Settings = sample.Settings.Duplicate(true),
		};
		foreach (var z in ins.Zones)
			if (ZoneSample(z) == sample) z["sample"] = f;
		lib.Samples.Insert(lib.Samples.IndexOf(sample) + 1, f);
		ins.EmitChanged();
		return f;
	}

	// --- CD64 import ----------------------------------------------------------------------------

	/// <summary>Imports a CD64 export (folder or sidecar) into the library and, unless it's a
	/// library export, into the bank set named after it (see the class notes). Saves both.
	/// Nothing is written unless the whole sidecar checks out. Returns "" or an error message.</summary>
	public string ImportCd64(string path)
	{
		Summary = "";
		LastSetPath = "";
		try
		{
			var imp = new N64Cd64Importer();
			string sidecar = imp.SidecarFor(path);
			if (sidecar == "") return $"no {N64Cd64Importer.Suffix} in {path}";
			string folder = Path.GetDirectoryName(Path.GetFullPath(sidecar));
			using var doc = JsonDocument.Parse(File.ReadAllText(sidecar));
			var root = doc.RootElement;
			if (N64Cd64Importer.Str(root, "format", "") != "cd64-n64bank") return "not a CD64 sidecar (format isn't \"cd64-n64bank\")";
			if (N64Cd64Importer.Int(root, "version", 0) != 1) return $"unsupported sidecar version {N64Cd64Importer.Int(root, "version", 0)} (this importer reads 1)";
			string tag = N64Cd64Importer.Str(root, "name", "");
			if (tag == "") tag = Path.GetFileName(sidecar)[..^N64Cd64Importer.Suffix.Length];
			string kind = N64Cd64Importer.Str(root, "kind", "");
			bool song = N64Cd64Importer.Bool(root, "song", false) || kind == "song";
			if (kind is not ("song" or "sfx" or "library")) kind = song ? "song" : "";

			var samplesIn = new List<N64Cd64Importer.SampleIn>();
			var ids = new HashSet<string>();
			foreach (var e in N64Cd64Importer.Arr(root, "samples")) samplesIn.Add(N64Cd64Importer.ReadSample(e, folder, ids));
			var instsIn = new List<N64Cd64Importer.InstIn>();
			foreach (var e in N64Cd64Importer.Arr(root, "instruments")) instsIn.Add(N64Cd64Importer.ReadInstrument(e, ids, song));

			var lib = Load();
			foreach (var s in lib.Samples) EnsureSource(s);
			var byKey = new Dictionary<string, List<N64Sample>>();
			foreach (var s in lib.Samples)
			{
				string k = SampleKey(s);
				if (!byKey.TryGetValue(k, out var l)) byKey[k] = l = new List<N64Sample>();
				l.Add(s);
			}
			string srcDir = ProjectSettings.GlobalizePath(Dir(SourceDir));
			Directory.CreateDirectory(srcDir);
			if (!File.Exists(srcDir + "/.gdignore")) File.WriteAllText(srcDir + "/.gdignore", "");

			// Samples: the library's own when it has the same processing of the same recording.
			var byId = new Dictionary<string, N64Sample>();
			var warnings = new List<string>();
			int added = 0, shared = 0;
			foreach (var si in samplesIn)
			{
				string hash = HashFile(si.Source);
				var probe = new N64Sample
				{
					Name = si.Name, Adpcm = si.Adpcm, Book = si.Book, SampleCount = si.SampleCount, SampleRate = si.SampleRate,
					Loop = si.Loop, LoopStart = si.LoopStart, LoopEnd = si.LoopEnd, RootKey = si.RootKey, TuneCents = si.TuneCents,
					Settings = si.Settings, SourceHash = hash, SourcePath = $"{Dir(SourceDir)}/{hash}.wav",
				};
				string key = hash + "|" + CanonicalSettings(si.Settings);
				if (!byKey.TryGetValue(key, out var cands)) byKey[key] = cands = new List<N64Sample>();
				var match = cands.Find(c => SameData(c, probe));
				if (match != null)
				{
					byId[si.Id] = match;
					shared++;
					continue;
				}
				if (cands.Count > 0)
					warnings.Add($"{si.Id}: same recording and settings as {cands[0].Name} but other data (another encoder?): kept apart");
				string dest = ProjectSettings.GlobalizePath(probe.SourcePath);
				if (!File.Exists(dest)) File.Copy(si.Source, dest);
				string err = new N64AudioProcessor().LoadWav(probe.SourcePath);
				if (err != "") warnings.Add($"{si.Id}: source can't be re-processed ({err})");
				probe.SetMeta(TagMeta, tag);
				probe.SetMeta(N64Cd64Importer.IdMeta, si.Id);
				lib.Samples.Add(probe);
				cands.Add(probe);
				byId[si.Id] = probe;
				added++;
			}

			// Instruments: this export's own (by their sidecar name), or for a library export
			// every instrument by name.
			bool libraryKind = kind == "library";
			var own = new Dictionary<string, N64Instrument>();
			foreach (var ins in lib.Instruments)
			{
				if (libraryKind) own.TryAdd(ins.Name, ins);
				else if (N64Cd64Importer.TagOf(ins) == tag)
					own.TryAdd(ins.HasMeta(NameMeta) ? ins.GetMeta(NameMeta).AsString() : ins.Name, ins);
			}
			var played = new HashSet<N64Sample>();  // what this export's instruments played before
			foreach (var ins in own.Values)
				foreach (var z in ins.Zones)
					if (ZoneSample(z) is N64Sample s) played.Add(s);
			var insFor = new Dictionary<N64Cd64Importer.InstIn, N64Instrument>();
			int instAdded = 0, instUpdated = 0, instShared = 0;
			foreach (var ii in instsIn)
			{
				var zones = new Godot.Collections.Array<Godot.Collections.Dictionary>();
				foreach (var z in ii.Zones)
				{
					var d = z.Duplicate();
					d["sample"] = byId[z["sample"].AsString()];
					zones.Add(d);
				}
				for (int i = 0; i < ii.Zones.Count; i++)
					for (int j = i + 1; j < ii.Zones.Count; j++)
						if (N64Cd64Importer.Overlap(ii.Zones[i], ii.Zones[j], "key") && N64Cd64Importer.Overlap(ii.Zones[i], ii.Zones[j], "vel"))
						{
							warnings.Add($"{ii.Name}: zones {i} and {j} overlap, only zone {i} plays there");
							i = j = ii.Zones.Count;
						}
				var incoming = new N64Instrument
				{
					Name = ii.Name, Program = ii.Program, Bank = ii.Bank, IsDrumKit = ii.IsDrumKit,
					Envelope = ii.Envelope, Volume = ii.Volume, Pan = ii.Pan, Vibrato = ii.Vibrato,
				};
				if (!own.Remove(ii.Name, out var ins))
				{
					// A library instrument exported unchanged (CD64 keeps its name): the same one.
					var have = lib.FindInstrumentByName(ii.Name);
					if (have != null && SameInstrument(have, incoming, zones))
					{
						insFor[ii] = have;
						instShared++;
						continue;
					}
					ins = new N64Instrument();
					ins.Name = have == null ? ii.Name : lib.UniqueName($"{ii.Name} ({tag})");
					ins.SetMeta(TagMeta, tag);
					ins.SetMeta(NameMeta, ii.Name);
					lib.Instruments.Add(ins);
					instAdded++;
				}
				else instUpdated++;
				ins.Program = ii.Program; ins.Bank = ii.Bank; ins.IsDrumKit = ii.IsDrumKit;
				ins.Envelope = ii.Envelope; ins.Volume = ii.Volume; ins.Pan = ii.Pan; ins.Vibrato = ii.Vibrato;
				if (ii.VariantOf != "") ins.SetMeta(VariantMeta, ii.VariantOf);
				ins.Zones = zones;
				ins.EmitChanged();
				insFor[ii] = ins;
			}
			// This export's instruments it no longer has: removed (a library export removes nothing).
			int instGone = 0;
			if (!libraryKind)
				foreach (var ins in own.Values)
				{
					lib.Instruments.Remove(ins);
					instGone++;
				}
			// This export's samples nothing plays any more: removed.
			var stillPlayed = new HashSet<N64Sample>();
			foreach (var ins in lib.Instruments)
				foreach (var z in ins.Zones)
					if (ZoneSample(z) is N64Sample s) stillPlayed.Add(s);
			var fresh = new HashSet<N64Sample>(byId.Values);
			int gone = 0;
			for (int i = lib.Samples.Count - 1; i >= 0; i--)
			{
				var s = lib.Samples[i];
				if (!stillPlayed.Contains(s) && !fresh.Contains(s) && (played.Contains(s) || N64Cd64Importer.TagOf(s) == tag))
				{
					lib.Samples.RemoveAt(i);
					gone++;
				}
			}

			string saveErr = Save(lib);
			if (saveErr != "") return saveErr;

			// The export's bank set (programs / channels as the sidecar has them).
			string setNote = "";
			if (!libraryKind)
			{
				N64BankSet set = null;
				foreach (var s in LoadSets())
					if (N64Cd64Importer.TagOf(s) == tag) { set = s; break; }
				bool newSet = set == null;
				if (newSet)
				{
					set = new N64BankSet { Name = UniqueSetName(tag) };
					set.SetMeta(TagMeta, tag);
				}
				set.Kind = kind == "sfx" ? N64BankSet.SetKind.Sfx : N64BankSet.SetKind.Music;
				var mine = new HashSet<N64Instrument>(insFor.Values);
				var entries = new Godot.Collections.Array<Godot.Collections.Dictionary>();
				foreach (var ii in instsIn)
					entries.Add(new Godot.Collections.Dictionary
					{
						["instrument"] = insFor[ii], ["program"] = ii.Program, ["bank"] = ii.Bank, ["channel"] = ii.Channel,
					});
				var libInst = new HashSet<N64Instrument>(lib.Instruments);
				foreach (var e in set.Entries)
				{
					var ins = N64BankSet.Ins(e);
					if (ins != null && !mine.Contains(ins) && N64Cd64Importer.TagOf(ins) != tag && libInst.Contains(ins)) entries.Add(e);
				}
				set.Entries = entries;
				string err = SaveSet(set);
				if (err != "") return err;
				LastSetPath = set.ResourcePath;
				var clashes = set.Clashes();
				setNote = $"; bank set {set.Name} ({set.Kind}, {(newSet ? "new" : "updated")}, {set.Entries.Count} instruments, {set.StoredBytes() / 1024.0:0.0} KB)";
				if (clashes.Length > 0) warnings.Add($"program clashes in {set.Name}, the first listed plays: {string.Join(", ", clashes)}");
			}

			string pre = Summary;
			Summary = $"Imported {tag} into the library {Root}: {samplesIn.Count} samples ({added} new, {shared} shared with the library, {gone} removed), "
				+ $"{instsIn.Count} instruments ({instAdded} new, {instUpdated} updated, {instShared} the library's own, {instGone} removed){setNote}";
			if (pre != "") Summary += "; " + pre;
			if (warnings.Count > 0) Summary += "; " + string.Join("; ", warnings);
			return "";
		}
		catch (Exception e) { return e.Message; }
	}

	// --- CD64 export ------------------------------------------------------------------------

	/// <summary>Writes the library instruments called `names` (empty = all) and the samples
	/// they play as a CD64 export folder `folder` (EXPORT_FORMAT.md, "kind": "library"): SFZ +
	/// samples/*.wav, adpcm/*.bin, source/*.wav (the recordings), the sidecar
	/// &lt;exportName&gt;.n64bank.json with each sample's settings. Sample ids are the sample
	/// files' names, so they stay the same across exports. Returns "" or an error message.</summary>
	public string ExportCd64(N64Library lib, string[] names, string folder, string exportName)
	{
		Summary = "";
		try
		{
			var want = names == null ? new HashSet<string>() : new HashSet<string>(names);
			var insts = lib.Instruments.Where(i => i != null && (want.Count == 0 || want.Contains(i.Name))).ToList();
			if (insts.Count == 0) return "no instruments to export";
			string dir = ProjectSettings.GlobalizePath(folder);
			foreach (var sub in new[] { "adpcm", "source", "samples" }) Directory.CreateDirectory(Path.Combine(dir, sub));
			var ids = new Dictionary<N64Sample, string>();
			var usedIds = new HashSet<string>();
			var samples = new List<N64Sample>();
			foreach (var ins in insts)
				foreach (var z in ins.Zones)
					if (ZoneSample(z) is N64Sample s && !ids.ContainsKey(s))
					{
						string id = N64Cd64Importer.FileStem(Owned(s, SamplesDir) ? s.ResourcePath.GetFile().GetBaseName() : s.Name);
						string u = id;
						for (int n = 2; !usedIds.Add(u); n++) u = $"{id}_{n}";
						ids[s] = u;
						samples.Add(s);
					}
			var warnings = new List<string>();
			using var ms = new MemoryStream();
			using (var w = new Utf8JsonWriter(ms, new JsonWriterOptions { Indented = true, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))
			{
				w.WriteStartObject();
				w.WriteString("format", "cd64-n64bank");
				w.WriteNumber("version", 1);
				w.WriteString("kind", "library");
				w.WriteString("name", exportName);
				w.WriteStartObject("origin");
				w.WriteString("tool", "m3d3 N64 Sounds library");
				w.WriteEndObject();
				w.WriteStartArray("samples");
				foreach (var s in samples)
				{
					string id = ids[s];
					File.WriteAllBytes(Path.Combine(dir, "adpcm", id + ".bin"), s.Adpcm);
					string src = s.SourcePath != "" ? ProjectSettings.GlobalizePath(s.SourcePath) : "";
					int srcRate = 0;
					string srcOut = Path.Combine(dir, "source", id + ".wav");
					if (src != "" && File.Exists(src))
					{
						File.Copy(src, srcOut, true);
						var p = new N64AudioProcessor();
						if (p.LoadWav(s.SourcePath) == "") srcRate = p.SourceRate;
					}
					else
					{
						// No recording: the N64 sample itself stands in (re-processing starts from it).
						File.WriteAllBytes(srcOut, N64SoundFontExporter.Wav(s));
						srcRate = s.SampleRate;
						warnings.Add($"{s.Name}: recording missing, source/{id}.wav is the N64 sample");
					}
					w.WriteStartObject();
					w.WriteString("id", id);
					w.WriteString("name", s.Name);
					w.WriteString("adpcm", $"adpcm/{id}.bin");
					w.WriteStartArray("book");
					foreach (var c in s.Book) w.WriteNumberValue(c);
					w.WriteEndArray();
					w.WriteNumber("sample_count", s.SampleCount);
					w.WriteNumber("sample_rate", s.SampleRate);
					w.WriteBoolean("loop", s.Loop);
					w.WriteNumber("loop_start", s.LoopStart);
					w.WriteNumber("loop_end", s.LoopEnd);
					w.WriteNumber("root_key", s.RootKey);
					w.WriteNumber("tune_cents", F(s.TuneCents));
					w.WriteString("preview", $"samples/{id}.wav");
					w.WriteString("source", $"source/{id}.wav");
					w.WriteNumber("source_rate", srcRate);
					w.WritePropertyName("settings");
					WriteVariant(w, s.Settings);
					w.WriteEndObject();
				}
				w.WriteEndArray();
				w.WriteStartArray("instruments");
				foreach (var ins in insts)
				{
					w.WriteStartObject();
					w.WriteString("name", ins.Name);
					w.WriteNumber("program", ins.Program);
					w.WriteNumber("bank", ins.Bank);
					w.WriteBoolean("is_drum_kit", ins.IsDrumKit);
					WriteFloats(w, "envelope", ins.Envelope.X, ins.Envelope.Y, ins.Envelope.Z, ins.Envelope.W);
					w.WriteNumber("volume", F(ins.Volume));
					w.WriteNumber("pan", F(ins.Pan));
					WriteFloats(w, "vibrato", ins.Vibrato.X, ins.Vibrato.Y, ins.Vibrato.Z);
					if (ins.HasMeta(VariantMeta)) w.WriteString("variant_of", ins.GetMeta(VariantMeta).AsString());
					w.WriteStartArray("zones");
					foreach (var z in ins.Zones)
					{
						if (ZoneSample(z) is not N64Sample s) continue;
						w.WriteStartObject();
						w.WriteString("sample", ids[s]);
						foreach (var k in new[] { "key_lo", "key_hi", "vel_lo", "vel_hi", "root_key" })
							w.WriteNumber(k, N64Instrument.Get(z, k, k switch { "key_hi" or "vel_hi" => 127, "root_key" => -1, _ => 0 }));
						w.WriteNumber("tune_cents", Num(z, "tune_cents", 0));
						w.WriteNumber("volume", Num(z, "volume", 1));
						w.WriteNumber("pan", Num(z, "pan", 0));
						w.WriteEndObject();
					}
					w.WriteEndArray();
					w.WriteEndObject();
				}
				w.WriteEndArray();
				w.WriteEndObject();
			}
			// SFZ + previews (samples/<id>.wav): copies of the samples named by their ids.
			var tmp = new N64SoundBank { Name = exportName };
			var copy = new Dictionary<N64Sample, N64Sample>();
			foreach (var s in samples)
			{
				var c = new N64Sample
				{
					Name = ids[s], Adpcm = s.Adpcm, Book = s.Book, SampleCount = s.SampleCount, SampleRate = s.SampleRate, Loop = s.Loop,
					LoopStart = s.LoopStart, LoopEnd = s.LoopEnd, RootKey = s.RootKey, TuneCents = s.TuneCents,
				};
				copy[s] = c;
				tmp.Samples.Add(c);
			}
			foreach (var ins in insts)
			{
				var c = new N64Instrument
				{
					Name = ins.Name, Program = ins.Program, Bank = ins.Bank, IsDrumKit = ins.IsDrumKit, Envelope = ins.Envelope,
					Volume = ins.Volume, Pan = ins.Pan, Vibrato = ins.Vibrato,
				};
				foreach (var z in ins.Zones)
					if (ZoneSample(z) is N64Sample s)
					{
						var d = z.Duplicate();
						d["sample"] = copy[s];
						c.Zones.Add(d);
					}
				tmp.Instruments.Add(c);
			}
			string sfzErr = new N64SoundFontExporter().WriteSfz(tmp, folder);
			if (sfzErr != "") return sfzErr;
			File.WriteAllBytes(Path.Combine(dir, N64Cd64Importer.FileStem(exportName) + N64Cd64Importer.Suffix), ms.ToArray());
			Summary = $"Exported {insts.Count} instruments, {samples.Count} samples to {folder}";
			if (warnings.Count > 0) Summary += "; " + string.Join("; ", warnings);
			return "";
		}
		catch (Exception e) { return e.Message; }
	}

	static double F(float f) => double.Parse(f.ToString("R", System.Globalization.CultureInfo.InvariantCulture), System.Globalization.CultureInfo.InvariantCulture);

	static double Num(Godot.Collections.Dictionary z, string k, double def) => z.ContainsKey(k) ? z[k].AsDouble() : def;

	static void WriteFloats(Utf8JsonWriter w, string name, params float[] v)
	{
		w.WriteStartArray(name);
		foreach (var f in v) w.WriteNumberValue(F(f));
		w.WriteEndArray();
	}

	static void WriteVariant(Utf8JsonWriter w, Variant v)
	{
		switch (v.VariantType)
		{
			case Variant.Type.Bool: w.WriteBooleanValue(v.AsBool()); break;
			case Variant.Type.Int: w.WriteNumberValue(v.AsInt64()); break;
			case Variant.Type.Float: w.WriteNumberValue(v.AsDouble()); break;
			case Variant.Type.String or Variant.Type.StringName: w.WriteStringValue(v.AsString()); break;
			case Variant.Type.Dictionary:
				w.WriteStartObject();
				foreach (var (k, x) in v.AsGodotDictionary())
				{
					w.WritePropertyName(k.AsString());
					WriteVariant(w, x);
				}
				w.WriteEndObject();
				break;
			case Variant.Type.Array:
				w.WriteStartArray();
				foreach (var x in v.AsGodotArray()) WriteVariant(w, x);
				w.WriteEndArray();
				break;
			default: w.WriteNullValue(); break;
		}
	}

	// --- Legacy banks ---------------------------------------------------------------------------

	/// <summary>Copies a legacy bank's samples and instruments into the library (samples the
	/// library already has, by recording + settings + data, are shared; an instrument with the
	/// same name and content is reused, a different one of that name gets " (&lt;set&gt;)") and
	/// makes a bank set `setName` with the bank's programs (CD64 song slots keep their channel).
	/// The bank itself is not changed. Saves the library and the set. Returns "" or an error.</summary>
	public string ConvertBank(N64SoundBank bank, string setName)
	{
		Summary = "";
		LastSetPath = "";
		try
		{
			if (bank == null) return "no bank";
			if (string.IsNullOrEmpty(setName)) setName = bank.Name;
			var lib = Load();
			foreach (var s in lib.Samples) EnsureSource(s);
			var byKey = new Dictionary<string, List<N64Sample>>();
			foreach (var s in lib.Samples)
			{
				string k = SampleKey(s);
				if (!byKey.TryGetValue(k, out var l)) byKey[k] = l = new List<N64Sample>();
				l.Add(s);
			}
			var all = new List<N64Sample>();
			foreach (var s in bank.Samples) if (s != null) all.Add(s);
			foreach (var ins in bank.Instruments)
				if (ins != null)
					foreach (var z in ins.Zones)
						if (ZoneSample(z) is N64Sample s) all.Add(s);
			var map = new Dictionary<N64Sample, N64Sample>();
			int added = 0, shared = 0;
			foreach (var s in all)
			{
				if (map.ContainsKey(s)) continue;
				var c = new N64Sample
				{
					Name = s.Name, Adpcm = s.Adpcm, Book = s.Book, SampleCount = s.SampleCount, SampleRate = s.SampleRate, Loop = s.Loop,
					LoopStart = s.LoopStart, LoopEnd = s.LoopEnd, RootKey = s.RootKey, TuneCents = s.TuneCents,
					SourcePath = s.SourcePath, Settings = s.Settings.Duplicate(true),
				};
				if (s.HasMeta(TagMeta)) c.SetMeta(TagMeta, s.GetMeta(TagMeta));
				EnsureSource(c);
				string key = SampleKey(c);
				if (!byKey.TryGetValue(key, out var cands)) byKey[key] = cands = new List<N64Sample>();
				var match = cands.Find(o => SameData(o, c));
				if (match != null) { map[s] = match; shared++; continue; }
				lib.Samples.Add(c);
				cands.Add(c);
				map[s] = c;
				added++;
			}
			var set = new N64BankSet { Name = UniqueSetName(setName) };
			int instAdded = 0, instShared = 0;
			foreach (var ins in bank.Instruments)
			{
				if (ins == null) continue;
				var zones = new Godot.Collections.Array<Godot.Collections.Dictionary>();
				foreach (var z in ins.Zones)
				{
					var d = z.Duplicate();
					if (ZoneSample(z) is N64Sample s) d["sample"] = map[s];
					zones.Add(d);
				}
				var have = lib.FindInstrumentByName(ins.Name);
				N64Instrument target;
				if (have != null && SameInstrument(have, ins, zones)) { target = have; instShared++; }
				else
				{
					target = new N64Instrument
					{
						Name = have == null ? ins.Name : lib.UniqueName($"{ins.Name} ({set.Name})"), Program = ins.Program, Bank = ins.Bank,
						IsDrumKit = ins.IsDrumKit, Envelope = ins.Envelope, Volume = ins.Volume, Pan = ins.Pan, Vibrato = ins.Vibrato, Zones = zones,
					};
					if (ins.HasMeta(TagMeta))
					{
						target.SetMeta(TagMeta, ins.GetMeta(TagMeta));
						target.SetMeta(NameMeta, ins.Name);
					}
					lib.Instruments.Add(target);
					instAdded++;
				}
				if (!set.Has(target))
					set.Entries.Add(new Godot.Collections.Dictionary
					{
						["instrument"] = target, ["program"] = ins.Program, ["bank"] = ins.Bank,
						["channel"] = ins.HasMeta(N64Cd64Importer.ChannelMeta) ? ins.GetMeta(N64Cd64Importer.ChannelMeta).AsInt32() : 0,
					});
			}
			string err = Save(lib);
			if (err != "") return err;
			err = SaveSet(set);
			if (err != "") return err;
			LastSetPath = set.ResourcePath;
			string pre = Summary;
			Summary = $"Converted {bank.Name} into the library: {map.Count} samples ({added} new, {shared} shared), "
				+ $"{set.Entries.Count} instruments ({instAdded} new, {instShared} already there); bank set {set.Name} ({set.StoredBytes() / 1024.0:0.0} KB)";
			if (pre != "") Summary += "; " + pre;
			return "";
		}
		catch (Exception e) { return e.Message; }
	}

	static bool SameInstrument(N64Instrument a, N64Instrument b, Godot.Collections.Array<Godot.Collections.Dictionary> bZones)
	{
		if (a.IsDrumKit != b.IsDrumKit || a.Envelope != b.Envelope || a.Volume != b.Volume || a.Pan != b.Pan || a.Vibrato != b.Vibrato
			|| a.Zones.Count != bZones.Count)
			return false;
		for (int i = 0; i < a.Zones.Count; i++)
		{
			var za = a.Zones[i];
			var zb = bZones[i];
			if (za.Count != zb.Count) return false;
			foreach (var k in za.Keys)
			{
				if (!zb.ContainsKey(k)) return false;
				var va = za[k];
				var vb = zb[k];
				if (k.AsString() == "sample") { if (va.As<N64Sample>() != vb.As<N64Sample>()) return false; }
				else if (va.VariantType is Variant.Type.Int or Variant.Type.Float ? va.AsDouble() != vb.AsDouble() : !va.Equals(vb)) return false;
			}
		}
		return true;
	}
}
#endif
