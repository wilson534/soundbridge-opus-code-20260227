import Foundation
@preconcurrency import MultipeerConnectivity

@MainActor
@Observable
final class MPCService: NSObject {
    enum ConnectionState: Equatable {
        case idle
        case browsing
        case inviting(peerName: String)
        case connected(peerName: String)
        case failed(reason: String)
    }

    var connectedPeers: [MCPeerID] = []
    var discoveredPeers: [MCPeerID] = []
    var isConnected: Bool { !connectedPeers.isEmpty }
    var connectionState: ConnectionState = .idle
    var lastErrorMessage: String?
    var isConnecting: Bool {
        if case .inviting = connectionState {
            return true
        }
        return false
    }

    var onPayloadReceived: ((TranscriptPayload) -> Void)?

    nonisolated(unsafe) let session: MCSession
    private let myPeerID: MCPeerID
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var isAdvertising = false
    private var isBrowsing = false
    private var targetPeer: MCPeerID?
    private var keepaliveTask: Task<Void, Never>?
    private var invitationTimeoutTask: Task<Void, Never>?

    /// 心跳包标记，接收端据此忽略
    nonisolated static let keepaliveMarker = Data("__keepalive__".utf8)

    init(displayName: String) {
        myPeerID = MCPeerID(displayName: displayName)
        session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
    }

    // MARK: - iPad: Advertise

    func startAdvertising() {
        guard !isAdvertising else { return }
        let adv = MCNearbyServiceAdvertiser(
            peer: myPeerID,
            discoveryInfo: nil,
            serviceType: Constants.serviceType
        )
        adv.delegate = self
        adv.startAdvertisingPeer()
        advertiser = adv
        isAdvertising = true
        if connectedPeers.isEmpty {
            connectionState = .idle
        }
    }

    func stopAdvertising() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        isAdvertising = false
    }

    // MARK: - iPhone: Browse

    func startBrowsing() {
        guard !isBrowsing else { return }
        let br = MCNearbyServiceBrowser(
            peer: myPeerID,
            serviceType: Constants.serviceType
        )
        br.delegate = self
        br.startBrowsingForPeers()
        browser = br
        isBrowsing = true
        if case .failed = connectionState {
            lastErrorMessage = nil
        }
        if connectedPeers.isEmpty {
            connectionState = .browsing
        }
    }

    func stopBrowsing() {
        browser?.stopBrowsingForPeers()
        browser = nil
        isBrowsing = false
        discoveredPeers.removeAll()
        if connectedPeers.isEmpty {
            connectionState = .idle
        }
    }

    func connectToPeer(_ peer: MCPeerID) {
        guard let browser else {
            setFailure("搜索尚未开始，请重试")
            return
        }
        targetPeer = peer
        lastErrorMessage = nil
        connectionState = .inviting(peerName: peer.displayName)
        startInvitationTimeout(for: peer)
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 30)
    }

    // MARK: - Send

    func send(_ payload: TranscriptPayload) {
        guard !session.connectedPeers.isEmpty else { return }
        do {
            let data = try JSONEncoder().encode(payload)
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
        } catch {
            print("发送失败: \(error)")
        }
    }

    func disconnect() {
        stopKeepalive()
        stopInvitationTimeout()
        session.disconnect()
        stopAdvertising()
        stopBrowsing()
        connectedPeers.removeAll()
        discoveredPeers.removeAll()
        targetPeer = nil
        lastErrorMessage = nil
        connectionState = .idle
    }

    // MARK: - Keepalive

    private func startKeepalive() {
        guard keepaliveTask == nil else { return }
        keepaliveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, !session.connectedPeers.isEmpty else { continue }
                try? session.send(Self.keepaliveMarker, toPeers: session.connectedPeers, with: .reliable)
            }
        }
    }

    private func stopKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    private func startInvitationTimeout(for peer: MCPeerID) {
        stopInvitationTimeout()
        invitationTimeoutTask = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            guard case let .inviting(peerName) = self.connectionState,
                  peerName == peer.displayName,
                  !self.isConnected else {
                return
            }
            setFailure("连接超时，请重试")
        }
    }

    private func stopInvitationTimeout() {
        invitationTimeoutTask?.cancel()
        invitationTimeoutTask = nil
    }

    private func setFailure(_ reason: String) {
        lastErrorMessage = reason
        connectionState = .failed(reason: reason)
    }
}

