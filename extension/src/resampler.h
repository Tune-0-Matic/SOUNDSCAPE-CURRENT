/**************************************************************************/
/*  resampler.h                                                           */
/*  SincResampler / StreamPlayer -- every native stream to the mix rate.  */
/**************************************************************************/
//
// Godot's AudioStreamPlaybackResampled converts a stream to the mix rate with a 4-point cubic
// and a 16-bit fixed-point step. Measured on this project: 44.1 kHz on the 96 kHz mix ran
// -19.9 ppm fast-to-slow and a 10 kHz tone came out at about -26 dB THD+N. The native streams
// now hand the mixer frames already AT the mix rate, through this:
//
//   - a Kaiser-windowed sinc, designed for 120 dB of stopband from the two rates on the main
//     thread, passband flat to 91 % of the lower Nyquist. The stopband starts at the passband's
//     mirror about that Nyquist, so the cutoff sits ON it: whatever the transition band lets
//     through -- images going up, aliases coming down -- lands above the passband, never in it
//     (SoX's "aliasing allowed"). Half the taps of a stopband AT Nyquist for the same rejection,
//     and every upsampler's zero phase becomes an exact copy of its source frame.
//   - one precomputed row of taps per output phase. The step is the EXACT rational ratio --
//     out/gcd phases per source frame -- advanced in integers, so there is no drift at all and
//     no interpolation between rows while pitch is unity
//   - equal rates are a straight copy, bit for bit
//
// ponytail: pitch_scale (rate_scale) is honoured by interpolating between rows, with the kernel
// still cut for unity; nothing in SOUNDSCAPE sets pitch_scale, so that path is untested audio.
//
// The audio-thread half follows rt.h: render() touches only buffers sized in configure(), and a
// seek crosses from the main thread as an atomic applied at the top of the next mix.
//
// Cost matters beyond the CPU meter. Godot's Dummy driver (every headless test) sleeps a whole
// number of milliseconds after each mix -- Sleep(usdelay / 1000) on Windows, never less the time
// the mix took -- so the audio clock runs slow by whatever the mix spends, and the Video TEST
// pictures that follow it drift. On this laptop the clock lost several times what a render
// benchmark predicts: 44.1 kHz cost 10 ms a second against Godot's cubic with the process pinned
// to P-cores (20 on E-cores) while the benchmark said about 2.5. Hence a lean hot path:
//   - the taps run as eight explicit float lanes -- one AVX accumulator or two SSE2 ones, whichever
//     the CPU has -- in a fixed order, so every path gives the same bits (a strict-order double
//     sum does not vectorise without fast-math: it was 1.4 % of real time at 44.1 kHz)
//   - unity pitch runs its own loop on integer phases (_render_unity)
//   - the mirrored stopband above halves the taps
// Together 44.1 kHz went from 1.4 % of real time to under 0.2 %, and the video tests are back in
// line with the old cubic path.

#ifndef SOUNDSCAPE_RESAMPLER_H
#define SOUNDSCAPE_RESAMPLER_H

#include <godot_cpp/classes/audio_frame.hpp>

#if defined(__SSE2__) || defined(_M_X64) || defined(_M_AMD64)
#include <emmintrin.h>
#define SOUNDSCAPE_SSE2 1
#endif
#if defined(__GNUC__) && (defined(__x86_64__) || defined(__i386__))
#include <immintrin.h>
#define SOUNDSCAPE_AVX 1 // compiled for AVX per function, taken only where the CPU and OS have it
#endif

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <numeric>
#include <vector>

