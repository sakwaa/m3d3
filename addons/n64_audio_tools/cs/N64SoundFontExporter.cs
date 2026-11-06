#if TOOLS
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using Godot;

namespace m3d3.Audio.Tools;

/// <summary>
/// Editor-only export of a sound bank for composing in a DAW (sforzando / any SoundFont
/// player in Ableton): the N64-processed samples exactly as the game plays them (decoded
/// ADPCM at their low rates), with zones, loops, envelopes, vibrato.
///  - SF2: one file, a preset per instrument (drum kits in bank 128).
///  - SFZ: a folder: one .sfz per instrument + samples/*.wav.
/// </summary>
[GlobalClass, Tool]
public partial class N64SoundFontExporter : RefCounted
{
	// --- SF2 ------------------------------------------------------------------------------------

	/// <summary>Writes `bank` as an SF2. Returns "" or an error message.</summary>
	public string WriteSf2(N64SoundBank bank, string path)
	{
		try
		{
			var samples = new List<N64Sample>();
			foreach (var s in bank.Samples) if (s != null) samples.Add(s);
			var index = new Dictionary<N64Sample, int>();
			for (int i = 0; i < samples.Count; i++) index[samples[i]] = i;

			// Sample data: each sample + 46 zero samples (SF2 rule), offsets in samples.
			var smpl = new MemoryStream();
			var bw = new BinaryWriter(smpl);
			var starts = new List<uint>();
			foreach (var s in samples)
			{
				starts.Add((uint)(smpl.Length / 2));
				foreach (var v in s.Pcm) bw.Write(v);
				for (int k = 0; k < 46; k++) bw.Write((short)0);
			}

			var phdr = new MemoryStream(); var pbag = new MemoryStream(); var pgen = new MemoryStream();
			var inst = new MemoryStream(); var ibag = new MemoryStream(); var igen = new MemoryStream();
			var shdr = new MemoryStream();
			var phdrW = new BinaryWriter(phdr); var pbagW = new BinaryWriter(pbag); var pgenW = new BinaryWriter(pgen);
			var instW = new BinaryWriter(inst); var ibagW = new BinaryWriter(ibag); var igenW = new BinaryWriter(igen);
			var shdrW = new BinaryWriter(shdr);
			int pbagN = 0, pgenN = 0, ibagN = 0, igenN = 0, instN = 0;

			var instruments = new List<N64Instrument>();
			foreach (var ins in bank.Instruments) if (ins != null) instruments.Add(ins);
			foreach (var ins in instruments)
			{
				// Instrument: one bag per zone.
				Name(instW, ins.Name);
				instW.Write((ushort)ibagN);
				foreach (var z in ins.Zones)
				{
					var smp = z.ContainsKey("sample") ? z["sample"].As<N64Sample>() : null;
					if (smp == null || !index.ContainsKey(smp)) continue;
					ibagW.Write((ushort)igenN); ibagW.Write((ushort)0); ibagN++;
					void Gen(ushort op, short amount) { igenW.Write(op); igenW.Write(amount); igenN++; }
					void Range(ushort op, int lo, int hi) { igenW.Write(op); igenW.Write((byte)Math.Clamp(lo, 0, 127)); igenW.Write((byte)Math.Clamp(hi, 0, 127)); igenN++; }
					Range(43, N64Instrument.Get(z, "key_lo", 0), N64Instrument.Get(z, "key_hi", 127));
					Range(44, N64Instrument.Get(z, "vel_lo", 0), N64Instrument.Get(z, "vel_hi", 127));
					float vol = N64Instrument.GetF(z, "volume", 1f) * ins.Volume;
					Gen(48, (short)Math.Clamp(Math.Round(-200 * Math.Log10(Math.Max(vol, 1e-4))), 0, 1440));
					float pan = Math.Clamp(N64Instrument.GetF(z, "pan", 0f) + ins.Pan, -1f, 1f);
					Gen(17, (short)Math.Round(pan * 500));
					// Envelope (timecents; sustain as attenuation in cB).
					Gen(34, TimeCents(ins.Envelope.X));
					Gen(36, TimeCents(ins.Envelope.Y));
					Gen(37, (short)Math.Clamp(Math.Round(-200 * Math.Log10(Math.Max(ins.Envelope.Z, 1e-4))), 0, 1440));
					Gen(38, TimeCents(ins.Envelope.W));
					if (ins.Vibrato.X > 0)
					{
						Gen(6, (short)Math.Round(ins.Vibrato.X));
						Gen(24, (short)Math.Round(1200 * Math.Log2(Math.Max(ins.Vibrato.Y, 0.01) / 8.176)));
						Gen(23, TimeCents(ins.Vibrato.Z));
					}
					int root = N64Instrument.Get(z, "root_key", -1);
					if (ins.IsDrumKit && root < 0) root = N64Instrument.Get(z, "key_lo", 60);
					Gen(58, (short)(root >= 0 ? root : smp.RootKey));
					// Tuning: the sample's correction + the zone's, as coarse semitones + fine cents.
					double cents = smp.TuneCents + N64Instrument.GetF(z, "tune_cents", 0f);
					int coarse = (int)Math.Round(cents / 100.0);
					int fine = (int)Math.Round(cents - coarse * 100.0);
					if (coarse != 0) Gen(51, (short)coarse);
					if (fine != 0) Gen(52, (short)fine);
					if (smp.Loop) Gen(54, 1);
					Gen(53, (short)index[smp]);  // sampleID: must be last
				}
				instN++;
			}
			// Terminals: instrument list, its bag, its generators.
			Name(instW, "EOI"); instW.Write((ushort)ibagN);
			ibagW.Write((ushort)igenN); ibagW.Write((ushort)0);
			igenW.Write((uint)0);

			// Presets: one per instrument, one zone pointing at it.
			for (int i = 0; i < instruments.Count; i++)
			{
				var ins = instruments[i];
				Name(phdrW, ins.Name);
				phdrW.Write((ushort)Math.Clamp(ins.Program, 0, 127));
				phdrW.Write((ushort)(ins.IsDrumKit ? 128 : Math.Clamp(ins.Bank, 0, 127)));
				phdrW.Write((ushort)pbagN);
				phdrW.Write(0u); phdrW.Write(0u); phdrW.Write(0u);
				pbagW.Write((ushort)pgenN); pbagW.Write((ushort)0); pbagN++;
				pgenW.Write((ushort)41); pgenW.Write((ushort)i); pgenN++;
			}
			Name(phdrW, "EOP"); phdrW.Write((ushort)0); phdrW.Write((ushort)0); phdrW.Write((ushort)pbagN);
			phdrW.Write(0u); phdrW.Write(0u); phdrW.Write(0u);
			pbagW.Write((ushort)pgenN); pbagW.Write((ushort)0);
			pgenW.Write((uint)0);

			// Sample headers.
			for (int i = 0; i < samples.Count; i++)
			{
				var s = samples[i];
				uint st = starts[i];
				Name(shdrW, s.Name);
				shdrW.Write(st);
				shdrW.Write(st + (uint)s.SampleCount);
				uint ls = s.Loop ? st + (uint)s.LoopStart : st;
				uint le = s.Loop ? st + (uint)s.LoopEnd : st + (uint)Math.Max(s.SampleCount - 1, 0);
				shdrW.Write(ls);
				shdrW.Write(le);
				shdrW.Write((uint)s.SampleRate);
				shdrW.Write((byte)Math.Clamp(s.RootKey, 0, 127));
				shdrW.Write((sbyte)0);
				shdrW.Write((ushort)0);
				shdrW.Write((ushort)1);  // mono
			}
			Name(shdrW, "EOS");
			shdrW.Write(new byte[46 - 20]);

			var mod = new byte[10];  // no modulators: just the terminal record
			var info = List("INFO",
				Chunk("ifil", new byte[] { 2, 0, 1, 0 }),
				Chunk("isng", ZStr("EMU8000")),
				Chunk("INAM", ZStr(bank.Name)),
				Chunk("ISFT", ZStr("m3d3 N64 Sounds")));
			var sdta = List("sdta", Chunk("smpl", smpl.ToArray()));
			var pdta = List("pdta",
				Chunk("phdr", phdr.ToArray()), Chunk("pbag", pbag.ToArray()), Chunk("pmod", mod), Chunk("pgen", pgen.ToArray()),
				Chunk("inst", inst.ToArray()), Chunk("ibag", ibag.ToArray()), Chunk("imod", mod), Chunk("igen", igen.ToArray()),
				Chunk("shdr", shdr.ToArray()));
			var body = Concat(Encoding.ASCII.GetBytes("sfbk"), info, sdta, pdta);
			File.WriteAllBytes(ProjectSettings.GlobalizePath(path), Concat(Encoding.ASCII.GetBytes("RIFF"), BitConverter.GetBytes(body.Length), body));
			return "";
		}
		catch (Exception e) { return e.Message; }
	}

