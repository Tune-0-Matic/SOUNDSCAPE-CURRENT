/**************************************************************************/
/*  ss_effect.cpp                                                         */
/**************************************************************************/

#include "ss_effect.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cstring>

using namespace godot;

/**************************************************************************/
/* SsEffectInstance -- the audio thread                                   */
/**************************************************************************/

SsEffectInstance::SsEffectInstance() {}

void SsEffectInstance::set_shared(const std::shared_ptr<SharedState> &p_shared) {
	// MAIN THREAD ONLY, before the instance is handed to the server. The raw pointer
	// is what _process uses; the shared_ptr beside it is only there to guarantee the
	// block outlives every thread that can still reach it.
	_shared_owner = p_shared;
	_shared = p_shared.get();
}

bool SsEffectInstance::_process_silence() const {
	return true;
}

void SsEffectInstance::_process(const void *p_src_buffer, AudioFrame *r_dst_buffer,
		int32_t p_frame_count) {
	// ===================== AUDIO THREAD -- RT CONTRACT APPLIES =====================
	// No allocation. No locks. No Godot API. No printing. No exceptions. Nothing here
	// may take an unbounded amount of time. See rt.h for the full list.
	// ==============================================================================

	if (_shared == nullptr) {
		return;
	}

	// Godot hands the source as const void* because the buffer's real layout is the
	// server's business, not ours. For a stereo bus it is AudioFrame-shaped: two
	// interleaved floats per frame, which is exactly what the destination is. The
	// cast is the whole reason this class is in C++ and not GDScript.
	const AudioFrame *src = static_cast<const AudioFrame *>(p_src_buffer);

	if (src == nullptr || r_dst_buffer == nullptr || p_frame_count <= 0) {
		// A null buffer is not an error to report from here -- reporting means I/O.
		// It is recorded in a flag the main thread reads at its leisure.
		_shared->saw_null_buffer.store(true, std::memory_order_relaxed);
		return;
	}

	// Bounded drain. The pass-through has no parameters yet; running the drain anyway
	// means the boundary is exercised and counted by the milestone rather than first
	// being tried by the gate.
	const uint32_t drained = _shared->params.drain(soundscape::kMaxDrainPerBlock,
			[this](const soundscape::ParamMsg &m) {
				if (m.param_id == 0) {
					_gain = m.value;
				}
			});
	(void)drained;

	// ---- the kernel ----------------------------------------------------------
	// A pass-through, and deliberately a LITERAL one: sample in, same sample out, no
	// gain applied even though _gain is sitting right there. Multiplying by 1.0f is
	// exact in IEEE-754, but a kernel that reads a parameter is a kernel whose output
	// depends on a race, and the point of this milestone is an assertion that cannot
	// be argued with. _gain is written above and read by nothing until a real kernel
	// lands here.
	//
	// std::memcpy rather than a loop: same result, and it lets the compiler use the
	// widest move it has without anyone hand-writing intrinsics. It allocates nothing
	// and cannot throw.
	std::memcpy(r_dst_buffer, src, static_cast<size_t>(p_frame_count) * sizeof(AudioFrame));

	// ---- meters, for the harness --------------------------------------------
	// One pass, no branches worth predicting. This is the only work the pass-through
	// does beyond the copy, and it exists so the verification has something to read
	// that proves the callback ran on real audio and not on silence.
	float peak_l = 0.0f;
	float peak_r = 0.0f;
	float sum_sq = 0.0f;
	for (int32_t i = 0; i < p_frame_count; ++i) {
		const float l = src[i].left;
		const float r = src[i].right;
		const float al = l < 0.0f ? -l : l;
		const float ar = r < 0.0f ? -r : r;
		if (al > peak_l) {
			peak_l = al;
		}
		if (ar > peak_r) {
			peak_r = ar;
		}
		sum_sq += l * l + r * r;
	}

	soundscape::MeterMsg meter;
	meter.peak_left = peak_l;
	meter.peak_right = peak_r;
	// No sqrt of a zero-length block: p_frame_count > 0 is guaranteed above.
	meter.rms = sum_sq / static_cast<float>(p_frame_count * 2);
	meter.frames = static_cast<uint32_t>(p_frame_count);
	if (!_shared->meters.push(meter)) {
		// Nobody drained the meter ring. Not an error -- the UI is simply not looking.
	}

	const uint32_t block = static_cast<uint32_t>(p_frame_count);
	if (block > _shared->max_block_seen.load(std::memory_order_relaxed)) {
		_shared->max_block_seen.store(block, std::memory_order_relaxed);
	}
	_shared->frames_processed.fetch_add(block, std::memory_order_relaxed);
	_shared->blocks_processed.fetch_add(1, std::memory_order_relaxed);
}

