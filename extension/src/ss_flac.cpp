/**************************************************************************/
/*  ss_flac.cpp                                                           */
/**************************************************************************/

#include "ss_flac.h"

#include <godot_cpp/classes/audio_server.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cstring>

// dr_flac v0.13.4, public domain / MIT-0, vendored as extension/src/dr_flac.h. Memory-only:
// files arrive through Godot's FileAccess, which handles res://, user:// and non-ASCII
// Windows paths that fopen would not.
#define DR_FLAC_IMPLEMENTATION
#define DR_FLAC_NO_STDIO
#define DR_FLAC_NO_OGG
#include "dr_flac.h"

using namespace godot;

namespace {

inline drflac *as_flac(void *p) {
	return static_cast<drflac *>(p);
}

} // namespace

/**************************************************************************/
/* SsFlacStream -- main thread                                            */
/**************************************************************************/

Ref<SsFlacStream> SsFlacStream::load_from_file(const String &p_path) {
	Ref<SsFlacStream> stream;
	stream.instantiate();
	if (stream->load(p_path) != OK) {
		return Ref<SsFlacStream>();
	}
	return stream;
}

int SsFlacStream::load(const String &p_path) {
	PackedByteArray bytes = FileAccess::get_file_as_bytes(p_path);
	if (bytes.is_empty()) {
		return ERR_FILE_CANT_OPEN;
	}
	drflac *f = drflac_open_memory(bytes.ptr(), size_t(bytes.size()), nullptr);
	if (f == nullptr) {
		return ERR_FILE_UNRECOGNIZED;
	}
	const int rate = int(f->sampleRate);
	const int channels = int(f->channels);
	const int bits = int(f->bitsPerSample);
	const int64_t frames = int64_t(f->totalPCMFrameCount);
	drflac_close(f);
	if (rate <= 0 || channels <= 0) {
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

PackedFloat32Array SsFlacStream::decode_frames(int64_t p_from_frame, int64_t p_frame_count) const {
	PackedFloat32Array out;
	if (_data.is_empty() || p_frame_count <= 0) {
		return out;
	}
	drflac *f = drflac_open_memory(_data.ptr(), size_t(_data.size()), nullptr);
	if (f == nullptr) {
		return out;
	}
	if (p_from_frame > 0) {
		drflac_seek_to_pcm_frame(f, drflac_uint64(p_from_frame));
	}
	out.resize(p_frame_count * _channels);
	const drflac_uint64 got = drflac_read_pcm_frames_f32(f, drflac_uint64(p_frame_count), out.ptrw());
	drflac_close(f);
	out.resize(int64_t(got) * _channels);
	return out;
}

PackedFloat32Array SsFlacStream::render(int p_out_rate, double p_from_seconds, int64_t p_frames) const {
	PackedFloat32Array out;
	Ref<SsFlacPlayback> playback;
	playback.instantiate();
	if (p_frames <= 0 || p_out_rate <= 0 || !playback->open(Ref<SsFlacStream>(const_cast<SsFlacStream *>(this)), p_out_rate)) {
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

Ref<AudioStreamPlayback> SsFlacStream::_instantiate_playback() const {
	Ref<SsFlacPlayback> playback;
	playback.instantiate();
	// const_cast: the playback must hold a Ref to keep the bytes alive, and Ref has no const form
	if (!playback->open(Ref<SsFlacStream>(const_cast<SsFlacStream *>(this)))) {
		return Ref<AudioStreamPlayback>();
	}
	return playback;
}

String SsFlacStream::_get_stream_name() const {
	return _path.get_file();
}

double SsFlacStream::_get_length() const {
	return _rate > 0 ? double(_frames) / double(_rate) : 0.0;
}

bool SsFlacStream::_is_monophonic() const {
	return false;
}

void SsFlacStream::_bind_methods() {
	ClassDB::bind_static_method("SsFlacStream", D_METHOD("load_from_file", "path"), &SsFlacStream::load_from_file);
	ClassDB::bind_method(D_METHOD("load", "path"), &SsFlacStream::load);
	ClassDB::bind_method(D_METHOD("get_sample_rate"), &SsFlacStream::get_sample_rate);
	ClassDB::bind_method(D_METHOD("get_channels"), &SsFlacStream::get_channels);
	ClassDB::bind_method(D_METHOD("get_bits_per_sample"), &SsFlacStream::get_bits_per_sample);
	ClassDB::bind_method(D_METHOD("get_frame_count"), &SsFlacStream::get_frame_count);
	ClassDB::bind_method(D_METHOD("decode_frames", "from_frame", "frame_count"), &SsFlacStream::decode_frames);
	ClassDB::bind_method(D_METHOD("render", "out_rate", "from_seconds", "frames"), &SsFlacStream::render);
}

/**************************************************************************/
/* SsFlacPlayback                                                         */
/**************************************************************************/

int64_t SsFlacPlayback::Reader::read(float *l, float *r, int64_t frames) {
	// AUDIO THREAD: decodes compressed bytes already in memory into a buffer sized in open()
	drflac *f = as_flac(flac);
	int64_t done = 0;
	while (done < frames) {
		const int64_t want = std::min<int64_t>(frames - done, int64_t(scratch.size()) / channels);
		const drflac_uint64 got = drflac_read_pcm_frames_f32(f, drflac_uint64(want), scratch.data());
		for (drflac_uint64 i = 0; i < got; ++i) {
			const size_t at = size_t(i) * size_t(channels);
			// mono feeds both sides; beyond stereo, the first two channels are the pair
			l[done + int64_t(i)] = scratch[at];
			r[done + int64_t(i)] = channels > 1 ? scratch[at + 1] : scratch[at];
		}
		done += int64_t(got);
		if (got < drflac_uint64(want)) {
			break; // end of stream
		}
	}
	return done;
}

void SsFlacPlayback::Reader::seek(int64_t frame) {
	drflac_seek_to_pcm_frame(as_flac(flac), drflac_uint64(frame));
}

SsFlacPlayback::~SsFlacPlayback() {
	if (_reader.flac != nullptr) {
		drflac_close(as_flac(_reader.flac));
	}
}

bool SsFlacPlayback::open(const Ref<SsFlacStream> &p_stream, int p_out_rate) {
	if (p_stream.is_null() || p_stream->bytes().is_empty()) {
		return false;
	}
	_stream = p_stream;
	const PackedByteArray &b = _stream->bytes();
	drflac *f = drflac_open_memory(b.ptr(), size_t(b.size()), nullptr);
	if (f == nullptr) {
		return false;
	}
	_reader.flac = f;
	_reader.channels = int(f->channels);
	_reader.scratch.assign(size_t(soundscape::SincResampler::kRead) * size_t(_reader.channels), 0.0f);
	const int out_rate = p_out_rate > 0 ? p_out_rate : int(AudioServer::get_singleton()->get_mix_rate());
	_player.open(&_reader, int64_t(f->sampleRate), int64_t(out_rate));
	return true;
}

void SsFlacPlayback::_start(double p_from_pos) {
	_player.start(p_from_pos);
}

void SsFlacPlayback::_stop() {
	_player.stop();
}

bool SsFlacPlayback::_is_playing() const {
	return _player.playing();
}

int32_t SsFlacPlayback::_get_loop_count() const {
	return 0;
}

double SsFlacPlayback::_get_playback_position() const {
	return _player.position();
}

void SsFlacPlayback::_seek(double p_position) {
	_player.seek(p_position);
}

int32_t SsFlacPlayback::_mix(AudioFrame *p_buffer, float p_rate_scale, int32_t p_frames) {
	// AUDIO THREAD -- rt.h applies: no allocation, no locks, no Godot API, no I/O
	return _player.mix(p_buffer, p_rate_scale, p_frames);
}

void SsFlacPlayback::_bind_methods() {}
