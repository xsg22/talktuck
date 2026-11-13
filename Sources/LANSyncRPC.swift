import Foundation

private struct LANSyncEnvelope: Codable {
    let id: UUID
    var request: LANSyncRequest?
    var accepted: Bool?
}

/// Stop-and-wait transport bounds network buffering and means a successful
/// acknowledgement is evidence of receiver acceptance, not mere submission.
@MainActor final class LANSyncRPC {
    enum Failure: Error { case unavailable, rejected, timeout, malformed }
    private let channel: LANSyncChannel
    private let stagingRoot: URL?
    private let publish: ((LANSyncRecord, [URL]) async throws -> Void)?
    private var receiver: LANSyncReceiver?
    private var receiving = false
    private var pending: (UUID, CheckedContinuation<Void, Error>)?
    private var timer: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    init(channel: LANSyncChannel, stagingRoot: URL? = nil, publish: ((LANSyncRecord, [URL]) async throws -> Void)? = nil) {
        self.channel = channel; self.stagingRoot = stagingRoot; self.publish = publish
        channel.receive = { [weak self] data in self?.handle(data) }
    }

    func request(_ command: LANSyncRequest) async throws {
        guard channel.ready, pending == nil, stagingRoot == nil else { throw Failure.unavailable }
        let id = UUID()
        let data = try JSONEncoder().encode(LANSyncEnvelope(id: id, request: command, accepted: nil))
        guard data.count <= 128 * 1024 else { throw Failure.malformed }
        try await withCheckedThrowingContinuation { continuation in
            pending = (id, continuation)
            do { try channel.send(data) }
            catch { pending = nil; continuation.resume(throwing: error); return }
            timer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
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
            if accepted { pending.1.resume() } else { pending.1.resume(throwing: Failure.rejected) }
            return
        }
        guard let command = envelope.request, envelope.accepted == nil, let stagingRoot, let publish, !receiving else {
            channel.stop(); cancel(); return
        }
        if receiver == nil { receiver = LANSyncReceiver(root: stagingRoot, publish: publish) }
        guard let receiver else { channel.stop(); cancel(); return }
        receiving = true
        receiveTask = Task { [weak self] in
            let accepted: Bool
            do { try await receiver.accept(command); accepted = true }
            catch { await receiver.cancel(); accepted = false }
            guard let self else { return }
            guard !Task.isCancelled else { self.receiving = false; return }
            self.receiveTask = nil
            self.receiving = false
            if !accepted || command.kind == .commit || command.kind == .abort { self.receiver = nil }
            do {
                let reply = try JSONEncoder().encode(LANSyncEnvelope(id: envelope.id, request: nil, accepted: accepted))
                try self.channel.send(reply)
            } catch { self.channel.stop(); self.cancel() }
        }
    }
}
