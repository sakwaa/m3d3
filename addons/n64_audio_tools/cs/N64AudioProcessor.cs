#if TOOLS
using System;
using System.IO;
using Godot;

namespace m3d3.Audio.Tools;

/// <summary>
/// Editor-only sample processing for the sound bank tools: loads a recording (WAV), and
/// turns it into an N64Sample the N64 way: mono, resampled to a low rate (windowed sinc),
/// optional low-pass / trim / normalise / bit reduction, loop points found at matching
/// waveform positions (with an optional crossfade), root key from pitch detection, and
/// 4-bit ADPCM with a trained predictor book. Used from GDScript (the panel).
/// </summary>
[GlobalClass, Tool]
public partial class N64AudioProcessor : RefCounted
{
	/// <summary>Source audio (mono, -1..1) and its rate.</summary>
	public float[] Source = Array.Empty<float>();
	public int SourceRate = 44100;

	/// <summary>Last processed result's PCM (before ADPCM) for A/B and stats.</summary>
	private short[] _processed = Array.Empty<short>();

	public int SourceFrames => Source.Length;
	public float SourceSeconds => Source.Length / (float)Math.Max(SourceRate, 1);

	/// <summary>Loads a WAV file (8/16/24-bit PCM or 32-bit float, any channel count, mixed
	/// to mono). Returns an error message, or "" on success.</summary>
	public string LoadWav(string path)
	{
		byte[] bytes;
		try { bytes = File.ReadAllBytes(ProjectSettings.GlobalizePath(path)); }
		catch (Exception e) { return e.Message; }
		if (bytes.Length < 44 || Ascii(bytes, 0) != "RIFF" || Ascii(bytes, 8) != "WAVE")
			return "not a RIFF/WAVE file";
		int pos = 12, format = 0, channels = 0, rate = 0, bits = 0;
		int dataOff = -1, dataLen = 0;
		while (pos + 8 <= bytes.Length)
		{
			string id = Ascii(bytes, pos);
			int len = BitConverter.ToInt32(bytes, pos + 4);
			int body = pos + 8;
			if (id == "fmt ")
			{
				format = BitConverter.ToUInt16(bytes, body);
				channels = BitConverter.ToUInt16(bytes, body + 2);
				rate = BitConverter.ToInt32(bytes, body + 4);
				bits = BitConverter.ToUInt16(bytes, body + 14);
				if (format == 0xFFFE && len >= 26)
					format = BitConverter.ToUInt16(bytes, body + 24);  // extensible: sub-format
			}
			else if (id == "data")
			{
				dataOff = body;
				dataLen = Math.Min(len, bytes.Length - body);
			}
			pos = body + len + (len & 1);
		}
		if (dataOff < 0 || channels < 1 || rate < 1)
			return "missing fmt / data chunk";
		if (!(format == 1 && (bits == 8 || bits == 16 || bits == 24 || bits == 32)) && !(format == 3 && bits == 32))
			return $"unsupported WAV format {format} / {bits}-bit";
		int bps = bits / 8;
		int frames = dataLen / (bps * channels);
		var mono = new float[frames];
		for (int f = 0; f < frames; f++)
		{
			float sum = 0;
			for (int c = 0; c < channels; c++)
			{
				int o = dataOff + (f * channels + c) * bps;
				float v = bits switch
				{
					8 => (bytes[o] - 128) / 128f,
					16 => BitConverter.ToInt16(bytes, o) / 32768f,
					24 => ((bytes[o] | (bytes[o + 1] << 8) | ((sbyte)bytes[o + 2] << 16))) / 8388608f,
					_ => format == 3 ? BitConverter.ToSingle(bytes, o) : BitConverter.ToInt32(bytes, o) / 2147483648f,
				};
				sum += v;
			}
			mono[f] = sum / channels;
		}
		Source = mono;
		SourceRate = rate;
		return "";
	}

