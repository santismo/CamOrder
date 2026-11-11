# CamOrder Studio AU 0.10.1 — automatic playback previews

November 10, 2026. Intel/macOS 13+ development build.

## Behavior

In Balanced or Light, Main Stage automatically prepares missing playback copies after one idle second. It must be visible, playback stopped, every lane disarmed, and capture/export inactive. Full does no preparation. Closing Main Stage suspends work; reopening it picks up pending clips. Completed previews stay cached, including when new recordings join the project.

Transport, arming, capture, export, view closure and quality/project changes cancel unfinished work. A replacement job waits for the cancelled job to finish cleaning up, avoiding overlapping conversions. Failed files use originals and are not automatically retried continuously. Prepare now starts immediately while idle or retries failures. Pause previews pauses the current idle period.

Recording encoders, original media, export inputs, source timing and live-preview quality are unchanged from 0.10.0. The preparation list resolves paths when media changes, not on each playhead update. The optional direct-camera ideas remain deferred.

## Verification

- **94 Swift tests passed, zero failures.** Six new scheduling tests cover busy/idle gating, newly recorded files, cached-file reuse, immediate/manual requests respecting the gate, cancelling in-flight work, automatic resume, serial job retirement, cancelling during the idle delay, Full mode, pause/resume, quality/project changes, and failure retry behavior. The existing real proxy conversion tests still cover dimensions, portrait/VFR timing, source preservation and cancellation cleanup.
- The production full-editor fixture automatically reached **Auto · playback 1/1 ready** with no Prepare click. Its screenshot was visually inspected. Existing lane-drag and editing tests pass. The 12-second recording fixture delivered 359 previews with no recording warnings, and the playback fixture decoded 51 frames in 1.7 seconds with 0.07 ms mean clock error. These are synthetic-fixture results, not physical-camera performance promises.
- Native AU integration passes transport callbacks/fallback/error handling, silent and ordinary pass-through, mono/stereo 44.1/48/96 kHz with 1/64/512-frame blocks, state round trip, instance isolation, and native editor creation/resizing/closing/reopening.
- The installed bundle passes deep/strict code-signature checks and its AU/helper binaries and main plist match the tested build byte-for-byte. Apple `auval` reports **Component Version: 0.10.1 (0xA01)** and **AU VALIDATION SUCCEEDED**. Installation backed up the previous 0.10.0 component. Only the user's disposable AudioComponentRegistrar was restarted; Logic and its projects were not closed or edited.
- The exact 0.10.0 capture helper is retained, including its signing identity. Its executable SHA-256 is `622673b09817eee99c4502fd2818f7c93c4e7ae6c32eceb1cdcc3d2fcff09399`. Core capture/preview/proxy sources and helper sources are unchanged from the tested 0.10.0 build. A normal source rebuild may generate a different ad-hoc identity; the local release package deliberately restores the verified helper before signing the outer AU.

The [0.10.0 record](VERIFICATION-0.10.0.md) covers live-preview CPU measurements and the previous native three/four-camera session tests. This update changes the preparation controller/UI, not capture or host-session logic. The public release also includes the automatic motion, lane-drag and playback improvements documented in [0.9.0](VERIFICATION-0.9.0.md) and [0.9.2](VERIFICATION-0.9.2.md), which were already part of the local development build.

## Limits and reproduction

Automatic preparation runs while Main Stage is visible. It does not create a headless background worker when the editor is closed. Encoding still uses resources while idle; only missing previews are processed, one at a time. Physical camera combinations and the user's exact Logic session require user verification. This change does not fix missing Logic transport callbacks during silence; the user's metronome observation remains a separate workaround.

Commands: `swift test -j 4`, `Scripts/build-au.sh`, `Scripts/test-au.sh`, `Scripts/install-au.sh`, `auval -v aufx CmSt Sntm`. The release build used the same build script with four Swift compiler jobs, then restored the identical helper before signing. Logs/screenshots are under `CamOrderStudio/.build/auto-preview-check/`. Installer/DMG/source ZIP packaging uses the existing scripts; checksums accompany the assets. The installer remains unsigned and non-notarized; the AU is locally ad-hoc signed. Apple silicon builds are not included or validated.
