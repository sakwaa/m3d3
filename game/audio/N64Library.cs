using System.Collections.Generic;
using Godot;

namespace m3d3.Audio;

/// <summary>
/// The instrument library: every instrument and processed sample of the game, like the
/// N64 ROM's banks, from which bank sets (<see cref="N64BankSet"/>) pick what one song or
/// area loads into sample RAM. A folder (Project Settings > n64/audio/library_path, default
/// res://audio/library): instruments/*.tres and samples/*.tres, each its own file so bank sets
/// share them, sets/*.tres, areas/*.tres, _source/&lt;hash&gt;.wav (the full-rate recordings, once
/// each, ignored by Godot and never exported) and this index, library.tres.
/// Instruments are referenced by their unique Name (variants are separate entries:
/// "Strings", "Strings dark 11k"); a processed sample is identified by its recording's
/// content and its processing settings, so instruments asking for the same processing share
/// one sample file and different settings make separate samples (separate RAM).
/// Editing: N64 Sounds > Library (N64LibraryTools). Not needed by the game itself.
/// </summary>
[GlobalClass, Tool]
public partial class N64Library : N64SoundBank
{
	public const string PathSetting = "n64/audio/library_path";
	public const string DefaultPath = "res://audio/library";
	public const string IndexFile = "library.tres";

	/// <summary>The library folder (Project Settings > n64/audio/library_path).</summary>
	public static string Root()
	{
		string p = ProjectSettings.HasSetting(PathSetting) ? ProjectSettings.GetSetting(PathSetting).AsString() : "";
		return string.IsNullOrEmpty(p) ? DefaultPath : p.TrimEnd('/');
	}

	/// <summary>The instrument called `name`, or null.</summary>
	public N64Instrument FindInstrumentByName(string name)
	{
		foreach (var ins in Instruments)
			if (ins != null && ins.Name == name)
				return ins;
		return null;
	}

	/// <summary>The instruments playing `sample`.</summary>
	public Godot.Collections.Array<N64Instrument> UsersOf(N64Sample sample)
	{
		var outA = new Godot.Collections.Array<N64Instrument>();
		foreach (var ins in Instruments)
		{
			if (ins == null)
				continue;
			foreach (var z in ins.Zones)
				if (z.ContainsKey("sample") && z["sample"].As<N64Sample>() == sample)
				{
					outA.Add(ins);
					break;
				}
		}
		return outA;
	}

	/// <summary>`name`, or "name 2", "name 3", ... if an instrument (other than `except`) has it.</summary>
	public string UniqueName(string name, N64Instrument except = null)
	{
		var taken = new HashSet<string>();
		foreach (var ins in Instruments)
			if (ins != null && ins != except)
				taken.Add(ins.Name);
		if (!taken.Contains(name))
			return name;
		for (int i = 2; ; i++)
			if (!taken.Contains($"{name} {i}"))
				return $"{name} {i}";
	}
}
