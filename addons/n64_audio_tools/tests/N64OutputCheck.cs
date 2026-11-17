#if TOOLS
using System;
using System.IO;
using Godot;
using m3d3.Audio;
using m3d3.Audio.Tools;

namespace m3d3.Audio.Tests;

/// <summary>
/// Checks the N64 / Zelda64 output options of <see cref="N64Synth"/> on a generated instrument
/// (a bright sawtooth pluck, ADPCM-encoded like any library sample) and writes WAVs to listen
/// to: dry, each Zelda reverb preset, muffled, a channel filter, headphone stereo, the DAC
/// output stage. Prints measurements (tail energy, high-frequency energy, ear delay) and
/// FAIL lines. Run: tests/audio/output_check.gd.
/// </summary>
public partial class N64OutputCheck : RefCounted
{
	private const int Rate = N64Synth.OutputRate;
	private int _fails;

	public int Run(string outDir)
	{
		Directory.CreateDirectory(outDir);
		var bank = MakeBank();
		// Defaults: deterministic and the classic path (parity with the C++ port).
		var a = Phrase(Make(bank), 2.0f);
		var b = Phrase(Make(bank), 2.0f);
		Check(Same(a, b), "default render is deterministic");
		Write(outDir, "01_dry_classic", a);

		foreach (var preset in new[] { "outdoor", "room", "hall", "dungeon", "cave", "echo", "underwater" })
		{
			var s = Make(bank);
			Check(s.SetReverbPreset(preset), $"preset {preset} known");
			var o = Phrase(s, 3.0f);
			float tail = Energy(o, (int)(1.6f * Rate), o.Length);
			GD.Print($"reverb {preset,-10} tail energy {tail:F5}");
			Write(outDir, "02_reverb_" + preset, o);
		}
		var dungeon = Make(bank);
		dungeon.SetReverbPreset("dungeon");
		var none = Make(bank);
		none.SetReverbPreset("none");
		Check(Energy(Phrase(dungeon, 3f), (int)(1.6f * Rate), 3 * Rate) > 4 * Energy(Phrase(none, 3f), (int)(1.6f * Rate), 3 * Rate) + 1e-6f,
			"dungeon reverb rings after the notes, none doesn't");

		var muffled = Make(bank);
		muffled.SetOutputLowPass(700f);
		var m = Phrase(muffled, 2f);
		float hiDry = HighEnergy(a), hiMuf = HighEnergy(m);
		GD.Print($"high-frequency energy dry {hiDry:F5}, muffled {hiMuf:F5}");
		Check(hiMuf < hiDry * 0.2f, "output low-pass removes the highs");
		Write(outDir, "03_muffled_700hz", m);

		var chan = Make(bank);
		chan.SetChannelFilter(0, 1200f);
		Write(outDir, "04_channel_filter_1200hz", Phrase(chan, 2f));

		// Headphones: a hard-right note reaches the left (far) ear HaasMax samples later.
		var hp = Make(bank);
		hp.ReverbLevel = 0f;
		hp.Headphones = true;
		hp.ControlChange(0, 10, 100);  // (partly right: a hard pan leaves the far ear silent)
		hp.NoteOn(0, 60, 110);
		var h = hp.Render(Rate / 4);
		int onR = FirstAbove(h, false), onL = FirstAbove(h, true);
		int expect = (int)MathF.Round((100 - 64) / 63f * hp.HaasMax);
		GD.Print($"headphones: right ear starts at {onR}, left (far) ear at {onL} (expected delay {expect})");
		Check(onL - onR >= expect - 1, "far ear is delayed");
		var hp2 = Make(bank);
		hp2.Headphones = true;
		Write(outDir, "05_headphones_panned", PannedPhrase(hp2));
		var sp = Make(bank);
		Write(outDir, "05_speakers_panned", PannedPhrase(sp));

		// DAC stage at 48 kHz: 16-bit steps, near-identical level.
		var dac = Make(bank);
		dac.DacOutput = true;
		Play(dac);
		var d = dac.RenderOutput(48000, 48000 * 2);
		bool steps = true;
		foreach (var f in d)
			if (MathF.Abs(f.X * 32767f - MathF.Round(f.X * 32767f)) > 1e-3f) { steps = false; break; }
		Check(steps, "DAC output is 16-bit");
		GD.Print($"DAC 48k energy {Energy(d, 0, d.Length) * Rate / 48000f:F5} vs 32k dry {Energy(a, 0, a.Length):F5}");
		Write(outDir, "06_dac_48k", d, 48000);
		GD.Print(_fails == 0 ? "ALL PASS" : $"{_fails} FAIL");
		return _fails;
	}

	private static N64Synth Make(N64SoundBank bank) => new() { Bank = bank, DacOutput = false, MixThread = false };

	private static void Play(N64Synth s)
	{
		int[] keys = { 60, 64, 67, 72 };
		for (int i = 0; i < keys.Length; i++)
			s.NoteOn(0, keys[i], 110);
	}

