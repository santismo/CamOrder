# CamOrder Studio AU 0.5.0 verification

Checked on an Intel Mac on September 26, 2026. Component identity: `aufx / CmSt / Sntm`, version 0.5.0 (`0x500`). Public screenshots use the actual editor in an owned native Audio Unit host with synthetic cameras and encoded test footage.

## Export and editing checks

- **39 Swift tests passed.** Actual MOV/MP4 frames verify a fixed edited export start with 0, −82 and +82 ms corrections. A trimmed clip advances inside the movie when its offset is negative; a positive offset creates leading black. File duration and import position remain fixed.
- A separate encoded-movie test combines a −50 ms project adjustment with +150 ms and −50 ms lane adjustments. Both visible layers independently use their +100 ms and −100 ms totals. Frame colors and lane end times verify the exported result.
- Layered export retains the lower video outside a smaller foreground video and after its end. Automation moves the upper image independently. Vertical pan and rotation around the moved image center match Main Stage coordinates.
- Existing regressions cover source trims, gaps, source-media overwrite protection, audio-cue placement, custom ranges, splits, save/reopen compatibility and non-destructive offsets.
- Native store checks delete/Undo/Redo while armed with pre-roll, preserving live capture connections and current arm state. Marker edits preserve earlier poses, interpolate to the edited pose and survive save/reopen.

## Transport, editor and capture checks

- Production sessions encode real synthetic-camera movies on Play and Record without creating an editor. Stop finalizes the take and disarms the lanes. Repeated takes, missing callbacks and manual finalization pass.
- Restoring AU project state creates the session before any editor. It follows the host before opening, after stopped scrubbing and across editor close/reopen. R/Space handoff reaches the host responder exactly once.
- Native keyboard/mouse events verify Return and outside-click lane-name commits and released focus. Actual canvas and window-grip drags pass.
- The native timeline centers a playhead about 2000 seconds into the project, ignores a transient zero callback, and preserves the time under the pinch handler's anchor. Initial positioning waits for the scroll view's layout. Physical trackpad gestures still need a user check in Logic.
- Four simultaneous synthetic-camera movies finalize aligned. Three lanes can share a single file. A camera disconnect does not stop other cameras; late arm and independent stop on a shared source retain each region's timing. Assignments save/reopen.
- Native AU integration verifies bit-exact mono/stereo pass-through at 44.1, 48 and 96 kHz, including silent input and 1/64/512-frame blocks; instance-state isolation; and editor creation, resizing, close/reopen.
- UI sizes include 1280 × 960, 1280 × 820, 1120 × 460, 820 × 520, 760 × 440, 803 × 417 and 720 × 360.
- Synthetic 30 fps playback delivered **51 advancing frames in 1.7 seconds**, with a mean player-clock error of **0.14 ms**. Twelve-second capture delivered **360 preview frames** with no recording warnings. These numbers are not measurements of physical camera/audio latency.

- **Apple auval passed** against installed version 0.5.0. The installed AU and helper binaries match the release build, and the component passes deep, strict code-signature verification. The previous installed component was backed up.
- Four capture-helper processes launched together, independently discovered inputs without activating cameras, acknowledged separate command channels and shut down cleanly.

## Distribution and limits

The download is **Intel/x86_64, macOS 13+, locally signed and not notarized**. Apple silicon can be built from source but is not included or validated here. Physical multi-camera capture and end-to-end synchronization with Logic's audio need checking on the actual setup; offsets intentionally default to 0 ms. Logic may impose window behavior beyond the test host.

An offset moves content within a fixed export window. Content crossing that window's edges is clipped, and uncovered time is black. Choose a custom range to retain extra time at either end. Existing movies must be re-exported to include changed offsets.

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

The public package contains the component, matching source, installer, guide and this verification record. It excludes private media, test-run logs and local project paths.
