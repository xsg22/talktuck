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
        let summary = rows.first { $0["event"] as? String == "summary" }
        precondition((summary?["fields"] as? [String: Any])?["bytesCount"] as? Int == expected.count && expected.count == 200_022)
        precondition(!String(decoding: snapshot, as: UTF8.self).contains("base64"))
        journal.record("worker-output", "bytes", fields: ["base64": Data("secret-text".utf8).base64EncodedString()])
        let exported = try journal.safeSnapshot()
        precondition(!String(decoding: exported, as: UTF8.self).contains("base64"))
        let expired = try journal.snapshot(since: Date().addingTimeInterval(60))
        precondition(expired.split(separator: 10).count == 1)
        let markersURL=root.appendingPathComponent("markers.log")
        FileManager.default.createFile(atPath:markersURL.path,contents:nil)
        let markersMirror=try FileHandle(forWritingTo:markersURL)
        let markerCapture=WorkerLogCapture(mirror:markersMirror,stage:"Qwen语音定稿",journal:journal)
        let markerChild=Process();markerChild.executableURL=URL(fileURLWithPath:"/bin/sh")
        markerChild.arguments=["-c","printf 'TALKTUCK_FALLBACK attempt token_'; printf 'limit\\nTALKTUCK_FALLBACK succeeded token_limit\\nTALKTUCK_FALLBACK failed engine_unavailable\\nTALKTUCK_FALLBACK failed private-transcript\\nprivate-transcript\\n'"]
        markerChild.standardOutput=markerCapture.pipe;markerChild.standardError=markerCapture.pipe
        try markerChild.run();markerCapture.start();markerChild.waitUntilExit()
        precondition(markerCapture.waitForDrain());try markersMirror.close()
        let safe=String(decoding:try journal.safeSnapshot(),as:UTF8.self)
        precondition(safe.contains("fallback-attempt") && safe.contains("fallback-succeeded") && safe.contains("fallback-failed"))
        precondition(safe.contains("token_limit") && safe.contains("engine_unavailable") && !safe.contains("private-transcript"))
        print("PASS: bounded worker summary, mirror preserved, legacy bytes excluded from feedback")
    }
}
