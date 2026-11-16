import Foundation

/// Bounded, asynchronous diagnostics for import and transcription. Values are an explicit allowlist.
final class QueueDiagnostics: @unchecked Sendable {
    static let shared = QueueDiagnostics()
    private let journal: FeedbackDiagnostics
    private let writer = DispatchQueue(label: "com.xsg.talktuck.import-queue-diagnostics", qos: .utility)
    private let lock = NSLock()
    private var pending = 0
    private var dropped = 0
    private let limit: Int
    init(journal: FeedbackDiagnostics = .shared, limit: Int = 128) { self.journal = journal; self.limit = max(1, limit) }
    func emit(_ event: String, operation: String, phase: String, outcome: String, depth: Int, elapsedMs: Int? = nil) {
        lock.lock()
        guard pending < limit else { dropped += 1; lock.unlock(); return }
        pending += 1; let droppedBefore = dropped; dropped = 0
        lock.unlock()
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        writer.async { [self] in
            var fields: [String: Any] = ["schema": 1, "platform": "macOS", "build": build,
                "operation": operation, "phase": phase, "outcome": outcome, "queueDepth": max(0, depth), "dropped": droppedBefore]
            if let elapsedMs { fields["elapsedMs"] = max(0, elapsedMs) }
            journal.record("import-queue", event, fields: fields)
            lock.lock(); pending -= 1; lock.unlock()
        }
    }
    func flush() { writer.sync {} }
    static func token() -> String { String(UUID().uuidString.prefix(8)) }
    static func elapsed(since start: UInt64) -> Int { Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) }
}
