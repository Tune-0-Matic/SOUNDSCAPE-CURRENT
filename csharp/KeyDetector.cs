using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Godot;

// SOUNDSCAPE -- background key detection.
//
// This is the one component in the hybrid plan that C# actually earns. The chromagram is
// ~12 million float multiply-accumulates per track; in GDScript that is roughly a second
// of wall time and it landed as a stutter. Compiled, the same maths is 20-40 ms, which is
// under a single frame at 30 fps even if it ran on the main thread -- and it does not.
//
// THREADING CONTRACT, and it is not optional:
//   - Detect()  is called from the main thread only.
//   - Analyse() runs on a ThreadPool task and touches NOTHING owned by the scene tree.
//   - The result comes back through CallDeferred, which is the only legal way to reach a
//     signal from a worker. Emitting directly from the task is a crash, not a race you
//     get away with.
//
// Requires the .NET build of Godot 4 (Godot_v4.7.1-stable_mono_win64). The standard
// build ignores this file entirely.
public partial class KeyDetector : Node
{
	/// <summary>Fires on the main thread when a track's key is known.</summary>
	/// <param name="path">The file that was analysed, so a late result can be matched up.</param>
	/// <param name="text">Formatted for display, e.g. "8A (Am)". Empty when detection failed.</param>
	/// <param name="pitchClass">0..11 with C = 0, or -1 when unknown.</param>
	/// <param name="score">Profile correlation, -1..1. Low means the answer is a guess.</param>
	[Signal]
	public delegate void KeyReadyEventHandler(string path, string text, int pitchClass, bool minor, float score);

	// --- analysis constants -------------------------------------------------
	// 11025 Hz is plenty: the highest bin is C6 at 1047 Hz, and a quarter of the samples
	// is a quarter of the work.
	private const int Rate = 11025;
	// 8192 @ 11025 Hz = 0.74 s, resolving 1.35 Hz. A semitone at the bottom of the range
	// (C2, 65 Hz) is 3.9 Hz apart, so even the lowest bins separate cleanly.
	private const int Frame = 8192;
	// Frames sampled across the track rather than every frame in it. Key is a global
	// property: ~24 s decides it as well as reading all of it.
	private const int Frames = 32;
	private const int MidiLo = 36;   // C2
	private const int MidiHi = 84;   // C6, exclusive
	private const int Seconds = 180;

	private static readonly string[] Names =
		{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };

	// Krumhansl-Schmuckler profiles: average listener rating of each pitch class against a
	// tonic, from the probe-tone experiments. Index 0 is the tonic.
	private static readonly double[] KsMajor =
		{ 6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88 };
	private static readonly double[] KsMinor =
		{ 6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17 };

	// Newest request wins. A double-clicked track must not have its predecessor's answer
	// arrive later and overwrite the display -- same rule as AudioEngine's decode token.
	private int _token;
	private readonly HashSet<string> _inFlight = new();
	private readonly object _lock = new();

	/// <summary>
	/// Queue a file for analysis. Returns immediately; listen for KeyReady.
	/// Calling twice for the same path while one is running is a no-op, not a second task.
	/// </summary>
	public void Detect(string path)
	{
		lock (_lock)
		{
			if (!_inFlight.Add(path))
				return;
		}
		int token = Interlocked.Increment(ref _token);
		_ = Task.Run(() => Run(path, token));
	}

	/// <summary>
	/// Analyse PCM the caller already has. Mono, -1..1, at <paramref name="rate"/> Hz.
	/// Use this when the samples are in hand and there is nothing to decode.
	/// </summary>
	public void DetectSamples(string path, float[] mono, int rate)
	{
		int token = Interlocked.Increment(ref _token);
		_ = Task.Run(() =>
		{
			var chroma = Chromagram(mono, rate);
			Deliver(path, token, Classify(chroma));
		});
	}

