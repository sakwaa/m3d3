using System;
using System.Collections.Generic;
using Godot;

namespace m3d3.Audio;

/// <summary>
/// N64-style software synth: up to <see cref="MaxVoices"/> sample voices (decoded 4-bit
/// ADPCM) mixed at 32 kHz like the N64's audio microcode: linear-interpolated pitch, the
/// instrument's linear ADSR envelope, vibrato, velocity, pan, and a small reverb on a send.
///
/// Two ways to play:
///  - MIDI-style channels (the sequencer): <see cref="NoteOn"/>, <see cref="NoteOff"/>,
///    <see cref="ProgramChange"/>, <see cref="ControlChange"/>, <see cref="PitchBend"/>.
///    Instruments come from <see cref="Bank"/> by (bank, program); channel 10 plays drum kits.
///  - Direct (sound effects, previews): <see cref="PlayNote"/> an instrument, then
///    <see cref="StopNote"/> / <see cref="FadeNote"/> its id; <see cref="SetNotePitch"/>,
///    <see cref="SetNoteVolume"/>, <see cref="SetNotePan"/> change it while it plays.
///    <see cref="N64SfxPlayer"/> plays sound effects by name on a synth of its own.
/// Songs play through attached <see cref="N64Sequence"/>s (see <see cref="N64MusicPlayer"/>),
/// stepped before every 1 ms mix block.
///
/// Output goes through an AudioStreamGenerator kept <see cref="Latency"/> seconds ahead
/// (mixed on the main thread each frame), so a note starts within about that time.
/// </summary>
[GlobalClass, Tool]
public partial class N64Synth : Node
{
	public const int OutputRate = 32000;
	public const int Channels = 16;
	public const int DrumChannel = 9;
	/// <summary>Pitch / vibrato are updated per block of this many frames (like the RSP's
	/// per-frame parameter updates).</summary>
	private const int Block = 32;

	public const int VoiceCapacity = 64;

	/// <summary>Instruments for the MIDI channels. Assigning a bank decodes its samples
	/// (<see cref="N64SoundBank.Prepare"/>) so no note-on decodes or allocates.</summary>
	[Export] public N64SoundBank Bank
	{
		get => _bank;
		set { _bank = value; value?.Prepare(); }
	}
	/// <summary>Polyphony (clamped to 1..<see cref="VoiceCapacity"/>). Lowering it fades the
	/// voices over the new limit out quickly (10 ms) instead of cutting them.</summary>
	[Export(PropertyHint.Range, "1,64")] public int MaxVoices = 24;
	[Export(PropertyHint.Range, "0,2,0.01")] public float MasterVolume = 0.7f;
	/// <summary>Seconds of audio mixed ahead: lower = notes start sooner, but a slow frame
	/// longer than this underruns (a click).</summary>
	[Export(PropertyHint.Range, "0.015,0.25,0.005")] public float Latency = 0.04f;
	[Export] public StringName AudioBus = "Master";
	/// <summary>Pitch bend range (semitones each way).</summary>
	[Export] public float PitchBendRange = 2f;
	/// <summary>Mod wheel at full: extra vibrato depth (cents).</summary>
	[Export] public float ModWheelDepth = 40f;

	[ExportGroup("Reverb")]
	[Export(PropertyHint.Range, "0,1,0.01")] public float ReverbLevel = 0.3f;
	[Export(PropertyHint.Range, "0,1,0.01")] public float RoomSize = 0.6f;
	[Export(PropertyHint.Range, "0,1,0.01")] public float Damping = 0.45f;
	/// <summary>Reverb send of direct (PlayNote) voices.</summary>
	[Export(PropertyHint.Range, "0,1,0.01")] public float DirectReverbSend = 0.25f;

