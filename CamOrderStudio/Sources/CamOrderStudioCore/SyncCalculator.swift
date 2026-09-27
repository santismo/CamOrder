import Foundation

/// A calculator format is explicit: a decimal tail must never be guessed to be
/// milliseconds, frames, bits or audio samples from its number of digits.
public enum SyncClockFormat: String, CaseIterable, Identifiable, Sendable {
    case frames, framesAndBits, decimalSeconds, secondsAndSamples, framesAndSamples, framesAndMilliseconds
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .frames: return "SMPTE · frames"
        case .framesAndBits: return "SMPTE · frames + bits (80)"
        case .decimalSeconds: return "Time · milliseconds"
        case .secondsAndSamples: return "Time · seconds + samples"
        case .framesAndSamples: return "SMPTE · frames + samples"
        case .framesAndMilliseconds: return "SMPTE · frames + milliseconds"
        }
    }
    public var usesFrames: Bool { self != .decimalSeconds && self != .secondsAndSamples }
    public var usesSamples: Bool { self == .secondsAndSamples || self == .framesAndSamples }
    public var example: String {
        switch self {
        case .frames: return "01:00:36:16"
        case .framesAndBits: return "01:00:36:16.36"
        case .decimalSeconds: return "01:00:36.160"
        case .secondsAndSamples: return "00:36.16036"
        case .framesAndSamples: return "01:00:36:16.0036"
        case .framesAndMilliseconds: return "01:00:36:16.020"
        }
    }
}

public enum SyncClockRate: String, CaseIterable, Identifiable, Sendable {
    case fps23_976 = "23.976", fps24 = "24", fps25 = "25", fps29_97 = "29.97 NDF"
    case fps29_97DF = "29.97 DF", fps30 = "30", fps50 = "50"
    case fps59_94 = "59.94 NDF", fps59_94DF = "59.94 DF", fps60 = "60"
    public var id: String { rawValue }
    public var nominal: Int {
        switch self {
        case .fps23_976, .fps24: return 24
        case .fps25: return 25
        case .fps29_97, .fps29_97DF, .fps30: return 30
        case .fps50: return 50
        case .fps59_94, .fps59_94DF, .fps60: return 60
        }
    }
    public var fps: Double {
        switch self {
        case .fps23_976: return 24000 / 1001
        case .fps29_97, .fps29_97DF: return 30000 / 1001
        case .fps59_94, .fps59_94DF: return 60000 / 1001
        default: return Double(nominal)
        }
    }
    public var droppedLabels: Int { self == .fps29_97DF ? 2 : (self == .fps59_94DF ? 4 : 0) }
}

public struct SyncClockReading: Equatable, Sendable {
    public let seconds: Double
    public let interpretation: String
}

public struct SyncCorrection: Equatable, Sendable {
    public let logic: SyncClockReading
    public let video: SyncClockReading
    /// The captured clock is older when video is late. Move that video earlier.
    public var milliseconds: Double { (video.seconds - logic.seconds) * 1000 }
    public func resultingOffset(from existingMS: Double) -> Double { existingMS + milliseconds }
}

