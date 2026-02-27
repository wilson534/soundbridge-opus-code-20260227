import SwiftUI
import Speech

struct SpeakerView: View {
    @State var speechService = SpeechService()
    @Bindable var mpcService: MPCService
    @State private var showPairing = false
    @State private var showPermissionAlert = false
    @State private var selectedLocale = "zh-CN"

    private let speaker = Speaker.defaultSpeaker
    private let locales = ["zh-CN", "yue-CN"]
    private let localeLabels = ["普通话", "粤语"]

    var body: some View {
        VStack(spacing: 0) {
            connectionBar

            Spacer()

            // 文字显示区
            ScrollView {
                Text(speechService.displayText.isEmpty ? "点击下方按钮开始说话" : speechService.displayText)
                    .font(.title2)
                    .foregroundStyle(speechService.displayText.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }

            Spacer()

            // 语言切换
            Picker("语言", selection: $selectedLocale) {
                ForEach(Array(zip(locales, localeLabels)), id: \.0) { locale, label in
                    Text(label).tag(locale)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 40)
            .padding(.bottom, 20)
            .onChange(of: selectedLocale) { _, newValue in
                speechService.switchLocale(to: newValue)
            }

            // 麦克风按钮
            Button {
                Task { await toggleListening() }
            } label: {
                Circle()
                    .fill(speechService.isListening ? Color.red : Color.blue)
                    .frame(width: 80, height: 80)
                    .overlay {
                        Image(systemName: speechService.isListening ? "stop.fill" : "mic.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                    }
            }
            .padding(.bottom, 40)
        }
        .sheet(isPresented: $showPairing) {
            PairingView(mpcService: mpcService)
        }
        .alert("需要语音识别权限", isPresented: $showPermissionAlert) {
            Button("去设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请在系统设置中开启语音识别权限")
        }
        .onAppear {
            setupTranscriptHandler()
        }
    }

    // MARK: - Connection Bar

    private var connectionBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(connectionIndicatorColor)
                        .frame(width: 10, height: 10)
                    Text(connectionStatusTitle)
                        .font(.subheadline)
                }
                if let detail = connectionStatusDetail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("配对") { showPairing = true }
                .font(.subheadline)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Actions

    private func toggleListening() async {
        if speechService.isListening {
            speechService.stopListening()
            return
        }

        let authorized = await speechService.requestAuthorization()
        guard authorized else {
            showPermissionAlert = true
            return
        }

        speechService.startListening()
    }

    private func setupTranscriptHandler() {
        speechService.onTranscript = { text, isFinal, seq in
            let payload = TranscriptPayload(
                speakerId: speaker.id,
                speakerName: speaker.displayName,
                sequence: seq,
                sentAt: Date(),
                isFinal: isFinal,
                rawText: text,
                locale: selectedLocale
            )
            mpcService.send(payload)
        }
    }

    private var connectionIndicatorColor: Color {
        switch mpcService.connectionState {
        case .connected:
            return .green
        case .browsing, .inviting:
            return .orange
        case .idle, .failed:
            return .red
        }
    }

    private var connectionStatusTitle: String {
        switch mpcService.connectionState {
        case .idle:
            return "未连接"
        case .browsing:
            return "搜索中"
        case .inviting:
            return "连接中"
        case .connected:
            return "已连接"
        case .failed:
            return "连接失败"
        }
    }

    private var connectionStatusDetail: String? {
        switch mpcService.connectionState {
        case let .inviting(peerName), let .connected(peerName):
            return peerName
        case let .failed(reason):
            return reason
        default:
            return nil
        }
    }
}
