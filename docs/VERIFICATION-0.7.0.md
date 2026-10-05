# CamOrder Studio AU 0.7.0 verification

Intel/x86_64 development build, macOS 13+. Adds live multicamera cuts, lane reordering, a selected-region framing preview, bottom controls and persistent export status. Source recordings remain unchanged.

## Live editing and output

- **57 Swift tests passed**, including encoded MOV/MP4 exports. New tests cover free cuts across independently offset lanes, preserved source frames and automation, rapid cuts under 50 ms, exact edit boundaries, invalid/empty/muted choices, saved-project round trips and stable playback identities.
- A real red/blue/red movie export verifies the chosen cameras before and after live cuts with a −82 ms project correction and an independent +42 ms lane correction. Encoding completes at 100%.
- The production project store passes nine-lane switching, 88 BPM nearest-grid cuts, one-step Undo/Redo, moving lanes across several rows, number reassignment after reordering, save/reopen and active-capture protection.
- Native AU key events switch cameras during playback and retain layer assignment while paused. All three existing player views survive a live cut: no decoder-view replacements for those continuous sources.
- Paused selected-region preview brings an obscured selection forward without changing exported ordering. Automation, offsets and source timing remain on their original regions.
- Export completes with the editor hidden, retains its finished-file link and writes the Logic placement note. The rendered file exists and progress reaches 100%.

## Existing behavior and performance

The session harness checks recording without an editor, repeated Play/Record/Stop, lost host callbacks, optional MIDI fallback, restored sessions, three independent synthetic cameras and a disconnected source. Existing native editor checks cover framing, window resizing, edge trims, Shift-selection, group edits, shortcuts, text-entry protection, timeline following and pinch anchoring.

The core suite continues to cover fixed export anchors, corrections baked into frames, animated layered video, trimmed footage, custom ranges and audio placement. Synthetic capture delivered **359 preview frames over 12 seconds** without recording warnings. Playback delivered **51 advancing frames over 1.7 seconds**, with a mean clock error of **0.12 ms**. These are synthetic checks, not physical camera latency measurements or a CPU benchmark.

The optimization preserves playback frame rate, capture settings, thumbnail resolution and export encoding. It reuses players across cuts in the same source, skips unchanged paused-player updates, limits thumbnail generation to two simultaneous jobs, cancels stale jobs and bounds the thumbnail cache to 64 MiB. No percentage CPU reduction is claimed.

## Audio Unit, interface and installation

The final component passes mono/stereo bit-exact pass-through at 44.1/48/96 kHz and 1/64/512-frame blocks, silent input, callback fallback, state round-trip, instance isolation and editor close/reopen. Native snapshots cover the 720 × 360 minimum, flat sizes and the bottom-controls layout.

The installed **0.7.0 (`0x700`)** component passes Apple `auval` and deep, strict signature verification. Installation saves the previous component in CamOrder's Plugin Backups folder and does not quit Logic. The installer payload contains the matching AU and capture helper; their binaries are byte-identical to the verified build. The DMG passes `hdiutil verify`. The native package targets the current user's Audio Unit folder.

The website guide covers live and paused shortcuts separately, lane reordering, selected-region preview, bottom controls and export status. The live-editing guide was checked at desktop and phone widths without horizontal overflow. The additional six-lane workflow example uses a copy of the owner’s saved project and a web encode of the supplied final movie; original takes and project bundles are unchanged.

## Limits and user check

These tests use an owned native host and synthetic cameras; they do not automate a real Logic session. Physical camera combinations, desktop focus and end-to-end sync need a user check after fully quitting and reopening Logic. Drag/drop uses a numbered grip on the lane header; lane-move semantics and Undo are covered, while a physical trackpad drag should be checked in Logic.

Live number shortcuts require CamOrder's keyboard focus and finished text entry. Record first, then stop and leave the video lanes disarmed before live editing. A switch changes the active right-hand segments, preserving later existing edit boundaries. Snapping may choose the next grid position, so that switch becomes visible when the playhead reaches it. Smaller foreground shots retain their framing and reveal the layers behind them.

The grid uses the host's current tempo/beat phase, not a full tempo map; existing cuts are not time-stretched. A bar is currently four quarter-note beats. Exported movies are limited by their frame rate.

This Intel build is ad-hoc signed locally. The installer is unsigned and not notarized. Apple silicon builds are available from source but are not validated on this Mac.

## Reproduce

From `CamOrderStudio/`, run sequentially:

```sh
Scripts/build-au.sh
Scripts/test-session.sh
swift test
Scripts/test-au.sh
Scripts/install-au.sh
auval -v aufx CmSt Sntm
python3 Scripts/package-installer.py --output-dir dist/release-0.7.0
python3 Scripts/package-au.py --output-dir dist/release-0.7.0
```

Confirm that `auval` reports 0.7.0; the registration service can briefly return its previous cached version immediately after installation. Packaging refuses to overwrite existing release assets.
