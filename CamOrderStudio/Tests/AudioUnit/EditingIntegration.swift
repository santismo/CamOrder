import Foundation
import CamOrderStudioCore

@MainActor
func runRegionClipboardRegression() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CamOrder-clipboard-" + UUID().uuidString + ".camorderstudio")
    let other = FileManager.default.temporaryDirectory.appendingPathComponent("CamOrder-other-" + UUID().uuidString + ".camorderstudio")
    defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: other) }
    let store = ProjectStore()
    store.document = try ProjectDocument.create(at: folder, project: .empty(name: "Clipboard regression"))
    let media = MediaAsset(kind: .video, displayName: "Take", relativePath: "media/video/test.mov", durationSeconds: 20)
    var source = VideoClip(clipId: "original", mediaAssetId: media.id, videoFile: media.relativePath, armedLaneId: "top", logicStartTimecode: .from(seconds: 4, frameRate: .fps30), logicStartSeconds: 4, durationSeconds: 5, frameRate: .fps30, trimInSeconds: 3, trimOutSeconds: 20, framing: ClipFraming(zoom: 1.2, offsetX: 0.2))
    source.playbackSyncOffsetSeconds = 0.04
    source.automationMarkers = [ClipAutomationMarker(timeSeconds: 1, framing: ClipFraming(zoom: 2)), ClipAutomationMarker(timeSeconds: 4, framing: ClipFraming(offsetX: -0.3))]
    store.project.media = [media]
    store.project.timeline.lanes = [VideoLane(id: "top", name: "Top", clips: [source]), VideoLane(id: "bottom", name: "Bottom")]
    store.setVideoOffsetMS(-82); store.setVideoOffsetMS(120, laneID: "top"); store.setVideoOffsetMS(-35, laneID: "bottom")
    store.selectedClipId = source.id
    store.copySelectedRegion()
    store.armLane("top")
    store.pasteRegion(at: 15)
    let first = store.selectedClip()!
    require(first.id != source.id && first.armedLaneId == "top" && store.hasArmedLane)
    require(abs(store.project.presentedClip(first).timelineStartSeconds - 15) < 0.000001)
    require(first.trimInSeconds == 3 && first.durationSeconds == 5 && first.framing == source.framing && first.playbackSyncOffsetSeconds == 0.04)
    require(first.automationMarkers.map(\.timeSeconds) == source.automationMarkers.map(\.timeSeconds) && first.automationMarkers[0].id != source.automationMarkers[0].id)
    require(store.project.media.count == 1 && store.clip(id: source.id) == source)
    store.undoProjectChange()
    require(store.clip(id: first.id) == nil && store.hasArmedLane, "Paste is one Undo step and preserves arming")
    store.redoProjectChange(); require(store.clip(id: first.id) == first)
    store.pasteRegion(at: 20, laneID: "bottom")
    let second = store.selectedClip()!
    require(second.armedLaneId == "bottom" && abs(store.project.presentedClip(second).timelineStartSeconds - 20) < 0.000001)
    store.pasteRegion(at: 0)
    let atZero = store.selectedClip()!
    require(abs(store.project.presentedClip(atZero).timelineStartSeconds) < 0.000001, "Positive lane offset must not push a paste away from zero")
    require(store.playbackClip(at: 0)?.id == atZero.id)
    store.pasteRegion(at: .nan)
    require(store.selectedClipId == atZero.id)
    // Copy/delete/paste retains the source reference after the last region is removed.
    for id in store.project.timeline.lanes.flatMap(\.clips).map(\.id) { store.deleteClip(id) }
    require(store.project.media.isEmpty && store.canPasteRegion)
    store.pasteRegion(at: 25)
    require(store.project.media == [media] && store.selectedClip()!.trimInSeconds == 3)
    require(store.saveProject())
    let reopened = try ProjectDocument.open(at: folder)
    require(reopened.project.timeline == store.project.timeline)
    store.document = try ProjectDocument.create(at: other, project: .empty())
    require(!store.canPasteRegion, "Clipboard media must not leak into a different project")
    store.pasteRegion(at: 10)
    require(store.project.timeline.lanes.flatMap(\.clips).isEmpty)
    print("PASS: region copy/paste preserves trims, framing and automation; independent offsets, zero position, repeated paste, armed Undo/Redo, deleted-source recovery, save/reopen and project isolation")
}

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
    store.setSnapToGrid(false) // This regression checks exact off-grid offset arithmetic.
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

