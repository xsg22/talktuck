import Foundation

@main struct OfflineProgressSmoke {
    final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [OfflineRecognitionProgress] = []
        func put(_ value: OfflineRecognitionProgress) { lock.lock(); values.append(value); lock.unlock() }
        func all() -> [OfflineRecognitionProgress] { lock.lock(); defer { lock.unlock() }; return values }
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("progress-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = Capture()
        let reader = OfflineProgressReader(directory: root, windows: [(0, 160000), (144000, 304000)], total: 30, notify: { capture.put($0) })
        reader.start()
        func write(_ index: Int, _ start: Double, _ end: Double, _ text: String) throws {
            let data = try JSONSerialization.data(withJSONObject: ["index": index, "start": start, "end": end, "text": text, "fallback": false, "truncated": false])
            try data.write(to: root.appendingPathComponent(String(format: "%08d.json", index)), options: .atomic)
        }
        try write(1, 9, 19, "second")
        try await Task.sleep(for: .milliseconds(650))
        precondition(capture.all().isEmpty, "out of order results must not advance progress")
        try write(0, 0, 10, "first")
        try await Task.sleep(for: .milliseconds(650))
        let values = capture.all()
        precondition(values.count == 2 && values[0].processedSeconds == 10 && values[1].processedSeconds == 19)
        precondition(values[1].preview == "first\nsecond" && values[1].totalSeconds == 30)
        try Data().write(to: root.appendingPathComponent("unavailable"))
        try await Task.sleep(for: .milliseconds(650))
        precondition(capture.all().last?.unavailable == true && capture.all().last?.preview == "first\nsecond")
        reader.finish()
        print("PASS: preview is ordered and progress follows actual recognized audio timestamps")
    }
}