	/// <summary>Source as 16-bit PCM bytes (A/B preview).</summary>
	public byte[] SourcePcmBytes()
	{
		var b = new byte[Source.Length * 2];
		for (int i = 0; i < Source.Length; i++)
		{
			short s = (short)Math.Clamp((int)(Source[i] * 32767f), -32768, 32767);
			b[i * 2] = (byte)s;
			b[i * 2 + 1] = (byte)(s >> 8);
		}
		return b;
	}

	/// <summary>Min / max pairs over `columns` buckets of the source (-1..1), for drawing.</summary>
	public float[] SourceWaveform(int columns) => Waveform(Source, columns);

	/// <summary>Detected pitch of the source: [midi note (float), confidence 0..1].</summary>
	public float[] DetectPitch()
	{
		var (hz, conf) = Pitch(Source, SourceRate);
		if (hz <= 0) return new float[] { 60, 0 };
		return new float[] { (float)(69 + 12 * Math.Log2(hz / 440.0)), conf };
	}

	/// <summary>
	/// Processes the source into an N64Sample. Settings (Dictionary, all optional):
	/// start / end (seconds into the source, end -1 = its end: cut first, before everything
	/// else; later times are relative to the cut), fade_ms (linear fade-out over the end of
	/// the result, not when looping), rate (int Hz), lowpass (Hz, 0 = just under the new Nyquist), trim (bool), trim_db,
	/// normalize (bool), gain_db, bits (16 = none, 8..15 = reduce), predictors (1..8),
	/// loop ("none" / "auto" / "manual"), loop_start / loop_end (seconds; hints for auto),
	/// crossfade_ms, root_key (-1 = detect), tune_cents.
	/// </summary>
	public N64Sample Process(Godot.Collections.Dictionary settings)
	{
		float startS = Get(settings, "start", 0f);
		float endS = Get(settings, "end", -1f);
		float fadeMs = Get(settings, "fade_ms", 0f);
		int rate = Get(settings, "rate", 16000);
		float lowpass = Get(settings, "lowpass", 0f);
		bool trim = Get(settings, "trim", true);
		float trimDb = Get(settings, "trim_db", -50f);
		bool normalize = Get(settings, "normalize", true);
		float gainDb = Get(settings, "gain_db", 0f);
		int bits = Math.Clamp(Get(settings, "bits", 16), 4, 16);
		int predictors = Math.Clamp(Get(settings, "predictors", 4), 1, 8);
		string loopMode = Get(settings, "loop", "none");
		float loopStartS = Get(settings, "loop_start", -1f);
		float loopEndS = Get(settings, "loop_end", -1f);
		float crossfadeMs = Get(settings, "crossfade_ms", 0f);
		int rootKey = Get(settings, "root_key", -1);
		float tune = Get(settings, "tune_cents", 0f);

		// Cut: the part of the source the sample is made from (also used for pitch detection).
		int cutA = Math.Clamp((int)(startS * SourceRate), 0, Source.Length);
		int cutB = endS >= 0 ? Math.Clamp((int)(endS * SourceRate), cutA, Source.Length) : Source.Length;
		var cut = new float[cutB - cutA];
		Array.Copy(Source, cutA, cut, 0, cut.Length);
		var x = (float[])cut.Clone();
		if (trim) x = TrimSilence(x, trimDb);
		// Low-pass before shrinking the rate, then resample.
		float cutoff = lowpass > 0 ? lowpass : rate * 0.45f;
		if (cutoff < SourceRate * 0.5f) x = Biquad(x, SourceRate, cutoff);
		x = Resample(x, SourceRate, rate);
		float gain = MathF.Pow(10f, gainDb / 20f);
		if (normalize)
		{
			float peak = 1e-6f;
			foreach (var v in x) peak = MathF.Max(peak, MathF.Abs(v));
			gain *= 0.89f / peak;  // -1 dBFS
		}
		bool loop = loopMode != "none" && x.Length > 64;
		// Fade-out over the last fadeN samples, down to 0 at the last one.
		int fadeN = loop ? 0 : Math.Clamp((int)(fadeMs * 0.001f * rate), 0, x.Length);
		var pcm = new short[x.Length];
		int quant = 1 << (16 - bits);
		for (int i = 0; i < x.Length; i++)
		{
			float v = x[i] * gain;
			if (i >= x.Length - fadeN) v *= (x.Length - 1 - i) / (float)fadeN;
			int s = Math.Clamp((int)MathF.Round(v * 32767f), -32768, 32767);
			if (quant > 1) s = Math.Clamp((int)MathF.Round(s / (float)quant) * quant, -32768, 32767);
			pcm[i] = (short)s;
		}
		int ls = 0, le = pcm.Length;
		if (loop)
		{
			int hs = loopStartS >= 0 ? (int)(loopStartS * rate) : pcm.Length * 2 / 5;
			int he = loopEndS >= 0 ? (int)(loopEndS * rate) : pcm.Length - pcm.Length / 20;
			he = Math.Clamp(he, 32, pcm.Length);
			hs = Math.Clamp(hs, 0, he - 32);
			(ls, le) = loopMode == "auto" ? FindLoop(pcm, hs, he, rate) : (hs, he);
			int cf = (int)(crossfadeMs * 0.001f * rate);
			if (cf > 0) Crossfade(pcm, ls, le, cf);
			// Nothing after the loop is ever heard.
			Array.Resize(ref pcm, le);
		}
		if (rootKey < 0)
		{
			var (hz, conf) = Pitch(cut, SourceRate);
			if (hz > 0 && conf > 0.5f)
			{
				double midi = 69 + 12 * Math.Log2(hz / 440.0);
				rootKey = (int)Math.Round(midi);
				tune += (float)((rootKey - midi) * 100.0);  // play back in tune
			}
			else rootKey = 60;
		}
		_processed = pcm;
		var (data, book) = N64AdpcmEncoder.Encode(pcm, predictors);
		var sample = new N64Sample
		{
			Adpcm = data, Book = book, SampleCount = pcm.Length, SampleRate = rate,
			Loop = loop, LoopStart = ls, LoopEnd = le, RootKey = rootKey, TuneCents = tune,
		};
		return sample;
	}

