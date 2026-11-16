import Foundation

/// A private preview channel; it never changes the durable transcript.
struct OfflineRecognitionProgress: Sendable {
    let processedSeconds: Double
    let totalSeconds: Double
    let preview: String
    var truncated = false
    var unavailable = false
}

final class OfflineProgressReader: @unchecked Sendable {
    private struct Entry: Decodable { let index: Int; let start: Double; let end: Double; let text: String; let fallback: Bool; let truncated: Bool }
    private let directory: URL
    private let windows: [(Int64, Int64)]
    private let total: Double
    private let notify: @Sendable (OfflineRecognitionProgress) -> Void
    private let queue = DispatchQueue(label: "com.talktuck.offline-progress", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var next = 0
    private var preview = ""
    private var truncated = false
    private var previous = ""
    private var previousEnd = -1.0
    private var previousFallback = false
    private var unavailable = false

    init(directory: URL, windows: [(Int64, Int64)], total: Double,
         notify: @escaping @Sendable (OfflineRecognitionProgress) -> Void) {
        self.directory = directory; self.windows = windows; self.total = total; self.notify = notify
    }
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.drain() }
        self.timer = timer; timer.resume()
    }
    func finish() {
        queue.sync { timer?.cancel(); timer = nil; drain() }
    }
    private func drain() {
        while next < windows.count && next < 8192 {
            let url = directory.appendingPathComponent(String(format: "%08d.json", next))
            guard let data = try? Data(contentsOf: url), data.count <= 128 * 1024,
                  let item = try? JSONDecoder().decode(Entry.self, from: data), item.index == next else { break }
            let window = windows[next], start = Double(window.0) / 16000, end = Double(window.1) / 16000
            guard item.start.isFinite, item.end.isFinite, abs(item.start - start) < 0.001, abs(item.end - end) < 0.001 else { break }
            let original = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = start < previousEnd && !item.fallback && !previousFallback ? TranscriptionEngine.removeExactOverlap(previous, original) : original
            if !text.isEmpty { preview += (preview.isEmpty ? "" : "\n") + text }
            truncated = truncated || item.truncated
            if preview.count > 200_000 { preview = String(preview.suffix(200_000)); truncated = true }
            previous = original; previousEnd = end; previousFallback = item.fallback; next += 1
            // Limit UI work for very long recordings; finalized output is unaffected.
            notify(OfflineRecognitionProgress(processedSeconds: min(total, end), totalSeconds: total, preview: preview, truncated: truncated))
        }
        if !unavailable && FileManager.default.fileExists(atPath: directory.appendingPathComponent("unavailable").path) {
            unavailable = true
            FeedbackDiagnostics.shared.record("transcription-engine", "preview-unavailable", fields: [:])
            notify(OfflineRecognitionProgress(processedSeconds: min(total, max(0, previousEnd)), totalSeconds: total, preview: preview, truncated: truncated, unavailable: true))
        }
    }
}
