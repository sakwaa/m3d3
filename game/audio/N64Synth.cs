using System;
using System.Collections.Generic;
using System.Threading;
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
/// Output goes through an AudioStreamGenerator kept <see cref="Latency"/> seconds ahead,
/// topped up by a mixing thread of its own (<see cref="MixThread"/>; off = on the main thread
/// each frame), so a slow game frame never starves the audio. Public calls are thread-safe
/// (they take <see cref="Sync"/>). Then the N64's output stage (<see cref="DacOutput"/>): the
/// 32 kHz samples held (zero-order hold, no smoothing) up to the device's rate, the analog
/// low-pass after the DAC, 16-bit.
///
/// N64 / Zelda64 options, all off by default so <see cref="Mix"/> stays bit-identical to the
/// CD64 plugin's C++ port (parity tests): the Zelda reverb (<see cref="ReverbModel"/>,
/// <see cref="SetReverbPreset"/>: OoT / MM's downsampled feedback delay with left / right
/// leak), channel and voice low-pass filters (MM's muffled channels; distant effects), an
/// output low-pass (underwater, behind walls) and OoT's headphone stereo (<see cref="Headphones"/>:
/// the far ear a little later and duller).
/// </summary>
[GlobalClass, Tool]
public partial class N64Synth : Node
{
	/// <summary>Group every synth joins (zones set reverb / muffling with call_group).</summary>
	public const string Group = "n64_synth";
	public enum ReverbKind { Classic, Zelda }
	/// <summary>Taken by every public call and by mixing: lock it to make several calls land in
	/// the same mix block (a sound effect's start and its pitch).</summary>
	public readonly object Sync = new();
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
		set
		{
			value?.Prepare();  // (decoding outside the lock: the mix thread keeps going)
			lock (Sync)
				_bank = value;
		}
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

	[ExportGroup("Output")]
	/// <summary>Mix on a thread of its own (off: on the main thread, each frame).</summary>
	[Export] public bool MixThread = true;
	/// <summary>The N64's output stage: zero-order hold to the device rate (no resampling
	/// filter: the DAC's images stay a little), the analog low-pass, 16-bit samples.</summary>
	[Export] public bool DacOutput = true;
	/// <summary>The analog low-pass after the DAC (Hz).</summary>
	[Export(PropertyHint.Range, "4000,20000,100")] public float DacCutoff = 14000f;
	/// <summary>Low-pass on the whole output (Hz, 0 = off): underwater, behind walls.</summary>
	[Export(PropertyHint.Range, "0,16000,10")] public float OutputLowPass = 0f;
	/// <summary>OoT's headphone stereo: a panned voice reaches the far ear up to
	/// <see cref="HaasMax"/> samples later and duller, so panning sounds wide on headphones.</summary>
	[Export] public bool Headphones = false;
	[Export(PropertyHint.Range, "0,32,1")] public int HaasMax = 16;

