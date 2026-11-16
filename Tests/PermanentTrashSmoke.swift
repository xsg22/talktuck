import Foundation

/// Uses only isolated synthetic records and files under TMPDIR.
@main struct PermanentTrashSmoke {
    static func check(_ value: Bool) { precondition(value) }
    final class FailingManager: FileManager, @unchecked Sendable {
        var denied: URL?
        override func removeItem(at URL: URL) throws {
            if URL.standardizedFileURL == denied?.standardizedFileURL { throw CocoaError(.fileWriteNoPermission) }
            try super.removeItem(at: URL)
        }
    }
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("trash-test-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("original.wav")
        try Data("original-audio".utf8).write(to: source)
        let library = try MeetingLibrary(root: root.appendingPathComponent("library"), publishAgentDataOnInit: false)
        var first = MeetingRecord(title: "synthetic local", text: "synthetic transcript")
        _ = try library.importAudio(source, into: &first, recordingDuration: 1)
        let managed = try library.audioURLs(for: first)[0]
        var other = MeetingRecord(title: "keep", text: "keep")
        _ = try library.importAudio(source, into: &other, recordingDuration: 1)
        try library.trash(first.id); try library.trash(other.id)
        let trash = library.root.appendingPathComponent("Trash").appendingPathComponent(first.id.uuidString)
        let outside = root.appendingPathComponent("outside.txt"); try Data("keep".utf8).write(to: outside)
        try fm.createSymbolicLink(at: trash.appendingPathComponent("link"), withDestinationURL: outside)
        let checkpoint = library.root.appendingPathComponent("TranscriptionCheckpoints").appendingPathComponent(first.id.uuidString)
        try fm.createDirectory(at: checkpoint, withIntermediateDirectories: true)
        try Data("checkpoint".utf8).write(to: checkpoint.appendingPathComponent("a"))
        var syncNotifications = 0
        library.didChange = { syncNotifications += 1 }
        try library.permanentlyDeleteTrashed(first.id)
        precondition(syncNotifications == 0, "local purge must not initiate cloud synchronization")
        precondition(!fm.fileExists(atPath: trash.path) && !fm.fileExists(atPath: checkpoint.path) && !fm.fileExists(atPath: managed.path))
        precondition(fm.fileExists(atPath: source.path) && fm.fileExists(atPath: outside.path))
        check(try library.listTrashed().map(\.id) == [other.id])
        do { try library.permanentlyDeleteTrashed(first.id); fatalError("duplicate delete") } catch {}

        let owner = UUID(), stranger = UUID(); library.activeSyncUserId = owner
        var owned = MeetingRecord(title: "account item", text: "synthetic"); owned.userId = owner
        _ = try library.save(owned); try library.trash(owned.id)
        let key = LibrarySyncValue.key(.recording, owned.id)
        check(try library.syncDeletions(owner).contains(key))
        library.activeSyncUserId = stranger
        do { try library.permanentlyDeleteTrashed(owned.id); fatalError("cross-account delete") } catch {}
        library.activeSyncUserId = owner; syncNotifications = 0
        try library.permanentlyDeleteTrashed(owned.id)
        precondition(syncNotifications == 0, "purging an account item must not start a remote delete")
        check(try library.syncDeletions(owner).contains(key))
        let reopened = try MeetingLibrary(root: library.root, publishAgentDataOnInit: false); reopened.activeSyncUserId = owner
        check(try reopened.syncDeletions(owner).contains(key) && !reopened.syncDeletions(stranger).contains(key))

        let metadataFile = library.root.appendingPathComponent("purged-recording-tombstones.json")
        let validTombstones = try Data(contentsOf: metadataFile)
        var another = MeetingRecord(title: "keep if metadata corrupt"); another.userId = owner
        _ = try library.save(another); try library.trash(another.id)
        try Data("broken".utf8).write(to: metadataFile)
        do { try library.permanentlyDeleteTrashed(another.id); fatalError("corrupt tombstone index") } catch {}
        check(try library.listTrashed().contains { $0.id == another.id })
        try validTombstones.write(to: metadataFile, options: .atomic)

        let brokenRoot = root.appendingPathComponent("failure"), manager = FailingManager()
        let failing = try MeetingLibrary(root: brokenRoot, manager: manager, publishAgentDataOnInit: false)
        failing.activeSyncUserId = owner
        var toRestore = MeetingRecord(title: "restore after failure"); toRestore.userId = owner
        _ = try failing.save(toRestore); try failing.trash(toRestore.id)
        manager.denied = brokenRoot.appendingPathComponent("Trash").appendingPathComponent(toRestore.id.uuidString)
        do { try failing.permanentlyDeleteTrashed(toRestore.id); fatalError("injected failure") } catch {}
        check(try failing.listTrashed().contains { $0.id == toRestore.id })
        check(try failing.syncDeletions(owner).contains(LibrarySyncValue.key(.recording, toRestore.id)))
        manager.denied = nil; _ = try failing.restoreTrashed(toRestore.id)
        check(try !failing.syncDeletions(owner).contains(LibrarySyncValue.key(.recording, toRestore.id)))

        // A symlinked checkpoint must never allow deletion outside the library.
        let guarded = MeetingRecord(title: "guarded"); _ = try failing.save(guarded); try failing.trash(guarded.id)
        let checkpoints = brokenRoot.appendingPathComponent("TranscriptionCheckpoints")
        try fm.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        let outsideDirectory = root.appendingPathComponent("outside-directory")
        try fm.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outsideDirectory.appendingPathComponent("sentinel"))
        try fm.createSymbolicLink(at: checkpoints.appendingPathComponent(guarded.id.uuidString), withDestinationURL: outsideDirectory)
        do { try failing.permanentlyDeleteTrashed(guarded.id); fatalError("symlinked checkpoint") } catch {}
        check(try failing.listTrashed().contains { $0.id == guarded.id })
        precondition(fm.fileExists(atPath: outsideDirectory.appendingPathComponent("sentinel").path))

        let diagnostics = FeedbackDiagnostics(root: root.appendingPathComponent("diagnostics"))
        let logger = QueueDiagnostics(journal: diagnostics)
        logger.emit("delete-finished", operation: "TEST1234", phase: "local", outcome: "failed", depth: 0, component: "trash")
        logger.flush()
        diagnostics.record("trash", "delete-finished", fields: ["title": "private-title"])
        let exported = String(decoding: try diagnostics.safeSnapshot(), as: UTF8.self)
        precondition(exported.contains("delete-finished") && exported.contains("TEST1234") && !exported.contains("private-title"))
        print("PASS: local permanent delete, account isolation, source and symlink protection, sync tombstones, failure and restore")
    }
}
