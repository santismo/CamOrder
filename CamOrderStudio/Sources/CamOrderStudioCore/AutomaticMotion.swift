import Foundation
import CoreGraphics

public enum MotionZoom: String, CaseIterable, Sendable { case none = "None", zoomIn = "In", zoomOut = "Out" }
public enum MotionPan: String, CaseIterable, Sendable {
    case none = "None", left = "Left", right = "Right", up = "Up", down = "Down"
    case upLeft = "Up left", upRight = "Up right", downLeft = "Down left", downRight = "Down right"
    public var vector: CGPoint {
        switch self {
        case .none: return .zero
        case .left: return CGPoint(x: -1, y: 0)
        case .right: return CGPoint(x: 1, y: 0)
        case .up: return CGPoint(x: 0, y: -1)
        case .down: return CGPoint(x: 0, y: 1)
        case .upLeft: return CGPoint(x: -1, y: -1)
        case .upRight: return CGPoint(x: 1, y: -1)
        case .downLeft: return CGPoint(x: -1, y: 1)
        case .downRight: return CGPoint(x: 1, y: 1)
        }
    }
}

public struct AutomaticMotion: Equatable, Sendable {
    public var zoom: MotionZoom = .zoomIn
    public var zoomAmount: Double = 0.08
    public var pan: MotionPan = .none
    /// Travel as a fraction of the canvas width/height. Pan describes the camera
    /// direction, so the image moves in the opposite direction.
    public var panAmount: Double = 0.04
    /// Canvas coordinates: center 0/0, left/top -1, right/bottom +1.
    public var focalX: Double = 0
    public var focalY: Double = 0
    public var keepEdgesCovered = true
    public var combineWithExisting = true
    public init() {}
    public var hasMotion: Bool { (zoom != .none && zoomAmount > 0) || (pan != .none && panAmount > 0) }

