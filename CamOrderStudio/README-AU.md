# CamOrder Studio Audio Unit — 0.4.0 development build

CamOrder Studio runs in a mono or stereo **Audio FX** slot in Logic Pro. Use **one instance on Stereo Out**, with your video lanes inside it. Audio passes through unchanged, with no added audio latency. Normal operation uses Logic’s Audio Unit transport; no timecode or MIDI routing is needed for the working Stereo Out setup.

## Install and record

1. Run `Install CamOrder Studio.command`. Fully quit and reopen Logic Pro after an update so it loads the new binary.
2. On **Stereo Out**, choose **Audio FX → Audio Units → Santismo → CamOrder Studio → Stereo**. If missing, rescan CamOrder Studio in Logic’s Plug-in Manager.
3. Open the project menu beside **CamOrder**, choose **New Project…**, and save a `.camorderstudio` folder alongside your Logic project. Keep that whole folder when moving or sharing the project; it contains the media.
4. Choose the shared **Default** source under **Live Inputs**. Every lane initially uses that input, and its preview starts automatically. Use the input menu on an individual lane to assign a different camera or screen source. Allow camera or screen access for the included **CamOrder Capture** helper when macOS asks. Permissions can be changed in System Settings → Privacy & Security.
5. Wait for the live image(s), **Arm** one or more CamOrder lanes, and press **Play or Record in Logic**. For audio recording, also arm the relevant Logic audio track. You can work in Logic’s timeline or close the plug-in editor; the video session stays active.
6. Stop Logic to finalize the take. The armed CamOrder lanes stay armed for the next Play/Record. **Disarm** cancels pre-roll; **Stop Take** finalizes and disarms.

Arming buffers video before transport starts so the beginning of the take can be retained. Different assigned inputs record simultaneously. Lanes sharing one camera use one capture connection and movie file, with a separate timeline region for each armed lane. Missing transport callbacks do not cut off capture or let the CamOrder playhead run indefinitely: the displayed clock holds its last confirmed position. If Logic stops without sending a stop report, use **Stop Take**. A backward transport move or manual Stop Take disarms the lane. Automatic repeated cycle takes are not supported.

## Lane inputs and multiple cameras

New projects start with three lanes; **+** adds more. Each lane starts at **Default**, using the source chosen above the Live Inputs panel. With one camera, every lane can use it without any extra setup. The first automatic choice is saved, so a reordered device list cannot silently change the input later.

Choose another source in a lane’s input menu to give it its own camera. The Live Inputs panel shows **one preview per distinct source**, labeled with the lanes using it. Assign the same source to several lanes to share its preview and connection. Choose **No input** for a lane used only for imported footage. Source assignments save with the project.

Arm any combination of lanes. Their different cameras follow the same Logic Play/Record/Stop clock and keep recording with the editor closed. A camera failure finalizes and disarms its affected lanes; the other cameras continue. Each lane keeps its own video-sync adjustment. Main Stage and export still use the top visible region, rather than combining camera images into a mosaic.

A lane armed during playback starts at the current position. Disarming one shared-camera lane fixes that region’s end while the other lanes keep recording. Its region shows **finishing** until the shared movie is finalized; stop the other lanes sharing that input before rearming that particular lane. Camera selection and capture-region changes are locked while affected lanes are armed or finishing.

Use a preview tile’s **…** menu to restart/stop its preview or show/apply/hide its screen capture region. Multiple previews wrap into a scrollable grid. Hiding Live Inputs affects the layout; it does not stop armed capture.

There is no fixed three-input cap. Four simultaneous synthetic inputs and four independent helper processes were verified. The number of physical cameras and sustainable frame rate depend on macOS, camera availability, USB bandwidth and encoding load; this build has not been tested with four physical cameras on this Mac.

The red transport button and **R** in the plug-in forward Logic’s R key command. **Space** and Play control Logic in **Logic** mode. In **Edit** mode, playback and scrubbing are local, with optional imported master audio. Arming a lane returns to Logic mode. Text entry is unaffected by transport shortcuts. Removing the plug-in ends its session.

## A simpler, adjustable workspace