namespace soundscape {

/// Where a playback's frames come from: the source's own rate, always as a stereo pair.
struct Source {
	virtual ~Source() = default;
	/// AUDIO THREAD. Up to `frames` frames into l and r; fewer than asked means the source ended.
	virtual int64_t read(float *l, float *r, int64_t frames) = 0;
	/// AUDIO THREAD. The next read() starts at `frame`.
	virtual void seek(int64_t frame) = 0;
};

/// sum(c[j] * a[j]) and sum(c[j] * b[j]) over `n` (a multiple of 8) taps, as eight lanes summed
/// lane-wise and then across -- the same order on every CPU, so the result does not depend on SSE2.
#ifdef SOUNDSCAPE_AVX
__attribute__((target("avx"))) inline void dot8_avx(const float *c, const float *a, const float *b, int n, float *la, float *lb) {
	__m256 sa = _mm256_setzero_ps();
	__m256 sb = _mm256_setzero_ps();
	for (int j = 0; j < n; j += 8) {
		const __m256 cj = _mm256_loadu_ps(c + j);
		sa = _mm256_add_ps(sa, _mm256_mul_ps(cj, _mm256_loadu_ps(a + j)));
		sb = _mm256_add_ps(sb, _mm256_mul_ps(cj, _mm256_loadu_ps(b + j)));
	}
	_mm256_storeu_ps(la, sa);
	_mm256_storeu_ps(lb, sb);
}

inline bool has_avx() {
	static const bool yes = (__builtin_cpu_init(), __builtin_cpu_supports("avx")); // libgcc checks the OS saves YMM too
	return yes;
}
#endif

inline void dot8(const float *c, const float *a, const float *b, int n, double &out_a, double &out_b) {
	float la[8] = {};
	float lb[8] = {};
#ifdef SOUNDSCAPE_AVX
	if (has_avx()) {
		dot8_avx(c, a, b, n, la, lb);
	} else
#endif
#ifdef SOUNDSCAPE_SSE2
	{
	__m128 sa0 = _mm_setzero_ps();
	__m128 sa1 = _mm_setzero_ps();
	__m128 sb0 = _mm_setzero_ps();
	__m128 sb1 = _mm_setzero_ps();
	for (int j = 0; j < n; j += 8) {
		const __m128 c0 = _mm_loadu_ps(c + j);
		const __m128 c1 = _mm_loadu_ps(c + j + 4);
		sa0 = _mm_add_ps(sa0, _mm_mul_ps(c0, _mm_loadu_ps(a + j)));
		sa1 = _mm_add_ps(sa1, _mm_mul_ps(c1, _mm_loadu_ps(a + j + 4)));
		sb0 = _mm_add_ps(sb0, _mm_mul_ps(c0, _mm_loadu_ps(b + j)));
		sb1 = _mm_add_ps(sb1, _mm_mul_ps(c1, _mm_loadu_ps(b + j + 4)));
	}
	_mm_storeu_ps(la, sa0);
	_mm_storeu_ps(la + 4, sa1);
	_mm_storeu_ps(lb, sb0);
	_mm_storeu_ps(lb + 4, sb1);
	}
#else
	for (int j = 0; j < n; j += 8) {
		for (int k = 0; k < 8; ++k) {
			la[k] += c[j + k] * a[j + k];
			lb[k] += c[j + k] * b[j + k];
		}
	}
#endif
	out_a = 0.0;
	out_b = 0.0;
	for (int k = 0; k < 8; ++k) {
		out_a += double(la[k]);
		out_b += double(lb[k]);
	}
}

inline double bessel_i0(double x) {
	double sum = 1.0;
	double term = 1.0;
	const double q = x * x * 0.25;
	for (int k = 1; k < 500; ++k) {
		term *= q / (double(k) * double(k));
		sum += term;
		if (term < sum * 1e-21) {
			break;
		}
	}
	return sum;
}

class SincResampler {
public:
	static constexpr double kStopbandDb = 120.0;
	static constexpr int kMinRows = 512;   // phases per source frame, at least
	static constexpr int64_t kRead = 4096; // source frames pulled per read

