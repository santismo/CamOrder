# Website session examples

The website uses the project owner’s real CamOrder performances and saved projects. Marketing captions describe the content rather than exposing working filenames or recording dates.

| Asset | Content | Duration |
| --- | --- | --- |
| `loop-idea.mp4` | Edited percussion, bass and guitar performance, with the original music | 28.57 seconds |
| `camera-session.mp4` | Guitar performance with saved zoom/pan automation and the original music | 86.17 seconds |
| `camera-clock-test.mp4` | The final camera-to-clock calibration region from the saved session | About 5.45 seconds, silent |
| `automation-editor.mp4` | The production CamOrder editor playing the saved automation project, timeline seconds 42–60 | 18 seconds, silent |

The two finished movies retain their original edits, timing and sound. Web copies use 1280 × 720 H.264 video, AAC stereo audio and fast-start MP4 headers. The guitar movie’s audio extends about 2.54 seconds beyond its video track; that source timing is preserved. Posters come from the same recordings.

The editor screenshot and silent playback demonstration use the production SwiftUI editor in a separate native preview host. Copies of the saved projects reference the original takes. Only display names and presentation settings are adjusted for the showcase: live input is hidden and the timeline zoom is reduced to show the edit. Regions, media timing, framing and automation are unchanged. The demonstration is captured at 12 fps; it is a workflow illustration, not a performance benchmark or a recording of the Logic host. Page captions identify the separate preview window.

The automation project contains lead, chords and bass takes, with 11 markers on the lead region. Its export placement note starts the movie at 7.272721 seconds, so timeline seconds 42–60 correspond to movie seconds 34.727279–52.727279. The page’s matching-section button starts the full movie there.

`../images/logic-session-september-27.jpg` is the unmodified saved window image from the related Logic project. It shows the export in Logic’s movie lane alongside drums, guitar and bass. The original recordings and project bundles are not included in this repository.

Players preload metadata so duration and native controls are ready; there is no autoplay. Starting one pauses the other players. Keep download links on `/releases/latest` (or its stable installer assets); release numbers belong in release and technical documentation.

The camera clock test is the final saved region, extracted from source seconds 6.003040011–11.457585466. It is not part of the earlier finished guitar export. The page labels its original samples display explicitly and instructs new tests to use milliseconds. The saved project correction is −82 ms; no claim is made that this is a universal Continuity Camera latency or that it can be measured from this one clock image alone.
