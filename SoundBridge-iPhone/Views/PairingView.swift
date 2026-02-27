import SwiftUI

struct PairingView: View {
    @Bindable var mpcService: MPCService
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPeerName: String?

    var body: some View {
        NavigationStack {
            List {
                statusSection

                if mpcService.discoveredPeers.isEmpty {
                    ContentUnavailableView(
                        "搜索中…",
                        systemImage: "antenna.radiowaves.left.and.right",
                        description: Text("正在搜索附近的 iPad")
                    )
                } else {
                    ForEach(mpcService.discoveredPeers, id: \.self) { peer in
                        Button {
                            selectedPeerName = peer.displayName
                            mpcService.connectToPeer(peer)
                        } label: {
                            HStack {
                                Image(systemName: "ipad")
                                Text(peer.displayName)
                                Spacer()
                                if mpcService.isConnected, selectedPeerName == peer.displayName {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                } else if mpcService.isConnecting, selectedPeerName == peer.displayName {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(mpcService.isConnecting && selectedPeerName != peer.displayName)
                    }
                }
            }
            .navigationTitle("配对设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .onAppear {
            selectedPeerName = nil
            mpcService.startBrowsing()
        }
        .onDisappear {
            if !mpcService.isConnected {
                mpcService.stopBrowsing()
            }
        }
        .onChange(of: mpcService.connectionState) { _, state in
            switch state {
            case .connected:
                dismiss()
            case .failed:
                selectedPeerName = nil
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch mpcService.connectionState {
        case let .inviting(peerName):
            HStack(spacing: 8) {
                ProgressView()
                Text("正在连接 \(peerName)…")
                    .font(.subheadline)
            }
            .listRowBackground(Color(.secondarySystemBackground))
        case let .failed(reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.subheadline)
        default:
            EmptyView()
        }
    }
}
