using Godot;

namespace m3d3.Audio;

/// <summary>
/// A sound bank: processed samples + the instruments built from them (the N64's control
/// data + sample table in one file). Music and sound effects play through banks.
/// </summary>
[GlobalClass, Tool]
public partial class N64SoundBank : Resource
{
	[Export] public string Name = "bank";
	[Export] public Godot.Collections.Array<N64Sample> Samples = new();
	[Export] public Godot.Collections.Array<N64Instrument> Instruments = new();

	/// <summary>Decodes every sample (bank list and zones) so that playing a note never
	/// decodes. <see cref="N64Synth.Bank"/> calls it on assignment; call it again after
	/// editing samples in place.</summary>
	public void Prepare()
	{
		foreach (var s in Samples)
			s?.Decode();
		foreach (var ins in Instruments)
		{
			if (ins == null) continue;
			foreach (var z in ins.Zones)
				if (z.ContainsKey("sample") && z["sample"].As<N64Sample>() is N64Sample s)
					s.Decode();
		}
	}

	/// <summary>Bytes the samples take as stored (ADPCM + books).</summary>
	public int StoredBytes()
	{
		int n = 0;
		foreach (var s in Samples)
			if (s != null) n += s.StoredBytes();
		return n;
	}
}
