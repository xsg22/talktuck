import Foundation
import AVFoundation

@main struct ImportQueueSmoke {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("queue-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let state = AppState(storageURL: root, connectionNamespace: UUID().uuidString,
                             speechModelStore: ASRModelStore(root: root.appendingPathComponent("no-model")),
                             copyImportedAudio: { source, destination in
            entered.signal()
            guard release.wait(timeout: .now() + 10) == .success else { throw CocoaError(.fileReadUnknown) }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
        })
        let active = MeetingRecord(title: "active", text: "preserve", status: .transcribing)
        let library = try MeetingLibrary(root: root)
        _ = try library.save(active); state.history = try library.list(); state.select(active.id)
        state.busy = true
        let first = root.appendingPathComponent("one.wav"), second = root.appendingPathComponent("two.wav")
        try Data("one".utf8).write(to: first); try Data("two".utf8).write(to: second)
        state.useAudio(first); state.useAudio(second)
        // Wait asynchronously: if copying blocks the main actor, the heartbeat below never runs.
        let started = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 5) == .success) }
        }
        precondition(started && state.importingAudioCount == 2)
        precondition(state.selection == active.id)
        release.signal(); release.signal()
        await state.waitForAudioImports()
        precondition(state.selection == active.id && state.text == "preserve")
        let queued = try library.list().filter { $0.queuedTranscriptionAt != nil }.sorted { $0.queuedTranscriptionAt! < $1.queuedTranscriptionAt! }
        precondition(queued.count == 2 && queued.map(\.title) == ["one", "two"])
        precondition(queued.allSatisfy { $0.status == .recorded && $0.audioFiles.count == 1 })
        let firstCopy = try Data(contentsOf: library.audioURLs(for: queued[0])[0])
        precondition(firstCopy == Data("one".utf8))
        let secondCopy = try Data(contentsOf: library.audioURLs(for: queued[1])[0])
        precondition(secondCopy == Data("two".utf8))
        precondition(FileManager.default.fileExists(atPath: first.path) && FileManager.default.fileExists(atPath: second.path))
        let reopened = try MeetingLibrary(root: root)
        let restored = try reopened.list()
        precondition(restored.filter { $0.queuedTranscriptionAt != nil }.count == 2)
        try FileManager.default.removeItem(at: library.audioURLs(for: queued[0])[0])
        state.busy = false
        state.startNextQueuedTranscription()
        let afterFailure = try library.load(queued[0].id)
        let afterNext = try library.load(queued[1].id)
        precondition(afterFailure.status == .failed && afterFailure.queuedTranscriptionAt == nil)
        precondition(afterNext.status == .recorded && afterNext.queuedTranscriptionAt != nil, "missing model pauses a valid next job")
        state.recording = true
        precondition(!state.canImportAudio)
        print("PASS: imports remain ordered and persisted during transcription; originals and active selection preserved")
    }
}
