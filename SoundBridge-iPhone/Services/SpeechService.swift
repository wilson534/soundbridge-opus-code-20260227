import AVFoundation
import Speech
import os.log

private let sbLog = Logger(subsystem: "com.soundbridge.phone", category: "Speech")

/// 线程安全的音频广播器：tap 装一次不动，通过切换 request 引用实现 session 热切换
private final class AudioBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [SFSpeechAudioBufferRecognitionRequest] = []

    func set(_ request: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock()
        requests = [request]
        lock.unlock()
    }

    func add(_ request: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    func remove(_ request: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock()
        requests.removeAll { $0 === request }
        lock.unlock()
    }

    func clear() {
        lock.lock()
        requests.removeAll()
        lock.unlock()
    }

    func broadcast(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = requests
        lock.unlock()
        for req in current {
            req.append(buffer)
        }
    }
}

@MainActor
@Observable
final class SpeechService {
    var isListening = false
    var displayText = ""
    var debugLog = ""
    var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined

    var onTranscript: ((String, Bool, Int) -> Void)?

    private let puncService: PunctuationService? = {
        let svc = PunctuationService()
        print("[SB] PunctuationService 初始化: \(svc != nil ? "成功" : "失败")")
        return svc
    }()

    private var recognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var broadcaster: AudioBroadcaster?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var currentTask: SFSpeechRecognitionTask?
    private var sequence = 0
    private var locale: String = "zh-CN"
    private var sessionGeneration = 0
    private var sessionConsumed = 0
    private var rawUnfinalized = ""
    private var finalizedRawText = ""

    // 60s rotation
    private var nextRequest: SFSpeechAudioBufferRecognitionRequest?
    private var nextTask: SFSpeechRecognitionTask?
    private var sessionTimer: Timer?
    private var silenceTimer: Timer?
    private var utteranceTimer: Timer?
    private var puncTimer: Timer?

    private func log(_ msg: String) {
        debugLog += "\n\(msg)"
        sbLog.info("[SB] \(msg)")
    }

    // MARK: - Authorization

