# SOUNDSCAPE — System Teardown

**Headless Horseman Edition · v1.0 · by ZFACTOR PSX**
Definitive architectural reference. Every figure below was read from source or measured on
the development machine; nothing is estimated. Where a documented intention and the
measured reality disagree, both are stated and the disagreement is called out.

Generated 10 September 2026 against Godot 4.7.1.stable (`a13da4feb`).

---

## 1. Executive Summary & System Benchmarks

### 1.1 Identity

| Property | Value | Source |
|---|---|---|
| Application name | `SOUNDSCAPE` | `project.godot` `config/name` |
| Byline (header bar) | `SOUNDSCAPE (HEADLESS HORSEMAN) BY ZFACTOR PSX` | `player.tscn` → `Title` |
| Byline (BIOS POST) | `SOUNDSCAPE (HEADLESS HORSEMAN) BY ZFACTORPSX v1.0` | `boot.gd` `LINES[0]` |
| Engine | Godot 4.7.1 stable, Forward+ | `config/features` |
| Render driver | Direct3D 12 | `rendering_device/driver.windows` |
| Physics | Jolt (declared, unused — no 3D physics bodies exist) | `3d/physics_engine` |
| Main scene | `res://player.tscn` | `run/main_scene` |
| Window mode at boot | `3` = **fullscreen**, not maximised | `window/size/mode` |
| Base viewport | 1920 × 1080, `canvas_items` stretch, `expand` aspect | `[display]` |
| Sub-windows | `embed_subwindows=false` → real OS windows | `[display]` |

> **The `window/size/mode=3` value is fullscreen.** This is the single most
> misread setting in the project. Godot's enum is `0=windowed, 1=minimized,
> 2=maximized, 3=fullscreen, 4=exclusive fullscreen`. Fullscreen covers the taskbar,
> which is why the program looks correct at boot and clips at the bottom after a
> monitor move (§5.5).

### 1.2 Design principles

- **Single scene.** `player.tscn`, 117 authored nodes, one root script. No inherited or
  instanced sub-scenes.
- **No autoloads.** Nothing in `[autoload]`. Every subsystem is a child node reached by
  walking down from `MediaPlayer`.
- **No plugins or addons.** No `addons/` directory, no `[editor_plugins]`.
- **No version control.** No `.git` directory exists, despite `.gitignore` and
  `.gitattributes` being present. Review is the only safety net.
- **No external GDScript dependencies.** The only runtime dependency is `ffmpeg` /
  `ffprobe` on `PATH`, used for FLAC transcoding and tag reading.
- **One source of truth per parameter.** Where a value appeared in two widgets, one was
  removed rather than synchronised.
- **Nothing writes to `AudioServer` from inside an input callback.** Every control sets a
  dirty flag; the bus is updated once per frame.

### 1.3 Measured benchmarks

Captured on the development machine — Intel Core i7-13620H (16 threads), NVIDIA GeForce
RTX 4070 Laptop, 15.7 GiB RAM, three displays — with a real FLAC playing and the
visualizer live.

| Metric | Measured | Notes |
|---|---|---|
| Frame time | **16.67 ms** | Smoothed from `_process` delta |
| Frame rate | **60 FPS** | Cap `FPS_DEFAULT = 60`, range 10–240 |
| Draw calls / frame | **117** | `RENDER_TOTAL_DRAW_CALLS_IN_FRAME` |
| Video memory | **43 278 336 B (41.3 MB)** | `RENDER_VIDEO_MEM_USED` |
| — of which texture | 16 146 432 B (15.4 MB) | `RENDER_TEXTURE_MEM_USED` |
| — of which buffer | 6 156 564 B (5.9 MB) | `RENDER_BUFFER_MEM_USED` |
| Static memory | **129 299 940 B (123.3 MB)** | `OS.get_static_memory_usage()` |
| Static memory peak | 139 728 362 B (133.3 MB) | `OS.get_static_memory_peak_usage()` |
| Runtime objects | 2 834 | `OBJECT_COUNT` |
| Runtime nodes | 487 | `OBJECT_NODE_COUNT` (117 authored + runtime-built UI) |
| Bus effects on Master | 13 | 12 from `Equalizer` + 1 analyser |
| Audio output latency | 0.0100 s | `AudioServer.get_output_latency()` |
| Library indexed | 79 tracks across 3 roots | — |

#### The "CPU" figure is frame time, not processor share

The STATS panel reads `CPU.....16.7 MS/FRAME @ 60 FPS`. It is deliberately **not** a
percentage. Godot exposes no system-wide CPU percentage and no per-process CPU time, and
`Performance.TIME_PROCESS` proved untrustworthy here — sampled against real frame time it
reported **43.55 ms of process time inside an 18.06 ms frame**, which is impossible. A
percentage built on it read 377–999 %. The panel now reports the delta `_process` is
handed, which is the frame by definition.

#### Mix rate: requested 96 kHz, delivered by the device

`project.godot` sets `driver/mix_rate=96000`. The **actual** rate is whatever the output
device negotiates: measured **48 000 Hz** in this run, and 96 000 Hz in others on the same
machine. The status ticker prints the live value (`MIX %d HZ`) rather than the requested
one, so the UI never claims a rate the hardware is not running.

---

## 2. Architecture & Scene Hierarchy

### 2.1 Module responsibilities

Total: **4 890 lines** across 10 files.

| File | Lines | Responsibility |
|---|---:|---|
| `player.gd` | 2 545 | Root controller. Every tab, readout and button; owns the two audio players, library index, config file, window management, tear-off windows and the FX rack UI. |
| `visualizer.gd` | 562 | Ten drawing modes over one shared normalization pipeline. Frame-rate-independent ballistics. |
| `equalizer.gd` | 454 | The DSP rack: 12 Master-bus effects driven from one dirty flag. |
| `audio_engine.gd` | 443 | Queue, decode, ffprobe metadata + key tags, FLAC transcode cache, gapless preload. All disk work on workers. |
| `audio_director.gd` | 259 | Spectrum tap, onset detection, tempo lock, predictive beat clock. |
| `countach.gd` | 210 | Wireframe Lamborghini generated from hand-placed `Vector3`s. |
| `skins.gd` | 180 | Eleven colour schemes applied by mutating shared styleboxes in place. |
| `boot.gd` | 114 | BIOS POST screen and name prompt. |
| `test_director.gd` | 83 | Standalone headless accuracy harness for the beat tracker. |
| `crt.gdshader` | 40 | Phosphor bloom + scanlines over the visualizer viewport. |

Non-script assets: `player.tscn` (29 699 B), `intro.ogv` (790 871 B), `logo.png`
(71 964 B), `Px437_IBM_BIOS.ttf` (23 832 B).

Inert: `csharp/KeyDetector.cs`, `csharp/TagKey.cs`, `csharp/AudioFxBridge.cs` — written as
a hybrid-architecture plan, never compiled. The project uses the standard (non-.NET)
Godot build, which ignores `.cs` entirely. Excluded from exports.

### 2.2 Scene tree — `player.tscn`

117 authored nodes. `%` marks `unique_name_in_owner`.

```
MediaPlayer                PanelContainer          ← root, script: player.gd
├─ Margin                  MarginContainer         %  6 px inset, 0 in FULLSCREEN feed
│  └─ Main                 VBoxContainer
│     ├─ TopHeaderBar      PanelContainer          %
│     │  └─ HB             HBoxContainer
│     │     ├─ Title       Label                      byline
│     │     └─ Clock       Label                   %  24 h or 12 h
│     ├─ TickerBar         PanelContainer          %
│     │  └─ Ticker         Label                   %  scrolls 1 char per TickTimer tick
│     ├─ Workspace         SplitContainer          %  vertical flag = portrait
│     │  ├─ LeftColumn     VBoxContainer           %
│     │  │  └─ ScreenPanel PanelContainer          %
│     │  │     └─ SVB      VBoxContainer
│     │  │        ├─ ScreenHeader  PanelContainer     "VISUAL_EQUALIZER_FEED"
│     │  │        ├─ Screen        PanelContainer
│     │  │        │  ├─ Video      VideoStreamPlayer %  optional source video
│     │  │        │  └─ VizBox     SubViewportContainer  stretch_shrink 4, CRT material
│     │  │        │     └─ SubViewport  328×225, transparent, NEAREST
│     │  │        │        └─ Viz  Control        %  script: visualizer.gd
│     │  │        └─ NoSignal      Label             "[ NO SIGNAL ]" / "[ LOADING ]"
│     │  └─ RightSidebar   PanelContainer          %  min width 575 (capped, §5.5)
│     │     └─ Tabs        TabContainer            %  7 tabs, TBS hidden
│     │        ├─ TRACKS   Search, SortRow▸Sort, Tracks(ItemList), Count
│     │        ├─ FOLDERS  FolderTree(Tree), Row▸AddFolder/RemoveFolder/Rescan
│     │        ├─ VISUAL   Skin, VizMode, ColorRow, Sens, Tilt, Height, Speed, Pad
│     │        ├─ EQ       TopRow▸EqMode/EqAdapt, PresetRow, NameRow, EzPanel, AdvPanel
│     │        ├─ TBS      8 settings rows (hidden from the bar — see §5.4)
│     │        └─ STATS    Stats(Label), Reboot
│     ├─ ScrubRow          Elapsed, Scrub(ProgressBar), Total
│     ├─ ControlDeck       Prev, Play, Stop, Next, Shuffle, Repeat, VolPanel▸Vol
│     └─ StatusBar         Status(Label)
├─ Boot                    Control                 %  visible=false until begin()
│  ├─ BG                   ColorRect
│  └─ Text                 Label
├─ Intro                   ColorRect               %  black backdrop
│  └─ IntroVid             VideoStreamPlayer       %  expand=true
├─ AudioA / AudioB         AudioStreamPlayer       %  crossfade pair
├─ Engine                  Node                    %  audio_engine.gd
├─ Eq                      Node                    %  equalizer.gd
├─ Director                Node                    %  audio_director.gd
├─ TickTimer               Timer                   %  ticker scroll
└─ Dialog                  FileDialog              %  native, adds library roots
```

Two rows are **built at runtime**, not authored: `ClockRow` and `IntroRow` are appended to
the TBS tab by `_add_settings_rows()`, bringing that tab to **ten** rows. The entire FX
tab is likewise constructed in code by `_setup_fx()` and inserted at tab index 4.

### 2.3 Runtime lifecycle

#### `_ready()` — exact order

1. **12 assertions** (§6.3). A failure stops the program here.
2. **`ConfigFile.load()`** — all 25 keys (§6.1). `_dedupe_roots()` runs immediately after
   `_folders` is assigned.
3. **Signal wiring & `_setup_*` chain**, in this order:
   `_setup_fade` → `_setup_feed` → `_setup_fps` → `_setup_boost` → `_setup_layout` →
   `_setup_beat` → `_setup_tbs` → `_setup_tbs_window` → `_setup_tear_off`
4. `_refresh_transport`, `_setup_pixel_font`
5. **`_setup_eq()`** — builds the 12-effect bus chain, then calls `_director.rebind()`.
6. **`_setup_fx()`** — builds the FX rack UI, inserts the tab at index 4.
7. **`_capture_tab_order()`** — must run *here*, after the runtime FX tab exists.
8. `_setup_cursor`, `_setup_visual`, `_director.attach(_audio)`
9. **`_rescan()`** — walks every root, prunes the FLAC cache, builds the folder tree,
   applies the checkbox filter, sorts, hands the queue to `AudioEngine`.
10. **`_start_intro()`**
11. **`_save()`** — a full config write, so nothing depends on a later edit.
12. Demo tone if the library is empty; `_stop()`.

> The library is fully walked and the DSP chain fully built **before** the intro appears.
> The intro and BIOS screens cover work that has already finished, not work in progress.

#### Boot sequence

| Stage | Behaviour |
|---|---|
| Logo | `intro.ogv` — Theora video + Vorbis audio, 1280×720, 9.4 s. Any key or click skips. Skippable; audio routes through the Master bus. |
| POST | `boot.gd` reveals its buffer at **150 chars/s**, substituting the real track count into `MOUNTING LIBRARY ... %d TRACKS`. |
| Identify | First run → `ENTER NAME:` (raw key capture, max 16 chars). Returning → `WELCOME BACK <name>`. |
| Enter | SPACE / ENTER → `finished(user_name)` → config write → player live. |

The whole sequence is skippable: the **INTRO VIDEO** setting (TBS tab, default on) bypasses
*both* the video and the POST when off.

> Godot 4 ships **no H.264 decoder**. `VideoStreamPlayer` will not accept an `.mp4` at all.
> The source MP4 was transcoded to Ogg Theora + Vorbis. The previous `intro.ogv` had a
> video stream only — intro audio never worked before this build.

---

## 3. Audio Pipeline & DSP Engine

### 3.1 Decode path

`AudioEngine.request(i)` is the single entry point.

```
request(i)
  ├─ _token += 1                       monotonic; only the newest request is honoured
  ├─ preloaded && path matches? ──────► _deliver(token, path, stream)      [no I/O]
  └─ WorkerThreadPool.add_task:
         decode(path)                  format-specific
         metadata(path)                ffprobe, ~55 ms
         _deliver.bind(...).call_deferred()   ← back on the main thread