	private void Run(string path, int token)
	{
		(string text, int pc, bool minor, float score) result;
		try
		{
			// The tag is free and authoritative when it exists; only fall through to DSP
			// when the file has nothing to say about itself.
			string tag = TagKey.Read(path);
			result = tag.Length > 0 ? Parse(tag) : Classify(Chromagram(DecodeMono(path)));
		}
		catch (Exception e)
		{
			GD.PushWarning($"KeyDetector failed on {Path.GetFileName(path)}: {e.Message}");
			result = ("", -1, false, 0f);
		}
		finally
		{
			lock (_lock) { _inFlight.Remove(path); }
		}
		Deliver(path, token, result);
	}

	// Signals cannot be emitted from a worker. CallDeferred hops to the main thread at the
	// start of the next frame, which is exactly where the UI wants to be touched anyway.
	private void Deliver(string path, int token, (string text, int pc, bool minor, float score) r)
	{
		if (token != Volatile.Read(ref _token))
			return;   // superseded; drop rather than fight the newer answer
		CallDeferred(nameof(EmitKeyReady), path, r.text, r.pc, r.minor, r.score);
	}

	private void EmitKeyReady(string path, string text, int pc, bool minor, float score)
		=> EmitSignal(SignalName.KeyReady, path, text, pc, minor, score);

	// --- decode -------------------------------------------------------------
	// ffmpeg rather than a managed decoder: it is already a dependency of this project for
	// FLAC, it handles every format the library holds, and a NuGet audio decoder would be a
	// second way to be wrong about mp3. -t sits after -i so it caps the OUTPUT and ffmpeg
	// stops reading early instead of decoding a ten-minute track for a three-minute look.
	private static float[] DecodeMono(string path)
	{
		string raw = Path.Combine(Path.GetTempPath(), $"sndscape_key_{path.GetHashCode():x8}.raw");
		var psi = new System.Diagnostics.ProcessStartInfo("ffmpeg")
		{
			UseShellExecute = false,
			CreateNoWindow = true,
			RedirectStandardError = true,
		};
		foreach (var a in new[] { "-y", "-v", "error", "-i", path, "-map", "0:a:0",
					"-t", Seconds.ToString(), "-ac", "1", "-ar", Rate.ToString(),
					"-c:a", "pcm_s16le", "-f", "s16le", raw })
			psi.ArgumentList.Add(a);

		try
		{
			using (var p = System.Diagnostics.Process.Start(psi))
			{
				string err = p.StandardError.ReadToEnd();
				p.WaitForExit();
				if (p.ExitCode != 0)
					throw new IOException($"ffmpeg exit {p.ExitCode}: {err}");
			}
			byte[] bytes = File.ReadAllBytes(raw);
			var mono = new float[bytes.Length / 2];
			for (int i = 0; i < mono.Length; i++)
				mono[i] = BitConverter.ToInt16(bytes, i * 2) / 32768f;
			return mono;
		}
		finally
		{
			try { File.Delete(raw); } catch { /* a temp file we could not remove is not a failure */ }
		}
	}

