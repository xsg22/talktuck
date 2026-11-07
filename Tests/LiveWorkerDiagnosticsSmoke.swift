import Foundation

final class DiagnosticEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var types: [String] = []
    func add(_ event: LiveTranscriptEvent) { lock.lock(); types.append(event.type); lock.unlock() }
    func contains(_ type: String) -> Bool { lock.lock(); defer { lock.unlock() }; return types.contains(type) }
}

@main struct LiveWorkerDiagnosticsSmoke {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("worker.sh")
        let source = """
        printf 'worker-diagnostic\\n' >&2
        printf '{"type":"partial","text":"synthetic words","start":0,"end":1}\\n'
        cat >/dev/null
        printf '{"type":"done","text":"","start":0,"end":1}\\n'
        """
        try Data(source.utf8).write(to: script)
        let journal = FeedbackDiagnostics(root: root.appendingPathComponent("journal"))
        let session = LiveTranscriptionSession(workerJournal: journal)
        let events = DiagnosticEvents(); session.onEvent = { events.add($0) }
        try session.start(model: script, executable: URL(fileURLWithPath: "/bin/sh"), language: "zh")
        session.append([Float](repeating: 0, count: 32))
        await session.finish()
        precondition(events.contains("partial") && events.contains("done"))
        let rows = try journal.snapshot().split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
        let data = rows.reduce(into: Data()) { result, row in
            if let fields = row["fields"] as? [String: Any], let encoded = fields["base64"] as? String,
               let bytes = Data(base64Encoded: encoded) { result.append(bytes) }
        }
        precondition(String(decoding: data, as: UTF8.self).contains("worker-diagnostic"))
        precondition(!String(decoding: data, as: UTF8.self).contains("synthetic words"))
        print("PASS: live transcript protocol remains intact; worker stderr enters the feedback journal")
    }
}
