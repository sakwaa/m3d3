using Godot;

namespace m3d3.Audio;

/// <summary>
/// One processed sample: mono, N64 sample rate, 4-bit ADPCM with its predictor book, loop
/// points. Built by the sound bank tools; decoded ahead of play when its bank is given to a
/// synth (<see cref="N64SoundBank.Prepare"/>).
/// </summary>
[GlobalClass, Tool]
public partial class N64Sample : Resource
{
	[Export] public string Name = "sample";
	[Export] public byte[] Adpcm = System.Array.Empty<byte>();
	/// <summary>Predictor book: pairs of Q11 coefficients (c1, c2), one pair per predictor.</summary>
	[Export] public int[] Book = System.Array.Empty<int>();
	[Export] public int SampleCount;
	[Export] public int SampleRate = 22050;
	[Export] public bool Loop;
	/// <summary>Loop runs from LoopStart up to (not including) LoopEnd.</summary>
	[Export] public int LoopStart;
	[Export] public int LoopEnd;
	/// <summary>MIDI note the sample was recorded at (zones can override).</summary>
	[Export] public int RootKey = 60;
	/// <summary>Fine tuning of the recording, cents.</summary>
	[Export] public float TuneCents;

	/// <summary>Authoring: the recording it was made from and the processing settings
	/// (re-processing in the editor). Cleared from exported builds.</summary>
	[Export] public string SourcePath = "";
	[Export] public Godot.Collections.Dictionary Settings = new();
	/// <summary>Authoring: content hash of the recording (library samples: with Settings, what
	/// tells processed samples apart; N64LibraryTools). Cleared from exported builds.</summary>
	[Export] public string SourceHash = "";

	private short[] _pcm;
	private readonly object _pcmLock = new();

	/// <summary>Decoded PCM (cached). Decodes on first use if <see cref="Decode"/> wasn't
	/// called; safe from any thread (one decode, under a lock).</summary>
	public short[] Pcm => System.Threading.Volatile.Read(ref _pcm) ?? Decode();

	/// <summary>Decodes now if needed (bank load / assignment, not mid-game) and returns the PCM.</summary>
	public short[] Decode()
	{
		lock (_pcmLock)
		{
			if (_pcm == null)
				System.Threading.Volatile.Write(ref _pcm, N64Adpcm.Decode(Adpcm, SampleCount, Book));
			return _pcm;
		}
	}

	/// <summary>Drops the decoded PCM (after editing the data). Voices already playing keep
	/// the old PCM.</summary>
	public void InvalidateCache()
	{
		lock (_pcmLock)
			_pcm = null;
	}

	/// <summary>Copies another sample's processed data (re-processing in place, so
	/// instruments referencing this sample see the update).</summary>
	public void CopyFrom(N64Sample o)
	{
		lock (_pcmLock)
		{
			Adpcm = o.Adpcm; Book = o.Book; SampleCount = o.SampleCount; SampleRate = o.SampleRate;
			Loop = o.Loop; LoopStart = o.LoopStart; LoopEnd = o.LoopEnd; RootKey = o.RootKey; TuneCents = o.TuneCents;
			_pcm = null;
		}
		EmitChanged();
	}

	/// <summary>Seconds of audio.</summary>
	public float Seconds() => SampleCount / (float)System.Math.Max(SampleRate, 1);

	/// <summary>Decoded PCM as little-endian 16-bit bytes (previews from GDScript).</summary>
	public byte[] PcmBytes()
	{
		var pcm = Pcm;
		var bytes = new byte[pcm.Length * 2];
		System.Buffer.BlockCopy(pcm, 0, bytes, 0, bytes.Length);
		return bytes;
	}

	/// <summary>Size in bytes as stored (what counts toward the bank budget).</summary>
	public int StoredBytes() => Adpcm.Length + Book.Length * 2;
}
