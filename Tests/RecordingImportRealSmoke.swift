import AppKit
import Foundation

/// Exercise the real capture, import queue and local ASR without microphone access.
@main struct RecordingImportRealSmoke {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("capture-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try MeetingLibrary(root: root)
        let active = try library.save(MeetingRecord(title: "synthetic capture", status: .recording))
        let capture = MeetingRecorder()
        try await capture.start(sources: .muted, directory: library.directory(for: active.id).appendingPathComponent("Capture"))
        let state = AppState(storageURL: root, connectionNamespace: UUID().uuidString, recorder: capture)
        precondition(state.model != nil, "model unavailable")
        state.language = "en"; state.select(active.id); state.bindRecordingContext(to: active.id)
        state.recording = true; state.liveEnabled = false
        state.useAudio(URL(fileURLWithPath: CommandLine.arguments[1])); state.useAudio(URL(fileURLWithPath: CommandLine.arguments[2]))
        await state.waitForAudioImports()
        let queued = state.history.filter { $0.queuedTranscriptionAt != nil }
        precondition(queued.count == 2 && state.recording && capture.state == .recording && state.selection == active.id)
        try await Task.sleep(for: .milliseconds(300))
        state.toggleRecording()
        let deadline = Date().addingTimeInterval(420)
        while Date() < deadline {
            let rows = queued.compactMap { queuedItem in state.history.first { $0.id == queuedItem.id } }
            if rows.count == 2 && rows.allSatisfy({ $0.status == .completed && $0.queuedTranscriptionAt == nil && !$0.text.isEmpty }) && !state.busy && !state.recording {
                let saved = try library.load(active.id)
                precondition(!saved.audioFiles.isEmpty && saved.duration > 0)
                precondition(state.selection == active.id, "import changed selection")
                print("PASS: muted capture continues during two imports; captured audio is saved and both queued files complete using actual ASR")
                return
            }
            if rows.contains(where: { $0.status == .failed }) { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        print("FAIL: imported jobs did not both complete after capture stopped")
        exit(1)
    }
}