	// --- chromagram ---------------------------------------------------------
	/// <summary>
	/// Twelve pitch-class energies, summed over frames sampled across the signal.
	/// Each frame is normalised to its own peak before it is added, so a loud chorus does
	/// not outvote a quiet verse -- without that, the key of the drop wins every time.
	/// </summary>
	private static double[] Chromagram(float[] mono, int rate = Rate)
	{
		var chroma = new double[12];
		if (mono == null || mono.Length < Frame)
			return chroma;

		// Hann window. Unwindowed frames leak a tonic into its own dominant, which is the
		// worst possible direction: that is also the way the profiles fail, so the two
		// errors compound instead of cancelling.
		var win = new double[Frame];
		for (int i = 0; i < Frame; i++)
			win[i] = 0.5 - 0.5 * Math.Cos(2.0 * Math.PI * i / (Frame - 1));

		// Precompute one Goertzel coefficient per semitone. 48 known frequencies is why
		// there is no FFT here: a semitone is not an FFT bin, and 48 second-order
		// recurrences beat a transform plus the interpolation needed to read it.
		int bins = MidiHi - MidiLo;
		var coeff = new double[bins];
		for (int b = 0; b < bins; b++)
		{
			double hz = 440.0 * Math.Pow(2.0, (MidiLo + b - 69) / 12.0);
			coeff[b] = 2.0 * Math.Cos(2.0 * Math.PI * hz / rate);
		}

		int hop = Math.Max((mono.Length - Frame) / Math.Max(Frames - 1, 1), Frame);
		var windowed = new double[Frame];
		var acc = new double[12];
		for (int pos = 0, n = 0; pos + Frame <= mono.Length && n < Frames; pos += hop, n++)
		{
			for (int i = 0; i < Frame; i++)
				windowed[i] = mono[pos + i] * win[i];

			Array.Clear(acc, 0, 12);
			for (int b = 0; b < bins; b++)
				acc[(MidiLo + b) % 12] += Goertzel(windowed, coeff[b]);

			double peak = 0.0;
			for (int i = 0; i < 12; i++)
				peak = Math.Max(peak, acc[i]);
			if (peak <= 0.0)
				continue;
			for (int i = 0; i < 12; i++)
				chroma[i] += acc[i] / peak;
		}
		return chroma;
	}

	private static double Goertzel(double[] x, double k)
	{
		double s1 = 0.0, s2 = 0.0;
		for (int i = 0; i < x.Length; i++)
		{
			double s0 = x[i] + k * s1 - s2;
			s2 = s1;
			s1 = s0;
		}
		return Math.Sqrt(Math.Max(s1 * s1 + s2 * s2 - k * s1 * s2, 0.0));
	}

	// --- classification -----------------------------------------------------
	/// <summary>
	/// Correlate the chromagram against all 24 rotated profiles and take the best fit.
	/// Pearson rather than a dot product, and that is not fussiness: the chromagram and the
	/// profiles have completely different means, and an uncorrected dot product just elects
	/// whichever note happened to be loudest.
	/// </summary>
	private static (string, int, bool, float) Classify(double[] chroma)
	{
		double total = 0.0;
		foreach (double v in chroma)
			total += v;
		if (total <= 0.0)
			return ("", -1, false, 0f);

		int bestPc = -1;
		bool bestMinor = false;
		double best = -2.0;
		for (int m = 0; m < 2; m++)
		{
			double[] profile = m == 1 ? KsMinor : KsMajor;
			for (int pc = 0; pc < 12; pc++)
			{
				double r = Pearson(chroma, profile, pc);
				if (r <= best)
					continue;
				best = r;
				bestPc = pc;
				bestMinor = m == 1;
			}
		}
		return (Label(bestPc, bestMinor), bestPc, bestMinor, (float)best);
	}

	private static double Pearson(double[] a, double[] profile, int rot)
	{
		double ma = 0.0, mb = 0.0;
		for (int i = 0; i < 12; i++)
		{
			ma += a[i];
			mb += profile[i];
		}
		ma /= 12.0;
		mb /= 12.0;

		double num = 0.0, da = 0.0, db = 0.0;
		for (int i = 0; i < 12; i++)
		{
			double u = a[i] - ma;
			double v = profile[((i - rot) % 12 + 12) % 12] - mb;
			num += u * v;
			da += u * u;
			db += v * v;
		}
		return num / Math.Sqrt(Math.Max(da * db, 1e-9));
	}

	// --- notation -----------------------------------------------------------
	/// <summary>
	/// Camelot wheel position. The number is the place on the circle of fifths with C major
	/// pinned at 8B; a minor key borrows the number of its RELATIVE major (A minor shares 8
	/// with C major), which is the entire point of the notation -- same number, compatible.
	/// </summary>
	public static string Camelot(int pc, bool minor)
	{
		int root = minor ? (pc + 3) % 12 : pc;
		return $"{(root * 7 + 7) % 12 + 1}{(minor ? "A" : "B")}";
	}

	/// <summary>"8A (Am)" -- Camelot for mixing, letter name for reading.</summary>
	public static string Label(int pc, bool minor)
		=> pc < 0 ? "" : $"{Camelot(pc, minor)} ({Names[pc]}{(minor ? "m" : "")})";