	private AudioStreamPlayer _player;
	private AudioStreamGeneratorPlayback _playback;
	private int _capacity;
	private Vector2[] _buffer = new Vector2[OutputRate / 4];
	private float[] _send = new float[OutputRate / 4];
	private N64SoundBank _bank;
	/// <summary>All voices, allocated once; only the first <see cref="_voiceLimit"/> take new
	/// notes, the others can still be fading out after MaxVoices was lowered.</summary>
	private readonly Voice[] _voices = new Voice[VoiceCapacity];
	private int _voiceLimit;
	private readonly ChannelState[] _channels = new ChannelState[Channels];
	private readonly Reverb _reverb = new();
	private long _nextId = 1;
	private long _clock;
	private readonly List<N64Sequence> _sequences = new();
	/// <summary>Per-channel gain on top of MIDI volume (dynamic music layers).</summary>
	private readonly float[] _channelGain = { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 };
	/// <summary>Gain on the whole output (music and sound effects), on top of
	/// <see cref="MasterVolume"/>. Sequences never change it.</summary>
	public float OutputGain = 1f;
	/// <summary>Fade gain of the attached sequences (their product, 1 when none), applied to
	/// MIDI-channel voices only: a music fade doesn't fade sound effects.</summary>
	private float _sequenceGain = 1f;

	public N64Synth()
	{
		for (int i = 0; i < Channels; i++)
			_channels[i] = new ChannelState();
		for (int i = 0; i < VoiceCapacity; i++)
			_voices[i] = new Voice();
		ApplyVoiceLimit();
		ResetChannels();
	}

	public override void _Ready()
	{
		var gen = new AudioStreamGenerator { MixRate = OutputRate, BufferLength = 0.25f };
		_capacity = (int)(gen.BufferLength * OutputRate);
		_player = new AudioStreamPlayer { Stream = gen, Bus = AudioBus };
		AddChild(_player, false, InternalMode.Back);
		_player.Play();
		_playback = (AudioStreamGeneratorPlayback)_player.GetStreamPlayback();
	}

	public override void _Process(double delta) => Fill();

	/// <summary>Tops the output up to <see cref="Latency"/> seconds ahead.</summary>
	public void Fill()
	{
		if (_playback == null)
			return;
		int buffered = _capacity - _playback.GetFramesAvailable();
		int want = Math.Min((int)(Latency * OutputRate) - buffered, _playback.GetFramesAvailable());
		while (want > 0)
		{
			int n = Math.Min(want, _buffer.Length);
			var span = _buffer.AsSpan(0, n);
			Mix(span);
			_playback.PushBuffer(span);
			want -= n;
		}
	}

	// --- Direct play ---------------------------------------------------------------------------

	/// <summary>Plays `instrument` at `key` (MIDI note) and `velocity` (1-127): returns a voice
	/// id for <see cref="StopNote"/>, or 0 if no zone covers the key. Volume 0-1, pan -1..1.</summary>
	public long PlayNote(N64Instrument instrument, int key, int velocity, float volume = 1f, float pan = 0f)
	{
		var v = Start(instrument, key, velocity, -1);
		if (v == null)
			return 0;
		v.DirectVolume = volume;
		v.DirectPan = pan;
		v.Send = DirectReverbSend;
		return v.Id;
	}

	/// <summary>Releases a voice started by <see cref="PlayNote"/> (its envelope's release).</summary>
	public void StopNote(long id)
	{
		foreach (var v in _voices)
			if (v.Active && v.Id == id)
				v.Release();
	}

	public bool IsPlaying(long id) => Find(id) != null;

	/// <summary>Releases voice `id` over `seconds` (linear, from its current level) instead of
	/// its envelope's release; 0 cuts it at once. Sound effects' fade-outs.</summary>
	public void FadeNote(long id, float seconds) => Find(id)?.Release(Math.Max(seconds, 0f));

	/// <summary>Pitch offset of voice `id` in cents on top of its key (sound effects: a hum
	/// that bends). Takes effect from the next block (32 frames).</summary>
	public void SetNotePitch(long id, float cents)
	{
		var v = Find(id);
		if (v != null)
			v.BaseCents = v.NaturalCents + cents;
	}

	/// <summary>Volume (0-1+) of voice `id`, as given to <see cref="PlayNote"/>; from the next block.</summary>
	public void SetNoteVolume(long id, float volume)
	{
		var v = Find(id);
		if (v != null)
			v.DirectVolume = Math.Max(volume, 0f);
	}

