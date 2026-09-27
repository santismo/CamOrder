import Foundation
import CamOrderStudioCore

@MainActor
func runEditingRegression() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CamOrder-editing-" + UUID().uuidString + ".camorderstudio")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = ProjectStore()
    store.document = try ProjectDocument.create(at: folder, project: .empty(name: "Editing regression"))
    let media = MediaAsset(kind: .video, displayName: "Take", relativePath: "media/video/test.mov", durationSeconds: 20)
    let top = VideoClip(clipId: "top", mediaAssetId: media.id, videoFile: media.relativePath, armedLaneId: "top", logicStartTimecode: .from(seconds: 4, frameRate: .fps30), logicStartSeconds: 4, durationSeconds: 10, frameRate: .fps30, trimInSeconds: 3, trimOutSeconds: 20)
    var bottom = top; bottom.id = UUID().uuidString; bottom.clipId = "bottom"; bottom.armedLaneId = "bottom"
    store.project.media = [media]
    store.project.timeline.lanes = [VideoLane(id: "top", name: "Top", clips: [top]), VideoLane(id: "bottom", name: "Bottom", clips: [bottom])]
    store.selectedClipId = bottom.id
    require(store.playbackClip(at: 6)?.id == top.id, "Selection cannot override the top visible lane")
    store.beginClipFramingEdit(top.id)
    for step in 1...60 {
        store.updateClipFraming(top.id, zoom: 1 + Double(step) / 60, offsetX: Double(step) / 60, offsetY: -0.25, trackUndo: false, origin: .canvas)
    }
    require(store.clip(id: top.id)?.framing?.zoom == 2 && store.clip(id: top.id)?.framing?.offsetX == 1)
    require(store.clip(id: bottom.id)?.framing == nil, "A live framing edit targets its captured clip ID, not selection")
    store.saveProject()
    let reopened = try ProjectDocument.open(at: folder)
    require(reopened.project.timeline.lanes[0].clips[0].framing == store.clip(id: top.id)?.framing, "Framing survives save/reopen")
    store.undoProjectChange()
    require(store.clip(id: top.id)?.framing == nil, "One gesture is one undo step")
    store.redoProjectChange()
    require(store.clip(id: top.id)?.framing?.zoom == 2)
    store.selectedClipId = top.id
    store.cutSelectedClip(at: 8)
    let right = store.selectedClip()!
    require(right.trimInSeconds == 7 && right.timelineStartSeconds == 8 && right.durationSeconds == 6)
    require(store.playbackClip(at: 8)?.id == right.id, "The exact cut boundary displays the right half")
    store.updateClipLeftEdge(right.id, startSeconds: 9)
    require(store.selectedClip()?.trimInSeconds == 8 && store.selectedClip()?.durationSeconds == 5)
    store.updateClipDuration(right.id, durationSeconds: 100)
    require(store.selectedClip()?.durationSeconds == 12, "The right edge cannot extend beyond source media")
    store.updateClipStart(right.id, startSeconds: 9.2)
    let sourceBeforeSnap = store.selectedClip()!.sourceSeconds(at: 10)
    store.snapSelectedClipStartToGrid()
    require(abs(store.selectedClip()!.sourceSeconds(at: 10) - sourceBeforeSnap) < 0.00001, "Grid left trim preserves source alignment")
    let restored = try ProjectDocument.open(at: folder)
    require(restored.project.timeline.lanes == store.project.timeline.lanes)
    let unchanged = store.project.timeline.lanes
    store.setVideoOffsetMS(-42.6)
    store.setVideoOffsetMS(12.6, laneID: "top")
    require(store.project.timeline.lanes[0].clips == unchanged[0].clips, "Sync adjustments do not rewrite edit points")
    let offsetSelection = ExportRangeSelection(project: store.project, selectedClip: store.selectedClip(), playhead: 10)
    offsetSelection.choice = .selected
    require(abs(offsetSelection.range!.startSeconds - store.selectedClip()!.timelineStartSeconds) < 0.00001)
    offsetSelection.choice = .custom; offsetSelection.startText = "11.25"; offsetSelection.endText = "12.5"
    require(offsetSelection.range!.durationSeconds == 1.25)
    let beforeCut = store.selectedClip()!
    store.cutSelectedClip(at: beforeCut.timelineStartSeconds - 0.03 + 1)
    require(abs(store.selectedClip()!.trimInSeconds - beforeCut.trimInSeconds - 1) < 0.00001, "Cuts use the offset-adjusted playhead")
    let offsetReopen = try ProjectDocument.open(at: folder)
    require(offsetReopen.project.sync.videoOffsetMS == -42.6 && offsetReopen.project.timeline.lanes[0].videoOffsetMS == 12.6)
    store.setVideoOffsetMS(0); store.setVideoOffsetMS(0, laneID: "top")
    print("PASS: non-destructive project/lane offsets save and reopen; export ranges use edited boundaries; cuts remain aligned after offsets")
    // Undo a deletion with live arming/pre-roll, without restoring stale arm state.
    store.armLane("top")
    store.startArmedBuffer(cameraDeviceId: "synthetic", laneID: "top")
    let bufferFile = store.armedBuffers["top"]?.relativeVideoFile
    let deleted = store.selectedClip()!
    store.deleteSelectedClip()
    require(store.clip(id: deleted.id) == nil)
    store.undoProjectChange()
    require(store.clip(id: deleted.id) == deleted && store.hasArmedLane, "Undo restores a deleted region without disarming")
    require(store.armedBuffers["top"]?.relativeVideoFile == bufferFile, "Undo keeps the active pre-roll connection")
    store.redoProjectChange(); require(store.clip(id: deleted.id) == nil && store.hasArmedLane)
    store.undoProjectChange(); store.discardArmedBuffer(laneID: "top"); store.unarmAllLanes()
    store.undoProjectChange()
    require(!store.hasArmedLane, "History never silently rearms a lane")
    store.redoProjectChange()
    store.selectedClipId = top.id
    var framingTime = 5.0
    store.framingPlayheadSeconds = { framingTime }
    store.insertAutomationMarker(at: 5)
    let firstPose = store.clip(id: top.id)!.automatedFraming(atTimelineSecond: 5)
    framingTime = 6
    store.insertAutomationMarker(at: 6)
    store.beginSelectedClipFramingEdit()
    store.updateSelectedClipFraming(offsetX: -0.5, trackUndo: false)
    store.endClipFramingEdit()
    let animated = store.clip(id: top.id)!
    require(animated.automatedFraming(atTimelineSecond: 5) == firstPose, "Editing a later marker must not move the first")
    require(animated.automatedFraming(atTimelineSecond: 6).offsetX == -0.5)
    require(animated.automatedFraming(atTimelineSecond: 5.5).offsetX != firstPose.offsetX, "The two markers animate position")
    let savedAnimation = try ProjectDocument.open(at: folder)
    require(savedAnimation.project.timeline.lanes[0].clips.first(where: { $0.id == top.id })!.automationMarkers == animated.automationMarkers)
    print("PASS: armed/pre-roll delete Undo/Redo preserves live state; marker edits animate independently and save/reopen")
    store.project.timeline.lanes[0].isMuted = true
    require(store.playbackClip(at: 10)?.id == bottom.id)
    store.project.timeline.lanes[1].clips[0].isEnabled = false
    require(store.playbackClip(at: 10) == nil, "Muted/disabled selection cannot leak onto the stage")
    print("PASS: top-lane playback ignores selection; framing stays on its target and survives save/reopen/undo; split, trim, grid alignment and source bounds")
}
