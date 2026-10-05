# CamOrder Studio AU 0.7.1 verification

Intel/x86_64 development build for macOS 13+. This update adds cross-lane region moves and a recorded-position anchor for new camera and screen takes. The application/transport-bridge architecture discussed separately is not part of this release.

## Region placement

- Drag region bodies vertically between lanes, or use the region context menu's **Move to Lane**. Group moves retain relative lane spacing and stop at the first/last lane boundary. The menu disables destinations that cannot fit the selection.
- A vertical-only move preserves exact presentation timing, including between independently offset lanes. Horizontal movement uses the existing grid and Option bypass. Trims, source frames, automation, explicit output layers and region IDs remain intact. Automatic layers follow destination lane order.
- Drag previews do not mutate or save the project. They keep native drag handles attached until mouse-up, with stacking order chosen so selected rows cannot hide each other's moving previews.
- **Return to Recorded Position** uses a persisted source-zero timeline anchor, including capture preroll. After a cut or left trim, the remaining source frames return to their own recorded time. Current lane/project offsets continue to apply. The action retains the current lane and all other edits, bypasses snapping and supports Undo/Redo.
- New anchors survive cuts, trims, moves, copies and saved-project round trips. Existing recordings and imported movies without this metadata cannot safely recover their original edited positions; the action is disabled. No heuristic migration rewrites old placement data.

## Validation

- **62 Swift tests passed**, including the new placement tests and the existing rendered MOV/MP4, independent sync-offset, camera switching and automation regressions. Capture delivered 358 preview frames in 12 seconds without recording warnings; these synthetic checks are not physical camera measurements or CPU benchmarks.
- The production project-store harness passes cross-lane preview/commit and context moves, exact off-grid vertical movement, independent offsets, armed Undo/Redo, copied recording anchors, Return and save/reopen. Newly captured movies retain their preroll-aware recording anchor.
- Native mouse events move a region into the adjacent lane without shifting time; one Undo restores it. Existing native tests pass edge trimming, Shift-selection, grouped edits, live camera shortcuts, text-field focus, window resizing, timeline centering/pinch, decoder retention and background export completion.
- Audio Unit integration passes mono/stereo bit-exact pass-through at 44.1/48/96 kHz with 1/64/512-frame blocks, transport/state handling, instance isolation and editor close/reopen.
- The installed component/helper report **0.7.1**. Apple `auval` passes for the installed AU; the component passes deep, strict signature verification. Installation preserves a backup and does not quit Logic.
- The expanded installer contains AU/helper binaries and plists byte-identical to the verified component. The DMG passes `hdiutil verify`.

## Limits

The native test host uses synthetic capture and the production AU/editor. It does not automate the user's running Logic project or measure physical camera latency. Reopen Logic to load the new component before checking a real session. No CPU reduction is claimed for this editing update.

The Intel component is locally ad-hoc signed; the public installer is unsigned and not notarized. Apple silicon source builds are not validated on this Mac.

## Reproduce

From `CamOrderStudio/`:

```sh
Scripts/build-au.sh
swift test
Scripts/test-session.sh
Scripts/test-au.sh
Scripts/install-au.sh
CAMORDER_DISABLE_AUTOPREVIEW_FOR_TESTS=1 auval -v aufx CmSt Sntm
python3 Scripts/package-installer.py --output-dir dist/release-0.7.1
python3 Scripts/package-au.py --output-dir dist/release-0.7.1
```

Confirm that `auval` reports 0.7.1. Audio Unit registration can briefly return a cached older version after installation. Packaging refuses to overwrite existing release assets.
