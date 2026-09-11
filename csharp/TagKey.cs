using System;
using System.IO;
using System.Text;

// SOUNDSCAPE -- embedded key tag reader.
//
// Item 4 of the plan: show a key INSTANTLY for tracks that already carry one, so spectral
// analysis is only ever the fallback for untagged files.
//
// Deliberately dependency-free. TagLib# would do this in one line, but it is a NuGet
// package pulled in to read two frame types out of two containers -- and this project's
// whole indexing path currently has zero managed dependencies. The parsing below is
// bounded: ID3v2 TKEY/TXXX for MP3, and the Vorbis comment block for FLAC. Everything
// else returns "" and falls through to the chromagram.
//
// Reads are seek-and-stop: it never loads the audio, only the header, so indexing a
// thousand files costs a thousand small reads rather than a thousand decodes.
public static class TagKey
{
	// The tag names taggers actually use, lowercased for comparison.
	private static readonly string[] Wanted = { "key", "initialkey", "initial_key", "tkey" };

	/// <summary>
	/// The file's own key tag, or "" when it has none. Never throws -- a malformed header
	/// is a file without a tag, not an error worth stopping an index scan for.
	/// </summary>
	public static string Read(string path)
	{
		try
		{
			using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
			string ext = Path.GetExtension(path).ToLowerInvariant();
			return ext == ".flac" ? ReadFlac(fs) : ReadId3(fs);
		}
		catch
		{
			return "";
		}
	}

	// --- ID3v2 (MP3) --------------------------------------------------------
	// Header: "ID3" + version(2) + flags(1) + size(4, syncsafe). Then frames of
	// id(4) + size(4) + flags(2). TKEY is the initial-key frame; some taggers instead
	// write a TXXX user frame whose description is "INITIALKEY", so both are handled.
	private static string ReadId3(Stream fs)
	{
		var head = new byte[10];
		if (fs.Read(head, 0, 10) != 10 || head[0] != 'I' || head[1] != 'D' || head[2] != '3')
			return "";
		int major = head[3];
		if (major < 3)
			return "";   // v2.2 uses 3-byte frame ids; vanishingly rare and not worth the branch
		int tagSize = SyncSafe(head, 6);

		long end = 10 + tagSize;
		var id = new byte[4];
		var sz = new byte[4];
		var flags = new byte[2];
		while (fs.Position + 10 <= end)
		{
			if (fs.Read(id, 0, 4) != 4 || id[0] == 0)
				break;   // padding: the frames are done
			if (fs.Read(sz, 0, 4) != 4 || fs.Read(flags, 0, 2) != 2)
				break;
			// v2.4 sizes are syncsafe, v2.3 sizes are plain big-endian. Getting this wrong
			// walks the reader into the middle of a frame and every id after it is garbage.
			int size = major >= 4 ? SyncSafe(sz, 0) : BigEndian(sz, 0);
			if (size <= 0 || fs.Position + size > end)
				break;

			string frame = Encoding.ASCII.GetString(id);
			if (frame != "TKEY" && frame != "TXXX")
			{
				fs.Seek(size, SeekOrigin.Current);
				continue;
			}

			var body = new byte[size];
			if (fs.Read(body, 0, size) != size)
				break;
			string text = DecodeText(body);
			if (frame == "TKEY")
			{
				if (text.Length > 0)
					return text;
				continue;
			}
			// TXXX is "description\0value"; only the initial-key one is interesting
			int nul = text.IndexOf('\0');
			if (nul <= 0)
				continue;
			string desc = text.Substring(0, nul).Trim().ToLowerInvariant().Replace(" ", "");
			if (Array.IndexOf(Wanted, desc) >= 0)
				return text.Substring(nul + 1).Trim('\0').Trim();
		}
		return "";
	}

	// ID3 text frames lead with an encoding byte. 0 = ISO-8859-1, 1 = UTF-16 with BOM,
	// 2 = UTF-16BE, 3 = UTF-8. Guessing wrong turns "Am" into mojibake, so this reads it.
	private static string DecodeText(byte[] body)
	{
		if (body.Length < 2)
			return "";
		byte enc = body[0];
		int off = 1;
		Encoding e;
		switch (enc)
		{
			case 1: e = Encoding.Unicode; break;          // BOM handled by the decoder
			case 2: e = Encoding.BigEndianUnicode; break;
			case 3: e = Encoding.UTF8; break;
			default: e = Encoding.Latin1; break;
		}
		return e.GetString(body, off, body.Length - off).TrimEnd('\0').Trim();
	}

	private static int SyncSafe(byte[] b, int at)
		=> (b[at] & 0x7F) << 21 | (b[at + 1] & 0x7F) << 14 | (b[at + 2] & 0x7F) << 7 | (b[at + 3] & 0x7F);

	private static int BigEndian(byte[] b, int at)
		=> b[at] << 24 | b[at + 1] << 16 | b[at + 2] << 8 | b[at + 3];

	// --- FLAC ---------------------------------------------------------------
	// "fLaC" then a chain of metadata blocks: header is flag/type(1) + length(3, BE), and
	// the top bit of the first byte marks the last block. Type 4 is VORBIS_COMMENT:
	// vendor length(4, LE) + vendor, then count(4, LE) of "NAME=value" strings, all UTF-8
	// and all little-endian -- the one place in audio where that is true.
	private static string ReadFlac(Stream fs)
	{
		var magic = new byte[4];
		if (fs.Read(magic, 0, 4) != 4 || Encoding.ASCII.GetString(magic) != "fLaC")
			return "";

		var head = new byte[4];
		while (fs.Read(head, 0, 4) == 4)
		{
			bool last = (head[0] & 0x80) != 0;
			int type = head[0] & 0x7F;
			int len = head[1] << 16 | head[2] << 8 | head[3];
			if (type != 4)
			{
				if (last)
					break;
				fs.Seek(len, SeekOrigin.Current);
				continue;
			}

			var block = new byte[len];
			if (fs.Read(block, 0, len) != len)
				break;
			int p = 0;
			int vendor = LittleEndian(block, p);
			p += 4 + vendor;
			if (p + 4 > len)
				break;
			int count = LittleEndian(block, p);
			p += 4;
			for (int i = 0; i < count && p + 4 <= len; i++)
			{
				int n = LittleEndian(block, p);
				p += 4;
				if (n < 0 || p + n > len)
					break;
				string entry = Encoding.UTF8.GetString(block, p, n);
				p += n;
				int eq = entry.IndexOf('=');
				if (eq <= 0)
					continue;
				string name = entry.Substring(0, eq).Trim().ToLowerInvariant();
				if (Array.IndexOf(Wanted, name) >= 0)
				{
					string v = entry.Substring(eq + 1).Trim();
					if (v.Length > 0)
						return v;
				}
			}
			break;   // there is only ever one comment block
		}
		return "";
	}

	private static int LittleEndian(byte[] b, int at)
		=> b[at] | b[at + 1] << 8 | b[at + 2] << 16 | b[at + 3] << 24;
}
