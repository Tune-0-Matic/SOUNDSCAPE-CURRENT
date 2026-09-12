class_name SpectralKey
## Offline Krumhansl-Schmuckler key estimate. Never runs at playtime: this is called
## once per track from a WorkerThreadPool task during a folder scan (see
## AudioEngine.queue_spectral_key), and its answer is cached by path hash so the same
## file is never analysed twice. A tag from the file itself always wins; this only
## fills in where one was silent, and the caller marks its answer "estimated" -- a
## chroma vote is a vote, not a fact.
##
## Downmix and resample to 11.025 kHz mono are done by ffmpeg (AudioEngine's job, the
## same external dependency the FLAC transcode already relies on) before this ever
## runs -- reinventing a resampler in GDScript on top of an already CPU-heavy FFT would
## be exactly the kind of tight-loop cost the tag-only design elsewhere in this program
## was built to avoid. What is genuinely homegrown here is the analysis: the FFT, the
## chroma fold and the profile correlation.

const SAMPLE_RATE := 11025
const FFT_SIZE := 4096
## No overlap: a Krumhansl-Schmuckler vote sums chroma over the whole excerpt into one
## answer, so the extra frames a 50% overlap would add smooth nothing this needs and
## simply double the cost for the same signal.
const HOP := FFT_SIZE
## Below A1 / above the top octave a chroma fold cares about -- outside this band a
## bin is either sub-bass rumble or high-frequency noise, neither of which carries key.
const F_MIN := 55.0
const F_MAX := 5000.0
## A bounded EXCERPT, not the whole track -- ~60 s of chroma settles a single overall
## key as reliably as the full length would, and analysing every track end to end is
## exactly the "tight-loop CPU per track" cost that got spectral estimation pulled from
## this program once already (see the key-tags note in audio_engine.gd). Measured: the
## whole-track version of this ran 7+ seconds per 3.5-minute file; this bound is what
## keeps a folder scan's background workers from being buried under it.
const MAX_ANALYZE_SEC := 60.0

