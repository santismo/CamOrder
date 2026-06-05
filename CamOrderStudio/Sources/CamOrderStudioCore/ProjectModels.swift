import Foundation

public struct CamOrderProject: Codable, Equatable, Sendable {
    public var projectVersion: Int
    public var name: String
    public var frameRate: FrameRate
    public var resolution: ProjectResolution
    public var timeline: Timeline
    public var media: [MediaAsset]
    public var sync: SyncSettings
    public var audio: MasterAudio
    public var captureLatencyProfiles: [CaptureLatencyProfile]
    public var exportSettings: ExportSettings

    public init(
        projectVersion: Int = 1,
        name: String,
        frameRate: FrameRate = .fps30,
        resolution: ProjectResolution = ProjectResolution(width: 1920, height: 1080),
        timeline: Timeline = Timeline(),
        media: [MediaAsset] = [],
        sync: SyncSettings = SyncSettings(),
        audio: MasterAudio = MasterAudio(),
        captureLatencyProfiles: [CaptureLatencyProfile] = [],
        exportSettings: ExportSettings = ExportSettings()
    ) {
        self.projectVersion = projectVersion
        self.name = name
        self.frameRate = frameRate
        self.resolution = resolution
        self.timeline = timeline
        self.media = media
        self.sync = sync
        self.audio = audio
        self.captureLatencyProfiles = captureLatencyProfiles
        self.exportSettings = exportSettings
    }

    public static func empty(name: String = "Untitled CamOrder Studio Project") -> CamOrderProject {
        CamOrderProject(
            name: name,
            timeline: Timeline(lanes: [
                VideoLane(id: "lane_1", name: "Lane 1"),
                VideoLane(id: "lane_2", name: "Lane 2")
            ])
        )
    }
}

public struct ProjectResolution: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct Timeline: Codable, Equatable, Sendable {
    public var durationSeconds: Double
    public var lanes: [VideoLane]
    public var tempoBPM: Double?
    public var gridDivision: BeatGridDivision?

    public init(durationSeconds: Double = 0, lanes: [VideoLane] = [], tempoBPM: Double? = 120, gridDivision: BeatGridDivision? = .beat) {
        self.durationSeconds = durationSeconds
        self.lanes = lanes
        self.tempoBPM = tempoBPM
        self.gridDivision = gridDivision
    }
}

public enum BeatGridDivision: String, Codable, CaseIterable, Sendable {
    case bar
    case beat
    case halfBeat
    case quarterBeat
    case eighthBeat

    public var displayName: String {
        switch self {
        case .bar: return "1 bar"
        case .beat: return "1 beat"
        case .halfBeat: return "1/2 beat"
        case .quarterBeat: return "1/4 beat"
        case .eighthBeat: return "1/8 beat"
        }
    }

    public var beats: Double {
        switch self {
        case .bar: return 4
        case .beat: return 1
        case .halfBeat: return 0.5
        case .quarterBeat: return 0.25
        case .eighthBeat: return 0.125
        }
    }
}

public struct VideoLane: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var isArmed: Bool
    public var isMuted: Bool
    public var clips: [VideoClip]

    public init(id: String = UUID().uuidString, name: String, isArmed: Bool = false, isMuted: Bool = false, clips: [VideoClip] = []) {
        self.id = id
        self.name = name
        self.isArmed = isArmed
        self.isMuted = isMuted
        self.clips = clips
    }
}

