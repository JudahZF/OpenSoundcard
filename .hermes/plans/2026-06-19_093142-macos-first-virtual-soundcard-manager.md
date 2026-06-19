# macOS First Virtual Soundcard Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Build the first OpenSoundcard target for macOS: a 64-channel GigaACE-backed virtual input soundcard plus a Virtual Soundcard Manager with both a normal window and menu-bar status/control surface, including stagebox identification/status.

**Architecture:** Use a shared Rust core for GigaACE decode, ring buffering, stream state, stagebox identity/probe logic, and manager-facing status. Use a native macOS CoreAudio Audio Server Driver Plug-in as the first virtual soundcard endpoint. Keep AudioDriverKit as a later spike, not the first path.

**Tech Stack:** Rust workspace, C ABI via `cbindgen`, C/Objective-C/CoreAudio HAL Audio Server Plug-in, Swift/SwiftUI manager app, menu bar `NSStatusItem`, macOS packet capture via libpcap/BPF investigation, install/uninstall shell scripts.

---

## Judah review decisions

1. First macOS MVP exposes **64 channels immediately**.
2. Manager should be **both** a normal windowed SwiftUI app and a menu bar app/status item.
3. Early install/repair should use **scripts**, not privileged in-app installation.
4. No safe committed GigaACE captures are available. Base decoder/stagebox behavior on:
   - current fork: `vendor/gigace`
   - upstream: `https://github.com/juliuskolosnjaji/GigaAceWindowsSoundcard`
5. First DAW validation target is **Ableton Live**.
6. Manager must include **stagebox identification/status** as part of the main status surface.

---

## Current context

- Repository root: `/home/hermes/projects/OpenSoundcard`
- GigaACE submodule: `vendor/gigace`
- Upstream comparison repo inspected locally at: `/home/hermes/projects/GigaAceWindowsSoundcard-upstream`
- Useful current-fork files:
  - `vendor/gigace/src/core/ace_decoder.c`
  - `vendor/gigace/src/core/ace_decoder.h`
  - `vendor/gigace/src/core/frame.h`
  - `vendor/gigace/src/core/shared_bridge.h`
  - `vendor/gigace/src/core/avantis_handshake.cpp`
  - `vendor/gigace/src/tools/gigaace_identify.cpp`
  - `vendor/gigace/docs/STAGEBOX_IDENTITY_PROBING.md`
- Existing stagebox probe variants from the fork:
  - `0 gx4816-slink-48k`
  - `1 gx4816-slink-96k`
  - `2 avantis-header-gx-mac`
  - `3 gx4816-stream01`
  - `4 gx4816-zero-prefix`
  - `5 short-gace-identity`

---

## Product shape

OpenSoundcard macOS should have three cooperating pieces:

1. **Rust core**
   - GigaACE frame decode
   - 64-channel float32 PCM ring buffer
   - status snapshots for app/plugin
   - stagebox identity variants and response detection
   - C ABI for macOS native callers

2. **macOS CoreAudio virtual input plug-in**
   - publishes `OpenSoundcard GigaACE`
   - exposes 64 input channels at 48 kHz
   - reads float32 PCM from the shared engine/ring
   - outputs silence on stopped/underrun

3. **Virtual Soundcard Manager**
   - normal SwiftUI window
   - menu bar status item/popover
   - starts/stops capture and demo tone
   - shows virtual device install/load state
   - shows capture/audio/buffer health
   - shows stagebox identification/probe state
   - exposes install/uninstall/restart script instructions, not privileged in-app install for MVP
   - exports diagnostics

---

## Proposed repository structure

```text
Cargo.toml
crates/
  opensoundcard-core/
    Cargo.toml
    src/lib.rs
    src/ring.rs
    src/status.rs
    src/ffi.rs
  opensoundcard-gigace/
    Cargo.toml
    src/lib.rs
    src/decoder.rs
    src/capture.rs
    src/stagebox_identity.rs
  opensoundcard-cli/
    Cargo.toml
    src/main.rs

platform/macos/
  README.md
  include/
    opensoundcard_ffi.h
  CoreAudioPlugin/
    Info.plist
    OpenSoundcardAudioServerPlugIn.c
    OpenSoundcardAudioServerPlugIn.h
    OpenSoundcardDevice.c
    OpenSoundcardDevice.h
  OpenSoundcardManager/
    OpenSoundcardManager.xcodeproj
    OpenSoundcardManager/
      App.swift
      ContentView.swift
      StatusModel.swift
      OpenSoundcardFFI.swift
      CaptureController.swift
      StageboxStatusModel.swift
      StageboxIdentityController.swift
      DeviceInstallController.swift
      DiagnosticsExporter.swift
  scripts/
    build-macos.sh
    generate-ffi-header.sh
    install-plugin.sh
    uninstall-plugin.sh
    restart-coreaudiod.sh

docs/
  macos-architecture.md
  manager-ui.md
```

