# CamOrder Studio AU 0.8.0 verification

Intel/x86_64 development build for macOS 13+. The new individual-window input requires macOS 14+. This update fixes a disconnected Live Inputs view after changing sources, adds visible screen-region controls, and adds window capture through the macOS sharing picker.

## Capture changes

- SwiftUI can reuse a single input's native preview view after the source changes. The view now cancels its previous subscription and binds to the new engine, including its current picture. Changes or shutdown of the old engine no longer blank the new source.
- Screen region exposes **Show region**, **Apply** and **Hide** directly on its preview tile. The Main Stage empty-state text distinguishes live sources from recorded timeline regions.
- **Window (choose…) → Choose window…** opens the ScreenCaptureKit system picker in the capture helper. Only explicit user action opens the picker; reopening a saved project does not silently request window sharing. The selection is session-only and must be chosen again after restarting Logic.
- Window streams use BGRA at up to 30 fps, capture video only, preserve aspect ratio, and keep the initial pixel dimensions if the window is resized. One chosen window can be shared by multiple lanes alongside other camera/screen inputs. Selecting another window is disabled while those lanes are armed or finishing.
- Window recording repeats the latest complete frame at 30 fps on the host clock while armed/recording. A static window therefore produces a full-length take, even when ScreenCaptureKit only emits idle events. The recording anchor uses the take's first encoded frame time, not an old preview timestamp. There is no repeating-frame encoding timer while merely previewing.
- Stream tokens reject late frames and stop events from a replaced window. Closing/stopping/suspending the source finalizes an active take and reports the interruption rather than silently continuing a frozen recording.

## Validation

- **66 Swift tests passed.** New tests verify native preview subscription replacement, actual SwiftUI view reuse, clearing and late updates from old sources, a playable 6.2-second static-window take, host-time anchoring and stale-window rejection with a new resolution. Existing rendered export, offsets, editing, automation and transport tests pass. Synthetic capture delivered 358 preview frames in 12 seconds with no recording warnings.
- Release AU/helper compilation targets macOS 13 and checks availability before invoking the macOS 14 picker. The release build has no compiler warnings. Both bundles report 0.8.0 and pass deep, strict ad-hoc signature verification.
- The session harness without its optional mouse-driven window passes background Play/Record/Stop, editor-independent restoration, recording failures, four simultaneous synthetic inputs, shared-input take timing and the project-store editing regressions.
- Audio Unit integration passes mono/stereo pass-through at 44.1/48/96 kHz and 1/64/512-frame blocks, state restoration, instance isolation, editor rendering, resizing, closing and reopening. Apple `auval` passes for the installed **0.8.0** component. Installation preserves a backup and does not quit Logic.
- The full native mouse/key harness did **not** pass cleanly: runs failed at right-edge trimming or the SwiftUI resize grip. A comparison using unchanged `github/main` editor sources also failed, later at paused number-key handling. These interaction failures remain unresolved; no clean full-suite pass is claimed. The new focused native-preview tests pass, including reuse of the actual SwiftUI representable.
- The expanded installer contains AU/helper binaries and plists byte-identical to the tested build. The DMG passes `hdiutil verify`.
- On October 4, 2026, the user confirmed that window capture works in Logic with the installed update after being asked to try the picker, live preview and a short armed take. This is a local user check, not validation of every window type or camera combination.

## Limits and manual check

Automated window-recording tests supply synthetic complete frames to the production writer. They do **not** approve the system picker, capture private windows, or verify a running Logic session. Window capture has the local user confirmation above; screen/region switching, source closure, restart behavior and additional physical camera combinations remain manual checks.

For that check, choose Window in Live Inputs, click **Choose window…**, select and confirm a window, wait for its image, arm a lane and record at least ten seconds in Logic. Stop and play the new region, then test another window and switching back to Main display/Screen region. A static selected window should record the full take. Test closing the selected window during a disposable take; it should stop with a message. Saved projects keep the input assignment but require a fresh window selection after Logic restarts.

Updating an ad-hoc-signed helper can invalidate an earlier screen-recording grant even while its setting remains enabled. The guide documents removing/resetting only CamOrder Capture's stale screen permission, then approving the installed helper. The window picker provides explicit selection approval.

The public installer remains unsigned and not notarized. Apple silicon source builds and macOS 14 hardware are not runtime-validated on this Intel macOS 15.7.4 Mac. No CPU reduction or physical-camera latency improvement is claimed.

## Reproduce

From `CamOrderStudio/`, run sequentially:

```sh
Scripts/build-au.sh
swift test
Scripts/test-session.sh
Scripts/test-au.sh
Scripts/install-au.sh
CAMORDER_DISABLE_AUTOPREVIEW_FOR_TESTS=1 auval -v aufx CmSt Sntm
python3 Scripts/package-installer.py --output-dir dist/release-0.8.0
python3 Scripts/package-au.py --output-dir dist/release-0.8.0
```

Confirm that `auval` reports 0.8.0; registration can briefly return a cached older version. Packaging refuses to overwrite existing release files.