	/// MAIN THREAD. Designs the kernel and sizes every buffer -- the only allocations. `pass_hz`
	/// narrows the passband below the default 91 % of the lower Nyquist (0 keeps the default).
	void configure(Source *p_src, int64_t p_in_rate, int64_t p_out_rate, double p_pass_hz = 0.0) {
#ifdef SOUNDSCAPE_AVX
		has_avx(); // the one-time CPU probe (a guarded static) runs here, never first on the audio thread
#endif
		_src = p_src;
		_passthrough = p_in_rate == p_out_rate;
		const int64_t g = std::gcd(p_in_rate, p_out_rate);
		_phases = p_out_rate / g; // L: phase units per source frame
		_advance = p_in_rate / g; // M: phase units per output frame
		_row_mul = std::max<int64_t>(1, (kMinRows + _phases - 1) / _phases);
		_rows = _phases * _row_mul;

		const double nyq = 0.5 * double(std::min(p_in_rate, p_out_rate));
		double pass = nyq * 0.91;
		if (p_pass_hz > 0.0) {
			pass = std::min(pass, p_pass_hz);
		}
		// a narrowed passband (DSD) keeps its stopband at Nyquist: shaped noise sits right above it,
		// loud, and none of it may fold back
		const double stop = p_pass_hz > 0.0 ? nyq : 2.0 * nyq - pass;
		const double fc = (p_pass_hz > 0.0 ? 0.5 * (pass + stop) : nyq) / double(p_in_rate); // cycles per source frame
		_delta0 = fc == 0.5; // upsampling: row 0 is a unit impulse
		const double dw = 2.0 * kPi * (stop - pass) / double(p_in_rate);
		const int taps = int(std::ceil((kStopbandDb - 7.95) / (2.285 * dw))) + 1;
		_half = std::max(2, (taps + 1) / 2);
		_width = 2 * _half;
		_wpad = (_width + 7) & ~7; // whole lanes; the padding taps are zero
		const double beta = 0.1102 * (kStopbandDb - 8.7);
		const double i0b = bessel_i0(beta);

		_table.assign(size_t(_rows + 1) * size_t(_width), 0.0);
		for (int64_t row = 0; row <= _rows; ++row) {
			const double frac = double(row) / double(_rows);
			double *c = &_table[size_t(row) * size_t(_width)];
			double sum = 0.0;
			for (int j = 0; j < _width; ++j) {
				const double d = frac + double(_half - 1) - double(j); // source time - tap
				if (std::fabs(d) >= double(_half)) {
					continue;
				}
				const double u = 2.0 * fc * d;
				// zero crossings exactly zero, so row 0 of an fc = 0.5 kernel is exactly an impulse
				const double sinc = u == 0.0 ? 1.0 : (u == std::floor(u) ? 0.0 : std::sin(kPi * u) / (kPi * u));
				const double x = d / double(_half);
				c[j] = 2.0 * fc * sinc * bessel_i0(beta * std::sqrt(std::max(0.0, 1.0 - x * x))) / i0b;
				sum += c[j];
			}
			// every phase row sums to exactly 1: no phase-dependent DC gain to modulate into images
			for (int j = 0; j < _width && sum != 0.0; ++j) {
				c[j] /= sum;
			}
		}
		// designed in double, run in float: a float tap is within 6e-8 of its double, which puts its
		// error images near -140 dB
		_ftable.assign(size_t(_rows + 1) * size_t(_wpad), 0.0f);
		for (int64_t row = 0; row <= _rows; ++row) {
			for (int j = 0; j < _width; ++j) {
				_ftable[size_t(row) * size_t(_wpad) + size_t(j)] = float(_table[size_t(row) * size_t(_width) + size_t(j)]);
			}
		}
		_table.clear();
		_table.shrink_to_fit();
		_crow.assign(size_t(_wpad), 0.0f);
		_cap = _width + 2 * kRead;
		// + _wpad: the lane loop reads up to seven frames past the window; zero taps meet them
		_l.assign(size_t(_cap + _wpad), 0.0f);
		_r.assign(size_t(_cap + _wpad), 0.0f);
		seek(0);
	}

	/// AUDIO THREAD. The next output frame sits exactly on source frame `frame`.
	void seek(int64_t p_frame) {
		_idx = std::max<int64_t>(0, p_frame);
		_num = 0.0;
		_eof = false;
		_end = INT64_MAX;
		_fill = 0;
		if (_passthrough) {
			_base = _idx;
			_src->seek(_idx);
			return;
		}
		const int64_t start = _idx - (_half - 1);
		if (start < 0) {
			const int64_t pad = std::min<int64_t>(-start, _cap);
			std::fill_n(_l.begin(), size_t(pad), 0.0f);
			std::fill_n(_r.begin(), size_t(pad), 0.0f);
			_fill = pad;
			_base = start;
			_src->seek(0);
		} else {
			_base = start;
			_src->seek(start);
		}
	}

