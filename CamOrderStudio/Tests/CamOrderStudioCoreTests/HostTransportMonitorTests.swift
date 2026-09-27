import XCTest
@testable import CamOrderStudioCore

final class HostTransportMonitorTests: XCTestCase {
    func testSilentAudioTrackCallbackGapDoesNotStopVideo() {
        var monitor = HostTransportMonitor()
        XCTAssertEqual(monitor.update(seconds: 10, reportedPlaying: true, valid: true, reportTime: 100, now: 100).event, .started)
        for i in 1...1800 {
            let update = monitor.update(seconds: 10, reportedPlaying: true, valid: true, reportTime: 100, now: 100 + Double(i) / 60)
            XCTAssertTrue(update.playing)
            XCTAssertNotEqual(update.event, .stopped)
            XCTAssertEqual(update.seconds, 10, "Lost callbacks must never create a free-running playhead")
        }
        let resumed = monitor.update(seconds: 40.1, reportedPlaying: true, valid: true, reportTime: 130.1, now: 130.1)
        XCTAssertEqual(resumed.event, .none)
        XCTAssertFalse(resumed.timingDelayed)
    }
    func testInvalidAndTransientStoppedCallbacksCannotEndTake() {
        var monitor = HostTransportMonitor()
        _ = monitor.update(seconds: 2, reportedPlaying: true, valid: true, reportTime: 10, now: 10)
        _ = monitor.update(seconds: 0, reportedPlaying: false, valid: false, reportTime: 10.1, now: 10.1)
        XCTAssertTrue(monitor.update(seconds: 2.2, reportedPlaying: false, valid: true, reportTime: 10.2, now: 10.2).playing)
        let recovered = monitor.update(seconds: 2.3, reportedPlaying: true, valid: true, reportTime: 10.3, now: 10.3)
        XCTAssertTrue(recovered.playing)
        XCTAssertEqual(recovered.event, .none)
    }
    func testConfirmedStopWorksEvenIfHostStopsRenderingAfterLastReport() {
        var monitor = HostTransportMonitor()
        _ = monitor.update(seconds: 2, reportedPlaying: true, valid: true, reportTime: 10, now: 10)
        _ = monitor.update(seconds: 3, reportedPlaying: false, valid: true, reportTime: 11, now: 11)
        let stopped = monitor.update(seconds: 3, reportedPlaying: false, valid: true, reportTime: 11, now: 11.21)
        XCTAssertEqual(stopped.event, .stopped)
        XCTAssertFalse(stopped.playing)
        XCTAssertEqual(stopped.seconds, 3)
    }
    func testRecordFlagGlitchesWhileTimelineAdvancesDoNotStopTake() {
        var monitor = HostTransportMonitor()
        _ = monitor.update(seconds: 1, reportedPlaying: true, valid: true, reportTime: 10, now: 10)
        for i in 1...120 {
            let t = Double(i) / 30
            XCTAssertTrue(monitor.update(seconds: 1 + t, reportedPlaying: false, valid: true, reportTime: 10 + t, now: 10 + t).playing)
        }
    }
    func testConfirmedBackwardSeekIsReportedButOneBadPositionIsIgnored() {
        var monitor = HostTransportMonitor()
        _ = monitor.update(seconds: 20, reportedPlaying: true, valid: true, reportTime: 10, now: 10)
        let glitch = monitor.update(seconds: 0, reportedPlaying: true, valid: true, reportTime: 10.02, now: 10.02)
        XCTAssertEqual(glitch.event, .none)
        XCTAssertEqual(glitch.seconds, 20, "An isolated zero cannot move the playhead or viewport")
        XCTAssertEqual(monitor.update(seconds: 20.04, reportedPlaying: true, valid: true, reportTime: 10.04, now: 10.04).event, .none)
        _ = monitor.update(seconds: 4, reportedPlaying: true, valid: true, reportTime: 10.06, now: 10.06)
        XCTAssertEqual(monitor.update(seconds: 4.02, reportedPlaying: true, valid: true, reportTime: 10.08, now: 10.08).event, .relocated)
    }
    func testForwardHostClockReanchorDoesNotStopVideo() {
        var monitor = HostTransportMonitor()
        _ = monitor.update(seconds: 10, reportedPlaying: true, valid: true, reportTime: 100, now: 100)
        let update = monitor.update(seconds: 12, reportedPlaying: true, valid: true, reportTime: 100.02, now: 100.02)
        XCTAssertTrue(update.playing)
        XCTAssertEqual(update.event, .none)
    }
    func testStoppedZeroGlitchDoesNotFlashTheStartDuringPlayback() {
        var monitor = HostTransportMonitor()
        _ = monitor.update(seconds: 250, reportedPlaying: true, valid: true, reportTime: 100, now: 100)
        let suspect = monitor.update(seconds: 0, reportedPlaying: false, valid: true, reportTime: 100.02, now: 100.02)
        XCTAssertEqual(suspect.seconds, 250)
        let recovered = monitor.update(seconds: 250.04, reportedPlaying: true, valid: true, reportTime: 100.04, now: 100.04)
        XCTAssertEqual(recovered.seconds, 250.04)
        XCTAssertEqual(recovered.event, .none)
    }

    @MainActor
    func testStoppedPreviewYieldsToLogicMovementAndPlay() {
        let sync = LogicSyncEngine(isHosted: true)
        sync.receiveHostPosition(seconds: 90, playing: false, tempo: 120, available: true)
        sync.preview(at: 100)
        sync.receiveHostPosition(seconds: 90, playing: false, tempo: 120, available: true)
        XCTAssertEqual(sync.editorSeconds, 100)
        XCTAssertEqual(sync.displaySeconds, 90, "Preview never changes the recording clock")
        sync.receiveHostPosition(seconds: 92, playing: false, tempo: 120, available: true)
        XCTAssertEqual(sync.editorSeconds, 92)
        sync.preview(at: 100)
        sync.receiveHostPosition(seconds: 92, playing: true, tempo: 120, available: true)
        XCTAssertEqual(sync.editorSeconds, 92)
        sync.preview(at: 0)
        XCTAssertEqual(sync.editorSeconds, 92, "Scrubbing cannot override a rolling host")
    }

    func testTimelineCenterAndPinchAnchorStayStableFarFromStart() {
        XCTAssertEqual(TimelineViewport.centeredOrigin(seconds: 2, scale: 18, viewportWidth: 600, contentWidth: 10000), 0)
        XCTAssertEqual(TimelineViewport.centeredOrigin(seconds: 300, scale: 18, viewportWidth: 600, contentWidth: 10000), 5100)
        let zoomed = TimelineViewport.zoomedOrigin(oldOrigin: 5100, oldScale: 18, newScale: 36, anchorX: 300)
        XCTAssertEqual(zoomed, 10500)
        XCTAssertEqual((zoomed + 300) / 36, 300, "The time under the pinch remains stationary")
    }

}