```

`_deliver()` drops the result if `token != _token`, so a fast double-click cannot let a
superseded decode hijack playback. On success it emits `track_ready` and immediately
warms the **next** track.

| Format | Path |
|---|---|
| mp3 | `AudioStreamMP3.load_from_file()` |
| ogg | `AudioStreamOggVorbis.load_from_file()` |
| wav | `AudioStreamWAV.load_from_file()` |
| flac | ffmpeg → raw `s16le` → hand-written RIFF header → `AudioStreamWAV`, cached in `user://` |

#### Gapless preload

`_preload()` decodes **and probes** on the worker. The probe is not incidental: without
it, `_deliver()` fell through to `metadata()` on the main thread and spawned ffprobe
there — **measured 54 ms, 3.3 dropped frames, on every gapless transition**. With the
probe warmed, the same call costs **0.02 ms**.

Cost: one decoded stream held in RAM, ~90 MB for a four-minute 96 kHz stereo track.

#### The `WAVE_FORMAT_EXTENSIBLE` trap

Godot 4.7 has **no FLAC decoder** — `AudioStreamFLAC` does not exist. Above 48 kHz,
ffmpeg's WAV muxer emits `WAVE_FORMAT_EXTENSIBLE` (fmt tag `0xFFFE`, 40-byte fmt chunk),
which Godot's parser rejects: `load_from_file` returns `null` **with no error**, presenting
as "the track just will not switch".

The fix is to never let ffmpeg mux. Raw `s16le` is piped out and a canonical 44-byte
header is written by hand (16-byte fmt chunk, `wFormatTag = 1`). Verified loading at
44.1 / 48 / 96 / 192 kHz. `CHUNK = 1 << 20` streams the copy so a 90 MB wav never sits in
RAM twice.

Cache files are `user://pcm_<hash>.wav`, pruned after every scan against what is on **disk**
— unchecking a folder must not force a re-transcode when it is re-checked. A cached file
of ≤ 44 bytes is treated as a miss and re-transcoded (a transcode killed mid-write used to
load as `null` forever).