	static short TimeCents(float seconds) =>
		(short)Math.Clamp(Math.Round(1200 * Math.Log2(Math.Max(seconds, 0.001))), -12000, 8000);

	static void Name(BinaryWriter w, string name)
	{
		var b = new byte[20];
		var src = Encoding.ASCII.GetBytes(name ?? "");
		Array.Copy(src, b, Math.Min(src.Length, 19));
		w.Write(b);
	}

	static byte[] ZStr(string s)
	{
		var b = Encoding.ASCII.GetBytes((s ?? "") + "\0");
		return b.Length % 2 == 0 ? b : Concat(b, new byte[1]);
	}

	static byte[] Chunk(string id, byte[] data)
	{
		var pad = data.Length % 2 == 1 ? new byte[1] : Array.Empty<byte>();
		return Concat(Encoding.ASCII.GetBytes(id), BitConverter.GetBytes(data.Length), data, pad);
	}

	static byte[] List(string type, params byte[][] chunks)
	{
		var body = Concat(Encoding.ASCII.GetBytes(type), Concat(chunks));
		return Concat(Encoding.ASCII.GetBytes("LIST"), BitConverter.GetBytes(body.Length), body);
	}

	static byte[] Concat(params byte[][] parts)
	{
		int n = 0;
		foreach (var p in parts) n += p.Length;
		var o = new byte[n];
		int at = 0;
		foreach (var p in parts) { Buffer.BlockCopy(p, 0, o, at, p.Length); at += p.Length; }
		return o;
	}

