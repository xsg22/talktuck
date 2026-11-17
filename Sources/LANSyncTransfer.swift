import Foundation

/// One request is outstanding at a time; an acknowledgement is sent only after
/// the receiver has accepted that chunk or committed the complete record.
struct LANSyncRequest: Codable {
    enum Kind: String, Codable { case metadata, file, commit, abort }
    var kind: Kind
    var index: Int = 0
    var offset: Int64 = 0
    var final: Bool = false
    var bytes: Data = Data()
    var allowReuse: Bool? = nil
}

actor LANSyncReceiver {
    enum Failure: Error { case protocolError, metadataTooLarge }
    static let maximumMetadataBytes = 32 * 1024 * 1024
    private let root: URL
    private let publish: (LANSyncRecord, [URL]) async throws -> Void
    private let canReuse: ((LANSyncRecord) async throws -> Bool)?
    private var metadata = Data()
    private var staging: LANSyncStaging?
    private var reusedRecord: LANSyncRecord?
    private var finished = false
    private var committing = false

    init(root: URL, canReuse: ((LANSyncRecord) async throws -> Bool)? = nil, publish: @escaping (LANSyncRecord, [URL]) async throws -> Void) {
        self.root = root; self.publish = publish; self.canReuse = canReuse
    }

    func accept(_ request: LANSyncRequest) async throws {
        _ = try await acceptOptimized(request)
    }
    func acceptOptimized(_ request: LANSyncRequest) async throws -> Bool {
        guard !finished, !committing else { throw Failure.protocolError }
        switch request.kind {
        case .abort:
            guard request.bytes.isEmpty, request.index == 0, request.offset == 0, !request.final else { throw Failure.protocolError }
            finished = true
            try? staging?.discard()
        case .metadata:
            guard staging == nil, reusedRecord == nil, request.index == 0, request.offset == Int64(metadata.count),
                  !request.bytes.isEmpty, request.bytes.count <= LANSyncStaging.maximumChunkBytes,
                  metadata.count <= Self.maximumMetadataBytes - request.bytes.count else { throw Failure.metadataTooLarge }
            metadata.append(request.bytes)
            if request.final {
                let record = try JSONDecoder().decode(LANSyncRecord.self, from: metadata)
                try record.validate()
                metadata.removeAll(keepingCapacity: false)
                if request.allowReuse == true, let canReuse, try await canReuse(record) {
                    reusedRecord = record
                    return true
                }
                staging = try LANSyncStaging(root: root, record: record)
            }
        case .file:
            guard let staging, !request.final else { throw Failure.protocolError }
            try staging.append(index: request.index, offset: request.offset, bytes: request.bytes)
        case .commit:
            guard request.bytes.isEmpty, request.index == 0, request.offset == 0, !request.final,
                  staging != nil || reusedRecord != nil else { throw Failure.protocolError }
            let record = staging?.record ?? reusedRecord!
            let files = try staging?.completedFiles() ?? []
            // A success reply means publication succeeded, not merely receipt.
            committing = true
            try Task.checkCancellation()
            do { try await publish(record, files) }
            catch { committing = false; throw error }
            finished = true
            // Staging contains only copies; publication has committed originals.
            try? staging?.discard()
        }
        return false
    }

    func cancel() {
        finished = true
        if !committing { try? staging?.discard() }
    }
}

actor LANSyncFileReader {
    private let handle: FileHandle
    init(url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
    func read() throws -> Data { try handle.read(upToCount: LANSyncStaging.maximumChunkBytes) ?? Data() }
    func close() throws { try handle.close() }
}

enum LANSyncSender {
    enum Failure: Error { case mismatch, unexpectedEOF }
    static func send(record: LANSyncRecord, files: [URL], progress: ((Int64, Int64) async -> Void)? = nil,
                     request: (LANSyncRequest) async throws -> Void) async throws {
        _ = try await sendOptimized(record: record, files: files, progress: progress, allowReuse: false) { requestValue in
            try await request(requestValue); return false
        }
    }
    @discardableResult static func sendOptimized(record: LANSyncRecord, files: [URL], progress: ((Int64, Int64) async -> Void)? = nil, allowReuse: Bool = true,
                     request: (LANSyncRequest) async throws -> Bool) async throws -> Bool {
        try record.validate()
        guard files.count == record.audio.count else { throw Failure.mismatch }
        var total: Int64 = 0
        for part in record.audio {
            let value = total.addingReportingOverflow(part.byteCount)
            guard !value.overflow else { throw Failure.mismatch }
            total = value.partialValue
        }
        var sent: Int64 = 0
        var lastProgress = ContinuousClock.now
        let metadata = try JSONEncoder().encode(record)
        guard !metadata.isEmpty, metadata.count <= LANSyncReceiver.maximumMetadataBytes else { throw LANSyncReceiver.Failure.metadataTooLarge }
        var position = 0
        var reuse = false
        while position < metadata.count {
            try Task.checkCancellation()
            let end = min(position + LANSyncStaging.maximumChunkBytes, metadata.count)
            let final = end == metadata.count
            let answer = try await request(LANSyncRequest(kind: .metadata, offset: Int64(position), final: final, bytes: metadata.subdata(in: position..<end), allowReuse: final && allowReuse ? true : nil))
            if final { reuse = answer }
            position = end
        }
        if !reuse { for index in files.indices {
            let reader = try LANSyncFileReader(url: files[index])
            var offset: Int64 = 0
            do {
                while offset < record.audio[index].byteCount {
                    try Task.checkCancellation()
                    let chunk = try await reader.read()
                    guard !chunk.isEmpty, Int64(chunk.count) <= record.audio[index].byteCount - offset else { throw Failure.unexpectedEOF }
                    _ = try await request(LANSyncRequest(kind: .file, index: index, offset: offset, bytes: chunk))
                    offset += Int64(chunk.count)
                    sent += Int64(chunk.count)
                    if let progress, lastProgress.duration(to: .now) >= .seconds(1) || sent == total {
                        await progress(sent, total); lastProgress = .now
                    }
                }
                // Detect a source that grew after the snapshot was prepared.
                guard try await reader.read().isEmpty else { throw Failure.mismatch }
                try await reader.close()
            } catch { try? await reader.close(); throw error }
        } }
        _ = try await request(LANSyncRequest(kind: .commit))
        return reuse
    }
}
