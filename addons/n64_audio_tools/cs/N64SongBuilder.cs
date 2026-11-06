#if TOOLS
using System;
using System.Collections.Generic;
using System.Linq;
using Godot;

namespace m3d3.Audio.Tools;

/// <summary>
/// Editor-only: compiles an <see cref="N64Song"/> from its parts (<see cref="N64Song.Tracks"/>):
/// reads each Standard MIDI File (format 0 / 1, running status, tempo changes), keeps the
/// chosen track(s), moves them to the part's channel, sets its instrument / volume / pan
/// at the start, tiles repeating parts to the song's length, and merges everything into
/// one timed event list (seconds). CC111 marks the loop start (RPG Maker convention).
/// A part naming a library instrument ("instrument") gets the program / bank the song's
/// bank set gives it (drum kits: the kit's program, sent only when the set has more than one
/// kit, as the synth otherwise plays the set's kit on channel 10 anyway).
/// </summary>
[Tool]
public partial class N64SongBuilder : RefCounted
{
	/// <summary>Builds the song in place. Returns "" or an error message.</summary>
	public string Build(N64Song song)
	{
		var parts = new List<(double t, int order, int ev)>();
		var errors = new List<string>();
		double songLength = 0;
		double loopCc = -1;
		float bpm = 0;
		int beats = 0;
		var repeating = new List<(List<(double t, int order, int ev)> evs, double length)>();
		for (int ti = 0; ti < song.Tracks.Count; ti++)
		{
			var tr = song.Tracks[ti];
			if (Get(tr, "mute", false))
				continue;
			string path = Get(tr, "path", "");
			if (!FileAccess.FileExists(path))
			{
				errors.Add($"part {ti + 1}: can't find {path}");
				continue;
			}
			Smf smf;
			try
			{
				smf = Smf.Read(FileAccess.GetFileAsBytes(path));
			}
			catch (Exception e)
			{
				errors.Add($"part {ti + 1}: {path.GetFile()}: {e.Message}");
				continue;
			}
			tr["mtime"] = (long)FileAccess.GetModifiedTime(path);
			if (bpm == 0)
			{
				bpm = smf.FirstBpm;
				beats = smf.BeatsPerBar;
			}
			bool drums = Get(tr, "drums", false);
			int program = Get(tr, "program", 0), bankSel = Get(tr, "bank", 0);
			bool kitProgram = false;
			string insName = Get(tr, "instrument", "");
			if (insName != "" && song.BankSet != null)
			{
				var entry = song.BankSet.EntryFor(insName);
				if (entry == null)
					errors.Add($"part {ti + 1}: {insName} isn't in the bank set {song.BankSet.Name} (plays program {program})");
				else
				{
					drums = N64BankSet.Ins(entry).IsDrumKit;
					program = N64BankSet.Prog(entry);
					bankSel = N64BankSet.BankOf(entry);
					int kits = 0;
					foreach (var e in song.BankSet.Entries)
						if (N64BankSet.Ins(e) is N64Instrument k && k.IsDrumKit) kits++;
					kitProgram = drums && kits > 1;
				}
			}
			int channel = drums ? N64Synth.DrumChannel : Get(tr, "channel", -1);
			int midiTrack = Get(tr, "midi_track", -1);
			var evs = new List<(double t, int order, int ev)>();
			// The part's set-up at time 0: instrument, volume, pan (the MIDI may change them later).
			int setupCh = channel >= 0 ? channel : smf.FirstChannel(midiTrack);
			if (!drums)
			{
				evs.Add((0, 0, N64Song.Pack(N64Song.Controller, setupCh, 0, bankSel)));
				evs.Add((0, 0, N64Song.Pack(N64Song.Program, setupCh, program, 0)));
			}
			else if (kitProgram)
				evs.Add((0, 0, N64Song.Pack(N64Song.Program, setupCh, program, 0)));
			evs.Add((0, 0, N64Song.Pack(N64Song.Controller, setupCh, 7, (int)Math.Round(Math.Clamp(GetF(tr, "volume", 0.79f), 0f, 1f) * 127))));
			evs.Add((0, 0, N64Song.Pack(N64Song.Controller, setupCh, 10, (int)Math.Round(Math.Clamp(GetF(tr, "pan", 0f), -1f, 1f) * 63 + 64))));
			double partLength = smf.LengthSeconds;
			foreach (var m in smf.Messages)
			{
				if (midiTrack >= 0 && m.Track != midiTrack)
					continue;
				int ch = channel >= 0 ? channel : m.Channel;
				double t = smf.Seconds(m.Tick);
				switch (m.Status & 0xF0)
				{
					case 0x90 when m.D2 > 0:
						evs.Add((t, 3, N64Song.Pack(N64Song.NoteOn, ch, m.D1, m.D2)));
						break;
					case 0x80:
					case 0x90:
						evs.Add((t, 1, N64Song.Pack(N64Song.NoteOff, ch, m.D1, 0)));
						break;
					case 0xB0:
						if (m.D1 == 111)
						{
							loopCc = loopCc < 0 ? t : Math.Min(loopCc, t);
							break;
						}
						evs.Add((t, 2, N64Song.Pack(N64Song.Controller, ch, m.D1, m.D2)));
						break;
					case 0xC0:
						// Program changes inside the MIDI are kept unless the part picks its instrument.
						if (!tr.ContainsKey("program") && !tr.ContainsKey("instrument"))
							evs.Add((t, 2, N64Song.Pack(N64Song.Program, ch, m.D1, 0)));
						break;
					case 0xE0:
						evs.Add((t, 2, N64Song.Pack(N64Song.Bend, ch, 0, m.D1 | (m.D2 << 7))));
						break;
				}
			}
			if (Get(tr, "repeat", false))
				repeating.Add((evs, partLength));
			else
			{
				parts.AddRange(evs);
				songLength = Math.Max(songLength, partLength);
			}
		}
		// Repeating parts tile to the longest non-repeating part (or play once if they're all
		// repeating: the song is as long as the longest of them).
		if (songLength <= 0)
			foreach (var r in repeating)
				songLength = Math.Max(songLength, r.length);
		foreach (var (evs, length) in repeating)
		{
			if (length <= 0.001)
				continue;
			for (double offset = 0; offset < songLength - 1e-6; offset += length)
				foreach (var e in evs)
				{
					// Set-up events once; notes / controllers every pass that starts in the song.
					if (offset > 0 && e.order == 0)
						continue;
					double t = e.t + offset;
					if (t < songLength - 1e-6 || N64Song.Type(e.ev) == N64Song.NoteOff)
						parts.Add((Math.Min(t, songLength), e.order, e.ev));
				}
		}
		// Time order; at the same time: set-up, note-offs, controllers, then note-ons.
		var sorted = parts.OrderBy(p => p.t).ThenBy(p => p.order).ToList();
		song.Times = sorted.Select(p => p.t).ToArray();
		song.Events = sorted.Select(p => p.ev).ToArray();
		song.Length = songLength;
		if (bpm > 0)
		{
			song.Bpm = bpm;
			song.BeatsPerBar = beats > 0 ? beats : 4;
		}
		if (song.LoopFromMidi && loopCc >= 0)
			song.LoopStart = loopCc;
		song.EmitChanged();
		return string.Join("\n", errors);
	}

