import Foundation

public enum FrameRate: String, Codable, CaseIterable, Identifiable, Sendable {
    case fps23_976
    case fps24
    case fps25
    case fps29_97
    case fps30
    case fps60

    public var id: String { rawValue }

    public var framesPerSecond: Double {
        switch self {
        case .fps23_976: return 24000.0 / 1001.0
        case .fps24: return 24
        case .fps25: return 25
        case .fps29_97: return 30000.0 / 1001.0
        case .fps30: return 30
        case .fps60: return 60
        }
    }

    public var nominalFramesPerSecond: Int {
        switch self {
        case .fps23_976, .fps24: return 24
        case .fps25: return 25
        case .fps29_97, .fps30: return 30
        case .fps60: return 60
        }
    }

    public var displayName: String {
        switch self {
        case .fps23_976: return "23.976 fps"
        case .fps24: return "24 fps"
        case .fps25: return "25 fps"
        case .fps29_97: return "29.97 fps"
        case .fps30: return "30 fps"
        case .fps60: return "60 fps"
        }
    }
}

public struct Timecode: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public var hours: Int
    public var minutes: Int
    public var seconds: Int
    public var frames: Int
    public var frameRate: FrameRate

    public init(hours: Int, minutes: Int, seconds: Int, frames: Int, frameRate: FrameRate) {
        self.hours = max(0, hours)
        self.minutes = min(max(0, minutes), 59)
        self.seconds = min(max(0, seconds), 59)
        self.frames = min(max(0, frames), frameRate.nominalFramesPerSecond - 1)
        self.frameRate = frameRate
    }

    public var totalFrames: Int {
        let wholeSeconds = ((hours * 60) + minutes) * 60 + seconds
        return wholeSeconds * frameRate.nominalFramesPerSecond + frames
    }

    public var secondsValue: Double {
        Double(totalFrames) / frameRate.framesPerSecond
    }

    public var description: String {
        String(format: "%02d:%02d:%02d:%02d", hours, minutes, seconds, frames)
    }

    public static func from(seconds: Double, frameRate: FrameRate) -> Timecode {
        let totalFrames = max(0, Int((seconds * frameRate.framesPerSecond).rounded()))
        return from(totalFrames: totalFrames, frameRate: frameRate)
    }

    public static func from(totalFrames: Int, frameRate: FrameRate) -> Timecode {
        let fps = frameRate.nominalFramesPerSecond
        let clampedFrames = max(0, totalFrames)
        let wholeSeconds = clampedFrames / fps
        let frames = clampedFrames % fps
        let hours = wholeSeconds / 3600
        let minutes = (wholeSeconds % 3600) / 60
        let seconds = wholeSeconds % 60
        return Timecode(hours: hours, minutes: minutes, seconds: seconds, frames: frames, frameRate: frameRate)
    }
}
