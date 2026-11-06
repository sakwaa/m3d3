using System.Collections.Generic;
using System.Linq;
using Godot;

namespace m3d3.Audio;

/// <summary>
/// The bank sets a game area (a level, a zone) uses, to check its sample RAM against the
/// budget (Project Settings > n64/audio/bank_budget_kb) in N64 Sounds > Library > Areas.
/// Rule: the area's SFX sets are all loaded the whole time; of its music sets one is loaded
/// at a time (a song's set replaces the previous song's), so the worst case is the biggest
/// music set together with all SFX sets, samples they share counting once. Areas whose songs
/// overlap (crossfades, a jingle over the music) set <see cref="MusicOverlaps"/>: then every
/// music set counts at once. At run time <see cref="Apply"/> loads the area into a music
/// player and a sound-effect player (SFX play on their own voices, in parallel with the music);
/// <see cref="LoadedBytes"/> is what they hold now.
/// </summary>
[GlobalClass, Tool]
public partial class N64AudioArea : Resource
{
	[Export] public string Name = "area";
	[Export] public Godot.Collections.Array<N64BankSet> MusicSets = new();
	[Export] public Godot.Collections.Array<N64BankSet> SfxSets = new();
	/// <summary>Music sets can be loaded at the same time (all count, not just the biggest).</summary>
	[Export] public bool MusicOverlaps;

	/// <summary>Loads the area: `sfx` gets exactly the area's SFX sets (sets of another area
	/// are unloaded, their effects fade out), `music` the first music set as the set of songs
	/// that don't name their own (a playing song keeps playing). Every music set is decoded now,
	/// so starting one of the area's songs later doesn't. Either player may be null.</summary>
	public void Apply(N64MusicPlayer music, N64SfxPlayer sfx)
	{
		if (sfx != null)
		{
			foreach (var s in sfx.LoadedSets())
				if (!SfxSets.Contains(s))
					sfx.Unload(s);
			foreach (var s in SfxSets)
				sfx.Load(s);
		}
		if (music != null)
		{
			foreach (var s in MusicSets)
				s?.Prepare();
			foreach (var s in MusicSets)
				if (s != null)
				{
					music.BankSet = s;
					break;
				}
		}
	}

	/// <summary>Sample RAM the players hold now, bytes: the music's bank
	/// (<see cref="N64MusicPlayer.LoadedBank"/>) and the loaded SFX sets, samples they share
	/// once. Debugging: compare with <see cref="WorstCaseBytes"/>.</summary>
	public static int LoadedBytes(N64MusicPlayer music, N64SfxPlayer sfx) =>
		N64BankSet.UnionBytes(sfx != null ? sfx.LoadedSets() : new Godot.Collections.Array<N64BankSet>(),
			new[] { music?.LoadedBank });

	/// <summary>Worst-case sample RAM, bytes (see the class notes).</summary>
	public int WorstCaseBytes() => Budget()["total"].AsInt32();

	/// <summary>The area's sample RAM: {total (bytes, worst case), sfx (the SFX sets
	/// together), music_set (name of the music set of the worst case, "" if none; "all" when
	/// music overlaps), per_music: {set name: bytes of that set with the SFX sets}}.</summary>
	public Godot.Collections.Dictionary Budget()
	{
		var sfx = new List<N64BankSet>();
		foreach (var s in SfxSets)
			if (s != null) sfx.Add(s);
		var music = new List<N64BankSet>();
		foreach (var s in MusicSets)
			if (s != null) music.Add(s);
		var per = new Godot.Collections.Dictionary();
		int sfxBytes = N64BankSet.UnionBytes(sfx);
		int total = sfxBytes;
		string worst = "";
		if (MusicOverlaps && music.Count > 0)
		{
			total = N64BankSet.UnionBytes(sfx.Concat(music));
			worst = "all";
		}
		foreach (var m in music)
		{
			int n = N64BankSet.UnionBytes(sfx.Append(m));
			per[m.Name] = n;
			if (!MusicOverlaps && (worst == "" || n > total))
			{
				total = n;
				worst = m.Name;
			}
		}
		return new Godot.Collections.Dictionary
		{
			["total"] = total, ["sfx"] = sfxBytes, ["music_set"] = worst, ["per_music"] = per,
		};
	}
}
