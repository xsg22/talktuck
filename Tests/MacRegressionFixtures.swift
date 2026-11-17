import Foundation
import AVFoundation

/// Synthetic data for the existing CLI/MCP assertions. Never loads a user library.
@main struct AgentCLIFixture {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let library = try MeetingLibrary(root: root)
        var record = MeetingRecord(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                                   title: "CLI fixture", text: "你好，世界！", duration: 1,
                                   notes: "旧笔记", summary: "旧总结", status: .completed, previewText: "Synthetic live preview")
        let directory = library.directory(for: record.id).appendingPathComponent("Audio")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fixture.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
        buffer.frameLength = 16000
        memset(buffer.floatChannelData![0], 0, 16000 * MemoryLayout<Float>.size)
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        record.audioFiles = [url.lastPathComponent]; record.audioDurations = [url.lastPathComponent: 1]
        _ = try library.save(record)
        let published = try AgentReadStore(root: root.appendingPathComponent("AgentData")).read(record.id)
        precondition(published.ready)
        print("PASS: isolated CLI fixture prepared")
    }
}