- Dark graphite UI with teal accents. **Inspector**, **Media**, and **Sync** open only when requested; click outside to hide them.
- Resize freely using the window edge or the small **bottom-right resize grip**. Minimum editor content size is **720 × 360**. There are no fixed layout presets.
- Drag the divider between **Main Stage and Live Inputs** to change their widths. Drag the horizontal divider above the timeline to change monitor/timeline heights. **View** can hide Live Inputs or the timeline and reset panel sizes.
- Main Stage remains available in compact layouts. Each lane’s input selector stays with its name and Arm controls. Lane headers and their Arm buttons scroll together with the timeline.
- The four small exterior canvas corners adjust width and height independently. Drag inside the video to position it; use pinch or Inspector zoom for framing. Inspector also provides rotation and canvas dimensions.
- Main Stage and export use the **top unmuted lane with an enabled region at the playhead**. Selecting a different region does not change compositing priority. Within one lane, the last overlapping region wins. Gaps remain blank.
- Splits and trims retain the correct source frames and framing animation. Original source movies are never rewritten.

Window behavior and screenshots were checked in an owned native AU host. Logic adds its own surrounding window controls and may impose additional sizing behavior.

## Video sync offsets

Open **Sync** for the whole-project offset and each lane’s offset. The sliders icon beside a lane opens its own adjustment. All new controls start at **0 ms**, including when opening an older project.

- **Negative** moves video earlier; **positive** moves it later.
- Project and lane values **add together**. For example, project −40 ms plus lane +10 ms produces −30 ms for that lane.
- Enter a value and press Return or **Apply**, use the 1 ms stepper, or choose **Reset**.
- The displayed regions, Main Stage playback and exported movie use the adjusted positions. Source recordings and underlying edit points stay unchanged. Adjustments save with the CamOrder project and support Undo.
- The panel shows a 1/64-note equivalent at the project tempo. At 88 BPM it is about **42.61 ms**. No correction is applied automatically.

The controls allow ±5000 ms each. Video shifted before project zero is clipped at zero. Imported master audio stays on its own project clock; camera audio, if explicitly included in export, travels with its video. Existing projects retain any previously saved legacy clip timing adjustments in addition to these new controls.

## Inputs

- Built-in cameras and USB webcams exposed by macOS.
- iPhone Continuity Camera over USB or wireless. Enable Continuity Camera, use a trusted connection, and refresh the input list after connecting.
- Wired iPhone/iPad screen capture when macOS exposes the device as a capture input. Connecting a cable alone does not provide an iPhone camera feed; Continuity Camera supplies that.
- Main display recording or a movable capture region on the main display. Use that input tile’s **… → Show capture region**, then **Apply capture region**. Secondary-display capture and an independent window picker are not included in this build.

Captured takes are video-only: they do not record the microphone or Logic’s mix. Import a bounced mix through **Media / Master Audio** if you want it included in the exported file. Imported movies can retain their own audio according to the Inspector’s export audio setting.

## Export the edited movie

1. Click **Export**. The save panel now includes an explicit **Range** choice:
   - **Edited timeline**: the first visible edited region through the final visible region, including all lane/project offsets.
   - **Selected region range**: the selected region’s current edited start and end, while retaining the same visible lane priority as Main Stage.
   - **From playhead**: the current playhead through the final visible region.
   - **From project start**: include time from zero.
   - **Custom range**: enter exact start/end seconds.
2. Check the displayed start, end and movie duration. MOV and MP4 exports read the current source trim; removed footage is not restored at the front. Exported master audio is restricted to the chosen range.
3. The movie is accompanied by a `.logic-placement.txt` note containing its **edited timeline start**. Use the project menu’s **Show last export** to reveal it.
4. In Logic, open the movie through **File → Movie → Open Movie**. Place Logic’s playhead at the start given in the note and use **Move Movie Region to Playhead**, or set Movie Start in Project Settings → Movie. For an absolute SMPTE position, add the Logic project’s SMPTE origin to the note’s seconds.

Movie import and placement are manual; this Audio Unit does not change Logic’s movie track. Export defaults to a silent movie for use with Logic’s existing audio. Existing exports survive a failed render, and source-media destinations are rejected.

## Optional transport fallback

