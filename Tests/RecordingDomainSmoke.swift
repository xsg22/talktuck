import Foundation

@main struct RecordingDomainSmoke {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("recording-domain-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let library = try MeetingLibrary(root:root)
        let local = MeetingRecord(title:"local final",text:"confirmed local ASR")
        _ = try library.save(local)
        precondition(local.canSelectFinalForSync && local.stateModel.localTranscription == .ready)
        let state = RecordingStateModel(origin:.watch,capture:.finished,localTranscription:.ready,remoteTranscription:.notRequested,transfer:.sending,audio:.unverified)
        precondition(state.presentation == .syncing)
        let decoded = try JSONDecoder().decode(RecordingStateModel.self,from:JSONEncoder().encode(state))
        precondition(decoded == state)
        let restored = try library.load(local.id)
        precondition(restored.text == local.text && restored.transcriptOrigin == .local)
        print("PASS: local state, Watch transfer and legacy record round-trip")
    }
}