### 3.2 Metadata, tags and thread safety

`metadata()` shells out to `ffprobe` for sample rate, channels, bit depth, codec, title,
artist, album and musical key. Results never change for a file, so they are cached for
the session in `_meta`.

`_meta` is written from **worker** threads and read from the **main** thread, and a Godot
`Dictionary` is not thread-safe — an insert can rehash under a concurrent read. It is
guarded by `_meta_lock: Mutex` with a deliberate protocol:

```
lock → read cache → unlock
   … probe unlocked (~55 ms) …
lock → if another thread already published, take theirs; else publish ours → unlock
```

The lock is **never** held across the probe. Holding it would serialise every worker and
block the main thread outright — reintroducing the stall the preload fix removed. Two
threads may therefore probe the same file; that costs one duplicate ffprobe and nothing
else, because the first writer wins and every caller ends up holding the same `Dictionary`
instance. Temp JSON is named `probe_<pathhash>_<threadid>.json` so concurrent probes of
the same file cannot clobber one another.

Verified under 24 concurrent workers on 6 files: 144 results, 0 content mismatches, 6
cache entries, 0 leftover temp files.

> `OS.execute()` decodes subprocess output using the **system ANSI codepage**, which
> mojibakes any non-Latin tag (`中原` came back as `ä¸­åŽŸ`). ffprobe writes its JSON to a
> file with `-o`; `FileAccess` reads it back as UTF-8 correctly.

#### Key tags

The key is read from the file's own tag during that same probe — matched
case-insensitively against `KEY`, `INITIALKEY`, `INITIAL_KEY`, `TKEY`, across both
container and stream tags. Whatever the tagger wrote is normalised:

| Input | Output | | Input | Output |
|---|---|---|---|---|
| `Am` | `8A (Am)` | | `F#m` | `11A (F#m)` |
| `8A` | `8A (Am)` | | `Ebm` | `2A (D#m)` |
| `A minor` | `8A (Am)` | | `10B` | `10B (D)` |
| `Amin` | `8A (Am)` | | `Bb` | `6B (A#)` |
| `A` | `11B (A)` | | `13A` | `13A` *(unparsed, passed through)* |

The Camelot number is a circle-of-fifths position with C major pinned at **8B**; a minor
key borrows the number of its **relative** major, which is the entire point of the
notation — same number means compatible. A tag that will not parse is shown verbatim
rather than blanked. Untagged files show `KEY: --` and cost nothing.

> Spectral key **estimation** was built (Goertzel chromagram + Krumhansl-Schmuckler,
> verified exact on synthetic material) and then **removed**: it cost ~1 s of tight-loop
> CPU plus a second concurrent ffmpeg per track, to produce a guess. Tags are free and
> authoritative.

### 3.3 Master bus chain — slots 0–12

Inserted at ascending slots from the head of the bus, so the analyser appended by
`AudioDirector` always ends up last. **The visualizer therefore shows post-EQ audio: what
you see is what you hear.** Bus effects also run *before* bus volume is applied on send, so
none of this is affected by the VOL knob.

| Slot | Effect | Role | Enabled when |
|---:|---|---|---|
| 0 | `LowPassFilter` | DJ filter, cut direction | `live && cut < 0.46` |
| 1 | `HighPassFilter` | DJ filter, boost direction | `live && cut > 0.54` |
| 2 | `PitchShift` | TAPE SPEED × KEY SHIFT | `live && |scale−1| > 0.005` |
| 3 | `EQ21` | 21 bands from a 16-lane curve | `mode != OFF` |
| 4 | `LowShelfFilter` | T-BASS lift, 120 Hz | `tbass > 0.001` |
| 5 | `Distortion` | T-BASS saturation (overdrive) | `tbass > 0.001` |
| 6 | `HighShelfFilter` | BBE sparkle, 3.5 kHz | `bbe > 0.001` |
| 7 | `StereoEnhance` | BBE phase alignment | `bbe > 0.001` |
| 8 | `Delay` | Two-tap stereo delay | `live && dly_on` |
| 9 | `Reverb` | Wet/dry crossfade | `live && rev_on` |
| 10 | `Amplify` | VOLUME BOOST, 0 → 24 dB | `boost_db > 0.05` |
| 11 | `HardLimiter` | Ceiling −0.5 dBFS | any of the above |
| 12 | `SpectrumAnalyzer` | Analysis tap, 32 bands | always |

Every effect is inserted **disabled**; `add_bus_effect` enables by default and the
per-frame push does not run until frame 1, so without this the chain would process a frame
or two before anything had decided it should be on.

Three ordering decisions are load-bearing:

1. **The DJ filter is at the front.** Filtering *after* the reverb would leave the tail
   unfiltered and the sweep would not read as a cut.
2. **Time-based effects follow the tone stage**, so they reverberate the shaped signal.
3. **Boost and limiter are effects, not bus volume.** Bus volume is applied after the
   chain on send, so a limiter placed anywhere else could never catch clipping the rack in
   front of it caused.

> **Adding or removing any bus effect rebuilds every effect *instance* on that bus**,
> silently invalidating the analyser handle `AudioDirector` cached in its own `_ready()` —
> levels then read 0.0 forever with no error. Children are ready before their parent, so
> `_setup_eq()` must call `_director.rebind()` after building the chain. Note that
> `set_bus_effect_enabled()` does **not** rebuild instances; only add/remove does.

#### Enabled-slot verification

With EQ OFF and no FX engaged, a live capture shows exactly one enabled slot:
`12:SpectrumAnalyzer`. Everything else genuinely unloads at rest.

### 3.4 DSP parameters

#### FX rack — `Equalizer.FX_SPEC`

One table drives the UI builder, the readouts and the config section, so a new knob is one
line rather than a setter, getter, save line, load line and slider.

| Key | Label | Min | Max | Default |
|---|---|---:|---:|---:|
| `rev_room` | ROOM SIZE | 0.0 | 1.0 | 0.60 |
| `rev_damp` | DAMPNESS | 0.0 | 1.0 | 0.50 |
| `rev_wet` | WET MIX | 0.0 | 1.0 | 0.30 |
| `dly_ms` | TIME | 20.0 | 1000.0 | 250.0 |
| `dly_fb` | FEEDBACK | 0.0 | 1.0 | 0.35 |
| `dly_wet` | MIX | 0.0 | 1.0 | 0.40 |
| `cut` | CUTOFF | 0.0 | 1.0 | 0.50 |
| `res` | RESONANCE | 0.0 | 1.0 | 0.20 |
| `tape` | TAPE SPEED | 0.5 | 2.0 | 1.0 |
| `key_semi` | KEY SHIFT | −12.0 | 12.0 | 0.0 |

Switches: `rev_on`, `dly_on`, `bypass`. Rack modules:
`[ REVERB UNIT ]`, `[ ECHO / DELAY ]`, `[ DJ FILTER DECK ]`, `[ KEY SHIFT ]`,
plus `[ HARDWARE DRIVE ]` (T-BASS / BBE / DRIVE).

#### DJ filter and its dead centre

`CUT_DEAD = 0.04` — a ±4 % detent around 0.5 where **neither** filter is in circuit.

```
cut < 0.46 →  LOW-PASS,  f = 80 · (20000/80)^(t)      t = cut/0.46
cut > 0.54 →  HIGH-PASS, f = 20 · (8000/20)^(t)       t = (cut−0.54)/0.46
otherwise  →  BYPASS
```

