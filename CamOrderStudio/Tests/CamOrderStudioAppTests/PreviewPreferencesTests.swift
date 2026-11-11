import XCTest
@testable import CamOrderStudioApp
import CamOrderStudioCore

final class PreviewPreferencesTests: XCTestCase {
    @MainActor
    func testPreferenceDefaultsToBalancedAndPersistsWithoutProjectMutation() {
        let name = "CamOrderPreviewTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = PreviewPreferences(defaults: defaults)
        XCTAssertEqual(preferences.quality, .balanced)
        preferences.quality = .light
        XCTAssertEqual(PreviewPreferences(defaults: defaults).quality, .light)
        defaults.set("future-unknown-value", forKey: "CamOrderPreviewQuality")
        XCTAssertEqual(PreviewPreferences(defaults: defaults).quality, .balanced)
    }

    @MainActor
    func testStopCancelsPreparationAndChangingQualityClearsResolvedURLs() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "motion", withExtension: "mp4", subdirectory: "Fixtures"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let controller = PlaybackPreviewController(cache: PreviewProxyCache(folder: folder))
        await controller.configure(.init(sources: [source], quality: .light))
        controller.prepare()
        XCTAssertTrue(controller.isPreparing)
        controller.stop()
        XCTAssertFalse(controller.isPreparing)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(controller.urls.isEmpty, "Cancelled work must not install a late result")
        controller.prepare()
        let deadline = Date().addingTimeInterval(10)
        while controller.isPreparing && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(controller.urls[source])
        await controller.configure(.init(sources: [source], quality: .full))
        XCTAssertTrue(controller.urls.isEmpty)
        controller.prepare()
        XCTAssertFalse(controller.isPreparing)
    }
}
