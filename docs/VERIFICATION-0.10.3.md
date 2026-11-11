# CamOrder Studio AU 0.10.3 — settled recording starts and footage recovery

Date: November 11, 2026.

## Diagnosis

The 0.10.2 follow-up logs showed a valid capture-helper completion with roughly 14.34 seconds of iPhone USB screen video in Light preview mode. The AU's initial timeline anchor was 18.6227 seconds while subsequent fresh Logic positions started near 4.8 seconds. At Stop, the resulting region had no visible duration. The earlier render-host-clock check did not reject this incorrect initial timeline position.

A new native AU regression reproduces the 18.62-to-4.8 transition with a correct render host clock. It fails against the unchanged 0.10.2 binary. Startup reports also include a much larger outlier and a transient zero position.

## Change

The AU treats the first Play position as a candidate. It checks subsequent timeline movement against the host-clock progression, rebases when that movement is inconsistent, and exposes the take-start anchor only after 50 ms of coherent reports. Pre-roll captures throughout that interval; the settled candidate retains its original time, so waiting does not remove the valid beginning. Failed callbacks and explicit stops clear readiness for a new take; a long callback gap starts a fresh candidate on resumption. The existing render-clock validation and MIDI fallback remain.

If a take has recorded media but cannot form a valid timeline region, the project retains the file and registers it as recovered media instead of deleting it in pre-roll cleanup. The error explains how to use **Media → Video Folder** and **Import Video**. Missing/empty recordings still report a capture failure. This does not restore files already removed by older versions.

## Verification

- **94 existing Swift tests passed** with zero failures, including sustained capture, playback, automatic preview preparation, editing and export. **Two new recovery tests pass**, covering saved movie bytes/project references/recovery guidance after Stop, and missing footage that must not be reported as recovered.
- **Native AU tests pass.** The new startup-position test fails against 0.10.2 and passes against 0.10.3. It checks the observed 18.62-to-4.8 transition, a large initial outlier and a transient zero; the capture anchor is unavailable until coherent reports have settled. Existing clock validation, audio pass-through, transport, state and editor lifecycle checks also pass.
- **Native session tests pass.** Repeated actual encoded takes land at the corrected timeline position and survive Stop. A forced placement failure retains the movie, project media record and recovery message. Existing three/four-camera, shared-source, independent lane start/stop, disconnect, closed-editor, restored-session and MIDI fallback checks pass.
- **Installed validation passes:** `Component Version: 0.10.3 (0xA03)` and `AU VALIDATION SUCCEEDED`. The installed AU, main plist and retained helper match the tested bundle byte-for-byte, and deep/strict code-signature verification passes. Installation backs up 0.10.2 and does not quit Logic.

**Physical setup confirmed:** after reopening Logic with 0.10.3, the user confirmed that the iPhone USB screen-feed clip remains on its lane and plays in Light preview mode. Read-only project/diagnostic checks show three sequential saved takes on lanes 1–3 with retained movie files and correct settled start anchors, with no capture-helper error. This confirms that setup; it is not a claim about all camera combinations.

AU SHA-256: `56ac04d10d9a5ff5ba7664b475c65fd45fbdd1c4eb680b30a91b187cf2f5dfd9`.
Helper SHA-256: `622673b09817eee99c4502fd2818f7c93c4e7ae6c32eceb1cdcc3d2fcff09399`.

## Scope and limits

The helper and encoding pipeline are retained byte-for-byte from 0.10.2 (helper version 0.10.0). The fix concerns take placement and retention. The separate limitation when Logic supplies no transport callbacks during silence remains. Intel/macOS 13+ development build; locally signed AU, unsigned/non-notarized installer, no validated Apple silicon binary.

Local build/test logs: `CamOrderStudio/.build/start-position-check/`. Native Swift builds use four compiler jobs. Tests use `swift test -j 4`, `Scripts/test-au.sh`, and `CAMORDER_SESSION_HEADLESS=1 Scripts/test-session.sh`, followed by installed Apple AU validation.