	/// <summary>Pan (-1..1) of voice `id`, as given to <see cref="PlayNote"/>; from the next block.</summary>
	public void SetNotePan(long id, float pan)
	{
		var v = Find(id);
		if (v != null)
			v.DirectPan = Math.Clamp(pan, -1f, 1f);
	}

	/// <summary>Whether voice `id` is releasing (note off, fade-out) rather than holding.</summary>
	public bool IsReleasing(long id) => Find(id)?.Released ?? false;

	private Voice Find(long id)
	{
		if (id <= 0)
			return null;
		foreach (var v in _voices)
			if (v.Active && v.Id == id)
				return v;
		return null;
	}

	/// <summary>Voices sounding now (including releasing ones).</summary>
	public int ActiveVoices()
	{
		int n = 0;
		foreach (var v in _voices)
			if (v.Active) n++;
		return n;
	}

	public void AttachSequence(N64Sequence seq)
	{
		if (!_sequences.Contains(seq))
			_sequences.Add(seq);
	}

	public void DetachSequence(N64Sequence seq) => _sequences.Remove(seq);

	/// <summary>Channel gain (0-1) on top of its MIDI volume / expression: music layers.</summary>
	public void SetChannelGain(int channel, float gain) => _channelGain[channel & 15] = Math.Max(gain, 0f);

	public float GetChannelGain(int channel) => _channelGain[channel & 15];

	/// <summary>Lets every voice go (envelope release).</summary>
	public void ReleaseAll() => StopAll(false);

	/// <summary>Releases every voice; `hard` silences them at once.</summary>
	public void StopAll(bool hard = false)
	{
		foreach (var v in _voices)
		{
			if (!v.Active) continue;
			if (hard) v.Active = false;
			else v.Release();
		}
	}

	// --- MIDI-style channels -----------------------------------------------------------------

	public void NoteOn(int channel, int key, int velocity)
	{
		if (velocity <= 0)
		{
			NoteOff(channel, key);
			return;
		}
		var ch = _channels[channel & 15];
		var inst = FindInstrument(channel & 15, ch);
		if (inst == null)
			return;
		// Same key again on the channel: the old note lets go (quickly), like a real retrigger.
		foreach (var v in _voices)
			if (v.Active && v.Channel == (channel & 15) && v.Key == key && !v.Released)
				v.Release(0.01f);
		Start(inst, key, velocity, channel & 15);
	}

	public void NoteOff(int channel, int key)
	{
		var ch = _channels[channel & 15];
		foreach (var v in _voices)
		{
			if (!v.Active || v.Channel != (channel & 15) || v.Key != key || v.Released)
				continue;
			if (ch.Sustain)
				v.HeldByPedal = true;
			else
				v.Release();
		}
	}

	public void ProgramChange(int channel, int program) => _channels[channel & 15].Program = Math.Clamp(program, 0, 127);

	/// <summary>CC 0 bank, 1 mod wheel, 7 volume, 10 pan, 11 expression, 64 sustain, 91 reverb,
	/// 120 all sound off, 121 reset controllers, 123 all notes off.</summary>
	public void ControlChange(int channel, int controller, int value)
	{
		var ch = _channels[channel & 15];
		float f = Math.Clamp(value, 0, 127) / 127f;
		switch (controller)
		{
			case 0: ch.BankSelect = Math.Clamp(value, 0, 127); break;
			case 1: ch.Mod = f; break;
			case 7: ch.Volume = f; break;
			case 10: ch.Pan = Math.Clamp((Math.Clamp(value, 0, 127) - 64) / 63f, -1f, 1f); break;
			case 11: ch.Expression = f; break;
			case 64:
				ch.Sustain = value >= 64;
				if (!ch.Sustain)
					PedalUp(channel & 15);
				break;
			case 91: ch.Reverb = f; break;
			case 120:
				foreach (var v in _voices)
					if (v.Active && v.Channel == (channel & 15)) v.Active = false;
				break;
			case 121:
				// Sustain goes off: notes held only by the pedal let go, as on a pedal-up
				// (hosts send this when the transport stops).
				ch.ResetControllers();
				PedalUp(channel & 15);
				break;
			case 123:
				foreach (var v in _voices)
					if (v.Active && v.Channel == (channel & 15)) v.Release();
				break;
		}
	}

