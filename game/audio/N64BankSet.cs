using System.Collections.Generic;
using Godot;

namespace m3d3.Audio;

/// <summary>
/// A bank set: the instruments of the instrument library (<see cref="N64Library"/>) that one
/// song or game area loads into sample RAM, like the N64's per-sequence banks (the ROM holds
/// every bank, a sequence names the one it needs). The set only references library
/// instruments (their files), so sets share instruments and processed samples instead of
/// copying them; its RAM is the sum of its DISTINCT samples (<see cref="StoredBytes"/>).
/// Programs are assigned per set (entries), so one instrument can sit on different programs
/// in different sets. The synth plays the set through <see cref="SoundBank"/>, an
/// N64SoundBank built from the entries (instrument copies carrying the set's programs, zones
/// shared with the library instruments).
/// Kind: Music sets are played by songs (N64MusicPlayer); Sfx sets hold sound effects, looked
/// up by instrument name (<see cref="FindByName"/>), loaded next to the area's music set.
/// </summary>
[GlobalClass, Tool]
public partial class N64BankSet : Resource
{
	public enum SetKind { Music, Sfx }

	/// <summary>Metadata on the copies in <see cref="SoundBank"/>: the library instrument's name.</summary>
	public const string NameMeta = "n64_name";

	[Export] public string Name = "set";
	[Export] public SetKind Kind = SetKind.Music;
	/// <summary>[{instrument: N64Instrument (a library file), program (0-127), bank (MIDI bank;
	/// drum kits conventionally 128), channel (CD64 song sets: the slot's MIDI channel 1-16,
	/// else 0)}]. Drum kits stay kits (played on channel 10, matched by program).</summary>
	[Export] public Godot.Collections.Array<Godot.Collections.Dictionary> Entries = new();

	private N64SoundBank _bank;
	private string _builtFor = "";

	/// <summary>The set as a sound bank for <see cref="N64Synth.Bank"/>: one instrument per
	/// entry (the library instrument with the entry's program / bank; zones and samples are
	/// the library's own), the distinct samples. Rebuilt when the entries change; instrument
	/// settings (envelope, volume, ...) are re-read from the library on every call, so edits
	/// in the editor play at once.</summary>
	public N64SoundBank SoundBank
	{
		get
		{
			string sig = Signature();
			if (_bank == null || sig != _builtFor)
				Rebuild(sig);
			else
				Sync();
			return _bank;
		}
	}

	/// <summary>Drops the built bank (the next <see cref="SoundBank"/> builds a new one).</summary>
	public void Invalidate() => _bank = null;

	private string Signature()
	{
		var b = new System.Text.StringBuilder();
		foreach (var e in Entries)
			b.Append(Ins(e)?.GetInstanceId() ?? 0).Append(':').Append(Prog(e)).Append(':').Append(BankOf(e)).Append(':').Append(Chan(e)).Append(';');
		return b.ToString();
	}

	private void Rebuild(string sig)
	{
		bool slots = false;
		foreach (var e in Entries)
			slots |= Chan(e) > 0;
		var bank = new N64SoundBank { Name = Name };
		foreach (var e in Entries)
		{
			var src = Ins(e);
			if (src == null)
				continue;
			var c = new N64Instrument();
			Copy(src, c);
			c.Program = Prog(e);
			c.Bank = BankOf(e);
			c.SetMeta(NameMeta, src.Name);
			// CD64 song sets: the editor lists slot instruments by channel (as song banks).
			if (slots)
				c.SetMeta("cd64_export", Name);
			if (Chan(e) > 0)
				c.SetMeta("cd64_channel", Chan(e));
			bank.Instruments.Add(c);
		}
		foreach (var s in DistinctSamples())
			bank.Samples.Add(s);
		_bank = bank;
		_builtFor = sig;
	}

