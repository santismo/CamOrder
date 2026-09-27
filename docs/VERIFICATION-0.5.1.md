# CamOrder Studio AU 0.5.1 verification

Development build for Intel/x86_64, macOS 13+. Adds the built-in Sync calculator to 0.5.0’s fixed-start export and lane offsets. The original video files remain unchanged.

## Calculator checks

- **47 Swift tests passed**, including eight new calculator tests. They verify signed millisecond corrections, adding a residual correction to an existing offset, second/minute/hour boundaries, fractional frame rates, 80 subframes per frame, sample-rate conversion, drop-frame minute boundaries, invalid/skipped frame labels and malformed input.
- Milliseconds are the default. `00:36.240` in Logic and `00:36.160` inside the picture gives **−80 ms**; an existing **−82 ms** setting becomes **−162 ms**. The inverse comparison gives a positive correction.
- Formats are explicit. A five-digit suffix is not automatically guessed to be decimal seconds, frames, subframes or samples. Frame formats require a selected timecode frame rate; sample formats require a sample rate.
- The production calculator session regression checks project and lane Apply, isolation of other offsets, save/reopen, one-step Undo, repeated-Apply protection, stale-project checks, the ±5000 ms setting limit, and refusal to Apply during capture/arming.
- Destroying and recreating the native calculator view preserves both entries and the computed result in the same session.

## Existing behavior

The core suite also covers real encoded MOV/MP4 frames with independent lane/project corrections inside a fixed export range, layered composition, animation, audio placement, cuts, trims, source bounds, capture and transport. Synthetic playback delivered 51 advancing frames in 1.7 seconds (mean clock error 0.07 ms); 12-second capture delivered 350 preview frames with no recording warnings. These are synthetic checks, not camera-to-audio latency measurements.

The native AU and session harnesses cover audio pass-through, state isolation, editor creation/resize/reopen, recording with no editor, automatic disarming, restoration before editor creation, four simultaneous synthetic inputs, armed Undo, marker edits, lane-name commits, centering and pinch anchoring.

The installed **0.5.1 (`0x501`)** component passed Apple `auval`. Its AU and helper binaries match the build, and the component passes deep, strict code-signature verification. Four helper processes also passed independent discovery/command-channel and clean-shutdown checks without activating cameras.

## Limits and usage

Use a fresh export made with the current offsets, place it at its noted Logic start, then read both clocks at one paused moment. The calculator compares Logic’s clock with the same clock recorded inside the video, not the movie player’s elapsed-time counter. Both readings must use the same display format and time origin. Re-export after Apply and import at the same start. A single correction addresses constant delay, not drift; movie frame-rate granularity still applies.

The build is locally signed and not notarized. Actual Logic/camera synchronization and physical multi-camera capacity still require checking on the user’s setup. Apple silicon is not validated in this release. Screenshots show the actual production UI in an owned native test host.

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
