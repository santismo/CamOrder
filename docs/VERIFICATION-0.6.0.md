# CamOrder Studio AU 0.6.0 verification

Intel/x86_64 development build, macOS 13+. Adds Logic-tempo snapping, grouped camera-region editing and explicit per-region output layers. Source movies remain unchanged.

## Musical editing and layers

- **51 Swift tests passed**, including real encoded MOV/MP4 exports. New tests verify 88 BPM beat phase and subdivisions, invalid host timing, numbered foreground overriding upper lanes, independent lane/project sync offsets, smaller foreground revealing background, exact split boundaries, legacy decode and save/reopen.
- The production session receives valid host tempo/beat reports without an editor. A test changes the host to 88 BPM with a nonzero beat origin, verifies the editing grid and saved project, then makes the musical callback unavailable and verifies that the last real grid remains intact.
- Three-camera editing checks cover Shift-selection toggling, common snapped cuts after independent lane offsets, group move/left/right trim, the tightest source bounds, free edits with Snap off, grouped clipboard, layer assignment and re-promotion, and one-step Undo while armed.
- Native mouse events select three camera regions, Shift-click one out and back in, drag the group, and trim the group by dragging one left edge. These checks use the visible region bodies, including their label area, and both nested timeline scrollers.
- The production AU key-equivalent handler processes T, number keys and Command-C/V/S. T splits every selected camera at the same snapped playhead. Number 1 places a lower-lane region in front. Lane-name text input does not trigger layer assignment.
- The native test host supplies controlled application/window focus because macOS may deny desktop activation to a command-line test process. Mouse events target owned windows; this is not automation of a real Logic session.

## Existing behavior

The complete session harness passed recording with the editor closed, repeated Play/Record/Stop, missing callbacks and manual finalization, automatic disarming, restored sessions, four simultaneous synthetic inputs, shared-camera lanes, independent starts/stops, a disconnected camera, armed Undo, framing/markers, lane-name commits, canvas/window dragging, timeline centering and pinch anchoring. Sync-calculator Apply, Undo, stale/repeated-result protection and retained entries also passed.

The core suite continues to cover fixed export anchors, sync corrections baked into exported frames, animated layered video, trimmed source frames, custom ranges, audio placement and capture/transport behavior. Synthetic capture delivered 358 preview frames over 12 seconds with no recording warnings. Playback delivered 51 advancing frames over 1.7 seconds with a mean clock error of 0.13 ms. These are synthetic measurements, not physical camera-to-audio latency measurements.

## Audio Unit and installation

The final AU passed bit-exact mono/stereo pass-through at 44.1/48/96 kHz and 1/64/512-frame blocks, silent input, transport callback fallback, state round-trip, instance isolation and editor close/reopen. Native editor snapshots include the minimum 720 × 360 layout and arbitrary small/flat sizes. The new Snap/grid/layer toolbar remains available in the compact layout.

The installed **0.6.0 (`0x600`)** component passed Apple `auval`. Its binary matches the final built component, and the installed bundle passes deep, strict signature verification. Installation preserves a backup of the previous component and does not quit Logic.

## Limits

The grid uses the host's current tempo and quarter-note beat phase, not a complete tempo map. Position Logic in the section being edited after a tempo change. Existing edits are not retimed or time-stretched. The 1-bar division currently represents four quarter-note beats. Frame-rate granularity still applies to exported movies.

Screenshots use the actual native editor with synthetic cameras and footage. Real Logic shortcut routing, physical camera combinations and end-to-end sync need a user check after restart. This build is locally signed, not notarized, and validated on Intel only. Fully quit and reopen Logic after installation.

## Reproduce

From `CamOrderStudio/`, run sequentially:

```sh
Scripts/build-au.sh
Scripts/test-session.sh
swift test
Scripts/test-au.sh
Scripts/install-au.sh
auval -v aufx CmSt Sntm
```

Check that `auval` reports 0.6.0, rather than a cached older component.
