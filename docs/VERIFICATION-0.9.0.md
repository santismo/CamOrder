# CamOrder Studio AU 0.9.0 motion test build

Local Intel/x86_64 build, October 5, 2026. This adds automatic zoom and pan to selected regions. **This is a test build; host playback and rendered output still need verification in Logic.** The public release remains 0.8.0.

## Behavior

- Timeline wand / region context menu opens Motion. Zoom in/out and eight pan directions combine, with amount presets and sliders, a clickable canvas focal point and a four-second still-preview loop.
- Each selected region gets a full move across its own edited length. Source dimensions are loaded once per shared video. All changes are prepared before one Undo transaction; missing media or changed targets abort the group. Original media, timing, trims, layers and sync offsets remain unchanged.
- Keep edges covered calculates a crop for the entire move, accounting for source/canvas aspect, offsets and rotation. Its small filtering margin also covers the affine interpolation approximation used by export. Zoom/position limits fail with an explanation instead of silently clamping to exposed edges. Turning coverage off permits smaller overlays. Baked-in black bars are part of the source image and cannot be removed by this edge calculation.
- Add to existing samples combined curves into editable linear markers. Replace begins at the original region's opening framing. Ordinary new moves use two smoothly interpolated markers. Optional marker interpolation preserves decoding of older project files; splits, trims and copy operations retain it.
- Main Stage, Motion and export share the same canvas fallback geometry, including older UHD settings with missing dimensions. Motion uses existing playback/export framing; it adds no realtime media processor.

## Completed checks

- Optimized AU compilation targets macOS 13 and completes without compiler warnings. The AU reports 0.9.0/build 900 and passes `codesign --verify --deep --strict`.
- **56 distinct Swift tests passed across focused runs**, including **8 AutomaticMotionTests** and **4 MotionStoreTests**. Coverage includes all directions, landscape/portrait/square sources, fixed focal anchors, rotation, projected corner coverage between keys and linearly interpolated export matrices, additive curve approximation, repeated-application marker bounds, no unnecessary crop accumulation, split/trim continuity, legacy JSON, invalid input, grouped Undo/Redo, saved project round-trip, unchanged media and all-or-nothing missing-media and failed-save handling.
- Existing focused tests cover host transport monitoring, time labels, MIDI parsing, tempo grids, multi-camera edits, cross-lane placement, project documents, sync calculation and independent lane offsets.
- A native SwiftUI panel test checks layout/creation, but **does not establish visual correctness**: GPU failures produce an incomplete image with missing controls/thumbnail. No screenshot from this session is represented as the finished UI.
- The packaged capture helper is the exact already-installed, user-confirmed 0.8.0 helper, preserving its executable and code-signing identity. Its executable SHA-256 is `df3afeb8426a6c27a0d2cfc20f1ab67338c2852eb9f3d6b9373b9498f41e2034`. Capture IPC and sources are unchanged. A normal source rebuild recompiles this helper and may change its ad-hoc identity.

## Blocked checks and controls

The current execution session restricts system services and installed plug-in writes. The full suite did not pass: its synthetic capture/movie writers and playback produced AVFoundation and unavailable OpenCL device failures. Focused metadata/store tests now use tiny synthetic preencoded fixtures rather than requiring an encoder for setup.

The actual new MOV/MP4 pixel test is retained but **has not passed**. With the preencoded input, the export session fails before a usable movie exists. A separate unanimated 64×64 export control also fails, reporting AVFoundation -11800 / OSStatus -12903. This supports an environmental limitation, but is not a substitute for validating the new animated output.

Native Audio Unit integration stops at `FAIL register component`. Running the same harness against the installed 0.8.0 control yields the same failure. No 0.9.0 `auval` pass, installed update, actual Logic session, new camera recording, full mouse/key harness or visual UI approval is claimed. Prior capture/host results belong to 0.8.0, not this build.

## Manual acceptance

1. Save and quit Logic. Install the local test package and reopen Logic; CamOrder should show AU 0.9.0.
2. On a copy of an existing project, Shift-select two or three clips with different lengths. Open Motion, preview Subtle zoom and diagonal pan, choose a focal point and Apply.
3. Play from each clip's start through its end. Confirm no outer frame edges show; compare portrait and landscape inputs. Export a short MOV and MP4 and inspect framing and synchronization in Logic.
4. Add another move, then Undo and Redo. Confirm the entire selection changes together. Save/reopen and check trimmed and split clips. Verify ordinary recording and transport still work.
5. Try coverage off for a small foreground overlay and inspect the full composition after deselecting.

Run `swift test --filter AutomaticMotionTests`, `swift test --filter MotionStoreTests`, `swift test --filter MovieExportTests/testAutomaticPanZoomExportCoversEveryFrameIncludingRotatingExistingMotion`, and `Scripts/test-au.sh` in a normal Mac development session to reproduce the focused checks. The full existing test suite should also be run there before public release.
