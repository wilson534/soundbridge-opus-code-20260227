import Foundation
import SwiftUI

@MainActor
@Observable
final class DisplayViewModel {
    var messages: [Message] = []
    var currentPartials: [UUID: Message] = [:]
    var fontSize: CGFloat = Constants.defaultFontSize
    var connectedCount = 0

    let cleanerService = CleanerService()

    // 流式输出中的文本缓冲：messageId -> 当前已收到的 token
    var streamingTexts: [UUID: String] = [:]

    func handlePayload(_ payload: TranscriptPayload) {
        let message = payload.toMessage()
        if payload.isFinal {
            // final 消息以 pending 状态加入，触发清洁
            var msg = message
            msg.cleaningState = .pending
            messages.append(msg)
            currentPartials.removeValue(forKey: payload.speakerId)
            triggerCleaning(for: msg)
        } else {
            currentPartials[payload.speakerId] = message
        }
    }

    private func triggerCleaning(for message: Message) {
        guard case .ready = cleanerService.status else {
            NSLog("[Display] triggerCleaning 跳过: 模型状态=%@", String(describing: self.cleanerService.status))
            markDone(id: message.id, cleanedText: nil)
            return
        }

        NSLog("[Display] triggerCleaning 开始: text=%@, locale=%@", message.text, message.locale)

        // 标记为 cleaning
        if let idx = messages.firstIndex(where: { $0.id == message.id }) {
            messages[idx].cleaningState = .cleaning
        }

        let rawText = message.text
        let locale = message.locale
        let msgId = message.id

        Task {
            let stream = cleanerService.cleanStream(rawText: rawText, locale: locale)
            streamingTexts[msgId] = ""

            for await token in stream {
                streamingTexts[msgId, default: ""] += token
            }

            let finalText = streamingTexts[msgId]
            streamingTexts.removeValue(forKey: msgId)
            markDone(id: msgId, cleanedText: finalText?.isEmpty == true ? nil : finalText)
        }
    }

    private static let cleanerPrefixes = ["清理后：", "清理后:", "清理后: ", "清理后： "]

    private func markDone(id: UUID, cleanedText: String?) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        let rawText = messages[idx].text
        let locale = messages[idx].locale
        let text = normalizeCleanerText(cleanedText)
        let finalCleaned = text?.isEmpty == true ? nil : text

        messages[idx].cleanedText = finalCleaned
        messages[idx].cleaningState = finalCleaned != nil ? .done : .skipped
        NSLog("[Display] markDone: result=%@", text ?? "nil")
        let rawLen = rawText.count
        let cleanedLen = finalCleaned?.count ?? 0
        let ratio = rawLen > 0 ? Double(cleanedLen) / Double(rawLen) : 0
        NSLog(
            "[CleanerEval] locale=%@ raw_len=%@ cleaned_len=%@ ratio=%@ raw=%@ cleaned=%@",
            locale,
            String(rawLen),
            String(cleanedLen),
            String(format: "%.3f", ratio),
            Self.logPreview(rawText),
            Self.logPreview(finalCleaned ?? "")
        )
    }

    private func normalizeCleanerText(_ cleanedText: String?) -> String? {
        var text = cleanedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let t = text {
            for prefix in Self.cleanerPrefixes {
                if t.hasPrefix(prefix) {
                    text = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
        }
        return text
    }

    private static func logPreview(_ text: String, limit: Int = 160) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: "\\n")
        guard singleLine.count > limit else { return singleLine }
        let end = singleLine.index(singleLine.startIndex, offsetBy: limit)
        return String(singleLine[..<end]) + "..."
    }

    func increaseFontSize() {
        fontSize = min(fontSize + Constants.fontSizeStep, Constants.maxFontSize)
    }

    func decreaseFontSize() {
        fontSize = max(fontSize - Constants.fontSizeStep, Constants.minFontSize)
    }

    // MARK: - Grouped Messages

    struct MessageGroup: Identifiable {
        let id: UUID
        let speakerId: UUID
        let speakerName: String
        let messages: [Message]

        var isFullyResolved: Bool {
            messages.allSatisfy { $0.cleaningState == .done || $0.cleaningState == .skipped }
        }
    }

    var groupedMessages: [MessageGroup] {
        var groups: [MessageGroup] = []
        for msg in messages {
            if let last = groups.last, last.speakerId == msg.speakerId {
                groups[groups.count - 1] = MessageGroup(
                    id: last.id,
                    speakerId: last.speakerId,
                    speakerName: last.speakerName,
                    messages: last.messages + [msg]
                )
            } else {
                groups.append(MessageGroup(
                    id: msg.id,
                    speakerId: msg.speakerId,
                    speakerName: msg.speakerName,
                    messages: [msg]
                ))
            }
        }
        return groups
    }

    func displayText(for group: MessageGroup) -> String {
        group.messages.map { msg in
            switch msg.cleaningState {
            case .done:
                return msg.cleanedText ?? msg.text
            case .cleaning:
                if let streaming = streamingTexts[msg.id], !streaming.isEmpty {
                    return streaming
                }
                return msg.text
            case .pending, .skipped:
                return msg.text
            }
        }.joined(separator: " ")
    }
}