	/// <summary>
	/// Normalise whatever a tagger wrote into the same form Classify returns.
	/// Taggers do not agree: Mixxx writes "Am", Rekordbox "8A", Traktor "Amin", foobar
	/// "A minor". Anything that will not parse is passed through verbatim with pc = -1 --
	/// an unreadable tag is still something the user put there deliberately.
	/// </summary>
	public static (string text, int pc, bool minor, float score) Parse(string raw)
	{
		string s = (raw ?? "").Trim();
		if (s.Length == 0)
			return ("", -1, false, 0f);

		// Camelot in, Camelot out: "8A", "10B", "1a"
		var cam = System.Text.RegularExpressions.Regex.Match(s, @"^(\d{1,2})\s*([ABab])$");
		if (cam.Success)
		{
			int n = int.Parse(cam.Groups[1].Value);
			if (n >= 1 && n <= 12)
			{
				bool min = cam.Groups[2].Value.ToLowerInvariant() == "a";
				// inverse of Camelot(): the wheel number is a circle-of-fifths position,
				// and a minor number belongs to the relative major -- step back three.
				int p = (n + 4) % 12 * 7 % 12;
				if (min)
					p = ((p - 3) % 12 + 12) % 12;
				return (Label(p, min), p, min, 1f);
			}
		}

		int letter = "CDEFGAB".IndexOf(char.ToUpperInvariant(s[0]));
		if (letter < 0)
			return (s.ToUpperInvariant(), -1, false, 0f);
		int pc = new[] { 0, 2, 4, 5, 7, 9, 11 }[letter];
		int i = 1;
		if (s.Length > 1 && (s[1] == '#' || s[1] == '♯'))
		{
			pc = (pc + 1) % 12;
			i = 2;
		}
		// a note letter never follows a note letter, so an uppercase B here is a flat
		else if (s.Length > 1 && (s[1] == 'b' || s[1] == 'B' || s[1] == '♭'))
		{
			pc = (pc + 11) % 12;
			i = 2;
		}
		string rest = s.Substring(i).Trim().ToLowerInvariant();
		bool minor = rest == "m" || rest.StartsWith("min");
		if (!(minor || rest.Length == 0 || rest.StartsWith("maj")))
			return (s.ToUpperInvariant(), -1, false, 0f);
		return (Label(pc, minor), pc, minor, 1f);
	}

	/// <summary>
	/// Self-check, mirroring the assert-based checks the GDScript side runs in _ready.
	/// Call it once from _Ready behind an #if DEBUG, or from a test scene.
	/// </summary>
	public static bool SelfTest()
	{
		var probes = new (string, string)[]
		{
			("Am", "8A (Am)"), ("8A", "8A (Am)"), ("A minor", "8A (Am)"), ("Amin", "8A (Am)"),
			("A", "11B (A)"), ("Ebm", "2A (D#m)"), ("10B", "10B (D)"), ("1A", "1A (G#m)"),
			("B", "1B (B)"), ("Bb", "6B (A#)"), ("F#m", "11A (F#m)"), ("13A", "13A"), ("", ""),
		};
		foreach (var (input, want) in probes)
			if (Parse(input).text != want)
				return false;

		// A synthetic C-E-G chromagram must come back C major; an A-weighted one, A minor.
		var cmaj = new double[12];
		cmaj[0] = cmaj[4] = cmaj[7] = 1.0;
		var amin = new double[12];
		amin[0] = amin[4] = amin[7] = 1.0;
		amin[9] = 3.0;
		return Classify(cmaj).Item2 == 0 && !Classify(cmaj).Item3
			&& Classify(amin).Item2 == 9 && Classify(amin).Item3
			&& Classify(new double[12]).Item2 == -1
			&& Camelot(0, false) == "8B" && Camelot(9, true) == "8A"
			&& Camelot(5, false) == "7B" && Camelot(4, true) == "9A";
	}
}
