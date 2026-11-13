import Foundation

/// A single untrusted transfer is staged outside the visible recording library.
/// The receiver allocates every filename and checks all bytes before publication.
final class LANSyncStaging {
    enum Failure: Error { case invalidState, invalidChunk, alreadyExists, insufficientSpace }
    static let maximumChunkBytes = 48 * 1024
    let record: LANSyncRecord
    let directory: URL
    private(set) var index = 0
    private(set) var offset: Int64 = 0
    private var handle: FileHandle?

    init(root: URL, record: LANSyncRecord) throws {
        try record.validate()
        guard root.isFileURL else { throw Failure.invalidState }
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw Failure.invalidState }
        let capacity = try FileManager.default.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? NSNumber
        guard let free = capacity?.int64Value, free > 1_073_741_824 else { throw Failure.insufficientSpace }
        var total: Int64 = 0
        for part in record.audio {
            let addition = total.addingReportingOverflow(part.byteCount)
            guard !addition.overflow else { throw Failure.insufficientSpace }
            total = addition.partialValue
        }
        // Staging and the final private copy coexist until durable publication.
        guard total <= (free - 1_073_741_824) / 2 else { throw Failure.insufficientSpace }
        self.record = record
        directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    deinit { try? handle?.close() }

    /// Only this randomly named staging directory is removed; source and
    /// committed library files are outside it.
    func discard() throws {
        try handle?.close(); handle = nil
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    func stagedURL(index: Int) throws -> URL {
        guard record.audio.indices.contains(index) else { throw Failure.invalidState }
        return directory.appendingPathComponent(String(format: "%08d.part", index), isDirectory: false)
    }

    func append(index incoming: Int, offset incomingOffset: Int64, bytes: Data) throws {
        guard index == incoming, incomingOffset == offset, record.audio.indices.contains(index),
              !bytes.isEmpty, bytes.count <= Self.maximumChunkBytes,
              offset <= record.audio[index].byteCount,
              Int64(bytes.count) <= record.audio[index].byteCount - offset else { throw Failure.invalidChunk }
        let url = try stagedURL(index: index)
        if handle == nil {
            guard offset == 0, !FileManager.default.fileExists(atPath: url.path),
                  FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw Failure.alreadyExists }
            handle = try FileHandle(forWritingTo: url)
        }
        guard let handle else { throw Failure.invalidState }
        try handle.write(contentsOf: bytes)
        offset += Int64(bytes.count)
        if offset == record.audio[index].byteCount {
            try handle.synchronize(); try handle.close(); self.handle = nil
            try LANSyncIntegrity.verify(url, against: record.audio[index])
            index += 1; offset = 0
        }
    }

    /// The caller must reverify at the point of publishing into the library.
    func completedFiles() throws -> [URL] {
        guard index == record.audio.count, handle == nil else { throw Failure.invalidState }
        return try record.audio.indices.map { number in
            let url = try stagedURL(index: number)
            try LANSyncIntegrity.verify(url, against: record.audio[number])
            return url
        }
    }
}
