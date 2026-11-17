import Foundation
import CryptoKit

// Versioned independently from either app's persisted recording model.
// File paths on the receiving device are constructed locally from these components.
struct LANSyncSpeaker: Codable, Equatable {
    let id: UUID
    let name: String
}
struct LANSyncParagraph: Codable, Equatable {
    var id: UUID = UUID()
    let text: String
    let startMs: Int?
    let endMs: Int?
    let speaker: String?
    var separator: String? = nil
    var speakers: [LANSyncSpeaker] = []
}

struct LANSyncFile: Codable, Equatable {
    let components: [String]
    let byteCount: Int64
    let sha256: String
    var timelineStartMs: Int? = nil
    var durationMs: Int? = nil
}

struct LANSyncRecord: Codable, Equatable {
    let schemaVersion: Int
    let id: UUID
    let title: String
    let createdAt: Date
    let durationMs: Int
    let language: String
    let paragraphs: [LANSyncParagraph]
    let summary: String?
    /// Either an ordinary audio file or a final manifest plus all of its original segments.
    let audio: [LANSyncFile]
    let entryPoint: [String]
    var source: String = "iphone"
    var transcriptOrigin: String = "local"
    var transcriptionState: String? = nil

    func validate() throws {
        guard schemaVersion == 1, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 4096, language.utf8.count <= 64,
              ["iphone", "watch", "macos", "imported", "unknown"].contains(source),
              ["local", "remote", "notGenerated"].contains(transcriptOrigin),
              (transcriptionState == nil || ["notRequested", "queued", "processing", "ready", "noSpeech", "failed", "needsModel", "interrupted"].contains(transcriptionState!)),
              durationMs >= 0, paragraphs.count <= 100_000, Set(paragraphs.map(\.id)).count == paragraphs.count,
              (summary?.utf8.count ?? 0) <= 8 * 1024 * 1024,
              !audio.isEmpty, audio.count <= 100_001 else { throw LANSyncFailure.invalidManifest }
        var names = Set<String>()
        for file in audio {
            guard Self.safeComponents(file.components), file.byteCount > 0,
                  file.sha256.utf8.count == 64,
                  file.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  ((file.timelineStartMs == nil && file.durationMs == nil) ||
                   (file.timelineStartMs != nil && file.durationMs != nil && file.timelineStartMs! >= 0 && file.durationMs! > 0 &&
                    file.timelineStartMs! <= Int.max - file.durationMs!)),
                  names.insert(file.components.joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw LANSyncFailure.invalidManifest }
        }
        guard Self.safeComponents(entryPoint), audio.contains(where: { $0.components == entryPoint }) else { throw LANSyncFailure.invalidManifest }
        for paragraph in paragraphs {
            guard paragraph.text.utf8.count <= 1024 * 1024, (paragraph.speaker?.utf8.count ?? 0) <= 4096,
                  (paragraph.separator?.utf8.count ?? 0) <= 4096, paragraph.speakers.count <= 16,
                  Set(paragraph.speakers.map(\.id)).count == paragraph.speakers.count,
                  paragraph.speakers.allSatisfy({ $0.name.utf8.count <= 4096 }),
                  (paragraph.startMs == nil && paragraph.endMs == nil) ||
                  (paragraph.startMs != nil && paragraph.endMs != nil && paragraph.startMs! >= 0 && paragraph.endMs! >= paragraph.startMs!) else {
                throw LANSyncFailure.invalidManifest
            }
        }
    }

    static func safeComponents(_ components: [String]) -> Bool {
        !components.isEmpty && components.count <= 4 && components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 128 &&
            !$0.contains("/") && !$0.contains("\\") && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }
    }
}

enum LANSyncFailure: Error { case invalidManifest, invalidFile, integrity }

enum LANSyncIntegrity {
    static func stableID(_ value: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    /// Incremental hashing keeps memory bounded for long recordings.
    static func digest(_ url: URL) throws -> (sha256: String, byteCount: Int64) {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard url.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true else { throw LANSyncFailure.invalidFile }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256(), count: Int64 = 0
        while let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            try Task.checkCancellation()
            guard count <= Int64.max - Int64(bytes.count) else { throw LANSyncFailure.invalidFile }
            count += Int64(bytes.count)
            hash.update(data: bytes)
        }
        guard count > 0 else { throw LANSyncFailure.invalidFile }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), count)
    }

    static func verify(_ url: URL, against expected: LANSyncFile) throws {
        let actual = try digest(url)
        guard actual.byteCount == expected.byteCount, actual.sha256 == expected.sha256 else { throw LANSyncFailure.integrity }
    }
}