Both sweeps are **logarithmic**. A linear sweep spends most of its travel above 10 kHz,
where nothing is, and crosses the whole audible bass range in the last few pixels. A click
within 6 % of centre snaps to exactly 0.5, because hitting a 8 %-wide detent by pixel while
sweeping is not something a hand can do.

#### T-BASS (bass enhancer)

```
shelf.cutoff_hz  = 120
shelf.gain       = 1.0 + tbass · 1.8        → up to 2.8×
drive.mode       = MODE_OVERDRIVE
drive.keep_hf_hz = 320                       band-limited: thickens, does not fizz
drive.drive      = tbass · 0.35
drive.pre_gain   = tbass · 4.0
drive.post_gain  = −tbass · 6.0              claws back the level the drive adds
```

#### BBE (sonic maximizer)

```
shelf.cutoff_hz        = 3500
shelf.gain             = 1.0 + bbe · 1.5     → up to 2.5×
phase.time_pullout_ms  = bbe · 12.0          inter-channel time offset
phase.surround         = bbe · 0.4
phase.pan_pullout      = 1.0
```

The time offset is the phase-alignment half of what a real Sonic Maximizer does.

> **T-BASS and BBE are independent of the EQ mode.** They used to be gated on
> `mode != OFF`, which made the rack faders silently inert whenever EQ read OFF — the
> fader moved, the readout changed, nothing happened to the sound, with the explanation
> two tabs away. They now behave exactly as `boost_db` always has: the drive stage is the
> hardware colour of the signal, not part of the equalizer curve.

#### Pitch / tape

```
pitch_scale = tape · 2^(key_semi / 12)
```

TAPE SPEED and KEY SHIFT are two views of **one** `AudioEffectPitchShift` — tape in
playback ratio, key in semitones, multiplied. A second shifter would double the most
expensive thing on the bus to say the same thing twice. At TAPE 1.00× and KEY 0 ST the
product is exactly 1.0 and the effect is **switched off**, not merely at unity.

Verified: `+7 ST → 1.4983`, `−12 ST → 0.5000`, `tape 1.25 alone → 1.2500`.

> `AudioStreamPlayer.pitch_scale` is deliberately never touched. Driving it puts every
> frame of a 96 kHz stream through the realtime resampler — measured as audible stutter.

#### Delay

```
tap1: delay = ms,        level = 20·log10(wet),      pan = −0.4
tap2: delay = ms × 1.5,  level = tap1 − 3 dB,        pan = +0.4
feedback: active if fb > 0.005, level = lerp(−30 dB, −3 dB, fb)
dry = 1.0
```

The 1× / 1.5× offset with opposed panning **is** the stereo in "stereo delay"; one centred
tap is an echo, not a spread. Feedback never reaches unity — at 0 dB a delay line never
decays and the tail builds until it clips. −3 dB at the top is still ~10 audible repeats.

#### Reverb

```
room_size = rev_room
damping   = rev_damp
wet       = rev_wet
dry       = 1.0 − rev_wet          a true crossfade
```

A wet send bolted onto a full dry signal would make the level climb with the mix knob, so
WET MIX would read as a volume.

#### Equalizer — 16 lanes onto 21 bands

Godot ships `EQ6`, `EQ10` and `EQ21`; there is no `EQ16`. The 16 UI lanes are a **control
curve**, sampled and linearly interpolated onto EQ21's band gains:

```
for band b in 0..20:
    t = b / 20 · 15
    i = floor(t);  f = t − i
    gain[b] = lerp(curve[i], curve[min(i+1, 15)], f)
```

Lane centres run 32 Hz → 16 kHz logarithmically: `f(i) = 32 · 500^(i/15)`. Only every
fourth lane is labelled — 16 stacked captions is unreadable at that width.

Range `GAIN_MIN −18 dB` … `GAIN_MAX +18 dB`. Modes: **OFF** (bypass), **EZ** (three macros
weighted onto the same curve with raised cosines, so bands overlap smoothly rather than
stepping at the crossover), **ADVANCED** (all 16 + 8 preset slots, `EQ_SLOTS = 8`).

**ADAPT** spreads a change across neighbours with a Gaussian of `ADAPT_SIGMA = 1.6` lanes —
the immediate neighbour lands at ≈0.82 of the dragged lane, the third out at ≈0.17. The
spread is measured from a **snapshot taken when the drag began**; working from live values
would compound the curve into a spike over a long drag.

`BOOST_MAX = 24 dB` (16× amplitude). The hard limiter behind it is what makes that safe:
past the clipping point it saturates instead, so the top of the dial trades dynamics for
loudness rather than breaking up.

### 3.5 Spectrum analysis & beat tracking

`AudioDirector` reads **32 bands** (`BAND_COUNT`) spread logarithmically from
`F_MIN = 30 Hz` to `F_MAX = 16 000 Hz`. That part is nearly free and always runs — it feeds
the visualizer. The tempo machinery on top is **off by default** (`track_tempo = false`)
because the fit sweeps ~560 candidate periods every 0.5 s on the main thread and nothing
but the BPM readout consumes it.

#### `BUFFER_LENGTH = 0.05` is measured, not chosen

| Value | Result |
|---|---|
| 0.10 | beat clock −169 ms, sd 196 — never locks |
| **0.05** | **+6 ms, sd 8** |
| 0.03 | tempo confidence collapses 0.87 → 0.29 |

#### Onset detection

Spectral flux is taken from the **low 11 bands only** (`FLUX_BANDS = 11`, ≈30–250 Hz: kick
and low bass), kick-weighted `1 + 2·(1 − i/32)`. Full-spectrum flux tracks a click track
fine but smears on a real dense mix — measured 0.11 confidence on a pop track versus a
usable lock from these bands.

An onset is flux above the mean of a trailing `FLUX_WINDOW = 43` frame window (≈0.7 s at
60 FPS) × `sensitivity` (default 1.5), plus a 0.12 s debounce (caps at ~500 onsets/min).
There is deliberately **no local-peak test**: it rejected the rising frame of short
transients and starved the fit — 7–11 onsets where 15–30 were present.

#### Tempo fit

Onsets are treated as impulses and the DFT magnitude taken at each candidate tempo:

```
for bpm in 60.0 … 200.0 step 0.25:            561 candidates
    period = 60 / bpm
    re = Σ cos(2π·t/period),  im = Σ sin(2π·t/period)
    magnitude = √(re² + im²) / n
phase = fposmod(atan2(im, re)/2π · period, period)
```

Phase-invariant, and the complex argument hands back the grid phase for free.

**Octave correction:** an eighth-note grid scores as well as the quarter-note one, so if
half the winning tempo scores above **0.8×** the best, the slower reading wins.

**Phase easing:** once locked, phase eases toward each new fit at `PHASE_EASE = 0.25`
rather than snapping. A hard re-anchor every fit jittered the clock to sd 89 ms at 90 BPM;
this is a PLL-lite that stays predictive while still following real drift.

History: `HISTORY = 10.0 s` of onsets, `MIN_ONSETS = 6` below which a fit is noise.

#### True song clock

```
song_time = player.get_playback_position()
          + AudioServer.get_time_since_last_mix()
          − AudioServer.get_output_latency()
```

This removes mix-ahead and output latency. It does **not** cover the analyser's own
trailing-buffer lag, which is why onsets are timestamped back by a separate calibration
constant, `onset_lag = 0.066`, while the beat clock runs on true song time. It is an
exposed knob, not a magic number: 0.035 overcorrects to +42 ms.

`time_to_beat()` returns seconds until the **next predicted** beat, so animation can be
led rather than triggered after the fact. Bar indices derive from the absolute beat index,
so a re-lock re-anchors bars to the music — bars emitted is deliberately *not* beats ÷ 4.

---

## 4. Rendering, CRT Shader & Visualizers

