import Foundation
import AVFoundation

@main struct LANImportSmoke {
    @MainActor static func main() async throws {
        guard let path = ProcessInfo.processInfo.environment["LAN_SYNC_TEST_ROOT"] else { fatalError("explicit test root required") }
        let root = URL(fileURLWithPath: path).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = root.appendingPathComponent("synthetic.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let samples = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        samples.frameLength = 16_000
        for i in 0..<16_000 { samples.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 16_000)) * 0.1 }
        do { let writer = try AVAudioFile(forWriting: audio, settings: format.settings); try writer.write(from: samples) }
        let hash = try LANSyncIntegrity.digest(audio)
        let part = LANSyncFile(components: ["audio.wav"], byteCount: hash.byteCount, sha256: hash.sha256)
        let id = UUID(), paragraphID = UUID(), date = Date()
        func value(title: String, text: String) -> LANSyncRecord {
            LANSyncRecord(schemaVersion: 1, id: id, title: title, createdAt: date, durationMs: 100,
                language: "zh", paragraphs: [LANSyncParagraph(id: paragraphID, text: text, startMs: 0, endMs: 100, speaker: nil)],
                summary: "summary", audio: [part], entryPoint: ["audio.wav"])
        }
        let library = try MeetingLibrary(root: root.appendingPathComponent("library"), publishAgentDataOnInit: false)
        let importer = MacLANSyncImporter(library: library)
        let first = value(title: "phone title", text: "first")
        try await importer.install(first, files: [audio])
        var local = try library.load(id)
        precondition(local.text == "first" && local.title == "phone title")
        local.title = "Mac edited title"; _ = try library.save(local)
        try await importer.install(value(title: "new phone title", text: "updated"), files: [audio])
        local = try library.load(id)
        precondition(local.title == "Mac edited title" && local.text == "updated")
        try await importer.install(value(title: "new phone title", text: "updated"), files: [audio])
        let listed = try library.list()
        precondition(listed.count == 1)
        local.text = "Mac edited text"; _ = try library.save(local)
        try await importer.install(value(title: "third phone title", text: "third phone text"), files: [audio])
        local = try library.load(id)
        precondition(local.title == "Mac edited title" && local.text == "Mac edited text")
        let bad = root.appendingPathComponent("bad.wav")
        try Data("not audio".utf8).write(to: bad)
        let badHash = try LANSyncIntegrity.digest(bad)
        let badPart = LANSyncFile(components: ["audio.wav"], byteCount: badHash.byteCount, sha256: badHash.sha256)
        let badRecord = LANSyncRecord(schemaVersion: 1, id: UUID(), title: "bad", createdAt: date, durationMs: 100,
            language: "zh", paragraphs: [], summary: nil, audio: [badPart], entryPoint: ["audio.wav"])
        do { try await importer.install(badRecord, files: [bad]); fatalError("unplayable audio accepted") } catch { }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: library.directory(for: id).deletingLastPathComponent().path)
        precondition(!remaining.contains { $0.hasPrefix(".lan-") })
        let multiID = UUID()
        let partA = LANSyncFile(components: ["part-00000.wav"], byteCount: hash.byteCount, sha256: hash.sha256, timelineStartMs: 0, durationMs: 1000)
        let partB = LANSyncFile(components: ["part-00001.wav"], byteCount: hash.byteCount, sha256: hash.sha256, timelineStartMs: 1500, durationMs: 1000)
        let one = LANSyncSpeaker(id: UUID(), name: "A"), two = LANSyncSpeaker(id: UUID(), name: "B")
        let multi = LANSyncRecord(schemaVersion: 1, id: multiID, title: "Multipart", createdAt: date, durationMs: 2500,
            language: "zh", paragraphs: [LANSyncParagraph(text: "second", startMs: 1600, endMs: 1800, speaker: nil, separator: " ", speakers: [one, two])],
            summary: nil, audio: [partA, partB], entryPoint: partA.components)
        try await importer.install(multi, files: [audio, audio])
        let multiRecord = try library.load(multiID)
        precondition(multiRecord.audioFiles.count == 2 && multiRecord.transcriptParagraphs.first?.audioFile == multiRecord.audioFiles[1])
        precondition(abs((multiRecord.transcriptParagraphs.first?.localStart ?? -1) - 0.1) < 0.0001)
        precondition(multiRecord.text == " second" && multiRecord.transcriptParagraphs.first?.speakerIDs == [one.id.uuidString, two.id.uuidString])
        try Data("tampered".utf8).write(to: audio)
        do { try await importer.install(first, files: [audio]); fatalError("tampered audio accepted") } catch { }
        let final = try library.load(id)
        precondition(final.title == "Mac edited title")

        let segmentedID = UUID(), segmentURL = root.appendingPathComponent("segment.m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
        do { let writer = try AVAudioFile(forWriting: segmentURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false); try writer.write(from: samples) }
        let decodedAudio = try AVAudioFile(forReading: segmentURL)
        let segmentHash = try LANSyncIntegrity.digest(segmentURL)
        let segment = BalancedAudioSegment(recordingID: segmentedID, streamID: "watch", index: 0, startFrame: 0,
            validFrames: decodedAudio.length, byteCount: segmentHash.byteCount, sha256: segmentHash.sha256)
        let manifest = BalancedRecordingManifest(recordingID: segmentedID, streams: [BalancedAudioStream(streamID: "watch", startFrame: 0, segments: [segment])])
        let manifestURL = root.appendingPathComponent("final.manifest.json")
        try manifest.canonicalData().write(to: manifestURL)
        let manifestHash = try LANSyncIntegrity.digest(manifestURL)
        let manifestPart = LANSyncFile(components: ["final.manifest.json"], byteCount: manifestHash.byteCount, sha256: manifestHash.sha256)
        let segmentPart = LANSyncFile(components: ["watch", "00000000.m4a"], byteCount: segmentHash.byteCount, sha256: segmentHash.sha256)
        var segmented = LANSyncRecord(schemaVersion: 1, id: segmentedID, title: "Watch fixture", createdAt: date,
            durationMs: 1000, language: "zh", paragraphs: [], summary: nil,
            audio: [manifestPart, segmentPart], entryPoint: ["final.manifest.json"])
        segmented.source = "watch"; segmented.transcriptOrigin = "notGenerated"
        try await importer.install(segmented, files: [manifestURL, segmentURL])
        let segmentedRecord = try library.load(segmentedID)
        precondition(segmentedRecord.source == .watch && segmentedRecord.transcriptOrigin == .notGenerated)
        let manifestOnMac = try library.audioURLs(for: segmentedRecord)[0]
        let reader = try CanonicalAudioReader(manifestURL: manifestOnMac)
        let window = try reader.read(startFrame: 0, count: 100)
        precondition(window.frameLength == 100)
        print("LAN import checks passed")
    }
}
