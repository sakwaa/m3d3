#if TOOLS
using System;
using System.Collections.Generic;

namespace m3d3.Audio.Tools;

/// <summary>
/// Editor-only ADPCM encoder for N64Adpcm: trains a book of order-2 predictors for the
/// sample (k-means over each frame's best predictor, like Nintendo's tabledesign), then
/// picks the predictor + scale per 16-sample frame that decodes closest to the input,
/// tracking the decoder's own history so errors don't accumulate.
/// </summary>
public static class N64AdpcmEncoder
{
	public static (byte[] data, int[] book) Encode(short[] pcm, int predictors = 4)
	{
		int[] book = TrainBook(pcm, Math.Clamp(predictors, 1, 16));
		int npred = book.Length / 2;
		int frames = (pcm.Length + N64Adpcm.FrameSamples - 1) / N64Adpcm.FrameSamples;
		var data = new byte[frames * N64Adpcm.FrameBytes];
		int s1 = 0, s2 = 0;
		var x = new int[N64Adpcm.FrameSamples];
		var best = new int[N64Adpcm.FrameSamples];
		var tmp = new int[N64Adpcm.FrameSamples];
		for (int f = 0; f < frames; f++)
		{
			for (int k = 0; k < x.Length; k++)
			{
				int i = f * N64Adpcm.FrameSamples + k;
				x[k] = i < pcm.Length ? pcm[i] : 0;
			}
			long bestErr = long.MaxValue;
			int bestPred = 0, bestScale = 0, bs1 = 0, bs2 = 0;
			for (int p = 0; p < npred; p++)
			{
				int c1 = book[p * 2], c2 = book[p * 2 + 1];
				for (int scale = 0; scale <= 12; scale++)
				{
					long err = 0;
					int a1 = s1, a2 = s2;
					for (int k = 0; k < x.Length && err < bestErr; k++)
					{
						int pred = (c1 * a1 + c2 * a2) >> N64Adpcm.CoefShift;
						int r = x[k] - pred;
						int q = (int)MathF.Round(r / (float)(1 << scale));
						q = Math.Clamp(q, -8, 7);
						int s = N64Adpcm.Clamp16(pred + (q << scale));
						tmp[k] = q;
						long e = x[k] - s;
						err += e * e;
						a2 = a1;
						a1 = s;
					}
					if (err < bestErr)
					{
						bestErr = err;
						bestPred = p;
						bestScale = scale;
						Array.Copy(tmp, best, best.Length);
						bs1 = a1;
						bs2 = a2;
					}
				}
			}
			int o = f * N64Adpcm.FrameBytes;
			data[o] = (byte)((bestScale << 4) | bestPred);
			for (int k = 0; k < best.Length; k += 2)
				data[o + 1 + k / 2] = (byte)(((best[k] & 0x0F) << 4) | (best[k + 1] & 0x0F));
			s1 = bs1;
			s2 = bs2;
		}
		return (data, book);
	}

	/// <summary>Book of `count` order-2 predictors (Q11 pairs) clustered from the frames.</summary>
	public static int[] TrainBook(short[] pcm, int count)
	{
		var vecs = new List<(double a1, double a2, double w)>();
		int n = N64Adpcm.FrameSamples;
		for (int f = 0; f * n < pcm.Length; f++)
		{
			double r11 = 0, r12 = 0, r22 = 0, r01 = 0, r02 = 0, energy = 0;
			for (int k = 0; k < n; k++)
			{
				int i = f * n + k;
				if (i >= pcm.Length) break;
				double x0 = pcm[i];
				double x1 = i >= 1 ? pcm[i - 1] : 0;
				double x2 = i >= 2 ? pcm[i - 2] : 0;
				r11 += x1 * x1; r12 += x1 * x2; r22 += x2 * x2;
				r01 += x0 * x1; r02 += x0 * x2;
				energy += x0 * x0;
			}
			if (energy < 1.0) continue;
			double reg = (r11 + r22) * 1e-4 + 1.0;
			double det = (r11 + reg) * (r22 + reg) - r12 * r12;
			if (Math.Abs(det) < 1e-9) continue;
			double a1 = (r01 * (r22 + reg) - r02 * r12) / det;
			double a2 = ((r11 + reg) * r02 - r12 * r01) / det;
			// Keep predictors stable (x = a1 x1 + a2 x2: |a2| < 1, |a1| < 1 - a2).
			a2 = Math.Clamp(a2, -0.98, 0.98);
			double lim = 1.0 - a2 - 0.01;
			a1 = Math.Clamp(a1, -lim, lim);
			vecs.Add((a1, a2, Math.Sqrt(energy)));
		}
		var centers = new List<(double a1, double a2)>();
		if (vecs.Count == 0)
		{
			centers.Add((0, 0));
		}
		else
		{
			// Init: spread over the frames by predictor shape, then weighted k-means.
			vecs.Sort((p, q) => p.a1.CompareTo(q.a1));
			int k = Math.Min(count, vecs.Count);
			for (int i = 0; i < k; i++)
			{
				var v = vecs[(int)((i + 0.5) * vecs.Count / k)];
				centers.Add((v.a1, v.a2));
			}
			var assign = new int[vecs.Count];
			for (int iter = 0; iter < 20; iter++)
			{
				for (int i = 0; i < vecs.Count; i++)
				{
					double bd = double.MaxValue;
					for (int c = 0; c < centers.Count; c++)
					{
						double d = Sq(vecs[i].a1 - centers[c].a1) + Sq(vecs[i].a2 - centers[c].a2);
						if (d < bd) { bd = d; assign[i] = c; }
					}
				}
				var sum = new double[centers.Count, 3];
				for (int i = 0; i < vecs.Count; i++)
				{
					sum[assign[i], 0] += vecs[i].a1 * vecs[i].w;
					sum[assign[i], 1] += vecs[i].a2 * vecs[i].w;
					sum[assign[i], 2] += vecs[i].w;
				}
				for (int c = 0; c < centers.Count; c++)
					if (sum[c, 2] > 0)
						centers[c] = (sum[c, 0] / sum[c, 2], sum[c, 1] / sum[c, 2]);
			}
		}
		var book = new int[centers.Count * 2];
		for (int c = 0; c < centers.Count; c++)
		{
			book[c * 2] = Math.Clamp((int)Math.Round(centers[c].a1 * (1 << N64Adpcm.CoefShift)), -32768, 32767);
			book[c * 2 + 1] = Math.Clamp((int)Math.Round(centers[c].a2 * (1 << N64Adpcm.CoefShift)), -32768, 32767);
		}
		return book;
	}

	static double Sq(double v) => v * v;
}
#endif