	/// <summary>Pitch bend, 14-bit (0-16383, 8192 = centre).</summary>
	public void PitchBend(int channel, int value) => _channels[channel & 15].Bend = (Math.Clamp(value, 0, 16383) - 8192) / 8192f;

	/// <summary>Back to General MIDI defaults (program 0, volume 100, pan centre, …). Notes
	/// held by the sustain pedal are released.</summary>
	public void ResetChannels()
	{
		for (int i = 0; i < Channels; i++)
		{
			var c = _channels[i];
			c.Program = 0;
			c.BankSelect = 0;
			c.ResetControllers();
			c.Volume = 100 / 127f;
			c.Pan = 0;
			c.Reverb = 40 / 127f;
			PedalUp(i);
		}
	}

	/// <summary>Releases the voices of `channel` that only the sustain pedal was holding.</summary>
	private void PedalUp(int channel)
	{
		foreach (var v in _voices)
			if (v.Active && v.Channel == channel && v.HeldByPedal)
				v.Release();
	}

	private N64Instrument FindInstrument(int channel, ChannelState ch)
	{
		if (Bank == null)
			return null;
		bool drums = channel == DrumChannel;
		N64Instrument byProgram = null;
		foreach (var ins in Bank.Instruments)
		{
			if (ins == null || ins.IsDrumKit != drums)
				continue;
			if (ins.Program == ch.Program && (drums || ins.Bank == ch.BankSelect))
				return ins;
			if (ins.Program == ch.Program)
				byProgram ??= ins;
		}
		if (byProgram != null)
			return byProgram;
		// Drum channel without a matching kit: the first kit (GM files often omit the program).
		if (drums)
			foreach (var ins in Bank.Instruments)
				if (ins != null && ins.IsDrumKit)
					return ins;
		return null;
	}

	// --- Voices --------------------------------------------------------------------------------

	private Voice Start(N64Instrument inst, int key, int velocity, int channel)
	{
		if (inst == null)
			return null;
		var z = inst.ZoneFor(key, Math.Clamp(velocity, 1, 127));
		if (z == null || !z.ContainsKey("sample"))
			return null;
		var smp = z["sample"].As<N64Sample>();
		if (smp == null || smp.SampleCount <= 0 || smp.SampleRate <= 0)
			return null;
		int root = N64Instrument.Get(z, "root_key", -1);
		if (inst.IsDrumKit && root < 0)
			root = N64Instrument.Get(z, "key_lo", key);
		if (root < 0)
			root = smp.RootKey;

		var v = Allocate();
		v.Active = true;
		v.Id = _nextId++;
		v.StartedAt = _clock;
		v.Channel = channel;
		v.Key = key;
		v.Pcm = smp.Pcm;
		v.Pos = 0;
		v.End = Math.Min(smp.SampleCount, v.Pcm.Length);
		// A negative loop start (bad data) loops from the beginning.
		v.LoopStart = Math.Max(smp.LoopStart, 0);
		v.Loop = smp.Loop && smp.LoopEnd > v.LoopStart + 1 && smp.LoopEnd <= v.End;
		v.LoopEnd = smp.LoopEnd;
		v.BaseCents = (key - root) * 100f - smp.TuneCents - N64Instrument.GetF(z, "tune_cents", 0f);
		v.NaturalCents = v.BaseCents;
		v.RateRatio = smp.SampleRate / (double)OutputRate;
		float vel = Math.Clamp(velocity, 1, 127) / 127f;
		v.Gain = vel * vel * N64Instrument.GetF(z, "volume", 1f) * inst.Volume;
		v.Pan = Math.Clamp(N64Instrument.GetF(z, "pan", 0f) + inst.Pan, -1f, 1f);
		v.DirectVolume = 1f;
		v.DirectPan = 0f;
		v.Send = 0f;
		v.Env = inst.Envelope;
		v.Vibrato = inst.Vibrato;
		v.VibPhase = 0;
		v.Age = 0;
		v.Released = false;
		v.HeldByPedal = false;
		v.Stage = v.Env.X > 0.0005f ? Stage.Attack : Stage.Decay;
		v.Level = v.Stage == Stage.Attack ? 0f : 1f;
		return v;
	}

