using System.Collections.Generic;
using Godot;

namespace m3d3.Audio;

/// <summary>
/// Plays sound effects by name from loaded Sfx bank sets (<see cref="N64BankSet"/>, Kind Sfx)
/// on a synth of its own (<see cref="Synth"/>): its voices (<see cref="MaxVoices"/>) are a
/// separate pool from the music's (<see cref="N64MusicPlayer"/>), so a burst of effects steals
/// only effect voices, never music ones. Effects are library instruments looked up by name
/// across the loaded sets (the first set loaded wins when two hold the same name).
///   long h = sfx.Play("Warp hum", pitchSemitones: 2);  sfx.SetPitch(h, 5);  sfx.Stop(h, 0.3f);
/// A handle is the effect's voice id (0 = nothing played); it stops being playing when the
/// sound ends, is stopped, or its voice is stolen by a newer effect.
/// Positional sound: the caller works out volume and pan (distance, direction to the camera)
/// and passes them to <see cref="Play"/> / <see cref="SetVolume"/> / <see cref="SetPan"/>
/// each frame.
/// </summary>
[GlobalClass, Tool]
public partial class N64SfxPlayer : Node
{
	/// <summary>Sets loaded when the player is ready (more with <see cref="Load"/>).</summary>
	[Export] public Godot.Collections.Array<N64BankSet> Sets = new();
	[Export(PropertyHint.Range, "0,2,0.01")] public float Volume
	{
		get => _volume;
		set { _volume = value; if (_synth != null) _synth.MasterVolume = value; }
	}
	[Export] public StringName AudioBus = "Master";
	[Export(PropertyHint.Range, "0.015,0.25,0.005")] public float Latency = 0.04f;
	/// <summary>Voices for effects (their own pool): past it the quietest / oldest effect is stolen.</summary>
	[Export(PropertyHint.Range, "1,64")] public int MaxVoices
	{
		get => _maxVoices;
		set { _maxVoices = value; if (_synth != null) _synth.MaxVoices = value; }
	}
	/// <summary>Instances of one effect playing at once (0 = no limit): a new one stops the
	/// oldest. <see cref="Play"/>'s maxInstances overrides it per call.</summary>
	[Export(PropertyHint.Range, "0,64")] public int MaxInstances;
	/// <summary>Reverb send of effects (the synth's own reverb: see <see cref="Synth"/>).</summary>
	[Export(PropertyHint.Range, "0,1,0.01")] public float ReverbSend
	{
		get => _reverbSend;
		set { _reverbSend = value; if (_synth != null) _synth.DirectReverbSend = value; }
	}

	/// <summary>Fade of the oldest instance stopped by the instance limit, seconds.</summary>
	private const float StealFade = 0.01f;

	private float _volume = 0.7f;
	private int _maxVoices = 8;
	private float _reverbSend = 0.25f;
	private N64Synth _synth;
	private readonly List<N64BankSet> _loaded = new();
	private readonly Dictionary<StringName, (N64Instrument ins, N64BankSet set)> _byName = new();
	private bool _dirty = true;
	/// <summary>Effects started and still playing (or fading), oldest first.</summary>
	private readonly List<Instance> _instances = new();

	private struct Instance
	{
		public long Handle;
		public StringName Name;
		public N64BankSet Set;
		/// <summary>Stopped by the caller / the instance limit: fading, no longer counted.</summary>
		public bool Stopped;
	}

	/// <summary>The synth playing the effects (reverb settings, offline renders).</summary>
	public N64Synth Synth
	{
		get
		{
			EnsureSynth();
			return _synth;
		}
	}

	public override void _Ready()
	{
		EnsureSynth();
		if (_synth.GetParent() == null)
			AddChild(_synth, false, InternalMode.Back);
		foreach (var s in Sets)
			Load(s);
	}

	public override void _Process(double delta) => Prune();

	/// <summary>The synth exists before the node is in the tree too (offline renders, tests);
	/// it starts its audio output once added.</summary>
	private void EnsureSynth()
	{
		if (_synth != null)
			return;
		_synth = new N64Synth { MasterVolume = _volume, AudioBus = AudioBus, Latency = Latency, MaxVoices = _maxVoices, DirectReverbSend = _reverbSend };
		if (IsInsideTree())
			AddChild(_synth, false, InternalMode.Back);
	}

	// --- Sets ----------------------------------------------------------------------------------