## Krumhansl & Kessler (1982) tone profiles, major then minor, indexed C, C#, D, ...
## Rotated per candidate root and correlated (dot product) against the piece's summed
## chroma vector; the rotation with the highest correlation wins.
const MAJOR_PROFILE := [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
const MINOR_PROFILE := [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

## Raw PCM (16-bit mono, SAMPLE_RATE) in, {"pc": int, "minor": bool} out -- or {} if
## the file was too short to analyse at all.
static func estimate(pcm_path: String) -> Dictionary:
	var f := FileAccess.open(pcm_path, FileAccess.READ)
	if not f:
		return {}
	var total := f.get_length()
	var max_bytes := int(MAX_ANALYZE_SEC * SAMPLE_RATE) * 2
	var take := mini(total, max_bytes)
	# centred, not from the start: an intro (silence, a fade-in, a spoken sample) is
	# often the least tonally representative part of a track
	var start := maxi(0, (total - take) / 2)
	start -= start % 2   # byte-aligned to a whole 16-bit sample
	f.seek(start)
	var bytes := f.get_buffer(take)
	f.close()
	var chroma := chroma_of(bytes)
	if chroma.is_empty():
		return {}
	return match_profile(chroma)

## Splits out for testing: feeding this a synthetic PCM buffer (a pure tone at a known
## pitch) is how the FFT + fold half of the pipeline is checked without a real file.
static func chroma_of(bytes: PackedByteArray) -> PackedFloat64Array:
	var n := bytes.size() / 2
	var chroma := PackedFloat64Array()
	chroma.resize(12)
	if n < FFT_SIZE:
		return PackedFloat64Array()
	var frames := 0
	var pos := 0
	while pos + FFT_SIZE <= n:
		var re := PackedFloat64Array()
		var im := PackedFloat64Array()
		re.resize(FFT_SIZE)
		im.resize(FFT_SIZE)
		for i in FFT_SIZE:
			var s := bytes.decode_s16((pos + i) * 2) / 32768.0
			# Hann window: without it FFT leakage smears every bin into its neighbours,
			# which is exactly the kind of blur a chroma fold cannot afford
			var w := 0.5 - 0.5 * cos(TAU * i / float(FFT_SIZE - 1))
			re[i] = s * w
		_fft(re, im)
		for k in FFT_SIZE / 2:
			var freq := float(k) * SAMPLE_RATE / float(FFT_SIZE)
			if freq < F_MIN or freq > F_MAX:
				continue
			var mag := sqrt(re[k] * re[k] + im[k] * im[k])
			var note := 12.0 * log(freq / 440.0) / log(2.0) + 69.0
			var pc := int(round(note)) % 12
			if pc < 0:
				pc += 12
			chroma[pc] += mag
		frames += 1
		pos += HOP
	return chroma if frames > 0 else PackedFloat64Array()

## Pure: the profile correlation alone, checkable against a synthetic chroma vector
## with no FFT or file involved.
##
## Krumhansl-Schmuckler is specifically PEARSON correlation against each of the 24
## rotated profiles, not a raw dot product -- major and minor profiles do not share a
## scale, so an unnormalised score would let one outweigh the other on magnitude alone
## rather than on how well its SHAPE actually fits. Caught by spectral_key_test(): a
## chroma vector built as an exact, perfectly rotated MAJOR_PROFILE came back matching
## MINOR at the wrong root under a plain dot product, because raw energy at the wrong
## shape scored higher than the true rotation's shape.
static func match_profile(chroma: PackedFloat64Array) -> Dictionary:
	var c_mean := 0.0
	for v in chroma:
		c_mean += v
	c_mean /= 12.0
	var c_dev := PackedFloat64Array()
	c_dev.resize(12)
	var c_ss := 0.0
	for i in 12:
		c_dev[i] = chroma[i] - c_mean
		c_ss += c_dev[i] * c_dev[i]

	var best_pc := 0
	var best_minor := false
	var best_score := -INF
	for minor in [false, true]:
		var profile: Array = MINOR_PROFILE if minor else MAJOR_PROFILE
		# mean/variance of the profile do not depend on its rotation, so both are
		# computed once per mode rather than once per candidate root
		var p_mean := 0.0
		for v in profile:
			p_mean += v
		p_mean /= 12.0
		var p_ss := 0.0
		for v in profile:
			p_ss += (float(v) - p_mean) * (float(v) - p_mean)
		for root in 12:
			var num := 0.0
			for i in 12:
				num += c_dev[i] * (float(profile[(i - root + 12) % 12]) - p_mean)
			var denom := sqrt(c_ss * p_ss)
			var score := num / denom if denom > 0.00001 else 0.0
			if score > best_score:
				best_score = score
				best_pc = root
				best_minor = minor
	return {"pc": best_pc, "minor": best_minor}

## In-place iterative radix-2 Cooley-Tukey. FFT_SIZE (4096) is a compile-time power of
## two, so the length is never checked at runtime -- a non-power-of-two call here would
## be a code bug, not a user-triggerable one.
static func _fft(re: PackedFloat64Array, im: PackedFloat64Array) -> void:
	var n := re.size()
	var j := 0
	for i in range(1, n):
		var bit := n >> 1
		while j & bit:
			j ^= bit
			bit >>= 1
		j ^= bit
		if i < j:
			var tr := re[i]; re[i] = re[j]; re[j] = tr
			var ti := im[i]; im[i] = im[j]; im[j] = ti
	var length := 2
	while length <= n:
		var ang := -TAU / float(length)
		var wr := cos(ang)
		var wi := sin(ang)
		var i := 0
		while i < n:
			var cwr := 1.0
			var cwi := 0.0
			for k in length / 2:
				var a := i + k
				var b := a + length / 2
				var vr := re[b] * cwr - im[b] * cwi
				var vi := re[b] * cwi + im[b] * cwr
				re[b] = re[a] - vr
				im[b] = im[a] - vi
				re[a] = re[a] + vr
				im[a] = im[a] + vi
				var nwr := cwr * wr - cwi * wi
				var nwi := cwr * wi + cwi * wr
				cwr = nwr
				cwi = nwi
			i += length
		length <<= 1

## Self-check, meant to be asserted from player.gd's _ready like every other pure-logic
## test in this program.
##   1. the FFT alone finds the right bin for a pure tone (a peak at 440 Hz, nothing
##      spurious dominating elsewhere).
##   2. the chroma fold puts that tone's energy in the right pitch class.
##   3. the profile matcher recovers a synthetic, perfectly rotated major profile as
##      its own root -- the part that never touches an FFT or a file at all.
static func spectral_key_test() -> bool:
	# (1) a 440 Hz (A4) tone, one FFT frame's worth at SAMPLE_RATE
	var re := PackedFloat64Array()
	var im := PackedFloat64Array()
	re.resize(FFT_SIZE)
	im.resize(FFT_SIZE)
	for i in FFT_SIZE:
		re[i] = sin(TAU * 440.0 * float(i) / SAMPLE_RATE)
	_fft(re, im)
	var peak_bin := 0
	var peak_mag := 0.0
	for k in FFT_SIZE / 2:
		var mag := sqrt(re[k] * re[k] + im[k] * im[k])
		if mag > peak_mag:
			peak_mag = mag
			peak_bin = k
	var peak_hz := float(peak_bin) * SAMPLE_RATE / float(FFT_SIZE)
	if absf(peak_hz - 440.0) > (SAMPLE_RATE / float(FFT_SIZE)):   # within one bin's width
		return false

	# (2) the same tone as raw PCM16, several frames' worth so chroma_of has enough to
	# fold -- must land in pitch class 9 (A), the loudest by a wide margin
	var n := FFT_SIZE + HOP * 3
	var buf := PackedByteArray()
	buf.resize(n * 2)
	for i in n:
		var v := sin(TAU * 440.0 * float(i) / SAMPLE_RATE) * 0.8
		buf.encode_s16(i * 2, int(v * 32767.0))
	var chroma := chroma_of(buf)
	if chroma.is_empty():
		return false
	var top_pc := 0
	for i in 12:
		if chroma[i] > chroma[top_pc]:
			top_pc = i
	if top_pc != 9:
		return false
	if chroma_of(PackedByteArray()).size() != 0:   # too short to analyse: no crash, empty
		return false

	# (3) profile matcher: a synthetic vector built as MAJOR_PROFILE rotated to root 4
	# (E major) must be recovered as exactly that -- root 4, not minor
	var rotated := PackedFloat64Array()
	rotated.resize(12)
	for i in 12:
		rotated[(i + 4) % 12] = MAJOR_PROFILE[i]
	var got := match_profile(rotated)
	return int(got["pc"]) == 4 and not bool(got["minor"])
