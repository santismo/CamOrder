import Foundation
import CamOrderStudioCore

@MainActor
final class PreviewPreferences: ObservableObject {
    static let shared = PreviewPreferences()
    private let defaults: UserDefaults
    @Published var quality: PreviewQuality {
        didSet { defaults.set(quality.rawValue, forKey: "CamOrderPreviewQuality") }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        quality = defaults.string(forKey: "CamOrderPreviewQuality").flatMap(PreviewQuality.init) ?? .balanced
    }
}
