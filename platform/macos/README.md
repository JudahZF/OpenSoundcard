# macOS Development Requirements

OpenSoundcard's first virtual soundcard target is macOS. Use a macOS development
machine for building and validating the CoreAudio HAL plug-in and manager app.

## Prerequisites

- macOS development machine
- Xcode and Xcode command-line tools
- Rust stable toolchain
- `cbindgen`
- Ableton Live for the first DAW validation target

## HAL Plug-In Locations

Verify the CoreAudio HAL plug-in install locations during development:

- `/Library/Audio/Plug-Ins/HAL/`
- `~/Library/Audio/Plug-Ins/HAL/`

## macOS Verification

On a macOS development machine, confirm the local toolchain with:

```bash
sw_vers
xcodebuild -version
rustc --version
cargo --version
```
