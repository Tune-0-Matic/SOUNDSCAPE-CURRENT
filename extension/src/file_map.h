/**************************************************************************/
/*  file_map.h                                                            */
/*  A file the decoder can index as bytes without holding it all in RAM.  */
/**************************************************************************/
//
// A DSD64 album track is 170 MB and a DSD128 one twice that, and SsDsdStream used to read every
// byte of it into a PackedByteArray before the first sample played. The decoder never wants the
// whole thing: it walks forward a byte per channel per output frame, and jumps only when the user
// seeks. So the file is MAPPED instead -- the pages arrive when they are touched, the OS reads
// ahead for a sequential walk, and every page is clean and file-backed, so the memory manager can
// take them all back under pressure without a single byte being written anywhere.
//
// What this is NOT is a promise about page faults. The audio thread touching a page that is not
// resident waits for the disk, the same way any player streaming from disk does; sequential
// readahead is what keeps that off the critical path, and the measured cost of a DSD64 stereo walk
// is ~706 KB/s, or about 172 pages a second. A feeder thread with a ring buffer would take even
// that away, at the price of a thread, a seek handshake and a second copy of every byte.
//
// ponytail: mapping, not a ring buffer, and no readahead thread. Revisit if a cold network share
// ever shows up as a stutter -- and note SsWavStream still reads whole files, which is the same
// problem waiting for a big WAV.
//
// Mapping can fail -- a filesystem that will not map, a zero-length file -- so the whole-file read
// is kept as the fallback. Callers see one pointer either way.

#ifndef SOUNDSCAPE_FILE_MAP_H
#define SOUNDSCAPE_FILE_MAP_H

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstdint>
#include <vector>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace soundscape {

class FileMap {
public:
	FileMap() = default;
	~FileMap() { close(); }
	FileMap(const FileMap &) = delete;
	FileMap &operator=(const FileMap &) = delete;

	/// MAIN THREAD. Maps `p_path` read-only. Falls back to reading the file whole, so a true
	/// return still means "the bytes are there"; mapped() says which way it went.
	bool open(const godot::String &p_path) {
		close();
		const godot::String abs = godot::ProjectSettings::get_singleton()->globalize_path(p_path);
		if (_map(abs)) {
			_mapped = true;
			return true;
		}
		const godot::PackedByteArray blob = godot::FileAccess::get_file_as_bytes(p_path);
		if (blob.is_empty()) {
			return false;
		}
		_fallback.assign(blob.ptr(), blob.ptr() + blob.size());
		_data = _fallback.data();
		_size = int64_t(_fallback.size());
		return true;
	}

	void close() {
#ifdef _WIN32
		if (_view) {
			UnmapViewOfFile(_view);
			_view = nullptr;
		}
		if (_mapping) {
			CloseHandle(HANDLE(_mapping));
			_mapping = nullptr;
		}
		if (_file) {
			CloseHandle(HANDLE(_file));
			_file = nullptr;
		}
#else
		if (_addr) {
			munmap(_addr, size_t(_size));
			_addr = nullptr;
		}
		if (_fd >= 0) {
			::close(_fd);
			_fd = -1;
		}
#endif
		_fallback.clear();
		_fallback.shrink_to_fit();
		_data = nullptr;
		_size = 0;
		_mapped = false;
	}

	const uint8_t *data() const { return _data; }
	int64_t size() const { return _size; }
	/// False when the bytes came from the whole-file fallback rather than a mapping.
	bool mapped() const { return _mapped; }

private:
	bool _map(const godot::String &p_abs) {
#ifdef _WIN32
		const godot::CharString utf8 = p_abs.utf8();
		const int wide_len = MultiByteToWideChar(CP_UTF8, 0, utf8.get_data(), -1, nullptr, 0);
		if (wide_len <= 0) {
			return false;
		}
		// two arguments, because `vector<wchar_t> wide(size_t(wide_len))` is a function
		// declaration to GCC, not a variable -- the vexing parse
		std::vector<wchar_t> wide(size_t(wide_len), L'\0');
		MultiByteToWideChar(CP_UTF8, 0, utf8.get_data(), -1, wide.data(), wide_len);
		// shared for reading AND deleting: a mapped track must not stop the library from
		// removing the file, which FILE_SHARE_DELETE is what allows on Windows
		HANDLE file = CreateFileW(wide.data(), GENERIC_READ,
				FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
				FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
		if (file == INVALID_HANDLE_VALUE) {
			return false;
		}
		LARGE_INTEGER len;
		if (!GetFileSizeEx(file, &len) || len.QuadPart <= 0) {
			CloseHandle(file);
			return false;
		}
		HANDLE mapping = CreateFileMappingW(file, nullptr, PAGE_READONLY, 0, 0, nullptr);
		if (!mapping) {
			CloseHandle(file);
			return false;
		}
		void *view = MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, 0);
		if (!view) {
			CloseHandle(mapping);
			CloseHandle(file);
			return false;
		}
		_file = file;
		_mapping = mapping;
		_view = view;
		_data = static_cast<const uint8_t *>(view);
		_size = int64_t(len.QuadPart);
		return true;
#else
		const godot::CharString utf8 = p_abs.utf8();
		const int fd = ::open(utf8.get_data(), O_RDONLY);
		if (fd < 0) {
			return false;
		}
		struct stat st = {};
		if (fstat(fd, &st) != 0 || st.st_size <= 0) {
			::close(fd);
			return false;
		}
		void *addr = mmap(nullptr, size_t(st.st_size), PROT_READ, MAP_PRIVATE, fd, 0);
		if (addr == MAP_FAILED) {
			::close(fd);
			return false;
		}
		// the decoder walks forward and seeks rarely: say so, and the kernel reads ahead
		madvise(addr, size_t(st.st_size), MADV_SEQUENTIAL);
		_fd = fd;
		_addr = addr;
		_data = static_cast<const uint8_t *>(addr);
		_size = int64_t(st.st_size);
		return true;
#endif
	}

	const uint8_t *_data = nullptr;
	int64_t _size = 0;
	bool _mapped = false;
	std::vector<uint8_t> _fallback;
#ifdef _WIN32
	void *_file = nullptr;
	void *_mapping = nullptr;
	void *_view = nullptr;
#else
	int _fd = -1;
	void *_addr = nullptr;
#endif
};

} // namespace soundscape

#endif // SOUNDSCAPE_FILE_MAP_H
