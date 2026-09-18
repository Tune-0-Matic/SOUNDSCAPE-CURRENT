/**************************************************************************/
/*  ss_parallel.cpp                                                       */
/**************************************************************************/

#include "ss_parallel.h"

#include <algorithm>
#include <cstring>

using namespace godot;

/**************************************************************************/
/* SsParallelInstance -- audio thread                                     */
/**************************************************************************/

void SsParallelInstance::setup(const std::shared_ptr<Shared> &p_shared, bool p_blend) {
	_keep = p_shared;
	_shared = p_shared.get();
	_blend = p_blend;
	_mix_now = _shared->mix.load();
}

void SsParallelInstance::_process(const void *p_src_buffer, AudioFrame *r_dst_buffer, int32_t p_frame_count) {
	// ===================== AUDIO THREAD -- RT CONTRACT APPLIES =====================
	const AudioFrame *src = static_cast<const AudioFrame *>(p_src_buffer);
	if (src == nullptr || r_dst_buffer == nullptr || p_frame_count <= 0 || _shared == nullptr) {
		return;
	}
	if (!_blend) {
		if (p_frame_count <= kMaxBlock) {
			std::memcpy(_shared->dry.data(), src, size_t(p_frame_count) * sizeof(AudioFrame));
			_shared->dry_frames = p_frame_count;
		} else {
			_shared->dry_frames = 0;
			_shared->oversize_blocks.fetch_add(1, std::memory_order_relaxed);
		}
		if (src != r_dst_buffer) {
			std::memcpy(r_dst_buffer, src, size_t(p_frame_count) * sizeof(AudioFrame));
		}
		return;
	}

	const float target = std::clamp(_shared->mix.load(std::memory_order_relaxed), 0.0f, 1.0f);
	if (_shared->dry_frames != p_frame_count) {
		// no dry copy for this block (oversize, or the tap was switched out alone): wet only
		if (src != r_dst_buffer) {
			std::memcpy(r_dst_buffer, src, size_t(p_frame_count) * sizeof(AudioFrame));
		}
		_mix_now = target;
		return;
	}
	const AudioFrame *dry = _shared->dry.data();
	if (_mix_now == target) {
		// the steady state is exact: MIX 1 is the wet signal bit for bit, MIX 0 the dry one
		const float keep = 1.0f - target;
		for (int32_t i = 0; i < p_frame_count; ++i) {
			r_dst_buffer[i].left = src[i].left * target + dry[i].left * keep;
			r_dst_buffer[i].right = src[i].right * target + dry[i].right * keep;
		}
	} else {
		const float from = _mix_now;
		const float span = target - from;
		for (int32_t i = 0; i < p_frame_count; ++i) {
			const float m = from + span * (float(i + 1) / float(p_frame_count));
			const float keep = 1.0f - m;
			r_dst_buffer[i].left = src[i].left * m + dry[i].left * keep;
			r_dst_buffer[i].right = src[i].right * m + dry[i].right * keep;
		}
		_mix_now = target;
	}
	_shared->split_blocks.fetch_add(1, std::memory_order_relaxed);
}

bool SsParallelInstance::_process_silence() const {
	return true;
}

void SsParallelInstance::_bind_methods() {}

/**************************************************************************/
/* SsParallel -- main thread                                              */
/**************************************************************************/

SsParallel::SsParallel() {
	_shared = std::make_shared<SsParallelInstance::Shared>();
	_shared->dry.assign(size_t(SsParallelInstance::kMaxBlock), AudioFrame{ 0.0f, 0.0f });
}

Ref<SsParallel> SsParallel::make_blend() const {
	Ref<SsParallel> blend;
	blend.instantiate();
	blend->_shared = _shared; // the constructor's own block is released here, before any audio runs
	blend->_blend = true;
	return blend;
}

void SsParallel::set_mix(float p_mix) {
	_shared->mix.store(std::clamp(p_mix, 0.0f, 1.0f));
}

float SsParallel::get_mix() const {
	return _shared->mix.load();
}

uint64_t SsParallel::get_split_blocks() const {
	return _shared->split_blocks.load(std::memory_order_relaxed);
}

uint64_t SsParallel::get_oversize_blocks() const {
	return _shared->oversize_blocks.load(std::memory_order_relaxed);
}

Ref<AudioEffectInstance> SsParallel::_instantiate() {
	Ref<SsParallelInstance> instance;
	instance.instantiate();
	instance->setup(_shared, _blend);
	return instance;
}

void SsParallel::_bind_methods() {
	ClassDB::bind_method(D_METHOD("make_blend"), &SsParallel::make_blend);
	ClassDB::bind_method(D_METHOD("is_blend"), &SsParallel::is_blend);
	ClassDB::bind_method(D_METHOD("set_mix", "mix"), &SsParallel::set_mix);
	ClassDB::bind_method(D_METHOD("get_mix"), &SsParallel::get_mix);
	ClassDB::bind_method(D_METHOD("get_split_blocks"), &SsParallel::get_split_blocks);
	ClassDB::bind_method(D_METHOD("get_oversize_blocks"), &SsParallel::get_oversize_blocks);
}
