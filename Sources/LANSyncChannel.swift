import Foundation
import Combine
import MultipeerConnectivity

/// On-demand, one-peer transport. Nothing is transferred until both people
/// confirm the same ephemeral verification code on their own devices.
@MainActor final class LANSyncChannel: NSObject, ObservableObject {
    enum Role { case sender, receiver }
    @Published private(set) var peers: [MCPeerID] = []
    @Published private(set) var code: String?
    @Published private(set) var ready = false
    @Published private(set) var status = "未连接"
    var receive: ((Data) -> Void)?

    private let role: Role
    private let identity = MCPeerID(displayName: UUID().uuidString)
    private let service = "tt-lansync"
    private var session: MCSession!
    private var browser: MCNearbyServiceBrowser?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var remote: MCPeerID?
    private var pairing: LANSyncPairing?
    private var localConfirmed = false
    private var remoteConfirmed = false

    init(role: Role) {
        self.role = role
        super.init()
        session = MCSession(peer: identity, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
    }

    func start() {
        guard browser == nil, advertiser == nil, remote == nil else { return }
        status = "正在查找设备"
        if role == .sender {
            let value = MCNearbyServiceBrowser(peer: identity, serviceType: service)
            value.delegate = self; browser = value; value.startBrowsingForPeers()
        } else {
            let value = MCNearbyServiceAdvertiser(peer: identity, discoveryInfo: nil, serviceType: service)
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
        do {
            try sendEnvelope(Data([0]))
            localConfirmed = true
            updateReady()
        } catch { fail() }
    }

    func send(_ payload: Data) throws {
        guard ready, payload.count <= 128 * 1024 else { throw LANSyncPairing.Failure.invalidMessage }
        try sendEnvelope(Data([1]) + payload)
    }

    func stop() {
        browser?.stopBrowsingForPeers(); advertiser?.stopAdvertisingPeer()
        browser = nil; advertiser = nil; session.disconnect()
        remote = nil; pairing = nil; code = nil; ready = false
        localConfirmed = false; remoteConfirmed = false; peers = []; status = "未连接"
    }

    private func sendEnvelope(_ data: Data) throws {
        guard let remote, let pairing else { throw LANSyncPairing.Failure.invalidMessage }
        try session.send(pairing.seal(data), toPeers: [remote], with: .reliable)
    }

    private func connected(_ peer: MCPeerID) {
        guard remote == peer, pairing == nil else { fail(); return }
        browser?.stopBrowsingForPeers(); advertiser?.stopAdvertisingPeer()
        let p = LANSyncPairing(role: role == .sender ? .sender : .receiver)
        pairing = p
        do { try session.send(p.publicKey, toPeers: [peer], with: .reliable) }
        catch { fail() }
    }

    private func handle(_ data: Data, from peer: MCPeerID) {
        guard peer == remote, let pairing else { fail(); return }
        do {
            if pairing.verificationCode == nil {
                try pairing.establish(peerPublicKey: data)
                code = pairing.verificationCode; status = "请核对两端验证码"
                return
            }
            guard data.count <= 128 * 1024 + 64 else { throw LANSyncPairing.Failure.invalidMessage }
            let clear = try pairing.open(data)
            guard let kind = clear.first else { throw LANSyncPairing.Failure.invalidMessage }
            if kind == 0 {
                guard clear.count == 1, !remoteConfirmed else { throw LANSyncPairing.Failure.invalidMessage }
                remoteConfirmed = true; updateReady()
            } else if kind == 1 {
                guard ready else { throw LANSyncPairing.Failure.invalidMessage }
                receive?(Data(clear.dropFirst()))
            } else { throw LANSyncPairing.Failure.invalidMessage }
        } catch { fail() }
    }

    private func updateReady() {
        ready = localConfirmed && remoteConfirmed
        status = ready ? "已安全连接" : "等待另一端确认"
    }
    private func fail() { stop(); status = "连接中断，请重新连接并核对验证码" }
}

extension LANSyncChannel: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if state == .connected { self.connected(peerID) }
            if state == .notConnected && self.remote == peerID { self.fail() }
        }
    }
    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor [weak self] in self?.handle(data, from: peerID) }
    }
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) { }
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) { }
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) { }
    nonisolated func session(_ session: MCSession, didReceiveCertificate certificate: [Any]?, fromPeer peerID: MCPeerID, certificateHandler: @escaping (Bool) -> Void) {
        // The application-level ephemeral key and user-verified code authenticate the channel.
        certificateHandler(true)
    }
}

extension LANSyncChannel: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor [weak self] in guard let self, !self.peers.contains(peerID) else { return }; self.peers.append(peerID) }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor [weak self] in self?.peers.removeAll { $0 == peerID } }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor [weak self] in self?.fail() }
    }
}

extension LANSyncChannel: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor [weak self] in
            guard let self, self.role == .receiver, self.remote == nil else { invitationHandler(false, nil); return }
            self.remote = peerID; self.status = "正在连接"; invitationHandler(true, self.session)
        }
    }
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor [weak self] in self?.fail() }
    }
}
