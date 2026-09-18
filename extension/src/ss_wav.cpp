/**************************************************************************/
/*  ss_wav.cpp                                                            */
/**************************************************************************/

#include "ss_wav.h"

#include <godot_cpp/classes/audio_server.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cstring>

// dr_wav v0.14.6 (dr_libs 019e75ba, 2026-08-31), public domain / MIT-0, vendored as
// extension/src/dr_wav.h. Memory-only, like dr_flac: files arrive through Godot's FileAccess,
// which handles res://, user:// and non-ASCII Windows paths that fopen would not.
#define DR_WAV_IMPLEMENTATION
#define DR_WAV_NO_STDIO
#include "dr_wav.h"

using namespace godot;

namespace {

inline drwav *as_wav(void *p) {
	return static_cast<drwav *>(p);
}

} // namespace

/**************************************************************************/
/* SsWavStream -- main thread                                             */
/**************************************************************************/

Ref<SsWavStream> SsWavStream::load_from_file(const String &p_path) {
	Ref<SsWavStream> stream;
	stream.instantiate();
	if (stream->load(p_path) != OK) {
		return Ref<SsWavStream>();
	}
	return stream;
}

int SsWavStream::load(const String &p_path) {
	PackedByteArray bytes = FileAccess::get_file_as_bytes(p_path);
	if (bytes.is_empty()) {
		return ERR_FILE_CANT_OPEN;
	}
	drwav w;
	if (!drwav_init_memory(&w, bytes.ptr(), size_t(bytes.size()), nullptr)) {
		return ERR_FILE_UNRECOGNIZED;
	}
	const int rate = int(w.sampleRate);
	const int channels = int(w.channels);
	const int bits = int(w.bitsPerSample);
	const int64_t frames = int64_t(w.totalPCMFrameCount);
	drwav_uninit(&w);
	if (rate <= 0 || channels <= 0 || frames <= 0) {
		return ERR_FILE_CORRUPT;
	}
	_data = bytes;
	_path = p_path;
	_rate = rate;
	_channels = channels;
	_bits = bits;
	_frames = frames;
	return OK;
}

PackedFloat32Array SsWavStream::decode_frames(int64_t p_from_frame, int64_t p_frame_count) const {
	PackedFloat32Array out;
	if (_data.is_empty() || p_frame_count <= 0) {
		return out;
	}
	drwav w;
	if (!drwav_init_memory(&w, _data.ptr(), size_t(_data.size()), nullptr)) {
		return out;
	}
	if (p_from_frame > 0) {
		drwav_seek_to_pcm_frame(&w, drwav_uint64(p_from_frame));
	}
	out.resize(p_frame_count * _channels);
	const drwav_uint64 got = drwav_read_pcm_frames_f32(&w, drwav_uint64(p_frame_count), out.ptrw());
	drwav_uninit(&w);
	out.resize(int64_t(got) * _channels);
	return out;
}

PackedFloat32Array SsWavStream::render(int p_out_rate, double p_from_seconds, int64_t p_frames) const {
	PackedFloat32Array out;
	Ref<SsWavPlayback> playback;
	playback.instantiate();
	if (p_frames <= 0 || p_out_rate <= 0 || !playback->open(Ref<SsWavStream>(const_cast<SsWavStream *>(this)), p_out_rate)) {
		return out;
	}
	playback->_start(p_from_seconds);
	out.resize(p_frames * 2);
	std::vector<AudioFrame> block(512);
	int64_t done = 0;
	while (done < p_frames) {
		const int32_t want = int32_t(std::min<int64_t>(512, p_frames - done));
		const int32_t got = playback->_mix(block.data(), 1.0f, want);
		for (int32_t i = 0; i < got; ++i) {
			out.set((done + i) * 2, block[size_t(i)].left);
			out.set((done + i) * 2 + 1, block[size_t(i)].right);
		}
		done += got;
		if (got < want) {
			break;
		}
	}
	out.resize(done * 2);
	return out;
}

Ref<AudioStreamPlayback> SsWavStream::_instantiate_playback() const {
	Ref<SsWavPlayback> playback;
	playback.instantiate();
	// const_cast: the playback must hold a Ref to keep the bytes alive, and Ref has no const form
	if (!playback->open(Ref<SsWavStream>(const_cast<SsWavStream *>(this)))) {
		return Ref<AudioStreamPlayback>();
	}
	return playback;
}