@MainActor
func runMusicalRegionEditingRegression() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CamOrder-musical-" + UUID().uuidString + ".camorderstudio")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = ProjectStore()
    store.document = try ProjectDocument.create(at: folder, project: .empty())
    let media = MediaAsset(kind: .video, displayName: "Camera", relativePath: "camera.mov", durationSeconds: 20)
    store.project.media = [media]
    store.project.sync.videoOffsetMS = -82
    for index in 0..<3 {
        let laneID = store.project.timeline.lanes[index].id
        store.project.timeline.lanes[index].videoOffsetMS = Double(index * 30)
        let offset = store.project.videoOffsetSeconds(forLane: laneID)
        let clip = VideoClip(clipId: "Camera \(index + 1)", mediaAssetId: media.id, videoFile: media.relativePath, armedLaneId: laneID,
            logicStartTimecode: .from(seconds: 4, frameRate: .fps30), logicStartSeconds: 4,
            timelineStartSeconds: 4 - offset, durationSeconds: 8, frameRate: .fps30, trimInSeconds: Double(index + 1))
        store.project.timeline.lanes[index].clips = [clip]
    }
    let originals = store.project.timeline.lanes.flatMap(\.clips), ids = originals.map(\.id)
    store.selectRegion(ids[0]); store.selectRegion(ids[1], extending: true); store.selectRegion(ids[2], extending: true)
    require(store.selectedClipIDs.count == 3)
    store.selectRegion(ids[1], extending: true); require(store.selectedClipIDs.count == 2)
    store.selectRegion(ids[1], extending: true)
    store.selectRegion(ids[2], preserveGroup: true); require(store.selectedClipIDs.count == 3)
    store.receiveHostGrid(seconds: 10, beat: 12, tempo: 88)
    let expected = store.musicalGrid.snapped(8.15, division: .beat)
    store.cutSelectedClip(at: 8.15)
    require(store.selectedClipIDs.count == 3 && store.project.timeline.lanes.allSatisfy { $0.clips.count == 2 })
    for (index, clip) in store.selectedRegions().enumerated() {
        require(abs(store.project.presentedClip(clip).timelineStartSeconds - expected) < 1e-9)
        require(abs(clip.trimInSeconds - originals[index].trimInSeconds - (expected - 4)) < 1e-9)
    }
    store.undoProjectChange()
    require(store.project.timeline.lanes.flatMap(\.clips) == originals, "A three-camera cut is one Undo")
    store.setRegionSelection(Set(ids), primary: ids[0])
    store.setSelectedRegionLayer(3)
    store.selectRegion(ids[1]); store.setSelectedRegionLayer(2)
    store.selectRegion(ids[2]); store.setSelectedRegionLayer(1)
    require(store.playbackClip(at: 6)?.id == ids[2], "Lower lane assigned foreground must win")
    store.selectRegion(ids[0]); store.setSelectedRegionLayer(1)
    require(store.playbackClip(at: 6)?.id == ids[0])
    store.selectRegion(ids[2]); store.setSelectedRegionLayer(1)
    require(store.playbackClip(at: 6)?.id == ids[2], "Pressing 1 again promotes the chosen region ahead of another foreground")
    store.selectRegion(ids[0]); store.setSelectedRegionLayer(3)
    store.setRegionSelection(Set(ids), primary: ids[0])
    let beforeMove = store.project
    let delta = store.regionEditDelta(anchor: ids[0], kind: .move, translation: 0.6)
    store.previewRegionEdit(anchor: ids[0], kind: .move, translation: 0.6)
    require(store.project == beforeMove && store.regionEditPreview?.ids.count == 3)
    store.commitRegionEdit(anchor: ids[0], kind: .move, translation: 0.6)
    for clip in store.selectedRegions() { require(abs(store.project.presentedClip(clip).timelineStartSeconds - 4 - delta) < 1e-9) }
    store.undoProjectChange(); store.setRegionSelection(Set(ids), primary: ids[0])
    store.commitRegionEdit(anchor: ids[0], kind: .left, translation: -50, bypassSnap: true)
    for (index, clip) in store.selectedRegions().enumerated() {
        require(abs(store.project.presentedClip(clip).timelineStartSeconds - 3) < 1e-9)
        require(abs(clip.trimInSeconds - Double(index)) < 1e-9)
    }
    store.undoProjectChange(); store.setRegionSelection(Set(ids), primary: ids[0])
    store.commitRegionEdit(anchor: ids[0], kind: .right, translation: 50, bypassSnap: true)
    require(store.selectedRegions().allSatisfy { abs($0.durationSeconds - 17) < 1e-9 }, "Tightest camera source constrains every selected right edge")
    store.undoProjectChange(); store.setRegionSelection(Set(ids), primary: ids[0])
    store.setSnapToGrid(false)
    store.commitRegionEdit(anchor: ids[0], kind: .move, translation: 0.123)
    require(abs(store.project.presentedClip(store.selectedRegions()[0]).timelineStartSeconds - 4.123) < 1e-9)
    store.copySelectedRegion(); store.pasteRegion(at: 22)
    require(store.selectedRegions().count == 3 && store.selectedRegions().allSatisfy { abs(store.project.presentedClip($0).timelineStartSeconds - 22) < 1e-9 })
    require(store.selectedRegions().map(\.compositingLayer) == [3, 2, 1])
    store.armLane("lane_1")
    let deleted = store.selectedRegions()
    store.deleteSelectedClip(); require(store.project.timeline.lanes.flatMap(\.clips).count == 3)
    store.undoProjectChange()
    require(deleted.allSatisfy { store.clip(id: $0.id) == $0 } && store.hasArmedLane)
    let saved = try ProjectDocument.open(at: folder)
    require(saved.project.timeline == store.project.timeline)
    print("PASS: host-anchored 88 BPM snapping, Shift-selection, three-camera cuts, group moves/trims/source limits, layer ordering, grouped clipboard, armed Undo and save/reopen")
}

