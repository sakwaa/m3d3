#if TOOLS
using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using Godot;

namespace m3d3.Audio.Tools;

/// <summary>
/// Editor-only import of a CD64 export (the CD64 Audio Unit plugin's SFZ folder + N64
/// sidecar `&lt;Name&gt;.n64bank.json`, format "cd64-n64bank" version 1) as an N64SoundBank.
/// ADPCM, books, loops and tuning are copied from the sidecar as they are (never
/// re-encoded), so the bank plays bit-for-bit what the plugin previewed. Each sample's
/// source recording is copied to res://audio/_source/&lt;bank&gt;/&lt;id&gt;.wav (ignored by Godot,
/// like textures/_source), so the workspace can re-process it like any recording.
/// Provenance: what an import adds is tagged with the sidecar's `name` (metadata
/// cd64_export; samples also keep their sidecar id in cd64_id), so one bank can hold
/// several exports (a song bank next to a set of effects, say) and hand-made content.
/// Re-importing an export updates only what carries its tag, in place: samples (matched
/// by id) and instruments (by name) are overwritten from the sidecar, tagged ones the
/// export no longer has are removed (samples with their recordings and zones), and
/// everything else in the bank is left as it is. Banks imported before tags: AdoptUntagged.
/// The sidecar's top-level "kind" (song / sfx / library) doesn't matter here: a legacy bank
/// takes any export as a plain bank. Imports into the instrument library: N64LibraryTools.
/// </summary>
[GlobalClass, Tool]
public partial class N64Cd64Importer : RefCounted
{
	public const string BankDir = "res://audio/banks";
	public const string SourceDir = "res://audio/_source";
	/// <summary>Metadata on imported samples / instruments: the export (sidecar `name`) they came from.</summary>
	public const string TagMeta = "cd64_export";
	/// <summary>Metadata on imported samples: their sidecar id.</summary>
	public const string IdMeta = "cd64_id";
	/// <summary>Metadata on instruments of a song bank (sidecar `"song": true`): the MIDI
	/// channel (1-16) of their slot, from the instrument's `channel`.</summary>
	public const string ChannelMeta = "cd64_channel";
	internal const string Suffix = ".n64bank.json";

	/// <summary>What the last Import did (for the output panel).</summary>
	public string Summary = "";

	/// <summary>The sidecar of an export: `path` itself, or the .n64bank.json in the folder
	/// `path` (the one named after the folder if there are several). "" if none.</summary>
	public string SidecarFor(string path)
	{
		string p = ProjectSettings.GlobalizePath(path ?? "");
		if (File.Exists(p)) return p.EndsWith(Suffix, StringComparison.OrdinalIgnoreCase) ? p : "";
		if (!Directory.Exists(p)) return "";
		var found = Directory.GetFiles(p, "*" + Suffix);
		if (found.Length == 1) return found[0];
		string named = Path.Combine(p, Path.GetFileName(p.TrimEnd('/', '\\')) + Suffix);
		return Array.IndexOf(found, named) >= 0 ? named : "";
	}

	/// <summary>The export's name: the sidecar's `name` (else its file name), which tags
	/// what it imports. "" if `path` has no sidecar.</summary>
	public string ExportName(string path)
	{
		string sidecar = SidecarFor(path);
		if (sidecar == "") return "";
		string name = "";
		try
		{
			using var doc = JsonDocument.Parse(File.ReadAllText(sidecar));
			name = Str(doc.RootElement, "name", "");
		}
		catch (Exception) { }
		return name != "" ? name : Path.GetFileName(sidecar)[..^Suffix.Length];
	}

	/// <summary>The bank an export imports into by default: res://audio/banks/&lt;name&gt;.res.
	/// "" if `path` has no sidecar.</summary>
	public string BankPathFor(string path)
	{
		string name = ExportName(path);
		return name == "" ? "" : $"{BankDir}/{FileStem(name)}.res";
	}

	/// <summary>The export a sample / instrument was imported from ("" = hand-made, or
	/// imported before tags).</summary>
	public static string TagOf(GodotObject o) => o != null && o.HasMeta(TagMeta) ? o.GetMeta(TagMeta).AsString() : "";