	/// <summary>Loads `set` (decodes its samples now, not on the first play). Returns false if
	/// it was loaded already. Names another loaded set already has are warned about: the
	/// earlier set keeps them.</summary>
	public bool Load(N64BankSet set)
	{
		if (set == null || _loaded.Contains(set))
			return false;
		if (set.Kind != N64BankSet.SetKind.Sfx)
			GD.PushWarning($"N64SfxPlayer: \"{set.Name}\" is a music set; its instruments play as effects by name.");
		set.Prepare();
		Reindex();
		foreach (var e in set.Entries)
			if (N64BankSet.Ins(e) is N64Instrument ins && _byName.TryGetValue(ins.Name, out var have))
				GD.PushWarning($"N64SfxPlayer: \"{ins.Name}\" is in \"{have.set.Name}\" and \"{set.Name}\": \"{have.set.Name}\"'s plays.");
		_loaded.Add(set);
		if (!set.IsConnected(Resource.SignalName.Changed, OnSetChanged))
			set.Connect(Resource.SignalName.Changed, OnSetChanged);
		_dirty = true;
		return true;
	}

	/// <summary>Unloads `set`: its effects still playing are faded out quickly (their samples
	/// leave RAM). Returns whether it was loaded.</summary>
	public bool Unload(N64BankSet set)
	{
		if (set == null || !_loaded.Remove(set))
			return false;
		if (set.IsConnected(Resource.SignalName.Changed, OnSetChanged))
			set.Disconnect(Resource.SignalName.Changed, OnSetChanged);
		for (int i = _instances.Count - 1; i >= 0; i--)
			if (_instances[i].Set == set)
			{
				_synth?.FadeNote(_instances[i].Handle, StealFade);
				_instances.RemoveAt(i);
			}
		_dirty = true;
		return true;
	}

	/// <summary>Unloads every set.</summary>
	public void UnloadAll()
	{
		foreach (var s in _loaded.ToArray())
			Unload(s);
	}

	public bool IsLoaded(N64BankSet set) => set != null && _loaded.Contains(set);

	/// <summary>The loaded sets, in load order.</summary>
	public Godot.Collections.Array<N64BankSet> LoadedSets() => new(_loaded);

	/// <summary>Whether an effect called `name` is loaded.</summary>
	public bool Has(StringName name) => Lookup(name).ins != null;

	/// <summary>Names of the loaded effects.</summary>
	public string[] EffectNames()
	{
		Reindex();
		var outA = new string[_byName.Count];
		int i = 0;
		foreach (var k in _byName.Keys)
			outA[i++] = k;
		return outA;
	}

	/// <summary>Sample RAM of the loaded sets, bytes (samples they share once).</summary>
	public int LoadedBytes() => N64BankSet.UnionBytes(_loaded);

	private void MarkDirty() => _dirty = true;

	/// <summary>Re-indexes names when a loaded set's entries change (editor).</summary>
	private Callable OnSetChanged => _onSetChanged ??= Callable.From(MarkDirty);
	private Callable? _onSetChanged;

	private void Reindex()
	{
		if (!_dirty)
			return;
		_byName.Clear();
		foreach (var set in _loaded)
			foreach (var e in set.Entries)
				if (N64BankSet.Ins(e) is N64Instrument ins && !_byName.ContainsKey(ins.Name))
					_byName[ins.Name] = (ins, set);
		_dirty = false;
	}

	private (N64Instrument ins, N64BankSet set) Lookup(StringName name)
	{
		Reindex();
		return name != null && _byName.TryGetValue(name, out var r) ? r : (null, null);
	}

	// --- Playing -------------------------------------------------------------------------------