    func requestAuthorization() async -> Bool {
        let mic: Bool
        if AVAudioApplication.shared.recordPermission == .granted {
            mic = true
        } else {
            mic = await AVAudioApplication.requestRecordPermission()
        }
        guard mic else { return false }

        let speech = SFSpeechRecognizer.authorizationStatus()
        if speech == .authorized {
            authorizationStatus = .authorized
            return true
        }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                Task { @MainActor in
                    self.authorizationStatus = status
                    continuation.resume(returning: status == .authorized)
                }
            }
        }
    }

    // MARK: - Audio Tap

    nonisolated private static func installBroadcastTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        broadcaster: AudioBroadcaster
    ) {
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            broadcaster.broadcast(buffer)
        }
    }

    // MARK: - Start / Stop

    func startListening() {
        guard !isListening else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            log("音频会话失败: \(error)")
            return
        }

        recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))

        guard let recognizer, recognizer.isAvailable else {
            log("识别器不可用")
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        req.addsPunctuation = true
        request = req
        sessionConsumed = 0

        sessionGeneration += 1
        let gen = sessionGeneration

        currentTask = recognizer.recognitionTask(with: req) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorDesc = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, gen == self.sessionGeneration else { return }
                if let errorDesc { self.log("识别错误: \(errorDesc)") }
                if let text { self.handleResult(text: text, isFinal: isFinal) }
                if isFinal, self.isListening {
                    self.log("isFinal → 热切换 session")
                    self.restartRecognitionSession()
                    self.scheduleSessionRotation()
                } else if error != nil, self.isListening {
                    self.restartRecognitionSession()
                }
            }
        }

        // 创建广播器，tap 只装一次
        let bc = AudioBroadcaster()
        bc.set(req)
        broadcaster = bc

        let engine = AVAudioEngine()
        audioEngine = engine

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            log("音频格式无效")
            currentTask?.cancel()
            currentTask = nil
            request = nil
            broadcaster = nil
            return
        }

        Self.installBroadcastTap(on: inputNode, format: format, broadcaster: bc)

        do {
            try engine.start()
        } catch {
            log("引擎启动失败: \(error)")
            inputNode.removeTap(onBus: 0)
            currentTask?.cancel()
            currentTask = nil
            request = nil
            audioEngine = nil
            broadcaster = nil
            return
        }

        isListening = true
        scheduleSessionRotation()
    }

    func stopListening() {
        guard isListening else { return }
        isListening = false
        invalidateAllTimers()

        broadcaster?.clear()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        broadcaster = nil

        request?.endAudio()
        currentTask?.cancel()
        nextRequest?.endAudio()
        nextTask?.cancel()

        request = nil
        currentTask = nil
        nextRequest = nil
        nextTask = nil
    }

    func switchLocale(to newLocale: String) {
        locale = newLocale
        if isListening {
            stopListening()
            startListening()
        }
    }

    // MARK: - Result Handling

    private func handleResult(text: String, isFinal: Bool) {
        if sessionConsumed > text.count {
            log("增量偏移越界，重置 consumed: consumed=\(sessionConsumed), textCount=\(text.count)")
            sessionConsumed = 0
        }

        let newContent = String(text.dropFirst(sessionConsumed))
        log("识别结果: final=\(isFinal), textCount=\(text.count), consumed=\(sessionConsumed), newCount=\(newContent.count), seq=\(sequence)")
        rawUnfinalized = newContent
        resetSilenceTimer()

        if isFinal {
            puncTimer?.invalidate()
            puncTimer = nil
            sequence += 1
            finalizedRawText += newContent
            let punctuated = puncService?.addPunctuation(finalizedRawText) ?? finalizedRawText
            displayText = punctuated
            sessionConsumed = 0
            rawUnfinalized = ""
            onTranscript?(punctuated, true, sequence)
            finalizedRawText = ""
            resetUtteranceTimer()
        } else {
            schedulePunctuationUpdate()
            onTranscript?(finalizedRawText + newContent, false, sequence)
            startUtteranceTimerIfNeeded()
        }
    }

    private func schedulePunctuationUpdate() {
        guard puncTimer == nil else { return }
        puncTimer = Timer.scheduledTimer(
            withTimeInterval: 0.8,
            repeats: false
        ) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.puncTimer = nil
                let fullRaw = self.finalizedRawText + self.rawUnfinalized
                guard !fullRaw.isEmpty else { return }
                let punctuated = self.puncService?.addPunctuation(fullRaw) ?? fullRaw
                self.displayText = punctuated
            }
        }
    }

    private func finalizeCurrentPartial() {
        let partialText = rawUnfinalized
        if !partialText.isEmpty {
            puncTimer?.invalidate()
            puncTimer = nil
            sequence += 1
            finalizedRawText += partialText
            let punctuated = puncService?.addPunctuation(finalizedRawText) ?? finalizedRawText
            displayText = punctuated
            sessionConsumed += partialText.count
            rawUnfinalized = ""
            onTranscript?(punctuated, true, sequence)
            finalizedRawText = ""
            resetUtteranceTimer()
            log("静默分段 finalize: seq=\(sequence), partialCount=\(partialText.count), consumed=\(sessionConsumed)")
        }
    }

    // MARK: - Session Hot-Swap (tap 不动，只换 request)

    private func restartRecognitionSession() {
        request?.endAudio()
        currentTask?.cancel()

        guard let recognizer, let broadcaster else {
            log("recognizer 或 broadcaster 为 nil")
            return
        }

        // recognizer 暂时不可用时延迟重试
        if !recognizer.isAvailable {
            log("识别器暂时不可用，0.5s 后重试")
            sessionTimer?.invalidate()
            sessionTimer = Timer.scheduledTimer(
                withTimeInterval: 0.5,
                repeats: false
            ) { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isListening else { return }
                    self.restartRecognitionSession()
                    self.scheduleSessionRotation()
                }
            }
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        req.addsPunctuation = true
        request = req
        sessionConsumed = 0

        // 热切换：只换 broadcaster 里的 request 引用，tap 不动，音频不断
        broadcaster.set(req)

        sessionGeneration += 1
        let gen = sessionGeneration

        currentTask = recognizer.recognitionTask(with: req) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorDesc = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, gen == self.sessionGeneration else { return }
                if let errorDesc { self.log("识别错误: \(errorDesc)") }
                if let text { self.handleResult(text: text, isFinal: isFinal) }
                if isFinal, self.isListening {
                    self.log("isFinal → 热切换 session")
                    self.restartRecognitionSession()
                    self.scheduleSessionRotation()
                } else if error != nil, self.isListening {
                    self.restartRecognitionSession()
                }
            }
        }
    }

    // MARK: - 60s Rotation

    private func scheduleSessionRotation() {
        sessionTimer?.invalidate()
        sessionTimer = Timer.scheduledTimer(
            withTimeInterval: Constants.rotationWarning,
            repeats: false
        ) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performRotation()
            }
        }
    }

    private func performRotation() {
        guard isListening, let recognizer, recognizer.isAvailable, let broadcaster else { return }

        // 先 finalize 当前未完成的文本
        finalizeCurrentPartial()

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        req.addsPunctuation = true
        nextRequest = req

        // 新 request 加入广播器，开始双路接收音频
        broadcaster.add(req)

        sessionGeneration += 1
        let gen = sessionGeneration
        sessionConsumed = 0

        nextTask = recognizer.recognitionTask(with: req) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor [weak self] in
                guard let self, gen == self.sessionGeneration, self.isListening else { return }
                if let text { self.handleResult(text: text, isFinal: isFinal) }
                if isFinal, self.isListening {
                    self.restartRecognitionSession()
                    self.scheduleSessionRotation()
                }
            }
        }

        // overlap 结束后切换到新 session
        Timer.scheduledTimer(
            withTimeInterval: Constants.overlapDuration,
            repeats: false
        ) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }

                // 从广播器移除旧 request，结束旧 session
                if let oldReq = self.request {
                    self.broadcaster?.remove(oldReq)
                    oldReq.endAudio()
                }
                self.currentTask?.cancel()

                self.request = self.nextRequest
                self.currentTask = self.nextTask
                self.nextRequest = nil
                self.nextTask = nil

                self.scheduleSessionRotation()
            }
        }
    }

    // MARK: - Silence Timer

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(
            withTimeInterval: Constants.silenceTimeout,
            repeats: false
        ) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let hadPartial = !self.rawUnfinalized.isEmpty
                self.finalizeCurrentPartial()
                if hadPartial, self.isListening {
                    self.log("静默触发后重建识别会话")
                    self.restartRecognitionSession()
                    self.scheduleSessionRotation()
                }
            }
        }
    }

    // MARK: - Utterance Timer (30s)

    private func startUtteranceTimerIfNeeded() {
        guard utteranceTimer == nil else { return }
        utteranceTimer = Timer.scheduledTimer(
            withTimeInterval: Constants.utteranceTimeout,
            repeats: false
        ) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.finalizeCurrentPartial()
                self.utteranceTimer = nil
            }
        }
    }

    private func resetUtteranceTimer() {
        utteranceTimer?.invalidate()
        utteranceTimer = nil
    }

    private func invalidateAllTimers() {
        sessionTimer?.invalidate()
        silenceTimer?.invalidate()
        utteranceTimer?.invalidate()
        puncTimer?.invalidate()
        sessionTimer = nil
        silenceTimer = nil
        utteranceTimer = nil
        puncTimer = nil
    }
}
