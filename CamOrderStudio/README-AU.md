# CamOrder Studio Audio Unit — 0.11.0 development build

CamOrder Studio runs in a mono or stereo **Audio FX** slot in Logic Pro. Use **one instance on Stereo Out**, with your video lanes inside it. Audio passes through unchanged, with no added audio latency. Normal operation uses Logic’s Audio Unit transport without MIDI routing, but depends on Logic continuing to process that channel. For silent sections or video-only editing, read [Transport and silent playback](#transport-and-silent-playback).

## Install and record

1. Open the downloaded **DMG**, double-click **Install CamOrder Studio.pkg**, and follow the standard Mac installer. It installs the AU and capture helper in your account’s plug-in folder. A direct PKG download is also available; the ZIP retains `Install CamOrder Studio.command` as an alternative. Fully quit and reopen Logic Pro afterward so it loads the new binary.
2. On **Stereo Out**, choose **Audio FX → Audio Units → Santismo → CamOrder Studio → Stereo**. If missing, rescan CamOrder Studio in Logic’s Plug-in Manager.
3. Open the project menu beside **CamOrder**, choose **New Project…**, and save a `.camorderstudio` folder alongside your Logic project. Keep that whole folder when moving or sharing the project; it contains the media.
4. Choose the shared **Default** source under **Live Inputs**. Every lane initially uses that input. Camera and main-display previews start automatically; Screen region needs an applied region, and Window needs a selection in the macOS picker. Use the input menu on an individual lane to assign a different camera or screen source. Allow camera or screen access for the included **CamOrder Capture** helper when macOS asks. Permissions can be changed in System Settings → Privacy & Security.
5. Wait for the live image(s), **Arm** one or more CamOrder lanes, and press **Play or Record in Logic**. For audio recording, also arm the relevant Logic audio track. You can work in Logic’s timeline or close the plug-in editor; the video session stays active.
6. Stop Logic to finalize the take. CamOrder automatically disarms the lanes when Stop is confirmed. Arm the desired lanes again for the next take. **Disarm** cancels pre-roll; **Stop Take** finalizes and disarms.

The installer is unsigned and not notarized. If macOS blocks it after you try to open it, follow [Apple’s instructions](https://support.apple.com/102445) in **System Settings → Privacy & Security** only if you trust the download. The native installer replaces the previous plug-in bundle; the ZIP’s command installer separately retains its existing backup behavior. Project folders and recordings are not part of either installation.

Arming buffers video before transport starts so the beginning of the take can be retained. Different assigned inputs record simultaneously. Lanes sharing one camera use one capture connection and movie file, with a separate timeline region for each armed lane. Missing transport callbacks do not cut off capture or let the CamOrder playhead run indefinitely: the displayed clock holds its last confirmed position. If Logic stops without sending a stop report, use **Stop Take**. A backward transport move or manual Stop Take disarms the lane. Automatic repeated cycle takes are not supported.

## Lane inputs and multiple cameras

New projects start with three lanes; **+** adds more. Each lane starts at **Default**, using the source chosen above the Live Inputs panel. With one camera, every lane can use it without any extra setup. The first automatic choice is saved, so a reordered device list cannot silently change the input later.

Choose another source in a lane’s input menu to give it its own camera. The Live Inputs panel shows **one preview per distinct source**, labeled with the lanes using it. Assign the same source to several lanes to share its preview and connection. Choose **No input** for a lane used only for imported footage. Source assignments save with the project.

Arm any combination of lanes. Their different cameras follow the same Logic Play/Record/Stop clock and keep recording with the editor closed. A camera failure finalizes and disarms its affected lanes; the other cameras continue. Each lane keeps its own video-sync adjustment. Main Stage and export combine visible regions using their assigned output layers. Numbered layers override lane position; without assignments, the top lane remains in front. Make foreground video smaller or move it aside to reveal the layers behind it.

A lane armed during playback starts at the current position. Disarming one shared-camera lane fixes that region’s end while the other lanes keep recording. Its region shows **finishing** until the shared movie is finalized; stop the other lanes sharing that input before rearming that particular lane. Camera selection and capture-region changes are locked while affected lanes are armed or finishing.

Use a preview tile’s **…** menu to restart/stop its preview. Screen region has visible **Show region**, **Apply** and **Hide** buttons. Window has **Choose window…**. Multiple previews wrap into a scrollable grid. Hiding Live Inputs affects the layout; it does not stop armed capture.

There is no fixed three-input cap. Four simultaneous synthetic inputs and four independent helper processes were verified. The number of physical cameras and sustainable frame rate depend on macOS, camera availability, USB bandwidth and encoding load; this build has not been tested with four physical cameras on this Mac.

The plug-in has one transport: the red button and **R** forward Logic’s R key command, and **Space** and Play control Logic. There is no Logic/Edit switch. When stopped, click the CamOrder timeline or a marker to preview that frame; starting Logic or receiving a changed host position resumes following Logic. Closing and reopening the editor also returns to the host clock. Restoring a saved AU project reconnects the video session before the editor opens. Text entry is unaffected by transport shortcuts. Removing the plug-in ends its session.

## A simpler, adjustable workspace

- Dark graphite UI with teal accents. **Inspector**, **Media**, and **Sync** open only when requested; click outside to hide them.
- Resize freely using the window edge or the small **bottom-right resize grip**. Minimum editor content size is **720 × 360**. There are no fixed layout presets.
- Drag the divider between **Main Stage and Live Inputs** to change their widths. Drag the horizontal divider above the timeline to change monitor/timeline heights. **View** can hide Live Inputs or the timeline and reset panel sizes.
- **View → Controls at bottom** puts Main Stage first, then the timeline, editing tools, transport and project controls. The preference survives reopening the editor.
- Main Stage remains available in compact layouts. Each lane’s input selector stays with its name and Arm controls. Lane headers and their Arm buttons scroll together with the timeline.
- The four small exterior canvas corners adjust width and height independently. Drag inside the video to position it; use pinch or Inspector zoom for framing. Inspector also provides rotation and canvas dimensions.
- Main Stage and export share **Output Layer** ordering. Selecting a region chooses what to edit; assigning a number determines where it appears in the final composition. Smaller or moved foreground videos reveal the layers behind them. Muted lanes and disabled regions stay hidden; empty gaps stay black.
- Press Return or click outside a lane name to commit it and release keyboard focus; Escape cancels the current rename.
- Delete and Undo/Redo work while a lane is armed or recording. Undo preserves current arming and capture connections, so it does not silently rearm a finished lane.
- During Play/Record, the timeline keeps the playhead near the center, clamped at the left edge near project start. Scrolling gives you two seconds to look elsewhere before following resumes. Pinch the trackpad over the timeline to zoom around the pointer.
- Splits and trims retain the correct source frames and framing animation. Original source movies are never rewritten.

Window behavior and screenshots were checked in an owned native AU host. Logic adds its own surrounding window controls and may impose additional sizing behavior.

## Save and edit regions

**Save** is beside Export, and **⌘S** saves the CamOrder project while its editor is active. The button briefly confirms **Saved**. Edits continue to save automatically. Saving the CamOrder project does not replace saving the Logic project.

Select a region, or **Shift-click** to add/remove regions in a group. **⌘A** selects all regions when the editor has focus. Drag a selected region to move the group; drag its **left or right edge grip** to trim or restore available footage. Both grips have a larger target and a left/right resize cursor; narrow regions show the grips just outside their ends. The left edge changes the source in-point while keeping the right edge fixed. The right edge changes the end and stops at the source movie’s limit. Drag the middle to move the region. The same time adjustment applies to every selected region, constrained by the tightest source or timeline limit so the cameras remain aligned. Each group gesture is one Undo step. Right-click a region for **Snap Left/Right Edge to Grid**.

To move footage between lanes, **drag the middle of a region up or down**, or right-click it and choose **Move to Lane**. Vertical-only moves keep the visible start exactly where it was, even between lanes with different sync offsets. Moving sideways at the same time follows the normal snap setting. A selected group keeps its relative lane spacing and stops at the first/last lane; the menu disables destinations that cannot fit the whole group. The menu also reaches lanes outside the visible viewport. Moving footage retains trims, animation and explicit output layers; automatic layering follows the destination lane. A lane's camera assignment is unchanged.

Right-click **Return to Recorded Position** to put the selected source frames back at the time they were recorded. This preserves cuts, edge trims, framing, automation and the current lane, and still applies the current lane/project sync offsets. It bypasses beat snapping and supports Undo/Redo, including while armed. The recording anchor survives moves, splits, trims, copy/paste and save/reopen. It is saved for **new recordings made with this build or later**. Older recordings and imported movies without that anchor show the action disabled; their original positions cannot be reconstructed reliably after editing.

To repeat edited regions:

1. Select one or more regions and click **Copy** above the timeline, press **⌘C**, or use the region’s right-click menu.
2. Move to the destination in Logic, or click the CamOrder ruler/empty lane while stopped.
3. Click **Paste**, press **⌘V**, or use **Paste at Playhead** in the context menu. Keyboard/toolbar Paste preserves the copied regions’ original lanes and relative timing. To choose another lane, right-click that lane and use **Paste Region Here at Playhead**.

The earliest copied region’s visible left edge lands at the playhead, accounting for each destination lane’s sync offset; other regions retain their relative timing. Source trim, duration, framing, camera calibration, output layer and automation are retained; the original region remains unchanged. Copy once and paste repeatedly. Paste supports Undo/Redo, including while armed, and shares the existing media file. Within the same lane and layer, the last pasted overlapping region takes precedence unless another region has a newer explicit layer assignment. The region clipboard belongs to the current CamOrder project/session; it is not a system movie-file clipboard and does not transfer footage between projects. Normal text copy/paste still works while editing a text field. **T** and the scissors button split all selected regions that cross the playhead; plain **C** remains an alias. With Snap enabled, the cut uses the nearest grid point. The right-hand pieces stay selected for the next edit; Delete removes the selected group and Undo restores it in one step.

## Beat grid and snapping

The timeline toolbar always shows **Snap**, grid division and current BPM, even with the Inspector hidden. In Logic, the AU’s reported **tempo and quarter-note beat position** automatically determine the grid; no manual “use detected tempo” step is needed. Snap defaults on. Choose a beat or a subdivision for tighter cuts. The **1 bar** option currently means four quarter-note beats.

Cuts, region moves, both trim edges and stopped timeline scrubbing use the same grid in visible timeline coordinates, including lane/project offsets. A group uses the region you drag as its snap anchor and preserves the other regions’ relative timing. Source limits take precedence at a footage boundary. Turn **Snap** off for free editing, or hold **Option** while dragging to bypass it temporarily. Pasting lands at the current playhead.

The host reports its current tempo, not a full project tempo map. For a project with tempo changes, position Logic in the section you are editing first; the grid updates to that tempo and beat phase. This does not time-stretch footage or automatically move existing edits when the tempo changes. The last detected grid is retained while Logic is stopped and saved with the project; a manual BPM is available before a host tempo is received.

## Foreground and background

While **paused**, select one or more regions and use **Output Layer** in the timeline toolbar, or press a number while the CamOrder editor has keyboard focus:

- **1 — Foreground**, cyan border and badge.
- **2 — Middle ground**, mint border and badge.
- **3 — Background**, purple border and badge.
- **4–9** — progressively farther behind the lower numbers.
- **0 — Automatic**, restoring lane order behind numbered layers.

A **yellow outline** means selected for editing; the numbered badge and colored border identify its output layer. The same ordering is used during Main Stage playback and in the exported movie. The stopped **View selected clip** preview described below temporarily brings your selection forward. If two overlapping regions share a number, the most recently assigned one is in front; equal assignments use lane order. Reassigning **1** brings the chosen region ahead of another layer-1 region. Within one lane and layer, remaining ties use the last overlapping region; different numbered layers can coexist within a lane.

Assignments survive splitting, trimming, copy/paste, Undo and save/reopen. Unassigned regions remain available behind numbered layers, so existing projects keep their previous appearance until you assign layers. A small foreground reveals the videos behind it. Number and editing shortcuts do not apply while you are typing in a text field.

## Live multicamera editing

Record your cameras first, stop, and leave the video lanes disarmed. Start Logic playback, click inside the CamOrder editor, and press **1–9** to choose the corresponding numbered lane. Each press splits every region crossing the cut position and puts the chosen lane's right-hand region in the foreground. Existing foreground regions behind it move to layer 2; framing and smaller picture-in-picture shots are retained. Earlier footage and later existing edit boundaries stay intact. **⌘Z** undoes one switch, including all its cuts and layer changes.

Use **Live cuts: Snap / Free** in the timeline toolbar:

- **Free** cuts at the current playhead time.
- **Snap** cuts at the nearest point on the current beat/subdivision grid, independently of the ordinary editing Snap toggle. A nearest grid point ahead of the playhead takes effect when playback reaches it; a point behind the playhead makes the cut there.

The first nine lanes are numbered from top to bottom. Empty or muted camera choices leave the edit intact and show a message. Live switching is for recorded footage; finish and disarm active captures first. While paused, numbers keep assigning output layers to the selection instead. **0** restores automatic layering only while paused. Keep keyboard focus in CamOrder and finish any text entry first; these are editor shortcuts, not global Logic key commands.

## Reorder camera lanes

Drag the **grip and number beside a lane name** up or down to another lane; the pointer can be over the header or the region area. The insertion line indicates whether the lane will move above or below that header. You can cross several lanes in one drag. Hold near the top/bottom of the lane viewport to scroll, or press Escape to cancel. Release to commit one undoable move. The header's right-click menu also provides **Move lane up/down**. Lane order saves with the project and supports Undo; the lane's regions, inputs, offsets and automation move together without changing their times. Live-switch numbers follow the new order. Explicit output layers remain assigned; automatic layers follow lane order.

## Animate video framing

Select a region, stop at the first desired position, set its framing, and press **M** or **Marker** in the timeline toolbar. Move the playhead to another position, add another marker, then change zoom, position or rotation. Once a clip has markers, framing edits update or add the pose at the current playhead; they no longer move every marker together. Each drag is one Undo step. Click a flag in the timeline to preview and edit that point while stopped. Animation plays in Main Stage and export, including after splits and trims.

While stopped, **View selected clip** in Main Stage brings the selected region forward so you can frame it even underneath another video. This is a preview at times within that region, including muted or disabled selections; it does not change output layers or exports. Scrub with the ruler or click a marker to keep the selection while positioning automation. Turn **View selected clip** off to inspect the final composition. Starting playback always shows the actual output order. Click empty timeline space, the black margin outside the canvas, or the deselect icon beside **View selected clip** to clear the selection.

## Automatic zoom and pan

Select a region, or Shift-click several, then click the **Motion** button (wand icon) in the timeline toolbar. Right-click **Motion…** opens the same panel. Choose zoom **In/Out** and/or a pan direction, including diagonals. **Subtle**, **Gentle** and **Bold** set starting amounts; the Zoom and Travel sliders let you refine them. Travel is a percentage of the canvas width/height, and pan describes the direction the camera looks (the image moves the opposite way).

Click or drag on the still preview to choose a zoom focal point, or press **Center**. The play button previews a four-second loop of the proposed framing on a still image; it does not start Logic. Each selected region receives a full move across its own current trimmed length. The preview shows the active region; applying also uses each other selected video's dimensions.

**Keep edges covered**, on by default, adds enough crop to fill the project's canvas throughout the move, including rotated framing and portrait sources. It can require substantial crop when source and canvas proportions differ. Turn it off for smaller overlay videos. This covers the source's outer edges; black bars already baked into a recording remain part of that video. Changing the canvas, extending a region or editing its markers afterward can require applying motion again.

Choose **Add to existing** to combine with current automation; applying again can stack another move. **Replace** clears its old markers and starts from the region's current opening framing. **Apply motion** creates ordinary editable automation markers. One Undo restores the entire selection, even across lanes. Original media, trimmed source positions, timeline positions, layering and sync offsets are unchanged; generated animation plays through the normal Main Stage/export path. Combined curves use sampled linear markers to avoid pausing at every intermediate point.

## Export progress and location

The Export button shows a progress bar and **percentage** while rendering, then an **Export finished** notice. Preparation begins at 0%; the percentage advances during encoding. The **folder icon beside Export** reveals the last successful movie in Finder, alongside its Logic placement note. The editor no longer opens Finder automatically. Progress and the finished-file link belong to the AU session and survive closing/reopening or repositioning the editor controls. A failed export reports its error and never replaces the link to the previous successful movie.

Main Stage reuses a source's decoder across region cuts and output-layer changes. Thumbnail generation is limited to two simultaneous jobs, cancels obsolete jobs after edits, and uses a bounded cache. Camera recording settings, playback frame rate, thumbnail resolution and export quality are unchanged.

## Video sync offsets

Open **Sync** for the whole-project offset and each lane’s offset. The sliders icon beside a lane opens its own adjustment. All new controls start at **0 ms**, including when opening an older project.

- **Negative** moves video earlier; **positive** moves it later.
- Project and lane values **add together**. For example, project −40 ms plus lane +10 ms produces −30 ms for that lane.
- Enter a value and press Return or **Apply**, use the 1 ms stepper, or choose **Reset**.
- The displayed regions, Main Stage playback and exported movie use the adjusted positions. You can change offsets after recording: existing takes update immediately, and the next export includes the correction. Source recordings and underlying edit points stay unchanged. Adjustments save with the CamOrder project and support Undo.
- **Edited timeline** export stays anchored to the edited start/end before sync adjustments. For example, changing the project offset to −82 ms advances picture within the exported movie; import it at the same noted start in Logic. Different lanes use their own combined lane + project offsets. Negative shifts can trim picture at the beginning and leave black at the end; positive shifts can leave leading black and clip the end. Use **Custom range** to include extra time when needed.
- The panel shows a 1/64-note equivalent at the project tempo. At 88 BPM it is about **42.61 ms**. No correction is applied automatically.

The controls allow ±5000 ms each. Video shifted before project zero is clipped at zero. Imported master audio stays on its own project clock; camera audio, if explicitly included in export, travels with its video. Existing projects retain any previously saved legacy clip timing adjustments in addition to these new controls.

## Sync calculator

Open **Sync → Calculator**. Milliseconds are the default: enter `01:00:36.240` or the shorter `00:36.240`.

1. Export with your current sync settings and put the movie at its noted start in Logic. Pause at a moment where both Logic’s clock and the same clock recorded inside the video are readable.
2. Enter **Actual Logic time** and **Clock visible inside the video**, using the same display format and SMPTE view offset for both. Use the clock shown *inside* the picture, not the movie player’s elapsed-time counter.
3. Choose **Whole project** or the lane to adjust, then **Calculate**. A smaller clock reading inside the video means it is late: the suggested correction is negative, moving video earlier.
4. Review the correction and the proposed offset. **Apply offset** adds the measured correction to the chosen current setting. For example, a −80 ms residual correction changes an existing −82 ms setting to −162 ms. Other lane settings stay unchanged.
5. Re-export and import at the same Logic position, then check again. Original recordings stay intact; existing movie files do not change until re-exported. Undo reverses Apply.

Entries and results survive dismissing the Sync popover or closing/reopening the editor within the same AU session. The same calculated result cannot be applied twice. Changed edits/offsets make the result stale; calculate again using a fresh matching export. Apply is unavailable while armed/recording and when the proposed setting exceeds ±5000 ms.

The format selector also supports SMPTE frames, frames with 80 subframes per frame, seconds plus samples, frames plus samples, and frames plus milliseconds. Frame formats require the **Logic timecode frame rate**; sample formats also require Logic’s project sample rate. Drop-frame rates are explicit. For frames with a fractional field, separate the fields (for example, `00:36:16.36` for 16 frames and 36 bits). The calculator shows how each reading was interpreted and rejects invalid values instead of guessing what a long string of digits means. [Apple’s display-format guide](https://support.apple.com/guide/logicpro/customize-the-control-bar-lgcp5bdd6d9d/mac) explains Logic’s options.

A single measurement estimates a constant offset. If the mismatch changes at different parts of the recording, one offset cannot correct that drift. Millisecond entry does not remove the exported movie’s frame-rate granularity.

## Inputs

- Built-in cameras and USB webcams exposed by macOS.
- iPhone Continuity Camera over USB or wireless. Enable Continuity Camera, use a trusted connection, and refresh the input list after connecting.
- Wired iPhone/iPad screen capture when macOS exposes the device as a capture input. For this setup, leave the phone/tablet **disabled as an audio device in Audio MIDI Setup** on the Mac: click **Disable** if enabled; seeing **Enable** means it is already disabled. Refresh Live Inputs afterward. See the [USB screen-camera setup](../docs/PHONE_CAMERA.md#set-up-once). Connecting a cable alone does not provide an iPhone camera feed; Continuity Camera supplies that.
- **Main display** records the main screen. **Screen region (main display)** captures a rectangle: click **Show region**, move/resize the frame on the main display, then **Apply**. **Hide** removes the outline without stopping capture. Whole secondary-display capture is not included.
- **Window (choose…)**, on **macOS 14+**, captures one individual window using ScreenCaptureKit. Click **Choose window…**, select the desired window in the macOS picker, and confirm sharing. Wait for its Live Inputs image, then arm and record normally. Window audio is not captured. Multiple lanes can share this window input; this release supports one selected window per CamOrder instance alongside other camera/screen inputs.

A window selection lasts for the capture-helper session. Saved projects retain the Window input assignment, but require **Choose window…** again after reopening Logic. Window selection is locked while its lanes are armed or finishing. Closing/minimizing the window or stopping sharing can end capture; restore it and choose it again. Resizing the source keeps the capture canvas fixed at its initial pixel dimensions and fits the window within it, preserving aspect ratio. Static windows keep recording for the full take.

**Live Inputs** shows the chosen camera, screen or window. **Main Stage** shows recorded regions at the timeline playhead; an empty timeline or a gap there is black. A live input by itself does not put a recorded region on Main Stage.

### Screen permission troubleshooting

For Main display and Screen region, enable **CamOrder Capture** under **System Settings → Privacy & Security → Screen & System Audio Recording** (Screen Recording on older macOS). Enable screen access, not just system audio, and fully quit/reopen Logic when macOS requests it. Window capture uses the macOS picker to approve the specific window.

These builds are ad-hoc signed. Updating the capture helper can invalidate an older screen-permission grant even if its switch still looks enabled. First save and quit Logic, remove the stale CamOrder Capture entry with the settings panel’s minus button, then reopen Logic and select Main display to request access for the installed helper. If the entry cannot be removed, the supported Terminal command `tccutil reset ScreenCapture com.santismo.CamOrderStudio.Capture` resets only this helper’s screen grant; reopen Logic and approve the new request afterward. This does not reset camera or microphone permissions.

Captured takes are video-only: they do not record the microphone or Logic’s mix. Import a bounced mix through **Media / Master Audio** if you want it included in the exported file. Imported movies can retain their own audio according to the Inspector’s export audio setting.

## Export the edited movie

1. Click **Export**. The save panel now includes an explicit **Range** choice:
   - **Edited timeline**: the first enabled, unmuted edited region through the final edited end, before lane/project sync offsets. Offsets move picture inside this fixed window.
   - **Selected region range**: the selected region’s current edited start and end, before sync offsets, with the same layered composition as Main Stage.
   - **From playhead**: the current playhead through the final visible region.
   - **From project start**: include time from zero.
   - **Custom range**: enter exact start/end seconds.
2. Check the displayed start, end and movie duration. The range stays fixed when only sync offsets change. MOV and MP4 exports read the current source trim; removed footage is not restored at the front. Exported master audio is restricted to the chosen range.
3. The movie is accompanied by a `.logic-placement.txt` note containing its **fixed export start**, unaffected by changes to sync offsets for the same edited range. Use the project menu’s **Show last export** to reveal it.
4. In Logic, open the movie through **File → Movie → Open Movie**. Place Logic’s playhead at the start given in the note and use **Move Movie Region to Playhead**, or set Movie Start in Project Settings → Movie. For an absolute SMPTE position, add the Logic project’s SMPTE origin to the note’s seconds.

Movie import and placement are manual; this Audio Unit does not change Logic’s movie track. Export defaults to a silent movie for use with Logic’s existing audio. Existing exports survive a failed render, and source-media destinations are rejected.

## Transport and silent playback

**The current tradeoff:** CamOrder follows Logic while Logic supplies Audio Unit timing. In testing with Logic, playback followed while audio was passing through Stereo Out, but could freeze in silent or empty sections when Logic stopped processing the plug-in. Keeping the editor open does not guarantee updates. CamOrder holds its last confirmed position instead of guessing how far Logic has moved, then follows again when timing resumes. This is separate from camera delay; changing a lane/project millisecond offset will not fix a frozen playhead.

For music-based editing, use the normal Stereo Out setup while audio plays. For a silent movie or footage-only project, choose the optional MIDI connection below, or try the [quiet-audio workaround](#video-only-editing-without-midi). Leave CamOrder lanes **disarmed** when reviewing existing footage; arming is for capturing a new take, not a playback setting.

## Optional transport fallback

**MTC (MIDI Time Code)** supplies the running time position. **MMC (MIDI Machine Control)** supplies transport commands such as Play, Stop and Locate. Enable both for the Logic Link setup. They work together as a timing fallback, rather than separate editing modes. No timecode-audio track is needed.

1. Open a CamOrder project and choose **View → Optional transport fallback…**.
2. In Logic, open **File → Project Settings → Synchronization → MIDI**. Set an unused **Destination** row to **CamOrder Logic Link**. If it is missing, leave CamOrder loaded and reopen the settings.
3. Check **MTC** and **MMC** on that row, and enable **Transmit MIDI Machine Control (MMC)**. MIDI Clock is a different protocol and is not required for this connection. Keep Logic in **Internal Sync**; Logic sends timing and CamOrder follows it. See [Apple’s MIDI synchronization settings](https://support.apple.com/en-ae/guide/logicpro/lgcp72142361/10.7/mac/11.0).
4. In CamOrder’s fallback panel, match **Logic project start** to Logic’s bar-1 SMPTE hour in **Synchronization → General**, commonly **01:00:00:00**. This aligns project origins; it is not the camera’s millisecond sync adjustment.
5. Save both projects. With all video lanes disarmed, test Play and Stop across an empty section, start from another position, then repeat with the editor closed and reopened. Confirm CamOrder follows before using this setup for a take.

**Fresh AU timing has priority.** CamOrder automatically uses Logic Link when AU timing becomes stale; existing MIDI routing does not override fresh AU positions. The connection can supply timing without audio reaching CamOrder. The automated MIDI fallback test passes, but this specific setup still needs checking in your Logic session.

Stopped cursor movement can only be followed when Logic sends a position report. The MIDI path supports 24, 25, 29.97 drop-frame and 30 fps, with whole-hour project origins. It is not sample-accurate video lock. Camera capture delay still uses the separate [Sync Calculator](#sync-calculator) and lane/project offsets.

## Video-only editing without MIDI

A continuous, very quiet **nonzero audio signal** may keep Logic processing Stereo Out while you edit a silent movie. This is a workaround to try, **not a verified fix or a guaranteed dB threshold**. Ordinary audio playback has been confirmed; an almost inaudible signal has not. Audibility and Logic’s processing behavior depend on the source, routing and session.

1. Add a dedicated Logic audio track named **CamOrder playback guide — exclude from final mix**, routed to the Stereo Out that contains CamOrder.
2. Put a continuous tone or noise recording on it and loop/extend it across the entire editing range, including gaps before and after your video. A file containing digital silence is not a substitute. Lower the track to a very quiet level, keeping its fader above **−∞**.
3. Keep the track enabled and unmuted, and keep CamOrder active. Avoid gaps, gates or other processing that removes the signal before CamOrder. Muting, soloing it out or routing it elsewhere can defeat the workaround.
4. Leave video lanes disarmed and test Logic Play/Stop through the longest otherwise silent section, including after closing/reopening the editor. If CamOrder still freezes, do not assume a quieter signal will help; use the optional MTC/MMC connection instead.

Alternatively, **Utility → Test Oscillator** on the dedicated track can provide a continuous signal. Turn down your monitoring before inserting it: it starts generating immediately. Lower its **Level** before restoring monitoring, then perform the same playback check. See [Apple’s Test Oscillator guide](https://support.apple.com/en-ca/guide/logicpro/lgcef2d8c9eb/12.2/mac/15.6).

**Keep the guide signal out of the finished audio.** It is still audio even when you cannot hear it, and may be included in a Logic bounce. Disable/remove it before making a final audio master. CamOrder’s movie export defaults to video-only and does not need Logic’s transport running, so the guide signal is unnecessary for export. If you import a bounced master into CamOrder, use one made without the guide signal.

## Performance changes

Live frames now update a native image layer directly. Timeline geometry and filmstrips no longer rebuild with every playhead tick; moving cursors and clocks update separately. Playback seeks are serialized, and resuming the decoder uses the requested host-clock anchor so seek completion does not leave a persistent playback delay.

Earlier-build measurements: the synthetic 30 fps playback check delivered **51 decoded frames over 1.7 seconds**. A 12-second capture test delivered **358 preview frames**, with no recording warnings. These checks do not measure camera latency or end-to-end synchronization with Logic’s audio; use a visible/audio cue to choose your own offset for the actual camera and session.

## Verification

The 0.9.2 baseline passed **83 Swift tests**, including actual MOV/MP4 rendering of automatic motion, independent sync offsets, multi-layer output, capture, editing, Undo/Redo and native lane drags with autoscroll and cancellation. The native session harness also verifies **playback with every lane disarmed**, paused-preview handoff, editor closure, R/Space forwarding, automatic disarming, restoration and simultaneous cameras.

AU 0.9.2 keeps its transport scheduling activity while a video project is open, so ordinary playback receives the same scheduling protection as armed recording. This activity survives closing the editor and ends when the project/session closes. It does not arm a lane or record video. Transport still uses Logic's positions; missing callbacks freeze the display instead of inventing motion. Playback diagnostics now include callback state and timer gaps even when disarmed.

The **Motion** label is beside the timeline editing buttons and also appears in the region's right-click menu. **View selected clip** (previously Edit selection) changes only the stopped preview, to expose a selected clip under another layer; it is not a transport mode and does not change the export. It makes no visible difference when that clip is already on top.

See the [0.11.0 verification record](../docs/VERIFICATION-0.11.0.md) (or `VERIFICATION.md` in the ZIP) for this build’s test record and limits. The [0.10.3 record](../docs/VERIFICATION-0.10.3.md) documents the confirmed USB-screen recording fix retained here. The [0.9.2 record](../docs/VERIFICATION-0.9.2.md) documents the prior playback and lane fixes retained in this build. It is an **Intel/macOS 13+ development build**, with a locally signed AU and an unsigned, non-notarized installer. The Logic follow-up confirmed playback while audio passes through Stereo Out, with the silent-section limitation described above. Automated host tests do not establish continuous transport in silent Logic sessions, and the quiet-audio workaround remains unverified.

An old cut made before the 0.2.5 fixes may already contain an incorrect saved source start. The app cannot safely infer its intended content; redo an affected old cut from the original take. Original media remains intact.

## Input crops in 0.11.0

In **Live Inputs**, open a camera’s **…** menu and choose **Crop input…**. A larger, resizable window shows the full feed. Drag any edge or corner to remove borders, or drag inside the rectangle to move it. The Left, Top, Right, and Bottom sliders provide finer adjustment. Choose **Apply crop** to save, **Cancel** to leave the input unchanged, or **Reset to full frame** followed by Apply to remove a crop.

Each physical input has one crop saved in the current project. Lanes sharing that input share its crop. Disarm those lanes and wait for their recording to finish before changing it; other idle cameras can still be adjusted. Crops also apply to Mac screen and window inputs, separately from the existing screen-region selector.

The selected rectangle is written into **new recording files** at the remaining source resolution. Removed borders cannot return when you shrink, move, zoom, or rotate that clip on Main Stage, prepare a playback preview, or export a movie. Existing clips are unchanged. Cropping is rectangular, with no fixed aspect ratio, and encoder dimensions round inward to even pixels. Keep the device orientation fixed during a take; if the input dimensions change during a cropped recording, CamOrder finalizes the usable footage and reports the change.

## Recording-start fix in 0.10.3

Logic can initially report an incorrect timeline position when Play/Record begins, even with a valid host-clock timestamp. CamOrder now waits for 50 ms of consistent reports before placing a take and corrects the starting anchor if the first position was transient. Video pre-roll continues during that check. This addresses the additional failure found after 0.10.2.

If recorded video cannot be placed on a lane, CamOrder keeps the file and shows recovery instructions. Open **Media → Video Folder** to find it, then use **Import Video**. A placement error no longer discards usable recorded footage.

## Render-clock check in 0.10.2

A fresh Play/Record callback can contain a render timestamp left over from before playback. Earlier builds could place an armed take far ahead of the playhead and discard it as an empty region at Stop. The AU now uses the callback’s current host clock when a render timestamp is more than two seconds away; ordinary precise render timestamps are preserved. Lanes still record on Play or Record and save/disarm on Stop.

## Preview quality

The **Preview** menu under Main Stage controls display quality in the AU. **Balanced** is the default and the choice is remembered across Logic sessions. This is a preview preference, not a project/export setting.

| Mode | Live Inputs maximum | Prepared playback maximum |
| --- | --- | --- |
| Full | 960 × 640 (previous live-preview limit) | Original file |
| Balanced | 640 × 480 | 1280 × 720 H.264 preview copy |
| Light | 320 × 240 | 640 × 480 H.264 preview copy |

Aspect ratio is preserved, so 16:9 live frames are 960 × 540, 640 × 360, and 320 × 180 respectively. The existing live preview cadence (about 30 fps for a 30 fps source) is retained. Changing modes updates all camera helpers without restarting a capture session. Preview quality does not downscale the recording. An optional input crop removes only the selected borders at the source resolution.

For lighter **recorded playback**, choose Balanced or Light. New and unprepared video files prepare **automatically after one idle second**, while Main Stage is visible, playback is stopped, every video lane is disarmed, and no take or movie export is active. Files are processed one at a time. Ready copies are reused; small originals need no conversion. Full uses original files and never starts preparation.

Starting playback, arming, recording, exporting, or closing Main Stage cancels unfinished conversion. When you return to an idle state or reopen the view, pending clips resume automatically. Completed copies are kept. Existing ready clips remain available as new media joins the queue. The preparation list resolves media paths only when project media changes.

**Prepare now** starts immediately while idle, or retries failed files. **Pause previews** pauses the current idle period; Prepare now or the next activity/idle cycle resumes it. Failed files fall back to originals and are not repeatedly retried in the background. The status reports preparation, waiting, readiness and failures.

These copies change neither project media paths nor the files used for final movie export. Source trims, sync offsets, portrait orientation, framing and motion continue to use the same source time. Preparation adds encoding work while idle, but is cancelled when the app reports playback or capture activity.

Preview copies use disk space in `~/Library/Caches/com.santismo.CamOrderStudio/Preview-v1/`. They are disposable: quit Logic before deleting that folder in Finder to recover the space, then prepare again if wanted. Changes to a source's path, size or modification date invalidate its old cache entry. The cache is local to this Mac and is not included in the project.

Three simultaneous full-quality recordings still require three encoders. These settings reduce preview work; they do not guarantee a particular overall CPU reduction or cure missing Logic transport callbacks. The user reports that enabling Logic's metronome improves playback on their setup; this is recorded as a practical observation, not a general transport fix.

Version 0.11.0 includes an updated capture helper for input cropping. macOS may ask for Camera or Screen Recording access again for CamOrder Capture; allow the requested access when using that input. The installer backs up the previous component and does not close Logic. The 0.10.3 recording-start and recovery fixes remain in place.

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
