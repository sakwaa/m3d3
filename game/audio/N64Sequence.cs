using System;

namespace m3d3.Audio;

/// <summary>
/// Plays an <see cref="N64Song"/> into an <see cref="N64Synth"/>: the synth steps it before
/// each 1 ms mix block, so events land within a millisecond of their time. Handles the
/// loop (notes held over the loop end get their normal release; controllers / programs
/// return to their state at the loop start), seeking, speed and fades.
/// </summary>
public sealed class N64Sequence
{
	public N64Song Song { get; private set; }
	/// <summary>Seconds into the song.</summary>
	public double Position { get; private set; }
	public bool Playing { get; private set; }
	public bool Paused;
	/// <summary>Tempo multiplier (1 = as written).</summary>
	public double Speed = 1.0;
	/// <summary>Fade gain (0-1) applied to the synth's MIDI-channel voices (not its sound effects).</summary>
	public float Gain { get; private set; } = 1f;
	/// <summary>Set when the song looped / ended; the owner clears them (signals).</summary>
	public bool LoopedFlag;
	public bool FinishedFlag;

	private int _index;
	private float _fadeTarget = 1f;
	private float _fadeRate;
	private bool _stopAfterFade;

	public void Start(N64Synth synth, N64Song song, double from = 0.0, float fadeIn = 0f)
	{
		Song = song;
		Playing = song != null;
		Paused = false;
		Gain = fadeIn > 0f ? 0f : 1f;
		FadeTo(1f, fadeIn);
		Seek(synth, from);
	}

	/// <summary>Stops (after a fade of `fadeOut` seconds); held notes are released.</summary>
	public void Stop(N64Synth synth, float fadeOut = 0f)
	{
		if (fadeOut > 0f && Playing)
		{
			FadeTo(0f, fadeOut);
			_stopAfterFade = true;
			return;
		}
		Playing = false;
		_stopAfterFade = false;
		synth.StopAll();
	}

	public void FadeTo(float target, float seconds)
	{
		_fadeTarget = Math.Clamp(target, 0f, 1f);
		_fadeRate = seconds > 0f ? Math.Abs(_fadeTarget - Gain) / seconds : float.MaxValue;
		_stopAfterFade = false;
	}

	/// <summary>Jumps to `seconds`: notes stop, controllers / programs are replayed up to there.</summary>
	public void Seek(N64Synth synth, double seconds)
	{
		synth.StopAll();
		synth.ResetChannels();
		Position = 0;
		_index = 0;
		if (Song == null)
			return;
		Position = Math.Clamp(seconds, 0, Song.Length);
		ReplayState(synth, Position);
	}

	/// <summary>Advances `seconds` of real time (the synth calls this before each mix block).</summary>
	public void Step(N64Synth synth, double seconds)
	{
		if (_fadeRate > 0f && Gain != _fadeTarget)
		{
			float d = (float)Math.Min(_fadeRate * seconds, 1.0);
			Gain = Gain < _fadeTarget ? Math.Min(Gain + d, _fadeTarget) : Math.Max(Gain - d, _fadeTarget);
		}
		// Also when the gain was already there (a fade-out stop while silent).
		if (_stopAfterFade && Gain == _fadeTarget)
		{
			_stopAfterFade = false;
			Playing = false;
			synth.StopAll(true);
		}
		if (!Playing || Paused || Song == null)
			return;
		double target = Position + seconds * Speed;
		var times = Song.Times;
		var events = Song.Events;
		int count = Song.EventCount;
		if (Song.Loops)
		{
			double end = Song.EffectiveLoopEnd;
			while (target >= end)
			{
				// Everything up to the loop end (but not notes starting right on it: they
				// belong to the next pass, at the loop start).
				while (_index < count && times[_index] <= end)
				{
					if (!(times[_index] >= end - 1e-6 && N64Song.Type(events[_index]) == N64Song.NoteOn))
						Dispatch(synth, events[_index]);
					_index++;
				}
				synth.ReleaseAll();
				double over = target - end;
				Position = Song.LoopStart;
				synth.ResetChannels();
				ReplayState(synth, Position);
				target = Position + over;
				LoopedFlag = true;
				if (end - Song.LoopStart < 1e-4)
					break;
			}
		}
		while (_index < count && times[_index] <= target)
			Dispatch(synth, events[_index++]);
		Position = target;
		if (!Song.Loops && _index >= count && Position >= Song.Length)
		{
			Playing = false;
			FinishedFlag = true;
			synth.ReleaseAll();
		}
	}

	/// <summary>Controllers, programs and pitch bends before `seconds` (no notes); puts
	/// the read index at the first event at / after it.</summary>
	private void ReplayState(N64Synth synth, double seconds)
	{
		var times = Song.Times;
		var events = Song.Events;
		int count = Song.EventCount;
		_index = 0;
		while (_index < count && times[_index] < seconds - 1e-9)
		{
			int t = N64Song.Type(events[_index]);
			if (t != N64Song.NoteOn && t != N64Song.NoteOff)
				Dispatch(synth, events[_index]);
			_index++;
		}
	}

	private static void Dispatch(N64Synth synth, int e)
	{
		int ch = N64Song.Channel(e);
		switch (N64Song.Type(e))
		{
			case N64Song.NoteOn: synth.NoteOn(ch, N64Song.Data1(e), N64Song.Data2(e)); break;
			case N64Song.NoteOff: synth.NoteOff(ch, N64Song.Data1(e)); break;
			case N64Song.Controller: synth.ControlChange(ch, N64Song.Data1(e), N64Song.Data2(e)); break;
			case N64Song.Program: synth.ProgramChange(ch, N64Song.Data1(e)); break;
			case N64Song.Bend: synth.PitchBend(ch, N64Song.Data2(e)); break;
		}
	}
}