	/// <summary>Imports the export at `path` (folder or sidecar) into `bankPath` ("" = the
	/// default, BankPathFor), creating or updating that bank, and saves it. Nothing is
	/// written unless the whole sidecar checks out. Returns "" or an error message.</summary>
	public string Import(string path, string bankPath = "")
	{
		Summary = "";
		try
		{
			string sidecar = SidecarFor(path);
			if (sidecar == "") return $"no {Suffix} in {path}";
			if (string.IsNullOrEmpty(bankPath)) bankPath = BankPathFor(path);
			string folder = Path.GetDirectoryName(Path.GetFullPath(sidecar));
			using var doc = JsonDocument.Parse(File.ReadAllText(sidecar));
			var root = doc.RootElement;
			if (Str(root, "format", "") != "cd64-n64bank") return "not a CD64 sidecar (format isn't \"cd64-n64bank\")";
			if (Int(root, "version", 0) != 1) return $"unsupported sidecar version {Int(root, "version", 0)} (this importer reads 1)";
			string tag = Str(root, "name", "");
			if (tag == "") tag = Path.GetFileName(sidecar)[..^Suffix.Length];

			// Read and check everything first.
			var samplesIn = new List<SampleIn>();
			var ids = new HashSet<string>();
			foreach (var e in Arr(root, "samples")) samplesIn.Add(ReadSample(e, folder, ids));
			var instsIn = new List<InstIn>();
			bool song = Bool(root, "song", false) || Str(root, "kind", "") == "song";
			foreach (var e in Arr(root, "instruments")) instsIn.Add(ReadInstrument(e, ids, song));

			var bank = new N64SoundBank();
			bool update = ResourceLoader.Exists(bankPath);
			if (update)
			{
				bank = ResourceLoader.Load(bankPath) as N64SoundBank;
				if (bank == null) return $"{bankPath} exists and isn't a sound bank";
			}
			string stem = bankPath.GetFile().GetBaseName();
			string srcDir = $"{SourceDir}/{stem}";

			// What an earlier import of this export left (only that is replaced or removed).
			var earlier = new Dictionary<string, N64Sample>();  // id -> sample
			var earlierInst = new List<N64Instrument>();
			foreach (var s in bank.Samples)
				if (s != null && TagOf(s) == tag) earlier[s.GetMeta(IdMeta, "").AsString()] = s;
			foreach (var ins in bank.Instruments)
				if (ins != null && TagOf(ins) == tag) earlierInst.Add(ins);
			bool adopted = update && earlier.Count == 0 && earlierInst.Count == 0 && bank.Name == tag
				&& AdoptUntagged(bank, srcDir, instsIn, earlier, earlierInst);

			// Recordings, for re-processing: <srcDir>/<id>.wav, or <srcDir>/<export>/<id>.wav
			// when another export (or the user) already has that file in this bank.
			var taken = new HashSet<string>();
			foreach (var s in bank.Samples)
				if (s != null && !earlier.ContainsValue(s)) taken.Add(s.SourcePath);
			var paths = new Dictionary<string, string>();
			foreach (var si in samplesIn)
			{
				string sp = $"{srcDir}/{si.Id}.wav";
				paths[si.Id] = taken.Contains(sp) ? $"{srcDir}/{FileStem(tag)}/{si.Id}.wav" : sp;
			}
			Directory.CreateDirectory(ProjectSettings.GlobalizePath(srcDir));
			string ignore = ProjectSettings.GlobalizePath($"{SourceDir}/.gdignore");
			if (!File.Exists(ignore)) File.WriteAllText(ignore, "");
			var warnings = new List<string>();
			foreach (var si in samplesIn)
			{
				string sp = paths[si.Id];
				Directory.CreateDirectory(ProjectSettings.GlobalizePath(sp.GetBaseDir()));
				File.Copy(si.Source, ProjectSettings.GlobalizePath(sp), true);
				string err = new N64AudioProcessor().LoadWav(sp);
				if (err != "") warnings.Add($"{si.Id}: source can't be re-processed ({err})");
			}

			// Samples: ones from an earlier import of this export are updated in place
			// (instruments and an open workspace keep pointing at them), new ones go last.
			var byId = new Dictionary<string, N64Sample>();
			var fresh = new List<N64Sample>();
			var unlink = new List<string>();  // recordings no longer used
			int added = 0, updated = 0;
			foreach (var si in samplesIn)
			{
				if (earlier.Remove(si.Id, out var s)) updated++;
				else { s = new N64Sample(); fresh.Add(s); added++; }
				if (s.SourcePath != "" && s.SourcePath != paths[si.Id]) unlink.Add(s.SourcePath);
				s.Name = si.Name; s.Adpcm = si.Adpcm; s.Book = si.Book; s.SampleCount = si.SampleCount;
				s.SampleRate = si.SampleRate; s.Loop = si.Loop; s.LoopStart = si.LoopStart; s.LoopEnd = si.LoopEnd;
				s.RootKey = si.RootKey; s.TuneCents = si.TuneCents; s.SourcePath = paths[si.Id]; s.Settings = si.Settings;
				s.SetMeta(TagMeta, tag);
				s.SetMeta(IdMeta, si.Id);
				s.InvalidateCache();
				s.EmitChanged();
				byId[si.Id] = s;
			}
			// This export's samples it no longer has: removed (with their recordings and zones).
			var removed = new HashSet<N64Sample>(earlier.Values);
			var samples = new Godot.Collections.Array<N64Sample>();
			foreach (var s in bank.Samples)
				if (s != null && !removed.Contains(s)) samples.Add(s);
			foreach (var s in fresh) samples.Add(s);
			foreach (var s in removed) unlink.Add(s.SourcePath);

			// Instruments: this export's matched by name and overwritten from the sidecar.
			var instruments = new Godot.Collections.Array<N64Instrument>();
			var instFresh = new List<N64Instrument>();
			int instAdded = 0, instUpdated = 0;
			foreach (var ii in instsIn)
			{
				var ins = earlierInst.Find(x => x.Name == ii.Name);
				if (ins != null) { earlierInst.Remove(ins); instUpdated++; }
				else { ins = new N64Instrument(); instFresh.Add(ins); instAdded++; }
				ins.Name = ii.Name; ins.Program = ii.Program; ins.Bank = ii.Bank; ins.IsDrumKit = ii.IsDrumKit;
				ins.Envelope = ii.Envelope; ins.Volume = ii.Volume; ins.Pan = ii.Pan; ins.Vibrato = ii.Vibrato;
				ins.SetMeta(TagMeta, tag);
				if (ii.Channel > 0) ins.SetMeta(ChannelMeta, ii.Channel);
				else if (ins.HasMeta(ChannelMeta)) ins.RemoveMeta(ChannelMeta);
				var zones = new Godot.Collections.Array<Godot.Collections.Dictionary>();
				foreach (var z in ii.Zones)
				{
					var d = z.Duplicate();
					d["sample"] = byId[z["sample"].AsString()];
					zones.Add(d);
				}
				ins.Zones = zones;
				ins.EmitChanged();
				// The synth plays the first zone a note / velocity falls in (N64Instrument.ZoneFor).
				for (int i = 0; i < ii.Zones.Count; i++)
					for (int j = i + 1; j < ii.Zones.Count; j++)
						if (Overlap(ii.Zones[i], ii.Zones[j], "key") && Overlap(ii.Zones[i], ii.Zones[j], "vel"))
						{
							warnings.Add($"{ii.Name}: zones {i} and {j} overlap, only zone {i} plays there");
							i = j = ii.Zones.Count;
						}
			}
			// This export's instruments it no longer has: removed.
			var instGone = new HashSet<N64Instrument>(earlierInst);
			foreach (var ins in bank.Instruments)
				if (ins != null && !instGone.Contains(ins)) instruments.Add(ins);
			foreach (var ins in instFresh) instruments.Add(ins);
			// Everything else is left alone, except zones playing a removed sample.
			var trimmed = new List<string>();
			int others = 0;
			foreach (var ins in instruments)
			{
				if (TagOf(ins) == tag) continue;
				others++;
				int before = ins.Zones.Count;
				for (int i = ins.Zones.Count - 1; i >= 0; i--)
					if (ins.Zones[i].ContainsKey("sample") && removed.Contains(ins.Zones[i]["sample"].As<N64Sample>()))
						ins.Zones.RemoveAt(i);
				if (ins.Zones.Count != before) { trimmed.Add(ins.Name); ins.EmitChanged(); }
			}
			// Two instruments on one program: the synth plays the one listed first.
			var clashes = new List<string>();
			foreach (var a in instruments)
				foreach (var b in instruments)
					if (TagOf(a) == tag && TagOf(b) != tag && a.IsDrumKit == b.IsDrumKit && a.Program == b.Program && (a.IsDrumKit || a.Bank == b.Bank))
						clashes.Add($"{a.Name} / {b.Name} ({(a.IsDrumKit ? "kit " : "")}{a.Program}{(a.IsDrumKit ? "" : $":{a.Bank}")})");
			if (clashes.Count > 0)
				warnings.Add($"{clashes.Count} program clash{(clashes.Count == 1 ? "" : "es")} with other instruments of the bank, the first listed plays: {string.Join(", ", clashes)}");

			if (!update) bank.Name = tag;
			bank.Samples = samples;
			bank.Instruments = instruments;
			Directory.CreateDirectory(ProjectSettings.GlobalizePath(bankPath.GetBaseDir()));
			var saved = ResourceSaver.Save(bank, bankPath);
			if (saved != Error.Ok) return $"saving {bankPath} failed ({saved})";
			bank.TakeOverPath(bankPath);
			// Recordings nothing plays any more (only in this bank's folder: a copy of the bank
			// saved elsewhere may still use the old one's).
			var used = new HashSet<string>();
			foreach (var s in samples) used.Add(s.SourcePath);
			foreach (var sp in unlink)
			{
				string f = ProjectSettings.GlobalizePath(sp);
				if (sp.StartsWith(srcDir + "/") && !used.Contains(sp) && File.Exists(f)) File.Delete(f);
			}

			Summary = $"{(update ? "Updated" : "Imported")} {tag} → {bankPath}: {samplesIn.Count} samples ({added} new, {updated} updated, {removed.Count} removed), "
				+ $"{instsIn.Count} instruments ({instAdded} new, {instUpdated} updated, {instGone.Count} removed)";
			if (adopted) Summary += "; took over the bank's untagged earlier import of it";
			int otherSamples = samples.Count - samplesIn.Count;
			if (otherSamples + others > 0) Summary += $"; left {otherSamples} samples, {others} instruments from other exports or made by hand";
			if (trimmed.Count > 0) Summary += $"; removed zones of dropped samples from {string.Join(", ", trimmed)}";
			if (warnings.Count > 0) Summary += "; " + string.Join("; ", warnings);
			return "";
		}
		catch (Exception e) { return e.Message; }
	}

