import Foundation
import Combine
import CryptoKit
import MultipeerConnectivity
import OSLog
#if os(iOS)
import UIKit
#endif

@MainActor final class LANSyncChannel: NSObject, ObservableObject {
    enum Role { case sender, receiver }
    private struct Hello: Codable { let version: Int; let id: UUID; let name: String; let key: Data }
    @Published private(set) var peers: [MCPeerID] = []
    @Published private(set) var peerNames: [MCPeerID: String] = [:]
    @Published private(set) var trustedDevices: [String: String] = [:]
    @Published private(set) var code: String?
    @Published private(set) var ready = false
    @Published private(set) var status = "未连接"
    var receive: ((Data) -> Void)?
    var onReady: (() -> Void)?
    var onDisconnected: (() -> Void)?
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.talktuck", category: "LANSync")
    private let role: Role
    private let trust: LANSyncTrustStore
    private let identity = MCPeerID(displayName: UUID().uuidString)
    private let service = "tt-lansync"
    private var session: MCSession!
    private var browser: MCNearbyServiceBrowser?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var remote: MCPeerID?
    private var peerIDs: [MCPeerID: UUID] = [:]
    private var peerID: UUID?
    private var peerName = ""
    private var pairing: LANSyncPairing?
    private var localConfirmed = false
    private var remoteConfirmed = false
    private var proofReceived = false
    private var wantsConfirm = false
    private var isRunning = false
    private var retry: Task<Void, Never>?