	[ExportGroup("Reverb")]
	/// <summary>Classic: a small Freeverb. Zelda: OoT / MM's reverb (see <see cref="SetReverbPreset"/>).</summary>
	[Export] public ReverbKind ReverbModel = ReverbKind.Classic;
	[Export(PropertyHint.Range, "0,1,0.01")] public float ReverbLevel = 0.3f;
	[Export(PropertyHint.Range, "0,1,0.01")] public float RoomSize = 0.6f;
	[Export(PropertyHint.Range, "0,1,0.01")] public float Damping = 0.45f;
	/// <summary>Reverb send of direct (PlayNote) voices.</summary>
	[Export(PropertyHint.Range, "0,1,0.01")] public float DirectReverbSend = 0.25f;
	/// <summary>Zelda reverb: delay (seconds), feedback decay, left / right leak, rate divider
	/// (2 = half rate, as the games ran it), low-pass on the feedback (0 bright .. 1 dark).</summary>
	[Export(PropertyHint.Range, "0.01,1,0.005")] public float ZeldaDelay = 0.12f;
	[Export(PropertyHint.Range, "0,0.95,0.01")] public float ZeldaDecay = 0.45f;
	[Export(PropertyHint.Range, "0,1,0.01")] public float ZeldaLeak = 0.3f;
	[Export(PropertyHint.Range, "1,4,1")] public int ZeldaDownsample = 2;
	[Export(PropertyHint.Range, "0,1,0.01")] public float ZeldaFilter = 0.4f;

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
	private readonly ZeldaReverb _zelda = new();
	private Vector2[] _sendStereo = new Vector2[OutputRate / 4];
	private float _outLpL, _outLpR, _outLp2L, _outLp2R;
	// Output stage / thread.
	private int _streamRate;
	private Vector2[] _src = new Vector2[256];
	private int _srcRead = 256;
	private Vector2 _hold;
	private double _dacPhase = 1.0;
	private Vector2 _dac1, _dac2;
	private Vector2[] _dev = new Vector2[4096];
	private Thread _thread;
	private volatile bool _running;
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
		AddToGroup(Group);
		lock (Sync)
			EnsureStream();
		if (MixThread)
		{
			_running = true;
			_thread = new Thread(MixLoop) { IsBackground = true, Name = "N64Synth mix", Priority = ThreadPriority.AboveNormal };
			_thread.Start();
		}
	}

	public override void _ExitTree()
	{
		_running = false;
		_thread?.Join(200);
		_thread = null;
	}

	public override void _Process(double delta)
	{
		// Stream setup is scene-tree work: main thread only. The mixing thread just pushes.
		int rate = DacOutput ? Math.Max((int)AudioServer.GetMixRate(), 8000) : OutputRate;
		if (rate != _streamRate)
			lock (Sync)
				EnsureStream();
		if (_playback == null && _player != null && _player.IsInsideTree())
		{
			if (!_player.Playing)
				_player.Play();
			var pb = _player.GetStreamPlayback() as AudioStreamGeneratorPlayback;
			lock (Sync)
				_playback = pb;
		}
		if (_thread == null)
			Fill();
	}

	private void MixLoop()
	{
		while (_running)
		{
			try
			{
				Fill();
			}
			catch (Exception e)
			{
				GD.PushError($"N64Synth mix thread: {e.Message}");
			}
			Thread.Sleep(2);
		}
	}

	/// <summary>A new output stream at the rate the output stage needs (device rate with the
	/// DAC stage, else 32 kHz for Godot to resample). Main thread.</summary>
	private void EnsureStream()
	{
		int rate = DacOutput ? Math.Max((int)AudioServer.GetMixRate(), 8000) : OutputRate;
		if (_player != null && rate == _streamRate)
			return;
		if (_player != null)
		{
			_player.Stop();
			_player.QueueFree();
		}
		_streamRate = rate;
		var gen = new AudioStreamGenerator { MixRate = rate, BufferLength = 0.25f };
		_capacity = (int)(gen.BufferLength * rate);
		_player = new AudioStreamPlayer { Stream = gen, Bus = AudioBus };
		AddChild(_player, false, InternalMode.Back);
		_playback = null;
	}

	/// <summary>Tops the output up to <see cref="Latency"/> seconds ahead (the mixing thread
	/// calls this; without it, _Process does). Pushing into the generator is thread-safe.</summary>
	public void Fill()
	{
		lock (Sync)
		{
			if (_playback == null)
				return;
			int free = _playback.GetFramesAvailable();
			int buffered = _capacity - free;
			int want = Math.Min((int)(Latency * _streamRate) - buffered, free);
			while (want > 0)
			{
				int n = Math.Min(want, DacOutput ? _dev.Length : _buffer.Length);
				Span<Vector2> span;
				if (DacOutput && _streamRate != OutputRate)
				{
					span = _dev.AsSpan(0, n);
					Dac(span);
				}
				else
				{
					span = _buffer.AsSpan(0, n);
					Mix(span);
				}
				_playback.PushBuffer(span);
				want -= n;
			}
		}
	}

	/// <summary>The N64 output stage into `output` (device rate): each 32 kHz sample held until
	/// the next (zero-order hold), a 2-pole analog low-pass, 16-bit.</summary>
	private void Dac(Span<Vector2> output)
	{
		double step = OutputRate / (double)_streamRate;
		float a = 1f - MathF.Exp(-MathF.Tau * Math.Clamp(DacCutoff, 1000f, _streamRate * 0.45f) / _streamRate);
		for (int i = 0; i < output.Length; i++)
		{
			_dacPhase += step;
			while (_dacPhase >= 1.0)
			{
				_dacPhase -= 1.0;
				if (_srcRead >= _src.Length)
				{
					Mix(_src);
					_srcRead = 0;
				}
				_hold = _src[_srcRead++];
			}
			_dac1 += (_hold - _dac1) * a;
			_dac2 += (_dac1 - _dac2) * a;
			output[i] = new Vector2(MathF.Round(_dac2.X * 32767f) / 32767f, MathF.Round(_dac2.Y * 32767f) / 32767f);
		}
	}

	// --- Direct play ---------------------------------------------------------------------------

	/// <summary>Plays `instrument` at `key` (MIDI note) and `velocity` (1-127): returns a voice
	/// id for <see cref="StopNote"/>, or 0 if no zone covers the key. Volume 0-1, pan -1..1.</summary>
	public long PlayNote(N64Instrument instrument, int key, int velocity, float volume = 1f, float pan = 0f)
	{
		lock (Sync)
		{
			var v = Start(instrument, key, velocity, -1);
			if (v == null)
				return 0;
			v.DirectVolume = volume;
			v.DirectPan = pan;
			v.Send = DirectReverbSend;
			return v.Id;
		}
	}

	/// <summary>Releases a voice started by <see cref="PlayNote"/> (its envelope's release).</summary>
	public void StopNote(long id)
	{
		lock (Sync)
		{
			foreach (var v in _voices)
				if (v.Active && v.Id == id)
					v.Release();
		}
	}

	public bool IsPlaying(long id) { lock (Sync) return Find(id) != null; }

	/// <summary>Releases voice `id` over `seconds` (linear, from its current level) instead of
	/// its envelope's release; 0 cuts it at once. Sound effects' fade-outs.</summary>
	public void FadeNote(long id, float seconds) { lock (Sync) Find(id)?.Release(Math.Max(seconds, 0f)); }

	/// <summary>Pitch offset of voice `id` in cents on top of its key (sound effects: a hum
	/// that bends). Takes effect from the next block (32 frames).</summary>
	public void SetNotePitch(long id, float cents)
	{
		lock (Sync)
		{
			var v = Find(id);
			if (v != null)
				v.BaseCents = v.NaturalCents + cents;
		}
	}

	/// <summary>Volume (0-1+) of voice `id`, as given to <see cref="PlayNote"/>; from the next block.</summary>
	public void SetNoteVolume(long id, float volume)
	{
		lock (Sync)
		{
			var v = Find(id);
			if (v != null)
				v.DirectVolume = Math.Max(volume, 0f);
		}
	}

	/// <summary>Pan (-1..1) of voice `id`, as given to <see cref="PlayNote"/>; from the next block.</summary>
	public void SetNotePan(long id, float pan)
	{
		lock (Sync)
		{
			var v = Find(id);
			if (v != null)
				v.DirectPan = Math.Clamp(pan, -1f, 1f);
		}
	}

	/// <summary>Whether voice `id` is releasing (note off, fade-out) rather than holding.</summary>
	public bool IsReleasing(long id) { lock (Sync) return Find(id)?.Released ?? false; }

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
		lock (Sync)
		{
			int n = 0;
			foreach (var v in _voices)
				if (v.Active) n++;
			return n;
		}
	}

	public void AttachSequence(N64Sequence seq)
	{
		lock (Sync)
		{
			if (!_sequences.Contains(seq))
				_sequences.Add(seq);
		}
	}

	public void DetachSequence(N64Sequence seq) { lock (Sync) _sequences.Remove(seq); }

	/// <summary>Channel gain (0-1) on top of its MIDI volume / expression: music layers.</summary>
	public void SetChannelGain(int channel, float gain) { lock (Sync) _channelGain[channel & 15] = Math.Max(gain, 0f); }

	public float GetChannelGain(int channel) => _channelGain[channel & 15];

	/// <summary>Lets every voice go (envelope release).</summary>
	public void ReleaseAll() => StopAll(false);

	/// <summary>Releases every voice; `hard` silences them at once.</summary>
	public void StopAll(bool hard = false)
	{
		lock (Sync)
		{
			foreach (var v in _voices)
			{
				if (!v.Active) continue;
				if (hard) v.Active = false;
				else v.Release();
			}
		}
	}

	// --- MIDI-style channels -----------------------------------------------------------------

	public void NoteOn(int channel, int key, int velocity)
	{
		lock (Sync)
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
	}

	public void NoteOff(int channel, int key)
	{
		lock (Sync)
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
	}

	public void ProgramChange(int channel, int program) { lock (Sync) _channels[channel & 15].Program = Math.Clamp(program, 0, 127); }

	/// <summary>CC 0 bank, 1 mod wheel, 7 volume, 10 pan, 11 expression, 64 sustain, 91 reverb,
	/// 120 all sound off, 121 reset controllers, 123 all notes off.</summary>
	public void ControlChange(int channel, int controller, int value)
	{
		lock (Sync)
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
	}

	/// <summary>Pitch bend, 14-bit (0-16383, 8192 = centre).</summary>
	public void PitchBend(int channel, int value) { lock (Sync) _channels[channel & 15].Bend = (Math.Clamp(value, 0, 16383) - 8192) / 8192f; }

	/// <summary>Back to General MIDI defaults (program 0, volume 100, pan centre, …). Notes
	/// held by the sustain pedal are released.</summary>
	public void ResetChannels()
	{
		lock (Sync)
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
		v.Cutoff = 0f;
		v.Z1 = v.Z2 = 0f;
		v.Shade = 0f;
		Array.Clear(v.Delay);
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
		lock (Sync)
			MixLocked(output);
	}

	private void MixLocked(Span<Vector2> output)
	{
		ApplyVoiceLimit();
		output.Clear();
		if (_send.Length < output.Length)
			_send = new float[output.Length];
		if (_sendStereo.Length < output.Length)
			_sendStereo = new Vector2[output.Length];
		var send = _send.AsSpan(0, output.Length);
		send.Clear();
		var sendS = _sendStereo.AsSpan(0, output.Length);
		sendS.Clear();
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
					MixVoice(v, output.Slice(start, n), send.Slice(start, n), sendS.Slice(start, n));
		}
		float wet = ReverbLevel;
		float master = MasterVolume * OutputGain;
		bool zelda = ReverbModel == ReverbKind.Zelda;
		if (zelda)
			_zelda.Configure(ZeldaDelay, ZeldaDecay, ZeldaLeak, ZeldaDownsample, ZeldaFilter);
		else
			_reverb.Configure(RoomSize, Damping);
		float olp = OutputLowPass > 0f ? 1f - MathF.Exp(-MathF.Tau * Math.Min(OutputLowPass, 15000f) / OutputRate) : 1f;
		for (int i = 0; i < output.Length; i++)
		{
			var r = zelda ? _zelda.Process(sendS[i]) : _reverb.Process(send[i]);
			float l = output[i].X + r.X * wet;
			float rr = output[i].Y + r.Y * wet;
			if (olp < 1f)
			{
				_outLpL += (l - _outLpL) * olp;
				_outLpR += (rr - _outLpR) * olp;
				_outLp2L += (_outLpL - _outLp2L) * olp;
				_outLp2R += (_outLpR - _outLp2R) * olp;
				l = _outLp2L;
				rr = _outLp2R;
			}
			output[i] = new Vector2(Math.Clamp(l * master, -1f, 1f), Math.Clamp(rr * master, -1f, 1f));
		}
		_clock += output.Length;
	}

	// --- N64 / Zelda64 options -----------------------------------------------------------------

	/// <summary>Zelda reverb presets (OoT / MM-like settings): "none", "outdoor", "room",
	/// "hall", "dungeon", "cave", "echo", "underwater". Switches <see cref="ReverbModel"/> to
	/// Zelda (except "classic"). Returns false for an unknown name.</summary>
	public bool SetReverbPreset(string name)
	{
		// delay s, decay, leak, downsample, filter, level
		float[] p = name switch
		{
			"none" => new[] { 0.05f, 0f, 0f, 2f, 0.4f, 0f },
			"outdoor" => new[] { 0.06f, 0.15f, 0.2f, 2f, 0.3f, 0.15f },
			"room" => new[] { 0.08f, 0.35f, 0.3f, 2f, 0.4f, 0.3f },
			"hall" => new[] { 0.18f, 0.55f, 0.35f, 2f, 0.4f, 0.35f },
			"dungeon" => new[] { 0.25f, 0.65f, 0.4f, 2f, 0.5f, 0.4f },
			"cave" => new[] { 0.3f, 0.72f, 0.45f, 2f, 0.7f, 0.45f },
			"echo" => new[] { 0.45f, 0.45f, 0.1f, 2f, 0.3f, 0.35f },
			"underwater" => new[] { 0.12f, 0.6f, 0.5f, 2f, 0.9f, 0.4f },
			_ => null,
		};
		lock (Sync)
		{
			if (name == "classic")
			{
				ReverbModel = ReverbKind.Classic;
				return true;
			}
			if (p == null)
				return false;
			ReverbModel = ReverbKind.Zelda;
			ZeldaDelay = p[0];
			ZeldaDecay = p[1];
			ZeldaLeak = p[2];
			ZeldaDownsample = (int)p[3];
			ZeldaFilter = p[4];
			ReverbLevel = p[5];
			return true;
		}
	}

	/// <summary>Low-pass on the whole output (Hz, 0 = off): muffled underwater / behind walls.</summary>
	public void SetOutputLowPass(float hz)
	{
		lock (Sync)
			OutputLowPass = Math.Max(hz, 0f);
	}

	/// <summary>Low-pass on MIDI channel `channel` (Hz, 0 = off): MM's channel filters (a music
	/// layer muffled, a muted part opening up).</summary>
	public void SetChannelFilter(int channel, float hz)
	{
		lock (Sync)
			_channels[channel & 15].Cutoff = Math.Max(hz, 0f);
	}

	public void SetHeadphones(bool on)
	{
		lock (Sync)
			Headphones = on;
	}

	/// <summary>Low-pass on voice `id` (Hz, 0 = off): distant sound effects.</summary>
	public void SetNoteFilter(long id, float hz)
	{
		lock (Sync)
		{
			var v = Find(id);
			if (v != null)
				v.Cutoff = Math.Max(hz, 0f);
		}
	}

	/// <summary>Reverb send (0-1) of voice `id` (distant effects ring more).</summary>
	public void SetNoteSend(long id, float send)
	{
		lock (Sync)
		{
			var v = Find(id);
			if (v != null)
				v.Send = Math.Max(send, 0f);
		}
	}

	/// <summary>Renders `frames` frames of the finished output at `deviceRate` offline: the
	/// N64 output stage (zero-order hold, analog low-pass, 16-bit) when <see cref="DacOutput"/>,
	/// else plain 32 kHz frames. WAV previews and tests.</summary>
	public Vector2[] RenderOutput(int deviceRate, int frames)
	{
		lock (Sync)
		{
			var outBuf = new Vector2[Math.Max(frames, 0)];
			if (!DacOutput)
			{
				MixLocked(outBuf);
				return outBuf;
			}
			int keep = _streamRate;
			_streamRate = Math.Max(deviceRate, 8000);
			Dac(outBuf);
			_streamRate = keep;
			return outBuf;
		}
	}

	/// <summary>Renders `frames` frames offline (tests, WAV previews) and returns them.</summary>
	public Vector2[] Render(int frames)
	{
		var outBuf = new Vector2[Math.Max(frames, 0)];
		Mix(outBuf);
		return outBuf;
	}

	private void MixVoice(Voice v, Span<Vector2> output, Span<float> send, Span<Vector2> sendS)
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
		float sendL = MathF.Cos(angle) * 1.41421f * 0.5f;
		float sendR = MathF.Sin(angle) * 1.41421f * 0.5f;
		// Low-pass: the voice's own (distant effects) or its channel's, whichever is lower.
		float cutoff = v.Cutoff;
		if (ch != null && ch.Cutoff > 0f)
			cutoff = cutoff > 0f ? Math.Min(cutoff, ch.Cutoff) : ch.Cutoff;
		float fa = cutoff > 0f && cutoff < 15000f ? 1f - MathF.Exp(-MathF.Tau * cutoff / OutputRate) : 1f;
		// Headphones: the far ear later (Haas) and a little duller (head shadow).
		int haas = Headphones ? (int)MathF.Round(Math.Abs(pan) * HaasMax) : 0;
		bool farLeft = pan > 0f;
		float shade = 1f - 0.5f * Math.Abs(pan);

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
			if (fa < 1f)
			{
				v.Z1 += (s - v.Z1) * fa;
				v.Z2 += (v.Z1 - v.Z2) * fa;
				s = v.Z2;
			}
			if (haas > 0)
			{
				v.Delay[v.DelayPos] = s;
				float late = v.Delay[(v.DelayPos - haas) & (Voice.DelaySize - 1)];
				v.DelayPos = (v.DelayPos + 1) & (Voice.DelaySize - 1);
				v.Shade += (late - v.Shade) * shade;
				if (farLeft)
					output[i] += new Vector2(v.Shade * gl, s * gr);
				else
					output[i] += new Vector2(s * gl, v.Shade * gr);
			}
			else
				output[i] += new Vector2(s * gl, s * gr);
			send[i] += s * sendGain;
			sendS[i] += new Vector2(s * sendGain * sendL, s * sendGain * sendR);
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
		public float Cutoff;
		public float Z1, Z2;
		public const int DelaySize = 64;
		public readonly float[] Delay = new float[DelaySize];
		public int DelayPos;
		public float Shade;
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
		/// <summary>Low-pass (Hz, 0 off): set by the game (SetChannelFilter), not by MIDI.</summary>
		public float Cutoff;

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

	/// <summary>Zelda64's reverb (OoT / MM, after the decomp's synthesis reverb): a stereo
	/// delay line run at a fraction of the rate (`downsample`: 2 = 16 kHz, the games' usual),
	/// fed back with `decay`, each side leaking into the other, a low-pass on the feedback.
	/// The wet signal is the delayed line held between its slow samples: the slightly gritty,
	/// echoey rooms and dungeons of the games, not a smooth modern tail.</summary>
	private sealed class ZeldaReverb
	{
		private readonly float[] _l = new float[OutputRate];
		private readonly float[] _r = new float[OutputRate];
		private int _len = 1, _pos, _down = 2, _phase;
		private float _decay, _leak, _filter;
		private Vector2 _acc, _hold, _lp;

		public void Configure(float delay, float decay, float leak, int down, float filter)
		{
			_down = Math.Clamp(down, 1, 4);
			int len = Math.Clamp((int)(delay * OutputRate / _down), 1, _l.Length);
			if (len != _len)
			{
				_len = len;
				_pos %= _len;
			}
			_decay = Math.Clamp(decay, 0f, 0.95f);
			_leak = Math.Clamp(leak, 0f, 1f);
			_filter = 1f - Math.Clamp(filter, 0f, 1f) * 0.85f;
		}

		public Vector2 Process(Vector2 input)
		{
			_acc += input;
			if (++_phase >= _down)
			{
				_phase = 0;
				Vector2 x = _acc / _down;
				_acc = Vector2.Zero;
				float dl = _l[_pos], dr = _r[_pos];
				var fb = new Vector2(dl + dr * _leak, dr + dl * _leak) / (1f + _leak);
				_lp += (fb - _lp) * _filter;
				_l[_pos] = x.X + _lp.X * _decay;
				_r[_pos] = x.Y + _lp.Y * _decay;
				_hold = new Vector2(dl, dr);
				if (++_pos >= _len)
					_pos = 0;
			}
			return _hold * 2.2f;
		}
	}
}