	/// <summary>Banks imported before provenance tags carry none. An export re-imported
	/// into the bank it made (the bank still has the export's name, as that import set it)
	/// takes over the untagged samples whose recordings sit in the bank's import folder
	/// (&lt;srcDir&gt;/&lt;id&gt;.wav: only the importer writes there), and the untagged instruments
	/// named like one of its own that play only those samples. Anything else untagged counts
	/// as hand-made and is never touched. Returns whether it took over anything.</summary>
	static bool AdoptUntagged(N64SoundBank bank, string srcDir, List<InstIn> instsIn,
		Dictionary<string, N64Sample> samples, List<N64Instrument> instruments)
	{
		foreach (var s in bank.Samples)
			if (s != null && TagOf(s) == "" && s.SourcePath.GetBaseDir() == srcDir)
				samples[s.SourcePath.GetFile().GetBaseName()] = s;
		var names = new HashSet<string>();
		foreach (var ii in instsIn) names.Add(ii.Name);
		foreach (var ins in bank.Instruments)
		{
			if (ins == null || TagOf(ins) != "" || !names.Contains(ins.Name)) continue;
			bool own = true;
			foreach (var z in ins.Zones)
				own &= z.ContainsKey("sample") && samples.ContainsValue(z["sample"].As<N64Sample>());
			if (own) instruments.Add(ins);
		}
		return samples.Count + instruments.Count > 0;
	}

