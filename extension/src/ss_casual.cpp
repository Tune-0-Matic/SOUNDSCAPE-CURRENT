/**************************************************************************/
/*  ss_casual.cpp                                                         */
/**************************************************************************/

#include "ss_casual.h"

#include "resampler.h" // soundscape::dot8, soundscape::bessel_i0

#include <godot_cpp/classes/audio_server.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>

using namespace godot;

namespace {
constexpr double kPi = 3.14159265358979323846;
constexpr double kLowHz = 120.0;
constexpr double kLowDb = 2.2;
constexpr double kMidHz = 3000.0;
constexpr double kMidDb = -0.8;
constexpr double kMidHalfHz = 1000.0; // half the dip this far either side of kMidHz
constexpr double kHighPassHz = 8500.0; // flat up to here
constexpr double kHighStopHz = 16000.0; // the full rolloff from here
constexpr double kHighDb = -1.5;
constexpr double kHighAttenDb = 60.0; // how closely the rolloff holds 0 dB below and -1.5 dB above
// sin(pi x) / (pi x) = 0.5^(1/4) at x = 0.3185: four boxcars of M = 0.3185 fs / f multiply to half
// amplitude at f
constexpr double kBoxcarX = 0.3185;

double mid_sigma(double p_mix_rate) {
	// a Gaussian at half amplitude kMidHalfHz from its centre, as a window width in frames
	const double sigma_hz = kMidHalfHz / std::sqrt(2.0 * std::log(2.0));
	return p_mix_rate / (2.0 * kPi * sigma_hz);
}

int odd_at_least(double v, int floor) {
	int n = std::max(floor, int(std::lround(v)));
	return n | 1;
}
} // namespace

/**************************************************************************/
/* SsCasualCurveInstance                                                  */
/**************************************************************************/

void SsCasualCurveInstance::design(double p_mix_rate, int &r_boxcar, int &r_mid, int &r_high) {
	r_boxcar = odd_at_least(kBoxcarX * p_mix_rate / kLowHz, 3);
	r_mid = 2 * int(std::ceil(4.0 * mid_sigma(p_mix_rate))) + 1; // the Gaussian cut at 4 sigma
	const double dw = 2.0 * kPi * (kHighStopHz - kHighPassHz) / p_mix_rate;
	r_high = odd_at_least(std::ceil((kHighAttenDb - 7.95) / (2.285 * dw)) + 1.0, 3);
}

void SsCasualCurveInstance::setup(const std::shared_ptr<Shared> &p_shared, double p_mix_rate) {
	_keep = p_shared;
	_shared = p_shared.get();
	int nm = 1;
	int nh = 1;
	design(p_mix_rate, _m, nm, nh);
	_n = nm + nh - 1;
	_npad = (_n + 7) & ~7;
	_d1 = 2 * (_m - 1);
	_gl_minus_1 = float(std::pow(10.0, kLowDb / 20.0) - 1.0);

	// mid recess: an impulse plus (gM - 1) times the Gaussian bell modulated to 3 kHz (unity at its peak)
	const int cm = (nm - 1) / 2;
	const double sigma = mid_sigma(p_mix_rate);
	std::vector<double> mid(static_cast<size_t>(nm));
	double gsum = 0.0;
	for (int k = 0; k < nm; ++k) {
		const double d = double(k - cm) / sigma;
		mid[size_t(k)] = std::exp(-0.5 * d * d);
		gsum += mid[size_t(k)];
	}
	const double gm1 = std::pow(10.0, kMidDb / 20.0) - 1.0;
	for (int k = 0; k < nm; ++k) {
		mid[size_t(k)] *= gm1 * 2.0 * std::cos(2.0 * kPi * kMidHz * double(k - cm) / p_mix_rate) / gsum;
	}
	mid[size_t(cm)] += 1.0;

	// high rolloff: gH times an impulse plus (1 - gH) times a Kaiser lowpass normalised to unity at DC
	const int ch = (nh - 1) / 2;
	const double beta = 0.1102 * (kHighAttenDb - 8.7);
	const double fc = 0.5 * (kHighPassHz + kHighStopHz) / p_mix_rate;
	const double i0b = soundscape::bessel_i0(beta);
	std::vector<double> high(static_cast<size_t>(nh));
	double lsum = 0.0;
	for (int k = 0; k < nh; ++k) {
		const double d = double(k - ch);
		const double u = 2.0 * fc * d;
		const double sinc = d == 0.0 ? 1.0 : std::sin(kPi * u) / (kPi * u);
		const double r = d / double(ch);
		high[size_t(k)] = 2.0 * fc * sinc * soundscape::bessel_i0(beta * std::sqrt(std::max(0.0, 1.0 - r * r))) / i0b;
		lsum += high[size_t(k)];
	}
	const double gh = std::pow(10.0, kHighDb / 20.0);
	for (int k = 0; k < nh; ++k) {
		high[size_t(k)] *= (1.0 - gh) / lsum;
	}
	high[size_t(ch)] += gh;

	// one FIR for both, mirrored so float rounding cannot make it a hair asymmetric
	std::vector<double> both(static_cast<size_t>(_n), 0.0);
	for (int a = 0; a < nm; ++a) {
		for (int b = 0; b < nh; ++b) {
			both[size_t(a + b)] += mid[size_t(a)] * high[size_t(b)];
		}
	}
	_fir.assign(size_t(_npad), 0.0f);
	for (int k = 0; k <= (_n - 1) / 2; ++k) {
		const float tap = float(0.5 * (both[size_t(k)] + both[size_t(_n - 1 - k)]));
		_fir[size_t(k)] = tap;
		_fir[size_t(_n - 1 - k)] = tap;
	}
	for (int ch = 0; ch < 2; ++ch) {
		for (int s = 0; s < kStages; ++s) {
			_box[ch][s].assign(size_t(_m), 0.0f);
		}
		_xdelay[ch].assign(size_t(_d1), 0.0f);
		_hist[ch].assign(size_t(2 * _n + _npad), 0.0f);
	}
	_clear();
}

