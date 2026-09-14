/**************************************************************************/
/*  ss_effect.h                                                           */
/*  SsEffect / SsEffectInstance -- the pass-through milestone.            */
/**************************************************************************/
//
// The bridge that exists to close the ceiling documented in fx_rack.gd:
//
//   AudioEffectInstance._process, as seen from GDScript, is
//     _process(src_buffer: int, r_dst_buffer: int, frame_count: int)
//   because GDExtension marshals pointers through Variant and Variant has no
//   pointer type. There is no cast in GDScript that recovers them.
//
// In C++ the same virtual is emitted by godot-cpp as
//   virtual void _process(const void *p_src_buffer, AudioFrame *r_dst_buffer,
//                         int32_t p_frame_count);
// with AudioFrame declared in extension_api.json's native_structures block as
//   { float left; float right; }
// Verified against Godot v4.7.1.stable.official -- see extension/STEP0.md.
//
// THIS CLASS DOES NOTHING TO THE AUDIO ON PURPOSE. It is the milestone, not a
// feature: if a bit-identical copy through the real bus chain does not hold, no
// DSP written on top of it can be trusted either. Every kernel that follows
// (gate, crusher, FFT tap) replaces the copy in _process and changes nothing else.

#ifndef SOUNDSCAPE_SS_EFFECT_H
#define SOUNDSCAPE_SS_EFFECT_H

#include <godot_cpp/classes/audio_effect.hpp>
#include <godot_cpp/classes/audio_effect_instance.hpp>
#include <godot_cpp/classes/audio_frame.hpp>
#include <godot_cpp/core/class_db.hpp>

#include "rt.h"

#include <atomic>
#include <memory>

namespace godot {

class SsEffect;

/**
 * The audio-thread half. One per bus the effect is inserted on.
 *
 * Holds no Ref<> to its owning SsEffect and never calls back into it: the resource
 * lives on the main thread and touching it from here would mean refcount traffic on
 * the audio thread, which is an atomic RMW at best and a free() at worst.
 * Communication is one-way through the rings, which are owned by a shared block that
 * outlives both (see SharedState).
 */
class SsEffectInstance : public AudioEffectInstance {
	GDCLASS(SsEffectInstance, AudioEffectInstance)

public:
	/// Rings + anything both halves read. Heap-allocated ONCE when the effect is
	/// instantiated, and kept alive by a shared_ptr held on both sides, so the audio
	/// thread can never observe a dangling pointer if the resource is freed mid-block.
	/// The shared_ptr is copied on the MAIN thread only; the audio thread only ever
	/// dereferences the raw pointer it captured at construction.
	struct SharedState {
		soundscape::ParamRing params;
		soundscape::MeterRing meters;
		// Diagnostics, written by the audio thread, read by the harness. Relaxed
		// ordering throughout: these are counters, not synchronisation.
		std::atomic<uint64_t> frames_processed{ 0 };
		std::atomic<uint64_t> blocks_processed{ 0 };
		std::atomic<uint32_t> max_block_seen{ 0 };
		std::atomic<uint32_t> params_dropped{ 0 };
		// Set false by the audio thread the first time it is handed a null buffer,
		// so the harness can distinguish "never ran" from "ran and was fed nothing".
		std::atomic<bool> saw_null_buffer{ false };
	};

	SsEffectInstance();
	~SsEffectInstance() override = default;

	/// AUDIO THREAD. See the contract in rt.h. Nothing in here allocates or locks.
	void _process(const void *p_src_buffer, AudioFrame *r_dst_buffer,
			int32_t p_frame_count) override;

	/// Returning false means Godot stops calling _process once the bus goes silent.
	/// The pass-through wants to keep running so the harness can count blocks over a
	/// gap; a reverb tail would want the same for a real reason.
	bool _process_silence() const override;

	void set_shared(const std::shared_ptr<SharedState> &p_shared);

protected:
	static void _bind_methods();

private:
	std::shared_ptr<SharedState> _shared_owner; // keeps the block alive
	SharedState *_shared = nullptr; // what the audio thread actually touches
	// Local mirror of whatever the params ring carries. Unused by the pass-through;
	// present so the drain path is exercised and measured from day one rather than
	// bolted on with the first kernel.
	float _gain = 1.0f;
};

/**
 * The main-thread half: a Resource, so it saves into a scene or a preset like any
 * other AudioEffect, and so player.gd can hold it in exactly the same way it holds
 * the stock effects in fx_rack.gd.
 */
class SsEffect : public AudioEffect {
	GDCLASS(SsEffect, AudioEffect)

public:
	SsEffect();
	~SsEffect() override = default;

	/// Called by the server when the effect is inserted on a bus. REQUIRED virtual.
	Ref<AudioEffectInstance> _instantiate() override;

	// --- diagnostics, main thread only; all cheap relaxed atomic reads -------------
	uint64_t get_frames_processed() const;
	uint64_t get_blocks_processed() const;
	uint32_t get_max_block_seen() const;
	uint32_t get_params_dropped() const;
	bool get_saw_null_buffer() const;
	void reset_counters();

	/// Pushes one parameter message across the boundary. Returns false if the ring was
	/// full, which is information the caller is entitled to rather than a silent drop.
	bool push_param(int p_module_id, int p_param_id, float p_value);

	/// True when the ring reported itself lock-free on this platform. If this is ever
	/// false, the RT contract is broken on that target and the extension must not ship
	/// there -- std::atomic<uint32_t> falling back to a mutex is exactly the failure
	/// this whole design exists to avoid.
	bool is_lock_free() const;

protected:
	static void _bind_methods();

private:
	std::shared_ptr<SsEffectInstance::SharedState> _shared;
};

} // namespace godot

#endif // SOUNDSCAPE_SS_EFFECT_H