	// --- Sidecar ------------------------------------------------------------------------------

	internal class SampleIn
	{
		public string Id, Name, Source;
		public byte[] Adpcm;
		public int[] Book;
		public int SampleCount, SampleRate, LoopStart, LoopEnd, RootKey;
		public bool Loop;
		public float TuneCents;
		public Godot.Collections.Dictionary Settings;
	}

	internal class InstIn
	{
		public string Name, VariantOf;
		public int Program, Bank, Channel;  // Channel: song banks' slot (1-16), else 0
		public bool IsDrumKit;
		public Vector4 Envelope;
		public Vector3 Vibrato;
		public float Volume, Pan;
		public List<Godot.Collections.Dictionary> Zones = new();
	}

	internal static SampleIn ReadSample(JsonElement e, string folder, HashSet<string> ids)
	{
		string id = Need(Str(e, "id", ""), "a sample without an id");
		if (!SafeId(id)) throw new FormatException($"sample id \"{id}\" isn't [A-Za-z0-9_-]");
		if (!ids.Add(id)) throw new FormatException($"sample id \"{id}\" appears twice");
		var s = new SampleIn
		{
			Id = id, Name = Str(e, "name", id),
			Adpcm = File.ReadAllBytes(InExport(folder, Need(Str(e, "adpcm", ""), $"{id}: no adpcm"))),
			Source = InExport(folder, Need(Str(e, "source", ""), $"{id}: no source")),
			SampleCount = Int(e, "sample_count", -1), SampleRate = Int(e, "sample_rate", 0),
			Loop = Bool(e, "loop", false), LoopStart = Int(e, "loop_start", 0), LoopEnd = Int(e, "loop_end", 0),
			RootKey = Int(e, "root_key", 60), TuneCents = (float)Num(e, "tune_cents", 0),
			Settings = e.TryGetProperty("settings", out var st) && st.ValueKind == JsonValueKind.Object
				? ToVariant(st).AsGodotDictionary() : new Godot.Collections.Dictionary(),
		};
		var book = new List<int>();
		foreach (var c in Arr(e, "book"))
			book.Add(Whole(c, out int v) ? v : throw new FormatException($"{id}: book holds {c} (Q11 coefficients are integers)"));
		s.Book = book.ToArray();
		if (!File.Exists(s.Source)) throw new FormatException($"{id}: source recording missing ({Str(e, "source", "")})");
		if (s.SampleCount < 0 || s.SampleRate <= 0) throw new FormatException($"{id}: needs sample_count and sample_rate");
		if (s.Book.Length < 2 || s.Book.Length % 2 != 0) throw new FormatException($"{id}: book must be (c1, c2) pairs");
		if (s.Adpcm.Length < N64Adpcm.EncodedSize(s.SampleCount))
			throw new FormatException($"{id}: {s.Adpcm.Length} ADPCM bytes is short of {s.SampleCount} samples");
		// Every frame that decodes must name a predictor of the book.
		int frames = (s.SampleCount + N64Adpcm.FrameSamples - 1) / N64Adpcm.FrameSamples;
		for (int f = 0; f < frames; f++)
			if ((s.Adpcm[f * N64Adpcm.FrameBytes] & 0x0F) >= s.Book.Length / 2)
				throw new FormatException($"{id}: frame {f} uses predictor {s.Adpcm[f * N64Adpcm.FrameBytes] & 0x0F}, the book has {s.Book.Length / 2}");
		if (s.Loop && (s.LoopStart < 0 || s.LoopEnd <= s.LoopStart || s.LoopEnd > s.SampleCount))
			throw new FormatException($"{id}: loop {s.LoopStart}–{s.LoopEnd} is outside 0–{s.SampleCount}");
		return s;
	}