public enum SyncCalculator {
    public struct InputError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(_ message: String) { self.message = message }
    }

    public static func compare(logic: String, video: String, format: SyncClockFormat,
                               rate: SyncClockRate? = nil, sampleRate: Double? = nil) throws -> SyncCorrection {
        let actual: SyncClockReading
        do { actual = try parse(logic, format: format, rate: rate, sampleRate: sampleRate) }
        catch { throw InputError("Logic time: \(error.localizedDescription)") }
        let recorded: SyncClockReading
        do { recorded = try parse(video, format: format, rate: rate, sampleRate: sampleRate) }
        catch { throw InputError("Time in video: \(error.localizedDescription)") }
        return SyncCorrection(logic: actual, video: recorded)
    }

    public static func parse(_ text: String, format: SyncClockFormat,
                             rate: SyncClockRate? = nil, sampleRate: Double? = nil) throws -> SyncClockReading {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if format.usesSamples {
            guard let sampleRate, sampleRate.isFinite, (8000...384000).contains(sampleRate) else {
                throw InputError("Choose Logic's sample rate.")
            }
        }
        if !format.usesFrames {
            guard let fields = match(#"^(?:([0-9]{1,2}):)?([0-9]{1,2}):([0-9]{1,2})\.([0-9]{1,9})$"#, text),
                  let fraction = Double(fields[3]) else {
                throw InputError("Use [hours:]minutes:seconds.fraction, for example \(format.example).")
            }
            let (hours, minutes, seconds) = try clock(fields)
            let suffix: Double
            let detail: String
            if format == .secondsAndSamples {
                guard fraction < sampleRate! else { throw InputError("Samples must be smaller than the sample rate.") }
                suffix = fraction / sampleRate!
                detail = "\(fields[3]) samples at \(Int(sampleRate!)) Hz"
            } else {
                suffix = fraction / pow(10, Double(fields[3].count))
                detail = String(format: "%.6f decimal seconds", suffix)
            }
            return SyncClockReading(seconds: Double((hours * 60 + minutes) * 60 + seconds) + suffix,
                interpretation: "\(hours)h \(minutes)m \(seconds)s + \(detail)")
        }
        guard let rate else { throw InputError("Choose Logic's timecode frame rate.") }
        if text.contains(";"), rate.droppedLabels == 0 {
            throw InputError("A semicolon indicates drop-frame timecode. Choose a DF frame rate.")
        }
        let fields: [String]
        if format == .frames {
            guard let parsed = match(#"^(?:([0-9]{1,2}):)?([0-9]{1,2}):([0-9]{1,2})[:.;]([0-9]{1,2})$"#, text) else {
                throw InputError("Use [hours:]minutes:seconds:frames, for example \(format.example).")
            }
            fields = parsed
        } else {
            guard let parsed = match(#"^(?:([0-9]{1,2}):)?([0-9]{1,2}):([0-9]{1,2})[:.;]([0-9]{1,2})[.:/]([0-9]{1,6})$"#, text) else {
                throw InputError("Separate frames from the final value, for example \(format.example). Hours may be omitted.")
            }
            fields = parsed
        }
        let (hours, minutes, seconds) = try clock(fields)
        let frames = Int(fields[3])!
        guard frames < rate.nominal else { throw InputError("Frames must be 0–\(rate.nominal - 1) at \(rate.rawValue) fps.") }
        if rate.droppedLabels > 0, minutes % 10 != 0, seconds == 0, frames < rate.droppedLabels {
            throw InputError("That frame number is skipped at this minute in drop-frame timecode.")
        }
        let totalMinutes = hours * 60 + minutes
        let frameCount = (totalMinutes * 60 + seconds) * rate.nominal + frames
            - rate.droppedLabels * (totalMinutes - totalMinutes / 10)
        var subSeconds = 0.0
        var detail = ""
        if fields.count > 4 {
            let sub = Double(fields[4])!
            switch format {
            case .framesAndBits:
                guard sub < 80 else { throw InputError("SMPTE bits must be 0–79; they are not milliseconds.") }
                subSeconds = sub / 80 / rate.fps; detail = " + \(Int(sub))/80 frame"
            case .framesAndSamples:
                subSeconds = sub / sampleRate!
                detail = " + \(Int(sub)) samples at \(Int(sampleRate!)) Hz"
            case .framesAndMilliseconds:
                subSeconds = sub / 1000; detail = " + \(Int(sub)) ms within the frame"
            default: break
            }
            guard subSeconds < 1 / rate.fps else { throw InputError("The final value must fit within one frame. Check the display format and rate.") }
        }
        return SyncClockReading(seconds: Double(frameCount) / rate.fps + subSeconds,
            interpretation: "\(hours)h \(minutes)m \(seconds)s \(frames)f\(detail) · \(rate.rawValue) fps")
    }

    private static func clock(_ fields: [String]) throws -> (Int, Int, Int) {
        let hours = Int(fields[0]) ?? 0, minutes = Int(fields[1])!, seconds = Int(fields[2])!
        guard hours < 24, minutes < 60, seconds < 60 else { throw InputError("Use hours 0–23 and minutes/seconds 0–59.") }
        return (hours, minutes, seconds)
    }
    private static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<result.numberOfRanges).map { index in
            Range(result.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