	// --- SFZ ------------------------------------------------------------------------------------

	/// <summary>Writes `bank` as SFZ into `folder` (one .sfz per instrument, samples/*.wav).
	/// Returns "" or an error message.</summary>
	public string WriteSfz(N64SoundBank bank, string folder)
	{
		try
		{
			string dir = ProjectSettings.GlobalizePath(folder);
			Directory.CreateDirectory(Path.Combine(dir, "samples"));
			var names = new Dictionary<N64Sample, string>();
			foreach (var s in bank.Samples)
			{
				if (s == null) continue;
				string n = Safe(s.Name);
				while (names.ContainsValue(n)) n += "_";
				names[s] = n;
				File.WriteAllBytes(Path.Combine(dir, "samples", n + ".wav"), Wav(s));
			}
			foreach (var ins in bank.Instruments)
			{
				if (ins == null) continue;
				var sb = new StringBuilder();
				sb.AppendLine($"// {ins.Name}: program {ins.Program}{(ins.IsDrumKit ? " (drum kit)" : "")} — exported from m3d3 N64 Sounds");
				sb.AppendLine("<control> default_path=samples/");
				var e = ins.Envelope;
				sb.AppendLine(Inv($"<global> ampeg_attack={e.X:0.####} ampeg_decay={e.Y:0.####} ampeg_sustain={e.Z * 100:0.##} ampeg_release={e.W:0.####} volume={Db(ins.Volume):0.##} pan={ins.Pan * 100:0.#}"));
				if (ins.Vibrato.X > 0)
					sb.AppendLine(Inv($"pitchlfo_depth={ins.Vibrato.X:0.#} pitchlfo_freq={ins.Vibrato.Y:0.##} pitchlfo_delay={ins.Vibrato.Z:0.###}"));
				foreach (var z in ins.Zones)
				{
					var smp = z.ContainsKey("sample") ? z["sample"].As<N64Sample>() : null;
					if (smp == null || !names.ContainsKey(smp)) continue;
					int root = N64Instrument.Get(z, "root_key", -1);
					if (ins.IsDrumKit && root < 0) root = N64Instrument.Get(z, "key_lo", 60);
					if (root < 0) root = smp.RootKey;
					float tune = smp.TuneCents + N64Instrument.GetF(z, "tune_cents", 0f);
					var line = Inv($"<region> sample={names[smp]}.wav lokey={N64Instrument.Get(z, "key_lo", 0)} hikey={N64Instrument.Get(z, "key_hi", 127)} lovel={N64Instrument.Get(z, "vel_lo", 0)} hivel={N64Instrument.Get(z, "vel_hi", 127)} pitch_keycenter={root} tune={tune:0} volume={Db(N64Instrument.GetF(z, "volume", 1f)):0.##} pan={N64Instrument.GetF(z, "pan", 0f) * 100:0.#}");
					if (smp.Loop)
						line += $" loop_mode=loop_continuous loop_start={smp.LoopStart} loop_end={smp.LoopEnd - 1}";
					else if (ins.IsDrumKit)
						line += " loop_mode=one_shot";
					sb.AppendLine(line);
				}
				File.WriteAllText(Path.Combine(dir, Safe(ins.Name) + ".sfz"), sb.ToString());
			}
			return "";
		}
		catch (Exception e) { return e.Message; }
	}