---

## Phase 0: macOS build assumptions

### Task 0.1: Document macOS requirements

**Objective:** Make development prerequisites explicit.

**Files:**
- Create: `platform/macos/README.md`

**Include:**
- macOS dev machine
- Xcode + command-line tools
- Rust stable
- `cbindgen`
- Ableton Live as first DAW validation target
- HAL plug-in install locations to verify:
  - `/Library/Audio/Plug-Ins/HAL/`
  - `~/Library/Audio/Plug-Ins/HAL/`

**Verification on macOS:**

```bash
sw_vers
xcodebuild -version
rustc --version
cargo --version
```

**Commit:**

```bash
git add platform/macos/README.md
git commit -m "docs: add macOS build requirements"
```

---

## Phase 1: Rust workspace skeleton

### Task 1.1: Add root Rust workspace

**Objective:** Create a Rust workspace for shared core and GigaACE-specific logic.

**Files:**
- Create: `Cargo.toml`
- Create: `crates/opensoundcard-core/Cargo.toml`
- Create: `crates/opensoundcard-core/src/lib.rs`
- Create: `crates/opensoundcard-gigace/Cargo.toml`
- Create: `crates/opensoundcard-gigace/src/lib.rs`

**Root `Cargo.toml`:**

```toml
[workspace]
members = [
  "crates/opensoundcard-core",
  "crates/opensoundcard-gigace",
]
resolver = "2"

[workspace.package]
edition = "2021"
license = "MIT OR Apache-2.0"
repository = "https://codeberg.org/JudahZF/OpenSoundcard"
```

**Verification:**

```bash
cargo check --workspace
```

Expected: workspace builds.

**Commit:**

```bash
git add Cargo.toml crates/
git commit -m "chore: add Rust workspace skeleton"
```

---

## Phase 2: Shared status and 64-channel ring

### Task 2.1: Add stream status model

**Objective:** Define the fields needed by the CoreAudio plug-in and manager.

**Files:**
- Create: `crates/opensoundcard-core/src/status.rs`
- Modify: `crates/opensoundcard-core/src/lib.rs`

**Fields:**

```rust
#[repr(C)]
pub enum OscStreamState {
    Stopped = 0,
    Starting = 1,
    Running = 2,
    Underrun = 3,
    Error = 4,
}

#[repr(C)]
pub struct OscStatusSnapshot {
    pub state: OscStreamState,
    pub sample_rate: f64,
    pub channel_count: u32,
    pub capacity_frames: u32,
    pub read_index: u64,
    pub write_index: u64,
    pub packet_count: u64,
    pub decoded_frame_count: u64,
    pub underrun_count: u64,
    pub overrun_count: u64,
    pub last_error_code: i32,
}
```

**Verification:**

```bash
cargo test -p opensoundcard-core
```

### Task 2.2: Add 64-channel PCM ring buffer

**Objective:** Implement interleaved float32 ring behavior, designed for 64 channels from the first MVP.

**Files:**
- Create: `crates/opensoundcard-core/src/ring.rs`
- Modify: `crates/opensoundcard-core/src/lib.rs`

**Tests:**
- reads silence before first write
- writes/reads interleaved frames
- handles 64-channel frame writes
- overrun replaces oldest audio
- underrun increments counter and returns silence

**Verification:**

```bash
cargo test -p opensoundcard-core ring
```

**Commit:**

```bash
git add crates/opensoundcard-core
git commit -m "feat: add 64-channel PCM ring and status model"
```

---

## Phase 3: Core C ABI

### Task 3.1: Expose engine lifecycle/status/audio over C ABI

**Objective:** Let CoreAudio and Swift call the Rust core through a stable C ABI.

**Files:**
- Create: `crates/opensoundcard-core/src/ffi.rs`
- Modify: `crates/opensoundcard-core/src/lib.rs`

