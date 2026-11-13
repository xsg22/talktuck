import Foundation
import Combine
import CryptoKit

struct LibraryAudioPart: Codable, Equatable, Identifiable {
    var id: UUID; var recordingId: UUID; var sha256: String; var byteLength: Int
    var mimeType: String; var durationMs: Int; var timelineStartMs: Int
    var fileExtension: String { ["audio/mp4":"m4a","audio/wav":"wav","audio/mpeg":"mp3","audio/aiff":"aiff","audio/x-caf":"caf"][mimeType] ?? "bin" }
}
struct LibraryAudioManifest: Codable, Equatable { var recordingId: UUID; var version: Int; var parts: [LibraryAudioPart] }
// Retain exact downloaded originals even when iPhone needs a derived file for multipart playback.
struct LibraryAudioArchive: Codable, Equatable { var manifest: LibraryAudioManifest; var filenames: [String] }
