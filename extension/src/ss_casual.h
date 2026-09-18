/**************************************************************************/
/*  ss_casual.h                                                           */
/*  SsCasualCurve -- LISTENING MODE: CASUAL (SMOOTH), phase-linear.       */
/**************************************************************************/
//
// A warm, analog-coloured listening curve for harsh masterings:
//   +2.2 dB below 120 Hz    body       (half the lift at 120 Hz)
//   -0.8 dB around 3 kHz    glare      (a bell, half depth at 2 and 4 kHz)
//   -1.5 dB from 16 kHz     a relaxed top, flat up to 8.5 kHz and rolling off between the two
// It sits on Master ahead of the safety limiter, and AUDIOPHILE switches it out with
// set_bus_effect_enabled -- Godot then skips it entirely, so DIRECT stays bit-exact and free.
//
// PHASE-LINEAR, which Godot's shelving and peaking biquads are not: every stage is a symmetric FIR, so
// the whole curve delays every frequency by the same number of frames and moves no transient.
//
//   low shelf    y1 = x[n - D1] + (gL - 1) * LP120(x)
//                LP120 is FOUR cascaded moving averages of odd length M (a near-Gaussian lowpass,
//                symmetric, O(1) a sample whatever M is), at half amplitude at 120 Hz. D1 = 2 (M - 1).
//                Sidelobes near -52 dB, scaled by gL - 1 = 0.288: about 0.001 dB of ripple above it.
//   mid recess   y2 = y1[n - Dm] + (gM - 1) * BP3k(y1)
//                BP3k is a Gaussian window modulated to 3 kHz: a smooth bell of unity peak, leaking
//                -0.003 dB into the bass through its image at -3 kHz.
//   high rolloff y  = gH * y2[n - Dh] + (1 - gH) * LP(y2)
//                LP is a Kaiser-windowed sinc whose transition runs exactly 8.5 kHz -> 16 kHz at 60 dB.
// The mid and high stages are convolved into ONE symmetric FIR at design time, so the audio thread
// runs the boxcars and a single dot product.
//
// Latency 604 frames (6.3 ms) at a 96 kHz mix, about the same time at any rate -- the price of linear
// phase at 120 Hz, only paid while CASUAL is on. Measured response in test_ss_effect.gd 9.
//
// ponytail: switching modes jumps the output by that latency, a small click, and switching ON starts
// from reset delay lines, 6 ms of silence. A crossfade between the two paths is the upgrade if the
// toggle ever needs to be seamless mid-track.
#ifndef SOUNDSCAPE_SS_CASUAL_H
#define SOUNDSCAPE_SS_CASUAL_H

#include <godot_cpp/classes/audio_effect.hpp>
#include <godot_cpp/classes/audio_effect_instance.hpp>
#include <godot_cpp/classes/audio_frame.hpp>
#include <godot_cpp/core/class_db.hpp>

#include <atomic>
#include <memory>
#include <vector>

namespace godot {

class SsCasualCurveInstance : public AudioEffectInstance {
	GDCLASS(SsCasualCurveInstance, AudioEffectInstance)

public:
	static constexpr int kStages = 4;

	struct Shared {
		std::atomic<uint32_t> reset_epoch{ 0 }; // bumped by the main thread; each instance clears on a change
		std::atomic<uint64_t> blocks{ 0 };
	};

	/// MAIN THREAD. Designs the curve for `p_mix_rate` and sizes every buffer.
	void setup(const std::shared_ptr<Shared> &p_shared, double p_mix_rate);

	/// AUDIO THREAD. See rt.h.
	void _process(const void *p_src_buffer, AudioFrame *r_dst_buffer, int32_t p_frame_count) override;
	/// The delay lines still hold the last 8 ms when the input stops; they have to play out.
	bool _process_silence() const override;

	/// Boxcar length M, and the mid bell's and high rolloff's FIR lengths, for a mix rate. The combined
	/// FIR is mid + high - 1 taps; latency is 2 (M - 1) + (mid + high - 2) / 2.
	static void design(double p_mix_rate, int &r_boxcar, int &r_mid, int &r_high);

protected:
	static void _bind_methods();

private:
	void _clear();

	std::shared_ptr<Shared> _keep;
	Shared *_shared = nullptr;
	uint32_t _epoch = UINT32_MAX;
	int _m = 1;
	int _n = 1; // the combined mid + high FIR
	int _npad = 8;
	int _d1 = 0;
	float _gl_minus_1 = 0.0f;
	std::vector<float> _fir; // _npad taps, zero past _n
	// per channel: kStages boxcar rings of _m, their exact sums, the D1 delay ring, the FIR history
	std::vector<float> _box[2][kStages];
	double _sum[2][kStages] = {};
	std::vector<float> _xdelay[2];
	std::vector<float> _hist[2]; // 2 * _n + _npad: every sample written twice, so a window is contiguous
	int _box_at = 0;
	int _xd_at = 0;
	int _h_at = 0;
};

class SsCasualCurve : public AudioEffect {
	GDCLASS(SsCasualCurve, AudioEffect)

public:
	SsCasualCurve();

	/// MAIN THREAD. Clears the delay lines at the next block: call it before switching the curve in,
	/// or the first 8 ms would be whatever was playing the last time it was on.
	void reset();
	int get_latency_frames() const;
	uint64_t get_blocks() const;

	Ref<AudioEffectInstance> _instantiate() override;

protected:
	static void _bind_methods();

private:
	std::shared_ptr<SsCasualCurveInstance::Shared> _shared;
};

} // namespace godot

#endif // SOUNDSCAPE_SS_CASUAL_H
