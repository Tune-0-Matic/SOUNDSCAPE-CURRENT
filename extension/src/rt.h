/**************************************************************************/
/*  rt.h                                                                  */
/*  The real-time contract: what may cross the thread boundary, and how.  */
/**************************************************************************/
//
// Everything in this header exists to serve one rule: SsEffectInstance::_process
// runs on the audio thread, and the audio thread must never block, never allocate,
// and never touch anything that can. There is no error recovery on that thread --
// a missed deadline is a click in the user's speakers, and there is no way to
// un-hear it.
//
// FORBIDDEN inside _process, without exception:
//   - operator new / delete / malloc / free, directly or via a container that grows
//   - std::mutex, std::condition_variable, any lock at all
//   - file, socket or console I/O, including UtilityFunctions::print
//   - any Godot API that can touch the ObjectDB, allocate a Variant, or emit a signal
//   - exceptions, and anything that can throw
//   - unbounded loops
//
// PERMITTED: arithmetic over buffers that were sized once in the constructor, and
// draining a BOUNDED number of messages from an SpscRing.
//
// This mirrors the discipline that already makes fx_rack.gd safe (every effect
// created once in setup(), never at runtime) -- moved one layer down, to where the
// samples actually are.

#ifndef SOUNDSCAPE_RT_H
#define SOUNDSCAPE_RT_H

#include <atomic>
#include <cstddef>
#include <cstdint>

namespace soundscape {

// Cache line on every platform this ships to. Head and tail are separated by one so
// the producer's write to head does not invalidate the consumer's cache line holding
// tail -- false sharing on a 48 kHz callback is measurable, not theoretical.
static constexpr std::size_t kCacheLine = 64;

/**
 * Parameter update, main thread -> audio thread.
 *
 * POD only, and deliberately so: no std::string, no vector, no Ref<>, nothing with a
 * destructor. This struct is memcpy'd into a ring buffer by one thread and read out
 * by another with no synchronisation beyond the ring's own atomics, which is only
 * sound because copying it cannot run code.
 *
 * 16 bytes, which is two per cache line pair and lets the whole ring stay small.
 */
struct ParamMsg {
	uint16_t module_id = 0;
	uint16_t param_id = 0;
	float value = 0.0f;
	// Frame the change should take effect on, in the instance's own frame counter.
	// Unused by the pass-through milestone; it is here because retrofitting
	// sample-accurate automation into a message format later means a format version,
	// and a 4-byte field now costs nothing.
	uint32_t frame_stamp = 0;
	uint32_t reserved = 0;
};

static_assert(sizeof(ParamMsg) == 16, "ParamMsg must stay 16 bytes");

/**
 * Single-producer / single-consumer lock-free ring.
 *
 * One writer (main thread) and one reader (audio thread) ONLY. Two writers will
 * corrupt it silently; that is the trade for needing no locks at all.
 *
 * A full ring DROPS the incoming message and returns false. That is the correct
 * failure: a dropped knob update is one frame of staleness that the next update
 * fixes, where blocking the producer until the audio thread catches up would stall
 * the UI, and blocking the consumer would be a dropout. Nothing in this program has
 * a parameter stream dense enough to fill 256 slots between two audio callbacks --
 * the UI writes at frame rate, the callback drains at buffer rate.
 *
 * N must be a power of two so the index wrap is a mask rather than a modulo.
 */
template <typename T, std::size_t N>
class SpscRing {
	static_assert((N & (N - 1)) == 0, "SpscRing capacity must be a power of two");
	static_assert(N >= 2, "SpscRing needs at least two slots");

public:
	SpscRing() = default;
	SpscRing(const SpscRing &) = delete;
	SpscRing &operator=(const SpscRing &) = delete;

	/// Producer side. Main thread only. Never blocks; returns false when full.
	bool push(const T &item) {
		const uint32_t head = _head.load(std::memory_order_relaxed);
		const uint32_t next = (head + 1) & kMask;
		// acquire: the tail we read must not be reordered after the slot write below
		if (next == _tail.load(std::memory_order_acquire)) {
			return false; // full -- drop, see the note above
		}
		_buf[head] = item;
		// release: the slot write must be visible before the consumer sees the new head
		_head.store(next, std::memory_order_release);
		return true;
	}

	/// Consumer side. Audio thread only. Never blocks; returns false when empty.
	bool pop(T &out) {
		const uint32_t tail = _tail.load(std::memory_order_relaxed);
		if (tail == _head.load(std::memory_order_acquire)) {
			return false; // empty
		}
		out = _buf[tail];
		_tail.store((tail + 1) & kMask, std::memory_order_release);
		return true;
	}

	/// Bounded drain, so a flooded ring can never stretch one audio callback.
	/// Returns how many were consumed.
	template <typename Fn>
	uint32_t drain(uint32_t max_items, Fn &&fn) {
		T msg;
		uint32_t n = 0;
		while (n < max_items && pop(msg)) {
			fn(msg);
			++n;
		}
		return n;
	}

	bool is_lock_free() const { return _head.is_lock_free() && _tail.is_lock_free(); }

private:
	static constexpr uint32_t kMask = static_cast<uint32_t>(N - 1);

	alignas(kCacheLine) std::atomic<uint32_t> _head{ 0 }; // producer writes
	alignas(kCacheLine) std::atomic<uint32_t> _tail{ 0 }; // consumer writes
	alignas(kCacheLine) T _buf[N]{};
};

/**
 * What the audio thread hands back: peak and RMS per block, for meters.
 *
 * Same POD rule. This is the channel Pillar 4's FFT tap will widen -- it is here now
 * so the pass-through milestone proves both directions of the boundary, not just one.
 */
struct MeterMsg {
	float peak_left = 0.0f;
	float peak_right = 0.0f;
	float rms = 0.0f;
	uint32_t frames = 0;
};

static_assert(sizeof(MeterMsg) == 16, "MeterMsg must stay 16 bytes");

using ParamRing = SpscRing<ParamMsg, 256>;
using MeterRing = SpscRing<MeterMsg, 64>;

/// Messages drained per callback. Bounded so a UI that floods the ring cannot
/// lengthen one audio block; leftovers are simply handled on the next one.
static constexpr uint32_t kMaxDrainPerBlock = 64;

} // namespace soundscape

#endif // SOUNDSCAPE_RT_H
