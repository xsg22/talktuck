import Foundation
@main struct QueueRealSmoke {
 @MainActor static func main() async throws {
  let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("real-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: base) }
  let state = AppState(storageURL: base, connectionNamespace: "queue-real-" + UUID().uuidString)
  precondition(state.model != nil, "model unavailable")
  state.language = "en"
  state.useAudio(URL(fileURLWithPath: CommandLine.arguments[1])); await state.waitForAudioImports()
  let first = state.selection!
  state.transcribe(); precondition(state.busy, "first job did not start")
  state.useAudio(URL(fileURLWithPath: CommandLine.arguments[2])); await state.waitForAudioImports()
  let queued = state.history.first { $0.queuedTranscriptionAt != nil }!
  let deadline = Date().addingTimeInterval(420)
  while Date() < deadline {
   if let a = state.history.first(where: { $0.id == first }), let b = state.history.first(where: { $0.id == queued.id }),
      !state.busy && a.status == .completed && b.status == .completed {
      precondition(!a.text.isEmpty && !b.text.isEmpty && b.queuedTranscriptionAt == nil)
      print("PASS: actual ASR completed first and automatically processed queued second; both transcripts saved")
      return
   }
   if state.history.contains(where: { ($0.id == first || $0.id == queued.id) && $0.status == .failed }) { break }
   try await Task.sleep(nanoseconds: 500_000_000)
  }
  let rows = state.history.map { "\($0.id == first ? "first" : "second"):\($0.status.rawValue):queued=\($0.queuedTranscriptionAt != nil)" }.joined(separator: " ")
  print("FAIL: " + rows + " status=" + state.status)
  exit(1)
 }
}
