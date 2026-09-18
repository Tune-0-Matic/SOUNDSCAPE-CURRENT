/**************************************************************************/
/*  ss_dsd.cpp                                                            */
/**************************************************************************/

#include "ss_dsd.h"

#include <godot_cpp/classes/audio_server.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>

using namespace godot;

namespace {

constexpr int64_t kDsd64Base44 = 2822400; // 64 x 44.1 kHz
constexpr int64_t kDsd64Base48 = 3072000; // 64 x 48 kHz
constexpr uint8_t kDsdSilence = 0x69; // four ones, four zeros: a zero-DC byte, not "all minus one"

inline uint32_t le32(const uint8_t *p) {
	return uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
}
inline uint64_t le64(const uint8_t *p) {
	return uint64_t(le32(p)) | (uint64_t(le32(p + 4)) << 32);
}
inline uint16_t be16(const uint8_t *p) {
	return uint16_t((uint16_t(p[0]) << 8) | uint16_t(p[1]));
}
inline uint32_t be32(const uint8_t *p) {
	return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | uint32_t(p[3]);
}
inline uint64_t be64(const uint8_t *p) {
	return (uint64_t(be32(p)) << 32) | uint64_t(be32(p + 4));
}
inline bool id_is(const uint8_t *p, const char *id) {
	return std::memcmp(p, id, 4) == 0;
}
inline uint8_t reverse_bits(uint8_t v) {
	uint8_t r = 0;
	for (int b = 0; b < 8; ++b) {
		r = uint8_t((r << 1) | ((v >> b) & 1));
	}
	return r;
}

} // namespace

/**************************************************************************/
/* soundscape::DsdDecimator                                               */
/**************************************************************************/

namespace soundscape {

void DsdDecimator::configure(const DsdLayout &p_layout, int64_t p_dsd_rate) {
	_layout = p_layout;
	_hist = 16 * std::max(1, _layout.bytes_per_out);
	const int taps = _hist * 8;
	// cutoff at the 8x-rate Nyquist; 128 taps per byte-of-rate at beta 14.5 is ~140 dB, and puts the
	// stop edge near 278 kHz -- clear of 304.8 kHz, the lowest DSD noise that could fold under 48 kHz
	const double pcm_rate = double(p_dsd_rate) / double(8 * std::max(1, _layout.bytes_per_out));
	const double fc = 0.5 * pcm_rate / double(p_dsd_rate);
	constexpr double kPi = 3.14159265358979323846;
	const double beta = 14.5;
	const double i0b = bessel_i0(beta);
	std::vector<double> h(static_cast<size_t>(taps));
	const double center = 0.5 * double(taps - 1);
	double sum = 0.0;
	for (int i = 0; i < taps; ++i) {
		const double d = double(i) - center;
		const double u = 2.0 * fc * d;
		const double sinc = u == 0.0 ? 1.0 : std::sin(kPi * u) / (kPi * u);
		const double x = d / (0.5 * double(taps));
		h[size_t(i)] = 2.0 * fc * sinc * bessel_i0(beta * std::sqrt(std::max(0.0, 1.0 - x * x))) / i0b;
		sum += h[size_t(i)];
	}
	for (double &c : h) {
		c /= sum; // all ones in, exactly +1.0 out
	}
	// byte slot j (0 = newest) holds lags j*8 .. j*8+7; within a byte the earliest bit is bit 0, so
	// the newest -- bit 7 -- is lag j*8
	_table.assign(size_t(_hist) * 256, 0.0);
	for (int j = 0; j < _hist; ++j) {
		for (int v = 0; v < 256; ++v) {
			double s = 0.0;
			for (int b = 0; b < 8; ++b) {
				s += h[size_t(j * 8 + 7 - b)] * (((v >> b) & 1) ? 1.0 : -1.0);
			}
			_table[size_t(j) * 256 + size_t(v)] = s;
		}
	}
	_ring.assign(size_t(std::max(1, _layout.channels)) * size_t(_hist), kDsdSilence);
	_head = 0;
	_pos = 0;
}

uint8_t DsdDecimator::_byte(int p_channel, int64_t p_index) const {
	const int64_t off = _layout.planar
			? (p_index / _layout.block) * _layout.block * _layout.channels + p_channel * _layout.block + (p_index % _layout.block)
			: p_index * _layout.channels + p_channel;
	const uint8_t v = _layout.data[off];
	return _layout.msb_first ? reverse_bits(v) : v;
}

void DsdDecimator::_push() {
	_head = (_head + 1) % _hist;
	for (int ch = 0; ch < _layout.channels; ++ch) {
		_ring[size_t(ch) * size_t(_hist) + size_t(_head)] = _byte(ch, _pos);
	}
	++_pos;
}

double DsdDecimator::_sum(int p_channel) const {
	const uint8_t *ring = &_ring[size_t(p_channel) * size_t(_hist)];
	double s = 0.0;
	for (int j = 0; j < _hist; ++j) {
		int slot = _head - j;
		if (slot < 0) {
			slot += _hist;
		}
		s += _table[size_t(j) * 256 + ring[slot]];
	}
	return s;
}

int64_t DsdDecimator::read(float *l, float *r, int64_t frames) {
	// AUDIO THREAD: table lookups over bytes already in memory
	int64_t n = 0;
	for (; n < frames; ++n) {
		if (_pos + _layout.bytes_per_out > _layout.bytes_per_channel) {
			break;
		}
		for (int k = 0; k < _layout.bytes_per_out; ++k) {
			_push();
		}
		const double left = _sum(0);
		l[n] = float(left);
		r[n] = _layout.channels > 1 ? float(_sum(1)) : float(left);
	}
	return n;
}

void DsdDecimator::seek(int64_t frame) {
	// starts _hist bytes early and runs them through, so a seek lands on exactly the samples a
	// continuous decode would have produced there
	const int64_t target = std::min(std::max<int64_t>(0, frame) * _layout.bytes_per_out, _layout.bytes_per_channel);
	std::fill(_ring.begin(), _ring.end(), kDsdSilence);
	_head = 0;
	_pos = std::max<int64_t>(0, target - _hist);
	while (_pos < target) {
		_push();
	}
}

} // namespace soundscape