The previous prominent “Connect Logic” setup is removed from the normal workflow. **AU timing has priority** whenever Logic is actively processing CamOrder on Stereo Out. An optional fallback remains under **View → Optional transport fallback…** to preserve existing connections and cover hosts/channels that stop sending AU timing.

Only if you encounter that condition, route **MTC and MMC** from Logic’s Project Settings → Synchronization → MIDI to **CamOrder Logic Link**, and enable Transmit MIDI Machine Control. Keep Logic in Internal Sync. Match CamOrder’s fallback project-start hour to Logic’s bar-1 SMPTE time (usually 01:00:00:00). Existing routing may remain; it does not override fresh AU transport.

Stopped cursor movement can only be followed when Logic sends a position report. The optional MIDI path supports 24, 25, 29.97 drop-frame and 30 fps, with whole-hour project origins. It is not sample-accurate video lock. There is no timecode audio track to configure.

## Performance changes

Live frames now update a native image layer directly. Timeline geometry and filmstrips no longer rebuild with every playhead tick; moving cursors and clocks update separately. Playback seeks are serialized, and resuming the decoder uses the requested host-clock anchor so seek completion does not leave a persistent playback delay.

The synthetic 30 fps playback check delivered **51 decoded frames over 1.7 seconds**. A 12-second capture test delivered **360 preview frames**, with no recording warnings. These checks do not measure camera latency or end-to-end synchronization with Logic’s audio; use a visible/audio cue to choose your own offset for the actual camera and session.

## Verification

- 33 Swift tests: real MOV/MP4 exports, trimmed first-frame colors, audio cue alignment after offsets, custom export ranges, negative offsets, save/reopen compatibility, layer priority, splits, animated framing, capture and preview delivery, and transport gaps.
- Installed-component validation with Apple’s `auval` for `aufx / CmSt / Sntm`.
- Bit-exact mono/stereo pass-through at 44.1, 48 and 96 kHz, including silent input and 1/64/512-frame blocks; independent Audio Unit instance state.
- Native editor creation, close/reopen and screenshots at 1280 × 820, 820 × 520, 1120 × 460, 760 × 440, arbitrary 803 × 417, and minimum 720 × 360; the four-input overview is also captured at 1280 × 960.
- Production recording session with no editor: Play/Record, host following, Stop, repeated takes, missing callbacks and manual finalization, using real encoded synthetic-camera movies.
- Multi-input session regression: three lanes sharing one camera/file, three different cameras with one disconnecting mid-take, independent late arm/stop on a shared camera, four simultaneous encoded movies, and assignment save/reopen.
- Four capture helpers running together with isolated command channels and clean shutdown, without activating physical cameras.
- Isolated CoreMIDI fallback transport with no AU processing, R/Space forwarding, actual SwiftUI canvas and window-grip drags, and saved edit/offset/undo regressions.
- Capture-helper launch, input discovery and clean shutdown without activating a physical camera.
- Read-only playback of the saved edited regions in the existing test project.

A verification summary and screenshots are included in the release. The actual Logic session and physical camera combination still need a user check after restart. The download is a locally signed development build for **Intel Macs, macOS 13 or newer**, not a notarized or universal distribution release.

An old cut made before the 0.2.5 fixes may already contain an incorrect saved source start. The app cannot safely infer its intended content; redo an affected old cut from the original take. Original media remains intact.

## Build and uninstall

Requires Xcode and its command-line tools. Apple’s AudioUnitSDK is vendored with its license and pinned revision; no paid libraries or package downloads are needed.

```sh
cd CamOrderStudio
Scripts/build-au.sh
swift test
Scripts/test-au.sh
Scripts/test-session.sh
Scripts/install-au.sh
auval -v aufx CmSt Sntm
```

Build and session tests must run sequentially because the session harness links the build’s object files. The default architecture is the current Mac; set `CAMORDER_ARCH=arm64` or `x86_64` to cross-compile one architecture. The standalone Swift app is still available with `swift run CamOrderStudio` and uses its original MTC workflow. The installed standalone app and older CamOrder.component are not replaced.

To uninstall, quit Logic and remove `~/Library/Audio/Plug-Ins/Components/CamOrder Studio.component`. Video projects are independent and are not deleted. Installer backups are stored in `~/Library/Application Support/CamOrder Studio/Plugin Backups`.
