/**************************************************************************/
/*  ss_flac.cpp                                                           */
/**************************************************************************/

#include "ss_flac.h"

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

// Frames decoded per read inside one mix call. AudioStreamPlaybackResampled asks for its
// internal block size (well under this), so one read normally covers a whole call.
constexpr int64_t kChunk = 4096;

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
}

/**************************************************************************/
/* SsFlacPlayback                                                         */
/**************************************************************************/

SsFlacPlayback::~SsFlacPlayback() {
	if (_flac != nullptr) {
		drflac_close(as_flac(_flac));
	}
}

bool SsFlacPlayback::open(const Ref<SsFlacStream> &p_stream) {
	if (p_stream.is_null() || p_stream->bytes().is_empty()) {
		return false;
	}
	_stream = p_stream;
	const PackedByteArray &b = _stream->bytes();
	drflac *f = drflac_open_memory(b.ptr(), size_t(b.size()), nullptr);
	if (f == nullptr) {
		return false;
	}
	_flac = f;
	_channels = int(f->channels);
	_rate = double(f->sampleRate);
	_scratch.assign(size_t(kChunk) * size_t(_channels), 0.0f);
	return true;
}

void SsFlacPlayback::_start(double p_from_pos) {
	_seek(p_from_pos);
	_active.store(true);
	begin_resample();
}

void SsFlacPlayback::_stop() {
	_active.store(false);
}

bool SsFlacPlayback::_is_playing() const {
	return _active.load();
}

int32_t SsFlacPlayback::_get_loop_count() const {
	return 0;
}

double SsFlacPlayback::_get_playback_position() const {
	return _rate > 0.0 ? double(_position.load()) / _rate : 0.0;
}

void SsFlacPlayback::_seek(double p_position) {
	const int64_t frame = std::max<int64_t>(0, int64_t(p_position * _rate));
	_position.store(frame);
	_pending_seek.store(frame);
}

float SsFlacPlayback::_get_stream_sampling_rate() const {
	return float(_rate);
}

int32_t SsFlacPlayback::_mix_resampled(AudioFrame *r_dst_buffer, int32_t p_frame_count) {
	// ===================== AUDIO THREAD -- RT CONTRACT APPLIES =====================
	// No allocation, no locks, no Godot API, no I/O: the decoder reads the compressed bytes
	// already in memory and writes into a buffer sized in open().
	// ==============================================================================
	drflac *f = as_flac(_flac);
	if (f == nullptr || r_dst_buffer == nullptr || p_frame_count <= 0 || !_active.load(std::memory_order_relaxed)) {
		return 0;
	}

	const int64_t seek = _pending_seek.exchange(-1, std::memory_order_relaxed);
	if (seek >= 0) {
		drflac_seek_to_pcm_frame(f, drflac_uint64(seek));
	}

	int32_t done = 0;
	while (done < p_frame_count) {
		const int64_t want = std::min<int64_t>(p_frame_count - done, kChunk);
		const drflac_uint64 got = drflac_read_pcm_frames_f32(f, drflac_uint64(want), _scratch.data());
		for (drflac_uint64 i = 0; i < got; ++i) {
			const size_t at = size_t(i) * size_t(_channels);
			// mono feeds both sides; beyond stereo, the first two channels are the pair
			r_dst_buffer[done + int32_t(i)].left = _scratch[at];
			r_dst_buffer[done + int32_t(i)].right = _channels > 1 ? _scratch[at + 1] : _scratch[at];
		}
		done += int32_t(got);
		if (got < drflac_uint64(want)) {
			break; // end of stream
		}
	}

	_position.fetch_add(done, std::memory_order_relaxed);
	if (done < p_frame_count) {
		for (int32_t i = done; i < p_frame_count; ++i) {
			r_dst_buffer[i].left = 0.0f;
			r_dst_buffer[i].right = 0.0f;
		}
		_active.store(false, std::memory_order_relaxed); // lets AudioStreamPlayer emit finished
	}
	return done;
}

void SsFlacPlayback::_bind_methods() {}