/**************************************************************************/
/* SsDsdStream -- main thread                                             */
/**************************************************************************/

Ref<SsDsdStream> SsDsdStream::load_from_file(const String &p_path) {
	Ref<SsDsdStream> stream;
	stream.instantiate();
	if (stream->load(p_path) != OK) {
		return Ref<SsDsdStream>();
	}
	return stream;
}

int SsDsdStream::load(const String &p_path) {
	_data = FileAccess::get_file_as_bytes(p_path);
	if (_data.size() < 16) {
		_data = PackedByteArray();
		return ERR_FILE_CANT_OPEN;
	}
	int err = ERR_FILE_UNRECOGNIZED;
	if (id_is(_data.ptr(), "DSD ")) {
		err = _parse_dsf();
	} else if (id_is(_data.ptr(), "FRM8")) {
		err = _parse_dff();
	}
	if (err != OK) {
		_data = PackedByteArray();
		_layout = soundscape::DsdLayout();
		return err;
	}
	_path = p_path;
	return OK;
}

namespace {

/// Rate family and bytes per 8x-rate frame, or 0 when the rate is not a DSD rate this plays.
int bytes_per_out_for(int64_t p_rate) {
	for (int64_t base : { kDsd64Base44, kDsd64Base48 }) {
		if (p_rate >= base && p_rate % base == 0 && p_rate / base <= 8) {
			return int(p_rate / base);
		}
	}
	return 0;
}

} // namespace

int SsDsdStream::_parse_dsf() {
	// "DSD " chunk, "fmt " chunk, "data" chunk -- all little-endian, 64-bit chunk sizes
	const uint8_t *p = _data.ptr();
	const int64_t n = _data.size();
	if (n < 28 || le64(p + 4) < 28 || int64_t(le64(p + 4)) > n) {
		return ERR_FILE_CORRUPT;
	}
	int64_t at = int64_t(le64(p + 4));
	uint32_t channels = 0, rate = 0, bits = 0, block = 0;
	uint64_t samples = 0;
	bool have_fmt = false;
	while (at + 12 <= n) {
		const uint8_t *c = p + at;
		const uint64_t size = le64(c + 4);
		if (size < 12) {
			return ERR_FILE_CORRUPT;
		}
		if (id_is(c, "fmt ")) {
			if (size < 52 || size > uint64_t(n - at)) {
				return ERR_FILE_CORRUPT;
			}
			if (le32(c + 16) != 0) {
				return ERR_UNAVAILABLE; // format id 0 is raw DSD; nothing else is defined
			}
			channels = le32(c + 24);
			rate = le32(c + 28);
			bits = le32(c + 32);
			samples = le64(c + 36);
			block = le32(c + 44);
			have_fmt = true;
		} else if (id_is(c, "data")) {
			if (!have_fmt || channels < 1 || channels > 8 || block < 1 || (bits != 1 && bits != 8)) {
				return ERR_FILE_CORRUPT;
			}
			const int bpo = bytes_per_out_for(rate);
			if (bpo == 0) {
				return ERR_UNAVAILABLE;
			}
			// a truncated file plays what it holds rather than reading past its end
			const int64_t len = std::min<int64_t>(int64_t(size) - 12, n - at - 12);
			const int64_t whole = (len / (int64_t(block) * channels)) * int64_t(block);
			_layout.data = p + at + 12;
			_layout.channels = int(channels);
			_layout.planar = true;
			_layout.block = int64_t(block);
			_layout.msb_first = bits == 8;
			_layout.bytes_per_out = bpo;
			_layout.bytes_per_channel = std::min<int64_t>(int64_t((samples + 7) / 8), whole);
			if (_layout.bytes_per_channel < bpo) {
				return ERR_FILE_CORRUPT;
			}
			_container = "DSF";
			_dsd_rate = int(rate);
			_pcm_rate = int(rate / (8 * bpo));
			return OK;
		}
		if (size > uint64_t(n - at)) {
			return ERR_FILE_CORRUPT; // unsigned: a hostile 2^63+ size must not wrap negative and walk back
		}
		at += int64_t(size);
	}
	return ERR_FILE_CORRUPT;
}

