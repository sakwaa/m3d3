using System;
using Godot;

namespace m3d3.Audio;

/// <summary>
/// A sequenced song, compiled ahead of time from MIDI (like the N64's sequence files):
/// timed channel events ready to play through an <see cref="N64Synth"/>, plus a loop.
/// Built in the editor (N64 Sounds > Songs) from MIDI files exported from a DAW, one per
/// part (Ableton exports a clip per file); the MIDI itself never ships.
/// </summary>
[GlobalClass, Tool]
public partial class N64Song : Resource
{
	public const int NoteOn = 1, NoteOff = 2, Controller = 3, Program = 4, Bend = 5;

	[Export] public string Name = "song";
	/// <summary>Bank the song is written for (null = the player's bank). Older songs; see BankSet.</summary>
	[Export] public N64SoundBank Bank;
	/// <summary>Bank set (library instruments) the song plays with; takes precedence over
	/// <see cref="Bank"/>. Parts name their instrument, the set gives its program.</summary>
	[Export] public N64BankSet BankSet;
	/// <summary>Event times, seconds (tempo changes already applied), ascending.</summary>
	[Export] public double[] Times = Array.Empty<double>();
	/// <summary>Packed events (see <see cref="Pack"/>), one per time.</summary>
	[Export] public int[] Events = Array.Empty<int>();
	/// <summary>Seconds.</summary>
	[Export] public double Length;
	/// <summary>Loop start, seconds (&lt; 0 = plays once).</summary>
	[Export] public double LoopStart = -1;
	/// <summary>Loop end, seconds (&lt; 0 = the end of the song).</summary>
	[Export] public double LoopEnd = -1;
	[Export(PropertyHint.Range, "0,2,0.01")] public float Volume = 1f;
	/// <summary>First tempo and time signature (bar display in the editor).</summary>
	[Export] public float Bpm = 120f;
	[Export] public int BeatsPerBar = 4;

	/// <summary>Authoring (stripped from exported builds): the parts: [{path, midi_track (-1
	/// = every track), channel (-1 = the file's), instrument (name of a library instrument of
	/// <see cref="BankSet"/>: its program / bank there win), program, bank, drums, volume
	/// (0-1), pan (-1..1), repeat (tile to the song's length), mute, mtime}].</summary>
	[Export] public Godot.Collections.Array<Godot.Collections.Dictionary> Tracks = new();
	/// <summary>Authoring: CC111 in the MIDI sets the loop start (RPG Maker convention).</summary>
	[Export] public bool LoopFromMidi = true;

	/// <summary>The bank the song plays with: its set's, else its bank (null = the player's).</summary>
	public N64SoundBank PlayBank => BankSet?.SoundBank ?? Bank;

	public int EventCount => Math.Min(Times.Length, Events.Length);

	public double EffectiveLoopEnd => LoopEnd >= 0 ? Math.Min(LoopEnd, Length) : Length;

	public bool Loops => LoopStart >= 0 && LoopStart < EffectiveLoopEnd - 0.001;

	/// <summary>type (4 bits) | channel (4) | data1 (8) | data2 (16: 0-127, or 14-bit bend).</summary>
	public static int Pack(int type, int channel, int d1, int d2) =>
		(type << 28) | ((channel & 15) << 24) | ((d1 & 0xFF) << 16) | (d2 & 0xFFFF);

	public static int Type(int e) => (e >> 28) & 15;
	public static int Channel(int e) => (e >> 24) & 15;
	public static int Data1(int e) => (e >> 16) & 0xFF;
	public static int Data2(int e) => e & 0xFFFF;
}
