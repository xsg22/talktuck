import Foundation

@main struct WorkerLogCaptureSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let journal = FeedbackDiagnostics(root: root.appendingPathComponent("journal"))
        let logURL = root.appendingPathComponent("mirror.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let mirror = try FileHandle(forWritingTo: logURL)
        let capture = WorkerLogCapture(mirror: mirror, stage: "smoke", journal: journal)
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "printf stdout-test; printf stderr-test >&2; head -c 200000 /dev/zero | tr '\\0' x"]
        child.standardOutput = capture.pipe; child.standardError = capture.pipe
        try child.run(); capture.start(); child.waitUntilExit()
        precondition(child.terminationStatus == 0 && capture.waitForDrain())
        try mirror.close()
        let expected = try Data(contentsOf: logURL)
        let snapshot = try journal.snapshot()
        let rows = try snapshot.split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
        let reconstructed = rows.dropFirst().reduce(into: Data()) { result, row in
            if let fields = row["fields"] as? [String: Any], let encoded = fields["base64"] as? String,
               let bytes = Data(base64Encoded: encoded) { result.append(bytes) }
        }
        precondition(expected == reconstructed && expected.count == 200_022)
        let expired = try journal.snapshot(since: Date().addingTimeInterval(60))
        precondition(expired.split(separator: 10).count == 1)
        print("PASS: complete stdout/stderr capture, large output, mirror and time boundary")
    }
}