int SsDsdStream::_parse_dff() {
	// DSDIFF: big-endian IFF with 64-bit sizes, chunks padded to an even length
	const uint8_t *p = _data.ptr();
	const int64_t n = _data.size();
	if (n < 16 || !id_is(p + 12, "DSD ")) {
		return ERR_FILE_UNRECOGNIZED;
	}
	const int64_t end = std::min<int64_t>(n, 12 + int64_t(std::min<uint64_t>(be64(p + 4), uint64_t(INT64_MAX / 2))));
	int64_t at = 16;
	uint32_t rate = 0;
	int channels = 0;
	bool compressed = false;
	int64_t sound_at = -1;
	int64_t sound_len = 0;
	while (at + 12 <= end) {
		const uint8_t *c = p + at;
		const uint64_t size = be64(c + 4);
		const int64_t body = at + 12;
		const bool sound = id_is(c, "DSD ");
		if (size > uint64_t(end - body)) {
			if (!sound) {
				return ERR_FILE_CORRUPT;
			}
			sound_at = body; // truncated sound data: play what is there
			sound_len = end - body;
			break;
		}
		if (id_is(c, "PROP") && size >= 4 && id_is(p + body, "SND ")) {
			int64_t s = body + 4;
			const int64_t prop_end = body + int64_t(size);
			while (s + 12 <= prop_end) {
				const uint8_t *sub = p + s;
				const uint64_t sub_size = be64(sub + 4);
				const int64_t sub_body = s + 12;
				if (sub_size > uint64_t(prop_end - sub_body)) {
					return ERR_FILE_CORRUPT;
				}
				if (id_is(sub, "FS  ") && sub_size >= 4) {
					rate = be32(p + sub_body);
				} else if (id_is(sub, "CHNL") && sub_size >= 2) {
					channels = int(be16(p + sub_body));
				} else if (id_is(sub, "CMPR") && sub_size >= 4) {
					compressed = !id_is(p + sub_body, "DSD ");
				}
				s = sub_body + int64_t(sub_size) + int64_t(sub_size & 1);
			}
		} else if (sound) {
			sound_at = body;
			sound_len = int64_t(size);
		} else if (id_is(c, "DST ")) {
			compressed = true;
		}
		at = body + int64_t(size) + int64_t(size & 1);
	}
	if (compressed) {
		return ERR_UNAVAILABLE;
	}
	const int bpo = bytes_per_out_for(rate);
	if (sound_at < 0 || channels < 1 || channels > 8 || bpo == 0) {
		return bpo == 0 && rate != 0 ? ERR_UNAVAILABLE : ERR_FILE_CORRUPT;
	}
	_layout.data = p + sound_at;
	_layout.channels = channels;
	_layout.planar = false;
	_layout.block = 1;
	_layout.msb_first = true;
	_layout.bytes_per_out = bpo;
	_layout.bytes_per_channel = sound_len / channels;
	if (_layout.bytes_per_channel < bpo) {
		return ERR_FILE_CORRUPT;
	}
	_container = "DFF";
	_dsd_rate = int(rate);
	_pcm_rate = int(rate / (8 * bpo));
	return OK;
}

