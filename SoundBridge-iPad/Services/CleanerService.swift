import Foundation
import MLX
import MLXLLM
import MLXLMCommon

enum CleanerStatus: Sendable {
    case notReady
    case loading
    case ready
    case failed(String)
}

@MainActor
@Observable
final class CleanerService {
    private(set) var status: CleanerStatus = .notReady

    private var modelContainer: ModelContainer?

    func prepare() async {
        guard case .notReady = status else { return }
        status = .loading

        do {
            guard let modelDir = Bundle.main.url(
                forResource: Constants.cleanerModelDir,
                withExtension: nil
            ) else {
                status = .failed("模型目录未找到")
                NSLog("[Cleaner] 模型目录未找到: %@", Constants.cleanerModelDir)
                return
            }

            let config = ModelConfiguration(directory: modelDir)
            let container = try await LLMModelFactory.shared.loadContainer(
                configuration: config
            )
            modelContainer = container
            status = .ready
            NSLog("[Cleaner] 模型加载完成")
        } catch {
            status = .failed(error.localizedDescription)
            NSLog("[Cleaner] 模型加载失败: %@", error.localizedDescription)
        }
    }

    /// 流式清洁文本，逐 token 返回
    func cleanStream(rawText: String, locale: String) -> AsyncStream<String> {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let container = modelContainer else {
            return AsyncStream { $0.finish() }
        }

        let prompt = Self.buildPrompt(rawText: text, locale: locale)
        NSLog("[Cleaner] cleanStream 输入: %@", text)

        return AsyncStream { continuation in
            let task = Task.detached { [prompt] in
                do {
                    try await container.perform { context in
                        let input = UserInput(prompt: prompt)
                        let lmInput = try await context.processor.prepare(input: input)

                        let parameters = GenerateParameters(
                            maxTokens: Constants.cleanerMaxTokens,
                            temperature: Constants.cleanerTemperature
                        )

                        let stream = try MLXLMCommon.generate(
                            input: lmInput,
                            parameters: parameters,
                            context: context
                        )

                        for await generation in stream {
                            switch generation {
                            case .chunk(let text):
                                continuation.yield(text)
                            case .info:
                                break
                            case .toolCall:
                                break
                            }
                        }

                        continuation.finish()
                    }
                } catch {
                    NSLog("[Cleaner] 推理失败: %@", error.localizedDescription)
                    continuation.finish()
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// 非流式清洁，带超时 fallback
    func clean(rawText: String, locale: String) async -> String? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, modelContainer != nil else { return nil }

        var collected = ""
        let stream = cleanStream(rawText: text, locale: locale)

        for await token in stream {
            collected += token
        }

        return collected.isEmpty ? nil : collected
    }

    // MARK: - Prompt

    nonisolated private static func buildPrompt(rawText: String, locale: String) -> String {
        let langName = locale.hasPrefix("yue") ? "粤语" : "普通话"
        let dialectHint = locale.hasPrefix("yue")
            ? "\n6. 保留粤语口语词和语气词（例如：啦、喇、咯、咩、嘅、呢），不要自行替换成普通话。"
            : ""
        return """
        你是语音转文字的后处理助手。请对以下\(langName)语音识别文本做最小改动清理：
        1. 仅修正明显错字和明显断句问题。
        2. 不要删除任何词，不要压缩内容，不要总结，不要改写语序。
        3. 时间、数字、人名、地名、药名、英文单词必须保留。
        4. 如果不确定，保持原文不变。
        5. 只输出处理后的文本，不要加任何前缀或说明。\(dialectHint)

        原文：\(rawText)
        """
    }
}
