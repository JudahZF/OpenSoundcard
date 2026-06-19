# OpenSoundcard

OpenSoundcard is an umbrella project for open virtual sound-card drivers and bridges across macOS, Linux, and Windows.

The first target is **GigaACE**, using JudahZF/GigaAceSoundcard as the protocol/bridge implementation.

## Repository layout

```text
vendor/gigace/        GigaACE implementation fork, tracked as a git submodule
docs/driver-options.md  Initial cross-platform driver architecture notes
```

## Clone with submodules

```bash
git clone --recurse-submodules https://codeberg.org/JudahZF/OpenSoundcard.git
```

If already cloned:

```bash
git submodule update --init --recursive
```

## GigaACE submodule

```bash
git submodule add https://github.com/JudahZF/GigaAceSoundcard.git vendor/gigace
```

Current submodule commit at setup time:

```text
60cc14ef76692d7e49917069014280967d065015 vendor/gigace
```

## Early direction

The practical approach is a shared Rust core where possible, with platform-specific audio endpoint layers:

- protocol decode, packet capture abstraction, ring buffers, and shared audio engine in Rust/C ABI
- Windows endpoint initially based on the existing C++/SysVAD path or ASIO bridge, then Rust where safe
- Linux user-space first through PipeWire/JACK/ALSA plugins before considering kernel ALSA
- macOS virtual device via CoreAudio Audio Server Plug-in or AudioDriverKit, likely thin native shell around shared core

See `docs/driver-options.md` for details.
