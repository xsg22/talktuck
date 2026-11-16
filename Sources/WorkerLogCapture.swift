import Foundation

/// Copies the worker's output to its original error log and a timestamped,
/// persistent feedback journal. The worker never waits on the UI thread.
final class WorkerLogCapture: @unchecked Sendable {
    let pipe = Pipe()
    private let mirror: FileHandle
    private let stage: String
    private let workerID = String(UUID().uuidString.prefix(8))
    private let finished = DispatchSemaphore(value: 0)
    private let journal: FeedbackDiagnostics
    private let diagnostics = DispatchQueue(label: "com.xsg.talktuck.fallback-diagnostics", qos: .utility)
    private let diagnosticsLock = NSLock()
    private var pending = 0, dropped = 0

    init(mirror: FileHandle, stage: String, journal: FeedbackDiagnostics = .workers) {
        self.mirror = mirror; self.stage = stage; self.journal = journal
    }

    func start() {
        try? pipe.fileHandleForWriting.close()
        journal.record("worker-output", "capture-start", fields: ["stage": stage, "workerID": workerID])
        DispatchQueue.global(qos: .utility).async { [self] in
            defer {
                journal.record("worker-output", "capture-end", fields: ["stage": stage, "workerID": workerID])
                try? pipe.fileHandleForReading.close(); finished.signal()
            }
            var byteCount = 0
            var line = [UInt8](), overflow = false
            while true {
                let bytes = pipe.fileHandleForReading.availableData
                if bytes.isEmpty { break }
                do { try mirror.write(contentsOf: bytes) }
                catch { journal.record("worker-output", "mirror-write-failed", fields: ["stage": stage, "workerID": workerID]) }
                if stage == "Qwen语音定稿" {
                    for byte in bytes {
                        if byte == 10 {
                            if !overflow { self.captureFallbackMarker(line) }
                            line.removeAll(keepingCapacity: true); overflow = false
                        } else if !overflow {
                            if line.count < 128 { line.append(byte) } else { line.removeAll(keepingCapacity: true); overflow = true }
                        }
                    }
                }
                byteCount += bytes.count
            }
            journal.record("worker-output", "summary", fields: ["stage": stage, "workerID": workerID, "bytesCount": byteCount])
        }
    }

    /// Avoid indefinitely holding up recording finalization if a descendant
    /// process inherited the output descriptor.
    func waitForDrain() -> Bool {
        let drained = finished.wait(timeout: .now() + 5) == .success
        if drained { diagnostics.sync {} }
        return drained
    }

    /// Only fixed protocol markers are retained, never arbitrary worker text.
    private func captureFallbackMarker(_ bytes: [UInt8]) {
        guard let value=String(bytes: bytes, encoding: .utf8) else { return }
        let parts=value.split(separator: " ").map(String.init)
        guard parts.count == 3, parts[0] == "TALKTUCK_FALLBACK" else { return }
        let phase=parts[1], reason=parts[2]
        let reasons: Set<String> = ["token_limit", "seam_unresolved", "repeated_decoding"]
        let failures: Set<String> = ["unsupported_language", "engine_unavailable", "incomplete_result", "invalid_result", "engine_failed"]
        guard ((phase == "attempt" || phase == "succeeded") && reasons.contains(reason)) || (phase == "failed" && failures.contains(reason)) else { return }
        diagnosticsLock.lock()
        guard pending < 32 else { dropped += 1; diagnosticsLock.unlock(); return }
        pending += 1; let discarded=dropped; dropped=0
        diagnosticsLock.unlock()
        diagnostics.async { [self] in
            let build=Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
            journal.record("worker-output", "fallback-"+phase, fields: ["schema":1, "platform":"macOS", "build":build, "stage":"Qwen语音定稿", "workerID":workerID, "reason":reason, "dropped":discarded])
            diagnosticsLock.lock(); pending -= 1; diagnosticsLock.unlock()
        }
    }
}