public struct VideoClip: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var clipId: String
    public var mediaAssetId: String
    public var videoFile: String
    public var armedLaneId: String
    public var logicStartTimecode: Timecode
    public var logicStartSeconds: Double
    public var timelineStartSeconds: Double
    public var appCaptureStartHostTime: UInt64?
    public var captureLatencyMs: Int
    public var durationSeconds: Double
    public var frameRate: FrameRate
    public var cameraDeviceId: String?
    public var droppedFrameWarnings: [String]
    public var trimInSeconds: Double
    public var trimOutSeconds: Double?
    public var isEnabled: Bool
    public var framing: ClipFraming?
    public var playbackSyncOffsetSeconds: Double?

    public init(
        id: String = UUID().uuidString,
        clipId: String,
        mediaAssetId: String,
        videoFile: String,
        armedLaneId: String,
        logicStartTimecode: Timecode,
        logicStartSeconds: Double,
        timelineStartSeconds: Double? = nil,
        appCaptureStartHostTime: UInt64? = nil,
        captureLatencyMs: Int = 0,
        durationSeconds: Double,
        frameRate: FrameRate,
        cameraDeviceId: String? = nil,
        droppedFrameWarnings: [String] = [],
        trimInSeconds: Double = 0,
        trimOutSeconds: Double? = nil,
        isEnabled: Bool = true,
        framing: ClipFraming? = nil,
        playbackSyncOffsetSeconds: Double? = nil
    ) {
        self.id = id
        self.clipId = clipId
        self.mediaAssetId = mediaAssetId
        self.videoFile = videoFile
        self.armedLaneId = armedLaneId
        self.logicStartTimecode = logicStartTimecode
        self.logicStartSeconds = logicStartSeconds
        self.timelineStartSeconds = timelineStartSeconds ?? Self.timelineStart(logicStartSeconds: logicStartSeconds, captureLatencyMs: captureLatencyMs)
        self.appCaptureStartHostTime = appCaptureStartHostTime
        self.captureLatencyMs = captureLatencyMs
        self.durationSeconds = durationSeconds
        self.frameRate = frameRate
        self.cameraDeviceId = cameraDeviceId
        self.droppedFrameWarnings = droppedFrameWarnings
        self.trimInSeconds = trimInSeconds
        self.trimOutSeconds = trimOutSeconds
        self.isEnabled = isEnabled
        self.framing = framing
        self.playbackSyncOffsetSeconds = playbackSyncOffsetSeconds
    }

    public static func timelineStart(logicStartSeconds: Double, captureLatencyMs: Int) -> Double {
        max(0, logicStartSeconds + (Double(captureLatencyMs) / 1000.0))
    }
}

public struct ClipFraming: Codable, Equatable, Sendable {
    public var zoom: Double
    public var offsetX: Double
    public var offsetY: Double
    public var rotationDegrees: Double

    public init(zoom: Double = 1, offsetX: Double = 0, offsetY: Double = 0, rotationDegrees: Double = 0) {
        self.zoom = zoom
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.rotationDegrees = rotationDegrees
    }

    private enum CodingKeys: String, CodingKey {
        case zoom
        case offsetX
        case offsetY
        case rotationDegrees
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        zoom = try container.decodeIfPresent(Double.self, forKey: .zoom) ?? 1
        offsetX = try container.decodeIfPresent(Double.self, forKey: .offsetX) ?? 0
        offsetY = try container.decodeIfPresent(Double.self, forKey: .offsetY) ?? 0
        rotationDegrees = try container.decodeIfPresent(Double.self, forKey: .rotationDegrees) ?? 0
    }
}

public enum MediaAssetKind: String, Codable, Sendable {
    case video
    case audio
    case legacy
}

public struct MediaAsset: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: MediaAssetKind
    public var displayName: String
    public var relativePath: String
    public var durationSeconds: Double?
    public var frameRate: FrameRate?
    public var importedAt: Date

    public init(
        id: String = UUID().uuidString,
        kind: MediaAssetKind,
        displayName: String,
        relativePath: String,
        durationSeconds: Double? = nil,
        frameRate: FrameRate? = nil,
        importedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.relativePath = relativePath
        self.durationSeconds = durationSeconds
        self.frameRate = frameRate
        self.importedAt = importedAt
    }
}

public enum SyncMode: String, Codable, CaseIterable, Sendable {
    case mtc
    case midiClock
}

public enum LogicSyncState: String, Codable, CaseIterable, Sendable {
    case disconnected
    case waitingForTimecode
    case locating
    case chasing
    case playing
    case stopped
    case unstable
    case error
}

public struct SyncSettings: Codable, Equatable, Sendable {
    public var mode: SyncMode
    public var frameRate: FrameRate
    public var lastKnownTimecode: Timecode
    public var state: LogicSyncState
    public var clockDisplayFormat: ClockDisplayFormat?
    public var subtractSMPTEHourOffset: Bool?
    public var defaultPlaybackSyncOffsetSeconds: Double?

