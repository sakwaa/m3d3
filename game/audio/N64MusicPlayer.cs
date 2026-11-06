using Godot;

namespace m3d3.Audio;

/// <summary>
/// Plays <see cref="N64Song"/>s through its own <see cref="N64Synth"/> (the song's bank set or
/// bank, else <see cref="BankSet"/> / <see cref="Bank"/>): play / stop with fades, pause, seek, speed, per-channel gain (music
/// layers). Emits <see cref="SignalName.Looped"/> each loop and <see cref="SignalName.Finished"/>
/// when a non-looping song ends.
/// </summary>
[GlobalClass, Tool]
public partial class N64MusicPlayer : Node
{
	[Signal] public delegate void LoopedEventHandler();
	[Signal] public delegate void FinishedEventHandler();

	/// <summary>Bank for songs that don't name their own.</summary>
	[Export] public N64SoundBank Bank;
	/// <summary>Bank set for songs that don't name their own (before <see cref="Bank"/>).</summary>
	[Export] public N64BankSet BankSet;
	[Export] public N64Song Song;
	[Export] public bool Autoplay;
	[Export(PropertyHint.Range, "0,2,0.01")] public float Volume
	{
		get => _volume;
		set { _volume = value; if (_synth != null) _synth.MasterVolume = value; }
	}
	[Export(PropertyHint.Range, "0.25,4,0.01")] public double Speed
	{
		get => _seq.Speed;
		set => _seq.Speed = value;
	}
	[Export] public StringName AudioBus = "Master";
	[Export(PropertyHint.Range, "0.015,0.25,0.005")] public float Latency = 0.04f;
	[Export(PropertyHint.Range, "1,64")] public int MaxVoices = 24;

	private float _volume = 0.7f;
	private readonly N64Sequence _seq = new();
	private N64Synth _synth;

	/// <summary>The synth playing the music (reverb settings, channel gains, …).</summary>
	public N64Synth Synth => _synth;

	/// <summary>The bank in sample RAM: the playing (last played) song's, else the one the next
	/// song without its own would get (<see cref="BankSet"/>, <see cref="Bank"/>). Debugging /
	/// budgets: <see cref="N64AudioArea.LoadedBytes"/>.</summary>
	public N64SoundBank LoadedBank => _synth?.Bank ?? BankSet?.SoundBank ?? Bank;

	public override void _Ready()
	{
		_synth = new N64Synth { MasterVolume = _volume, AudioBus = AudioBus, Latency = Latency, MaxVoices = MaxVoices };
		AddChild(_synth, false, InternalMode.Back);
		_synth.AttachSequence(_seq);
		if (Autoplay && Song != null && !Engine.IsEditorHint())
			Play();
	}

	public override void _Process(double delta)
	{
		if (_seq.LoopedFlag)
		{
			_seq.LoopedFlag = false;
			EmitSignal(SignalName.Looped);
		}
		if (_seq.FinishedFlag)
		{
			_seq.FinishedFlag = false;
			EmitSignal(SignalName.Finished);
		}
	}

	/// <summary>Plays `song` (default: <see cref="Song"/>) from `from` seconds, fading in.</summary>
	public void Play(N64Song song = null, float fadeIn = 0f, double from = 0.0)
	{
		song ??= Song;
		if (song == null || _synth == null)
			return;
		Song = song;
		_synth.Bank = song.PlayBank ?? BankSet?.SoundBank ?? Bank;
		_synth.StopAll(true);
		_seq.Start(_synth, song, from, fadeIn);
	}

	public void Stop(float fadeOut = 0f) { if (_synth != null) _seq.Stop(_synth, fadeOut); }

	public void FadeTo(float gain, float seconds) => _seq.FadeTo(gain, seconds);

	public void SetPaused(bool paused)
	{
		_seq.Paused = paused;
		if (paused && _synth != null)
			_synth.ReleaseAll();
	}

	public bool IsPaused() => _seq.Paused;

	public bool IsPlaying() => _seq.Playing && !_seq.Paused;

	/// <summary>Seconds into the song.</summary>
	public double GetPosition() => _seq.Position;

	public void Seek(double seconds) { if (_synth != null) _seq.Seek(_synth, seconds); }

	/// <summary>Gain (0-1) of a MIDI channel on top of the song's own volumes.</summary>
	public void SetChannelGain(int channel, float gain) => _synth?.SetChannelGain(channel, gain);

	public float GetChannelGain(int channel) => _synth?.GetChannelGain(channel) ?? 1f;

	/// <summary>Renders `frames` frames of the playing song offline (tests, previews).</summary>
	public Vector2[] Render(int frames) => _synth?.Render(frames) ?? System.Array.Empty<Vector2>();
}
