# CamOrder Studio Plan

## Current CamOrder architecture

CamOrder is currently a browser-based workflow centered on `index.html`. The web app records camera takes, writes media into a selected project folder, generates FCPXML/Resolve-oriented output, and relies on an FFmpeg conversion step for WebM-to-MOV compatibility. That workflow remains valuable for existing users and should stay intact while the native app grows beside it.

## New native architecture

CamOrder Studio should be a native macOS app built with Swift, SwiftUI, AVFoundation, AVKit, CoreMIDI, CoreMedia, UniformTypeIdentifiers, and Codable project files. Logic Pro remains the master timeline. CamOrder Studio follows transport/timecode from Logic, records or imports video into timeline lanes, lets the user select and trim takes, imports mastered audio later, and exports a finished `.mov` or `.mp4`.

The first scaffold is intentionally package-first under `CamOrderStudio/`:

- `CamOrderStudioCore`: model, timecode, project document, parser, and engine interfaces.
- `CamOrderStudioApp`: SwiftUI shell for project create/open/save, media import, preview, sync status, inspector, and simple timeline display.
- `CamOrderStudioCoreTests`: focused tests for timecode math, MTC parsing, project JSON, and latency placement.

## Why native macOS app instead of AU plugin

An Audio Unit is mainly appropriate when the product must generate or process audio inside a DAW host. CamOrder Studio is a video recording, editing, and rendering application. It needs Logic Pro transport and timeline position, not live audio streaming from Logic. CoreMIDI/MTC gives a more direct MVP path because SMPTE-style `hh:mm:ss:ff` maps naturally to a video editor timeline.

An AUv3 or helper bridge can be researched later if Logic integration needs become more advanced, but it should not be the main product surface.

## Reuse vs rewrite

Keep:

- Existing static web workflow and documentation.
- Existing FCPXML/Resolve export concepts as legacy/advanced compatibility.
- Existing media folder assumptions where they help migration.

Rewrite/build native:

- Project model and persistence as `.camorderstudio/project.json`.
- Timecode/frame-based timeline.
- AVFoundation import, preview, composition, and export.
- CoreMIDI sync engine.
- Camera capture and capture-latency placement.

## App module breakdown

- `CamOrderStudioApp`: native app entry point.
- `ProjectStore`: UI-facing state and project commands.
- `ProjectDocument`: create/open/save `.camorderstudio` folders.
- `CamOrderProject`: Codable project root.
- `Timeline`, `VideoLane`, `VideoClip`: timecode-based edit model.
- `MediaAsset`, `MediaLibrary`: imported and recorded media metadata.
- `LogicSyncEngine`: CoreMIDI/MTC sync state owner.
- `MTCParser`: quarter-frame and full-frame MTC parser.
- `MIDIClockParser`: secondary beat/clock sync parser.
- `CameraCaptureEngine`: preview and recording interface.
- `RenderExportEngine`: AVFoundation render/export interface.
- `MasterAudioImporter`: mastered audio ingest.
- `CaptureLatencyProfile`: per-camera manual latency offsets.
- `ExportSettings`: container, resolution, frame-rate, and audio-mode options.

## Project file format

Project folders should use:

```txt
MyProject.camorderstudio/
  project.json
  media/
    video/
    audio/
    proxies/
  exports/
  logs/
```

The JSON root stores `projectVersion`, `name`, `frameRate`, `resolution`, `timeline`, `media`, `sync`, `audio`, `captureLatencyProfiles`, and `exportSettings`. Recorded clips store both Logic start time and adjusted timeline placement so placement is based on Logic timecode, not file finalization time.

## Timeline model

The MVP timeline is video-first and timecode-based:

- Store frame rate explicitly with `FrameRate`.
- Represent display/playhead values with `Timecode`.
- Store timeline placement in seconds and frame-derived values.
- Avoid assuming every project is 30 fps.
- Support multiple lanes with per-lane arm/mute state.
- Resolve overlapping clips initially by highest enabled lane or explicit active clip, then document that export rule.

## Export model

`RenderExportEngine` should use AVFoundation:

- Build an `AVMutableComposition`.
- Add selected/active video clips at their timeline positions.
- Add mastered audio with `audioOffsetSeconds`.
- Default to mastered audio only.
- Export `.mov` first, `.mp4` where feasible.
- Report progress and AVFoundation errors clearly.

The first scaffold only defines the engine surface. The first real export milestone should support simple cuts before complex multi-layer compositing.

## Milestones

1. Docs, native scaffold, project create/open/save, video import, preview.
2. Timeline lanes, clip placement, trimming, save/load timeline.
3. CoreMIDI/MTC sync, Logic playhead chase, sync status UI.
4. Camera recording into armed lane, Logic-timecode placement, capture latency offset.
5. Mastered audio import, audio offset, export with mastered audio.
6. Polish, legacy import, waveform/timeline improvements, optional pre-roll, optional AUv3/helper research.

## Risks

- Logic Pro sync setup may vary by user and project.
- MTC quarter-frame timing needs stability detection and locate/jump handling.
- Camera capture startup latency can vary by device and format.
- Pre-roll buffering may be needed for tight starts but is more complex than manual offset.
- AVFoundation export gets harder with overlapping lanes, mixed frame rates, and camera audio rules.
- SwiftPM app scaffolding is convenient for early work but an Xcode project or app bundle packaging may be needed for distribution.
