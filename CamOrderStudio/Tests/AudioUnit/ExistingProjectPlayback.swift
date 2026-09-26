import Foundation
import AVFoundation
import CamOrderStudioCore

// Read-only playback probe for existing projects. Never writes media or project state.
@main
struct ExistingProjectPlayback {
    @MainActor static func main() throws {
        let document = try ProjectDocument.open(at: URL(fileURLWithPath: CommandLine.arguments[1]))
        var tested = 0
        for lane in document.project.timeline.lanes {
            for clip in lane.clips where clip.isEnabled && clip.durationSeconds > 1 {
                let media = document.project.media.first { $0.id == clip.mediaAssetId }!
                let url = document.absoluteURL(for: media.relativePath)
                let playback = TimelineVideoPlayer()
                let initial = clip.sourceSeconds(at: clip.timelineStartSeconds + 0.1, syncOffset: clip.playbackSyncOffsetSeconds ?? 0)
                playback.update(url: url, sourceSeconds: initial, isPlaying: false)
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                playback.player.currentItem!.add(output)
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline && (playback.player.currentItem?.status != .readyToPlay || abs(playback.player.currentTime().seconds - initial) > 0.04) {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                }
                precondition(abs(playback.player.currentTime().seconds - initial) < 0.04, "Existing trimmed region must seek successfully")
                let start = ProcessInfo.processInfo.systemUptime
                var frames = 0
                while ProcessInfo.processInfo.systemUptime - start < 0.8 {
                    let elapsed = ProcessInfo.processInfo.systemUptime - start
                    playback.update(url: url, sourceSeconds: initial + elapsed, isPlaying: true)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.016))
                    if output.hasNewPixelBuffer(forItemTime: playback.player.currentTime()), output.copyPixelBuffer(forItemTime: playback.player.currentTime(), itemTimeForDisplay: nil) != nil { frames += 1 }
                }
                precondition(playback.player.currentTime().seconds > initial + 0.6 && frames > 8, "Existing movie must deliver advancing frames after a trim")
                playback.player.pause()
                tested += 1
                print("PASS: existing region \(tested), source start \(String(format: "%.3f", initial)), decoded \(frames) advancing frames")
            }
        }
        precondition(tested > 0)
        print("PASS: existing project playback checked read-only; no project or source media changed")
    }
}
