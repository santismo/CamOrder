import Foundation
import CoreGraphics

final class PreviewReceiver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.santismo.CamOrder.previewReceiver", qos: .userInitiated)
    private let gate = DispatchSemaphore(value: 1)
    private let url: URL
    private let deliver: @Sendable (CGImage) -> Void
    private var shared: SharedPreview?
    private var sequence: UInt64 = 0
    private var timer: DispatchSourceTimer?
    init(url: URL, deliver: @escaping @Sendable (CGImage) -> Void) {
        self.url = url; self.deliver = deliver
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60.0, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }
    deinit { timer?.cancel() }
    private func poll() {
        if shared == nil { shared = try? SharedPreview(url: url, writable: false) }
        guard let shared, gate.wait(timeout: .now()) == .success else { return }
        guard let frame = shared.copyNewFrame(after: &sequence) else { gate.signal(); return }
        let deliver = deliver, gate = gate
        DispatchQueue.main.async { deliver(frame); gate.signal() }
    }
}
