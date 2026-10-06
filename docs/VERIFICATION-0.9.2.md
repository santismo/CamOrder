# CamOrder Studio AU 0.9.2 verification

Local Intel/x86_64 development build for macOS 13+, October 5, 2026. Public GitHub releases remain at 0.8.0. This build includes the automatic-motion feature from 0.9.0, ordinary-playback scheduling changes, clearer controls and native lane dragging.

## Behavior

- An open project retains the same process activity previously used only while armed/recording. Disarming or closing the editor no longer releases this scheduling protection. Closing the project/session releases it. It permits idle system sleep and does not arm a lane or begin capture. The host's reported position remains authoritative; missing callbacks still freeze the cursor. Disarmed diagnostic entries now record timer gaps, callback state, reported/followed play state and activity status.
- This addresses the scheduling difference matching the user's report that arming a lane restores playback. App Nap was not directly reproduced in the user's running Logic process. The subsequent Logic follow-up below confirms the silent-section limitation remains.
- **Motion** is visibly labeled next to Marker/Cut/Copy/Paste/Delete. The region's **Motion…** context menu also opens the panel and retains a multiple-region selection. It bakes zoom/pan moves into editable framing markers with the existing coverage, focal-point, combination and one-step Undo behavior.
- **Edit selection** is now **View selected clip**. Its tooltip explains that it temporarily brings the selected region forward for framing while paused; output layers and exports do not change. It has no visible effect if that region is already foremost. Playback always uses the actual composition.
- Lane reordering uses native mouse events instead of SwiftUI item-provider drag/drop. Drag the shaded grip/number by the lane name, cross any number of rows and release at the insertion line. The pointer can be over the lane headers or region area. Holding near the viewport's top/bottom scrolls; Escape or release outside cancels. Geometry uses actual row positions, not guessed fixed hit boxes. Rows stay in place until release, which saves one undoable move. Lane contents, camera assignments, offsets and automation remain attached to the lane. The existing context-menu Up/Down actions remain available.

## Completed checks

- **83 Swift tests pass in one final run**, including four new native lane-drag tests. Window-dispatched mouse events verify multi-row moves in both directions, drops over the region area, one-step Undo and save/reopen, Escape/outside cancellation, and autoscrolling to hidden rows. A further case uses the complete production editor in hosted mode, including its nested horizontal/vertical scroll views and input controls.
- The full suite includes actual MOV and MP4 pixel inspection for automatic zoom/pan combined with rotating existing motion; the earlier 0.9.0 environment failures are resolved in this execution environment. Coverage includes marker interpolation, trimmed/split motion, group application, atomic failure handling, independent offsets, compositing, clipboard/editing and source preservation.
- Synthetic capture delivered 359 preview frames over 12 seconds with no recording warnings. Synthetic playback delivered 51 decoded frames over 1.7 seconds with mean clock error 0.12 ms. These are local regression measurements, not physical camera latency or end-to-end Logic synchronization measurements.
- The native session harness passed with the final transport implementation before the subsequent label/lane UI changes: all-lanes-disarmed Play with no editor, stopped-preview handoff, editor removal, no accidental recording, automatic-disarm activity retention and activity release on session closure. Existing checks passed for Play/Record/Stop recording, callback loss, restoration, R/Space handoff, MIDI fallback, independent offsets/editing, shared cameras and four simultaneous synthetic inputs. `CAMORDER_SESSION_HEADLESS=1 Scripts/test-session.sh` selects this mode.
- Final optimized AU 0.9.2 compilation targets macOS 13. Built and installed bundles pass deep, strict ad-hoc signature verification.
- Final AU integration passes transport callback ordering, v1/v2 fallback, invalid-callback handling, AudioUnitProcess, silent/ordinary pass-through, mono/stereo 44.1/48/96 kHz with 1/64/512-frame blocks, project-state round trip, instance isolation, native editor creation, resizing, closing and reopening.
- Apple `auval` reports **Component Version: 0.9.2 (0x902)** and **AU VALIDATION SUCCEEDED** for the installed component. The user AudioComponentRegistrar cache was refreshed; Logic was not quit or edited. The previous installed plug-in is backed up under the user's CamOrder Studio/Plugin Backups folder.
- The local unsigned Installer package contains AU/helper binaries and plists byte-identical to the validated build. Its DMG passes `hdiutil verify`; both have SHA-256 sidecars under `dist/playback-lanes-0.9.2/`.
- The capture helper is byte-identical to the user-confirmed 0.8.0 helper, retaining its code-signing identity. Executable SHA-256: `df3afeb8426a6c27a0d2cfc20f1ab67338c2852eb9f3d6b9373b9498f41e2034`. A normal source rebuild recompiles the helper and can change its ad-hoc identity; this local bundle deliberately restores the verified helper before signing the outer AU.
- The editor and Motion panel were visually inspected using WindowServer captures restricted to each test's own window. Test-pattern footage is synthetic. These images show the production views, not the user's Logic project.

## Limits and next user check

The existing broad mouse/key session harness has historical intermittent failures in unrelated region-edge/resize gestures and was not used to claim a complete interaction-suite pass. The new focused lane gestures pass in both their isolated fixture and the full editor. The Logic follow-up below covers audio-active versus silent playback; physical-camera capture and every real multicamera workflow have not been rechecked in this build.

Save and fully quit/reopen Logic. Confirm **AU 0.9.2** in CamOrder's footer. With a project open and every video lane disarmed, start playback from Logic and check that CamOrder follows. Repeat after closing/reopening the plug-in window and after a stopped timeline scrub. Then try Motion on a Shift-selected group, View selected clip on an obscured paused clip, and dragging the lane grip across several rows. Existing projects and original footage are not rewritten by installation.

## Logic follow-up: playback through silence

On October 5, 2026, the user confirmed CamOrder follows when audio plays through Stereo Out, but can remain frozen during otherwise silent playback. Diagnostic entries showed the session timer and scheduling activity still active while the AU render count stopped advancing and the last callback aged. Retaining process activity did not resolve Logic's suspension of AU timing. This is a host-processing dependency, not a verified App Nap fix.

The existing automated session test exercises MIDI fallback without AU rendering and without an editor. It does not establish that the user's Logic project has been configured or tested with MTC/MMC; the user chose to keep the normal AU setup.

The [transport guide](../CamOrderStudio/README-AU.md#transport-and-silent-playback) now documents this tradeoff, MTC/MMC setup and a proposed continuous quiet-audio workaround for footage-only editing. No almost-inaudible signal level has been validated, and no universal dB threshold is claimed. Such a signal must be excluded from final audio bounces. This documentation change does not alter plug-in behavior or add a new binary test result.

## Local reproduction records

Logs under `CamOrderStudio/.build/`: `playhead-final-swift-tests.log`, `lane-drag-tests.log`, `lane-editor-tests.log`, `playhead-session-tests.log`, `playhead-au-tests-092.log`, `playhead-auval-092.log`, `playhead-build-092.log`. Screenshots: `editor-092.png`, `motion-panel-window-091.png`, `au-tests/editor.png` and its compact variants. Build products live under `CamOrderStudio/dist/` and are not committed.
