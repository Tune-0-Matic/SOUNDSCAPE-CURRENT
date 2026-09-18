/**************************************************************************/
/*  ss_parallel.h                                                         */
/*  SsParallel -- a true parallel wet/dry split on a serial bus.          */
/**************************************************************************/
//
// A Godot bus is a serial chain, so an FX module's MIX used to be a depth control on the effect
// itself -- a notch made shallower, a distortion driven less -- which is not a dry signal at all.
// This gives every rack module a real parallel path using two effects around it:
//
//   [TAP] -> module effects (the WET path, run at full strength) -> [BLEND] -> ...
//
//   TAP    copies the block it is handed, untouched, into memory both halves share, and passes
//          it on unchanged
//   BLEND  outputs  wet * mix + dry * (1 - mix): a LINEAR crossfade, constant sum. Equal-power
//          would lift the middle by 3 dB on every correlated module (a filter, a pan, a pumper),
//          which is most of the rack
//
// Both run on the audio thread inside ONE bus mix, in bus order, on the same block, so the dry copy
// BLEND reads is always the block TAP saw moments earlier. MIX crosses from the main thread as an
// atomic and is ramped across each block, so a fader drag does not zipper.
//
// ponytail: no latency compensation. A module whose wet path delays the signal (the pitch
// shifters) sums against an undelayed dry at mid MIX; matching it needs the module's latency.
// ponytail: one shared block, so a pair serves a stereo bus; a surround bus's extra channel pairs
// each get their own instance but would share -- and trample -- this one buffer.

#ifndef SOUNDSCAPE_SS_PARALLEL_H
#define SOUNDSCAPE_SS_PARALLEL_H

#include <godot_cpp/classes/audio_effect.hpp>
#include <godot_cpp/classes/audio_effect_instance.hpp>
#include <godot_cpp/classes/audio_frame.hpp>
#include <godot_cpp/core/class_db.hpp>

#include <atomic>
#include <memory>
#include <vector>

namespace godot {

class SsParallelInstance : public AudioEffectInstance {
	GDCLASS(SsParallelInstance, AudioEffectInstance)

public:
	/// Largest block the pair can split; bigger ones pass wet only. AudioServer mixes 512 at a time.
	static constexpr int32_t kMaxBlock = 16384;

	struct Shared {
		std::vector<AudioFrame> dry; // sized once, on the main thread
		int32_t dry_frames = 0; // written by TAP, read by BLEND -- both on the audio thread, in order
		std::atomic<float> mix{ 1.0f };
		std::atomic<uint64_t> split_blocks{ 0 };
		std::atomic<uint64_t> oversize_blocks{ 0 };
	};

	void setup(const std::shared_ptr<Shared> &p_shared, bool p_blend);

	/// AUDIO THREAD. See rt.h.
	void _process(const void *p_src_buffer, AudioFrame *r_dst_buffer, int32_t p_frame_count) override;
	/// A reverb tail keeps sounding after its input stops, so both halves keep running too.
	bool _process_silence() const override;

protected:
	static void _bind_methods();

private:
	std::shared_ptr<Shared> _keep; // keeps the block alive (not _owner: Wrapped already has one)
	Shared *_shared = nullptr;
	bool _blend = false;
	float _mix_now = 1.0f; // the mix the last block ended on, ramped from
};

class SsParallel : public AudioEffect {
	GDCLASS(SsParallel, AudioEffect)

public:
	SsParallel();

	/// The BLEND half for this TAP: a new effect sharing this one's dry buffer and MIX.
	Ref<SsParallel> make_blend() const;
	bool is_blend() const { return _blend; }

	void set_mix(float p_mix);
	float get_mix() const;
	uint64_t get_split_blocks() const;
	uint64_t get_oversize_blocks() const;

	Ref<AudioEffectInstance> _instantiate() override;

protected:
	static void _bind_methods();

private:
	std::shared_ptr<SsParallelInstance::Shared> _shared;
	bool _blend = false;
};

} // namespace godot

#endif // SOUNDSCAPE_SS_PARALLEL_H
