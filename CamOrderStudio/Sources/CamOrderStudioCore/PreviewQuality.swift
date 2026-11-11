import Foundation

/// Display-only preferences. Never used by capture encoders or final movie export.
public enum PreviewQuality: String, CaseIterable, Identifiable, Sendable {
    case full, balanced, light
    public var id: String { rawValue }
    public var title: String {
        switch self { case .full: return "Full"; case .balanced: return "Balanced"; case .light: return "Light" }
    }
    public var liveSize: CGSize {
        switch self {
        case .full: return CGSize(width: 960, height: 640)
        case .balanced: return CGSize(width: 640, height: 480)
        case .light: return CGSize(width: 320, height: 240)
        }
    }
}
