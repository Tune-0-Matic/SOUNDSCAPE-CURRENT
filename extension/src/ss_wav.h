/**************************************************************************/
/*  ss_wav.h                                                              */
/*  SsWavStream / SsWavPlayback -- native WAV at full bit depth.          */
/**************************************************************************/
//
// Godot 4.7's AudioStreamWAV stores 16 bits at most and refuses the WAVE_FORMAT_EXTENSIBLE header
// that ffmpeg, DAWs and hi-res downloads write for anything past 16-bit or 48 kHz: those files
// came back null and the row read DECODE FAILED, and a 24-bit file with a plain header lost its
// low 8 bits with no dither (-39 dB THD+N on a -60 dBFS tone, against -87 dB through FLAC).
// This reads the file with dr_wav instead. PCM 8/16/24/32-bit, IEEE float, A-law/mu-law, plain
// or EXTENSIBLE, all reach the mixer as 32-bit float, which holds every 24-bit sample exactly.
//
// Same shape as SsFlacStream (ss_flac.h) on purpose: the file bytes stay in memory, frames are
// read block by block inside the mix, and the audio thread touches only memory that was allocated
// before playback started. For uncompressed PCM the whole file is resident -- the RAM
// AudioStreamWAV already spent, without its truncation.
// ponytail: whole file in RAM, as AudioStreamWAV did; a multi-GB recording would want a reader
// that streams from disk.

#ifndef SOUNDSCAPE_SS_WAV_H
#define SOUNDSCAPE_SS_WAV_H

#include <godot_cpp/classes/audio_frame.hpp>
#include <godot_cpp/classes/audio_stream.hpp>
#include <godot_cpp/classes/audio_stream_playback.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

#include "resampler.h"

#include <vector>

namespace godot {

class SsWavStream : public AudioStream {
	GDCLASS(SsWavStream, AudioStream)

public:
	/// null when the file cannot be read or is not a WAV dr_wav understands.
	static Ref<SsWavStream> load_from_file(const String &p_path);

	/// OK (0), or a Godot Error code as an int. Reads the whole file and validates its header.
	int load(const String &p_path);

	int get_sample_rate() const { return _rate; }
	int get_channels() const { return _channels; }
	int get_bits_per_sample() const { return _bits; }
	int64_t get_frame_count() const { return _frames; }

	/// Interleaved float frames decoded on the CALLING thread with a private reader --
	/// for verification and analysis, never used by playback.
	PackedFloat32Array decode_frames(int64_t p_from_frame, int64_t p_frame_count) const;

	/// Interleaved STEREO frames at `out_rate` through the exact _mix path -- see SsFlacStream::render.
	PackedFloat32Array render(int p_out_rate, double p_from_seconds, int64_t p_frames) const;

	const PackedByteArray &bytes() const { return _data; }

	Ref<AudioStreamPlayback> _instantiate_playback() const override;
	String _get_stream_name() const override;
	double _get_length() const override;
	bool _is_monophonic() const override;

protected:
	static void _bind_methods();

private:
	PackedByteArray _data;
	String _path;
	int _rate = 0;
	int _channels = 0;
	int _bits = 0;
	int64_t _frames = 0;
};

class SsWavPlayback : public AudioStreamPlayback {
	GDCLASS(SsWavPlayback, AudioStreamPlayback)

public:
	SsWavPlayback() = default;
	~SsWavPlayback() override;

	/// MAIN THREAD. Opens the reader over the stream's bytes and sizes every buffer -- the only
	/// allocations this playback ever makes. `p_out_rate` 0 means the AudioServer's mix rate.
	bool open(const Ref<SsWavStream> &p_stream, int p_out_rate = 0);

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
	struct Reader : soundscape::Source {
		void *wav = nullptr; // drwav*, kept opaque so this header need not include dr_wav.h
		int channels = 0;
		std::vector<float> scratch;
		int64_t read(float *l, float *r, int64_t frames) override;
		void seek(int64_t frame) override;
	};

	Ref<SsWavStream> _stream; // keeps the file bytes alive under the reader
	Reader _reader;
	soundscape::StreamPlayer _player;
};

} // namespace godot

#endif // SOUNDSCAPE_SS_WAV_H