PackedFloat32Array SsDsdStream::decode_frames(int64_t p_from_frame, int64_t p_frame_count) const {
	PackedFloat32Array out;
	if (_data.is_empty() || p_frame_count <= 0) {
		return out;
	}
	soundscape::DsdDecimator dec;
	dec.configure(_layout, _dsd_rate);
	dec.seek(p_from_frame);
	std::vector<float> l(static_cast<size_t>(p_frame_count)), r(static_cast<size_t>(p_frame_count));
	const int64_t got = dec.read(l.data(), r.data(), p_frame_count);
	out.resize(got * 2);
	for (int64_t i = 0; i < got; ++i) {
		out.set(i * 2, l[size_t(i)]);
		out.set(i * 2 + 1, r[size_t(i)]);
	}
	return out;
}

PackedFloat32Array SsDsdStream::render(int p_out_rate, double p_from_seconds, int64_t p_frames) const {
	PackedFloat32Array out;
	Ref<SsDsdPlayback> playback;
	playback.instantiate();
	if (p_frames <= 0 || p_out_rate <= 0 || !playback->open(Ref<SsDsdStream>(const_cast<SsDsdStream *>(this)), p_out_rate)) {
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

Ref<AudioStreamPlayback> SsDsdStream::_instantiate_playback() const {
	Ref<SsDsdPlayback> playback;
	playback.instantiate();
	if (!playback->open(Ref<SsDsdStream>(const_cast<SsDsdStream *>(this)))) {
		return Ref<AudioStreamPlayback>();
	}
	return playback;
}

String SsDsdStream::_get_stream_name() const {
	return _path.get_file();
}

double SsDsdStream::_get_length() const {
	return _dsd_rate > 0 ? double(_layout.bytes_per_channel * 8) / double(_dsd_rate) : 0.0;
}

bool SsDsdStream::_is_monophonic() const {
	return false;
}

void SsDsdStream::_bind_methods() {
	ClassDB::bind_static_method("SsDsdStream", D_METHOD("load_from_file", "path"), &SsDsdStream::load_from_file);
	ClassDB::bind_method(D_METHOD("load", "path"), &SsDsdStream::load);
	ClassDB::bind_method(D_METHOD("get_sample_rate"), &SsDsdStream::get_sample_rate);
	ClassDB::bind_method(D_METHOD("get_pcm_rate"), &SsDsdStream::get_pcm_rate);
	ClassDB::bind_method(D_METHOD("get_channels"), &SsDsdStream::get_channels);
	ClassDB::bind_method(D_METHOD("get_bits_per_sample"), &SsDsdStream::get_bits_per_sample);
	ClassDB::bind_method(D_METHOD("get_frame_count"), &SsDsdStream::get_frame_count);
	ClassDB::bind_method(D_METHOD("get_container"), &SsDsdStream::get_container);
	ClassDB::bind_method(D_METHOD("decode_frames", "from_frame", "frame_count"), &SsDsdStream::decode_frames);
	ClassDB::bind_method(D_METHOD("render", "out_rate", "from_seconds", "frames"), &SsDsdStream::render);
}

/**************************************************************************/
/* SsDsdPlayback                                                          */
/**************************************************************************/

bool SsDsdPlayback::open(const Ref<SsDsdStream> &p_stream, int p_out_rate) {
	if (p_stream.is_null() || p_stream->layout().data == nullptr) {
		return false;
	}
	_stream = p_stream;
	_decimator.configure(_stream->layout(), _stream->get_sample_rate());
	const int out_rate = p_out_rate > 0 ? p_out_rate : int(AudioServer::get_singleton()->get_mix_rate());
	_player.open(&_decimator, int64_t(_stream->get_pcm_rate()), int64_t(out_rate), kPassHz);
	return true;
}

void SsDsdPlayback::_start(double p_from_pos) {
	_player.start(p_from_pos);
}

void SsDsdPlayback::_stop() {
	_player.stop();
}

bool SsDsdPlayback::_is_playing() const {
	return _player.playing();
}

int32_t SsDsdPlayback::_get_loop_count() const {
	return 0;
}

double SsDsdPlayback::_get_playback_position() const {
	return _player.position();
}

void SsDsdPlayback::_seek(double p_position) {
	_player.seek(p_position);
}

int32_t SsDsdPlayback::_mix(AudioFrame *p_buffer, float p_rate_scale, int32_t p_frames) {
	// AUDIO THREAD -- rt.h applies: no allocation, no locks, no Godot API, no I/O
	return _player.mix(p_buffer, p_rate_scale, p_frames);
}

void SsDsdPlayback::_bind_methods() {}
