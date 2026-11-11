import XCTest
@testable import CamOrderStudioApp
import CamOrderStudioCore

private actor ControlledPreviewCache: PlaybackPreviewPreparing {
    struct Key: Hashable { var source: URL; var quality: PreviewQuality }
    var calls: [Key] = []
    var ready: [Key: URL] = [:]
    var blocked = Set<URL>()
    var failures = Set<URL>()
    var active = 0
    var maxActive = 0
    var cancellations = 0
    func block(_ url: URL) { blocked.insert(url) }
    func release(_ url: URL) { blocked.remove(url) }
    func fail(_ url: URL) { failures.insert(url) }
    func seed(_ source: URL, quality: PreviewQuality) { ready[Key(source: source, quality: quality)] = source.appendingPathExtension("cached") }
    func cachedURL(for source: URL, quality: PreviewQuality) async -> URL? { ready[Key(source: source, quality: quality)] }
    func prepare(_ source: URL, quality: PreviewQuality) async throws -> URL {
        let key = Key(source: source, quality: quality)
        calls.append(key); active += 1; maxActive = max(maxActive, active)
        defer { active -= 1 }
        if failures.contains(source) { throw NSError(domain: "PreviewTest", code: 1) }
        do {
            while blocked.contains(source) { try await Task.sleep(nanoseconds: 5_000_000) }
            try Task.checkCancellation()
        } catch {
            cancellations += 1
            throw error
        }
        let proxy = source.appendingPathExtension(quality.rawValue)
        ready[key] = proxy
        return proxy
    }
}