	/// AUDIO THREAD. Returns the frames written; fewer than asked means the source ended.
	int32_t render(godot::AudioFrame *p_out, int32_t p_frames, double p_rate_scale) {
		if (_passthrough) {
			int32_t done = 0;
			while (done < p_frames) {
				const int64_t want = std::min<int64_t>(p_frames - done, kRead);
				const int64_t got = _src->read(_l.data(), _r.data(), want);
				for (int64_t i = 0; i < got; ++i) {
					p_out[done + i].left = _l[size_t(i)];
					p_out[done + i].right = _r[size_t(i)];
				}
				done += int32_t(got);
				_idx += got;
				if (got < want) {
					break;
				}
			}
			return done;
		}
		if (p_rate_scale == 1.0 && _num == std::floor(_num)) {
			return _render_unity(p_out, p_frames);
		}
		const double step = double(_advance) * p_rate_scale;
		const double units = double(_phases);
		int32_t n = 0;
		for (; n < p_frames; ++n) {
			_refill(_idx - (_half - 1), _idx + _half);
			if (_eof && _idx >= _end) {
				break;
			}
			const double p = _num * double(_row_mul); // exact integer while rate_scale is 1
			const int64_t row = std::min<int64_t>(int64_t(p), _rows - 1);
			const float t = float(p - double(row));
			const float *c0 = &_ftable[size_t(row) * size_t(_wpad)];
			const int64_t off = _idx - (_half - 1) - _base;
			double yl = 0.0;
			double yr = 0.0;
			if (t == 0.0f && row == 0 && _delta0) {
				yl = _l[size_t(off + _half - 1)]; // what the impulse row sums to, bit for bit
				yr = _r[size_t(off + _half - 1)];
			} else if (t == 0.0f) {
				dot8(c0, &_l[size_t(off)], &_r[size_t(off)], _wpad, yl, yr);
			} else {
				const float *c1 = c0 + _wpad;
				for (int j = 0; j < _wpad; ++j) {
					_crow[size_t(j)] = c0[j] + t * (c1[j] - c0[j]);
				}
				dot8(_crow.data(), &_l[size_t(off)], &_r[size_t(off)], _wpad, yl, yr);
			}
			p_out[n].left = float(yl);
			p_out[n].right = float(yr);
			_num += step;
			while (_num >= units) {
				_num -= units;
				++_idx;
			}
		}
		return n;
	}

	/// Source frames, fractional, of the NEXT output frame.
	double position() const { return double(_idx) + _num / double(_phases); }
	int half_width() const { return _half; }
	bool passthrough() const { return _passthrough; }

private:
	static constexpr double kPi = 3.14159265358979323846;

	/// render() at unity pitch, bit-identical to the general loop: the phase is an exact integer, so
	/// each run of frames whose windows are already held goes through one tight loop on locals --
	/// no refill check, float phase or member reload between frames. The bookkeeping, not the taps,
	/// was most of the cost once the taps ran in lanes.
	int32_t _render_unity(godot::AudioFrame *p_out, int32_t p_frames) {
		const int64_t units = _phases;
		const int64_t advance = _advance;
		const int64_t row_step = _row_mul * int64_t(_wpad);
		const int64_t lead = _half - 1;
		const int wpad = _wpad;
		const bool delta0 = _delta0;
		const float *table = _ftable.data();
		int64_t k = int64_t(_num);
		int32_t n = 0;
		while (n < p_frames) {
			_refill(_idx - lead, _idx + _half);
			int64_t last = _base + _fill - 1 - _half; // the last frame whose whole window is held
			if (_eof) {
				if (_idx >= _end) {
					break;
				}
				last = std::min(last, _end - 1);
			}
			// frames j = 0, 1, ... sit on source frame _idx + (k + j * advance) / units
			const int64_t run = std::min<int64_t>(p_frames - n, ((last - _idx + 1) * units - k + advance - 1) / advance);
			if (run <= 0) {
				break; // _refill could not hold a window: cannot happen while _cap holds one plus two reads
			}
			const float *l = _l.data();
			const float *r = _r.data();
			const int64_t base = _base;
			int64_t idx = _idx;
			const int32_t stop = n + int32_t(run);
			for (; n < stop; ++n) {
				const int64_t off = idx - lead - base;
				double yl;
				double yr;
				if (k == 0 && delta0) {
					yl = l[off + lead];
					yr = r[off + lead];
				} else {
					dot8(table + k * row_step, l + off, r + off, wpad, yl, yr);
				}
				p_out[n].left = float(yl);
				p_out[n].right = float(yr);
				k += advance;
				while (k >= units) {
					k -= units;
					++idx;
				}
			}
			_idx = idx;
		}
		_num = double(k);
		return n;
	}

