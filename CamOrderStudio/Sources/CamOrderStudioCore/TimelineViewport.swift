import Foundation

public enum TimelineViewport {
    public static func centeredOrigin(seconds: Double, scale: Double, viewportWidth: Double, contentWidth: Double) -> Double {
        min(max(0, contentWidth - viewportWidth), max(0, seconds * scale - viewportWidth / 2))
    }
    public static func zoomedOrigin(oldOrigin: Double, oldScale: Double, newScale: Double, anchorX: Double) -> Double {
        max(0, (oldOrigin + anchorX) / max(0.001, oldScale) * newScale - anchorX)
    }
}