    public init(mode: SyncMode = .mtc, frameRate: FrameRate = .fps30, lastKnownTimecode: Timecode? = nil, state: LogicSyncState = .disconnected, clockDisplayFormat: ClockDisplayFormat? = .logicTime, subtractSMPTEHourOffset: Bool? = true, defaultPlaybackSyncOffsetSeconds: Double? = 0.333) {
        self.mode = mode
        self.frameRate = frameRate
        self.lastKnownTimecode = lastKnownTimecode ?? Timecode(hours: 0, minutes: 0, seconds: 0, frames: 0, frameRate: frameRate)
        self.state = state
        self.clockDisplayFormat = clockDisplayFormat
        self.subtractSMPTEHourOffset = subtractSMPTEHourOffset
        self.defaultPlaybackSyncOffsetSeconds = defaultPlaybackSyncOffsetSeconds
    }
}

public enum ClockDisplayFormat: String, Codable, CaseIterable, Sendable {
    case logicTime
    case smpte
    case seconds

    public var displayName: String {
        switch self {
        case .logicTime: return "00:00.00000"
        case .smpte: return "00:00:00:00"
        case .seconds: return "seconds"
        }
    }
}

public struct MasterAudio: Codable, Equatable, Sendable {
    public var masteredAudioFile: String?
    public var audioOffsetSeconds: Double

    public init(masteredAudioFile: String? = nil, audioOffsetSeconds: Double = 0) {
        self.masteredAudioFile = masteredAudioFile
        self.audioOffsetSeconds = audioOffsetSeconds
    }
}

public struct CaptureLatencyProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var cameraDeviceId: String
    public var displayName: String
    public var latencyMs: Int
    public var playbackSyncOffsetSeconds: Double?

    public init(id: String = UUID().uuidString, cameraDeviceId: String, displayName: String, latencyMs: Int = 0, playbackSyncOffsetSeconds: Double? = nil) {
        self.id = id
        self.cameraDeviceId = cameraDeviceId
        self.displayName = displayName
        self.latencyMs = latencyMs
        self.playbackSyncOffsetSeconds = playbackSyncOffsetSeconds
    }
}

public struct CameraDeviceInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    public var kind: CaptureSourceKind

    public init(id: String, displayName: String, kind: CaptureSourceKind = .camera) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
    }
}

public enum CaptureSourceKind: String, Codable, Sendable {
    case camera
    case screen
    case window
}

public enum ExportContainer: String, Codable, CaseIterable, Sendable {
    case mov
    case mp4
    case m4v

    public var displayName: String {
        switch self {
        case .mov: return ".mov"
        case .mp4: return ".mp4"
        case .m4v: return ".m4v"
        }
    }
}

public enum ExportResolution: String, Codable, CaseIterable, Sendable {
    case source
    case hd1080
    case uhd4k

    public var displayName: String {
        switch self {
        case .source: return "Source"
        case .hd1080: return "1080p"
        case .uhd4k: return "4K"
        }
    }
}

public enum ExportAudioMode: String, Codable, CaseIterable, Sendable {
    case masteredOnly
    case cameraOnly
    case masteredAndCamera
    case muteAll

    public var displayName: String {
        switch self {
        case .masteredOnly: return "Mastered audio only"
        case .cameraOnly: return "Camera audio only"
        case .masteredAndCamera: return "Mastered + camera audio"
        case .muteAll: return "Mute all"
        }
    }
}

public struct ExportSettings: Codable, Equatable, Sendable {
    public var container: ExportContainer
    public var resolution: ExportResolution
    public var frameRate: FrameRate
    public var audioMode: ExportAudioMode
    public var canvasWidth: Int?
    public var canvasHeight: Int?

    public init(container: ExportContainer = .mov, resolution: ExportResolution = .hd1080, frameRate: FrameRate = .fps30, audioMode: ExportAudioMode = .masteredOnly, canvasWidth: Int? = 1920, canvasHeight: Int? = 1080) {
        self.container = container
        self.resolution = resolution
        self.frameRate = frameRate
        self.audioMode = audioMode
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
    }
}
