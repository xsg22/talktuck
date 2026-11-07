import Foundation

/// Copies the worker's output to its original error log and a timestamped,
/// persistent feedback journal. The worker never waits on the UI thread.
final class WorkerLogCapture: @unchecked Sendable {
    let pipe = Pipe()
    private let mirror: FileHandle
    private let stage: String
    private let workerID = UUID().uuidString
    private let finished = DispatchSemaphore(value: 0)
    private let journal: FeedbackDiagnostics

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
            while true {
                let bytes = pipe.fileHandleForReading.availableData
                if bytes.isEmpty { break }
                do { try mirror.write(contentsOf: bytes) }
                catch { journal.record("worker-output", "mirror-write-failed", fields: ["stage": stage, "workerID": workerID, "error": String(describing: error)]) }
                for offset in stride(from: 0, to: bytes.count, by: 32_768) {
                    let part = bytes.subdata(in: offset..<min(offset + 32_768, bytes.count))
                    journal.record("worker-output", "bytes", fields: ["stage": stage, "workerID": workerID, "base64": part.base64EncodedString()])
                }
            }
        }
    }

    /// Avoid indefinitely holding up recording finalization if a descendant
    /// process inherited the output descriptor.
    func waitForDrain() -> Bool { finished.wait(timeout: .now() + 5) == .success }
}
