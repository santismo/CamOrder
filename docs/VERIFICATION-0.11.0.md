# CamOrder Studio AU 0.11.0 — per-input recording crops

Date: November 11, 2026. Physical camera follow-up confirmed.

## Behavior

Live Inputs → the input’s **…** menu → **Crop input…** opens a larger resizable window with the full source feed. Drag edges/corners, move the selection, or adjust the four border sliders. Apply saves the crop for that source in the project; Cancel leaves it unchanged; Reset followed by Apply restores the full frame. All lanes sharing a source share its crop.

Crops are baked into new movie pixels before encoding, independently of Main Stage framing and preview quality. Existing movies are unchanged. The source-relative rectangle uses the remaining source resolution, rounded inward to even output dimensions. Mac screen/window inputs use the same recording path; the existing screen-region selector remains separate.

Applying or undoing a crop cannot change an armed input, pre-roll, active take, or finalizing writer. The crop editor closes when its input/project goes away. The full preview feed remains available for expanding/resetting a crop, while the Live Inputs card shows the cropped view. No second camera connection is opened for the editor.

The cropper reuses a bounded BGRA pixel pool and copies only selected rows. An uncropped take keeps the original sample path. If the pool is busy, a frame is counted as dropped without ending the take or including uncropped borders. Original sample timing and the existing host-clock mapping are retained. If cropped output dimensions change mid-take, capture finalizes usable footage and reports the change.

## Verification

- **106 Swift tests passed**, including all 96 prior tests and ten crop tests. Cropped decoded movies match corresponding pixels from the uncropped reference. Three inputs encode distinct crops under Light preview, reset restores full resolution, active-writer changes are rejected, and preview/raw-feed orientation agrees.
- **Three 1920 × 1080 synthetic inputs** recorded 270 frames with Light previews and no recording warnings; each cropped output is 1440 × 810. This is an automated regression, not a claim about all physical three-camera setups.
- Tests cover exact top-left pixel selection, original timestamps, old-project decoding, per-source persistence/shared lanes, busy-input/undo protection, bounded-pool backpressure/recovery, static-window recording, native drag geometry, raw preview independence, and closing the crop editor without committing its draft.
- The existing 12-second recording/preview test delivered 358 preview frames with no recording warning. Playback timing, automatic preparation, recovery, editing and export tests remain passing.
- **Native AU tests passed:** startup clock/outlier correction, transport callbacks, silent-audio behavior, audio pass-through, instance isolation, state restoration, and editor lifecycle/resizing.
- **Native session tests passed:** corrected startup/outlier takes survive Stop, forced placement failure retains the movie and recovery message, repeated Play/Record, closed-editor capture, MIDI fallback, restored sessions, three/four-camera recording, shared-source lane joins/stops, disconnect recovery, and editing/undo regressions.
- **Installed Apple AU validation passed:** `Component Version: 0.11.0 (0xB00)` and `AU VALIDATION SUCCEEDED`. The installed AU, helper and both plists match the tested build byte-for-byte; deep/strict code-signature verification passes. The installer backed up 0.10.3 under backup `20261111-003204` and left Logic running.
- The crop window was visually checked using an owned native test window. The preview fixture is synthetic; it does not establish a physical iPad/iPhone camera result.

AU SHA-256: `d3da1b56cfe49eb26995ed7e57b24b91af166f9d721600bc2b2ca69550880a2f`.
Helper SHA-256: `d8f98c0b6bbebe39592ae7c494ec6cc841e011dbd425534fe0b5da0df39065f9`.

## Scope and limits

The 0.10.3 recording-start and footage-recovery fixes are retained. Both the AU and capture helper are now version 0.11.0; this feature requires the new helper. macOS may request capture permission again for CamOrder Capture after reopening the host. Existing Logic projects and media are not changed by installation; the installer backs up the previous component and does not quit Logic.

**Physical setup confirmed:** the user completed the requested AU 0.11.0 follow-up and reported that crop and recording work: the cropped USB screen-camera take plays correctly, and removed borders remain absent when the clip is shrunk on Main Stage. This confirms their setup; it is not a claim about every iPhone/iPad combination. Keep device orientation fixed while recording.

Rectangular crops only. Cropping does not turn a USB screen feed into a direct camera connection, restore pixels from older recordings, or fix missing Logic transport callbacks during silence. Intel/macOS 13+ development build, locally signed, without a validated Apple silicon binary.

Local build/test logs: `CamOrderStudio/.build/input-crop-check/`. Tests use `swift test -j 4`, `Scripts/test-au.sh`, and `CAMORDER_SESSION_HEADLESS=1 Scripts/test-session.sh`.