void SsEffectInstance::_bind_methods() {}

/**************************************************************************/
/* SsEffect -- the main thread                                            */
/**************************************************************************/

SsEffect::SsEffect() {
	// The one allocation in the whole design, and it happens here: on the main thread,
	// when the resource is constructed, long before any audio flows.
	_shared = std::make_shared<SsEffectInstance::SharedState>();
}

Ref<AudioEffectInstance> SsEffect::_instantiate() {
	Ref<SsEffectInstance> ins;
	ins.instantiate();
	ins->set_shared(_shared);
	return ins;
}

uint64_t SsEffect::get_frames_processed() const {
	return _shared->frames_processed.load(std::memory_order_relaxed);
}

uint64_t SsEffect::get_blocks_processed() const {
	return _shared->blocks_processed.load(std::memory_order_relaxed);
}

uint32_t SsEffect::get_max_block_seen() const {
	return _shared->max_block_seen.load(std::memory_order_relaxed);
}

uint32_t SsEffect::get_params_dropped() const {
	return _shared->params_dropped.load(std::memory_order_relaxed);
}

bool SsEffect::get_saw_null_buffer() const {
	return _shared->saw_null_buffer.load(std::memory_order_relaxed);
}

void SsEffect::reset_counters() {
	_shared->frames_processed.store(0, std::memory_order_relaxed);
	_shared->blocks_processed.store(0, std::memory_order_relaxed);
	_shared->max_block_seen.store(0, std::memory_order_relaxed);
	_shared->params_dropped.store(0, std::memory_order_relaxed);
	_shared->saw_null_buffer.store(false, std::memory_order_relaxed);
}

bool SsEffect::push_param(int p_module_id, int p_param_id, float p_value) {
	soundscape::ParamMsg msg;
	msg.module_id = static_cast<uint16_t>(p_module_id);
	msg.param_id = static_cast<uint16_t>(p_param_id);
	msg.value = p_value;
	if (!_shared->params.push(msg)) {
		_shared->params_dropped.fetch_add(1, std::memory_order_relaxed);
		return false;
	}
	return true;
}

bool SsEffect::is_lock_free() const {
	return _shared->params.is_lock_free() && _shared->meters.is_lock_free();
}

void SsEffect::_bind_methods() {
	ClassDB::bind_method(D_METHOD("get_frames_processed"), &SsEffect::get_frames_processed);
	ClassDB::bind_method(D_METHOD("get_blocks_processed"), &SsEffect::get_blocks_processed);
	ClassDB::bind_method(D_METHOD("get_max_block_seen"), &SsEffect::get_max_block_seen);
	ClassDB::bind_method(D_METHOD("get_params_dropped"), &SsEffect::get_params_dropped);
	ClassDB::bind_method(D_METHOD("get_saw_null_buffer"), &SsEffect::get_saw_null_buffer);
	ClassDB::bind_method(D_METHOD("reset_counters"), &SsEffect::reset_counters);
	ClassDB::bind_method(D_METHOD("push_param", "module_id", "param_id", "value"),
			&SsEffect::push_param);
	ClassDB::bind_method(D_METHOD("is_lock_free"), &SsEffect::is_lock_free);
}