**Required exports:**

```c
void* osc_engine_create(uint32_t channels, uint32_t capacity_frames, double sample_rate);
void osc_engine_destroy(void* engine);
uint32_t osc_engine_read_interleaved(void* engine, float* output, uint32_t frame_count);
void osc_engine_write_interleaved(void* engine, const float* input, uint32_t frame_count);
void osc_engine_get_status(void* engine, OscStatusSnapshot* out_status);
void osc_engine_set_running(void* engine, bool running);
```

**Verification:**

```bash
cargo test -p opensoundcard-core
cargo build -p opensoundcard-core
```

### Task 3.2: Generate C header

**Files:**
- Create: `cbindgen.toml`
- Create: `platform/macos/scripts/generate-ffi-header.sh`
- Generate: `platform/macos/include/opensoundcard_ffi.h`

**Verification:**

```bash
bash platform/macos/scripts/generate-ffi-header.sh
grep osc_engine_create platform/macos/include/opensoundcard_ffi.h
```

**Commit:**

```bash
git add crates/opensoundcard-core cbindgen.toml platform/macos/include platform/macos/scripts/generate-ffi-header.sh
git commit -m "feat: expose OpenSoundcard core C ABI"
```

---

## Phase 4: GigaACE decoder and stagebox model

### Task 4.1: Add decoder tests from current fork/upstream behavior

**Objective:** Create tests without relying on unavailable `.pcap/.pcapng` fixtures.

**Files:**
- Create: `crates/opensoundcard-gigace/src/decoder.rs`
- Modify: `crates/opensoundcard-gigace/src/lib.rs`

**Approach:**
- Base behavior on `vendor/gigace/src/core/ace_decoder.c`, `frame.h`, and upstream equivalents.
- Use synthetic frames for EtherType/header parsing, PCM24 pack/unpack, channel extraction, and 64-channel frame shape.
- Do not commit fake captures pretending to be real captures. Tiny synthetic unit-test frames are okay if labeled as synthetic.

**Verification:**

```bash
cargo test -p opensoundcard-gigace decoder
```

### Task 4.2: Implement Rust GigaACE decoder

**Objective:** Decode GigaACE frames into interleaved float32 PCM.

**Public API:**

```rust
pub struct DecodedGigaAceFrame {
    pub dst_mac: [u8; 6],
    pub src_mac: [u8; 6],
    pub ethertype: u16,
    pub counter: u8,
    pub stream_type: u8,
    pub channel_count: usize,
    pub pcm: Vec<f32>,
}

pub fn decode_frame(frame: &[u8], max_channels: usize) -> Result<DecodedGigaAceFrame, DecodeError>;
```

**Verification:**

```bash
cargo test -p opensoundcard-gigace
```

### Task 4.3: Port stagebox identity variants

**Objective:** Bring the conservative GX4816/SLink stagebox identity/probe model into Rust.

**Files:**
- Create: `crates/opensoundcard-gigace/src/stagebox_identity.rs`
- Modify: `crates/opensoundcard-gigace/src/lib.rs`

**Base behavior on:**
- `vendor/gigace/docs/STAGEBOX_IDENTITY_PROBING.md`
- `vendor/gigace/src/tools/gigaace_identify.cpp`
- upstream `juliuskolosnjaji/GigaAceWindowsSoundcard` equivalents if needed

**API:**

```rust
pub struct StageboxIdentityVariant {
    pub id: u8,
    pub name: &'static str,
    pub note: &'static str,
    pub ethertype: u16,
    pub stream_type: u8,
    pub frame_len: usize,
    pub packet_rate: f64,
}

pub struct ConsoleResponse {
    pub src_mac: [u8; 6],
    pub known_avantis_mac: bool,
    pub allen_heath_oui: bool,
}

pub fn identity_variants() -> &'static [StageboxIdentityVariant];
pub fn build_identity_frame(variant_id: u8) -> Result<Vec<u8>, StageboxIdentityError>;
pub fn is_console_response(frame: &[u8]) -> Option<ConsoleResponse>;
```

**Verification:**

```bash
cargo test -p opensoundcard-gigace stagebox_identity
```

Expected: all six variants are modeled and console-response detection matches the C++ logic.

**Commit:**

```bash
git add crates/opensoundcard-gigace
git commit -m "feat: add GigaACE decoder and stagebox identity model"
```

---

