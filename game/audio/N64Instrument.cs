using Godot;

namespace m3d3.Audio;

/// <summary>
/// An instrument of a sound bank: zones map key / velocity ranges to samples (with their
/// own root key, tuning, volume, pan) under one volume envelope. Drum kits are instruments
/// whose zones are single keys. Program / bank pick it from MIDI (General MIDI numbering).
/// </summary>
[GlobalClass, Tool]
public partial class N64Instrument : Resource
{
	[Export] public string Name = "instrument";
	/// <summary>MIDI program (0-127, General MIDI numbering).</summary>
	[Export] public int Program;
	/// <summary>MIDI bank (drum kits conventionally 128).</summary>
	[Export] public int Bank;
	[Export] public bool IsDrumKit;
	/// <summary>Zones: [{sample: N64Sample (from the bank), key_lo, key_hi, vel_lo, vel_hi,
	/// root_key (-1 = the sample's), tune_cents, volume (0-1), pan (-1..1)}].</summary>
	[Export] public Godot.Collections.Array<Godot.Collections.Dictionary> Zones = new();
	/// <summary>Volume envelope: attack, decay (seconds), sustain (0-1), release (seconds).</summary>
	[Export] public Vector4 Envelope = new(0.005f, 0.2f, 0.8f, 0.25f);
	[Export] public float Volume = 1f;
	[Export] public float Pan;
	/// <summary>Vibrato: depth (cents), rate (Hz), delay (seconds).</summary>
	[Export] public Vector3 Vibrato = new(0, 5.5f, 0.25f);

	/// <summary>The zone playing `key` at `velocity` (first match), or null.</summary>
	public Godot.Collections.Dictionary ZoneFor(int key, int velocity)
	{
		foreach (var z in Zones)
		{
			if (key >= Get(z, "key_lo", 0) && key <= Get(z, "key_hi", 127)
				&& velocity >= Get(z, "vel_lo", 0) && velocity <= Get(z, "vel_hi", 127))
				return z;
		}
		return null;
	}

	public static int Get(Godot.Collections.Dictionary z, string k, int def) =>
		z.ContainsKey(k) ? z[k].AsInt32() : def;

	public static float GetF(Godot.Collections.Dictionary z, string k, float def) =>
		z.ContainsKey(k) ? (float)z[k].AsDouble() : def;
}
