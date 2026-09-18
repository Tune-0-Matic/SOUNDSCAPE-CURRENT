/**************************************************************************/
/*  ss_dsd.h                                                              */
/*  SsDsdStream / SsDsdPlayback -- native DSD (.dsf, .dff), no transcode.  */
/**************************************************************************/
//
// DSD is a 1-bit pulse-density stream at 64 or 128 times 44.1 kHz (or 48 kHz). Godot plays none
// of it, so this decodes it inside the mix, in two stages:
//
//   1. DECIMATE: a 128-tap-per-byte-of-rate Kaiser FIR (140 dB design) over the bit stream,
//      evaluated as one table lookup per incoming byte -- the classic dsd2pcm structure, with
//      this file's own coefficients -- down to 8x base rate: 352.8 kHz (or 384 kHz)
//   2. RESAMPLE: resampler.h's windowed sinc from there to the mix rate, with the passband held
//      to 30 kHz. Above that a DSD modulator's shaped noise climbs steeply; passing it would put
//      tens of dB of ultrasonic hash into every bus effect and the analyser
//
// Levels are the bitstream's own: all ones is +1.0, so the SACD 0 dB reference (50 % modulation)
// plays at -6 dBFS, the way DSD is mastered. No makeup gain: DSD routinely modulates past 50 %.
//
// ponytail: the whole file stays in RAM, like SsWavStream -- about 42 MB a minute for stereo
// DSD64, 85 MB for DSD128. A reader streaming from disk is the upgrade for long DSD128 albums.
// ponytail: DST-compressed DFF is refused rather than decoded; no free DST decoder is vendored.

#ifndef SOUNDSCAPE_SS_DSD_H
#define SOUNDSCAPE_SS_DSD_H

#include <godot_cpp/classes/audio_frame.hpp>
#include <godot_cpp/classes/audio_stream.hpp>
#include <godot_cpp/classes/audio_stream_playback.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

#include "resampler.h"

#include <cstdint>
#include <vector>

namespace soundscape {

/// Where the bit stream lives inside the file bytes, as the container parser found it.
struct DsdLayout {
	const uint8_t *data = nullptr; // start of the sound data
	int channels = 0;
	int64_t bytes_per_channel = 0;
	bool planar = false; // DSF: per-channel blocks; DFF: interleaved byte by byte
	int64_t block = 1; // DSF block size per channel
	bool msb_first = false; // DFF (and DSF at 8 bits per sample) put the earliest bit in bit 7
	int bytes_per_out = 1; // DSD64: 1 byte per 8x-rate frame, DSD128: 2, DSD256: 4
};

/// Stage 1, as a Source at 8x base rate.
class DsdDecimator : public Source {
public:
	/// MAIN THREAD. Designs the FIR and builds its byte tables; `p_dsd_rate` sets the cutoff.
	void configure(const DsdLayout &p_layout, int64_t p_dsd_rate);
	int64_t read(float *l, float *r, int64_t frames) override;
	void seek(int64_t frame) override;
	int64_t frame_count() const { return _layout.bytes_per_channel / _layout.bytes_per_out; }

private:
	uint8_t _byte(int p_channel, int64_t p_index) const;
	void _push();
	double _sum(int p_channel) const;

	DsdLayout _layout;
	int _hist = 16; // bytes of history per channel = 16 * bytes_per_out
	std::vector<double> _table; // [_hist][256]: that byte slot's contribution, newest slot first
	std::vector<uint8_t> _ring; // [channels][_hist]
	int _head = 0;
	int64_t _pos = 0; // next byte index, per channel
};

} // namespace soundscape

namespace godot {

class SsDsdStream : public AudioStream {
	GDCLASS(SsDsdStream, AudioStream)

public:
	static Ref<SsDsdStream> load_from_file(const String &p_path);

	/// OK (0), or a Godot Error code as an int. Reads the whole file and parses DSF or DFF.
	int load(const String &p_path);

	/// The 1-bit rate: 2822400 for DSD64, 5644800 for DSD128.
	int get_sample_rate() const { return _dsd_rate; }
	/// What stage 1 hands the resampler: 352800 (or 384000 for the 48 kHz family).
	int get_pcm_rate() const { return _pcm_rate; }
	int get_channels() const { return _layout.channels; }
	int get_bits_per_sample() const { return 1; }
	/// DSD samples (bits) per channel.
	int64_t get_frame_count() const { return _layout.bytes_per_channel * 8; }
	String get_container() const { return _container; }

	/// Interleaved STEREO float frames at get_pcm_rate(), straight out of stage 1.
	PackedFloat32Array decode_frames(int64_t p_from_frame, int64_t p_frame_count) const;
	/// Interleaved STEREO frames at `out_rate` through the exact _mix path.
	PackedFloat32Array render(int p_out_rate, double p_from_seconds, int64_t p_frames) const;

	const soundscape::DsdLayout &layout() const { return _layout; }

	Ref<AudioStreamPlayback> _instantiate_playback() const override;
	String _get_stream_name() const override;
	double _get_length() const override;
	bool _is_monophonic() const override;

protected:
	static void _bind_methods();

private:
	int _parse_dsf();
	int _parse_dff();

	PackedByteArray _data;
	String _path;
	String _container;
	int _dsd_rate = 0;
	int _pcm_rate = 0;
	soundscape::DsdLayout _layout;
};

class SsDsdPlayback : public AudioStreamPlayback {
	GDCLASS(SsDsdPlayback, AudioStreamPlayback)

public:
	/// Stage 2's passband: see the note at the top of this file.
	static constexpr double kPassHz = 30000.0;

	/// MAIN THREAD. `p_out_rate` 0 means the AudioServer's mix rate.
	bool open(const Ref<SsDsdStream> &p_stream, int p_out_rate = 0);

	void _start(double p_from_pos) override;
	void _stop() override;
	bool _is_playing() const override;
	int32_t _get_loop_count() const override;
	double _get_playback_position() const override;
	void _seek(double p_position) override;
	int32_t _mix(AudioFrame *p_buffer, float p_rate_scale, int32_t p_frames) override;

protected:
	static void _bind_methods();

private:
	Ref<SsDsdStream> _stream; // keeps the file bytes alive under the decimator
	soundscape::DsdDecimator _decimator;
	soundscape::StreamPlayer _player;
};

} // namespace godot

#endif // SOUNDSCAPE_SS_DSD_H
