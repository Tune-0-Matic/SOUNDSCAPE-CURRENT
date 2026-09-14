/**************************************************************************/
/*  ss_flac.h                                                             */
/*  SsFlacStream / SsFlacPlayback -- native FLAC, no transcode.           */
/**************************************************************************/
//
// Godot 4.7 has no FLAC decoder, so every FLAC used to go through ffmpeg into a 16-bit WAV
// cached in user:// -- 30-120 MB per track, a process spawn per cold track, and 24-bit
// sources truncated to 16 on the way. This decodes the FLAC itself, with dr_flac, straight
// into the mixer:
//
//   - the COMPRESSED file is what stays in memory; frames are decoded block by block inside
//     the mix, so there is no decoded copy and no cache file at all
//   - samples are handed over as 32-bit float, which holds every 24-bit value exactly
//   - the file's own sample rate is kept; AudioStreamPlaybackResampled converts it to the
//     mix rate with Godot's own resampler, exactly as it does for Ogg and MP3
//
// The audio-thread half follows rt.h: _mix_resampled reads only memory that was allocated
// on the main thread before playback started, and the one thing the main thread can change
// under it -- a seek -- crosses as an atomic, applied at the top of the next block.

#ifndef SOUNDSCAPE_SS_FLAC_H
#define SOUNDSCAPE_SS_FLAC_H

#include <godot_cpp/classes/audio_frame.hpp>
#include <godot_cpp/classes/audio_stream.hpp>
#include <godot_cpp/classes/audio_stream_playback.hpp>
#include <godot_cpp/classes/audio_stream_playback_resampled.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

#include <atomic>
#include <vector>

namespace godot {

class SsFlacStream : public AudioStream {
	GDCLASS(SsFlacStream, AudioStream)

public:
	/// null when the file cannot be read or is not FLAC. Mirrors AudioStreamMP3.load_from_file.
	static Ref<SsFlacStream> load_from_file(const String &p_path);

	/// OK (0), or a Godot Error code as an int. Reads the whole file and validates its header.
	int load(const String &p_path);

	int get_sample_rate() const { return _rate; }
	int get_channels() const { return _channels; }
	int get_bits_per_sample() const { return _bits; }
	int64_t get_frame_count() const { return _frames; }

	/// Interleaved float frames decoded on the CALLING thread with a private decoder --
	/// for verification and analysis, never used by playback.
	PackedFloat32Array decode_frames(int64_t p_from_frame, int64_t p_frame_count) const;

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

class SsFlacPlayback : public AudioStreamPlaybackResampled {
	GDCLASS(SsFlacPlayback, AudioStreamPlaybackResampled)

public:
	SsFlacPlayback() = default;
	~SsFlacPlayback() override;

	/// MAIN THREAD. Opens the decoder over the stream's bytes and sizes the scratch buffer --
	/// the only allocations this playback ever makes.
	bool open(const Ref<SsFlacStream> &p_stream);

	void _start(double p_from_pos) override;
	void _stop() override;
	bool _is_playing() const override;
	int32_t _get_loop_count() const override;
	double _get_playback_position() const override;
	void _seek(double p_position) override;
	int32_t _mix_resampled(AudioFrame *r_dst_buffer, int32_t p_frame_count) override;
	float _get_stream_sampling_rate() const override; // float in the 4.7 binding, unlike its neighbours

protected:
	static void _bind_methods();

private:
	Ref<SsFlacStream> _stream; // keeps the compressed bytes alive under the decoder
	void *_flac = nullptr; // drflac*, kept opaque so this header need not include dr_flac.h
	std::vector<float> _scratch;
	int _channels = 0;
	double _rate = 44100.0;
	std::atomic<bool> _active{ false };
	std::atomic<int64_t> _pending_seek{ -1 };
	std::atomic<int64_t> _position{ 0 };
};

} // namespace godot

#endif // SOUNDSCAPE_SS_FLAC_H
