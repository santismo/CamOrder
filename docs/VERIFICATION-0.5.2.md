# CamOrder Studio AU 0.5.2 verification

Intel/x86_64 development build, macOS 13+. Adds a visible Save button, larger region-edge drag handles, and region copy/paste. Existing source movies remain unchanged.

## Editing checks

- **48 Swift tests passed**. The new boundary test trims and restores a region pasted at visible timeline zero with a positive presentation offset, retaining its source alignment and fixed right edge.
- Native mouse events exercise both region grips, narrow regions, restoring trimmed footage, and the left edge at timeline zero. Each drag produces one Undo step. The preview and committed edge use the same source limits.
- Copy/paste retains source trim, duration, framing, camera calibration and automation, with independent region/marker identities and shared media. Tests cover repeated paste, independent destination lane/project offsets, visible zero, one-step Undo/Redo while armed, deleting the copied source region before pasting, project isolation and save/reopen.
- Command-C, Command-V and Command-S are exercised through the production AU editor's native key-equivalent handler. Command-C copies without invoking the plain-C split action; Paste lands at the playhead; Save writes the edited timeline. The command-line test host supplies a controlled editor-focus state because macOS may deny it desktop activation. This does not simulate keyboard control of Logic itself.
- The Save button and Copy/Paste toolbar controls are visible in the actual native editor screenshot. The guide documents toolbar, shortcut and context-menu behavior, including choosing another destination lane.

## Regression checks

The complete session harness passed: recording real synthetic-camera movies with the editor closed, repeated Play/Record/Stop, missing callbacks and manual finalization, automatic disarming, host restoration, four simultaneous inputs, shared-camera lanes, independent stop times, a disconnected camera, armed Undo, framing/markers, lane-name commits, canvas/window dragging, timeline centering and pinch anchoring. The sync calculator's Apply, Undo, repeated/stale result protection and retained entries also passed.

The core suite includes real MOV/MP4 exports with trims, layered video, independent lane/project offsets inside a fixed export range, audio placement, clock parsing, capture and transport. Synthetic capture delivered 348 preview frames over 12 seconds without recording warnings; playback delivered 51 advancing frames over 1.7 seconds, with a mean clock error of 0.11 ms in this run. These are synthetic measurements, not camera-to-audio latency measurements.

The AU harness passed bit-exact mono/stereo pass-through at 44.1/48/96 kHz and 1/64/512-frame blocks, silent input, project state round-trip, instance isolation, editor resizing, creation and close/reopen.

The installed **0.5.2 (`0x502`)** component passed Apple `auval`. Its AU binary matches the built component, and the installed bundle passes deep, strict code-signature verification.

## Limits

This build is locally signed, not notarized, and validated on Intel only. Screenshots and mouse/shortcut checks use an owned native AU test host with synthetic footage. Actual Logic shortcut routing, camera/audio synchronization and physical multi-camera capacity still need checking in a real user session. Fully quit and reopen Logic after installation. Region copy/paste is scoped to the current CamOrder project/session; it does not transfer media between projects or applications.

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

Check that `auval` reports 0.5.2, rather than cached registration for an older version.