### 4.1 SubViewport upscaling

The visualizer does **not** draw at window resolution.

| Property | Value |
|---|---|
| `SubViewport.size` | 328 × 225 (authored base) |
| `transparent_bg` | true |
| `canvas_item_default_texture_filter` | 0 (nearest) |
| `SubViewportContainer.stretch` | true |
| `stretch_shrink` | 4 |
| `texture_filter` | 1 (nearest) |

With `stretch = true` the SubViewport is resized to `container_size / 4` each layout, so
the authored 328 × 225 is a starting point, not a fixed buffer. Measured live:

| Context | SubViewport |
|---|---|
| LARGE feed, 1920×1080 | 327 × 220 |
| FULLSCREEN feed, screen 0 | 476 × 259 |
| FULLSCREEN feed, portrait screen (1080×1920) | 511 × 259 |
| FULLSCREEN feed, screen 2 (1646×1029) | 476 × 268 |

A "pixel" in a bar is genuinely one buffer texel blown up to a 4×4 block. **Every
coordinate in the drawing code is snapped to an integer** — at this resolution a half-pixel
smears a cell edge and loses the entire point of the viewport. Column edges are snapped
independently so bars tile exactly; some end up 1 px wider, which is correct for pixel art
and is what stops a dead strip appearing on the right at awkward widths.

### 4.2 CRT shader

`crt.gdshader` is a `canvas_item` shader on the **container**, not the viewport. That
ordering matters: the buffer is already upscaled by the time the shader runs, so scanlines
land on real screen pixels rather than on chunky viewport texels — which is what makes them
read as a monitor instead of as part of the artwork.

| Uniform | Range | Value | Effect |
|---|---|---:|---|
| `glow_amount` | 0–3 | **1.15** | Strength of phosphor bloom over the base sample |
| `glow_radius` | 0–8 | **2.2** | Ring offset in texels for the 8-tap blur |
| `scan_strength` | 0–1 | **0.30** | How far dark rows are pulled down |
| `scan_period` | 2–12 | **4.0** | Screen-space px per scanline pair |
| `bleed` | 0–1 | **0.25** | How much of the glow's alpha survives |

```glsl
sum = (8 taps around a ring at ±px, ±0.7px) × 0.125
col = base.rgb + sum.rgb · glow_amount
a   = clamp(base.a + sum.a · glow_amount · bleed, 0, 1)
row = mod(FRAGCOORD.y, scan_period)
col *= mix(1 − scan_strength, 1, step(scan_period·0.5, row))
```

The blur is an 8-tap ring rather than a separable Gaussian: a Gaussian would be cleaner but
needs two passes, and on a 1 px wireframe over black the two are indistinguishable.

> **Glow must carry alpha.** The viewport is transparent. Adding only `sum.rgb` produces a
> bloom that is mathematically present and completely invisible, because destination alpha
> is still zero everywhere the source was.

Hard alternating rows via `step()`, not a soft sine wash — distinct, like a real monitor.

### 4.3 Normalization pipeline

All ten modes read the same 32 magnitudes and pass through the same four stages. The
constants were measured against this library, not guessed.

1. **dB conversion.** `linear_to_db(max(level, 1e-7))`. Linear amplitude leaves a real mix
   pinned to the floor; dB is the only mapping that spreads it over the full height.
2. **Spectral tilt.** `+ tilt_db · i/32`, default **20 dB**, cancelling the library's
   natural ≈39 dB slope (band 0 peaks −7 dBFS, band 28 −46). At tilt 0 the top two-thirds
   of the display never leave the floor.
3. **Auto-gain.** Mandatory, not polish — masters here range −7 to −32 dBFS peak.
   `_agc = max(max(_agc − 8.0·dt, top), −50)`: tracks the loudest band instantly, falls at
   `AGC_FALL = 8 dB/s`, floored at `AGC_FLOOR = −50`.
4. **Ballistics.** Attack 0.22→0.95, release 0.04→0.40, peak-hold fall 0.15→1.30, all
   driven by one SPEED knob. **Attack always outruns release** — equal rates read as
   flicker rather than as an EQ, so the two ranges never cross.

Window span: `lerp(80, 30, sensitivity)` dB.

#### Frame-rate independence

Anything that used to advance "once per `_process`" ran 2.4× faster at 144 FPS than at 60.
`REF_FPS = 60.0` is the reference every per-frame constant was tuned at.

```
_fps_lerp(a, b, k, dt) = lerp(a, b, 1 − (1−k)^(dt · REF_FPS))
```

At exactly 60 FPS the exponent is 1 and this reduces to the original `lerp`, so the tuned
feel is preserved rather than re-guessed. `_due_steps(dt)` converts elapsed time into whole
steps for the discrete effects (waterfall rows, grid history, fire propagation), carrying
the remainder, capped at 4 so a frame hitch replays a few steps instead of hundreds.

Measured:

| | 30 FPS | 60 FPS | 144 FPS |
|---|---|---|---|
| Attack → 90 % | 166.7 ms | 166.7 ms | 159.7 ms |
| Release → 10 % | 966.7 ms | 950.0 ms | 944.4 ms |
| Waterfall rows/s | 60 | 60 | 59 |

Already correctly delta-scaled and left alone: AGC fall, peak decay, hue cycling, tunnel
phase, road phase.

### 4.4 The ten modes

| Mode | Technique |
|---|---|
| **SEGMENTS** | Classic lit-cell ladder; independently snapped column edges. |
| **MIRROR** | The same ladder reflected about the horizontal centre. |
| **WATERFALL** | One row per step into a ring-buffer `Image` (`WF_HEIGHT = 96`), drawn as two offset halves — far cheaper than shifting the image or drawing 32×96 rects. Alpha is `v²`; linear alpha made every cell bright and read as a green wall. |
| **GRID** | Perspective spectrum landscape: `GRID_ROWS = 20` past spectra receding to a horizon, newest at the front. The 90s "3D bars" view, wireframed to stay crisp. |
| **RADIAL** | Spectrum swept around a circle; the 90s scope-panel look. |
| **MATRIX** | Dot-matrix panel where unlit cells stay faintly on, the way a real VFD looks. That dim grid is what separates it from SEGMENTS. |
| **TUNNEL** | Rings receding on a 1/z curve, cross-sectioned by the spectrum itself, so the tube bulges wherever a band is loud. Phase `+= dt·(0.35 + bass·2.4)·speed`. |
| **CRUISE** | The Countach on a receding road, EQ bars along both verges, retrowave sun on the horizon. Phase `+= dt·(2.0 + bass·9.0)·speed`. |
| **FIRE** | Demoscene cellular fire on a deliberately coarse `FIRE_W 56 × FIRE_H 40` grid so it upscales chunky. Bottom row seeded from the spectrum; each cell above averages `(below·2 + left + right)·0.25·cool`. |
| **KALEIDO** | Spectrum swept through a quarter turn and mirrored into the other three quadrants. |

Colour: six presets (green, amber, cyan, white, magenta, red) plus a rainbow mode selected
one past the last preset, cycling hue at ≈16 s per revolution at mid SPEED. Ring modes cap
their radius at the circle inscribed in the canvas — unclamped, `height_scale` at maximum
pushed RADIAL to 0.74 and KALEIDO to 0.81 of the short side, so in a short wide panel the
ring was cut flat and read as a squashed oval.

#### CRUISE projection

```
EYE_Y = 1.30     camera height above the road plane
ROAD_HALF = 5.0  half-width of the tarmac
VERGE = 6.4      x offset of the EQ bars
Z_NEAR = 0.55    RIB_SPACING = 2.4     Z_FAR = 46.0
```