String SsWavStream::_get_stream_name() const {
	return _path.get_file();
}

double SsWavStream::_get_length() const {
	return _rate > 0 ? double(_frames) / double(_rate) : 0.0;
}

bool SsWavStream::_is_monophonic() const {
	return false;
}

void SsWavStream::_bind_methods() {
	ClassDB::bind_static_method("SsWavStream", D_METHOD("load_from_file", "path"), &SsWavStream::load_from_file);
	ClassDB::bind_method(D_METHOD("load", "path"), &SsWavStream::load);
	ClassDB::bind_method(D_METHOD("get_sample_rate"), &SsWavStream::get_sample_rate);
	ClassDB::bind_method(D_METHOD("get_channels"), &SsWavStream::get_channels);
	ClassDB::bind_method(D_METHOD("get_bits_per_sample"), &SsWavStream::get_bits_per_sample);
	ClassDB::bind_method(D_METHOD("get_frame_count"), &SsWavStream::get_frame_count);
	ClassDB::bind_method(D_METHOD("decode_frames", "from_frame", "frame_count"), &SsWavStream::decode_frames);
	ClassDB::bind_method(D_METHOD("render", "out_rate", "from_seconds", "frames"), &SsWavStream::render);
}

/**************************************************************************/
/* SsWavPlayback                                                          */
/**************************************************************************/

int64_t SsWavPlayback::Reader::read(float *l, float *r, int64_t frames) {
	// AUDIO THREAD: walks file bytes already in memory into a buffer sized in open()
	drwav *w = as_wav(wav);
	int64_t done = 0;
	while (done < frames) {
		const int64_t want = std::min<int64_t>(frames - done, int64_t(scratch.size()) / channels);
		const drwav_uint64 got = drwav_read_pcm_frames_f32(w, drwav_uint64(want), scratch.data());
		for (drwav_uint64 i = 0; i < got; ++i) {
			const size_t at = size_t(i) * size_t(channels);
			// mono feeds both sides; beyond stereo, the first two channels are the pair
			l[done + int64_t(i)] = scratch[at];
			r[done + int64_t(i)] = channels > 1 ? scratch[at + 1] : scratch[at];
		}
		done += int64_t(got);
		if (got < drwav_uint64(want)) {
			break; // end of stream
		}
	}
	return done;
}

void SsWavPlayback::Reader::seek(int64_t frame) {
	drwav_seek_to_pcm_frame(as_wav(wav), drwav_uint64(frame));
}

SsWavPlayback::~SsWavPlayback() {
	if (_reader.wav != nullptr) {
		drwav_uninit(as_wav(_reader.wav));
		delete as_wav(_reader.wav);
	}
}

bool SsWavPlayback::open(const Ref<SsWavStream> &p_stream, int p_out_rate) {
	if (p_stream.is_null() || p_stream->bytes().is_empty()) {
		return false;
	}
	_stream = p_stream;
	const PackedByteArray &b = _stream->bytes();
	drwav *w = new drwav;
	if (!drwav_init_memory(w, b.ptr(), size_t(b.size()), nullptr)) {
		delete w;
		return false;
	}
	_reader.wav = w;
	_reader.channels = int(w->channels);
	_reader.scratch.assign(size_t(soundscape::SincResampler::kRead) * size_t(_reader.channels), 0.0f);
	const int out_rate = p_out_rate > 0 ? p_out_rate : int(AudioServer::get_singleton()->get_mix_rate());
	_player.open(&_reader, int64_t(w->sampleRate), int64_t(out_rate));
	return true;
}

void SsWavPlayback::_start(double p_from_pos) {
	_player.start(p_from_pos);
}

void SsWavPlayback::_stop() {
	_player.stop();
}

bool SsWavPlayback::_is_playing() const {
	return _player.playing();
}

int32_t SsWavPlayback::_get_loop_count() const {
	return 0;
}

double SsWavPlayback::_get_playback_position() const {
	return _player.position();
}

void SsWavPlayback::_seek(double p_position) {
	_player.seek(p_position);
}

int32_t SsWavPlayback::_mix(AudioFrame *p_buffer, float p_rate_scale, int32_t p_frames) {
	// AUDIO THREAD -- rt.h applies: no allocation, no locks, no Godot API, no I/O
	return _player.mix(p_buffer, p_rate_scale, p_frames);
}

void SsWavPlayback::_bind_methods() {}