## Phase 5: macOS CoreAudio plug-in

### Task 5.1: Create CoreAudio plug-in skeleton

**Objective:** Build a HAL Audio Server Driver Plug-in bundle that can publish a virtual input device.

**Files:**
- Create: `platform/macos/CoreAudioPlugin/Info.plist`
- Create: `platform/macos/CoreAudioPlugin/OpenSoundcardAudioServerPlugIn.h`
- Create: `platform/macos/CoreAudioPlugin/OpenSoundcardAudioServerPlugIn.c`
- Create: `platform/macos/CoreAudioPlugin/OpenSoundcardDevice.h`
- Create: `platform/macos/CoreAudioPlugin/OpenSoundcardDevice.c`

**Device properties:**

```text
Name: OpenSoundcard GigaACE
Manufacturer: OpenSoundcard
Transport: Virtual
Direction: Input/capture
Channels: 64
Sample rate: 48000 Hz
Sample format: Float32
```

**Verification on macOS:**

```bash
xcrun clang -fsyntax-only \
  -I platform/macos/include \
  -framework CoreAudio \
  platform/macos/CoreAudioPlugin/*.c
```

### Task 5.2: Publish silence-only 64-channel input

**Objective:** Prove CoreAudio and Ableton can see the virtual device before GigaACE capture works.

**Behavior:**
- Publish one 64-channel input device.
- Return silence for all requested buffers.
- Support start/stop IO calls.
- Report stable sample/host time.

**Verification:**

```bash
system_profiler SPAudioDataType | grep -A8 -i OpenSoundcard
```

Then open Ableton Live and verify `OpenSoundcard GigaACE` is visible as a 64-channel input device.

### Task 5.3: Feed plug-in from Rust engine

**Objective:** Replace silence-only audio with `osc_engine_read_interleaved`.

**Behavior:**
- CoreAudio callback reads from shared engine/ring.
- Stopped/underrun returns silence.
- Status counters update.

**Verification:**
- Start manager demo tone.
- Select `OpenSoundcard GigaACE` input in Ableton Live.
- Record 5 seconds.
- Expected: tone records through the virtual input.

**Commit:**

```bash
git add platform/macos/CoreAudioPlugin
git commit -m "feat: add 64-channel macOS CoreAudio virtual input"
```

---

## Phase 6: macOS scripts

### Task 6.1: Add build script

**Files:**
- Create: `platform/macos/scripts/build-macos.sh`

**Behavior:**
- build Rust release library
- generate FFI header
- build CoreAudio bundle
- build manager app once Xcode project exists

**Verification:**

```bash
bash platform/macos/scripts/build-macos.sh
```

### Task 6.2: Add install/uninstall/restart scripts

**Files:**
- Create: `platform/macos/scripts/install-plugin.sh`
- Create: `platform/macos/scripts/uninstall-plugin.sh`
- Create: `platform/macos/scripts/restart-coreaudiod.sh`

**Behavior:**
- copy/remove HAL plug-in bundle
- restart `coreaudiod`
- print verification command

**Verification:**

```bash
bash platform/macos/scripts/install-plugin.sh
system_profiler SPAudioDataType | grep -A8 -i OpenSoundcard
```

**Commit:**

```bash
git add platform/macos/scripts
git commit -m "chore: add macOS build and install scripts"
```

---

## Phase 7: Virtual Soundcard Manager

### Task 7.1: Create SwiftUI window + menu bar shell

**Objective:** Build both the normal app window and menu bar status surface.

**Files:**
- Create: `platform/macos/OpenSoundcardManager/`
- Create: `platform/macos/OpenSoundcardManager/OpenSoundcardManager/App.swift`
- Create: `platform/macos/OpenSoundcardManager/OpenSoundcardManager/ContentView.swift`
- Create: `platform/macos/OpenSoundcardManager/OpenSoundcardManager/StatusModel.swift`

**UI sections:**

```text
OpenSoundcard GigaACE

Device
- CoreAudio Plug-in: Installed / Not installed
- CoreAudio Device: Loaded / Missing
- Sample Rate: 48 kHz
- Channels: 64

Capture
- Interface: <selected interface>
- State: Stopped / Running / Error
- Packets/sec
- Decoded frames/sec

Stagebox / Console
- Identification: Disabled / Probing / Responding / No response / Error
- Active variant
- Console response frames
- Last console MAC
- Allen & Heath OUI detected
- Last response age
- Last probe error
- Safety warning

Buffer
- Fill estimate
- Read index
- Write index
- Underruns
- Overruns

Controls
- Start Capture
- Stop Capture
- Demo Tone
- Stagebox Probe
- Show install/repair script instructions
- Export Diagnostics
- Open Logs
```

