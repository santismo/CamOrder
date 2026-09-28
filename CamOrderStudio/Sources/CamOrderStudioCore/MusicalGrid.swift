import Foundation

/// A local musical grid anchored to the host's quarter-note beat and sample time.
/// The AU reports the tempo at its current location, not the complete tempo map.
public struct MusicalGrid: Equatable, Sendable {
    public var tempoBPM: Double
    public var originSeconds: Double

    public init(tempoBPM: Double = 120, originSeconds: Double = 0) {
        self.tempoBPM = tempoBPM.isFinite && tempoBPM > 0 ? tempoBPM : 120
        self.originSeconds = originSeconds.isFinite ? originSeconds : 0
    }

    public init?(hostSeconds: Double, beat: Double, tempoBPM: Double) {
        guard hostSeconds.isFinite, beat.isFinite, tempoBPM.isFinite, tempoBPM > 0 else { return nil }
        self.init(tempoBPM: tempoBPM, originSeconds: hostSeconds - beat * 60 / tempoBPM)
    }

    public func spacing(_ division: BeatGridDivision) -> Double { max(0.001, 60 / tempoBPM * division.beats) }

    public func snapped(_ seconds: Double, division: BeatGridDivision) -> Double {
        guard seconds.isFinite else { return seconds }
        let step = spacing(division)
        return max(0, originSeconds + ((seconds - originSeconds) / step).rounded() * step)
    }

    public func firstTick(atOrAfter seconds: Double, spacing: Double) -> Double {
        originSeconds + ceil((seconds - originSeconds) / spacing - 1e-9) * spacing
    }
}