	/// <summary>Plays the effect called `name`: `pitchSemitones` above its natural key (or
	/// `key`, a MIDI note, when &gt;= 0), volume 0-1, pan -1..1. `maxInstances` (&gt; 0) caps
	/// how many of this effect play at once (a new one stops the oldest); -1 =
	/// <see cref="MaxInstances"/>, 0 = no limit. Returns a handle, 0 if nothing played (unknown
	/// name: warned; no zone at the key).</summary>
	public long Play(StringName name, float pitchSemitones = 0f, float volume = 1f, float pan = 0f, int key = -1, int maxInstances = -1)
	{
		var (ins, set) = Lookup(name);
		if (ins == null)
		{
			GD.PushWarning($"N64SfxPlayer: no sound effect \"{name}\" in the loaded sets.");
			return 0;
		}
		EnsureSynth();
		Prune();
		int limit = maxInstances >= 0 ? maxInstances : MaxInstances;
		if (limit > 0)
		{
			int n = 0;
			foreach (var it in _instances)
				if (!it.Stopped && it.Name == name)
					n++;
			for (int i = 0; i < _instances.Count && n >= limit; i++)
				if (!_instances[i].Stopped && _instances[i].Name == name)
				{
					_synth.FadeNote(_instances[i].Handle, StealFade);
					_instances.RemoveAt(i--);
					n--;
				}
		}
		long id = _synth.PlayNote(ins, key >= 0 ? key : NaturalKey(ins), 127, volume, pan);
		if (id == 0)
			return 0;
		if (pitchSemitones != 0f)
			_synth.SetNotePitch(id, pitchSemitones * 100f);
		_instances.Add(new Instance { Handle = id, Name = name, Set = set });
		return id;
	}

	/// <summary>Stops an effect: fades it out over `fadeOut` seconds (0 = at once, &lt; 0 = its
	/// instrument's own release).</summary>
	public void Stop(long handle, float fadeOut = 0f)
	{
		if (_synth == null || handle <= 0)
			return;
		if (fadeOut < 0f)
			_synth.StopNote(handle);
		else
			_synth.FadeNote(handle, fadeOut);
		MarkStopped(handle);
	}

	/// <summary>Stops every effect (see <see cref="Stop"/> for `fadeOut`).</summary>
	public void StopAll(float fadeOut = 0f)
	{
		foreach (var it in _instances.ToArray())
			Stop(it.Handle, fadeOut);
	}

	/// <summary>Whether the effect is still sounding (fading out included).</summary>
	public bool IsPlaying(long handle) => _synth != null && _synth.IsPlaying(handle);

	/// <summary>Pitch of a playing effect, semitones above the key it was started at.</summary>
	public void SetPitch(long handle, float semitones) => _synth?.SetNotePitch(handle, semitones * 100f);

	public void SetVolume(long handle, float volume) => _synth?.SetNoteVolume(handle, volume);

	public void SetPan(long handle, float pan) => _synth?.SetNotePan(handle, pan);

	/// <summary>Handles of the effects sounding now (fading ones included).</summary>
	public long[] Handles()
	{
		Prune();
		var outA = new long[_instances.Count];
		for (int i = 0; i < outA.Length; i++)
			outA[i] = _instances[i].Handle;
		return outA;
	}

	/// <summary>Instances of effect `name` playing now (null / empty: of every effect), not
	/// counting ones fading after a stop.</summary>
	public int PlayingCount(StringName name = null)
	{
		Prune();
		bool all = name == null || name.IsEmpty;
		int n = 0;
		foreach (var it in _instances)
			if (!it.Stopped && (all || it.Name == name))
				n++;
		return n;
	}

	/// <summary>Renders `frames` frames of the effects offline (tests, previews).</summary>
	public Vector2[] Render(int frames) => Synth.Render(frames);

	/// <summary>The key an effect plays at when none is given: its first zone's root key
	/// (kits: the zone's key), kept inside that zone's key range.</summary>
	public static int NaturalKey(N64Instrument ins)
	{
		if (ins == null || ins.Zones.Count == 0)
			return 60;
		var z = ins.Zones[0];
		int lo = N64Instrument.Get(z, "key_lo", 0), hi = Mathf.Max(N64Instrument.Get(z, "key_hi", 127), lo);
		if (ins.IsDrumKit)
			return lo;
		int root = N64Instrument.Get(z, "root_key", -1);
		if (root < 0 && z.ContainsKey("sample") && z["sample"].As<N64Sample>() is N64Sample s)
			root = s.RootKey;
		return Mathf.Clamp(root < 0 ? 60 : root, lo, hi);
	}

	private void MarkStopped(long handle)
	{
		for (int i = 0; i < _instances.Count; i++)
			if (_instances[i].Handle == handle)
			{
				var it = _instances[i];
				it.Stopped = true;
				_instances[i] = it;
			}
	}

	/// <summary>Forgets effects that ended (or whose voice was stolen).</summary>
	private void Prune()
	{
		if (_synth == null)
			return;
		for (int i = _instances.Count - 1; i >= 0; i--)
			if (!_synth.IsPlaying(_instances[i].Handle))
				_instances.RemoveAt(i);
	}
}