Segments are clipped to the near plane **before** projecting; without that a line crossing
behind the camera wraps to the far side of the screen instead of running off it.

### 4.5 The Countach

Built entirely from hand-placed `Vector3`s in a local space where **+Z is the nose, +Y is
up, and the wheels sit on y = 0**.

The body is **lofted**: nine cross-section rings ("stations") from nose tip to chopped tail
are rungged together with longitudinal rails, producing the wedge without hand-listing
several hundred edges. Each station is
`[z, lower half-width, lower y, waist half-width, waist y, top half-width, top y]`.

| # | z | Station |
|---:|---:|---|
| 0 | +1.70 | nose tip, low wedge |
| 1 | +1.45 | nose break |
| 2 | +1.05 | front axle |
| 3 | +0.62 | windscreen base |
| 4 | +0.18 | roof front |
| 5 | −0.42 | roof rear |
| 6 | −0.85 | rear deck |
| 7 | −1.30 | over rear axle |
| 8 | −1.62 | chopped tail |

**Stations 4–5 are the greenhouse, and the numbers are the car**: top half-width collapses
to **0.40** while the waist stays at **0.72**. That pinch *is* the Countach's narrow cabin
over wide hips.

On top of the loft: deployed pop-up headlights with inset lens faces, side NACA ducts,
shoulder scoops, the rear wing as a closed box so it has thickness in wireframe, flared
arches as 8-segment arcs, and **octagonal wheels** (`WHEEL_R 0.26`, `WHEEL_X 0.70`, axles
at ±1.05) — at this line weight a circle needs far more segments to read as round, and
faceted wheels are truer to the vector-graphics era anyway.

#### Suspension

The edge list is built once in `_init()` and never rebuilt — the body does not deform.
Motion is a transform offset applied at draw time:

```
offset.y = sin(t·47.0)·0.009 + sin(t·31.3)·0.0054      jitter_amp = 0.009
offset.x = sin(t·0.37)·0.11  + sin(t·0.23)·0.0605      sway_amp   = 0.11
```

Detuned sine pairs, so the cycle never visibly repeats. Amplitudes are deliberately tiny:
the road is already moving, so the car only has to stop looking welded to the screen.

---

## 5. UI System, Styling & Responsive Layout

### 5.1 The skin system

Eleven schemes: `WIN98, MAROON, MIDNIGHT, AMBER, TOKYO, TERMINAL, ICE, VAPORWAVE, MIAMI,
C64, HAZARD`.

**The in-place mutation trick.** Every stylebox in `player.tscn` is a *shared sub-resource*.
`Skins.apply()` mutates those resources directly — `sb.bg_color = s.panel` — so a single
write repaints every panel that references it. No theme rebuild, no node walk, no per-node
override.

This is also why the FX rack (built entirely in GDScript) repaints with every skin for
free: it creates **no** styleboxes of its own. A locally-constructed one would be the single
panel stuck on WIN98 grey.

Each scheme defines `window, panel, border, header, header_text, text, screen, screen_text,
accent`, and optionally `accent2`. Where `accent2` exists it drives the **filled** indicators
(progress bars, fader tracks, list selection) while `accent` keeps the text highlights —
that split is what makes the two-tone skins read as two-tone instead of one hue smeared
over everything.

Theme **type variations** rather than per-node overrides: `Header` and `Screen` derive from
`PanelContainer`; `HeaderLabel` and `Green` from `Label`. Every stylebox is a
`StyleBoxFlat` with **corner radius 0** and a 1 px border. Nothing is rounded; nothing has
a shadow.

> **`Skins._flat()` must test `has_stylebox()` first.** For a **missing** entry Godot does
> *not* return `null` — it hands back a fresh default `StyleBoxFlat`, which sails through
> an `is StyleBoxFlat` test. Type-checking alone caught only a wrong-*typed* entry and
> stayed silent on a renamed or deleted one, which is exactly the case the warning exists
> for. Audited across all 11 schemes: no dead entries today.

### 5.2 Typography

`Px437_IBM_BIOS.ttf` — a vector reconstruction of the 8×16 VGA ROM font from the IBM PC
BIOS. Theme `default_font`, `default_font_size = 16`, the size at which its 16 px glyph
cells land on exact pixel boundaries.

Every import setting exists to stop Godot being helpful:

| Setting | Value | Why |
|---|---|---|
| `antialiasing` | 0 | A bitmap-derived face with AA looks like a blurry photocopy of itself |
| `subpixel_positioning` | 0 | Glyphs snap to whole pixels, not fractional offsets |
| `hinting` | 0 | The outlines already sit on the pixel grid |
| `generate_mipmaps` | false | Nothing to scale down to; a mipchain only softens |
| `disable_embedded_bitmaps` | true | — |
| `keep_rounding_remainders` | true | Stops accumulated advance error drifting a long line off grid |

**CJK fallback.** Px437 covers code page 437 — box drawing, a few accents, no Japanese. The
library contains tracks by 中原めいこ, which would render as tofu. `_setup_pixel_font()`
attaches a `SystemFont` chain at runtime:

```
font_names = ["Yu Gothic UI", "Meiryo", "MS Gothic", "Segoe UI"]
antialiasing         = FONT_ANTIALIASING_NONE
subpixel_positioning = SUBPIXEL_POSITIONING_DISABLED
```

The fallback carries the **same** settings. Without that, a Japanese album name renders
smooth and grey beside hard black Latin text in the same label — which reads as a bug, not
as a fallback.

**Cursor.** A 12×19 arrow built in code from an ASCII-art constant (`#` outline, `.` fill,
space transparent), nearest-scaled ×3 (`CURSOR_SCALE`), hotspot at pixel (0,0). Drawing it
rather than shipping a PNG keeps it one file and lets a constant decide how chunky the
pixels read.

### 5.3 Responsive layout

`Workspace` is a `SplitContainer` whose `vertical` flag is the portrait switch.

```
aspect = viewport.x / viewport.y
portrait = aspect < PORTRAIT_BELOW        PORTRAIT_BELOW = 1.1
```

**1.1 rather than 1.0** so a near-square window commits to one layout instead of flickering
between the two on tiny resizes. `AUTO-DETECT` can be overridden by `FORCE LANDSCAPE` /
`FORCE PORTRAIT`.

Feed sizes and their divider fractions:

| Mode | Landscape ratio | Portrait ratio | Divider fraction |
|---|---:|---:|---|
| LARGE | 3.0 | 0.82 | r/(r+1) = 0.750 / 0.451 |
| MEDIUM | 1.5 | 0.54 | 0.600 / 0.351 |
| SMALL | 0.5 | 0.30 | 0.333 / 0.231 |
| GONE | — | — | left column hidden |
| FULLSCREEN | — | — | all chrome hidden, margin 0 |
| CUSTOM | — | — | user's stored `split_frac` |

`SIDEBAR_MIN_X = 575` keeps the tab dock usable beside the feed, but is capped at **half the
viewport** in landscape — on a narrow-but-still-landscape window (700 px is aspect 1.13, so
not portrait) an unconditional 575 leaves the visualizer 125 px and pushes the layout past
the window edge. In portrait the floor is dropped to 0, because stacked it would be a
horizontal floor on the whole window.

> **LARGE cannot reach 3:1.** It lands at 0.694 because the 575 px sidebar floor is a hard
> minimum. This is not a regression: the previous `BoxContainer` gave 0.696 for the same
> reason — minimum size beats stretch ratio.

#### The split solver

`SplitContainer` ignores `size_flags_stretch_ratio`; it positions the divider from
`split_offset`, a **delta from a default set by the children's minimum sizes**. That default
cannot simply be read — measured, `split_offset = 0` is *itself* clamped and reads 102 px
short. The relationship is otherwise exactly linear, slope 1.0:

```
off=0     → first = 1325   (clamped)
off=−200  → first = 1227
off=−400  → first = 1027
off=−1000 → first =  427        ⇒ true default = 1427
```

So `_split_to_fraction()` solves by fixed-point iteration: with slope 1 it lands exactly in
one correction when the target is reachable, and stops itself the moment the offset stops
changing — which is what a clamped mode does. Two frames per pass (the container re-sorts a
frame after the offset is set). A `_split_gen` token drops superseded runs, because
switching feed size twice quickly leaves two coroutines both writing the divider.

**`split_frac` is stored as a fraction, not pixels.** The stretch base pins the viewport
width at 1920 on every screen, so only the height changes — 1080 on the landscape panel,
3413 on the portrait one. A single stored pixel offset was being applied to a *horizontal*
split across 1920 and a *vertical* split across 3413; it could not be correct in both.

Verified across all three monitors: 0.400 requested, 0.400 measured on each.

### 5.4 Detachable windows

`embed_subwindows=false` makes `Window` nodes **real OS windows**. This is global — there is
no per-window override — and it also promotes the FOLDERS file dialog to a native window.

**The settings screen.** The TBS tab is hidden from the tab bar
(`set_tab_hidden`); all ten of its rows pop out into an OS window via the
`[ TBS SCREEN ]` button on STATS. The node is hidden rather than deleted because it is where
the rows go home to when the window closes. Window: 640 × 620, min 430 × 470, centred on the
**usable** rect of its screen.

**Tear-off tabs.** `drag_to_rearrange_enabled = true` is what makes a tab draggable at all.
The tab under the cursor is recorded on `NOTIFICATION_DRAG_BEGIN`; on `DRAG_END`, if
`gui_is_drag_successful()` is false *and* the cursor is outside the TabContainer rect, the
tab tears off into its own window. Size 620 × 720 landscape / 560 × 1000 portrait, clamped
to the screen's usable rect, with the **minimum derived from the panel itself** — measured,
the tabs need 532 / 480 / 412 / 336 px, so the original fixed 380 px floor let EQ be dragged
152 px narrower than it can draw in. Padding drops 6 px → 1 px below 520 px wide.

Restoring uses a **canonical order map**, not a stored index: a stored absolute index goes
stale the moment a second tab is torn off. Verified with three tabs torn off and restored in
a different order than they left.

> **Reparenting and `%UniqueName`.** Measured: `reparent()` preserves a moved node's whole
> subtree of unique-name registrations **when that node has an owner**. A runtime-created
> carrier with no owner loses them for its descendants — silently, so `%EqMode` simply stops
> resolving and the next `_refresh_eq()` dies on a null. `_restore_unique_names()` re-toggles
> the flag over the moved subtree as insurance, since the FX tab is built at runtime and has
> no owner.

### 5.5 Window management & multi-monitor

Every display on the development machine reserves **72 px** for the taskbar:

| Screen | Size | Usable | Taskbar |
|---|---|---|---:|
| 0 | 1920 × 1080 | 1920 × 1008 | 72 |
| 1 | 1080 × 1920 (portrait) | 1080 × 1848 | 72 |
| 2 | 1646 × 1029 | 1646 × 957 | 72 |

The program boots **fullscreen**, which covers the taskbar, so nothing is hidden at rest.
Shift+Win+Arrow moves the window while leaving that mode in place, and the taskbar then
draws over the bottom 72 px — exactly the status bar plus half the transport deck, gone with
nothing to say so.

`_refit_window_to_screen()` polls the current screen index each frame (Godot exposes no
"window changed screen" notification). On a change, if the window hangs past the usable rect
on **either** axis, it switches to **borderless MAXIMIZED**. The first reading is recorded
and never acted on — at boot the window *is* deliberately 72 px past the usable rect.

Why that repair and not another, all measured:

- `WINDOWED` is **unreachable** from the boot fullscreen state on this build — setting it
  reports `EXCLUSIVE_FULLSCREEN` back and `window_set_size` is refused outright.
- Re-asserting `FULLSCREEN` on the new screen changes nothing; still 72 px under.
- `MAXIMIZED` lands inside the usable rect on all three screens, portrait included.
- `BORDERLESS` keeps the chromeless look the fullscreen boot has.

#### F11

`F11` toggles the OS window. Entering saves the current geometry to `_windowed_rect`
(session-only — a saved rect that no longer fits the current monitor arrangement is worse
than none) and sets fullscreen. Leaving clears borderless, goes via `MAXIMIZED`, then
requests `WINDOWED`, verifies the result, and **falls back to borderless MAXIMIZED** if the
release did not take. Geometry is restored exactly:

```
F11 → fullscreen    saved rect = [P:(0,419), S:(1920,1006)]
F11 → windowed      restored   = pos (0,419) size (1920,1006)
```

`ESC` unwinds whichever kind of full screen is on — the in-app FULLSCREEN *feed* first
(hides chrome), then the OS window mode. The two are separate and stack.

Both paths call `_relayout_for_window()`: two frames deferred (the window has not finished
resizing when the mode change returns), then `_update_orientation()` re-reads the viewport,
re-picks portrait/landscape, recomputes the sidebar floor and re-applies the feed — which
re-solves the split from its **fraction**, so the divider lands proportionally right at the
new size. The SubViewport follows on its own via `stretch_shrink`.

Measured on all three monitors in fullscreen: viewport aspect equals window aspect in every
case (no letterboxing), and the FULLSCREEN feed fills the workspace exactly.

### 5.6 Controls

| Input | Action | Notes |
|---|---|---|
| SPACE | Play / pause | A focused `LineEdit` consumes it first, so typing a space in SEARCH is unaffected |
| H | Hide / show mouse pointer | `MOUSE_MODE_HIDDEN`, not `CAPTURED` — the pointer still moves, hovers and clicks |
| F11 | Toggle OS fullscreen | Saves/restores geometry |
| ESC | Leave in-app FULLSCREEN feed, else OS fullscreen | — |
| Any key / click | Skip the logo intro | Handled in the root's `_input`, because Boot has not taken control yet |
| Double-click a fader | Reset to `FX_SPEC` default | Works on every rack bar |
| Click-drag a bar | Set value | Shared `_bar_drag()` predicate |
| REBOOT ×2 | Factory reset | First click arms and shows `CONFIRM?`; a second within 4 s commits |

Scrub and volume are `ProgressBar` + `gui_input`, not `HSlider` — a real slider needs a
grabber texture, and a texture is the one thing the skin system cannot recolour. The EQ's
vertical faders *do* use `VSlider`, so they get a generated 13×7 cap drawn in code in
deliberately neutral grey, so it reads on every skin without being rebuilt when the palette
changes.

> **The zero-width bar trap.** A `Control` not yet laid out still receives input, and
> computing a ratio on a zero-width bar returns 0 for *any* x — silently writing the minimum
> of the range into whatever parameter that bar owns. This is not theoretical: it flattened
> a whole config section to its floor values during testing. Every drag handler tests
> `bar.size.x < 2.0` first.

> **End-of-drag is polled, not awaited.** A release outside the bar is never delivered to
> its `gui_input`; waiting for one let the scrub's drag flag latch on permanently, so a
> later hover kept scrubbing with nothing held down. `_process` polls the button instead.

---

## 6. Data Persistence, Safeguards & Self-Checks

### 6.1 Configuration

