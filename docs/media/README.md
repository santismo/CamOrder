# Website session examples

The website uses the project owner’s real CamOrder performances and saved projects. Marketing captions describe the content rather than exposing working filenames or recording dates.

| Asset | Content | Duration |
| --- | --- | --- |
| `loop-idea.mp4` | Edited percussion, bass and guitar performance, with the original music | 28.57 seconds |
| `camera-session.mp4` | Guitar performance with saved zoom/pan automation and the original music | 86.17 seconds |
| `camera-clock-test.mp4` | The final camera-to-clock calibration region from the saved session | About 5.45 seconds, silent |
| `full-session.mp4` | Drums and touchscreen instruments in a complete six-lane arrangement, with the original music | 128.37 seconds |
| `full-session-editor.mp4` | Current production editor playing the saved six-lane arrangement, timeline seconds 50–68, with controls at the bottom | 18 seconds, silent |
| `automation-editor.mp4` | The production CamOrder editor playing the saved automation project, timeline seconds 42–60 | 18 seconds, silent |

The finished movies retain their original edits, timing and sound. Web copies use 1280 × 720 H.264 video, AAC stereo audio and fast-start MP4 headers. The guitar movie’s audio extends about 2.54 seconds beyond its video track; that source timing is preserved. Posters come from the same recordings.

The editor screenshot and silent playback demonstration use the production SwiftUI editor in a separate native preview host. Copies of the saved projects reference the original takes. Only display names and presentation settings are adjusted for the showcase. The earlier examples hide live input and reduce timeline zoom; the full-arrangement example uses the current editor’s bottom-controls option with live camera connections disabled in the preview host. Regions, media timing, framing and automation are unchanged. The demonstration is captured at 12 fps; it is a workflow illustration, not a performance benchmark or a recording of the Logic host. Page captions identify the separate preview window.

The automation project contains lead, chords and bass takes, with 11 markers on the lead region. Its export placement note starts the movie at 7.272721 seconds, so timeline seconds 42–60 correspond to movie seconds 34.727279–52.727279. The page’s matching-section button starts the full movie there.

`../images/logic-session-september-27.jpg` is the unmodified saved window image from the related Logic project. It shows the export in Logic’s movie lane alongside drums, guitar and bass. The original recordings and project bundles are not included in this repository.

Players preload metadata so duration and native controls are ready; there is no autoplay. Starting one pauses the other players. Keep download links on `/releases/latest` (or its stable installer assets); release numbers belong in release and technical documentation.

The camera clock test is the final saved region, extracted from source seconds 6.003040011–11.457585466. It is not part of the earlier finished guitar export. The page labels its original samples display explicitly and instructs new tests to use milliseconds. The saved project correction is −82 ms; no claim is made that this is a universal Continuity Camera latency or that it can be measured from this one clock image alone.

The full-arrangement project has six lanes (drums, keys, synth bass and synth chords), 116 regions and 52 framing markers at a saved tempo of 77 BPM. The finished movie is the owner’s supplied final cut, not a new render from the preview host; it includes later finishing and is not advertised as an exact timestamp match to the editor excerpt. The original project bundle, source takes and Logic project remain private and unchanged.
