# SOUNDSCAPE (HEADLESS HORSEMAN)
## Technical Master Manual and Architecture Guide

**Version:** V1.6 BETA · **Engine:** Godot 4.7.1 · **Native layer:** `libsoundscape_dsp` (C++ GDExtension, godot-cpp @ `6cceaf6`)
**Platforms:** Windows x86-64, Linux x86-64 · **Document revision:** 2026-09-19

---

### How to read this document

Every code block below is quoted from the working tree, not paraphrased. Where a design is
unusual, the reason is given — this codebase has a habit of writing the reason next to the code,
and this manual preserves that rather than flattening it into a feature list. Where something is
a known limitation, it says so; those are marked **ponytail** in the source and are reproduced
here under the same name.

**Contents**

1. [Architecture & DSP Pipeline (C++ / GDExtension)](#1-architecture--dsp-pipeline-c--gdextension)
2. [System Architecture & Deck Controllers (GDScript)](#2-system-architecture--deck-controllers-gdscript)
3. [User Interface & Settings](#3-user-interface--settings)
4. [Build System & Cross-Platform CI/CD](#4-build-system--cross-platform-cicd)
5. [User Guide & API Reference](#5-user-guide--api-reference)
6. [Appendices](#6-appendices)

---

## 0. What SOUNDSCAPE is

SOUNDSCAPE is a two-deck audiophile music player with a 90s terminal aesthetic. It is one Godot
project (37 GDScript files, ~17,250 lines) sitting on one native extension (12 C++ translation
units plus two vendored single-header decoders, ~25,000 lines including `dr_flac.h` and
`dr_wav.h`).

The division of labour is strict and worth stating up front, because almost every design decision
downstream follows from it:

| Layer | Owns | Never does |
|---|---|---|
| `libsoundscape_dsp` (C++) | Sample-rate conversion, FLAC/WAV/DSD decoding, the CASUAL curve, parallel wet/dry splitting | Allocate, lock or log on the audio thread |
| `AudioEngine` (GDScript) | Queue, decks, buses, metadata, the library index, worker threads | Touch samples |
| `DeckController` (GDScript) | Which player is sounding, crossfades, REV, auto-advance faults | Own any Control |
| `LibraryModel` (GDScript) | Roots, paths, index, sorting, filters, playlists/cues/labels | Own any Control |
| `player.gd` (GDScript) | Every Control, every setting, every drawing routine | Own library or deck state |

`player.gd` is still the largest file at 7,982 lines, and that is deliberate: it is the UI, and the
UI of this program is genuinely large. What it no longer contains is the *model*.

---

## 1. ARCHITECTURE & DSP PIPELINE (C++ / GDExtension)

### 1.1 The extension boundary and entry symbol

The engine's entire knowledge of the native layer passes through one exported C function, named in
`soundscape.gdextension` as `entry_symbol`:

```cpp
extern "C" {
// The symbol named by soundscape.gdextension's `entry_symbol`. If these two ever
// disagree the library loads and then silently registers nothing, which presents as
// "SsEffect does not exist" with no error anywhere -- so they are checked by
// test_ss_effect.gd rather than trusted.
GDExtensionBool GDE_EXPORT soundscape_dsp_init(
        GDExtensionInterfaceGetProcAddress p_get_proc_address,
        const GDExtensionClassLibraryPtr p_library,
        GDExtensionInitialization *r_initialization) {
    godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

    init_obj.register_initializer(initialize_soundscape_dsp);
    init_obj.register_terminator(uninitialize_soundscape_dsp);
    init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

    return init_obj.init();
}
}
```

The failure mode called out in that comment is the reason the CI workflow runs
`nm -D --defined-only | grep -qw soundscape_dsp_init` on every build: a mismatched entry symbol is
not a load error, it is *silence*.

**Registration order is load-bearing.** An `AudioEffect` subclass that returns an instance type
from `_instantiate()` cannot be registered before that instance type exists:

```cpp
void initialize_soundscape_dsp(ModuleInitializationLevel p_level) {
    // SCENE is the level AudioEffect and its friends exist at. Registering earlier
    // means registering against a ClassDB that has not seen our base class yet.
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }

    // Order matters: the instance type must exist before the resource that returns it
    // from _instantiate, or the return type cannot be resolved.
    GDREGISTER_CLASS(SsEffectInstance);
    GDREGISTER_CLASS(SsEffect);
    GDREGISTER_CLASS(SsFlacPlayback);
    GDREGISTER_CLASS(SsFlacStream);
    GDREGISTER_CLASS(SsWavPlayback);
    GDREGISTER_CLASS(SsWavStream);
    GDREGISTER_CLASS(SsDsdPlayback);
    GDREGISTER_CLASS(SsDsdStream);
    GDREGISTER_CLASS(SsParallelInstance);
    GDREGISTER_CLASS(SsParallel);
    GDREGISTER_CLASS(SsCasualCurveInstance);
    GDREGISTER_CLASS(SsCasualCurve);
}
```

#### 1.1.1 The shutdown crash, and why teardown is not empty

Godot 4.7's `Main::cleanup` deinitializes extensions **before** `audio_server->finish()`. An effect
of ours still attached to a bus at quit was therefore destroyed *after* its class had been
unregistered — a dangling vtable pointer that crashed roughly one exit in ten:

```cpp
    // But the EFFECTS can outlive us. Godot 4.7's Main::cleanup deinitializes extensions at this level
    // BEFORE audio_server->finish() frees the buses, so an SsParallel, SsCasualCurve or SsEffect still
    // on a bus at quit was destroyed after its class had been unregistered -- a dangling pointer that
    // crashed about one exit in ten (measured 2026-09-16 with the CASUAL curve left on Master). The
    // server is still alive here, so every effect of ours comes off every bus now, while its class exists.
    AudioServer *server = AudioServer::get_singleton();
    if (server == nullptr) {
        return;
    }
    for (int32_t bus = server->get_bus_count() - 1; bus >= 0; --bus) {
        for (int32_t i = server->get_bus_effect_count(bus) - 1; i >= 0; --i) {
            const Ref<AudioEffect> effect = server->get_bus_effect(bus, i);
            if (Object::cast_to<SsParallel>(effect.ptr()) || Object::cast_to<SsCasualCurve>(effect.ptr())
                    || Object::cast_to<SsEffect>(effect.ptr())) {
                server->remove_bus_effect(bus, i);
            }
        }
    }
```

There is deliberately **no global state** in the extension. Every `SharedState` is owned by its
effect's `shared_ptr` and dies with it, because a static outliving the audio server is the same
class of shutdown crash arriving from the other direction.

### 1.2 The real-time contract (`rt.h`)

`rt.h` is not a utility header; it is the written constitution of the audio thread.

```
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
```

Parameters cross the thread boundary through a single-producer / single-consumer lock-free ring.
The message is POD by contract — it is `memcpy`'d between threads with no synchronisation beyond
the ring's own atomics, which is only sound because copying it cannot run code:

```cpp
struct ParamMsg {
    uint16_t module_id = 0;
    uint16_t param_id = 0;
    float value = 0.0f;
    uint32_t frame_stamp = 0;
    uint32_t reserved = 0;
};

static_assert(sizeof(ParamMsg) == 16, "ParamMsg must stay 16 bytes");
```

The ring's push is the interesting half, because its memory ordering is the whole correctness
argument:

```cpp
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
```

Three design decisions worth understanding:

- **A full ring drops the message.** That is the correct failure. A dropped knob update is one
  frame of staleness the next update fixes; blocking the producer stalls the UI, and blocking the
  consumer is a dropout.
- **Capacity is a power of two** (`ParamRing = SpscRing<ParamMsg, 256>`) so the index wrap is a
  mask rather than a modulo.
- **Head and tail are `alignas(64)`** — separate cache lines. False sharing on a 48 kHz callback is
  measurable, not theoretical.

Draining is bounded so a flooded ring can never stretch one callback:

```cpp
static constexpr uint32_t kMaxDrainPerBlock = 64;
```

### 1.3 Native decoding: FLAC, WAV, DSD

Godot 4.7 ships no FLAC decoder and no DSD decoder. Before the native layer, every FLAC went
through an ffmpeg transcode into a 16-bit WAV cached in `user://` — 30–120 MB per track, a process
spawn per cold track, and **24-bit sources truncated to 16 bits on the way**.

`SsFlacStream` replaces that entirely:

```
//   - the COMPRESSED file is what stays in memory; frames are decoded block by block inside
//     the mix, so there is no decoded copy and no cache file at all
//   - samples are handed over as 32-bit float, which holds every 24-bit value exactly
//   - the file's own rate is converted to the mix rate HERE, by resampler.h's windowed sinc,
//     not by Godot's cubic -- a playback at the mix rate already is a straight copy
```

#### 1.3.1 DSD (`.dsf`, `.dff`)

DSD is a 1-bit pulse-density stream at 64× or 128× the 44.1/48 kHz base rate. It is decoded in two
stages inside the mix:

```
//   1. DECIMATE: a 128-tap-per-byte-of-rate Kaiser FIR (140 dB design) over the bit stream,
//      evaluated as one table lookup per incoming byte -- the classic dsd2pcm structure, with
//      this file's own coefficients -- down to 8x base rate: 352.8 kHz (or 384 kHz)
//   2. RESAMPLE: resampler.h's windowed sinc from there to the mix rate, with the passband held
//      to 30 kHz. Above that a DSD modulator's shaped noise climbs steeply; passing it would put
//      tens of dB of ultrasonic hash into every bus effect and the analyser
```

Levels follow the format rather than being normalised: all-ones is `+1.0`, so the SACD 0 dB
reference (50 % modulation) plays at **−6 dBFS**, the way DSD is mastered. No makeup gain is
applied, because DSD routinely modulates past 50 %.

A detail that reveals the care taken: the silence byte is `0x69`, not `0x00`.

```cpp
constexpr uint8_t kDsdSilence = 0x69; // four ones, four zeros: a zero-DC byte, not "all minus one"
```

In a 1-bit stream, a zero byte is not silence — it is eight consecutive −1 samples, i.e. full-scale
DC. `0x69` alternates to give zero DC.

**ponytail (known limitations):** the whole DSD file stays in RAM — about 42 MB/minute for stereo
DSD64, 85 MB for DSD128; a streaming reader is the upgrade for long DSD128 albums. DST-compressed
DFF is refused rather than decoded, because no free DST decoder is vendored.

### 1.4 The windowed-sinc resampler

This is the heart of the AUDIOPHILE claim. Godot's `AudioStreamPlaybackResampled` uses a 4-point
cubic with a 16-bit fixed-point step. **Measured on this project:** 44.1 kHz on a 96 kHz mix ran
−19.9 ppm fast-to-slow, and a 10 kHz tone came out at roughly **−26 dB THD+N**.

The replacement:

```
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
```

Two properties matter for correctness claims:

- **Exact rational phase stepping** (`L = out/gcd`, `M = in/gcd`, advanced in integers) means there
  is *no* accumulated drift — not "small drift", none.
- **Equal rates are a straight copy, bit for bit.** A 96 kHz file on a 96 kHz mix is not resampled
  at all. This is what `test_ss_effect.gd` check 8 verifies as bit-identical output.

Measured THD+N of the native path, recorded in the autopsy constants:

```gdscript
## THD+N of the C++ sinc on the worst case test_flac_native.gd measures: an 18 kHz tone, 44.1 kHz to
## 96 kHz, 24-bit (its image, 2 kHz into the stopband). A 1 kHz tone measures -139 dB.
const AUTOPSY_SINC_THDN_DB := -124
## Godot's own 4-point cubic, measured in the 2026-09-14 audit: a 10 kHz tone, 44.1 kHz to 96 kHz.
const AUTOPSY_CUBIC_THDN_DB := -26
```

#### 1.4.1 Why the hot path is hand-vectorised

The cost of the resampler is not only a CPU-meter concern. Godot's **Dummy audio driver** — used by
every headless test — sleeps a whole number of milliseconds after each mix, never less than the
time the mix itself took. The audio clock therefore runs slow by whatever the mix spends, and the
video-sync tests that follow it drift.

```
//   - the taps run as eight explicit float lanes -- one AVX accumulator or two SSE2 ones, whichever
//     the CPU has -- in a fixed order, so every path gives the same bits (a strict-order double
//     sum does not vectorise without fast-math: it was 1.4 % of real time at 44.1 kHz)
//   - unity pitch runs its own loop on integer phases (_render_unity)
//   - the mirrored stopband above halves the taps
// Together 44.1 kHz went from 1.4 % of real time to under 0.2 %, and the video tests are back in
// line with the old cubic path.
```

The phrase **"in a fixed order, so every path gives the same bits"** is the important one: the AVX
and SSE2 paths must produce *identical* output, or the bit-exactness tests would pass on one
machine and fail on another.

### 1.5 AUDIOPHILE vs CASUAL: the listening curve

`SsCasualCurve` implements LISTENING MODE's warm profile for harsh masterings:

```
//   +2.2 dB below 120 Hz    body       (half the lift at 120 Hz)
//   -0.8 dB around 3 kHz    glare      (a bell, half depth at 2 and 4 kHz)
//   -1.5 dB from 16 kHz     a relaxed top, flat up to 8.5 kHz and rolling off between the two
```

```cpp
constexpr double kLowHz = 120.0;
constexpr double kLowDb = 2.2;
constexpr double kMidHz = 3000.0;
constexpr double kMidDb = -0.8;
constexpr double kMidHalfHz = 1000.0; // half the dip this far either side of kMidHz
constexpr double kHighPassHz = 8500.0; // flat up to here
constexpr double kHighStopHz = 16000.0; // the full rolloff from here
constexpr double kHighDb = -1.5;
constexpr double kHighAttenDb = 60.0;
```

#### 1.5.1 Phase-linear by construction

Godot's shelving and peaking biquads are minimum-phase; this curve is not. Every stage is a
**symmetric FIR**, so the whole curve delays every frequency by the same number of frames and moves
no transient:

```
//   low shelf    y1 = x[n - D1] + (gL - 1) * LP120(x)
//                LP120 is FOUR cascaded moving averages of odd length M (a near-Gaussian lowpass,
//                symmetric, O(1) a sample whatever M is), at half amplitude at 120 Hz. D1 = 2 (M - 1).
//                Sidelobes near -52 dB, scaled by gL - 1 = 0.288: about 0.001 dB of ripple above it.
//   mid recess   y2 = y1[n - Dm] + (gM - 1) * BP3k(y1)
//   high rolloff y  = gH * y2[n - Dh] + (1 - gH) * LP(y2)
```

The four cascaded boxcars are the elegant part: a moving average is **O(1) per sample regardless of
length**, and four of them cascade into a near-Gaussian lowpass. A 120 Hz linear-phase shelf that
would otherwise need a very long FIR costs four add/subtract pairs per sample per channel.

The mid and high stages are convolved into **one** symmetric FIR at design time, so the audio
thread runs the boxcars plus a single dot product. Latency is **604 frames (6.3 ms)** at 96 kHz.

The running boxcar sums are re-derived once per lap to stop floating-point drift accumulating:

```cpp
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
```

#### 1.5.2 The 150 ms crossfade, and why it blends against the *undelayed* dry

This is the single most counter-intuitive decision in the DSP layer, and the header explains it at
length because the "obvious" implementation is wrong:

```
// SWITCHING IS A RAMP, not a jump. `mix` crossfades this curve against the UNDELAYED input, so at
// mix 0 the output is the input sample for sample -- which is what lets AUDIOPHILE stay bit-exact
// even with the effect still in circuit, and lets the bus switch it out afterwards with nothing
// audible left to switch. Crossfading against the *delay-matched* dry would have been the textbook
// choice and is wrong here: both ends of that fade are 6.3 ms displaced from the real signal, so
// entering and leaving the fade are themselves the clicks this exists to remove. Against the
// undelayed dry the fade combs briefly -- a 150 ms flange, which is smooth and musical -- and both
// ends land exactly on the true signal.
```

The blend, with an explicit bit-exact branch at `mix <= 0`:

```cpp
        // one step per frame toward the target, so a mode switch is a ramp however small the block
        if (_mix != target) {
            _mix = _mix < target ? (_mix + step < target ? _mix + step : target)
                                 : (_mix - step > target ? _mix - step : target);
        }
        if (_mix >= 1.0f) {
            r_dst_buffer[i].left = float(out_l);
            r_dst_buffer[i].right = float(out_r);
        } else if (_mix <= 0.0f) {
            // EXACTLY the input: the same float back out, not a multiply by 1.0 and an add of 0.0
            r_dst_buffer[i].left = in[0];
            r_dst_buffer[i].right = in[1];
        } else {
            const float dry = 1.0f - _mix;
            r_dst_buffer[i].left = in[0] * dry + float(out_l) * _mix;
            r_dst_buffer[i].right = in[1] * dry + float(out_r) * _mix;
        }
```

`in[0]` is returned *as the same float*, not multiplied by 1.0 and added to 0.0 — because
`x * 1.0f + y * 0.0f` is not guaranteed to be bitwise `x` for every `x` (signed zeros, and any
`y` that is NaN or infinity).

The GDScript half sequences the bus switch around the ramp:

```gdscript
##   to CASUAL:     switch the effect IN at mix 0 (output is the input, sample for sample, so
##                  nothing is audible at the switch) and ramp the mix up
##   to AUDIOPHILE: ramp the mix down to 0, and only once it has arrived switch the effect OUT
##                  -- by then it is passing the input through unchanged, so again nothing is
##                  audible at the switch
```

**AUDIOPHILE remains bit-exact and zero-cost**: once the ramp lands the effect is removed from the
bus with `set_bus_effect_enabled(..., false)`, and Godot skips it entirely.

### 1.6 Parallel wet/dry: `SsParallel`

A Godot bus is a serial chain, so an FX module's MIX control was historically a *depth* control —
a notch made shallower, a distortion driven less — which is not a dry signal at all. `SsParallel`
gives every rack module a true parallel path using two effects bracketing it:

```
//   [TAP] -> module effects (the WET path, run at full strength) -> [BLEND] -> ...
//
//   TAP    copies the block it is handed, untouched, into memory both halves share, and passes
//          it on unchanged
//   BLEND  outputs  wet * mix + dry * (1 - mix): a LINEAR crossfade, constant sum. Equal-power
//          would lift the middle by 3 dB on every correlated module (a filter, a pan, a pumper),
//          which is most of the rack
```

Note the contrast with the crossfader in §2.3: **linear here, equal-power there**, and for exactly
opposite reasons. The wet and dry paths of one module are *correlated* (the same signal, processed),
so their amplitudes add and linear is correct. Two decks playing different tracks are
*uncorrelated*, so their powers add and cos/sin is correct. Using either law in the other place
produces an audible 3 dB error.

**ponytail:** no latency compensation — a module whose wet path delays the signal sums against an
undelayed dry at mid MIX. One shared block per pair, so a surround bus's extra channel pairs would
trample it.

### 1.7 RF64 recording pipeline

`recorder.gd` captures the Master bus through an `AudioEffectCapture` into 32-bit float WAV, then
optionally converts via ffmpeg.

| Constant | Value | Meaning |
|---|---|---|
| `BUS` | `"Master"` | What is captured |
| `BUFFER_SEC` | `2.0` | Capture buffer length |
| `FILE_TYPES` | `["WAV", "FLAC"]` | Output containers |
| `RATES` | `[44100, 48000, 96000]` | Output rates |
| `WAV_DEPTHS` | `[16, 24, 32]` | WAV bit depths |
| `FLAC_BITS` | `24` | FLAC depth |
| `HEADER_BYTES` | `80` | Fixed header size, RIFF or RF64 |
| `MAX_U32` | `4294967295` | Where 32-bit size fields wrap |
| `BYTES_PER_FRAME` | `8` | Stereo × 32-bit float |

A standard RIFF/WAV header stores sizes in 32-bit fields, which wrap at 4 GiB — **93 minutes 12
seconds** at 96 kHz stereo float. A DJ set can exceed that. RF64 (EBU Tech 3306) solves it by
writing 64-bit sizes into a `ds64` chunk.

The trick is that the file must be written *before* its length is known. SOUNDSCAPE reserves the
space up front as a `JUNK` chunk and upgrades it in place:

```gdscript
static func header_bytes(frames: int, rate: int, force_rf64 := false) -> PackedByteArray:
    var data_bytes := frames * BYTES_PER_FRAME
    var riff_bytes := HEADER_BYTES - 8 + data_bytes
    var big: bool = force_rf64 or riff_bytes > MAX_U32 or data_bytes > MAX_U32
    var out := PackedByteArray()
    out.resize(HEADER_BYTES)
    out.fill(0)
    _put_tag(out, 0, "RF64" if big else "RIFF")
    out.encode_u32(4, MAX_U32 if big else riff_bytes)
    _put_tag(out, 8, "WAVE")
    _put_tag(out, 12, "ds64" if big else "JUNK")
    out.encode_u32(16, 28)
    if big:
        out.encode_u64(20, riff_bytes)
        out.encode_u64(28, data_bytes)
        out.encode_u64(36, frames)
        out.encode_u32(44, 0)
    _put_tag(out, 48, "fmt ")
    out.encode_u32(52, 16)
    out.encode_u16(56, 3)                          # IEEE float
    out.encode_u16(58, 2)                          # stereo
    out.encode_u32(60, rate)
    out.encode_u32(64, rate * BYTES_PER_FRAME)     # byte rate
    out.encode_u16(68, BYTES_PER_FRAME)            # block align
    out.encode_u16(70, 32)                         # bits per sample
    _put_tag(out, 72, "data")
    out.encode_u32(76, MAX_U32 if big else data_bytes)
    return out
```

Because `JUNK` and `ds64` are both 28 bytes of payload at the same offset, the header can be
rewritten at the end of the take with no data movement.

**Every write is checked.** A silent write failure would leave a REC indicator counting up beside a
file nothing is being added to:

```gdscript
## A write that did not land. The take stops where it stopped, its header is patched so the
## audio that DID reach the disk is playable, and the UI is told: the alternative is a REC
## indicator counting up beside a file nothing is being added to.
func _fail(reason: String) -> void:
    error = reason
    recording = false
    AudioServer.set_bus_effect_enabled(_bus_idx, _slot, false)
    var path := _raw_path
    if _file:
        _write_header(frames_written)   # best effort; if this fails too the sizes stay as written
        _file.close()
        _file = null
```

Take names are timestamped to microseconds (`SOUNDSCAPE_YYYYMMDD_HHMMSS_micros`) with a
`file_exists` duplicate guard, so overlapping takes can never overwrite an active conversion.

---

## 2. SYSTEM ARCHITECTURE & DECK CONTROLLERS (GDScript)

### 2.1 The dual-deck model

A deck is a **pair** of `AudioStreamPlayer`s, not one. A crossfade needs the outgoing track to keep
sounding while the incoming one rises, so each deck alternates between its two players.

```gdscript
## deck -> [engine primary, scene spare]
var pair := [[], []]
## deck -> which side of its pair was last live
var deck_live := [null, null]
## deck -> the path it holds
var deck_cur := ["", ""]
## Whichever player currently owns playback: the live player of the DRIVEN deck.
var audio: AudioStreamPlayer
```

The design rule stated in the header is the one that prevents a whole family of bugs:

```gdscript
## Everything here is written to be TRUE OF EITHER DECK. The bug this shape exists to prevent
## is state that reads like it belongs to a deck but is actually shared: one `_reversed` flag
## for two decks meant reversing deck A also mirrored deck B's cue markers, and one crossfade
## tween for two decks let STOP on one deck strand the other mid-transition with both its
## players stuck at partial volume.
```

Hence `_fades` is an array of two tweens, `reversed_a`/`reversed_b` are separate, and
`live(deck)` resolves per deck:

```gdscript
func live(deck: int) -> AudioStreamPlayer:
    if engine != null and deck == engine.deck:
        return audio
    return deck_live[deck] if deck_live[deck] else pair[deck][0]
```

Buses are fixed: `const DECK_BUSES := ["DeckA", "DeckB"]`, each carrying its own `Equalizer` and
`FxRack` instance.

### 2.2 The 3-strike auto-advance guard

A decode failure during auto-advance used to end the set silently: one FLAC on a build without the
extension, one DST-compressed DSD, one cloud file not downloaded, and playback simply stopped
behind a note that cleared itself after four seconds.

The rule is a pure function, so it is testable with no deck, no file and no audio device:

```gdscript
## What a track that would not decode should DO, given who asked for it and how many failed
## before it. A track somebody PICKED is never skipped past -- the failure is reported and the
## deck stays where it is -- and neither is a failure on the deck nobody is driving. Pure, so
## the rule is checkable without a deck, a file or an audio device.
static func fail_action(auto: bool, same_deck: bool, streak: int) -> Fail:
    if not auto or not same_deck:
        return Fail.REPORT
    return Fail.STOP if streak + 1 >= MAX_AUTO_SKIPS else Fail.SKIP
```

`MAX_AUTO_SKIPS` is 3. The state machine:

| Condition | Action | Effect |
|---|---|---|
| User picked the track | `REPORT` | Note shown, deck stays put |
| Failure on the non-driven deck | `REPORT` | Live deck untouched |
| Auto-advance, streak 0–1 | `SKIP` | Log, note, `_next(true)` |
| Auto-advance, streak 2 | `STOP` | Playback stops, note does **not** self-clear |

The threshold's reasoning:

```gdscript
## How many unplayable tracks in a row end the set rather than being skipped past. Three is
## enough to step over a broken file or two mid-playlist, and few enough that a whole folder
## gone offline -- an unplugged drive, a cloud library with nothing downloaded -- stops the
## program on the third rather than tearing through a thousand tracks announcing each one.
const MAX_AUTO_SKIPS := 3
```

`AudioEngine` refines the *reason* so the log is actionable rather than generic:

```gdscript
    if not s:
        var why := "decode failed"
        match path.get_extension().to_lower():
            "flac": why = "decode failed" if native_flac_available() else "FLAC needs libsoundscape_dsp"
            "dsf", "dff": why = "decode failed" if ClassDB.class_exists("SsDsdStream") else "DSD needs libsoundscape_dsp"
            "mp4": why = "decode failed" if video_test else "Video TEST is off"
        track_failed.emit(path, why, d)
        return
```

### 2.3 The equal-power crossfader

```gdscript
## EQUAL POWER, not equal amplitude, and the difference is audible on every blend. Two decks
## playing different music are UNCORRELATED signals, so their POWERS add where their
## amplitudes do not. The old law faded each side linearly, which put both decks at 0.5
## amplitude dead centre: that sums to sqrt(0.5^2 + 0.5^2) = 0.707 of full power, a -3 dB hole
## in the middle of the sweep. Every DJ knows that dip as the crossfader eating the mix
## halfway across, and the fix is the standard one -- cos/sin, which hold cos^2 + sin^2 = 1
## across the whole travel.
##
## `x` is 0 (all deck A) to 1 (all deck B). Returns [deck A dB, deck B dB].
static func deck_gains_db(x: float) -> Array:
    var t := clampf(x, 0.0, 1.0) * 0.5 * PI
    return [deck_gain_db(cos(t)), deck_gain_db(sin(t))]

static func deck_gain_db(gain: float) -> float:
    return DECK_SILENT_DB if gain <= 0.001 else linear_to_db(gain)
```

| Position | Deck A | Deck B | Summed power |
|---|---|---|---|
| 0.0 | 0.00 dB | −80 dB (silent) | 1.0 |
| 0.5 | −3.01 dB | −3.01 dB | 1.0 |
| 1.0 | −80 dB (silent) | 0.00 dB | 1.0 |

The self-check asserts the *invariant* rather than the three endpoints, which is what the old
linear law actually failed:

```gdscript
    # the invariant that matters, and the one the old linear law failed in the middle: the
    # PAIR sits at unity power everywhere along the sweep
    var flat := true
    for i in 21:
        var at := deck_gains_db(float(i) * 0.05)
        var power := 0.0
        for g in at:
            if g > DECK_SILENT_DB:
                power += pow(db_to_linear(g), 2.0)
        flat = flat and absf(power - 1.0) < 1e-5
```

### 2.4 Crossfade transitions

`DeckController.crossfade()` starts the incoming track PLAY DELAY into the fade so both ramps
finish together, and the delay is clamped so an over-long value cannot turn the transition into a
hard cut:

```gdscript
    # clamped so delay + fade-in always fits inside FADE TIME; both ramps therefore finish
    # together and the whole transition still lasts exactly FADE TIME
    var delay: int = clampi(delay_ms, DELAY_MS_MIN, maxi(fade_ms - MIN_FADE_IN_MS, 0))
```

The incoming player is armed **silent and not playing**, because starting it during the delay would
advance its playhead:

```gdscript
    # armed but silent and NOT playing: starting it now would advance the playhead during the
    # delay, so the track would be mid-intro by the time it is audible
    incoming.stream = stream
    incoming.volume_db = SILENT_DB
    incoming.stream_paused = false
```

Defaults: `fade_ms = 1000`, `delay_ms = 250`, `MIN_FADE_IN_MS = 100`, `SILENT_DB = -80.0`.

### 2.5 REV playback and non-destructive cue markers

`AudioStreamPlayer` has no negative `pitch_scale`, so reverse playback is a **rendered** reversed
copy of the track, cached as `user://rev_<md5 of path+mtime+size>.flac` at 24-bit and the source's
own rate.

The cue-marker problem: a marker at 30 s of a 120 s track sits at 90 s of the reversed render. If
the UI simply wrote back what it read, marking a cue during REV would corrupt the stored time
permanently.

The solution is a single **self-inverse** mapping that every cue time crosses in both directions:

```gdscript
## A cue's time is ALWAYS stored against the track as recorded, forwards. While a deck plays
## the reversed render, that same instant sits at `length - t` in what is actually sounding --
## so every marker crosses this on its way to the screen or the playhead, and every marker the
## user drops or drags crosses it on the way back. Stored times therefore never mirror, which
## is what stops a cue marked during REV from being written at the wrong place for good.
##
## Its own inverse: applying it to a stream time hands back the stored time, which is why one
## function serves both directions.
static func cue_stream_time(t: float, length: float, reversed: bool) -> float:
    if not reversed or length <= 0.0:
        return t
    return clampf(length - t, 0.0, length)
```

It is applied at **every** call site: `_draw_cues`, `_cue_at`, `_tab_at`, `_drag_cue_step`,
`_add_cue`, `_jump_to_key` and `_audition`. Missing one would corrupt cues in exactly one
interaction path.

A cue is a plain dictionary:

```gdscript
    var cue := {
        "id": next_cue_id(_cues_for(_bar_path())),
        "time": clampf(at, 0.0, _len()),
        "shape": "square",
        "label": "CUE %d" % (_cues_for(_bar_path()).size() + 1),
        # the skin accent, captured at creation: markers read against every scheme, and a
        # cue keeps the colour it was born with even after the skin changes
        "color": theme.get_color("font_color", "Green").to_html(false),
    }
```

### 2.6 Track identity: why cues survive a moved library

Playlists, cues and RENAME tags are keyed by **track ID**, not path:

```gdscript
## A track's identity, independent of where it sits on disk. Name and size: a folder move, a
## drive re-letter and a whole library relocation all keep both, so the cues, the labels and
## the playlists survive them. Re-encoding a file changes its size and so its id, which is
## correct -- that is a different render of the track, and its old cue times need not fit.
static func track_id(path: String, size: int) -> String:
    return ("%s:%d" % [path.get_file().to_lower(), size]).sha1_text().left(16)
```

**ponytail:** two files with the same name and byte count share an id and therefore share cues. For
identical copies of one track that is the desired behaviour; a content hash is the upgrade if a
library ever shows up where it is not.

IDs live in `library_index.dat` under an `"ids"` key. The index format is version 2 but still reads
version 1 — refusing an old file would throw away a whole library's cached durations, tags and keys
to gain nothing:

```gdscript
const INDEX_VERSION := 2
const INDEX_VERSIONS_READ := [1, 2]
```

`RELOCATE` (beside REMOVE FOLDER) re-points every root under one prefix in a single step. It needs
to touch nothing else, because an id does not know where the file is.

### 2.7 Setlist and `.cue` sheet export

Every track that starts during a take is logged at its offset into the take. When the take
finishes, two companion files are written beside the audio.

CUE timestamps are **MM:SS:FF at 75 frames per second** — the format's own unit, not milliseconds:

```gdscript
## MM:SS:FF at 75 frames a second, which is what the CUE format counts in -- not milliseconds.
static func cue_stamp(secs: float) -> String:
    var total := maxf(secs, 0.0)
    var m := int(total / 60.0)
    var sec := int(total) % 60
    var frames := int((total - floor(total)) * 75.0)
    return "%02d:%02d:%02d" % [m, sec, frames]
```

```gdscript
static func cue_sheet(entries: Array, audio_file: String) -> String:
    var out := PackedStringArray([
        'TITLE "SOUNDSCAPE SET"',
        'FILE "%s" WAVE' % audio_file])
    for i in entries.size():
        var e: Dictionary = entries[i]
        out.append("  TRACK %02d AUDIO" % (i + 1))
        out.append('    TITLE "%s"' % str(e.get("title", "")).replace('"', "'"))
        var who := str(e.get("artist", ""))
        if not who.is_empty():
            out.append('    PERFORMER "%s"' % who.replace('"', "'"))
        out.append("    INDEX 01 %s" % cue_stamp(float(e.get("at", 0.0))))
    return "\n".join(out) + "\n"
```

Example output for a two-track set:

```
TITLE "SOUNDSCAPE SET"
FILE "SOUNDSCAPE_20260918_041500_123456.wav" WAVE
  TRACK 01 AUDIO
    TITLE "Opener"
    PERFORMER "Someone"
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    TITLE "Second"
    INDEX 01 03:05:37
```

Writing either file can fail without being fatal — the audio *is* the recording, and these are
notes about it. A failure is routed to the system log (§3.5).

### 2.8 Beat tracking and deck sync

`AudioDirector` runs a spectral-flux onset detector and a tempo fit per deck.

| Constant | Value | Purpose |
|---|---|---|
| `BAND_COUNT` | 32 | Analyser bands (also the EQ's bar count) |
| `F_MIN` / `F_MAX` | 30 Hz / 16 kHz | Analyser range |
| `HISTORY` | 10.0 s | Onsets kept for the tempo fit |
| `MIN_ONSETS` | 6 | Below this a fit is noise |
| `PHASE_EASE` | 0.25 | How hard a locked clock follows each new fit |
| `FLUX_BANDS` | 11 | Low bands only (~30–250 Hz): kick and low bass |
| `FLUX_WINDOW` | 43 | ~0.7 s adaptive threshold window at 60 fps |

`song_time()` compensates for output latency, which is the standard Godot idiom and essential for
any beat-aligned action:

```gdscript
    var t := _player.get_playback_position() \
        + AudioServer.get_time_since_last_mix() \
        - AudioServer.get_output_latency()
```

`sync_seek(master, slave, tol)` returns the seek offset that aligns the slave's grid to the
master's, or `NAN` when the two cannot be aligned — either clock unlocked, or tempos further apart
than `tol`. **No time-stretching is performed**; a genuine tempo mismatch is refused rather than
faked.

---

## 3. USER INTERFACE & SETTINGS

### 3.1 Tab layout

The right sidebar is a `TabContainer`. Long titles are shortened to fit a 108 px tab:

```gdscript
const TAB_SHORT_TITLES := {
    "RECORD SET": "REC", "FOLDERS": "DIRS", "VISUAL": "VIS", "TRACKS A": "TRK A", "TRACKS B": "TRK B",
    "SETTINGS": "SET",
}
const TAB_MAX_WIDTH := 108
```

Tabs can be torn off into independent OS windows and re-docked, and any tab page that is not
visible is put to sleep:

```gdscript
static func sleep_hidden_pages(dock: TabContainer) -> void:
```

A page that is not visible in the tree gets `PROCESS_MODE_DISABLED`; showing it restores
`PROCESS_MODE_INHERIT` with all state intact. Verified through a tab click, a tear-off, a re-dock,
and the whole dock hiding.

### 3.2 The SETTINGS screen

The tab was historically called **TBS** ("to be sorted"), from when it held a staging list for
tracks. That list was deleted two releases before the name was, and the internals remain `_tbs_*`
so the detached window, the tear-off and the config keys did not all have to move at once.

Forty-two rows are grouped into six sections:

```gdscript
const SETTING_GROUPS := {
    "AUDIO": ["FadeRow", "FadeTimeRow", "PlayDelayRow", "BoostRow", "BeatRow", "MonoRow",
        "ListeningModeRow"],
    "LIBRARY": ["ShowMsRow"],
    "DISPLAY": ["FeedSizeRow", "FpsRow", "LayoutRow", "ClockRow", "FontRow", "FontsRow",
        "CursorRow", "CrtRow", "PlayBarRow", "PlayBarShapeRow", "VisualWinRow", "DualDeckRow",
        "FadeSpeedRow"],
    "VIDEO": ["IntroRow", "VideoTestRow", "VideoColorRow"],
    "INPUT": ["SkipSecsRow"],
    "ADVANCED": ["MessageLogRow", "CheatRow", "AutopsyPanel"],
}
```

Assignment is a pure function with a safe default, so a row added later appears *somewhere* rather
than vanishing:

```gdscript
static func setting_group(row_name: String) -> String:
    for group in SETTING_GROUPS:
        if row_name in (SETTING_GROUPS[group] as Array):
            return group
    # every keybind lands under INPUT beside SKIP SECONDS, the only other thing on that screen
    # about what the keyboard does; anything else added later shows up in ADVANCED rather than
    # vanishing, which is what an unlisted row would otherwise do
    return "INPUT" if row_name.begins_with("Bind_") else "ADVANCED"
```

#### 3.2.1 Search filtering

A FIND field at the top filters as you type, matching a row's caption, whatever its control
currently reads, **and** its group name — so `FADE` finds FADE, FADE TIME and TAB FADE SPEED, while
`AUDIO` brings back the whole group:

```gdscript
static func setting_haystack(row: Node) -> String:
    var parts := PackedStringArray([str(row.name)])
    var stack: Array[Node] = [row]
    while not stack.is_empty():
        var n: Node = stack.pop_back()
        for c in n.get_children():
            stack.append(c)
        if n is Label:
            parts.append((n as Label).text)
        elif n is Button:
            parts.append((n as Button).text)
        elif n is LineEdit:
            parts.append((n as LineEdit).text)
    return " ".join(parts).to_lower()
```

A group with nothing showing hides its header too, rather than leaving a run of titles over empty
space.

### 3.3 Playbar rendering: waveform vs solid

The scrub bar can draw the track's shape behind the cue markers. The overview is 512 min/max pairs
built by ffmpeg on a worker — **4 KB per track however long it is**:

```gdscript
const WAVE_DIR := "user://waveforms"
const WAVE_BUCKETS := 512
const WAVE_RATE := 8000
```

```gdscript
## Built by ffmpeg on a worker, from mono at WAVE_RATE. That rate is the deliberate part: a peak
## meter would need the full rate to catch inter-sample peaks, and this is not a meter -- it is a
## few hundred pixels wide, and 8 kHz already carries far more detail than one bucket can show.
```

The fold is pure, so it is testable without ffmpeg, a file or a thread:

```gdscript
static func fold_waveform(samples: PackedFloat32Array, buckets: int) -> PackedFloat32Array:
    var out := PackedFloat32Array()
    if samples.is_empty() or buckets <= 0:
        return out
    out.resize(buckets * 2)
    var n := samples.size()
    for b in buckets:
        var from := int(float(b) * float(n) / float(buckets))
        var to := int(float(b + 1) * float(n) / float(buckets))
        if to <= from:
            to = mini(from + 1, n)
        var lo := 1.0
        var hi := -1.0
        for i in range(from, to):
            var v := samples[i]
            lo = minf(lo, v)
            hi = maxf(hi, v)
        out[b * 2] = clampf(lo, -1.0, 1.0)
        out[b * 2 + 1] = clampf(hi, -1.0, 1.0)
    return out
```

Bucket bounds are computed from the ends rather than by accumulating a step, so the last bucket
always finishes exactly at the last sample however the division falls.

**PLAYBAR SHAPE** (SETTINGS → DISPLAY) toggles between `[ WAVEFORM ]` and `[ SOLID ]`, saved as
`playbar_waveform` under `[display]` in `library.cfg`. The guard sits *before* the build request,
so SOLID does not queue an ffmpeg job for an overview nothing will draw:

```gdscript
func _draw_waveform(w: float, top: float) -> void:
    if not _show_playbar_wave:
        return   # before waveform_for(), so OFF does not start a build nobody will draw
    var wave := _engine.waveform_for(_bar_path())
```

The silhouette is drawn **under** the cue lines at `WAVE_ALPHA = 0.30`, mirrored about the centre
of the strip, so a marker stays findable against it.

> **Note on the row name.** The row is `PlayBarShapeRow`, not `PlayBarRow` — that name already
> belongs to the PLAY BAR (BOTTOM) show/hide toggle directly above it. Two siblings with one name
> means Godot silently renames the second, and a renamed row stops matching `SETTING_GROUPS` and
> lands in ADVANCED. `settings_test()` pins both rows to DISPLAY so they cannot drift.

### 3.4 Focus contexts (F2) vs transport hotkeys

This program's transport occupies exactly the keys focus navigation needs: SPACE, the arrow keys
and TAB. Enabling focus everywhere would hand all five to whichever button was last clicked.

```gdscript
##   MOUSE (default)  no control takes focus, and every shortcut means what it says.
##   KEYBOARD (F2)    buttons, lists and tabs take focus; TAB and the arrows move between them
##                    and ENTER/SPACE press the one you are on, because Godot's GUI consumes
##                    those before _unhandled_input ever sees them. ESC or F2 goes back.
```

The policy is one function, applied on every mode switch and to every node added later:

```gdscript
func _drop_focus(n: Node) -> void:
    if n is LineEdit:
        return
    # in the keyboard context these are exactly the things worth landing on; in the mouse
    # context none of them may hold focus, because the keys that would move it are the transport
    if n is Button or n is TabBar or n is ItemList or n is OptionButton or n is Tree:
        (n as Control).focus_mode = Control.FOCUS_ALL if _kb_nav else Control.FOCUS_NONE
```

A `LineEdit` is never touched by either context — typing has to keep working.

A mouse press anywhere returns to the MOUSE context, closing the loop from the other direction:

```gdscript
    # A press anywhere returns to the mouse context. Without this, clicking a button in keyboard
    # mode would leave it focused and eating SPACE -- the exact failure the two contexts exist
    # to prevent, arrived at from the other direction.
    if _kb_nav and event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
        _set_kb_nav(false)
```

The focus ring is a **tint**, not a stylebox, because the skins define normal/hover/pressed and
repaint them — a focus box would be one more thing every skin had to remember:

```gdscript
const KB_FOCUS_TINT := Color(1.35, 1.35, 1.0)
```

### 3.5 The system message log

`ERR: 0000` in the status bar used to be `0 if _note.is_empty() else 1` — it counted whether a note
happened to be on screen, making it a second copy of the note rather than an error count.

```gdscript
const LOG_MAX := 500
const LOG_ERROR := "ERROR"
const LOG_WARN := "WARN"

func _log_fault(what: String, detail := "", kind := LOG_ERROR) -> void:
    _log.append({"at": _session_secs, "kind": kind, "what": what, "detail": detail})
    if _log.size() > LOG_MAX:
        # oldest first: a session that hits its cap has usually gone wrong in one way over
        # and over, and the recent copies are the ones with the current paths in them
        _log = _log.slice(_log.size() - LOG_MAX)
    if kind == LOG_ERROR:
        _log_errors += 1
```

Faults routed to it: track decode failures, config write failures, recording write failures,
delete-from-disk failures, and set-list write failures. **Notes are not faults** and none are
logged. The log opens from SETTINGS → ADVANCED → MESSAGE LOG, newest first.

### 3.6 Visualizers

Eleven modes:

```gdscript
enum Mode { SEGMENTS, MIRROR, WATERFALL, GRID, RADIAL, MATRIX, TUNNEL, CRUISE, FIRE, KALEIDO, SNAKE }
```

#### 3.6.1 GPU field shader (FIRE and WATERFALL)

These two draw a *field* rather than a set of rects, and both used to build a `Color` per cell per
frame on the main thread — 32×96 for the waterfall, 56×40 and three lerps deep for the fire — then
push it through `Image.set_pixel` and upload it so the GPU could upscale it.

Now the CPU writes **one byte of magnitude per cell** and `viz_field.gdshader` makes every colour
decision:

```glsl
void fragment() {
	vec2 uv = UV;
	if (field_mode == 0) {
		// oldest row at the top: walk backwards from the write head, wrapping
		uv.y = fract(uv.y + scroll);
	}
	float v = texture(TEXTURE, uv).r;
	vec3 accent = texture(palette, vec2(UV.x, 0.5)).rgb;
	if (field_mode == 0) {
		COLOR = vec4(accent * v, v * 0.9);
	} else {
		// black -> accent -> white, with the white stop held back to the top of the range so
		// the body of the flame keeps its colour instead of blowing out
		vec3 col = mix(vec3(0.0), accent, min(v * 1.8, 1.0));
		col = mix(col, vec3(1.0), clamp((v - white_at) * 4.0, 0.0, 1.0));
		COLOR = vec4(col, clamp(v * 1.5, 0.0, 1.0));
	}
}
```

Two consequences fall out of moving the palette into the shader:

- The palette is applied to the **whole history every frame**, so changing gradient recolours the
  waterfall already on screen instead of only the rows yet to arrive.
- The waterfall is **one quad instead of two** — the shader wraps the ring buffer via the `scroll`
  uniform, where the CPU previously had to draw it in two ordered halves.

**ponytail:** the fire's cellular automaton stays on the CPU. It is 2,240 cells of a sequential
bottom-up recurrence, and moving it would need a SubViewport with feedback to hold the previous
frame — real machinery for a loop that size.

The field textures are sampled with `TEXTURE_FILTER_NEAREST` (set on the SubViewport via
`canvas_item_default_texture_filter = 0`), which is what keeps the fire chunky rather than smooth.

#### 3.6.2 CRT post-processing

```glsl
uniform float glow_amount : hint_range(0.0, 3.0) = 1.15;
uniform float glow_radius : hint_range(0.0, 8.0) = 2.2;
uniform float scan_strength : hint_range(0.0, 1.0) = 0.30;
uniform float scan_period : hint_range(2.0, 12.0) = 4.0;
uniform float bleed : hint_range(0.0, 1.0) = 0.25;
```

Applied as a material over `%VizBox`, captured once at boot so CRT OFF can null it out.

### 3.7 The FX rack

Eleven modules, each with a real parallel wet/dry path (§1.6):

| Key | Name | Parameters |
|---|---|---|
| `notch` | FEEDBACK KILLER | FREQ, WIDTH, MIX |
| `tbass` | T-BASS | AMOUNT, MIX |
| `bbe` | BBE | AMOUNT, MIX |
| `octaver` | DUAL OCTAVER | MIX, OCTAVE (−1/unison/+1) |
| `pumper` | PUMPER | RATE HZ, DEPTH, MIX |
| `pan` | PAN | PAN, AUTO RATE HZ, AUTO, MIX |
| `wah` | WAH | FREQ, Q, AUTO RATE HZ, AUTO, MIX |
| `chorus` | CHORUS | RATE HZ, DEPTH MS, MIX |
| `fuzz` | FUZZ | DRIVE, TONE HZ, MIX |
| `tape` | TAPE SIMULATOR | DRIVE, WOW, MODULATE, MIX |
| `reverb` | REVERB | SIZE, DAMP, MIX, TYPE |

Reverb types carry distinct physical models:

```gdscript
## room_size / damping / spread / predelay per reverb type, in TYPE order above.
## Plate is the tell: near-zero predelay, wide spread, bright (low damping) -- a plate
## is a sheet of metal, not a space, so it has no early-reflection gap to model.
```

**Nothing is allocated at runtime.** Every `AudioEffect` is created and inserted once in `setup()`,
disabled; "ADD EFFECT" only flips `set_bus_effect_enabled` on a slot that has existed since boot,
because `add_bus_effect`/`remove_bus_effect` rebuild every effect instance on the bus.

The **bypass contract** is strict: MIX 0 or a module switched off is bit-exact dry and costs zero
CPU, verified by `test_fx_rack.gd` check 8.

### 3.8 Equalizer

A 21-band `AudioEffectEQ21` driven from 16 UI lanes, plus a boost stage and a hard limiter.

A flat curve is **bypassed**, not processed — and the reason is genuinely subtle:

```gdscript
    # A flat curve is NOT a neutral equalizer. AudioEffectEQ21 is a PARALLEL bank of 21
    # two-pole bandpass sections summed with per-band gain, not a cascade of peaking
    # filters -- so with every lane at 0 dB the output is the sum of 21 IIR responses
    # rather than the input: magnitude roughly flat, phase very much not. The only
    # transparent setting is the effect switched out of the chain.
```

In v1.5 the dormant fixed FX rack (reverb, stereo delay, DJ filter sweep, pitch shifter) was
removed. Its controls went when performance FX became `FxRack`, so for two releases it was six
`AudioEffect`s allocated on every deck bus that nothing could reach, set or switch on.
`equalizer.gd` went from 488 to 297 lines.

---

## 4. BUILD SYSTEM & CROSS-PLATFORM CI/CD

### 4.1 SCons layout

```
cd extension
scons godot_cpp_dir=C:/dev/godot-cpp target=template_debug
scons godot_cpp_dir=C:/dev/godot-cpp target=template_release
scons -c                                # clean
```

The build tree lives **outside** the project, because objects and the signature database are
rewritten on every build and the project is OneDrive-synced:

```python
build_dir = os.path.join(build_root, env["suffix"].strip("."))
```

`env["suffix"]` is godot-cpp's `.<platform>.<target>.<arch>` string, so each build gets its own
directory — e.g. `windows.template_debug.x86_64`. Keyed on `target` alone (as it was before v1.5)
a Linux `template_release` build wrote objects over the Windows ones of the same name in the same
directory, and the next Windows link reused whichever set happened to be there.

**api_version is pinned:**

```python
env = SConscript(os.path.join(godot_cpp_dir, "SConstruct"), {"api_version": "4.7"})
```

This matches `compatibility_minimum = "4.7"` in `soundscape.gdextension`. A godot-cpp that has
moved on generates bindings the engine loads and then crashes on, at the first call into a method
whose hash moved.

**Float determinism** is a compiler flag, and `fast-math` is deliberately *not* enabled:

```python
#   - fast-math is deliberately NOT enabled: it lets the compiler reassociate float
#     arithmetic, and the pass-through milestone asserts BIT-IDENTICAL output. An
#     optimiser that is allowed to reorder a sum cannot be asked for exactness.
if env["platform"] == "windows" and env.get("use_mingw", False) is False:
    # MSVC: /fp:precise is the default and is what the bit-identical assertion needs.
    env.Append(CCFLAGS=["/fp:precise"])
else:
    env.Append(CCFLAGS=["-ffp-contract=off"])  # no fused multiply-add substitution
```

#### 4.1.1 The archive command that is too long to run

godot-cpp's static library is one `ar` invocation listing ~3,000 object files. Spelled out in full
that exceeds what a shell accepts, and the build dies at the last step after ten minutes with
`sh: Argument list too long`. Whether it trips depends on the **length of the checkout path**, so
it passes in a short local checkout and fails on a CI runner.

```python
if env["platform"] not in ("windows", "web"):
    env["ARCOM_POSIX"] = env["ARCOM"].replace("$TARGET", "$TARGET.posix").replace("$SOURCES", "$SOURCES.posix")
    env["ARCOM"] = "${TEMPFILE(ARCOM_POSIX)}"
    env["MAXLINELENGTH"] = 2048   # past this the arguments go to a file, not the command line
```

This works from outside godot-cpp because its `SConstruct` ends with `Return("env")` — the same env
it created the library target with — and SCons expands `$ARCOM` at *build* time rather than when
the target is defined. godot-cpp already does this for the web platform in `tools/web.py`; linux
and macos were simply missing it.

### 4.2 The `.gdextension` library keys

```ini
[libraries]

windows.debug.x86_64 = "res://bin/libsoundscape_dsp.windows.template_debug.x86_64.dll"
windows.release.x86_64 = "res://bin/libsoundscape_dsp.windows.template_release.x86_64.dll"

linux.debug.x86_64 = "res://bin/libsoundscape_dsp.linux.template_debug.x86_64.so"
linux.release.x86_64 = "res://bin/libsoundscape_dsp.linux.template_release.x86_64.so"
```

A key is a **set of feature tags**, order irrelevant, and every tag must be present for the entry to
match:

| Tag set | Matches |
|---|---|
| `editor` + `debug` | The editor, and any `--headless --script` run (the whole test suite) |
| `template_debug` + `debug` | An exported debug build |
| `template_release` + `release` | An exported release build |

So `linux.debug.x86_64` covers the editor **and** exported debug builds. Writing it as
`linux.x86_64.template_debug` looks more precise and is worse: the editor has no `template_debug`
tag, so the extension stops loading there entirely. Measured on 2026-09-18 — the engine says only
`No GDExtension library found for current OS and architecture (windows.x86_64)`, with no hint that
the key shape is the reason.

### 4.3 GitHub Actions CI

`.github/workflows/build-linux.yml` builds the Linux libraries that the Windows development machine
cannot produce (w64devkit emits PE objects only).

```yaml
    strategy:
      fail-fast: false
      matrix:
        target: [template_debug, template_release]
```

godot-cpp is pinned to the revision the Windows libraries were built from:

```yaml
      - name: Check out godot-cpp
        uses: actions/checkout@v4
        with:
          repository: godotengine/godot-cpp
          ref: 6cceaf6a5f8b0d78ac5d71c139fd7fabba43b918
          path: godot-cpp-src
```

The runner verifies what it built rather than trusting that a green build means a working library:

```yaml
      - name: Verify the library
        run: |
          so="bin/libsoundscape_dsp.linux.${{ matrix.target }}.x86_64.so"
          test -f "$so" || { echo "::error::$so was not produced"; exit 1; }
          file "$so"
          file "$so" | grep -q "ELF 64-bit LSB shared object, x86-64" \
            || { echo "::error::$so is not an x86-64 ELF shared object"; exit 1; }
          nm -D --defined-only "$so" | grep -qw soundscape_dsp_init \
            || { echo "::error::$so does not export soundscape_dsp_init (entry_symbol in soundscape.gdextension)"; exit 1; }
```

A `bundle` job merges both targets into one `linux-dsp-libraries` artifact so it drops straight
into `bin/`.

**The export is deliberately not done on the runner** — it would mean pulling ~1 GB of Godot export
templates into CI to build a package whose presets, paths and templates already live on the
development machine.

### 4.4 Export presets and packaging

| Preset | Platform | Output |
|---|---|---|
| `Windows Desktop` | Windows Desktop | `SOUNDSCAPE RELEASES/HEADLESS HORSEMAN/v1.6/SOUNDSCAPE BETA v1.6 WIN.zip` |
| `Linux/X11` | Linux | `SOUNDSCAPE RELEASES/HEADLESS HORSEMAN/v1.6/SOUNDSCAPE LINUX v1.6.zip` |
| `macOS` | macOS | (v1.4 path; not part of the v1.6 release) |

Both presets embed the PCK into the binary and exclude `test_director.gd` and the teardown
documents.

```bash
# Windows
godot --headless --path . --export-release "Windows Desktop"
# Linux
godot --headless --path . --export-release "Linux/X11"
```

> **Trap worth knowing.** Godot does **not** create the export output directory, and does not fail
> when it is absent. The first Linux export printed `[DONE] savepack`, exited 0, and wrote nothing
> at all because `.../v1.5/linux/` did not exist (that was the v1.5 layout). Always `mkdir -p` the
> target and `ls` the output.

### 4.5 Release workflow, end to end

```bash
# 1. Build the native libraries
cd extension
scons godot_cpp_dir=C:/dev/godot-cpp target=template_debug
scons godot_cpp_dir=C:/dev/godot-cpp target=template_release

# 2. Linux libraries come from CI
git push origin main
gh run watch <id> --exit-status
gh run download <id> --name linux-dsp-libraries --dir bin

# 3. Verify what arrived
nm -D --defined-only bin/libsoundscape_dsp.linux.template_release.x86_64.so | grep soundscape_dsp_init

# 4. Suite must be green before anything ships
godot --headless --path . --script res://test_<each>.gd

# 5. Export both platforms
mkdir -p "../SOUNDSCAPE RELEASES/HEADLESS HORSEMAN/v1.6"
godot --headless --path . --export-release "Windows Desktop"
godot --headless --path . --export-release "Linux/X11"
```

---

## 5. USER GUIDE & API REFERENCE

### 5.1 Keyboard shortcuts

All bindings are remappable from SETTINGS → INPUT. Defaults:

| Key | Action | Notes |
|---|---|---|
| `SPACE` | PAUSE / PLAY | Suspended in KEYBOARD focus context |
| `←` / `→` | SEEK BACK / FORWARD | Step set by SKIP SECONDS (1–30 s, default 5) |
| `↑` / `↓` | MASTER VOLUME UP / DOWN | ±5 % |
| `1` | DECK A | |
| `2` | DECK B | |
| `TAB` | DECK A+B | Both decks at unity |
| `F2` | KEYBOARD NAVIGATION | Toggles focus context; `ESC` also leaves |
| `M` | MARK MODE | Arms cue marking |
| `H` | HIDE CURSOR | |
| `F1` | VISUALIZER FULLSCREEN | |
| `F11` | OS FULLSCREEN | |
| `ESC` | Leave (in order) keyboard nav → visualizer fullscreen → OS fullscreen | Innermost first |
| Media keys | PLAY/PAUSE, NEXT, PREV, STOP | Require window focus; Godot has no OS media session |
| `A`–`Z`, `0`–`9` | Jump to cue with that key | Only while a track is loaded |

A focused `LineEdit` consumes keys before `_unhandled_input` sees them, so typing a search term can
never trigger a jump.

### 5.2 GUI navigation

- **TRK A / TRK B** — the library, one list per deck, each with its own search, sort and playlist.
  Double-click loads that deck.
- **DIRS** — library roots, folder checkboxes, SCAN SONGS (becomes STOP SCAN while running),
  RELOCATE.
- **VIS** — visualizer mode, gradients, colour animation, DUAL VISUAL.
- **EQ** — 16-lane equalizer, EZ/ADVANCED modes, presets.
- **RACK** — the FX rack, per deck.
- **REC** — recording controls, format, rate, quality, directory.
- **SET** — settings, grouped and searchable.

### 5.3 `AudioEngine` API

```gdscript
# --- signals ---
signal track_ready(path: String, stream: AudioStream, meta: Dictionary, deck: int)
signal track_failed(path: String, reason: String, deck: int)
signal queue_changed()
signal deck_changed(deck: int)
signal waveform_ready(path: String)
signal reversed_ready(path: String, stream: AudioStream)
signal spectral_key_ready(path: String, pc: int, minor: bool)
signal video_ready(path: String, ogv: String)
```

**Loading and playing a track**

```gdscript
var engine: AudioEngine = %Engine

# Point the queue at a list of paths, re-anchored on the track already playing
engine.set_queue(paths, current_path)

# Ask for an index; the decode happens on a worker and comes back as a signal
engine.request(4)

engine.track_ready.connect(func(path, stream, meta, deck):
    var player := engine.deck_player(deck)
    player.stream = stream
    player.play())
```

**Deck and crossfader control**

```gdscript
engine.set_deck(1)              # drive deck B
engine.set_both(true)           # A+B: both at unity, crossfader bypassed
engine.set_crossfader(0.5)      # equal power: both decks at -3.01 dB
var gains := AudioEngine.deck_gains_db(0.5)   # [-3.0103, -3.0103]
```

**Listening mode**

```gdscript
engine.set_listening_mode(AudioEngine.ListeningMode.CASUAL)
print(engine.curve_latency_ms())   # 6.29 at 96 kHz; 0.0 in AUDIOPHILE
```

Note that `set_listening_mode()` is a coroutine when switching *to* AUDIOPHILE: it awaits the
150 ms ramp before removing the effect from the bus.

**Metadata and waveforms**

```gdscript
var m := engine.metadata(path)      # blocking probe if uncached
var c := engine.cached_meta(path)   # cache only, never probes
# {title, artist, album, sample_rate, channels, bits, codec, key, duration}

var wave := engine.waveform_for(path)   # empty first call; starts a worker build
engine.waveform_ready.connect(func(p): _cue_overlay.queue_redraw())
```

**Static helpers**

```gdscript
AudioEngine.native_flac_available()      # is libsoundscape_dsp loaded?
AudioEngine.driver_name()                # "WASAPI", "PULSEAUDIO", "DUMMY"...
AudioEngine.path_text()                  # "NATIVE DSP" or "GODOT DSP"
AudioEngine.camelot(pc, minor)           # "8A"
AudioEngine.key_shifted(pc, semitones)
AudioEngine.file_stamp(path)             # [mtime, size] or []
```

### 5.4 `DeckController` API

```gdscript
var decks := DeckController.new()
decks.engine = _engine
decks.director = _director
add_child(decks)          # needs the tree: crossfade drives a Tween
```

```gdscript
decks.live(0)                       # the AudioStreamPlayer deck A is sounding through
decks.fading(0)                     # is a crossfade in flight on deck A?
decks.kill_fade(0)

decks.set_reversed(0, true)
decks.is_reversed(0)

# self-inverse: stored time <-> sounding time
var on_screen := DeckController.cue_stream_time(30.0, 120.0, true)   # 90.0
var stored := DeckController.cue_stream_time(on_screen, 120.0, true) # 30.0

# the auto-advance rule, with no deck required
DeckController.fail_action(true, true, 0)   # Fail.SKIP
DeckController.fail_action(true, true, 2)   # Fail.STOP
DeckController.fail_action(false, true, 9)  # Fail.REPORT
```

**Crossfading a new stream in**

```gdscript
decks.crossfade(stream, deck, func(d: int, incoming: AudioStreamPlayer) -> void:
    _sync_attach(d, incoming)
    if _engine.deck == d:
        decks.audio = incoming
        _director.attach(decks.audio))
```

### 5.5 `LibraryModel` API

```gdscript
var lib := LibraryModel.new()
lib.engine = _engine
add_child(lib)                       # needs the tree so the scan worker can report

lib.folders = ["D:/Music"]
lib.scan_progress.connect(func(done, total, where): print(where, done))
lib.scan_finished.connect(func(found, cancelled): print(found))
lib.scan()                           # false if one is already running
lib.stop_scan()

lib.apply_folder_filter()            # re-derive `paths` from `all_paths`
lib.reindex()                        # rebuild row strings, ids and sort orders

var id := lib.id_for(path)
var where := lib.path_for(id)        # "" if the library no longer holds it
lib.relocate("D:/Music", "E:/Sounds")
```

### 5.6 C++ extension API from GDScript

The native classes are ordinary Godot classes once registered:

```gdscript
if ClassDB.class_exists("SsFlacStream"):
    var stream: AudioStream = ClassDB.instantiate("SsFlacStream")
    stream.call("load_file", path)
    print(stream.call("get_sample_rate"), stream.call("get_bits_per_sample"))
```

```gdscript
# the CASUAL curve, if you need to drive it directly
var curve := ClassDB.instantiate("SsCasualCurve")
curve.call("set_mix", 1.0)             # target; the audio thread slews to it
curve.call("get_ramp_sec")             # 0.15
curve.call("get_latency_frames")       # 604 at 96 kHz
curve.call("reset")                    # clear the delay lines before switching in
```

### 5.7 Configuration file

`user://library.cfg` (or `library_dev.cfg` in the editor). Sections:

| Section | Holds |
|---|---|
| `[library]` | Roots, enabled folders, sort modes, RENAME tags, selected playlists, setlist |
| `[playlists]` | Playlist contents (track IDs) and playlist-scoped cues |
| `[cues]` | Global cues, keyed by track ID |
| `[audio]` | Volume, boost, fade, play delay, crossfader, deck, mono, beat sync |
| `[visual]` | Feed size, fonts, cursor, skin, CRT, gradients, visualizer state, listening mode |
| `[display]` | `playbar_waveform` |
| `[input]` | Skip seconds |
| `[keybinds]` | One entry per remappable action |
| `[eq]` / `[rack]` | Per-deck equalizer and FX rack state, plus presets |
| `[record]` | Directory, rate, type, quality |
| `[spectral_keys]` | Offline key-estimation cache |
| `[stats]` | Lifetime seconds, user name |
| `[secrets]` | Unlocked features, license endpoint |

Saves are atomic and never half-written: the new file goes to `.tmp`, the live file moves to
`.bak`, then `.tmp` takes its place. Every step is a rename, so at any instant a complete copy
exists as the live file, the `.bak` or the `.tmp`.

A file that exists but will not parse is renamed `.corrupt-<unix time>` and its `.bak` loaded —
the old behaviour fell through to defaults, and the next save wrote those defaults over every
playlist and cue.

The file is **built** on the main thread (every value read off live state) but **written** on a
worker:

```gdscript
var _cfg_task := -1

func _write_cfg_async(cfg: ConfigFile) -> void:
    if _cfg_task != -1:
        WorkerThreadPool.wait_for_task_completion(_cfg_task)
    var path := _cfg
    _cfg_task = WorkerThreadPool.add_task(func() -> void:
        var err := save_cfg_atomic(cfg, path)
        if err != OK:
            _on_cfg_write_failed.call_deferred(error_string(err)))
```

---

## 6. APPENDICES

### 6.1 Test suite

24 scripts, each run standalone. There is no test framework — every script prints numbered check
lines and a final `RESULT PASS` / `RESULT FAIL`, and exits non-zero on failure.

```bash
godot --headless --path . --script res://test_ss_effect.gd
```

| Script | Covers |
|---|---|
| `test_ss_effect` | SsEffect pass-through, CASUAL placement, bit-exact bypass, curve response table |
| `test_flac_native` | Native FLAC decode vs ffmpeg's own float decode |
| `test_wav_native` | Native WAV, including EXTENSIBLE headers and float WAVs |
| `test_dsd_native` | DSD64/128 decode, DSF and DFF containers |
| `test_fx_rack` | Module build, parameter clamping, MIX 0 bit-exact bypass contract |
| `test_rack_wheel` | Mouse-wheel parameter steps: fine, coarse, accelerator |
| `test_recorder` | RF64 header arithmetic past 4 GiB, write-failure handling, unique take names |
| `test_director` | Tempo lock accuracy and beat phase at 90/120/128/174 BPM |
| `test_beat_sync` | Two-deck grid alignment and refusal on genuine tempo mismatch |
| `test_dual_deck` | Deck wing layout, focus throttle, tab sleep, pure model rules |
| `test_library_model` | Worker scan, cancellation, track ids, RELOCATE, id migration |
| `test_library_index` | Index persistence, validation, ffprobe avoidance |
| `test_keybinds` | Rebinding, conflicts, ui_* stripping, focus contexts |
| `test_config` | Atomic save, corrupt-file recovery |
| `test_video_fixture` | Audio/video drift over a real 175 s track |
| `test_video_test` | MP4 gating, render cache, kick extraction |
| `test_viz_fps` | Frame-rate independence of visualizer stepping |
| `test_spectral_key` | FFT peak, chroma fold, Krumhansl-Schmuckler profile match |
| `test_skins`, `test_grad_anim`, `test_grad_strip` | Theme and gradient handling |
| `test_mono_fold`, `test_bar_drag`, `test_shutdown` | Mono fold, drag predicate, clean teardown |

**Test isolation rule.** Never boot `player.tscn` against the real `user://` — its `_ready` purges
every `user://pcm_*.wav` and rewrites the config. Boot tests run against a project copy with
`config/use_custom_user_dir=true` and `config/custom_user_dir_name="SOUNDSCAPE_TEST"`.

**Pure checks must be called from a test script.** `player.gd` asserts ~20 pure self-checks in
`_ready`, and nothing in the suite boots `player.tscn`, so those assertions never run there.
`test_dual_deck.gd` calls them explicitly:

```gdscript
    var rules: bool = DeckController.deck_test() and AudioEngine.deck_test() and LibraryModel.model_test() \
        and AudioEngine.waveform_test() and load("res://player.gd").settings_test() \
        and load("res://player.gd").set_export_test()
```

### 6.2 The headless clock hazard

Godot's Dummy audio driver paces itself with `audio_server_process()` followed by
`OS::delay_usec(usdelay)`. On Windows `delay_usec` is `Sleep(p_usec / 1000)`, truncated to whole
milliseconds and never shorter than the mix took. **The headless audio clock therefore runs slow in
proportion to mix-thread CPU.**

Practical consequences:

- `test_video_fixture`, `test_beat_sync` and `test_director` are timing-sensitive. Run them with
  nothing else loading the machine; a parallel build or a second suite skews them.
- A failure in these under load is not evidence of a regression. Re-run solo before investigating.
- The tell for a clock artifact rather than a real fault: readings biased **in one direction**
  (e.g. +14.5 to +19.9 ms) rather than scattered around zero.

Two test bars were recalibrated in v1.5 to account for measurement physics rather than loosened:

- `test_beat_sync` demanded the residual beat `sync_seek`'s own 15 ms tolerance with no margin for
  the frame an onset is stamped at. The bar is now `15 ms + measured audio-seconds-per-frame`.
- `test_director` accepted `TOL_BPM = 2.0` while demanding a flat 20 ms phase — but a tolerated
  tempo error *is* a phase error. The bar is now `TOL_PHASE + d_bpm / track_bpm * HISTORY * 0.5`;
  an exact lock still faces the flat 20 ms.

### 6.3 DSP autopsy readout

SETTINGS → ADVANCED carries a live signal-flow readout, refreshed at 4 Hz. Captions are padded to
11 characters with dots, and a block's continuation lines are indented to match:

```gdscript
static func _autopsy_block(caption: String, parts: Array[String]) -> Array[String]:
    var out: Array[String] = []
    for i in parts.size():
        out.append((caption.rpad(11, ".") if i == 0 else " ".repeat(11)) + parts[i])
    return out
```

For a 24-bit 44.1 kHz FLAC on a 96 kHz mix, with two FX modules in circuit and CASUAL on, the four
generators above produce:

```
DECK.......DECK A
SOURCE.....FLAC | 44.1 KHZ / 24-BIT | STEREO
RESAMPLER..C++ WINDOWED-SINC (SincResampler)
           PHASE 320:147 | THD+N -124 DB (TESTED)
FX ENGINE..PARALLEL WET/DRY: 2 TAP/BLEND PAIRS
           ACTIVE MODULES: 2
MASTER OUT.96000 HZ / 32-BIT FLOAT | CASUAL (SMOOTH) +6.3 MS
           TPDF DITHER: ON (REC WAV 24-BIT)
```

`PHASE 320:147` is the exact rational step from §1.4 — `gcd(44100, 96000) = 300`, so the resampler
advances 320 phases per 147 source frames with no drift. A file already at the mix rate reads
`NONE: PASSTHROUGH` / `PHASE 1:1 | BIT-EXACT COPY` instead, and a build without the extension reads
`GODOT 4-POINT CUBIC (16-BIT STEP)` with the −26 dB figure.

### 6.4 Known limitations (`ponytail` markers)

| Area | Limitation | Upgrade path |
|---|---|---|
| DSD | Whole file in RAM (~42 MB/min DSD64) | Streaming reader |
| DSD | DST-compressed DFF refused | Vendor a DST decoder |
| `SsParallel` | No latency compensation for delaying modules | Report module latency to BLEND |
| `SsParallel` | One shared dry block per pair | Per-channel-pair buffers for surround |
| Resampler | `pitch_scale` path untested (nothing sets it) | Row interpolation is implemented but unexercised |
| FIRE | Cellular automaton on CPU | SubViewport with feedback |
| Track IDs | Same name + same size share cues | Content hash |
| Waveform | 8 kHz mono; misses inter-sample peaks | Full-rate pass if it ever matters |
| Linux | Never smoke-tested on real hardware | Run on a Linux box |

### 6.5 Version history (v1.5 cycle)

| Tag | Content |
|---|---|
| `v1.5-beta` | Native DSP engine, dual deck mode, DSD, listening mode |
| `v1.5-phase1` | RF64 recording, per-deck REV with cue mapping, resilient auto-advance |
| `v1.5-phase2` | `LibraryModel` + `DeckController` extracted, track IDs, threaded scan/saves, equal-power crossfader, dead code removed |
| `v1.5-phase3` | SETTINGS rename/grouping/search, DELETE confirmation, clipped-control tooltips |
| `v1.5-phase4` | System message log, CASUAL crossfade, GPU field shader, truthful POST/ticker |
| `v1.5-phase5` | Focus contexts, waveform overviews, set list / CUE export |
| `v1.5` | Release artifacts, Windows package |
| `v1.5-linux` | Linux `.so` pair and exported Linux package |

---

*End of document. Every code excerpt is quoted from the working tree at the revision this document
was committed. Where behaviour is described as "measured", the measurement is reproducible from the
test script named beside it.*