State lives in a single `ConfigFile` under `user://` — on Windows,
`%APPDATA%\Godot\app_userdata\SOUNDSCAPE\`.

```gdscript
var _cfg := "user://library_dev.cfg" if OS.has_feature("editor") else "user://library.cfg"
```

The editor and an exported build share `user://` on one machine, so an editor save would
otherwise be the first thing a shipped player sees. On a player's machine neither file
exists yet, so the export always starts clean.

All **25 keys**, verified to both load *and* save (no orphans in either direction):

| Section | Keys |
|---|---|
| `[library]` | `folders`, `enabled_folders`, `known_folders`, `sort`, `tbs`, `shuffle`, `repeat` |
| `[audio]` | `volume`, `boost`, `fade`, `fade_ms`, `play_delay_ms`, `track_tempo` |
| `[visual]` | `feed_size`, `split_frac`, `clock_12h`, `intro_video`, `layout`, `max_fps`, `skin`, `viz` |
| `[eq]` | `state`, `presets` |
| `[effects]` | one entry per `FX_SPEC` key + the three switches (flat and hand-editable) |
| `[stats]` | `total_seconds`, `user_name` |

`[effects]` is written one entry per parameter rather than a single blob, so it stays
readable and hand-editable like every other section — and everything is **re-clamped on
load** rather than trusted, because a plain text file a user can edit will eventually
contain an out-of-range value, and an out-of-range cutoff is an audible fault, not a caught
error.

Two things are deliberately **not** persisted: `Feed.FULLSCREEN` (it would boot into a UI
with no visible way out) and the `[H]` cursor-hidden state (same reason).

`known_folders` exists because the enabled set alone cannot distinguish "the user switched
this off" from "this did not exist yet" — both are simply absent. Treating the second as the
first is what made a freshly dropped album invisible with no error anywhere.

#### Write scheduling

| Trigger | Timing |
|---|---|
| Continuous controls (faders, volume) | `_save_soon()` — **1.5 s debounce**, at most one write regardless of how many controls move |
| Odometer flush | every **30 s** of `_session_secs` |
| Discrete actions (toggles, sort, folders) | immediate `_save()` |
| Application exit | `NOTIFICATION_WM_CLOSE_REQUEST` — the only exit path, so without it the last half-minute is lost |

Both periodic jobs schedule against `_session_secs`, which starts at zero every launch.
`_save_at` previously ran off `_total_secs` — a lifetime counter loaded from config — which
needed re-anchoring after load or the first frame tripped it.

### 6.2 Factory reset

`REBOOT` arms on the first click (`CONFIRM?`) and commits on a second within 4 s. It resets
every persisted setting: library roots, enabled/known folders, TBS list, sort, skin,
username, EQ state and presets, all six visualizer parameters, boost, shuffle, repeat, beat
tracking, layout, clock format, intro video, max FPS, feed size — **and** volume, fade,
fade time, play delay, split fraction and the search filter, each pushing its widget back as
well. A reset that leaves the UI showing old values is worse than one that skips.

Named default constants (`VOLUME_DEFAULT 80.0`, `FADE_ON_DEFAULT true`,
`FADE_MS_DEFAULT 1000`, `DELAY_MS_DEFAULT 250`, `SPLIT_FRAC_DEFAULT 0.5`,
`FPS_DEFAULT 60`) are shared between the config fallbacks and the reset, so the two cannot
drift.

### 6.3 Startup assertion battery

There is no test framework. Pure logic with real branches carries a static self-test, and
those run as `assert()` on every debug launch — a failure stops the program at startup
rather than producing a plausible-looking wrong answer later.

| Assertion | Pins |
|---|---|
| `_fmt`, `_ratio_at` | Time formatting; drag-ratio clamping at both ends |
| `_is_audio` | Extension matching is case-insensitive and rejects cover art |
| `_cmp_by` ×2 | All five sort comparators order as their names claim |
| `peek_next` ×3 | Shuffle never returns the playing track (except a one-track queue); repeat OFF terminates |
| `Equalizer.cut_test` | DJ filter dead centre and both sweep endpoints |
| `Equalizer.pitch_test` | TAPE × KEY SHIFT, and defaults producing exactly 1.0 |
| `AudioEngine.key_tag_test` | 15 tag spellings, four Camelot corners, unparsed passthrough |
| `_viz.fps_lerp_test` | Visualizer settles in the same wall-clock time at 30 / 60 / 144 FPS |
| `clock_test` | 12-hour wrap: midnight and noon are **both** 12 |
| `roots_test` | Library root nesting and path normalisation |

`Equalizer` extends `Node`, not `RefCounted`, so any test constructing one must `free()` it
or leak.

### 6.4 Headless harnesses

**`test_director.gd`** — `godot --headless --path . --script res://test_director.gd`.
Synthesises click tracks at 90 / 120 / 128 / 174 BPM (55 ms kicks, 120 → 45 Hz pitch sweep
with exponential decay — a sub-one-cycle blip is not a fair test signal), plays them, and
asserts locked BPM within **±2.0** and mean phase error within **±30 ms**, judging only the
second half so the lock-in transient is ignored.

> `Engine.max_fps` is load-bearing there: headless Godot runs `_process` uncapped, which
> aliases against the audio mix callback and smears the song clock badly enough to look like
> a tracker bug.

**Visual verification** — `--write-movie <dir>/f.png --fixed-fps 20 --quit-after N` writes a
numbered PNG sequence, so any screen can be inspected without adding debug drawing.

> The render opens a **real window under the mouse**, and stray input lands on whatever
> control is beneath it, silently rewriting persisted settings. Renders go to
> `library_dev.cfg`, so the real library is safe, but the dev config needs resetting after a
> render session.

### 6.5 Known ceilings and deliberate constraints

| Ceiling | Detail |
|---|---|
| **16-bit truncation** | Sample rate is preserved exactly at any rate and FLAC is never re-encoded through a lossy codec — but `AudioStreamWAV` supports 8- and 16-bit PCM only, so a 24-bit source is **always** truncated somewhere. There is no bit-transparent path in this engine version, and no arrangement of these functions creates one. |
| **No FLAC decoder** | `AudioStreamFLAC` does not exist in Godot 4.7; FLAC requires the ffmpeg round-trip. |
| **No H.264** | `VideoStreamPlayer` will not take an `.mp4` at all. Ogg Theora only. |
| **Key from tags only** | Untagged files show `KEY: --`. Spectral estimation was built, measured and removed. |
| **mm:ss rollover** | `_fmt` is mm:ss only, so a 61-minute source reads `61:04`. |
| **Preload holds ~90 MB** | One decoded stream stays in RAM for the next track — the price of gapless-feeling transitions. |
| **Tempo fit is main-thread** | ~560 candidate periods every 0.5 s; ships **off**, and `_process` returns before any of that work when it is off. |
| **`WINDOWED` unreliable** | Not reachable from fullscreen on this build; F11 falls back to borderless MAXIMIZED. |
| **Mix rate is the device's** | The project *requests* 96 kHz; the device decides. The UI prints the live value. |
| **C# files inert** | `csharp/` cannot compile without the .NET Godot build and the .NET SDK, neither of which is installed. Excluded from exports. |
| **No version control** | No `.git`. ~4 900 lines with no history. |

#### Deliberate non-features

- **TBS means TO BE SORTED.** It is now a settings screen; the staging list was removed at
  the owner's request. The `[library] tbs` key is still loaded and saved, so an existing
  list survives untouched if the feature is ever restored.
- **The FX rack's BYPASS does not reach the drive stage.** T-BASS, BBE and the booster are
  the hardware colour of the signal, not spatial effects, so they stay live.
- **The visualizer runs post-EQ deliberately.** The analyser is the last slot so the display
  cannot disagree with the ears.

---

*End of teardown. Every numeric claim above traces to a source file or a measurement taken
on 9–10 September 2026.*