	/// <summary>Signal-to-noise ratio (dB) of the ADPCM in `sample` against the processed
	/// PCM it was encoded from (last Process call).</summary>
	public float AdpcmSnr(N64Sample sample)
	{
		var dec = sample.Pcm;
		double sig = 0, noise = 0;
		int n = Math.Min(dec.Length, _processed.Length);
		for (int i = 0; i < n; i++)
		{
			sig += (double)_processed[i] * _processed[i];
			double d = _processed[i] - dec[i];
			noise += d * d;
		}
		return noise <= 0 ? 99f : (float)(10 * Math.Log10(sig / noise));
	}

	// --- DSP ------------------------------------------------------------------------------

	static float[] Waveform(float[] x, int columns)
	{
		var w = new float[columns * 2];
		for (int c = 0; c < columns; c++)
		{
			int a = (int)((long)c * x.Length / columns);
			int b = Math.Max(a + 1, (int)((long)(c + 1) * x.Length / columns));
			float lo = 0, hi = 0;
			for (int i = a; i < b && i < x.Length; i++) { lo = MathF.Min(lo, x[i]); hi = MathF.Max(hi, x[i]); }
			w[c * 2] = lo;
			w[c * 2 + 1] = hi;
		}
		return w;
	}

	static float[] TrimSilence(float[] x, float db)
	{
		var (a, b) = Unsilent(x, 0, x.Length, db);
		var o = new float[b - a];
		Array.Copy(x, a, o, 0, o.Length);
		return o;
	}

	/// <summary>The part of x[from..to) left after trimming silence below `db` (all of it
	/// when less than 16 samples would remain).</summary>
	static (int, int) Unsilent(float[] x, int from, int to, float db)
	{
		float th = MathF.Pow(10f, db / 20f);
		int a = from, b = to;
		while (a < b && MathF.Abs(x[a]) < th) a++;
		while (b > a && MathF.Abs(x[b - 1]) < th) b--;
		return b - a < 16 ? (from, to) : (a, b);
	}

