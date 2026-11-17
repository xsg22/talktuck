import Foundation
import AVFoundation
import CryptoKit

/// Import transactions stage a complete private copy, then publish by a single
/// directory rename. Existing Mac records are never replaced wholesale.
@MainActor final class MacLANSyncImporter {
    enum Failure: Error { case conflict, incompleteArchive, invalidAudio, unavailable }
    private struct Baseline: Codable { let remote: LANSyncRecord; let projected: MeetingRecord }
    private struct Prepared { let directory: URL; let projected: MeetingRecord }
    private let library: MeetingLibrary
    init(library: MeetingLibrary) { self.library = library }

    func canReuseAudio(_ incoming: LANSyncRecord) async throws -> Bool {
        let target = library.directory(for: incoming.id)
        let url = target.appendingPathComponent("lan-sync-base.json")
        guard let data = try? Data(contentsOf: url), let base = try? JSONDecoder().decode(Baseline.self, from: data),
              base.remote.id == incoming.id, base.remote.audio == incoming.audio,
              base.remote.entryPoint == incoming.entryPoint,
              let current = try? library.load(incoming.id, includingHidden: true),
              current.status != .recording, current.status != .transcribing,
              current.audioFiles == base.projected.audioFiles else { return false }
        let worker = Task.detached(priority: .utility) { try Self.verifyExisting(base.remote, target: target, audioFiles: current.audioFiles) }
        do { try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() } }
        catch is CancellationError { throw CancellationError() }
        catch { return false }
        try Task.checkCancellation()
        return (try? Data(contentsOf: url)) == data && (try? library.load(incoming.id, includingHidden: true)) == current
    }

    func install(_ incoming: LANSyncRecord, files: [URL]) async throws {
        try incoming.validate()
        if files.isEmpty {
            guard FileManager.default.fileExists(atPath: library.directory(for: incoming.id).path) else { throw Failure.conflict }
            try await updateExisting(incoming, target: library.directory(for: incoming.id))
            return
        }
        guard files.count == incoming.audio.count else { throw Failure.invalidAudio }
        let verifyWorker = Task.detached(priority: .utility) {
            for (index, file) in files.enumerated() { try LANSyncIntegrity.verify(file, against: incoming.audio[index]) }
        }
        try await withTaskCancellationHandler { try await verifyWorker.value } onCancel: { verifyWorker.cancel() }
        let target = library.directory(for: incoming.id)
        if FileManager.default.fileExists(atPath: target.path) {
            try await updateExisting(incoming, target: target)
            return
        }
        guard !(try library.listTrashed().contains { $0.id == incoming.id }) else { throw Failure.conflict }
        let parent = target.deletingLastPathComponent()
        let prepareWorker = Task.detached(priority: .utility) { try Self.prepare(incoming, files: files, parent: parent) }
        let prepared = try await withTaskCancellationHandler { try await prepareWorker.value } onCancel: { prepareWorker.cancel() }
        defer { if FileManager.default.fileExists(atPath: prepared.directory.path) { try? FileManager.default.removeItem(at: prepared.directory) } }
        try Task.checkCancellation()
        // Recheck after suspension: a recording or another import may have appeared.
        guard !FileManager.default.fileExists(atPath: target.path),
              !(try library.listTrashed().contains { $0.id == incoming.id }) else { throw Failure.conflict }
        try FileManager.default.moveItem(at: prepared.directory, to: target)
        try BalancedAudioIO.syncDirectory(parent)
        // The directory already contains a valid meeting and source snapshot.
        // Agent publication is best effort and cannot undo the committed original.
        _ = try library.save(prepared.projected)
        try Self.syncFile(target.appendingPathComponent("meeting.json"))
        try BalancedAudioIO.syncDirectory(target)
    }

    private func updateExisting(_ incoming: LANSyncRecord, target: URL) async throws {
        let url = target.appendingPathComponent("lan-sync-base.json")
        guard let data = try? Data(contentsOf: url), let base = try? JSONDecoder().decode(Baseline.self, from: data),
              base.remote.id == incoming.id, base.remote.audio == incoming.audio,
              base.remote.entryPoint == incoming.entryPoint else { throw Failure.conflict }
        var local = try library.load(incoming.id, includingHidden: true)
        guard local.status != .recording, local.status != .transcribing else { throw Failure.unavailable }
        guard local.audioFiles == base.projected.audioFiles else { throw Failure.conflict }
        let before = local
        let verifyWorker = Task.detached(priority: .utility) { try Self.verifyExisting(base.remote, target: target, audioFiles: before.audioFiles) }
        try await withTaskCancellationHandler { try await verifyWorker.value } onCancel: { verifyWorker.cancel() }
        try Task.checkCancellation()
        guard try library.load(incoming.id, includingHidden: true) == before,
              (try? Data(contentsOf: url)) == data else { throw Failure.conflict }
        if incoming == base.remote { return }
        let next = Self.project(incoming, audioFiles: base.projected.audioFiles)
        local.lanTranscriptionState = next.lanTranscriptionState
        if local.status == base.projected.status && local.text == base.projected.text && local.transcriptParagraphs == base.projected.transcriptParagraphs {
            local.status = next.status
        }
        if local.title == base.projected.title { local.title = next.title }
        if local.summary == base.projected.summary { local.summary = next.summary }
        if (incoming.paragraphs != base.remote.paragraphs || incoming.transcriptOrigin != base.remote.transcriptOrigin) &&
            local.transcriptOrigin == base.projected.transcriptOrigin && local.text == base.projected.text && local.transcriptParagraphs == base.projected.transcriptParagraphs &&
            local.speakerNames == base.projected.speakerNames && local.customSpeakerNameIDs == base.projected.customSpeakerNameIDs &&
            local.speakerAliases == base.projected.speakerAliases {
            local.text = next.text; local.transcriptParagraphs = next.transcriptParagraphs
            local.speakerNames = next.speakerNames; local.customSpeakerNameIDs = next.customSpeakerNameIDs
            local.transcriptOrigin = next.transcriptOrigin
        }
        // Save local first. If the following sidecar write fails, retry detects
        // a conservative conflict instead of treating unsaved state as a base.
        _ = try library.save(local)
        try Self.syncFile(target.appendingPathComponent("meeting.json"))
        try BalancedAudioIO.syncDirectory(target)
        let newBase = Baseline(remote: incoming, projected: next)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(newBase).write(to: url, options: .atomic)
        try Self.syncFile(url)
        try BalancedAudioIO.syncDirectory(target)
    }

    private nonisolated static func verifyExisting(_ input: LANSyncRecord, target: URL, audioFiles: [String]) throws {
        guard !audioFiles.isEmpty else { throw Failure.invalidAudio }
        if input.entryPoint == ["final.manifest.json"] {
            let folder = target.appendingPathComponent("Capture").appendingPathComponent(input.id.uuidString)
            for item in input.audio {
                var path = folder
                for component in item.components { path.appendPathComponent(component) }
                try LANSyncIntegrity.verify(path, against: item)
            }
        } else {
            guard input.audio.count == audioFiles.count else { throw Failure.invalidAudio }
            for (item, name) in zip(input.audio, audioFiles) {
                let file = try MeetingLibrary.managedAudioURL(name, in: target)
                try LANSyncIntegrity.verify(file, against: item)
            }
        }
    }

    private nonisolated static func syncFile(_ url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
    }

    private nonisolated static func project(_ input: LANSyncRecord, audioFiles: [String]) -> MeetingRecord {
        var result = MeetingRecord(id: input.id, title: input.title, created: input.createdAt,
            text: "", language: input.language, duration: Double(input.durationMs) / 1000,
            summary: input.summary, audioFiles: audioFiles,
            status: ["ready", "noSpeech"].contains(input.transcriptionState ?? (input.paragraphs.isEmpty ? "notRequested" : "ready")) ? .completed : .recorded)
        result.source = RecordingOrigin(rawValue: input.source) ?? .unknown
        result.transcriptOrigin = TranscriptionOrigin(rawValue: input.transcriptOrigin) ?? .notGenerated
        result.lanTranscriptionState = input.transcriptionState ?? (input.paragraphs.isEmpty ? "notRequested" : "ready")
        if audioFiles.count == input.audio.count {
            for (name, part) in zip(audioFiles, input.audio) {
                if let ms = part.durationMs { result.audioDurations[name] = Double(ms) / 1000 }
            }
        }
        var speakers: [String: String] = [:], names: [String: String] = [:]
        result.transcriptParagraphs = input.paragraphs.enumerated().map { number, row in
            let fallback = row.speakers.isEmpty ? row.speaker.map { name -> String in
                if let old = speakers[name] { return old }
                let hash = SHA256.hash(data: Data((input.id.uuidString + ":" + name).utf8))
                let bytes = Array(hash.prefix(16))
                let key = UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15])).uuidString
                speakers[name] = key; names[key] = name; return key
            } : nil
            let speakerIDs = row.speakers.isEmpty ? (fallback.map { [$0] } ?? []) : row.speakers.map { item in
                let key = item.id.uuidString; names[key] = item.name; return key
            }
            let index: Int? = {
                if audioFiles.count == 1 { return 0 }
                guard let start = row.startMs else { return nil }
                return input.audio.indices.last { index in
                    guard let begin = input.audio[index].timelineStartMs, let duration = input.audio[index].durationMs else { return false }
                    return begin <= start && start < begin + duration
                }
            }()
            let audioFile = index.flatMap { audioFiles.indices.contains($0) ? audioFiles[$0] : nil }
            let localStart = row.startMs.flatMap { start -> Double? in
                guard let index else { return nil }
                let offset = audioFiles.count == 1 ? 0 : (input.audio[index].timelineStartMs ?? 0)
                return Double(start - offset) / 1000
            }
            return TranscriptParagraph(id: row.id, text: row.text, separator: row.separator ?? (number == 0 ? "" : "\n"),
                start: row.startMs.map { Double($0) / 1000 }, end: row.endMs.map { Double($0) / 1000 },
                audioFile: audioFile, speakerIDs: speakerIDs, localStart: localStart)
        }
        result.text = result.paragraphText; result.speakerNames = names; result.customSpeakerNameIDs = Set(names.keys)
        return result
    }

    private nonisolated static func prepare(_ input: LANSyncRecord, files: [URL], parent: URL) throws -> Prepared {
        let manager = FileManager.default
        let work = parent.appendingPathComponent(".lan-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var complete = false
        defer { if !complete { try? manager.removeItem(at: work) } }
        var entries: [String] = []
        if input.entryPoint == ["final.manifest.json"] {
            guard let manifestIndex = input.audio.firstIndex(where: { $0.components == input.entryPoint }) else { throw Failure.incompleteArchive }
            let size = try files[manifestIndex].resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 32 * 1024 * 1024 else { throw Failure.incompleteArchive }
            let data = try Data(contentsOf: files[manifestIndex])
            let manifest = try JSONDecoder().decode(BalancedRecordingManifest.self, from: data)
            try manifest.validate()
            guard manifest.recordingID == input.id, manifest.segmentCount + 1 == input.audio.count else { throw Failure.incompleteArchive }
            let expected = Dictionary(uniqueKeysWithValues: manifest.streams.flatMap { stream in stream.segments.map { ([stream.streamID, $0.filename].joined(separator: "/"), $0) } })
            for part in input.audio where part.components != input.entryPoint {
                guard let descriptor = expected[part.components.joined(separator: "/")], descriptor.sha256 == part.sha256,
                      descriptor.byteCount == part.byteCount else { throw Failure.incompleteArchive }
            }
            let folder = work.appendingPathComponent("Capture").appendingPathComponent(input.id.uuidString)
            var directories = Set<URL>()
            for (index, part) in input.audio.enumerated() {
                try Task.checkCancellation()
                var destination = folder
                for component in part.components { destination.appendPathComponent(component) }
                try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try LANSyncIntegrity.verify(files[index], against: part)
                try manager.copyItem(at: files[index], to: destination)
                try LANSyncIntegrity.verify(destination, against: part)
                try syncFile(destination)
                directories.insert(destination.deletingLastPathComponent())
                if part.components != input.entryPoint, let segment = expected[part.components.joined(separator: "/")] {
                    try BalancedAudioIO.validateFile(destination, segment: segment)
                }
            }
            for directory in directories.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
                try BalancedAudioIO.syncDirectory(directory)
            }
            try BalancedAudioIO.syncDirectory(work.appendingPathComponent("Capture"))
            entries = ["capture_" + input.id.uuidString + ".aacarchive"]
        } else {
            guard input.entryPoint == input.audio.first?.components else { throw Failure.invalidAudio }
            let folder = work.appendingPathComponent("Audio", isDirectory: true)
            try manager.createDirectory(at: folder, withIntermediateDirectories: false)
            var lastEnd = 0
            for (index, part) in input.audio.enumerated() {
                try Task.checkCancellation()
                guard part.components.count == 1 else { throw Failure.invalidAudio }
                let suffix = URL(fileURLWithPath: part.components[0]).pathExtension.lowercased()
                guard !suffix.isEmpty, suffix.count <= 12, suffix.allSatisfy({ $0.isLetter || $0.isNumber }) else { throw Failure.invalidAudio }
                if input.audio.count > 1 {
                    guard let start = part.timelineStartMs, let duration = part.durationMs, start >= lastEnd else { throw Failure.invalidAudio }
                    lastEnd = start + duration
                }
                let name = "iphone-" + UUID().uuidString + "." + suffix
                let destination = folder.appendingPathComponent(name)
                try LANSyncIntegrity.verify(files[index], against: part)
                try manager.copyItem(at: files[index], to: destination)
                try LANSyncIntegrity.verify(destination, against: part)
                try syncFile(destination)
                let audio = try AVAudioFile(forReading: destination)
                guard audio.length > 0, audio.processingFormat.sampleRate > 0 else { throw Failure.invalidAudio }
                entries.append(name)
            }
            try BalancedAudioIO.syncDirectory(folder)
        }
        let projected = project(input, audioFiles: entries)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(projected).write(to: work.appendingPathComponent("meeting.json"), options: .atomic)
        try encoder.encode(Baseline(remote: input, projected: projected)).write(to: work.appendingPathComponent("lan-sync-base.json"), options: .atomic)
        try syncFile(work.appendingPathComponent("meeting.json"))
        try syncFile(work.appendingPathComponent("lan-sync-base.json"))
        try BalancedAudioIO.syncDirectory(work)
        complete = true
        return Prepared(directory: work, projected: projected)
    }
}