    init(role: Role, trust: LANSyncTrustStore = LANSyncTrustStore()) {
        self.role = role; self.trust = trust
        super.init()
        trustedDevices = trust.peers.mapValues(\.name)
        session = MCSession(peer: identity, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
    }
    private var deviceName: String {
        #if os(macOS)
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        return UIDevice.current.name
        #endif
    }
    func start() {
        isRunning = true
        guard browser == nil, advertiser == nil, remote == nil else { return }
        Self.log.info("lan-sync discovery-started v1")
        status = "正在查找设备"
        if role == .sender {
            let value = MCNearbyServiceBrowser(peer: identity, serviceType: service)
            value.delegate = self; browser = value; value.startBrowsingForPeers()
        } else {
            let value = MCNearbyServiceAdvertiser(peer: identity, discoveryInfo: ["deviceName": deviceName, "deviceID": trust.id.uuidString], serviceType: service)
            value.delegate = self; advertiser = value; value.startAdvertisingPeer()
        }
    }
    func connect(_ peer: MCPeerID) {
        guard role == .sender, remote == nil, peers.contains(peer), let browser else { return }
        remote = peer; status = "正在连接"
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 30)
    }
    func confirm() {
        guard code != nil, !localConfirmed else { return }
        if !proofReceived { wantsConfirm = true; return }
        do { try sendEnvelope(Data([0])); localConfirmed = true; updateReady() } catch { fail() }
    }
    func forget(_ id: String) {
        let needsRestart = status == "配对信息不一致，请在两端解除配对后重试。"
        guard trust.forget(id) else { status = "无法更新已配对设备"; return }
        trustedDevices = trust.peers.mapValues(\.name)
        Self.log.info("lan-sync device-unpaired v1")
        if peerID?.uuidString == id { resetConnection(); if isRunning { start() } }
        else if needsRestart { start() }
    }
    func send(_ payload: Data) throws {
        guard ready, payload.count <= 128 * 1024 else { throw LANSyncPairing.Failure.invalidMessage }
        try sendEnvelope(Data([1]) + payload)
    }
    func stop() { isRunning = false; retry?.cancel(); retry = nil; resetConnection() }
    private func resetConnection() {
        browser?.stopBrowsingForPeers(); advertiser?.stopAdvertisingPeer()
        browser = nil; advertiser = nil
        let wasConnected = remote != nil
        remote = nil; session.disconnect(); pairing = nil; peerID = nil; peerName = ""
        code = nil; ready = false; localConfirmed = false; remoteConfirmed = false; proofReceived = false; wantsConfirm = false
        peers = []; peerNames = [:]; peerIDs = [:]; status = "未连接"
        if wasConnected { onDisconnected?() }
    }
    private func sendEnvelope(_ data: Data) throws {
        guard let remote, let pairing else { throw LANSyncPairing.Failure.invalidMessage }
        try session.send(pairing.seal(data), toPeers: [remote], with: .reliable)
    }
    private func connected(_ peer: MCPeerID) {
        guard remote == peer, pairing == nil else { fail(); return }
        browser?.stopBrowsingForPeers(); advertiser?.stopAdvertisingPeer()
        let p = LANSyncPairing(role: role == .sender ? .sender : .receiver); pairing = p
        do {
            let hello = Hello(version: 2, id: trust.id, name: deviceName, key: p.publicKey)
            try session.send(JSONEncoder().encode(hello), toPeers: [peer], with: .reliable)
        } catch { fail() }
    }
    private func proof(secret: Data, role: Role, pairing: LANSyncPairing) -> Data {
        let label = role == .sender ? "sender" : "receiver"
        return Data(HMAC<SHA256>.authenticationCode(for: pairing.handshakeTranscript + Data(label.utf8), using: SymmetricKey(data: secret)))
    }
    private func handle(_ data: Data, from peer: MCPeerID) {
        guard peer == remote, let pairing else { fail(); return }
        do {
            if pairing.verificationCode == nil {
                guard data.count <= 4096 else { throw LANSyncPairing.Failure.invalidMessage }
                let hello = try JSONDecoder().decode(Hello.self, from: data)
                guard hello.version == 2, hello.id != trust.id, !hello.name.isEmpty, hello.name.utf8.count <= 1024,
                      (peerIDs[peer] == nil || peerIDs[peer] == hello.id) else { throw LANSyncPairing.Failure.invalidMessage }
                peerID = hello.id; peerName = hello.name
                try pairing.establish(peerPublicKey: hello.key, senderID: role == .sender ? trust.id : hello.id,
                                      receiverID: role == .receiver ? trust.id : hello.id)
                let saved = trust.peers[hello.id.uuidString]
                try sendEnvelope(Data([2]) + (saved.map { proof(secret: $0.secret, role: role, pairing: pairing) } ?? Data()))
                Self.log.info("lan-sync verification-started v1")
                code = pairing.verificationCode; status = "请核对两端验证码"
                return
            }
            guard data.count <= 128 * 1024 + 64 else { throw LANSyncPairing.Failure.invalidMessage }
            let clear = try pairing.open(data)
            guard let kind = clear.first else { throw LANSyncPairing.Failure.invalidMessage }
            if kind == 2 {
                guard !proofReceived, let peerID else { throw LANSyncPairing.Failure.invalidMessage }
                proofReceived = true
                let received = Data(clear.dropFirst())
                if let saved = trust.peers[peerID.uuidString] {
                    guard received.count == 32, HMAC<SHA256>.isValidAuthenticationCode(received, authenticating: pairing.handshakeTranscript + Data((role == .sender ? "receiver" : "sender").utf8), using: SymmetricKey(data: saved.secret)) else {
                        Self.log.error("lan-sync trust-mismatch v1")
                        isRunning = false; resetConnection()
                        status = "配对信息不一致，请在两端解除配对后重试。"
                        return
                    }
                    Self.log.info("lan-sync trusted-peer-verified v1")
                    confirm()
                } else if !received.isEmpty && received.count != 32 { throw LANSyncPairing.Failure.invalidMessage }
                if wantsConfirm { wantsConfirm = false; confirm() }
            } else if kind == 0 {
                guard proofReceived, clear.count == 1, !remoteConfirmed else { throw LANSyncPairing.Failure.invalidMessage }
                remoteConfirmed = true; updateReady()
            } else if kind == 1 {
                guard ready else { throw LANSyncPairing.Failure.invalidMessage }
                receive?(Data(clear.dropFirst()))
            } else { throw LANSyncPairing.Failure.invalidMessage }
        } catch { fail() }
    }
    private func updateReady() {
        guard localConfirmed && remoteConfirmed, !ready, let peerID, let pairing, let secret = pairing.trustSecret else {
            if !ready { status = "等待另一端确认" }; return
        }
        if trust.peers[peerID.uuidString] == nil {
            guard trust.save(id: peerID, name: peerName, secret: secret) else { Self.log.error("lan-sync trust-save-failed v1"); fail(); status = "无法保存配对，请检查设备设置"; return }
            Self.log.info("lan-sync device-paired v1")
            trustedDevices = trust.peers.mapValues(\.name)
        }
        Self.log.info("lan-sync connected v1")
        ready = true; status = "已安全连接"; onReady?()
    }
    private func fail() {
        Self.log.error("lan-sync connection-failed v1")
        resetConnection(); status = "连接中断，请重新连接并核对验证码"
        guard isRunning else { return }
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.isRunning else { return }
            self.start()
        }
    }
}
extension LANSyncChannel: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor [weak self] in guard let self else { return }; if state == .connected && self.remote == peerID { self.connected(peerID) }; if state == .notConnected && self.remote == peerID { self.fail() } }
    }
    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) { Task { @MainActor [weak self] in self?.handle(data, from: peerID) } }
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) { }
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) { }
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) { }
    nonisolated func session(_ session: MCSession, didReceiveCertificate certificate: [Any]?, fromPeer peerID: MCPeerID, certificateHandler: @escaping (Bool) -> Void) { certificateHandler(true) }
}
extension LANSyncChannel: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor [weak self] in
            guard let self, self.browser === browser else { return }
            if let name = info?["deviceName"], !name.isEmpty { self.peerNames[peerID] = name }
            if let raw = info?["deviceID"], let id = UUID(uuidString: raw) { self.peerIDs[peerID] = id }
            if !self.peers.contains(peerID) { self.peers.append(peerID) }
            if let id = self.peerIDs[peerID], self.trust.peers[id.uuidString] != nil { self.connect(peerID) }
        }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) { Task { @MainActor [weak self] in self?.peers.removeAll { $0 == peerID }; self?.peerNames.removeValue(forKey: peerID); self?.peerIDs.removeValue(forKey: peerID) } }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) { Task { @MainActor [weak self] in self?.fail() } }
}
extension LANSyncChannel: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor [weak self] in
            guard let self, self.isRunning, self.role == .receiver, self.remote == nil else { invitationHandler(false, nil); return }
            self.remote = peerID; self.status = "正在连接"; invitationHandler(true, self.session)
        }
    }
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) { Task { @MainActor [weak self] in self?.fail() } }
}
