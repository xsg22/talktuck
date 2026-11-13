import Foundation
import Combine
import CryptoKit

// Kept only for decoding and identifying data saved by older versions.
enum LibrarySyncError: Error { case invalidData }

// Shared verbatim with the Mac client. Wire v1 is a text-only projection, not a native archive.
struct LibrarySyncSpeaker: Codable, Equatable { var id: UUID; var name: String }
struct LibrarySyncParagraph: Codable, Equatable {
    var id: UUID; var text: String; var separator: String
    var startMs: Int?; var endMs: Int?; var speakerIds: [UUID]
    enum CodingKeys: String, CodingKey { case id, text, separator, startMs, endMs, speakerIds }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(text, forKey: .text); try c.encode(separator, forKey: .separator)
        try c.encode(startMs, forKey: .startMs); try c.encode(endMs, forKey: .endMs); try c.encode(speakerIds, forKey: .speakerIds)
    }
}
struct LibrarySyncRecording: Codable, Equatable {
    var id: UUID; var title: String; var createdAt: String; var durationMs: Int?
    var source: String; var language: String; var isStarred: Bool; var groupId: UUID?
    var speakers: [LibrarySyncSpeaker]; var paragraphs: [LibrarySyncParagraph]
    var transcriptOrigin: TranscriptionOrigin? = nil
    var formalOrigin: TranscriptionOrigin { paragraphs.isEmpty ? .notGenerated : (transcriptOrigin ?? .remote) }
    enum CodingKeys: String, CodingKey { case id,title,createdAt,durationMs,source,language,isStarred,groupId,speakers,paragraphs,transcriptOrigin }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,forKey:.id);try c.encode(title,forKey:.title);try c.encode(createdAt,forKey:.createdAt)
        try c.encode(durationMs,forKey:.durationMs);try c.encode(source,forKey:.source);try c.encode(language,forKey:.language)
        try c.encode(isStarred,forKey:.isStarred);try c.encode(groupId,forKey:.groupId)
        try c.encode(speakers,forKey:.speakers);try c.encode(paragraphs,forKey:.paragraphs)
        try c.encodeIfPresent(transcriptOrigin,forKey:.transcriptOrigin)
    }
    var text: String { paragraphs.map { $0.separator + $0.text }.joined() }
}
struct LibrarySyncGroup: Codable, Equatable { var id: UUID; var name: String }
enum LibrarySyncKind: String, Codable { case group, recording }
struct LibrarySyncValue: Codable, Equatable {
    var group: LibrarySyncGroup?; var recording: LibrarySyncRecording?
    enum CodingKeys: String, CodingKey { case group, recording }
    init(group: LibrarySyncGroup?, recording: LibrarySyncRecording?) { self.group = group; self.recording = recording }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        group = try c.decodeIfPresent(LibrarySyncGroup.self, forKey:.group)
        recording = try c.decodeIfPresent(LibrarySyncRecording.self, forKey:.recording)
        guard (group == nil) != (recording == nil) else { throw LibrarySyncError.invalidData }
    }
    var id: UUID { group?.id ?? recording!.id }
    var kind: LibrarySyncKind { group == nil ? .recording : .group }
    var key: String { Self.key(kind, id) }
    static func key(_ kind: LibrarySyncKind, _ id: UUID) -> String { kind.rawValue + ":" + id.uuidString.lowercased() }
    static func group(_ group: LibrarySyncGroup) -> Self { Self(group: group, recording: nil) }
    static func recording(_ record: LibrarySyncRecording) -> Self { Self(group: nil, recording: record) }
}
struct LibrarySyncAccess { var server: URL; var token: String; var userId: UUID }