	internal static InstIn ReadInstrument(JsonElement e, HashSet<string> ids, bool song)
	{
		var env = Floats(e, "envelope", new[] { 0.005f, 0.2f, 0.8f, 0.25f });
		var vib = Floats(e, "vibrato", new[] { 0f, 5.5f, 0.25f });
		var ins = new InstIn
		{
			Name = Str(e, "name", "instrument"), Program = Int(e, "program", 0), Bank = Int(e, "bank", 0),
			IsDrumKit = Bool(e, "is_drum_kit", false), Volume = (float)Num(e, "volume", 1), Pan = (float)Num(e, "pan", 0),
			Envelope = new Vector4(env[0], env[1], env[2], env[3]), Vibrato = new Vector3(vib[0], vib[1], vib[2]),
			Channel = song ? Int(e, "channel", 0) : 0, VariantOf = Str(e, "variant_of", ""),
		};
		if (song && e.TryGetProperty("channel", out _) && ins.Channel is < 1 or > 16)
			throw new FormatException($"instrument {ins.Name}: channel {ins.Channel} isn't 1-16");
		foreach (var z in Arr(e, "zones"))
		{
			string id = Str(z, "sample", "");
			if (!ids.Contains(id)) throw new FormatException($"instrument {ins.Name}: zone plays unknown sample \"{id}\"");
			// Keys and types as the instrument editor writes them (N64Instrument.Zones).
			ins.Zones.Add(new Godot.Collections.Dictionary
			{
				["sample"] = id, ["key_lo"] = Int(z, "key_lo", 0), ["key_hi"] = Int(z, "key_hi", 127),
				["vel_lo"] = Int(z, "vel_lo", 0), ["vel_hi"] = Int(z, "vel_hi", 127), ["root_key"] = Int(z, "root_key", -1),
				["tune_cents"] = Num(z, "tune_cents", 0), ["volume"] = Num(z, "volume", 1), ["pan"] = Num(z, "pan", 0),
			});
		}
		return ins;
	}

