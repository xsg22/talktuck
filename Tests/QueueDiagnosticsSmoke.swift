import Foundation
@main struct QueueDiagnosticsSmoke {
 static func main() throws {
  let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let journal = FeedbackDiagnostics(root: root, maximumBytes: 20_000, archiveCount: 2)
  let queue = QueueDiagnostics(journal: journal, limit: 8)
  queue.emit("import-accepted", operation: "ABC12345", phase: "import", outcome: "queued", depth: 2)
  queue.emit("transcription-finished", operation: "ABC12345", phase: "recognition", outcome: "failed", depth: 1, elapsedMs: 123)
  queue.flush()
  journal.record("worker-output", "bytes", fields: ["base64": Data("private-transcript".utf8).base64EncodedString(), "error": "/private/user/path"])
  journal.record("worker-output", "capture-end", fields: ["workerID": "123", "error": "/private/user/path"])
  let data = try journal.safeSnapshot()
  let text = String(decoding: data, as: UTF8.self)
  precondition(text.contains("import-accepted") && text.contains("transcription-finished") && text.contains("failed"))
  precondition(!text.contains("base64") && !text.contains("/private/user/path") && !text.contains("private-transcript"))
  let rows = try data.split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
  precondition(rows.contains { ($0["fields"] as? [String: Any])?["operation"] as? String == "ABC12345" })
  let blocked = root.appendingPathComponent("blocked")
  try Data("x".utf8).write(to: blocked)
  let failing = QueueDiagnostics(journal: FeedbackDiagnostics(root: blocked.appendingPathComponent("no")))
  failing.emit("import-failed", operation: "ABC12345", phase: "import", outcome: "copy-or-save-failed", depth: 0)
  failing.flush()
  print("PASS: queue correlation and failure class; legacy payloads filtered; failed writes do not crash")
 }
}
