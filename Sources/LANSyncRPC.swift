import Foundation

private struct LANSyncEnvelope: Codable {
    let id: UUID
    var request: LANSyncRequest?
    var accepted: Bool?
    var reuseAudio: Bool? = nil
}

/// Stop-and-wait transport bounds network buffering and means a successful
/// acknowledgement is evidence of receiver acceptance, not mere submission.
@MainActor final class LANSyncRPC {
    enum Failure: Error { case unavailable, rejected, timeout, malformed }
    private let channel: LANSyncChannel
    private let stagingRoot: URL?
    private let publish: ((LANSyncRecord, [URL]) async throws -> Void)?
    private let canReuse: ((LANSyncRecord) async throws -> Bool)?
    private var receiver: LANSyncReceiver?
    private var receiving = false
    private var pending: (UUID, CheckedContinuation<Bool, Error>)?
    private var timer: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    init(channel: LANSyncChannel, stagingRoot: URL? = nil, canReuse: ((LANSyncRecord) async throws -> Bool)? = nil, publish: ((LANSyncRecord, [URL]) async throws -> Void)? = nil) {
        self.channel = channel; self.stagingRoot = stagingRoot; self.publish = publish; self.canReuse = canReuse
        channel.receive = { [weak self] data in self?.handle(data) }
    }

    func request(_ command: LANSyncRequest) async throws {
        _ = try await requestResult(command)
    }
    func requestResult(_ command: LANSyncRequest) async throws -> Bool {
        guard channel.ready, pending == nil, stagingRoot == nil else { throw Failure.unavailable }
        let id = UUID()
        let data = try JSONEncoder().encode(LANSyncEnvelope(id: id, request: command, accepted: nil))
        guard data.count <= 128 * 1024 else { throw Failure.malformed }
        return try await withCheckedThrowingContinuation { continuation in
            pending = (id, continuation)
            do { try channel.send(data) }
            catch { pending = nil; continuation.resume(throwing: error); return }
            let timeoutSeconds = (command.kind == .metadata && command.final && command.allowReuse == true) || command.kind == .commit ? 600 : 30
            timer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                guard !Task.isCancelled, let self, let item = self.pending, item.0 == id else { return }
                self.pending = nil; item.1.resume(throwing: Failure.timeout)
            }
        }
    }

    func cancel() {
        timer?.cancel(); timer = nil
        if let pending { self.pending = nil; pending.1.resume(throwing: CancellationError()) }
        receiveTask?.cancel(); receiveTask = nil
        let oldReceiver = receiver; receiver = nil
        if let oldReceiver { Task { await oldReceiver.cancel() } }
    }

    private func handle(_ bytes: Data) {
        guard let envelope = try? JSONDecoder().decode(LANSyncEnvelope.self, from: bytes) else { channel.stop(); cancel(); return }
        if let accepted = envelope.accepted, envelope.request == nil {
            guard let pending, pending.0 == envelope.id else { channel.stop(); cancel(); return }
            self.pending = nil; timer?.cancel(); timer = nil
            if accepted { pending.1.resume(returning: envelope.reuseAudio == true) } else { pending.1.resume(throwing: Failure.rejected) }
            return
        }
        guard let command = envelope.request, envelope.accepted == nil, let stagingRoot, let publish, !receiving else {
            channel.stop(); cancel(); return
        }
        if receiver == nil { receiver = LANSyncReceiver(root: stagingRoot, canReuse: canReuse, publish: publish) }
        guard let receiver else { channel.stop(); cancel(); return }
        receiving = true
        receiveTask = Task { [weak self] in
            let accepted: Bool
            let reuse: Bool
            do { reuse = try await receiver.acceptOptimized(command); accepted = true }
            catch { await receiver.cancel(); accepted = false; reuse = false }
            guard let self else { return }
            guard !Task.isCancelled else { self.receiving = false; return }
            self.receiveTask = nil
            self.receiving = false
            if !accepted || command.kind == .commit || command.kind == .abort { self.receiver = nil }
            do {
                let reply = try JSONEncoder().encode(LANSyncEnvelope(id: envelope.id, request: nil, accepted: accepted, reuseAudio: reuse ? true : nil))
                try self.channel.send(reply)
            } catch { self.channel.stop(); self.cancel() }
        }
    }
}