**Verification:**

```bash
xcodebuild -project platform/macos/OpenSoundcardManager/OpenSoundcardManager.xcodeproj -scheme OpenSoundcardManager build
```

Expected: app builds, launches with window, and has a menu bar item/popover.

### Task 7.2: Bind manager to Rust status

**Files:**
- Create: `platform/macos/OpenSoundcardManager/OpenSoundcardManager/OpenSoundcardFFI.swift`
- Modify: `StatusModel.swift`
- Modify: `ContentView.swift`

**Behavior:**
- poll `osc_engine_get_status` every 500ms
- show 64-channel device status
- show counters and last error
- stay responsive if engine/plugin is absent

### Task 7.3: Add 64-channel demo tone mode

**Objective:** Test the virtual device without GigaACE hardware.

**Behavior:**
- demo mode writes a tone to channels 1-2 and silence to remaining channels, or optionally staggered low-level tones across channel groups later
- device remains 64-channel even if only first pair carries tone

**Verification:**
- Ableton sees 64 inputs.
- Ableton records tone from channels 1-2.

**Commit:**

```bash
git add platform/macos/OpenSoundcardManager
git commit -m "feat: add macOS virtual soundcard manager"
```

---

## Phase 8: macOS capture and stagebox probing

### Task 8.1: Add macOS packet capture abstraction

**Objective:** Let the manager capture GigaACE frames from a selected macOS interface.

**Files:**
- Create: `crates/opensoundcard-gigace/src/capture.rs`
- Modify: `platform/macos/OpenSoundcardManager/OpenSoundcardManager/CaptureController.swift`

**Recommendation:** Use `libpcap` first because the current Windows app uses pcap-style capture and it maps naturally to macOS/BPF.

**Verification with hardware:**
- list interfaces
- select interface
- start capture
- packets/sec increments
- decoded frames/sec increments when GigaACE traffic is present

### Task 8.2: Add stagebox status panel

**Files:**
- Create: `platform/macos/OpenSoundcardManager/OpenSoundcardManager/StageboxStatusModel.swift`
- Create: `platform/macos/OpenSoundcardManager/OpenSoundcardManager/StageboxIdentityController.swift`
- Modify: `ContentView.swift`

**Behavior:**
- show active variant
- show response count
- show last console MAC
- show response age
- show no-response/error states cleanly

### Task 8.3: Add bounded stagebox identity probing

**Objective:** Implement macOS equivalent of `GigaAceIdentify.exe --send`.

**Safety:**
- opt-in only
- bounded duration
- visible warning: isolated SLink/GigaACE test link only, not a normal LAN
- only one transmit/probe mode active at a time

**Verification with isolated test link:**
1. Select interface.
2. Start variant `0 gx4816-slink-48k` for 10 seconds.
3. Manager shows response count / last console MAC if console responds.
4. Transmit stops after timer expires.

**Commit:**

```bash
git add crates/opensoundcard-gigace platform/macos/OpenSoundcardManager
git commit -m "feat: add macOS GigaACE capture and stagebox probing"
```

---

## Phase 9: Install status and diagnostics

### Task 9.1: Add plug-in install/load detection

**Files:**
- Create: `platform/macos/OpenSoundcardManager/OpenSoundcardManager/DeviceInstallController.swift`
- Modify: `StatusModel.swift`

**Detection checks:**
- HAL plug-in bundle exists
- bundle version matches manager version
- CoreAudio device named `OpenSoundcard GigaACE` appears
- restart `coreaudiod` suggested if installed but missing
- script paths shown for install/uninstall/restart

### Task 9.2: Add diagnostics export

**Files:**
- Create: `platform/macos/OpenSoundcardManager/OpenSoundcardManager/DiagnosticsExporter.swift`
- Modify: `ContentView.swift`

**Export includes:**

```text
macOS version
app version
plug-in installed path/version
CoreAudio device visible yes/no
Ableton validation notes if entered/available
selected network interface
stream status snapshot
stagebox identification snapshot
last 200 log lines
```

**Verification:**
- click `Export Diagnostics`
- generated file contains all sections