// MARK: - DisplayView

struct DisplayView: View {
    @Bindable var mpcService: MPCService
    @State private var viewModel = DisplayViewModel()

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            messageArea
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            mpcService.onPayloadReceived = { payload in
                viewModel.handlePayload(payload)
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .task {
            // 等待 MPC 连接建立后再加载模型，避免握手期间内存压力导致断连
            while !mpcService.isConnected {
                try? await Task.sleep(for: .milliseconds(500))
            }
            try? await Task.sleep(for: .seconds(5))
            await viewModel.cleanerService.prepare()
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            // 左：连接状态
            HStack(spacing: 6) {
                Circle()
                    .fill(connectionIndicatorColor)
                    .frame(width: 8, height: 8)
                    .overlay {
                        if mpcService.isConnected {
                            Circle()
                                .fill(.green.opacity(0.4))
                                .frame(width: 16, height: 16)
                                .phaseAnimator([false, true]) { content, phase in
                                    content.opacity(phase ? 0.0 : 0.6)
                                } animation: { _ in .easeInOut(duration: 1.5) }
                        }
                    }

                Text(connectionStatusTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let detail = connectionStatusDetail {
                    Text(detail)
                        .lineLimit(1)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if !mpcService.connectedPeers.isEmpty {
                    Text("(\(mpcService.connectedPeers.count))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // 中：模型状态
            modelStatusIcon

            Spacer()

            // 右：字号调节
            HStack(spacing: 4) {
                Button {
                    viewModel.decreaseFontSize()
                } label: {
                    Image(systemName: "textformat.size.smaller")
                        .frame(width: 44, height: 44)
                }

                Text("\(Int(viewModel.fontSize))")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Button {
                    viewModel.increaseFontSize()
                } label: {
                    Image(systemName: "textformat.size.larger")
                        .frame(width: 44, height: 44)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var modelStatusIcon: some View {
        switch viewModel.cleanerService.status {
        case .notReady:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.tertiary)
                .font(.caption)
        case .loading:
            ProgressView()
                .controlSize(.mini)
        case .ready:
            Image(systemName: "brain")
                .foregroundStyle(.green)
                .font(.caption)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
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
            return "待连接"
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

    // MARK: - Message Area

    private var messageArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(viewModel.groupedMessages) { group in
                        groupRow(group)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    // Partial 文本内联显示
                    ForEach(Array(viewModel.currentPartials.values), id: \.id) { msg in
                        Text(msg.text)
                            .font(.system(size: viewModel.fontSize * 0.85))
                            .foregroundStyle(.secondary)
                            .lineSpacing(viewModel.fontSize * 0.4)
                            .phaseAnimator([false, true]) { content, phase in
                                content.opacity(phase ? 0.5 : 1.0)
                            } animation: { _ in .easeInOut(duration: 1.0) }
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
            }
            .background(Color(.systemBackground))
            .onChange(of: viewModel.messages.count) { _, _ in
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.currentPartials.count) { _, _ in
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.streamingTexts) { _, _ in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private func groupRow(_ group: DisplayViewModel.MessageGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // 说话人标签 + cleaning 状态
            HStack(spacing: 6) {
                Text(group.speakerName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(speakerColor(for: group.speakerId).opacity(0.1))
                    )

                // DEBUG: cleaning state
                ForEach(group.messages, id: \.id) { msg in
                    Text(debugLabel(msg.cleaningState))
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(debugColor(msg.cleaningState))
                        )
                }
            }

            // 合并后的文本
            let text = viewModel.displayText(for: group)
            Text(text)
                .font(.system(size: viewModel.fontSize))
                .lineSpacing(viewModel.fontSize * 0.6)
                .foregroundStyle(group.isFullyResolved ? .primary : .secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(viewModel.displayText(for: group))
        .accessibilityAddTraits(.isStaticText)
    }

    private func speakerColor(for id: UUID) -> Color {
        let colors: [Color] = [.blue, .orange, .purple, .green, .pink]
        let index = abs(id.hashValue) % colors.count
        return colors[index]
    }

    // DEBUG helpers
    private func debugLabel(_ state: CleaningState) -> String {
        switch state {
        case .pending: "待清理"
        case .cleaning: "清理中"
        case .done: "已清理"
        case .skipped: "跳过"
        }
    }

    private func debugColor(_ state: CleaningState) -> Color {
        switch state {
        case .pending: .gray
        case .cleaning: .orange
        case .done: .green
        case .skipped: .red
        }
    }
}
