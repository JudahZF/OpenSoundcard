# Driver architecture options

## Goal

Build OpenSoundcard as a cross-platform open virtual sound-card stack, starting with GigaACE.

GigaACE has two separate responsibilities:

1. Capture/decode Allen & Heath GigaACE/SLink Ethernet audio frames.
2. Expose decoded PCM to the OS/DAW as a sound-card-like endpoint.

The existing `vendor/gigace` fork already contains a Windows-focused implementation with:

- Npcap capture
- GigaACE frame decoding
- shared-memory audio bridge
- ASIO bridge
- early Windows kernel-driver skeleton
- notes recommending Microsoft SysVAD as the Windows virtual audio baseline

## Recommendation

Use a **shared core + native platform endpoint** design.

Rust is a good fit for the shared core:

- packet parsing / protocol decode
- timing and buffering
- channel mapping
- sample format conversion
- common CLI/tools
- FFI surface exported to C/C++/Objective-C/native plugin shells

Rust is not yet the cleanest first choice for every OS audio endpoint:

- Windows virtual audio drivers still live in WDM/PortCls/WaveRT/SysVAD territory.
- macOS virtual devices use CoreAudio Audio Server Plug-ins or AudioDriverKit.
- Linux can often avoid kernel work by integrating with PipeWire/JACK/ALSA user-space layers.

So: write the portable logic in Rust, but keep each OS endpoint idiomatic and boring until the system works.

## Windows

### Practical first path

1. Keep the current user-mode GigaACE app/bridge working.
2. Use the ASIO bridge for fast DAW testing.
3. Use Microsoft SysVAD as the WDM/WaveRT virtual capture endpoint baseline.
4. Replace SysVAD's sample/tone source with the shared-memory/ring-buffer source.

The GigaACE fork already has `docs/WINDOWS_VIRTUAL_AUDIO_DRIVER.md`, which points at this path.

### Rust on Windows

Microsoft has active Rust-for-Windows-driver work via `windows-drivers-rs` / `cargo-wdk`, including WDM/WDF support. That is promising, but for an audio driver the hardest part is not just “can Rust build a kernel driver”; it is PortCls/WaveRT/SysVAD compatibility, INF/signing, and reliable DAW/OS behavior.

Recommendation: do **not** start the Windows audio endpoint in Rust. Start with SysVAD/C++ for the actual endpoint and use Rust for shared decode/buffer logic behind a C ABI once the behavior is stable.

## Linux

Linux has multiple viable levels:

### User-space first

Best first path:

- PipeWire node/module/client that publishes a capture source
- JACK client for pro-audio workflows
- optional ALSA PCM plugin if direct ALSA clients matter

This avoids kernel module maintenance, DKMS packaging, kernel ABI churn, and signing/security headaches.

### Kernel ALSA later

A true kernel ALSA virtual sound card is possible, but should be later. It adds maintenance burden and probably buys little for the first working GigaACE release if PipeWire/JACK can expose channels cleanly.

Recommendation: Linux endpoint should be user-space first, probably PipeWire + JACK, with a Rust core.

## macOS

macOS options:

1. CoreAudio Audio Server Plug-in — traditional virtual audio device route.
2. AudioDriverKit — newer DriverKit-based model; Apple’s WWDC21 material describes consolidating audio-server plug-in and DriverKit extension packaging.

For a virtual device with no physical hardware, Audio Server Plug-in remains a strong starting point. AudioDriverKit may be worth targeting once packaging/signing and deployment requirements are clearer.

Recommendation: macOS endpoint should be a thin C/Objective-C/Swift native plugin that calls the shared Rust core over C ABI.

## Proposed repository shape

```text
crates/
  opensoundcard-core/        shared audio engine, ring buffers, sample formats
  opensoundcard-gigace/      GigaACE packet decode, channel mapping
  opensoundcard-cli/         capture/replay/analyze tools
platform/
  windows/
    asio/                    development bridge, maybe wraps existing code
    sysvad/                  WDM/WaveRT endpoint based on SysVAD
  linux/
    pipewire/                PipeWire source/client
    jack/                    JACK client
    alsa-plugin/             optional ALSA PCM plugin
  macos/
    coreaudio-plugin/        Audio Server Plug-in shell
vendor/
  gigace/                    current JudahZF/GigaAceSoundcard fork as submodule
```

## First milestones

1. Preserve and document the GigaACE fork as `vendor/gigace`.
2. Extract/prototype a Rust decoder crate from `vendor/gigace/src/core/ace_decoder.c` and related frame structs.
3. Define one common PCM ring-buffer interface.
4. Prove replay-to-audio on one user-space endpoint first:
   - Windows ASIO, or
   - Linux PipeWire/JACK if development is easier locally.
5. Only after stable audio flow, build native OS virtual-device endpoints.

## Key risk

“Cross-platform driver” should not mean one kernel driver codebase. The stable boundary should be the shared Rust core and ring-buffer/PCM API. The OS integration layers should be separate because each platform’s audio driver model is very different.