    /// Bake editable markers over the currently trimmed region. Original media,
    /// timing, source trims, layers and sync offsets are untouched.
    public func applying(to clip: VideoClip, sourceSize: CGSize, canvasSize: CGSize) throws -> VideoClip {
        guard hasMotion else { throw MotionFailure("Choose zoom or pan before applying motion.") }
        guard clip.durationSeconds.isFinite, clip.durationSeconds > 0,
              [zoomAmount, panAmount, focalX, focalY].allSatisfy(\.isFinite),
              (0...1).contains(zoomAmount), (0...0.5).contains(panAmount),
              (-1...1).contains(focalX), (-1...1).contains(focalY),
              [sourceSize.width, sourceSize.height, canvasSize.width, canvasSize.height].allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw MotionFailure("This region has invalid motion, duration or video dimensions.")
        }
        let duration = clip.durationSeconds
        let combined = combineWithExisting && !clip.automationMarkers.isEmpty
        let base = clip.automatedFraming(atLocalSecond: 0)
        guard Self.valid(base), clip.automationMarkers.allSatisfy({ Self.valid($0.framing) && $0.timeSeconds.isFinite }) else {
            throw MotionFailure("This region's existing automation is invalid. Reset it before adding motion.")
        }
        var times: Set<Double> = [0, duration]
        if combined {
            // Sample existing smooth curves without applying another ease at
            // every sample. Already-linear baked motion does not multiply keys
            // with each new application.
            let keys = clip.automationMarkers.filter { $0.timeSeconds.isFinite }.sorted { $0.timeSeconds < $1.timeSeconds }
            let knots = [ClipAutomationMarker(timeSeconds: 0, framing: clip.framing ?? ClipFraming())] + keys
            for index in 0..<max(0, knots.count - 1) {
                let a = knots[index], b = knots[index + 1]
                guard b.timeSeconds > a.timeSeconds, b.timeSeconds > 0, a.timeSeconds < duration else { continue }
                let angle = abs(Self.angleDelta(a.framing.rotationDegrees, b.framing.rotationDegrees))
                let steps = max(a.interpolation == .linear ? 1 : 8, Int(ceil(angle / 4)))
                for step in 0...steps {
                    let t = a.timeSeconds + (b.timeSeconds - a.timeSeconds) * Double(step) / Double(steps)
                    if t > 0, t < duration { times.insert(t) }
                }
            }
            for key in keys where key.timeSeconds > 0 && key.timeSeconds < duration { times.insert(key.timeSeconds) }
            for step in 1..<16 { times.insert(duration * Double(step) / 16) }
        }
        let direction = pan.vector
        let uniqueTimes = times.sorted().reduce(into: [Double]()) { result, time in
            if result.last.map({ time - $0 > min(1e-7, duration / 1000) }) ?? true { result.append(time) }
        }
        var markers = uniqueTimes.map { time -> ClipAutomationMarker in
            let t = time / duration
            let progress = combined ? t * t * (3 - 2 * t) : t
            let zoomProgress = zoom == .zoomIn ? progress : (zoom == .zoomOut ? 1 - progress : 0)
            let multiplier = 1 + (zoom == .none ? 0 : zoomAmount * zoomProgress)
            let original = combined ? clip.automatedFraming(atLocalSecond: time) : base
            let value = ClipFraming(zoom: original.zoom * multiplier,
                offsetX: original.offsetX * multiplier + focalX * (1 - multiplier) - Double(direction.x) * 2 * panAmount * (progress - 0.5),
                offsetY: original.offsetY * multiplier + focalY * (1 - multiplier) - Double(direction.y) * 2 * panAmount * (progress - 0.5),
                rotationDegrees: original.rotationDegrees)
            return ClipAutomationMarker(id: clip.automationMarkers.first { abs($0.timeSeconds - time) < 1e-9 }?.id ?? UUID().uuidString,
                                        timeSeconds: time, framing: value, interpolation: combined ? .linear : .smooth)
        }
        guard markers.allSatisfy({ Self.valid($0.framing) }) else {
            throw MotionFailure("This region's existing framing is invalid. Reset its framing before adding motion.")
        }
        if keepEdgesCovered {
            let gain = Self.coverageGain(markers: markers, source: sourceSize, canvas: canvasSize)
            for index in markers.indices { markers[index].framing.zoom *= gain }
        }
        guard markers.allSatisfy({ (0.25...16).contains($0.framing.zoom) && abs($0.framing.offsetX) <= 8 && abs($0.framing.offsetY) <= 8 }) else {
            throw MotionFailure("This motion exceeds the framing limits. Reduce the amount, choose Replace, or turn off Keep edges covered for an overlay.")
        }
        var result = clip
        result.framing = markers[0].framing
        let outside = combineWithExisting ? clip.automationMarkers.filter { $0.timeSeconds < 0 || $0.timeSeconds > duration } : []
        result.automationMarkers = (outside + markers).sorted { $0.timeSeconds < $1.timeSeconds }
        return result
    }

    private static func valid(_ f: ClipFraming) -> Bool {
        [f.zoom, f.offsetX, f.offsetY, f.rotationDegrees].allSatisfy(\.isFinite) && f.zoom > 0
    }
    private static func angleDelta(_ a: Double, _ b: Double) -> Double {
        var d = (b.truncatingRemainder(dividingBy: 360) - a.truncatingRemainder(dividingBy: 360)).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }; if d < -180 { d += 360 }
        return d
    }
    /// With fixed rotation, the coverage inequalities are linear in zoom and
    /// translation: safe endpoints also cover every interpolated point. For
    /// rotating segments, bound each corner's projection over the angle range.
    private static func coverageGain(markers: [ClipAutomationMarker], source: CGSize, canvas: CGSize) -> Double {
        let fit = min(canvas.width / source.width, canvas.height / source.height)
        let half = CGSize(width: source.width * fit / 2, height: source.height * fit / 2)
        func corners(_ f: ClipFraming) -> [CGPoint] {
            [-1.0, 1.0].flatMap { x in [-1.0, 1.0].map { y in
                CGPoint(x: (x - f.offsetX) * canvas.width / 2, y: (y - f.offsetY) * canvas.height / 2)
            } }
        }
        func bound(_ a: Double, _ b: Double, _ low: Double, _ high: Double) -> Double {
            var angles = [low, high]
            let peak = atan2(b, a)
            let first = Int(ceil((low - peak) / .pi)), last = Int(floor((high - peak) / .pi))
            if first <= last { for n in first...last { angles.append(peak + Double(n) * .pi) } }
            return angles.map { abs(a * cos($0) + b * sin($0)) }.max() ?? 0
        }
        var gain = 0.0
        for index in 0..<(markers.count - 1) {
            let a = markers[index].framing, b = markers[index + 1].framing
            let start = a.rotationDegrees.truncatingRemainder(dividingBy: 360) * .pi / 180
            let delta = angleDelta(a.rotationDegrees, b.rotationDegrees) * .pi / 180
            for pose in [a, b] {
                let zoom = abs(delta) < 1e-9 ? pose.zoom : min(a.zoom, b.zoom)
                for p in corners(pose) {
                    gain = max(gain, bound(p.x, -p.y, min(start, start + delta), max(start, start + delta)) / (half.width * zoom),
                               bound(p.y, p.x, min(start, start + delta), max(start, start + delta)) / (half.height * zoom))
                }
            }
        }
        // Cover resampling at the pixel boundary and the small affine rotation
        // approximation between the densely sampled rotation keys during export.
        return max(1, gain * 1.01)
    }
}

public struct MotionFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
