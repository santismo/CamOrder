# CamOrder Studio AU 0.4.0 verification

Checked on an Intel Mac on September 26, 2026. The released component and capture helper match the locally installed and tested binaries. Component version is 0.4.0 (`0x400`), identity `aufx / CmSt / Sntm`. Both bundles pass deep, strict code-signature verification with local ad-hoc signatures.

## Completed checks

- **33 Swift tests passed:** encoded MOV/MP4 exports, trimmed first-frame colors, audio-cue alignment after offsets, custom ranges, negative offsets, project compatibility, region priority, splits, animated framing, capture delivery and transport gaps.
- **Apple `auval` passed** against the installed 0.4.0 component.
- **Native Audio Unit integration passed:** bit-exact mono/stereo audio at 44.1, 48 and 96 kHz with 1/64/512-frame blocks, silent input, instance-state isolation, transport callbacks and editor open/close/reopen.
- **Production session tests passed without an editor:** Play/Record capture, host following, stop and repeated takes, missing callbacks, manual finalization, keyboard handoff, fallback MIDI timing and saved edits/offsets/undo.
- **Multiple inputs passed:** three lanes sharing one encoded movie; three independent cameras with one simulated disconnect; independent late arm/stop on a shared source; four simultaneous synthetic-camera movies; assignment save/reopen.
- **Four capture-helper processes passed:** independent command channels, discovery and clean shutdown, without activating physical cameras.
- **Native UI checks passed:** actual canvas-corner and window-grip drags, sizes from 720 × 360 to 1280 × 960, including arbitrary 803 × 417 sizing. Screenshots use an owned native AU test host.
- **Playback checks:** 51 decoded frames in 1.7 seconds for synthetic 30 fps footage; 360 preview frames in a 12-second capture. Read-only playback of existing edited regions also advanced correctly.

## Limits

These checks do not establish end-to-end camera/audio sync in Logic or simultaneous capture from four physical devices. Camera latency, permissions, USB bandwidth, host behavior and sustainable frame rate need checking on the actual setup. Sync controls intentionally start at 0 ms.

The download is **Intel/x86_64, macOS 13+, locally signed and not notarized**. Apple silicon compilation is supported by the build script but was not validated here. Logic can impose window behavior beyond the test host. The editor screenshot's input tiles and movies are simulated test content.

## Reproduce

From `CamOrderStudio/`, run sequentially:

```sh
Scripts/build-au.sh
swift test
Scripts/test-au.sh
Scripts/test-session.sh
Scripts/install-au.sh
auval -v aufx CmSt Sntm
```

The helper-process and existing-project checks were additional local checks. The source includes an existing-project playback harness, but private project media and machine-specific logs are not distributed. Public packages include this verification summary, not those local logs.
