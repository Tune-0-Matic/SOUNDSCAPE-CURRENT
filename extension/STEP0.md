# Step 0 — vendor and signature verification

Everything here was **measured on this machine against the real 4.7.1 binary**, not
recalled. The whole C++ bridge rests on one claim — that the buffer pointers arrive in
C++ as real pointers — so it is verified rather than assumed.

Re-run this whenever the engine or godot-cpp moves.

---

## 1. The engine's own API declaration

Dumped straight from the binary:

```
godot --headless --dump-extension-api --dump-gdextension-interface
```

```
API version: Godot Engine v4.7.1.stable.official
native_structures: 14
  AudioFrame -> float left;float right
```

```
=== CLASS AudioEffect          inherits Resource    is_instantiable True
   _instantiate    () -> AudioEffectInstance                         [VIRTUAL REQUIRED]
=== CLASS AudioEffectInstance  inherits RefCounted  is_instantiable True
   _process        (const void* src_buffer, AudioFrame* r_dst_buffer,
                    int frame_count) -> void                         [VIRTUAL REQUIRED]
   _process_silence() -> bool                                        [VIRTUAL const]
```

`AudioFrame` is declared in the API's `native_structures` block. That is the whole
reason the ceiling is a GDScript ceiling and not an engine one: GDExtension marshals
these pointers through `Variant` for script, and `Variant` has no pointer type, so
GDScript sees `int`. C++ is handed the pointer itself.

Both `_process` and `_instantiate` are **REQUIRED** virtuals — `SsEffect` must override
`_instantiate` or the effect will not instantiate on a bus.

## 2. godot-cpp vendor audit

**There is no godot-cpp branch or tag for 4.7.** Upstream branches stop at 4.5:

```
git ls-remote --heads https://github.com/godotengine/godot-cpp.git
  -> 4.0  4.1  4.2  4.3  4.4  4.5
git ls-remote --tags  ... | grep '4\.(6|7)'
  -> (nothing)
```

`master` is what carries the 4.7 API. Verified commit:

```
6cceaf6a5f8b0d78ac5d71c139fd7fabba43b918   (2026-09-08)
```

godot-cpp master ships `gdextension/extension_api-4-7.json`. Diffed against this
machine's dump:

```
godot-cpp bundled 4.7 api : Godot Engine v4.7.stable.official
our binary dumped api     : Godot Engine v4.7.1.stable.official
classes: bundled 1036, ours 1036, only-in-ours 0, only-in-bundled 0
bundled _process args: const void* src_buffer, AudioFrame* r_dst_buffer, int frame_count
ours    _process args: const void* src_buffer, AudioFrame* r_dst_buffer, int frame_count
MATCH: True
```

Same class count, no class in one and not the other, identical signature. The 4.7 ->
4.7.1 point release did not move this API.

## 3. The emitted C++ signature — the actual check

Bindings generated from **our** dumped API file, not the bundled one:

```python
import binding_generator
binding_generator.generate_bindings(
    "../extension_api.json",                    # dumped from the 4.7.1 binary
    "gdextension/gdextension_interface.json",
    False, "64", "single", "gen_verify")
```

`gen_verify/gen/include/godot_cpp/classes/audio_effect_instance.hpp`:

```cpp
virtual void _process(const void *p_src_buffer, AudioFrame *r_dst_buffer, int32_t p_frame_count);
virtual bool _process_silence() const;
```

`gen_verify/gen/include/godot_cpp/classes/audio_frame.hpp`:

```cpp
struct AudioFrame {
	float left;
	float right;
};
GDVIRTUAL_NATIVE_PTR(AudioFrame);
```

`gen_verify/gen/include/godot_cpp/classes/audio_effect.hpp`:

```cpp
virtual Ref<AudioEffectInstance> _instantiate();
```

**VERIFIED.** Matches the target signature exactly; the parameter names carry
godot-cpp's `p_`/`r_` prefixes, the types are identical:

```cpp
virtual void _process(const void *src_buffer, AudioFrame *dst_buffer, int32_t frame_count);
```

## 4. Toolchain state on this machine

| Need | State |
|---|---|
| git | present |
| Python 3.12 + pip | present |
| SCons | installed during this step (`pip install scons`) |
| **C++ compiler** | **absent** — no MSVC, no MinGW, no clang, no Windows SDK |

godot-cpp defaults to MinGW on Windows when MSVC is not detected, so the build selects
`g++` and fails at the first compile with *"The system cannot find the file specified"*.
Everything up to that point works — see below.

### To finish the build