@MainActor
final class AutomaticPreviewTests: XCTestCase {
    private let first = URL(fileURLWithPath: "/preview-test/first.mov")
    private let second = URL(fileURLWithPath: "/preview-test/second.mov")
    private func waitUntil(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()) && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        let met = await condition()
        XCTAssertTrue(met, "Timed out waiting for preview state", file: file, line: line)
    }

    func testNewClipsWaitForIdleAndOnlyMissingFilesPrepare() async throws {
        let cache = ControlledPreviewCache()
        await cache.seed(first, quality: .light)
        let controller = PlaybackPreviewController(cache: cache, idleDelay: 20_000_000)
        let request = PlaybackPreviewController.Request(sources: [first, second], quality: .light)
        controller.update(request, isIdle: false) // playing, armed, recording, exporting or hidden
        try await waitUntil { !controller.isCheckingCache }
        controller.prepare() // Even a manual click must respect the gate.
        try await Task.sleep(nanoseconds: 50_000_000)
        let busyCalls = await cache.calls
        XCTAssertTrue(busyCalls.isEmpty)
        XCTAssertNotNil(controller.urls[first])
        controller.update(request, isIdle: true)
        try await waitUntil { controller.urls[second] != nil }
        let calls = await cache.calls
        XCTAssertEqual(calls.map(\.source), [second])
        for _ in 0..<20 { controller.update(request, isIdle: true) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let count = await cache.calls.count
        XCTAssertEqual(count, 1, "Idle refreshes must not rebuild ready footage")
    }

    func testBusyCancelsInFlightAndNextIdleResumesWithoutOverlappingJobs() async throws {
        let cache = ControlledPreviewCache()
        await cache.block(first)
        let controller = PlaybackPreviewController(cache: cache, idleDelay: 20_000_000)
        let request = PlaybackPreviewController.Request(sources: [first], quality: .balanced)
        controller.update(request, isIdle: true)
        try await waitUntil { await cache.active == 1 }
        controller.update(request, isIdle: false)
        XCTAssertFalse(controller.isPreparing)
        try await waitUntil { await cache.active == 0 }
        XCTAssertNil(controller.urls[first])
        await cache.release(first)
        controller.update(request, isIdle: true)
        try await waitUntil { controller.urls[first] != nil }
        let cancelled = await cache.cancellations, maximum = await cache.maxActive
        XCTAssertEqual(cancelled, 1); XCTAssertEqual(maximum, 1)
        // A second completed recording joins the queue automatically, preserving the first.
        controller.update(.init(sources: [first, second], quality: .balanced), isIdle: false)
        XCTAssertNotNil(controller.urls[first])
        try await waitUntil { !controller.isCheckingCache }
        controller.update(.init(sources: [first, second], quality: .balanced), isIdle: true)
        try await waitUntil { controller.urls[second] != nil }
        let calls = await cache.calls
        XCTAssertEqual(calls.map(\.source), [first, first, second])
    }

    func testBusyDuringIdleDelayPreventsStartingAndFullNeverPrepares() async throws {
        let cache = ControlledPreviewCache()
        let controller = PlaybackPreviewController(cache: cache, idleDelay: 50_000_000)
        let request = PlaybackPreviewController.Request(sources: [first], quality: .light)
        controller.update(request, isIdle: true)
        try await waitUntil { !controller.isCheckingCache }
        controller.update(request, isIdle: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        controller.update(.init(sources: [first], quality: .full), isIdle: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        let calls = await cache.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(controller.urls.isEmpty)
    }

    func testQualityAndProjectChangesDiscardOldWork() async throws {
        let cache = ControlledPreviewCache()
        await cache.block(first)
        let controller = PlaybackPreviewController(cache: cache, idleDelay: 20_000_000)
        controller.update(.init(sources: [first], quality: .light), isIdle: true)
        try await waitUntil { await cache.active == 1 }
        controller.update(.init(sources: [first], quality: .full), isIdle: true)
        controller.update(.init(sources: [first], quality: .balanced), isIdle: true)
        try await waitUntil { await cache.calls.count == 2 }
        await cache.release(first)
        try await waitUntil { controller.urls[first] != nil }
        XCTAssertEqual(controller.urls[first]?.pathExtension, "balanced")
        let maximum = await cache.maxActive
        XCTAssertEqual(maximum, 1)
        controller.update(.init(sources: [second], quality: .balanced), isIdle: true)
        XCTAssertNil(controller.urls[first])
        try await waitUntil { controller.urls[second] != nil }
        XCTAssertNil(controller.urls[first], "Old project media must not return through a late completion")
    }

    func testPauseStaysPausedUntilNextIdlePeriod() async throws {
        let cache = ControlledPreviewCache()
        let controller = PlaybackPreviewController(cache: cache, idleDelay: 30_000_000)
        let request = PlaybackPreviewController.Request(sources: [first], quality: .balanced)
        controller.update(request, isIdle: true)
        try await waitUntil { !controller.isCheckingCache }
        controller.stop()
        controller.update(request, isIdle: true)
        try await Task.sleep(nanoseconds: 80_000_000)
        let pausedCalls = await cache.calls
        XCTAssertTrue(pausedCalls.isEmpty)
        controller.update(request, isIdle: false) // closing/reopening or a transport/arm cycle
        controller.update(request, isIdle: true)
        try await waitUntil { controller.urls[first] != nil }
    }

    func testFailuresDoNotRetryContinuouslyOrBlockNewClips() async throws {
        let cache = ControlledPreviewCache()
        await cache.fail(first)
        let controller = PlaybackPreviewController(cache: cache, idleDelay: 20_000_000)
        let request = PlaybackPreviewController.Request(sources: [first], quality: .balanced)
        controller.update(request, isIdle: true)
        try await waitUntil { controller.message.contains("unavailable") }
        controller.update(request, isIdle: false)
        controller.update(.init(sources: [first, second], quality: .balanced), isIdle: true)
        try await waitUntil { controller.urls[second] != nil && !controller.isPreparing }
        let calls = await cache.calls
        XCTAssertEqual(calls.map(\.source), [first, second])
        controller.prepare() // Explicit retry is still available.
        try await waitUntil { await cache.calls.count == 3 }
        try await waitUntil { !controller.isPreparing }
        XCTAssertTrue(controller.message.contains("unavailable"))
    }
}