void SsCasualCurveInstance::_clear() {
	for (int ch = 0; ch < 2; ++ch) {
		for (int s = 0; s < kStages; ++s) {
			std::fill(_box[ch][s].begin(), _box[ch][s].end(), 0.0f);
			_sum[ch][s] = 0.0;
		}
		std::fill(_xdelay[ch].begin(), _xdelay[ch].end(), 0.0f);
		std::fill(_hist[ch].begin(), _hist[ch].end(), 0.0f);
	}
	_box_at = 0;
	_xd_at = 0;
	_h_at = 0;
}

void SsCasualCurveInstance::_process(const void *p_src_buffer, AudioFrame *r_dst_buffer, int32_t p_frame_count) {
	// ===================== AUDIO THREAD -- RT CONTRACT APPLIES =====================
	const AudioFrame *src = static_cast<const AudioFrame *>(p_src_buffer);
	if (src == nullptr || r_dst_buffer == nullptr || p_frame_count <= 0 || _shared == nullptr) {
		return;
	}
	const uint32_t epoch = _shared->reset_epoch.load(std::memory_order_relaxed);
	if (epoch != _epoch) {
		_epoch = epoch;
		_clear(); // fills buffers sized in setup(): no allocation
	}
	const double inv_m = 1.0 / double(_m);
	for (int32_t i = 0; i < p_frame_count; ++i) {
		const float in[2] = { src[i].left, src[i].right };
		const bool wrap = _box_at + 1 == _m;
		for (int ch = 0; ch < 2; ++ch) {
			// low shelf: the input delayed by the boxcars' own delay, plus the scaled lowpass
			float v = in[ch];
			for (int s = 0; s < kStages; ++s) {
				float &slot = _box[ch][s][size_t(_box_at)];
				_sum[ch][s] += double(v) - double(slot);
				slot = v;
				if (wrap) {
					// re-summed once a lap, so rounding in the running sum can never walk away
					double exact = 0.0;
					for (float f : _box[ch][s]) {
						exact += double(f);
					}
					_sum[ch][s] = exact;
				}
				v = float(_sum[ch][s] * inv_m);
			}
			float &xd = _xdelay[ch][size_t(_xd_at)];
			const float delayed = xd; // M >= 3, so D1 >= 4
			xd = in[ch];
			const float y1 = delayed + _gl_minus_1 * v;
			_hist[ch][size_t(_h_at)] = y1;
			_hist[ch][size_t(_h_at + _n)] = y1;
		}
		_box_at = wrap ? 0 : _box_at + 1;
		_xd_at = _xd_at + 1 == _d1 ? 0 : _xd_at + 1;
		_h_at = _h_at + 1 == _n ? 0 : _h_at + 1;
		// mid recess and high rolloff, one FIR over the last N frames of y1, oldest first
		double out_l = 0.0;
		double out_r = 0.0;
		soundscape::dot8(_fir.data(), &_hist[0][size_t(_h_at)], &_hist[1][size_t(_h_at)], _npad, out_l, out_r);
		r_dst_buffer[i].left = float(out_l);
		r_dst_buffer[i].right = float(out_r);
	}
	_shared->blocks.fetch_add(1, std::memory_order_relaxed);
}

bool SsCasualCurveInstance::_process_silence() const {
	return true;
}

void SsCasualCurveInstance::_bind_methods() {}

/**************************************************************************/
/* SsCasualCurve                                                          */
/**************************************************************************/

SsCasualCurve::SsCasualCurve() {
	_shared = std::make_shared<SsCasualCurveInstance::Shared>();
}

void SsCasualCurve::reset() {
	_shared->reset_epoch.fetch_add(1);
}

int SsCasualCurve::get_latency_frames() const {
	int m = 1;
	int nm = 1;
	int nh = 1;
	SsCasualCurveInstance::design(AudioServer::get_singleton()->get_mix_rate(), m, nm, nh);
	return 2 * (m - 1) + (nm + nh - 2) / 2;
}

uint64_t SsCasualCurve::get_blocks() const {
	return _shared->blocks.load(std::memory_order_relaxed);
}

Ref<AudioEffectInstance> SsCasualCurve::_instantiate() {
	Ref<SsCasualCurveInstance> instance;
	instance.instantiate();
	instance->setup(_shared, AudioServer::get_singleton()->get_mix_rate());
	return instance;
}

void SsCasualCurve::_bind_methods() {
	ClassDB::bind_method(D_METHOD("reset"), &SsCasualCurve::reset);
	ClassDB::bind_method(D_METHOD("get_latency_frames"), &SsCasualCurve::get_latency_frames);
	ClassDB::bind_method(D_METHOD("get_blocks"), &SsCasualCurve::get_blocks);
}