	/// <summary>A free voice, else the quietest released one, else the quietest / oldest
	/// (among the first MaxVoices).</summary>
	private Voice Allocate()
	{
		ApplyVoiceLimit();
		Voice best = null;
		for (int i = 0; i < _voiceLimit; i++)
			if (!_voices[i].Active)
				return _voices[i];
		for (int i = 0; i < _voiceLimit; i++)
		{
			var v = _voices[i];
			if (best == null)
			{
				best = v;
				continue;
			}
			bool better = v.Released != best.Released ? v.Released
				: (Math.Abs(v.Level - best.Level) > 0.05f ? v.Level < best.Level : v.StartedAt < best.StartedAt);
			if (better)
				best = v;
		}
		return best;
	}

	/// <summary>Follows <see cref="MaxVoices"/> (clamped) when it changed: voices over a lowered
	/// limit fade out quickly instead of being cut.</summary>
	private void ApplyVoiceLimit()
	{
		int n = Math.Clamp(MaxVoices, 1, VoiceCapacity);
		if (n == _voiceLimit)
			return;
		for (int i = n; i < _voiceLimit; i++)
			if (_voices[i].Active)
				_voices[i].Release(0.01f);
		_voiceLimit = n;
	}

	// --- Mixing --------------------------------------------------------------------------------

	/// <summary>Mixes the next `output.Length` frames (stereo, 32 kHz). Public for offline
	/// renders and tests; <see cref="Fill"/> calls it for playback.</summary>
	public void Mix(Span<Vector2> output)
	{
		ApplyVoiceLimit();
		output.Clear();
		if (_send.Length < output.Length)
			_send = new float[output.Length];
		var send = _send.AsSpan(0, output.Length);
		send.Clear();
		for (int start = 0; start < output.Length; start += Block)
		{
			int n = Math.Min(Block, output.Length - start);
			float seqGain = 1f;
			for (int q = 0; q < _sequences.Count; q++)
			{
				_sequences[q].Step(this, n / (double)OutputRate);
				seqGain *= _sequences[q].Gain;
			}
			_sequenceGain = seqGain;
			foreach (var v in _voices)
				if (v.Active)
					MixVoice(v, output.Slice(start, n), send.Slice(start, n));
		}
		_reverb.Configure(RoomSize, Damping);
		float wet = ReverbLevel;
		float master = MasterVolume * OutputGain;
		for (int i = 0; i < output.Length; i++)
		{
			var r = _reverb.Process(send[i]);
			output[i] = new Vector2(
				Math.Clamp((output[i].X + r.X * wet) * master, -1f, 1f),
				Math.Clamp((output[i].Y + r.Y * wet) * master, -1f, 1f));
		}
		_clock += output.Length;
	}

	/// <summary>Renders `frames` frames offline (tests, WAV previews) and returns them.</summary>
	public Vector2[] Render(int frames)
	{
		var outBuf = new Vector2[Math.Max(frames, 0)];
		Mix(outBuf);
		return outBuf;
	}