	/// <summary>Seconds of the recording before the sample's first sample: the cut's start
	/// plus the silence Trim removes after it. Sample times (its loop, the loop_start /
	/// loop_end settings) count from there.</summary>
	public float SampleStartSeconds(Godot.Collections.Dictionary settings)
	{
		if (Source == null || Source.Length == 0) return 0f;
		int cutA = Math.Clamp((int)(Get(settings, "start", 0f) * SourceRate), 0, Source.Length);
		float endS = Get(settings, "end", -1f);
		int cutB = endS >= 0 ? Math.Clamp((int)(endS * SourceRate), cutA, Source.Length) : Source.Length;
		int a = Get(settings, "trim", true) ? Unsilent(Source, cutA, cutB, Get(settings, "trim_db", -50f)).Item1 : cutA;
		return a / (float)Math.Max(SourceRate, 1);
	}

	/// <summary>RBJ low-pass, run forwards and backwards (no phase shift, 24 dB/oct).</summary>
	static float[] Biquad(float[] x, int rate, float cutoff)
	{
		double w0 = 2 * Math.PI * cutoff / rate, alpha = Math.Sin(w0) / (2 * 0.7071), cos = Math.Cos(w0);
		double b0 = (1 - cos) / 2, b1 = 1 - cos, b2 = b0, a0 = 1 + alpha, a1 = -2 * cos, a2 = 1 - alpha;
		b0 /= a0; b1 /= a0; b2 /= a0; a1 /= a0; a2 /= a0;
		var y = new float[x.Length];
		for (int pass = 0; pass < 2; pass++)
		{
			double x1 = 0, x2 = 0, y1 = 0, y2 = 0;
			var src = pass == 0 ? x : y;
			var dst = new float[x.Length];
			for (int k = 0; k < x.Length; k++)
			{
				int i = pass == 0 ? k : x.Length - 1 - k;
				double v = b0 * src[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
				x2 = x1; x1 = src[i]; y2 = y1; y1 = v;
				dst[i] = (float)v;
			}
			y = dst;
		}
		return y;
	}

	/// <summary>Windowed-sinc resampler (Blackman, 32 taps each side).</summary>
	static float[] Resample(float[] x, int from, int to)
	{
		if (from == to) return x;
		int n = (int)((long)x.Length * to / from);
		var y = new float[n];
		double ratio = (double)from / to;
		double fc = Math.Min(1.0, (double)to / from) * 0.97;
		const int Taps = 32;
		for (int i = 0; i < n; i++)
		{
			double pos = i * ratio;
			int c = (int)Math.Floor(pos);
			double sum = 0, wsum = 0;
			for (int k = c - Taps + 1; k <= c + Taps; k++)
			{
				if (k < 0 || k >= x.Length) continue;
				double t = pos - k;
				double s = t == 0 ? 1 : Math.Sin(Math.PI * fc * t) / (Math.PI * fc * t);
				double wpos = (t + Taps) / (2.0 * Taps);
				double win = 0.42 - 0.5 * Math.Cos(2 * Math.PI * wpos) + 0.08 * Math.Cos(4 * Math.PI * wpos);
				double w = s * Math.Max(win, 0);
				sum += x[k] * w;
				wsum += w;
			}
			y[i] = (float)(wsum != 0 ? sum / wsum : 0);
		}
		return y;
	}

	/// <summary>Loop points near the hints where the waveform before the end matches the
	/// waveform before the start (so the jump back is seamless), on upward zero crossings.
	/// Candidates without a full comparison window inside the sample are skipped (the hints
	/// themselves are the fallback), so it never reads outside `x`.</summary>
	static (int, int) FindLoop(short[] x, int hintStart, int hintEnd, int rate)
	{
		int win = Math.Clamp(rate / 200, 16, 256);  // ~5 ms compared
		int endRange = Math.Clamp(rate / 20, 32, 4000);
		int startRange = Math.Max(rate / 10, 64);
		var ends = Crossings(x, Math.Max(win, hintEnd - endRange), Math.Min(x.Length - 1, hintEnd));
		var starts = Crossings(x, Math.Max(win, hintStart - startRange), Math.Min(hintEnd - 64, hintStart + startRange));
		if (ends.Count == 0) ends.Add(hintEnd);
		if (starts.Count == 0) starts.Add(hintStart);
		double best = double.MaxValue;
		int bs = hintStart, be = hintEnd;
		foreach (int e in ends)
			foreach (int s in starts)
			{
				if (e - s < win * 2 || s < win || e > x.Length) continue;
				double err = 0;
				for (int i = 1; i <= win && err < best; i++)
				{
					double d = x[e - i] - x[s - i];
					err += d * d;
				}
				if (err < best) { best = err; bs = s; be = e; }
			}
		return (bs, be);
	}

	static System.Collections.Generic.List<int> Crossings(short[] x, int a, int b)
	{
		var o = new System.Collections.Generic.List<int>();
		for (int i = Math.Max(a, 1); i < b; i++)
			if (x[i - 1] < 0 && x[i] >= 0) o.Add(i);
		// Too many candidates on noisy material: thin them out evenly.
		while (o.Count > 400)
		{
			var thin = new System.Collections.Generic.List<int>();
			for (int i = 0; i < o.Count; i += 2) thin.Add(o[i]);
			o = thin;
		}
		return o;
	}

	/// <summary>Blends the `n` samples before the loop end into the `n` before its start.</summary>
	static void Crossfade(short[] x, int ls, int le, int n)
	{
		n = Math.Min(n, Math.Min(ls, le - ls));
		for (int i = 0; i < n; i++)
		{
			float t = (i + 1) / (float)(n + 1);
			int ei = le - n + i, si = ls - n + i;
			x[ei] = (short)Math.Clamp((int)(x[ei] * (1 - t) + x[si] * t), -32768, 32767);
		}
	}

	/// <summary>Fundamental (Hz) by normalised autocorrelation over a steady stretch, with a
	/// confidence (correlation peak, 0..1).</summary>
	static (double, float) Pitch(float[] x, int rate)
	{
		int len = Math.Min(x.Length, rate / 4);
		if (len < 512) return (0, 0);
		int off = Math.Max(0, Math.Min(x.Length - len, x.Length / 4));
		int minLag = Math.Max(2, rate / 2000), maxLag = Math.Min(len / 2, rate / 30);
		double bestR = 0; int bestLag = 0;
		var r = new double[maxLag + 2];
		for (int lag = minLag; lag <= maxLag + 1; lag++)
		{
			double s = 0, e1 = 0, e2 = 0;
			for (int i = 0; i + lag < len; i++)
			{
				double a = x[off + i], b = x[off + i + lag];
				s += a * b; e1 += a * a; e2 += b * b;
			}
			r[lag] = s / Math.Sqrt(e1 * e2 + 1e-12);
		}
		// First strong peak (avoids octave errors from later, similar peaks).
		double top = 0;
		for (int lag = minLag; lag <= maxLag; lag++) top = Math.Max(top, r[lag]);
		for (int lag = minLag + 1; lag <= maxLag; lag++)
			if (r[lag] > r[lag - 1] && r[lag] >= r[lag + 1] && r[lag] > top * 0.9) { bestLag = lag; bestR = r[lag]; break; }
		if (bestLag == 0) return (0, 0);
		double y0 = r[bestLag - 1], y1 = r[bestLag], y2 = r[bestLag + 1];
		double shift = (y0 - y2) / (2 * (y0 - 2 * y1 + y2));
		double lagF = bestLag + (double.IsFinite(shift) ? Math.Clamp(shift, -0.5, 0.5) : 0);
		return (rate / lagF, (float)bestR);
	}

	static string Ascii(byte[] b, int o) => System.Text.Encoding.ASCII.GetString(b, o, 4);

	static T Get<T>(Godot.Collections.Dictionary d, string key, T def)
	{
		if (!d.ContainsKey(key)) return def;
		var v = d[key];
		return v.Obj is T t ? t : (T)Convert.ChangeType(v.Obj, typeof(T));
	}
}
#endif
