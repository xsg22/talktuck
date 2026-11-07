import Foundation

@main struct FeedbackDiagnosticsRecoverySmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let journal = FeedbackDiagnostics(root: root)
        journal.record("worker-output", "capture-start", fields: ["workerID": "fixture"])
        let active = try journal.snapshot()
        let first = try JSONSerialization.jsonObject(with: Data(active.split(separator: 10)[0])) as! [String: Any]
        let activeFields = first["fields"] as! [String: Any]
        precondition(activeFields["possiblyTruncated"] as? Bool == true)
        precondition(activeFields["incompleteWorkerCaptures"] as? Int == 1)
        journal.record("worker-output", "capture-end", fields: ["workerID": "fixture"])
        let clean = try journal.snapshot()
        let cleanFields = (try JSONSerialization.jsonObject(with: Data(clean.split(separator: 10)[0])) as! [String: Any])["fields"] as! [String: Any]
        precondition(cleanFields["possiblyTruncated"] as? Bool == false)
        let file = try FileHandle(forWritingTo: root.appendingPathComponent("events.jsonl"))
        try file.seekToEnd(); try file.write(contentsOf: Data("{partial".utf8)); try file.close()
        let damaged = try journal.snapshot()
        let damagedFields = (try JSONSerialization.jsonObject(with: Data(damaged.split(separator: 10)[0])) as! [String: Any])["fields"] as! [String: Any]
        precondition(damagedFields["possiblyTruncated"] as? Bool == true && damagedFields["damagedLogData"] as? Bool == true)
        precondition(damaged.split(separator: 10).count == 3)
        print("PASS: unfinished captures and damaged tail marked, intact records preserved")
    }
}
