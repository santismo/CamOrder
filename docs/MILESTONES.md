# CamOrder Studio Milestones

## Milestone 1

- Add architecture and sync documentation.
- Add native macOS app scaffold.
- Add Codable project model.
- Create/open/save `.camorderstudio` project folders.
- Import video into `media/video`.
- Preview imported video.
- Add stubs for `LogicSyncEngine`, `MTCParser`, `CameraCaptureEngine`, `RenderExportEngine`, and `MasterAudioImporter`.
- Add basic tests for timecode, MTC parsing, project JSON, and latency placement.

## Milestone 2

- Add editable timeline lanes.
- Place clips on lanes.
- Edit clip start and duration.
- Add basic trim in/out controls.
- Save/load timeline edits.
- Define the first overlap rule for preview/export.

## Milestone 3

- Implement CoreMIDI input in `LogicSyncEngine`.
- Receive MTC from Logic Pro or IAC Bus.
- Feed raw MIDI packets into `MTCParser`.
- Make the app playhead chase incoming timecode.
- Show sync state and current Logic timecode in the UI.
- Add tests for locate/jump and unstable timecode behavior.

## Milestone 4

- Add camera device picker and preview.
- Arm one video lane at a time.
- Start recording when Logic starts and a lane is armed.
- Store pending recording state with lane id, requested Logic timecode, host time, and camera id.
- Stop/finalize recording when Logic stops.
- Create clips from recorded files and place them using Logic timecode.
- Apply manual per-camera capture latency offset.
- Persist capture warnings and dropped-frame messages.

## Milestone 5

- Import mastered audio files supported by AVFoundation.
- Store mastered audio as project media.
- Add a master audio lane placeholder.
- Edit audio offset in seconds or timecode.
- Implement AVFoundation export with mastered audio baked in.
- Support mastered audio only by default.
- Add camera audio and mute-all export options.

## Milestone 6

- Improve polish and packaging.
- Add legacy CamOrder project import.
- Detect existing `media/`, `.webm`, `.mov`, and FCPXML files.
- Generate migration reports when timing metadata is missing.
- Improve waveform and timeline UI.
- Add optional pre-roll buffer.
- Research optional AUv3/helper bridge only if CoreMIDI sync is insufficient.
