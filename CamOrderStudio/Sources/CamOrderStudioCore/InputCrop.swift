import Foundation
import CoreGraphics

/// A source-relative rectangle, measured from the top-left of the incoming
/// video. Independent of preview resolution, lane framing, and screen regions.
public struct InputCrop: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public init(_ rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
    public static let full = InputCrop(x: 0, y: 0, width: 1, height: 1)
    public var rect: CGRect? {
        guard [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
        let rect = CGRect(x: x, y: y, width: width, height: height).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return rect.isNull || rect.isEmpty ? nil : rect
    }
    public var normalized: InputCrop? { rect.map(InputCrop.init) }
    /// Round inward to whole pixels and even encoder dimensions; never include
    /// a pixel outside the selection. Preview reduction does not affect this.
    public func pixelRect(width: Int, height: Int) -> CGRect? {
        guard width >= 2, height >= 2, let rect else { return nil }
        let x = Int(ceil(rect.minX * Double(width)))
        let y = Int(ceil(rect.minY * Double(height)))
        let w = (Int(floor(rect.maxX * Double(width))) - x) / 2 * 2
        let h = (Int(floor(rect.maxY * Double(height))) - y) / 2 * 2
        guard w >= 2, h >= 2 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