	private void MixVoice(Voice v, Span<Vector2> output, Span<float> send)
	{
		float dt = 1f / OutputRate;
		ChannelState ch = v.Channel >= 0 ? _channels[v.Channel] : null;
		// Per-block parameters: pitch (bend, vibrato), gain, pan.
		float vibDepth = v.Vibrato.X + (ch != null ? ch.Mod * ModWheelDepth : 0f);
		float vib = 0f;
		if (vibDepth > 0f && v.Age >= v.Vibrato.Z)
		{
			float ramp = Math.Min(1f, (v.Age - v.Vibrato.Z) / 0.25f);
			vib = MathF.Sin(v.VibPhase) * vibDepth * ramp;
		}
		v.VibPhase += MathF.Tau * v.Vibrato.Y * output.Length * dt;
		v.VibPhase -= MathF.Tau * MathF.Floor(v.VibPhase / MathF.Tau);  // wrap: keeps float precision on long notes
		float cents = v.BaseCents + vib + (ch != null ? ch.Bend * PitchBendRange * 100f : 0f);
		double step = v.RateRatio * Math.Pow(2.0, cents / 1200.0);
		float gain = v.Gain * v.DirectVolume * (ch != null ? ch.Volume * ch.Expression * _channelGain[v.Channel] * _sequenceGain : 1f);
		float pan = Math.Clamp(v.Pan + v.DirectPan + (ch != null ? ch.Pan : 0f), -1f, 1f);
		float angle = (pan + 1f) * MathF.PI * 0.25f;
		float gl = MathF.Cos(angle) * gain * 1.41421f * 0.5f;
		float gr = MathF.Sin(angle) * gain * 1.41421f * 0.5f;
		float sendGain = (ch != null ? ch.Reverb : v.Send) * gain;

		var pcm = v.Pcm;
		for (int i = 0; i < output.Length; i++)
		{
			float env = v.NextEnvelope(dt);
			if (!v.Active)
				return;
			int p0 = (int)v.Pos;
			float frac = (float)(v.Pos - p0);
			int p1 = p0 + 1;
			if (v.Loop && p1 >= v.LoopEnd)
				p1 = v.LoopStart + (p1 - v.LoopEnd);
			float s0 = p0 < v.End ? pcm[p0] : 0f;
			float s1 = p1 < v.End ? pcm[p1] : 0f;
			float s = (s0 + (s1 - s0) * frac) * (1f / 32768f) * env;
			output[i] += new Vector2(s * gl, s * gr);
			send[i] += s * sendGain;
			v.Pos += step;
			if (v.Loop)
			{
				while (v.Pos >= v.LoopEnd)
					v.Pos -= v.LoopEnd - v.LoopStart;
			}
			else if (v.Pos >= v.End)
			{
				v.Active = false;
				return;
			}
		}
		v.Age += output.Length * dt;
	}

	private enum Stage { Attack, Decay, Sustain, Release }

	private sealed class Voice
	{
		public bool Active;
		public long Id;
		public long StartedAt;
		public int Channel;
		public int Key;
		public short[] Pcm;
		public double Pos;
		public int End;
		public bool Loop;
		public int LoopStart;
		public int LoopEnd;
		public float BaseCents;
		/// <summary>BaseCents without <see cref="SetNotePitch"/>'s offset.</summary>
		public float NaturalCents;
		public double RateRatio;
		public float Gain;
		public float Pan;
		public float DirectVolume;
		public float DirectPan;
		public float Send;
		public Vector4 Env;  // attack, decay, sustain, release
		public Vector3 Vibrato;  // depth (cents), rate (Hz), delay (s)
		public float VibPhase;
		public float Age;
		public bool Released;
		public bool HeldByPedal;
		public Stage Stage;
		public float Level;
		private float _releaseRate;

		/// <summary>Starts the release (from the current level, over the envelope's release
		/// time or `seconds`).</summary>
		public void Release(float seconds = -1f)
		{
			if (Released && seconds < 0f)
				return;
			Released = true;
			HeldByPedal = false;
			Stage = Stage.Release;
			float t = seconds >= 0f ? seconds : Env.W;
			_releaseRate = t > 0.0005f ? Math.Max(Level, 0.001f) / (t * OutputRate) : float.MaxValue;
		}