	static string Inv(FormattableString s) => s.ToString(System.Globalization.CultureInfo.InvariantCulture);

	static float Db(float v) => (float)(20 * Math.Log10(Math.Max(v, 1e-4)));

	static string Safe(string s)
	{
		var b = new StringBuilder();
		foreach (char c in s ?? "x") b.Append(char.IsLetterOrDigit(c) || c == '_' || c == '-' ? c : '_');
		return b.Length > 0 ? b.ToString() : "x";
	}

	/// <summary>16-bit mono WAV of the decoded sample, with a smpl chunk for its loop.</summary>
	public static byte[] Wav(N64Sample s)
	{
		var pcm = s.PcmBytes();
		var fmt = new MemoryStream();
		var f = new BinaryWriter(fmt);
		f.Write((ushort)1); f.Write((ushort)1); f.Write(s.SampleRate); f.Write(s.SampleRate * 2);
		f.Write((ushort)2); f.Write((ushort)16);
		var chunks = new List<byte[]> { Encoding.ASCII.GetBytes("WAVE"), Chunk("fmt ", fmt.ToArray()), Chunk("data", pcm) };
		if (s.Loop)
		{
			var sm = new MemoryStream();
			var w = new BinaryWriter(sm);
			w.Write(0u); w.Write(0u); w.Write((uint)(1_000_000_000L / Math.Max(s.SampleRate, 1)));
			w.Write((uint)s.RootKey); w.Write(0u); w.Write(0u); w.Write(0u);
			w.Write(1u); w.Write(0u);
			w.Write(0u); w.Write(0u); w.Write((uint)s.LoopStart); w.Write((uint)(s.LoopEnd - 1)); w.Write(0u); w.Write(0u);
			chunks.Add(Chunk("smpl", sm.ToArray()));
		}
		var body = Concat(chunks.ToArray());
		return Concat(Encoding.ASCII.GetBytes("RIFF"), BitConverter.GetBytes(body.Length), body);
	}
}
#endif
