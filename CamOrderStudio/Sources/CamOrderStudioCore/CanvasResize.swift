import Foundation
import CoreGraphics

/// Freeze the pixel-to-point ratio at mouse-down, so large source dimensions and
/// a refitting preview cannot change drag sensitivity midway through a gesture.
public struct CanvasResize {
    public let pixels: CGSize
    public let display: CGSize
    public let left: Bool
    public let top: Bool
    public init(pixels: CGSize, display: CGSize, left: Bool, top: Bool) {
        self.pixels = pixels; self.display = display; self.left = left; self.top = top
    }
    public func size(translation: CGSize) -> CGSize {
        let x = translation.width * pixels.width / max(1, display.width) * (left ? -2 : 2)
        let y = translation.height * pixels.height / max(1, display.height) * (top ? -2 : 2)
        // Even pixel sizes are supported by the video encoders.
        return CGSize(width: (min(7680, max(320, pixels.width + x)) / 2).rounded() * 2,
                      height: (min(4320, max(180, pixels.height + y)) / 2).rounded() * 2)
    }
}