	/// Holds source frames [lo, hi], reading ahead from the source and padding silence past its end.
	/// Frames behind `lo` are only dropped when the buffer needs the room, so the common call --
	/// the window already held -- is two comparisons, not a move per source frame.
	void _refill(int64_t p_lo, int64_t p_hi) {
		while (_base + _fill <= p_hi) {
			if (_cap - _fill < kRead) {
				const int64_t drop = std::min(std::max<int64_t>(0, p_lo - _base), _fill);
				if (drop == 0) {
					break; // cannot happen while _cap holds a window plus two reads
				}
				std::memmove(_l.data(), _l.data() + drop, size_t(_fill - drop) * sizeof(float));
				std::memmove(_r.data(), _r.data() + drop, size_t(_fill - drop) * sizeof(float));
				_fill -= drop;
				_base += drop;
			}
			if (_eof) {
				const int64_t pad = std::min(p_hi + 1 - (_base + _fill), _cap - _fill);
				std::fill_n(_l.begin() + _fill, size_t(pad), 0.0f);
				std::fill_n(_r.begin() + _fill, size_t(pad), 0.0f);
				_fill += pad;
				continue;
			}
			const int64_t want = std::min(kRead, _cap - _fill);
			const int64_t got = _src->read(_l.data() + _fill, _r.data() + _fill, want);
			if (got < want) {
				_eof = true;
				_end = _base + _fill + got;
			}
			_fill += got;
		}
	}

	Source *_src = nullptr;
	bool _passthrough = true;
	int64_t _phases = 1;
	int64_t _advance = 1;
	int64_t _row_mul = 1;
	int64_t _rows = 1;
	int _half = 2;
	int _width = 4;
	int _wpad = 4;
	bool _delta0 = false;
	std::vector<double> _table; // design scratch, freed once _ftable is built
	std::vector<float> _ftable; // [rows + 1][_wpad]
	std::vector<float> _crow; // an interpolated row, off the unity-pitch path only
	std::vector<float> _l;
	std::vector<float> _r;
	int64_t _cap = 0;
	int64_t _base = 0; // source frame held at _l[0]
	int64_t _fill = 0; // source frames held
	int64_t _idx = 0; // source frame at or just before the next output frame
	double _num = 0.0; // phase units past _idx, [0, _phases)
	bool _eof = false;
	int64_t _end = INT64_MAX;
};

/// The playback logic every native stream shares, so FLAC, WAV and DSD differ only in their Source.
class StreamPlayer {
public:
	/// MAIN THREAD. `p_src` must outlive this player.
	void open(Source *p_src, int64_t p_in_rate, int64_t p_out_rate, double p_pass_hz = 0.0) {
		_rate = double(p_in_rate);
		_rs.configure(p_src, p_in_rate, p_out_rate, p_pass_hz);
	}
	void start(double p_from) {
		seek(p_from);
		_active.store(true);
	}
	void stop() { _active.store(false); }
	bool playing() const { return _active.load(); }
	double position() const { return _pos.load(std::memory_order_relaxed); }
	void seek(double p_seconds) {
		const int64_t frame = std::max<int64_t>(0, int64_t(p_seconds * _rate));
		_pos.store(double(frame) / _rate);
		_pending.store(frame);
	}

	/// AUDIO THREAD.
	int32_t mix(godot::AudioFrame *p_dst, float p_rate_scale, int32_t p_frames) {
		if (p_dst == nullptr || p_frames <= 0 || !_active.load(std::memory_order_relaxed)) {
			return 0;
		}
		const int64_t seek_to = _pending.exchange(-1, std::memory_order_relaxed);
		if (seek_to >= 0) {
			_rs.seek(seek_to);
		}
		const int32_t done = _rs.render(p_dst, p_frames, double(p_rate_scale));
		_pos.store(_rs.position() / _rate, std::memory_order_relaxed);
		if (done < p_frames) {
			for (int32_t i = done; i < p_frames; ++i) {
				p_dst[i].left = 0.0f;
				p_dst[i].right = 0.0f;
			}
			_active.store(false, std::memory_order_relaxed); // lets AudioStreamPlayer emit finished
		}
		return done;
	}

private:
	SincResampler _rs;
	double _rate = 44100.0;
	std::atomic<bool> _active{ false };
	std::atomic<int64_t> _pending{ -1 };
	std::atomic<double> _pos{ 0.0 };
};

} // namespace soundscape

#endif // SOUNDSCAPE_RESAMPLER_H
