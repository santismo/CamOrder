# CamOrder Studio AU 0.10.2 — recording-start clock fix

Date: November 10, 2026 (local session; verification continued November 11 UTC).

## Failure and change

Local capture logs showed armed lanes and fresh successful Logic transport callbacks, but take starts far ahead of the playhead: approximately 219.57 seconds with Logic at 2.44, and 38.86 seconds with Logic at 4.86. At Stop the resulting region had no usable duration. This was separate from unavailable transport callbacks and automatic preview preparation.

A native AU regression reproduces that failure by supplying a fresh Play position with an old render host timestamp on its first block. It failed against the unchanged 0.10.1 binary before the fix. The AU now preserves render timestamps within two seconds of the callback's current monotonic host clock and substitutes that current clock for implausibly old/future values before setting the take-start anchor. It does not change Logic's reported timeline position. Capture diagnostics also include the published host/start anchors.

The recording encoder, preview scheduler and original media formats are unchanged. The packaged capture helper is byte-for-byte identical to 0.10.1 (helper version 0.10.0), preserving its existing local signing identity.

## Verification

- **94 Swift tests passed with zero failures**, including recording, playback, automatic preview preparation, editing and export.
- **Native AU regression:** the startup-clock check failed against 0.10.1 and passes against 0.10.2. It exercises render timestamps 217/34 seconds old, 34 seconds in the future, and a valid precise timestamp. AudioUnitProcess and AudioUnitRender transport paths, mono/stereo bit-exact audio pass-through, callback failure handling, state isolation and editor lifecycle checks pass.
- **Native session regression:** repeated Play/Record with stale/future first-block timestamps saves actual encoded, playable movies at the expected lane position and duration, then disarms on Stop. Existing tests also pass for closed-editor recording, restored projects, MIDI fallback, missing timing, independently joining/stopping lanes, three/four simultaneous synthetic cameras and disconnecting one camera while others continue.
- **Installed validation:** Apple `auval` reports `Component Version: 0.10.2 (0xA02)` and `AU VALIDATION SUCCEEDED`. Deep/strict code-signature verification passes. The installed AU binary, main plist and retained helper match the tested bundle byte-for-byte. Installation backed up 0.10.1; Logic and its projects were not closed or edited.

Helper SHA-256: `622673b09817eee99c4502fd2818f7c93c4e7ae6c32eceb1cdcc3d2fcff09399`.
AU binary SHA-256: `0a17d9be51c5bdc0f4e8a688f33c9f65b86c8f58a0911d220d971fe92ae479fb`.

## Limits

These checks use the production AU and session with synthetic host callbacks and real encoded test movies. They do not claim a successful new take in the user's running Logic session with physical cameras. Logic must be fully quit and reopened to load the installed update. The separate missing-callback limitation during silence remains; this fix handles bad render timestamps in callbacks that do arrive.

The build targets Intel Macs running macOS 13 or later. The AU is locally ad-hoc signed; the installer is unsigned and non-notarized. Apple silicon binaries are not included or validated. Historical preview checks are recorded in [0.10.1](VERIFICATION-0.10.1.md).

Commands: `swift test -j 4`, `Scripts/build-au.sh`, `Scripts/test-au.sh`, `CAMORDER_SESSION_HEADLESS=1 Scripts/test-session.sh`, `Scripts/install-au.sh`, `auval -v aufx CmSt Sntm`. Native Swift builds use four compiler jobs. Local logs are in `CamOrderStudio/.build/recording-check/`; release packaging uses the existing ZIP/PKG/DMG scripts.