	/// <summary>Re-reads the library instruments' settings into the built copies.</summary>
	private void Sync()
	{
		int i = 0;
		foreach (var e in Entries)
		{
			var src = Ins(e);
			if (src == null)
				continue;
			if (i < _bank.Instruments.Count)
				Copy(src, _bank.Instruments[i]);
			i++;
		}
	}

	private static void Copy(N64Instrument src, N64Instrument c)
	{
		c.Name = src.Name;
		c.IsDrumKit = src.IsDrumKit;
		c.Zones = src.Zones;
		c.Envelope = src.Envelope;
		c.Volume = src.Volume;
		c.Pan = src.Pan;
		c.Vibrato = src.Vibrato;
	}

	/// <summary>Decodes the set's samples (see <see cref="N64SoundBank.Prepare"/>).</summary>
	public void Prepare() => SoundBank.Prepare();

	/// <summary>The library instrument called `name` in this set, or null (sound effects).</summary>
	public N64Instrument FindByName(string name)
	{
		foreach (var e in Entries)
			if (Ins(e) is N64Instrument ins && ins.Name == name)
				return ins;
		return null;
	}

	/// <summary>The entry of the instrument called `name`, or null.</summary>
	public Godot.Collections.Dictionary EntryFor(string name)
	{
		foreach (var e in Entries)
			if (Ins(e) is N64Instrument ins && ins.Name == name)
				return e;
		return null;
	}

	/// <summary>The entry of `ins`, or null.</summary>
	public Godot.Collections.Dictionary EntryOf(N64Instrument ins)
	{
		foreach (var e in Entries)
			if (Ins(e) == ins)
				return e;
		return null;
	}

	public bool Has(N64Instrument ins) => EntryOf(ins) != null;

	/// <summary>Adds `ins` (a library instrument) and returns its entry; an instrument already
	/// in the set keeps its entry. program / bank &lt; 0 = assigned automatically: the
	/// instrument's own program and bank if no other entry of the same kind (melodic / kit)
	/// holds them, else the lowest free program of bank 0 (kits: bank 128), the next bank
	/// when that bank is full.</summary>
	public Godot.Collections.Dictionary Add(N64Instrument ins) => AddWith(ins, -1, -1, 0);

	/// <summary><see cref="Add"/> with the program / bank (&lt; 0 = automatic) and channel given.</summary>
	public Godot.Collections.Dictionary AddWith(N64Instrument ins, int program, int bank, int channel)
	{
		if (ins == null)
			return null;
		var have = EntryOf(ins);
		if (have != null)
			return have;
		if (program < 0 || bank < 0)
			(program, bank) = FreeProgram(ins);
		var e = new Godot.Collections.Dictionary { ["instrument"] = ins, ["program"] = program, ["bank"] = bank, ["channel"] = channel };
		Entries.Add(e);
		EmitChanged();
		return e;
	}

	/// <summary>Removes `ins`'s entry. Returns whether it was in the set.</summary>
	public bool Remove(N64Instrument ins)
	{
		var e = EntryOf(ins);
		if (e == null)
			return false;
		Entries.Remove(e);
		EmitChanged();
		return true;
	}

	/// <summary>The program / bank `ins` gets when added (see <see cref="Add"/>).</summary>
	public Vector2I FreeProgramFor(N64Instrument ins)
	{
		var (p, b) = FreeProgram(ins);
		return new Vector2I(p, b);
	}

	private (int program, int bank) FreeProgram(N64Instrument ins)
	{
		bool kit = ins.IsDrumKit;
		if (!Taken(kit, ins.Program, ins.Bank, null))
			return (ins.Program, ins.Bank);
		int b0 = kit ? 128 : 0;
		for (int b = b0; b < b0 + 128; b++)
			for (int p = 0; p < 128; p++)
				if (!Taken(kit, p, b, null))
					return (p, b);
		return (0, b0);
	}

