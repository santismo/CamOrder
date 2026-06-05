# Logic Sync Strategy

## Goal

CamOrder Studio syncs to Logic Pro transport and timeline position. It does not stream live audio from Logic. The app needs enough timeline truth to place recorded video clips at the correct timecode and to chase Logic's playhead while the user records takes.

## Recommended MVP: CoreMIDI + MTC

The first implementation should use CoreMIDI and MIDI Time Code:

1. CamOrder Studio creates or listens to a CoreMIDI input.
2. Logic Pro sends MIDI Time Code to that destination.
3. CamOrder Studio parses MTC quarter-frame and full-frame messages.
4. The app updates its playhead and sync state.
5. If a video lane is armed and Logic is playing/recording, recording starts and the pending clip stores the current Logic timecode.

MTC is preferred because it maps directly to video timecode: hours, minutes, seconds, and frames.

## Secondary option: MIDI Clock + Song Position Pointer

MIDI Clock and Song Position Pointer can be added as a secondary mode. This is useful for musical beat sync, but it is tempo-based and less direct for frame-accurate video placement. The app should keep this path separate from MTC so timecode-based export remains authoritative.

## Future option: AUv3/helper plugin

An AUv3 or helper plugin can be researched later if Logic exposes useful host timeline information that cannot be obtained robustly through MIDI sync. This should remain optional. The main product should stay a native video app.

## Sync state model

CamOrder Studio should expose:

- `disconnected`: no MIDI input or endpoint selected.
- `waitingForTimecode`: input is active but no valid timecode has arrived.
- `locating`: a full-frame locate or jump was received.
- `chasing`: valid timecode is arriving and the app is following.
- `playing`: transport appears to be moving steadily.
- `stopped`: transport has stopped or the user disabled sync.
- `unstable`: expected timecode stopped or became irregular.
- `error`: CoreMIDI setup or parsing failed.

The UI should always show current state and current timecode. Unstable and error states should be visually clear.

## MTC parser design

`MTCParser` should:

- Accept raw MIDI bytes from CoreMIDI packets.
- Parse quarter-frame messages (`0xF1`) by reconstructing the eight timecode nibbles.
- Parse full-frame SysEx locate messages.
- Detect MTC frame-rate bits.
- Emit `Timecode` plus a sync state hint.
- Mark sync as unstable when messages stop arriving.
- Treat full-frame messages as locate/jump events.

The initial parser scaffold handles quarter-frame and full-frame messages. CoreMIDI endpoint management belongs in `LogicSyncEngine`.

## Logic Pro user configuration

The user should configure Logic Pro to send MIDI Time Code to CamOrder Studio's MIDI destination or an IAC Bus:

1. Open macOS Audio MIDI Setup.
2. Enable the IAC Driver if a virtual MIDI bus is needed.
3. In Logic Pro, open synchronization or MIDI project settings.
4. Enable MIDI Time Code output.
5. Select the CamOrder Studio virtual destination or IAC Bus.
6. Match the Logic project frame rate to the CamOrder Studio project frame rate.
7. Press play or record in Logic and confirm CamOrder Studio leaves `waitingForTimecode`.

Exact Logic menu labels can vary by Logic version, so in-app help should use version-tolerant wording and show a troubleshooting checklist.

## Known limitations

- MTC quarter-frame arrives over multiple MIDI messages, so the parser reconstructs timecode after a complete set.
- MTC does not carry video frames or audio; it only communicates timeline position.
- MIDI Clock is not frame-accurate by itself.
- Locate and stop/play inference may need host-specific tuning.
- Frame-rate mismatches between Logic and the project will cause placement errors.

## Latency calibration

Camera capture can start late relative to the Logic playhead. CamOrder Studio should store per-camera `CaptureLatencyProfile` records with a default `0 ms` offset. When a recorded clip is placed:

```txt
timelineStartSeconds = logicStartSeconds - captureLatencyMs / 1000
```

The adjusted value should be clamped at zero and persisted with the clip metadata.

## Pre-roll buffer future design

A future pre-roll system can keep camera preview active and continuously hold a rolling buffer of 2 to 5 seconds. When Logic starts, CamOrder Studio commits buffered frames before the trigger point, letting the media begin exactly at the Logic start time. This should be designed after the basic camera recording path is stable because it affects memory, disk I/O, timestamps, and export metadata.
