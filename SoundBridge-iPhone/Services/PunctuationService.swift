import Foundation
import OnnxRuntimeBindings

final class PunctuationService: @unchecked Sendable {
    private let env: ORTEnv
    private let session: ORTSession
    private let token2id: [String: Int]
    private let unkId: Int
    private let punctuations: [String]  // index -> punct string
    private let underscoreId: Int

    init?() {
        guard let modelPath = Bundle.main.path(forResource: "model_int8", ofType: "onnx"),
              let vocabPath = Bundle.main.path(forResource: "punc_vocab", ofType: "json")
        else {
            print("[PuncService] 模型或词表文件未找到")
            return nil
        }

        // 加载词表
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: vocabPath))
            let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let tokensDict = json["tokens"] as! [String: Int]
            self.token2id = tokensDict
            self.unkId = json["unk_id"] as! Int
            self.punctuations = json["punctuations"] as! [String]
            self.underscoreId = punctuations.firstIndex(of: "_") ?? 1
        } catch {
            print("[PuncService] 词表加载失败: \(error)")
            return nil
        }

        // 初始化 ORT
        do {
            self.env = try ORTEnv(loggingLevel: .warning)
            let opts = try ORTSessionOptions()
            try opts.setIntraOpNumThreads(2)
            self.session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: opts)
        } catch {
            print("[PuncService] ORT 初始化失败: \(error)")
            return nil
        }
    }

    /// 为纯文本添加标点符号
    func addPunctuation(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        // 分词：中文按字符，英文按单词
        let words = tokenize(text)
        guard !words.isEmpty else { return text }

        // token -> id
        var ids: [Int32] = []
        var charMap: [String] = []  // 每个 id 对应的原始字符/词

        for word in words {
            if word.unicodeScalars.first.map({ $0.value > 127 }) == true {
                // 中文字符：逐字
                for c in word {
                    let s = String(c)
                    ids.append(Int32(token2id[s] ?? unkId))
                    charMap.append(s)
                }
            } else {
                // 英文单词：整词
                ids.append(Int32(token2id[word.lowercased()] ?? unkId))
                charMap.append(word)
            }
        }

        // 推理
        guard let puncIds = runInference(ids: ids) else { return text }

        // 拼接结果
        var result: [String] = []
        for (i, p) in puncIds.enumerated() {
            guard i < charMap.count else { break }
            // 英文词之间加空格
            if !result.isEmpty,
               let lastChar = result.last?.last,
               lastChar.asciiValue != nil,
               charMap[i].first?.asciiValue != nil {
                result.append(" ")
            }
            result.append(charMap[i])
            if p != underscoreId, p > 0, p < punctuations.count {
                result.append(punctuations[p])
            }
        }

        return result.joined()
    }

    // MARK: - Private

    private func tokenize(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""

        for c in text {
            let isMultibyte = String(c).utf8.count > 1

            if current.isEmpty {
                current = String(c)
            } else {
                let lastIsMultibyte = String(current.last!).utf8.count > 1
                if isMultibyte == lastIsMultibyte {
                    current.append(c)
                } else {
                    words.append(current)
                    current = String(c)
                }
            }
        }
        if !current.isEmpty {
            words.append(current)
        }
        return words
    }

    private func runInference(ids: [Int32]) -> [Int]? {
        do {
            let seqLen = ids.count

            // 创建输入 tensor: inputs [1, seqLen]
            let inputData = ids.withUnsafeBufferPointer { Data(buffer: $0) }
            let inputValue = try ORTValue(
                tensorData: NSMutableData(data: inputData),
                elementType: .int32,
                shape: [1, NSNumber(value: seqLen)]
            )

            // 创建输入 tensor: text_lengths [1]
            var lengthArray: [Int32] = [Int32(seqLen)]
            let lengthData = lengthArray.withUnsafeMutableBufferPointer { Data(buffer: $0) }
            let lengthValue = try ORTValue(
                tensorData: NSMutableData(data: lengthData),
                elementType: .int32,
                shape: [1]
            )

            // 运行推理
            let outputs = try session.run(
                withInputs: ["inputs": inputValue, "text_lengths": lengthValue],
                outputNames: ["logits"],
                runOptions: nil
            )

            guard let logitsValue = outputs["logits"] else { return nil }
            let logitsData = try logitsValue.tensorData() as Data

            // logits shape: [1, seqLen, 6], float32
            let floats: [Float] = logitsData.withUnsafeBytes { bytes in
                Array(bytes.bindMemory(to: Float.self))
            }

            let numClasses = punctuations.count  // 6
            var result: [Int] = []
            for i in 0..<seqLen {
                let offset = i * numClasses
                var maxIdx = 0
                var maxVal = floats[offset]
                for j in 1..<numClasses {
                    if floats[offset + j] > maxVal {
                        maxVal = floats[offset + j]
                        maxIdx = j
                    }
                }
                result.append(maxIdx)
            }

            return result
        } catch {
            print("[PuncService] 推理失败: \(error)")
            return nil
        }
    }
}
