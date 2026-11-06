using System;

namespace m3d3.Audio;

/// <summary>
/// N64-style 4-bit ADPCM (modelled on Nintendo's VADPCM): frames of 16 samples in 9 bytes.
/// Byte 0 = (scale &lt;&lt; 4) | predictor; bytes 1..8 = 16 signed 4-bit residuals.
/// Each predictor is an order-2 linear predictor (Q11 coefficients) from the sample's
/// "book", trained per sample by the encoder. Decoding ships with the game; encoding is
/// editor-only (N64AdpcmEncoder).
/// </summary>
public static class N64Adpcm
{
	public const int FrameSamples = 16;
	public const int FrameBytes = 9;
	public const int CoefShift = 11;

	/// <summary>Decodes `sampleCount` samples to 16-bit PCM (samples past the data stay 0).
	/// Never throws on bad data: a predictor index past the book (or a missing book) predicts
	/// from zero coefficients, a negative count gives no samples.</summary>
	public static short[] Decode(byte[] data, int sampleCount, int[] book)
	{
		data ??= Array.Empty<byte>();
		book ??= Array.Empty<int>();
		var outPcm = new short[Math.Max(sampleCount, 0)];
		int s1 = 0, s2 = 0;
		int frames = data.Length / FrameBytes;
		int n = 0;
		for (int f = 0; f < frames && n < sampleCount; f++)
		{
			int o = f * FrameBytes;
			int header = data[o];
			int scale = header >> 4;
			int pred = header & 0x0F;
			bool inBook = pred * 2 + 1 < book.Length;
			int c1 = inBook ? book[pred * 2] : 0;
			int c2 = inBook ? book[pred * 2 + 1] : 0;
			for (int k = 0; k < FrameSamples && n < sampleCount; k++)
			{
				int b = data[o + 1 + (k >> 1)];
				int nib = (k & 1) == 0 ? (b >> 4) : (b & 0x0F);
				if (nib >= 8) nib -= 16;
				int p = (c1 * s1 + c2 * s2) >> CoefShift;
				int s = Clamp16(p + (nib << scale));
				outPcm[n++] = (short)s;
				s2 = s1;
				s1 = s;
			}
		}
		return outPcm;
	}

	public static int Clamp16(int v) => v < -32768 ? -32768 : (v > 32767 ? 32767 : v);

	/// <summary>Bytes needed for `sampleCount` samples.</summary>
	public static int EncodedSize(int sampleCount) =>
		(sampleCount + FrameSamples - 1) / FrameSamples * FrameBytes;
}
