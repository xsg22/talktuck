import Foundation
import CryptoKit

/// An ephemeral authenticated channel. Both devices must compare the displayed code
/// before calling seal/open on application data. Transport encryption is also required.
final class LANSyncPairing {
    enum Role { case sender, receiver }
    enum Failure: Error { case badKey, wrongSequence, invalidMessage }
    private let privateKey = Curve25519.KeyAgreement.PrivateKey()
    private let role: Role
    private var sendKey: SymmetricKey?
    private var receiveKey: SymmetricKey?
    private var sendSequence: UInt64 = 0
    private var receiveSequence: UInt64 = 0
    private(set) var trustSecret: Data?
    private(set) var handshakeTranscript = Data()
    private(set) var verificationCode: String?
    var publicKey: Data { privateKey.publicKey.rawRepresentation }

    init(role: Role) { self.role = role }

    func establish(peerPublicKey: Data, senderID: UUID? = nil, receiverID: UUID? = nil) throws {
        guard verificationCode == nil, peerPublicKey.count == 32, peerPublicKey != publicKey else { throw Failure.badKey }
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let senderPublic = role == .sender ? publicKey : peerPublicKey
        let receiverPublic = role == .receiver ? publicKey : peerPublicKey
        let transcript = senderPublic + receiverPublic + Data((senderID?.uuidString ?? "").utf8) + Data((receiverID?.uuidString ?? "").utf8)
        handshakeTranscript = transcript
        let salt = Data("TalkTuck LAN sync v1".utf8)
        func key(_ label: String) -> SymmetricKey {
            shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                sharedInfo: transcript + Data(label.utf8), outputByteCount: 32)
        }
        let s2r = key("sender-to-receiver"), r2s = key("receiver-to-sender")
        sendKey = role == .sender ? s2r : r2s
        receiveKey = role == .sender ? r2s : s2r
        trustSecret = key("persistent-trust-v1").withUnsafeBytes { Data($0) }
        let check = key("verification")
        let hash = SHA256.hash(data: check.withUnsafeBytes { Data($0) } + transcript)
        let n = hash.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        verificationCode = String(format: "%08u", n % 100_000_000)
    }

    func seal(_ plaintext: Data) throws -> Data {
        guard let sendKey, sendSequence < UInt64.max else { throw Failure.invalidMessage }
        let header = Self.header(sendSequence)
        let box = try AES.GCM.seal(plaintext, using: sendKey, authenticating: header)
        guard let combined = box.combined else { throw Failure.invalidMessage }
        sendSequence += 1
        return header + combined
    }

    func open(_ packet: Data) throws -> Data {
        guard let receiveKey, packet.count >= 8 + 12 + 16 else { throw Failure.invalidMessage }
        let header = Data(packet.prefix(8))
        let number = header.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard number == receiveSequence, receiveSequence < UInt64.max else { throw Failure.wrongSequence }
        let box = try AES.GCM.SealedBox(combined: packet.dropFirst(8))
        let clear = try AES.GCM.open(box, using: receiveKey, authenticating: header)
        receiveSequence += 1
        return clear
    }

    private static func header(_ sequence: UInt64) -> Data {
        var value = sequence.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}

/// Persistent secrets are stored only after both sides confirm a code. A random
/// identifier is a discovery hint, never sufficient to authenticate a device.
import Security

final class LANSyncTrustStore {
    struct Peer: Codable { var name: String; var secret: Data }
    private struct State: Codable { var id: UUID; var peers: [String: Peer] }
    private let service: String
    private var state: State
    let persistent: Bool
    private let memoryOnly: Bool
    var id: UUID { state.id }
    var peers: [String: Peer] { state.peers }

    init(service: String = "com.talktuck.lansync.trust.v1", memoryOnly: Bool = false) {
        self.service = service; self.memoryOnly = memoryOnly
        if memoryOnly { state = State(id: UUID(), peers: [:]); persistent = false; return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "state", kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if status == errSecSuccess, let data = found as? Data, let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved; persistent = true
        } else if status == errSecItemNotFound {
            let fresh = State(id: UUID(), peers: [:])
            let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: "state", kSecValueData as String: (try? JSONEncoder().encode(fresh)) ?? Data(),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            let added = SecItemAdd(item as CFDictionary, nil) == errSecSuccess
            state = fresh; persistent = added
        } else { state = State(id: UUID(), peers: [:]); persistent = false }
    }

    @discardableResult func save(id: UUID, name: String, secret: Data) -> Bool {
        guard secret.count == 32 else { return false }
        var next = state; next.peers[id.uuidString] = Peer(name: name, secret: secret)
        return update(next)
    }
    @discardableResult func forget(_ id: String) -> Bool {
        var next = state; next.peers.removeValue(forKey: id); return update(next)
    }
    private func update(_ next: State) -> Bool {
        if memoryOnly { state = next; return true }
        guard persistent, let data = try? JSONEncoder().encode(next) else { return false }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "state"]
        guard SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess else { return false }
        state = next; return true
    }
}