```bash
# 1. a toolchain (either one)
#    MSVC: Visual Studio Build Tools, "Desktop development with C++" workload
#    MinGW: w64devkit, or msys2 + mingw-w64-x86_64-gcc

# 2. vendor godot-cpp
git clone --depth 1 --branch master \
    https://github.com/godotengine/godot-cpp.git extension/godot-cpp
git -C extension/godot-cpp checkout 6cceaf6a5f8b0d78ac5d71c139fd7fabba43b918

# 3. build
cd extension
scons target=template_debug

# 4. verify
godot --headless --path .. --script res://test_ss_effect.gd
```

The project lives under OneDrive. A godot-cpp checkout there is ~30 MB of files
OneDrive will sync forever, so put it elsewhere and point at it:

```bash
scons godot_cpp_dir=C:/dev/godot-cpp target=template_debug
```

## 5. What the build script was verified to do

Without a compiler, everything up to the compiler invocation was exercised:

- the missing-`godot-cpp` guard fires with the clone command rather than a stack trace
- `api_version=4.7` reaches godot-cpp; the binding generator runs
  (`Built-in type config: float_64`) and emits `gdextension_interface.h`
- both our sources enter the graph: `Compiling shared src/register_types.cpp`,
  `Compiling shared src/ss_effect.cpp`
- the RT-hardening branch resolves correctly — probed `use_mingw=True`,
  `CCFLAGS` carries `-ffp-contract=off`, `CPPDEFINES` carries `SOUNDSCAPE_DSP`
- the link step targets exactly the path `soundscape.gdextension` declares:

```
bin/libsoundscape_dsp.windows.template_debug.x86_64.dll
```

Built from `env["suffix"]` rather than typed by hand, which is what stops the
SConstruct and the `.gdextension` from drifting apart.

- Godot parses `soundscape.gdextension`, accepts `compatibility_minimum = "4.7"`,
  resolves the `windows.debug.x86_64` key, and reports the binary missing:
  `GDExtension dynamic library not found`. That error is expected and will disappear on
  the first successful build.

## 6. Why `-ffp-contract=off` and not `-ffast-math`

`test_ss_effect.gd` asserts **bit-identical** output using exact float equality. An
optimiser permitted to reassociate float arithmetic or substitute a fused multiply-add
cannot be asked for exactness. Denormal flushing is worth having on an audio path
(a decaying tail near 1e-38 costs hundreds of cycles per sample on x86); reassociation
is not, and the two are bundled together under `-ffast-math`. So: contraction off,
`/fp:precise` on MSVC, and denormal handling done explicitly in a kernel that needs it
rather than globally.

---

## 7. First real build (2026-09-14) -- supersedes the toolchain table in section 4

The compiler gap is closed with a **portable** MinGW, nothing installed system-wide:

| Piece | Where | Version |
|---|---|---|
| w64devkit (GCC, binutils, make) | `C:\dev\w64devkit` | 2.10.0, GCC 16.2.0 |
| godot-cpp | `C:\dev\godot-cpp` (outside OneDrive) | pinned `6cceaf6a`, `extension_api-4-7.json` |
| dr_flac | `extension/src/dr_flac.h` (vendored) | 0.13.4, public domain / MIT-0 |
| SCons | pip | 4.11.1 |

```bash
cd extension
PATH="/c/dev/w64devkit/bin:$PATH" scons godot_cpp_dir=C:/dev/godot-cpp platform=windows use_mingw=yes target=template_debug -j16
PATH="/c/dev/w64devkit/bin:$PATH" scons godot_cpp_dir=C:/dev/godot-cpp platform=windows use_mingw=yes target=template_release -j16
```

The first build of each target compiles all of godot-cpp (6-10 minutes); after that only
`src/*.cpp` rebuild. godot-cpp links MinGW builds with `-static-libgcc -static-libstdc++`, so
the DLL needs no MinGW runtime beside it.

One binding detail cost a build: in the 4.7 API every playback virtual returns `double`
except `AudioStreamPlaybackResampled._get_stream_sampling_rate`, which is `float`. Check
`C:\dev\godot-cpp\gen\include\godot_cpp\classes\*.hpp` before trusting the JSON types.

Verified on the debug DLL:
- `test_ss_effect.gd`: **PASS**, bit-identical through a real bus (4096 frames, 0 mismatches)
- `test_flac_native.gd`: **PASS**, a 24-bit / 96 kHz FLAC decoded by `SsFlacStream` matches
  ffmpeg's own float decode sample for sample (576000 samples, 0 mismatches), and plays,
  seeks and finishes on a real `AudioStreamPlayer`
