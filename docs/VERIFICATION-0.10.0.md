# CamOrder Studio AU 0.10.0 — preview quality

November 10, 2026. Local Intel/macOS 13+ development build, based on the installed 0.9.2 source (including automatic motion, lane drag and unarmed playback fixes). The phone-camera page and deferred direct-camera notes are retained.

## Behavior

- Main Stage offers Full, Balanced and Light. Balanced is the initial default; the preference persists in the host's user defaults and applies to all lane capture helpers, including helpers created later.
- Live previews scale before mailbox rendering/copying. For a 1920 × 1080 source the delivered image sizes are 960 × 540, 640 × 360 and 320 × 180. Cadence and the original capture samples remain unchanged. Light transfers one ninth of Full's pixel payload; this is not a claim of a ninefold CPU improvement.
- Prepare playback creates disposable video-only H.264 copies using AVFoundation's [size presets](https://developer.apple.com/documentation/avfoundation/export-presets), with original source time and orientation. Balanced caps at 1280 × 720; Light uses the 640 × 480 preset (640 × 360 for the tested 16:9 input). Small files remain original. Unprepared or failed files also use originals.
- Conversion runs one file at a time per open Main Stage, only after an explicit click while stopped/disarmed. Starting playback, arming, capture activity, exporting, quality/project changes, or closing the view cancels it. Start/cancel are serialized to prevent a cancelled job starting later. Completed copies are kept.
- Cached filenames include a hash of source path, size, modification timestamp and quality. The cache is separate from project files. No recording encoder or final-export source path uses it.
- Full immediately returns Main Stage to original files and Live Inputs to its previous maximum. Preview quality can change during capture without restarting the camera session.

## Verification

- **88 Swift tests pass, zero failures.** The five new tests cover actual live-frame dimensions and color, original buffer dimensions, portrait/VFR preview generation and source-time color transitions around the one-second boundary, source byte preservation, changed-source invalidation, cache reuse, immediate/in-flight cancellation cleanup, persistent preferences, and ignoring late cancelled results.
- The existing 12-second real-encoder test now switches Full → Balanced → Light during capture. It produced a 960 × 540 movie at the original duration with no recording warnings and 309 preview deliveries. Existing movie export, layering, timing, motion, edits and playback decoder tests pass. The playback fixture decoded 47 frames in 1.7 seconds with 0.27 ms mean clock error; these are synthetic-fixture results, not a guarantee for all Logic sessions.
- Two existing tests had wall-clock assumptions exposed during cold encoder startup and UI timer delays. The replacement-window test now waits for its first encoded frame before measuring a 400 ms take. The full-editor lane-drag test waits up to four seconds for the required destination instead of a fixed 1.3-second sleep. Assertions about recorded duration, dimensions, lane movement and Undo remain in place. No production capture or drag logic was changed for these test failures.
- The full editor with test-pattern footage was visually inspected at 1280 × 820 points. Preview selector, Prepare playback and status fit under Main Stage. This is an owned test window, not the user's Logic project.

- After removing repeated media-path resolution from playhead updates, **14 focused preview/editor tests passed** again. The repeated capture fixture delivered 357 previews over 12 seconds without warnings. Native AU integration also passes at compact/flat editor sizes, and those images were inspected.
- Native AU integration passes transport callback ordering/fallback/error handling, silent and ordinary audio pass-through, mono/stereo 44.1/48/96 kHz with 1/64/512-frame blocks, project-state round trip, instance isolation, and editor creation/resizing/close/reopen.
- The native session suite passes with the editor closed: unarmed playback, host timing loss behavior, CoreMIDI fallback, key forwarding, editing and restoration, shared-camera recording, three independent simultaneous cameras, one-camera disconnect isolation, independent lane join/stop timing, and four aligned inputs. Cameras in this suite are synthetic but encode real movies through the production session. The historical broad pointer-gesture suite was omitted using the existing `CAMORDER_SESSION_HEADLESS=1` option; the separate full-editor lane-drag test passes. The unchanged session script was run with four Swift compiler jobs to shorten compilation.
- The actual bundled helper acknowledges Full → Light → Balanced through its JSON command/status channel, ignores an invalid preference, remains idle during this test and removes its channel on quit. No physical camera was activated by that probe.
- Built and installed AU/helper binaries and plists match byte-for-byte. The installed bundle passes deep, strict code-signature verification. Apple `auval` reports **Component Version: 0.10.0 (0xA00)** and **AU VALIDATION SUCCEEDED**. The user's disposable AudioComponentRegistrar was restarted with SIGKILL after an ordinary termination left the cached 0.9.2 version; no Audio Unit cache files, host preferences or privacy permissions were deleted.
- Installation preserved 0.9.2 at `~/Library/Application Support/CamOrder Studio/Plugin Backups/20261110-222926/`. Logic and its projects were not closed or edited.

## Preview microbenchmark

An optimized standalone harness rendered and copied 300 synthetic 1920 × 1080 source frames through the production shared-preview path after ten warm-up frames per mode. CPU is user + system time for that process; it omits the host UI, WindowServer, driver processes and camera encoders. No recording or export ran concurrently with the final measurement.

| Implementation/mode | Process CPU seconds | Wall seconds |
| --- | ---: | ---: |
| Prior preview implementation | 1.383 | 1.961 |
| Full | 1.392 | 1.916 |
| Balanced | 1.028 | 1.278 |
| Light | 0.960 | 0.992 |

Balanced and Light used approximately 26% and 31% less process CPU time than Full in this one bounded measurement. Hardware/load and real camera content can change results. No overall Logic CPU reduction or simultaneous-physical-camera performance figure is claimed. Real playback proxies reduce decoded frame dimensions; the tests verify their dimensions, timing and orientation rather than making a decoder-speed claim.

## Reproduction and release files

Source: `codex/preview-quality` in this session's `work/CamOrder` checkout. Main commands: `swift test -j 4`, `Scripts/build-au.sh`, `Scripts/test-au.sh`, `CAMORDER_SESSION_HEADLESS=1 Scripts/test-session.sh`, `Scripts/install-au.sh`, and `auval -v aufx CmSt Sntm`. Logs and synthetic benchmark/helper probes are under `CamOrderStudio/.build/preview-check/`; build outputs are under `CamOrderStudio/dist/`. The installable archive includes the matching source. Local builds remain ad-hoc signed, with an unsigned, non-notarized installer.

## Limits

Three full-quality camera encoders still consume resources. Physical three-camera recording and the user's exact Logic session require a follow-up user check. The metronome improvement is the user's observation; this release does not change Logic transport or resolve missing callbacks in silent sections.

The helper is rebuilt in this release, unlike 0.9.2's deliberately retained 0.8.0 helper. Its ad-hoc signing identity changes and macOS may ask for Camera or Screen Recording access again. No privacy permissions are reset automatically. The installer backs up the previous AU and never quits Logic.

Playback copies consume local cache space. Quit Logic before deleting `~/Library/Caches/com.santismo.CamOrderStudio/Preview-v1/` to reclaim it. Reopen Logic and prepare again when needed.