		/// <summary>Linear ADSR, one output frame.</summary>
		public float NextEnvelope(float dt)
		{
			switch (Stage)
			{
				case Stage.Attack:
					Level += dt / Math.Max(Env.X, 0.0005f);
					if (Level >= 1f)
					{
						Level = 1f;
						Stage = Stage.Decay;
					}
					break;
				case Stage.Decay:
					float sustain = Math.Clamp(Env.Z, 0f, 1f);
					if (Env.Y <= 0.0005f)
						Level = sustain;
					else
						Level -= (1f - sustain) * dt / Env.Y;
					if (Level <= sustain)
					{
						Level = sustain;
						Stage = Stage.Sustain;
					}
					break;
				case Stage.Sustain:
					if (Level <= 0.0001f)
						Active = false;
					break;
				case Stage.Release:
					Level -= _releaseRate;
					if (Level <= 0f)
					{
						Level = 0f;
						Active = false;
					}
					break;
			}
			return Level;
		}
	}

	private sealed class ChannelState
	{
		public int Program;
		public int BankSelect;
		public float Volume;
		public float Expression;
		public float Pan;
		public float Mod;
		public float Bend;
		public float Reverb;
		public bool Sustain;

		public void ResetControllers()
		{
			Expression = 1f;
			Mod = 0f;
			Bend = 0f;
			Sustain = false;
		}
	}

	/// <summary>Small Schroeder / Freeverb-style reverb (4 combs + 2 allpasses per side) at
	/// 32 kHz: mono send in, stereo out.</summary>
	private sealed class Reverb
	{
		private static readonly int[] CombTuning = { 1116, 1188, 1277, 1356 };
		private static readonly int[] AllpassTuning = { 556, 441 };
		private const int StereoSpread = 23;
		private readonly Comb[] _combL;
		private readonly Comb[] _combR;
		private readonly Allpass[] _apL;
		private readonly Allpass[] _apR;

		public Reverb()
		{
			float scale = OutputRate / 44100f;
			_combL = new Comb[CombTuning.Length];
			_combR = new Comb[CombTuning.Length];
			for (int i = 0; i < CombTuning.Length; i++)
			{
				_combL[i] = new Comb((int)(CombTuning[i] * scale));
				_combR[i] = new Comb((int)((CombTuning[i] + StereoSpread) * scale));
			}
			_apL = new Allpass[AllpassTuning.Length];
			_apR = new Allpass[AllpassTuning.Length];
			for (int i = 0; i < AllpassTuning.Length; i++)
			{
				_apL[i] = new Allpass((int)(AllpassTuning[i] * scale));
				_apR[i] = new Allpass((int)((AllpassTuning[i] + StereoSpread) * scale));
			}
		}

		public void Configure(float room, float damping)
		{
			float fb = 0.7f + Math.Clamp(room, 0f, 1f) * 0.28f;
			float damp = Math.Clamp(damping, 0f, 1f) * 0.4f;
			foreach (var c in _combL) { c.Feedback = fb; c.Damp = damp; }
			foreach (var c in _combR) { c.Feedback = fb; c.Damp = damp; }
		}

		public Vector2 Process(float input)
		{
			float x = input * 0.03f;
			float l = 0f, r = 0f;
			for (int i = 0; i < _combL.Length; i++)
			{
				l += _combL[i].Process(x);
				r += _combR[i].Process(x);
			}
			for (int i = 0; i < _apL.Length; i++)
			{
				l = _apL[i].Process(l);
				r = _apR[i].Process(r);
			}
			return new Vector2(l, r);
		}

		private sealed class Comb
		{
			private readonly float[] _buf;
			private int _i;
			private float _store;
			public float Feedback = 0.84f;
			public float Damp = 0.2f;

			public Comb(int size) => _buf = new float[Math.Max(size, 1)];

			public float Process(float input)
			{
				float output = _buf[_i];
				_store = output * (1f - Damp) + _store * Damp;
				_buf[_i] = input + _store * Feedback;
				if (++_i >= _buf.Length) _i = 0;
				return output;
			}
		}

		private sealed class Allpass
		{
			private readonly float[] _buf;
			private int _i;

			public Allpass(int size) => _buf = new float[Math.Max(size, 1)];

			public float Process(float input)
			{
				float b = _buf[_i];
				float output = -input + b;
				_buf[_i] = input + b * 0.5f;
				if (++_i >= _buf.Length) _i = 0;
				return output;
			}
		}
	}
}