@MainActor
func runRegionPlacementRegression() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CamOrder-placement-" + UUID().uuidString + ".camorderstudio")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = ProjectStore()
    store.document = try ProjectDocument.create(at: folder, project: .empty())
    let lane = store.project.timeline.lanes[0].id, destination = store.project.timeline.lanes[1].id
    let source = VideoClip(clipId: "take", mediaAssetId: "source", videoFile: "test.mov", armedLaneId: lane,
        logicStartTimecode: .from(seconds: 10.123, frameRate: .fps30), logicStartSeconds: 10.123,
        durationSeconds: 8, frameRate: .fps30, trimInSeconds: 2, recordedSourceOriginSeconds: 8.123)
    store.project.media = [MediaAsset(id: "source", kind: .video, displayName: "Take", relativePath: "test.mov", durationSeconds: 20)]
    store.project.timeline.lanes[0].clips = [source]
    store.project.timeline.lanes[1].videoOffsetMS = 150
    store.project.sync.videoOffsetMS = -82
    store.selectedClipId = source.id
    store.armLane(lane)
    let before = store.project
    store.previewRegionEdit(anchor: source.id, kind: .move, translation: 0, laneDelta: 1)
    require(store.regionEditPreview?.laneDelta == 1 && store.regionEditPreview?.delta == 0 && store.project == before,
        "Vertical drag preview must leave the document and off-beat timing intact")
    store.commitRegionEdit(anchor: source.id, kind: .move, translation: 0, laneDelta: 1)
    require(store.regionEditPreview == nil && store.clip(id: source.id)?.armedLaneId == destination)
    require(abs(store.project.presentedClip(store.clip(id: source.id)!).timelineStartSeconds - before.presentedClip(source).timelineStartSeconds) < 1e-9)
    store.undoProjectChange(); require(store.project.timeline == before.timeline && store.hasArmedLane)
    store.redoProjectChange(); require(store.clip(id: source.id)?.armedLaneId == destination)
    store.moveRegions(anchor: source.id, toLaneID: lane)
    var returned = store.clip(id: source.id)!
    require(abs(returned.timelineStartSeconds - source.timelineStartSeconds) < 1e-9)
    returned.timelineStartSeconds = source.timelineStartSeconds
    require(returned == source, "Context move back preserves source state")
    store.commitRegionEdit(anchor: source.id, kind: .move, translation: 7, bypassSnap: true)
    store.copySelectedRegion(); store.pasteRegion(at: 30, laneID: destination)
    let copy = store.selectedClip()!
    require(copy.recordedSourceOriginSeconds == source.recordedSourceOriginSeconds)
    require(store.canReturnToRecordedPosition(anchor: copy.id))
    store.returnToRecordedPosition(anchor: copy.id)
    require(abs(store.clip(id: copy.id)!.timelineStartSeconds - 10.123) < 1e-9 && store.hasArmedLane)
    store.undoProjectChange(); require(store.clip(id: copy.id) == copy)
    store.redoProjectChange()
    let reopened = try ProjectDocument.open(at: folder)
    require(reopened.project.timeline == store.project.timeline && store.clip(id: copy.id)?.recordedSourceOriginSeconds == 8.123)
    print("PASS: cross-lane preview/commit/context moves preserve sync, armed Undo/Redo, recording origin through copy/paste, restore and save/reopen")
}