	/// <summary>Tracks / channels of a MIDI file, for the part editor: [{track, name,
	/// channels (array), notes}] and the length in seconds (as "length").</summary>
	public Godot.Collections.Dictionary Describe(string path)
	{
		var outD = new Godot.Collections.Dictionary();
		try
		{
			var smf = Smf.Read(FileAccess.GetFileAsBytes(path));
			var tracks = new Godot.Collections.Array();
			for (int t = 0; t < smf.TrackCount; t++)
			{
				var chans = smf.Messages.Where(m => m.Track == t && (m.Status & 0xF0) is 0x90 or 0x80).Select(m => m.Channel).Distinct().OrderBy(c => c).ToArray();
				int notes = smf.Messages.Count(m => m.Track == t && (m.Status & 0xF0) == 0x90 && m.D2 > 0);
				tracks.Add(new Godot.Collections.Dictionary
				{
					["track"] = t,
					["name"] = smf.TrackNames.TryGetValue(t, out var n) ? n : "",
					["channels"] = new Godot.Collections.Array(chans.Select(c => Variant.From(c))),
					["notes"] = notes,
				});
			}
			outD["tracks"] = tracks;
			outD["length"] = smf.LengthSeconds;
			outD["bpm"] = smf.FirstBpm;
		}
		catch (Exception e)
		{
			outD["error"] = e.Message;
		}
		return outD;
	}

	private static T Get<[MustBeVariant] T>(Godot.Collections.Dictionary d, string k, T def) =>
		d.ContainsKey(k) ? d[k].As<T>() : def;

	private static float GetF(Godot.Collections.Dictionary d, string k, float def) =>
		d.ContainsKey(k) ? (float)d[k].AsDouble() : def;

	/// <summary>A parsed Standard MIDI File: channel messages (absolute ticks) + tempo map.</summary>
	private sealed class Smf
	{
		public struct Msg
		{
			public int Track;
			public long Tick;
			public int Status;
			public int D1;
			public int D2;
			public int Channel => Status & 15;
		}