	/// <summary>`rel` inside the export folder (sidecars are untrusted: no escaping it).</summary>
	static string InExport(string folder, string rel)
	{
		if (Path.IsPathRooted(rel)) throw new FormatException($"path {rel} isn't relative to the export");
		string full = Path.GetFullPath(Path.Combine(folder, rel));
		if (!full.StartsWith(folder.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar))
			throw new FormatException($"path {rel} leaves the export folder");
		return full;
	}

	internal static bool Overlap(Godot.Collections.Dictionary a, Godot.Collections.Dictionary b, string k) =>
		N64Instrument.Get(a, k + "_lo", 0) <= N64Instrument.Get(b, k + "_hi", 127)
		&& N64Instrument.Get(b, k + "_lo", 0) <= N64Instrument.Get(a, k + "_hi", 127);

	internal static bool SafeId(string s)
	{
		foreach (char c in s)
			if (!(c is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or >= '0' and <= '9' or '_' or '-')) return false;
		return s.Length > 0;
	}

	internal static string FileStem(string name)
	{
		var b = new System.Text.StringBuilder();
		foreach (char c in name.ToLowerInvariant()) b.Append(c is >= 'a' and <= 'z' or >= '0' and <= '9' or '-' ? c : '_');
		string s = b.ToString().Trim('_');
		while (s.Contains("__")) s = s.Replace("__", "_");
		return s.Length > 0 ? s : "cd64_bank";
	}

	static string Need(string v, string what) => v != "" ? v : throw new FormatException(what);

	internal static IEnumerable<JsonElement> Arr(JsonElement o, string k) =>
		o.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Array ? v.EnumerateArray() : Array.Empty<JsonElement>();

	internal static string Str(JsonElement o, string k, string def) =>
		o.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : def;

	static double Num(JsonElement o, string k, double def) =>
		o.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDouble() : def;

	internal static int Int(JsonElement o, string k, int def) =>
		o.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number ? (int)Math.Round(v.GetDouble()) : def;

	internal static bool Bool(JsonElement o, string k, bool def) =>
		o.TryGetProperty(k, out var v) && v.ValueKind is JsonValueKind.True or JsonValueKind.False ? v.GetBoolean() : def;

	static float[] Floats(JsonElement o, string k, float[] def)
	{
		var l = new List<float>();
		foreach (var v in Arr(o, k)) l.Add((float)v.GetDouble());
		return l.Count == def.Length ? l.ToArray() : def;
	}

	/// <summary>A JSON number with no fraction (3464 or 3464.0) as an int.</summary>
	static bool Whole(JsonElement v, out int i)
	{
		i = 0;
		if (v.ValueKind != JsonValueKind.Number) return false;
		double d = v.GetDouble();
		if (d != Math.Floor(d) || d < int.MinValue || d > int.MaxValue) return false;
		i = (int)d;
		return true;
	}

	/// <summary>JSON as Godot values; whole numbers become ints (settings like rate, bits).</summary>
	static Variant ToVariant(JsonElement v)
	{
		switch (v.ValueKind)
		{
			case JsonValueKind.String: return v.GetString();
			case JsonValueKind.Number:
				if (Whole(v, out int i)) return i;
				return v.GetDouble();
			case JsonValueKind.True: return true;
			case JsonValueKind.False: return false;
			case JsonValueKind.Array:
				var a = new Godot.Collections.Array();
				foreach (var x in v.EnumerateArray()) a.Add(ToVariant(x));
				return a;
			case JsonValueKind.Object:
				var d = new Godot.Collections.Dictionary();
				foreach (var p in v.EnumerateObject()) d[p.Name] = ToVariant(p.Value);
				return d;
			default: return default;
		}
	}
}
#endif
