import Foundation

/// Run inside an isolated app bundle with synthetic fixtures and installed ASR resources.
@main struct QueueRetryRealSmoke {
 @MainActor static func main() async throws {
  let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
  let invalid = URL(fileURLWithPath: CommandLine.arguments[2])
  let valid = URL(fileURLWithPath: CommandLine.arguments[3])
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  QueueDiagnostics.shared.flush()
  let baselineCount = try FeedbackDiagnostics.shared.safeSnapshot().split(separator: 10).count
  let state = AppState(storageURL: root, connectionNamespace: "queue-retry-" + UUID().uuidString)
  guard state.model != nil else { fatalError("ASR model unavailable") }
  state.language = "en"
  state.useAudio(invalid); await state.waitForAudioImports()
  guard let id = state.selection else { fatalError("fixture import failed") }
  state.transcribe()
  let firstDeadline = Date().addingTimeInterval(120)
  while state.busy && Date() < firstDeadline { try await Task.sleep(nanoseconds: 200_000_000) }
  guard !state.busy, let failed = state.current, failed.status == .failed, state.errorRetry != nil else { fatalError("missing retryable failure") }
  let library = try MeetingLibrary(root: root)
  let managed = try library.audioURLs(for: failed)[0]
  try FileManager.default.removeItem(at: managed)
  try FileManager.default.copyItem(at: valid, to: managed)
  state.select(id, saveCurrent: false)
  state.retryLastError()
  guard state.busy else { fatalError("retry did not start") }
  let deadline = Date().addingTimeInterval(300)
  while state.busy && Date() < deadline { try await Task.sleep(nanoseconds: 250_000_000) }
  guard !state.busy, let result = state.current, result.status == .completed, !result.text.isEmpty else { fatalError("retry did not complete") }
  QueueDiagnostics.shared.flush()
  let exported = try FeedbackDiagnostics.shared.safeSnapshot()
  let rows = try exported.split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
  let events = rows.dropFirst(baselineCount).filter { $0["component"] as? String == "import-queue" }
  let outcomes = events.compactMap { ($0["fields"] as? [String: Any])?["outcome"] as? String }
  precondition(outcomes.contains("failed") && outcomes.contains("retry") && outcomes.contains("success"))
  let failedOperation = events.first { ($0["fields"] as? [String: Any])?["outcome"] as? String == "failed" }.flatMap { ($0["fields"] as? [String: Any])?["operation"] as? String }
  let retryOperation = events.first { ($0["fields"] as? [String: Any])?["outcome"] as? String == "retry" }.flatMap { ($0["fields"] as? [String: Any])?["operation"] as? String }
  precondition(failedOperation != nil && failedOperation == retryOperation)
  let text = String(decoding: exported, as: UTF8.self)
  precondition(!text.contains(root.path) && !text.contains(result.text) && !text.contains("base64"))
  print("PASS: real ASR failure, same-record retry, completion, structured outcomes and redacted feedback")
 }
}