	/// <summary>Four plucked notes 0.25 s apart, released at 1.2 s, rendered to `seconds`.</summary>
	private static Vector2[] Phrase(N64Synth s, float seconds)
	{
		var all = new Vector2[(int)(seconds * Rate)];
		int[] keys = { 60, 64, 67, 72 };
		int pos = 0;
		for (int i = 0; i < keys.Length; i++)
		{
			s.NoteOn(0, keys[i], 110);
			var chunk = s.Render(Rate / 4);
			chunk.CopyTo(all, pos);
			pos += chunk.Length;
		}
		var held = s.Render((int)(0.2f * Rate));
		held.CopyTo(all, pos);
		pos += held.Length;
		foreach (var k in keys)
			s.NoteOff(0, k);
		var rest = s.Render(all.Length - pos);
		rest.CopyTo(all, pos);
		return all;
	}

	private static Vector2[] PannedPhrase(N64Synth s)
	{
		var all = new System.Collections.Generic.List<Vector2>();
		foreach (int pan in new[] { 0, 127, 64, 0, 127 })
		{
			s.ControlChange(0, 10, pan);
			s.NoteOn(0, 67, 110);
			all.AddRange(s.Render(Rate / 3));
			s.NoteOff(0, 67);
		}
		all.AddRange(s.Render(Rate / 2));
		return all.ToArray();
	}

	public static N64SoundBank MakeBank()
	{
		// A bright plucked sawtooth (lots of highs to filter), 22.05 kHz, C4, looped.
		const int sr = 22050;
		int n = sr;
		var pcm = new short[n];
		double f = 261.63;
		for (int i = 0; i < n; i++)
		{
			double ph = (i * f / sr) % 1.0;
			double env = Math.Exp(-i / (sr * 0.35));
			pcm[i] = (short)((ph * 2 - 1) * env * 20000);
		}
		var (data, book) = N64AdpcmEncoder.Encode(pcm);
		var smp = new N64Sample { Name = "pluck", Adpcm = data, Book = book, SampleCount = n, SampleRate = sr, RootKey = 60 };
		var ins = new N64Instrument { Name = "pluck", Program = 0, Envelope = new Vector4(0.002f, 0.6f, 0.3f, 0.3f), Vibrato = Vector3.Zero };
		ins.Zones.Add(new Godot.Collections.Dictionary { { "sample", smp }, { "key_lo", 0 }, { "key_hi", 127 }, { "vel_lo", 1 }, { "vel_hi", 127 } });
		var bank = new N64SoundBank { Name = "check" };
		bank.Samples.Add(smp);
		bank.Instruments.Add(ins);
		return bank;
	}

	private void Check(bool ok, string what)
	{
		GD.Print((ok ? "ok   " : "FAIL ") + what);
		if (!ok) _fails++;
	}

	private static bool Same(Vector2[] a, Vector2[] b)
	{
		if (a.Length != b.Length) return false;
		for (int i = 0; i < a.Length; i++)
			if (a[i] != b[i]) return false;
		return true;
	}

	private static float Energy(Vector2[] a, int from, int to)
	{
		double e = 0;
		for (int i = Math.Max(from, 0); i < Math.Min(to, a.Length); i++)
			e += a[i].X * a[i].X + a[i].Y * a[i].Y;
		return (float)(e / Math.Max(to - from, 1));
	}

	/// <summary>Energy of the first difference (a crude high-pass).</summary>
	private static float HighEnergy(Vector2[] a)
	{
		double e = 0;
		for (int i = 1; i < a.Length; i++)
		{
			var d = a[i] - a[i - 1];
			e += d.X * d.X + d.Y * d.Y;
		}
		return (float)(e / a.Length);
	}

	private static int FirstAbove(Vector2[] a, bool left)
	{
		for (int i = 0; i < a.Length; i++)
			if (MathF.Abs(left ? a[i].X : a[i].Y) > 1e-4f)
				return i;
		return -1;
	}

	private static void Write(string dir, string name, Vector2[] frames, int rate = Rate)
	{
		using var fs = File.Create(Path.Combine(dir, name + ".wav"));
		using var w = new BinaryWriter(fs);
		int bytes = frames.Length * 4;
		w.Write("RIFF"u8.ToArray()); w.Write(36 + bytes); w.Write("WAVE"u8.ToArray());
		w.Write("fmt "u8.ToArray()); w.Write(16); w.Write((short)1); w.Write((short)2); w.Write(rate); w.Write(rate * 4); w.Write((short)4); w.Write((short)16);
		w.Write("data"u8.ToArray()); w.Write(bytes);
		foreach (var f in frames)
		{
			w.Write((short)Math.Clamp(f.X * 32767f, -32768f, 32767f));
			w.Write((short)Math.Clamp(f.Y * 32767f, -32768f, 32767f));
		}
	}
}
#endif