		public int Division;
		public int TrackCount;
		public readonly List<Msg> Messages = new();
		public readonly Dictionary<int, string> TrackNames = new();
		private readonly List<(long tick, int usPerQuarter)> _tempos = new();
		private long _endTick;
		public int BeatsPerBar = 4;

		public float FirstBpm => 60_000_000f / (_tempos.Count > 0 ? _tempos[0].usPerQuarter : 500000);

		public double LengthSeconds => Seconds(_endTick);

		public int FirstChannel(int track)
		{
			foreach (var m in Messages)
				if (track < 0 || m.Track == track)
					return m.Channel;
			return 0;
		}

		/// <summary>Ticks to seconds through the tempo map.</summary>
		public double Seconds(long tick)
		{
			double t = 0;
			long last = 0;
			int us = 500000;
			foreach (var (tk, u) in _tempos)
			{
				if (tk >= tick)
					break;
				t += (tk - last) * (double)us / Division / 1e6;
				last = tk;
				us = u;
			}
			return t + (tick - last) * (double)us / Division / 1e6;
		}

		public static Smf Read(byte[] data)
		{
			var smf = new Smf();
			int p = 0;
			if (data.Length < 14 || Str(data, 0) != "MThd")
				throw new Exception("not a MIDI file (no MThd header)");
			int hlen = Be32(data, 4);
			int format = Be16(data, 8);
			int ntracks = Be16(data, 10);
			smf.Division = Be16(data, 12);
			if ((smf.Division & 0x8000) != 0)
				throw new Exception("SMPTE time division isn't supported (export with ticks per beat)");
			if (format > 1)
				throw new Exception($"MIDI format {format} isn't supported (use format 0 or 1)");
			p = 8 + hlen;
			for (int tr = 0; tr < ntracks && p + 8 <= data.Length; tr++)
			{
				if (Str(data, p) != "MTrk")
					throw new Exception($"track {tr}: missing MTrk");
				int len = Be32(data, p + 4);
				int q = p + 8;
				int end = Math.Min(q + len, data.Length);
				long tick = 0;
				int status = 0;
				while (q < end)
				{
					tick += Vlq(data, ref q);
					int b = data[q];
					if (b >= 0x80)
					{
						q++;
						if (b < 0xF0)
							status = b;
					}
					else if (status == 0)
						throw new Exception($"track {tr}: data byte without a status");
					else
						b = status;  // running status
					if (b == 0xFF)
					{
						int type = data[q++];
						int mlen = (int)Vlq(data, ref q);
						if (type == 0x51 && mlen == 3)
							smf._tempos.Add((tick, (data[q] << 16) | (data[q + 1] << 8) | data[q + 2]));
						else if (type == 0x58 && mlen >= 1 && smf.BeatsPerBar == 4 && tick == 0)
							smf.BeatsPerBar = Math.Max((int)data[q], 1);
						else if (type == 0x03 && !smf.TrackNames.ContainsKey(tr))
							smf.TrackNames[tr] = System.Text.Encoding.UTF8.GetString(data, q, mlen);
						else if (type == 0x2F)
							smf._endTick = Math.Max(smf._endTick, tick);
						q += mlen;
						status = 0;
						continue;
					}
					if (b == 0xF0 || b == 0xF7)
					{
						int slen = (int)Vlq(data, ref q);
						q += slen;
						status = 0;
						continue;
					}
					int kind = b & 0xF0;
					int d1 = data[q++];
					int d2 = kind is 0xC0 or 0xD0 ? 0 : data[q++];
					smf._endTick = Math.Max(smf._endTick, tick);
					if (kind is 0x80 or 0x90 or 0xB0 or 0xC0 or 0xE0)
						smf.Messages.Add(new Msg { Track = tr, Tick = tick, Status = b, D1 = d1, D2 = d2 });
				}
				p = 8 + p + len;
				smf.TrackCount = tr + 1;
			}
			smf._tempos.Sort((a, b) => a.tick.CompareTo(b.tick));
			smf.Messages.Sort((a, b) => a.Tick.CompareTo(b.Tick));
			return smf;
		}

		private static string Str(byte[] d, int p) => p + 4 <= d.Length ? System.Text.Encoding.ASCII.GetString(d, p, 4) : "";
		private static int Be16(byte[] d, int p) => (d[p] << 8) | d[p + 1];
		private static int Be32(byte[] d, int p) => (d[p] << 24) | (d[p + 1] << 16) | (d[p + 2] << 8) | d[p + 3];

		private static long Vlq(byte[] d, ref int p)
		{
			long v = 0;
			for (int i = 0; i < 4 && p < d.Length; i++)
			{
				int b = d[p++];
				v = (v << 7) | (uint)(b & 0x7F);
				if ((b & 0x80) == 0)
					break;
			}
			return v;
		}
	}
}
#endif