	/// <summary>Whether another entry of the same kind plays on (program, bank). Kits are
	/// matched by program only (N64Synth on channel 10).</summary>
	public bool Taken(bool kit, int program, int bank, Godot.Collections.Dictionary except)
	{
		foreach (var e in Entries)
		{
			if (e == except || Ins(e) is not N64Instrument o || o.IsDrumKit != kit)
				continue;
			if (Prog(e) == program && (kit || BankOf(e) == bank))
				return true;
		}
		return false;
	}

	/// <summary>Entries sharing a program (the synth plays the first listed): "A / B (12:0)", ...</summary>
	public string[] Clashes()
	{
		var outL = new List<string>();
		for (int i = 0; i < Entries.Count; i++)
			for (int j = i + 1; j < Entries.Count; j++)
			{
				if (Ins(Entries[i]) is not N64Instrument a || Ins(Entries[j]) is not N64Instrument b || a.IsDrumKit != b.IsDrumKit)
					continue;
				if (Prog(Entries[i]) == Prog(Entries[j]) && (a.IsDrumKit || BankOf(Entries[i]) == BankOf(Entries[j])))
					outL.Add($"{a.Name} / {b.Name} ({(a.IsDrumKit ? "kit " : "")}{Prog(Entries[i])}{(a.IsDrumKit ? "" : $":{BankOf(Entries[i])}")})");
			}
		return outL.ToArray();
	}

	/// <summary>The samples the set's instruments play, each once.</summary>
	public Godot.Collections.Array<N64Sample> DistinctSamples()
	{
		var seen = new HashSet<N64Sample>();
		var outA = new Godot.Collections.Array<N64Sample>();
		foreach (var e in Entries)
			if (Ins(e) is N64Instrument ins)
				foreach (var z in ins.Zones)
					if (z.ContainsKey("sample") && z["sample"].As<N64Sample>() is N64Sample s && seen.Add(s))
						outA.Add(s);
		return outA;
	}

	/// <summary>Sample RAM of the set: its distinct samples (ADPCM + books), bytes.</summary>
	public int StoredBytes() => UnionBytes(new[] { this });

	/// <summary>Sample RAM of several sets loaded together: samples they share count once.</summary>
	public static int UnionBytes(IEnumerable<N64BankSet> sets)
	{
		var seen = new HashSet<N64Sample>();
		int n = 0;
		foreach (var set in sets)
			if (set != null)
				foreach (var s in set.DistinctSamples())
					if (seen.Add(s))
						n += s.StoredBytes();
		return n;
	}

	/// <summary><see cref="UnionBytes(IEnumerable{N64BankSet})"/> plus the samples of `banks`
	/// (their sample lists and zones: a legacy bank loads all of its samples).</summary>
	public static int UnionBytes(IEnumerable<N64BankSet> sets, IEnumerable<N64SoundBank> banks)
	{
		var seen = new HashSet<N64Sample>();
		int n = 0;
		void Count(N64Sample s)
		{
			if (s != null && seen.Add(s))
				n += s.StoredBytes();
		}
		foreach (var set in sets)
			if (set != null)
				foreach (var s in set.DistinctSamples())
					Count(s);
		foreach (var bank in banks)
		{
			if (bank == null)
				continue;
			foreach (var s in bank.Samples)
				Count(s);
			foreach (var ins in bank.Instruments)
				if (ins != null)
					foreach (var z in ins.Zones)
						if (z.ContainsKey("sample"))
							Count(z["sample"].As<N64Sample>());
		}
		return n;
	}

	public static N64Instrument Ins(Godot.Collections.Dictionary e) =>
		e != null && e.ContainsKey("instrument") ? e["instrument"].As<N64Instrument>() : null;

	public static int Prog(Godot.Collections.Dictionary e) => N64Instrument.Get(e, "program", 0);
	public static int BankOf(Godot.Collections.Dictionary e) => N64Instrument.Get(e, "bank", 0);
	public static int Chan(Godot.Collections.Dictionary e) => N64Instrument.Get(e, "channel", 0);
}