// MARK: - MCSessionDelegate

extension MPCService: MCSessionDelegate {
    nonisolated func session(
        _ session: MCSession,
        peer peerID: MCPeerID,
        didChange state: MCSessionState
    ) {
        let stateStr: String
        switch state {
        case .connected: stateStr = "已连接"
        case .notConnected: stateStr = "已断开"
        case .connecting: stateStr = "连接中"
        @unknown default: stateStr = "未知(\(state.rawValue))"
        }
        print("[MPC] peer=\(peerID.displayName) state=\(stateStr)")

        Task { @MainActor in
            let wasConnected = self.connectedPeers.contains(peerID)
            switch state {
            case .connected:
                self.stopInvitationTimeout()
                self.lastErrorMessage = nil
                if !self.connectedPeers.contains(peerID) {
                    self.connectedPeers.append(peerID)
                }
                self.targetPeer = peerID
                self.discoveredPeers.removeAll { $0 == peerID }
                self.startKeepalive()
                self.connectionState = .connected(peerName: peerID.displayName)
            case .notConnected:
                self.connectedPeers.removeAll { $0 == peerID }
                if self.connectedPeers.isEmpty {
                    self.stopKeepalive()
                }
                if wasConnected, self.isBrowsing, let target = self.targetPeer, target == peerID {
                    print("[MPC] 尝试自动重连 \(peerID.displayName)")
                    self.connectionState = .inviting(peerName: peerID.displayName)
                    self.startInvitationTimeout(for: peerID)
                    self.browser?.invitePeer(peerID, to: self.session, withContext: nil, timeout: 30)
                    return
                }

                if self.connectedPeers.isEmpty {
                    if self.isBrowsing, let target = self.targetPeer, target == peerID {
                        self.setFailure("连接失败，请重试")
                    } else {
                        self.connectionState = self.isBrowsing ? .browsing : .idle
                    }
                }
            case .connecting:
                if self.connectedPeers.isEmpty {
                    self.connectionState = .inviting(peerName: peerID.displayName)
                }
            @unknown default:
                if self.connectedPeers.isEmpty {
                    self.setFailure("连接状态异常，请重试")
                }
            }
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didReceive data: Data,
        fromPeer peerID: MCPeerID
    ) {
        // 忽略心跳包
        if data == MPCService.keepaliveMarker { return }
        guard let payload = try? JSONDecoder().decode(TranscriptPayload.self, from: data) else {
            return
        }
        Task { @MainActor in
            self.onPayloadReceived?(payload)
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MPCService: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        // 同步调用，自动接受所有邀请
        Task { @MainActor in
            self.lastErrorMessage = nil
            self.connectionState = .inviting(peerName: peerID.displayName)
        }
        invitationHandler(true, session)
    }

    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didNotStartAdvertisingPeer error: Error
    ) {
        print("广播失败: \(error)")
        Task { @MainActor in
            self.setFailure("广播失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MPCService: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        Task { @MainActor in
            if !self.discoveredPeers.contains(peerID),
               !self.connectedPeers.contains(peerID) {
                self.discoveredPeers.append(peerID)
            }
            if self.connectedPeers.isEmpty, !self.isConnecting {
                self.connectionState = .browsing
            }
        }
    }

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        lostPeer peerID: MCPeerID
    ) {
        Task { @MainActor in
            self.discoveredPeers.removeAll { $0 == peerID }
            if self.connectedPeers.isEmpty,
               let target = self.targetPeer,
               target == peerID {
                self.stopInvitationTimeout()
                self.targetPeer = nil
                self.setFailure("目标设备已离线")
            }
        }
    }

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        didNotStartBrowsingForPeers error: Error
    ) {
        print("搜索失败: \(error)")
        Task { @MainActor in
            self.setFailure("搜索失败：\(error.localizedDescription)")
        }
    }
}