**Commit:**

```bash
git add platform/macos/OpenSoundcardManager
git commit -m "feat: add install status and diagnostics export"
```

---

## Phase 10: End-to-end validation

### Task 10.1: Validate demo tone in Ableton

**Steps:**
1. Build Rust core, CoreAudio plug-in, and manager.
2. Install plug-in with script.
3. Restart CoreAudio with script.
4. Launch manager.
5. Start demo tone.
6. Select `OpenSoundcard GigaACE` as Ableton Live input.
7. Verify Ableton sees 64 channels.
8. Record 5 seconds from channels 1-2.

**Expected:**
- manager shows running state
- CoreAudio device is visible
- Ableton sees 64-channel input
- recording contains tone
- underrun/overrun counters are stable after startup

### Task 10.2: Validate real GigaACE capture in Ableton

**Prerequisites:**
- macOS test machine connected to GigaACE/SLink network
- capture permission granted
- known channel carrying signal

**Steps:**
1. Launch manager.
2. Select network interface.
3. Start capture.
4. Confirm packets/sec and decoded frames/sec increase.
5. Select `OpenSoundcard GigaACE` as Ableton Live input.
6. Record channels 1-2 first.
7. Validate Ableton sees the full 64-channel input device.
8. Expand validation across representative channel pairs, then all 64 channels.

### Task 10.3: Validate stagebox identification/status

**Prerequisites:**
- isolated SLink/GigaACE test link
- console/stagebox connected

**Steps:**
1. Launch manager.
2. Select interface.
3. Open stagebox panel.
4. Run variant `0 gx4816-slink-48k` for 10 seconds.
5. Observe console/stagebox state.
6. Confirm manager shows response/no-response clearly.
7. Export diagnostics.

**Expected:**
- probe is bounded and stops on time
- manager shows active variant, response count, last console MAC if present, and last error/no-response state
- diagnostics include stagebox status

---

## Validation checklist

### Rust

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```

### macOS native

```bash
bash platform/macos/scripts/build-macos.sh
bash platform/macos/scripts/install-plugin.sh
system_profiler SPAudioDataType | grep -A8 -i OpenSoundcard
```

### Manager

```bash
xcodebuild -project platform/macos/OpenSoundcardManager/OpenSoundcardManager.xcodeproj -scheme OpenSoundcardManager build
```

### End-to-end

- CoreAudio sees `OpenSoundcard GigaACE`.
- Manager shows plug-in installed/loaded.
- Manager window and menu bar item both work.
- Ableton sees the 64-channel input device.
- Demo tone records into Ableton.
- GigaACE capture updates manager stats.
- Real GigaACE input records into Ableton.
- Stagebox identification/status handles disabled, probing, responding, no-response, and error states.

---

## Risks / tradeoffs

1. **CoreAudio plug-in packaging/signing can be fiddly.**
   - Mitigation: start with local script install before distribution.

2. **Packet capture permissions on macOS may require elevated privileges or entitlements.**
   - Mitigation: keep capture in manager/helper process and document exact permission model early.

3. **CoreAudio plug-in process boundaries may complicate direct shared state.**
   - Mitigation: start simple; if needed move to named shared memory, XPC, or a small local daemon.

4. **64-channel CoreAudio exposure from MVP may require careful stream layout handling.**
   - Mitigation: keep format fixed at 48 kHz float input and validate in Ableton early.

5. **No safe real capture fixtures are available.**
   - Mitigation: use synthetic tests, compare current fork vs upstream source behavior, and validate with hardware later.

6. **Stagebox identity probing transmits raw identity-like frames.**
   - Mitigation: opt-in only, bounded duration, isolated-link warning, and no simultaneous transmit modes.

---

## MVP acceptance criteria

MVP is done when:

- `OpenSoundcard GigaACE` appears as a macOS 64-channel input device.
- Manager shows installed/loaded/running status.
- Manager works as both a window and menu bar item.
- Manager demo tone records into Ableton Live through the virtual input.
- Ableton Live sees the 64-channel input device.
- Manager can start GigaACE capture from a selected interface.
- Manager shows stagebox identification/status including active variant, response count, and last console MAC.
- At least channels 1-2 record real GigaACE audio into Ableton Live, with follow-up validation across all 64 channels.
- Diagnostics export contains enough audio, capture, stagebox, and install state to debug tester reports.
