import AppKit

/// 提示词助手：用本地 Ollama 理解对话上下文，决定「重画」还是「局部修改」，并改写成图像模型易懂的正面描述
enum Assistant {
    struct Result: Decodable {
        let mode: String    // generate | edit
        let prompt: String
        let reason: String
    }

    static let endpoint = URL(string: "http://localhost:11434")!

    static let system = """
    你是 Qwen-Image 图像模型的提示词助手。把用户的话转换成图像模型最容易理解的提示词，输出 JSON：{"mode": "generate" 或 "edit", "prompt": "...", "reason": "一句话说明"}。

    规则：
    1. 只用肯定句描述画面最终的样子。禁止出现任何否定或对比的说法（不要、不是、而不是、没有、无、原来、现在的视角是、改成）。图像模型读到“太空”就会画太空、读到“没有地球”也会画地球，所以不希望出现的东西一个字都别写，直接写希望出现的东西来替代。
    2. 把空间关系、视角、主体位置写得具体明确，例如“镜头位于舱内，柴犬漂浮在舱内前景，背景是舷窗，窗外是地球”。
    3. 引号里要写在画面上的文字原样保留。
    4. mode 判断：
       - 有上一张图时，默认 mode=edit：用户是在对上一张图提修改意见，图像模型会以上一张图为底图进行修改。
         · 小改（改颜色、增减物品、改表情或动作、换风格、换光线、换背景）→ prompt 写成一句简洁的编辑指令，结尾加“其余保持不变”。
         · 大改（改变视角、构图、主体位置、场景布局）→ prompt 写成清晰完整的编辑指令，直接描述修改后的目标画面，并点明要保留的东西，例如“将画面改为从太空站舱内拍摄：柴犬宇航员漂浮在舱内前景，身后是舷窗，窗外是地球，保持柴犬的外貌、宇航服和胶片质感”。
       - 只有当用户明确要求画一张全新的、和上一张无关的图（例如“重新画一张”“换个完全不同的”“来一只猫”这种新主题）→ mode=generate，写一段完整独立的新画面描述（80~150 字）。
       - 没有上一张图 → mode=generate，把用户描述扩写成细节丰富的画面描述（60~120 字）。
    5. 忠于用户：扩写只补充用户已提到元素的细节（材质、光线、镜头、构图、画质），不添加用户没提到的主体、场景、道具或背景主题。用户没指定背景时，用简洁干净的背景（例如纯色渐变或柔和虚化的环境），不要自己发明宇宙、城市、森林之类的场景。“漂浮在空中”就是悬浮在空中，不等于太空。
    6. 输出语言与用户一致。
    """

    static func rewrite(text: String, previousPrompt: String?, model: String) async throws -> Result {
        let user = "上一张图的提示词：\(previousPrompt ?? "（无，这是第一张）")\n\n用户的话：\(text)"
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "think": false,
            "keep_alive": "30m",
            "options": ["temperature": 0.4],
            "format": [
                "type": "object",
                "properties": [
                    "mode": ["type": "string", "enum": ["generate", "edit"]],
                    "prompt": ["type": "string"],
                    "reason": ["type": "string"],
                ],
                "required": ["mode", "prompt", "reason"],
            ],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        var req = URLRequest(url: endpoint.appending(path: "api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 180

        struct Reply: Decodable { struct Msg: Decodable { let content: String }; let message: Msg }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "Assistant", code: 1, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Ollama 返回错误"])
        }
        let content = try JSONDecoder().decode(Reply.self, from: data).message.content
        return try JSONDecoder().decode(Result.self, from: Data(content.utf8))
    }

    // MARK: - 官方提示词改写模型（Qwen-Image-2.1-PE）

    enum PETask: String { case t2i, edit }

    static let peModels: [PETask: String] = [
        .t2i: "hf.co/prithivMLmods/Qwen-Image-2.1-PE-T2I-GGUF:Q4_K_M",
        .edit: "hf.co/prithivMLmods/Qwen-Image-2.1-PE-I2I-GGUF:Q4_K_M",
    ]

    /// 官方 system prompt（Qwen Research License），首次使用时从官方仓库下载并缓存
    static func peSystemPrompt(_ task: PETask, cacheDir: URL) async throws -> String {
        let name = task == .t2i ? "system_prompt_t2i.txt" : "system_prompt_edit.txt"
        let local = cacheDir.appending(path: name)
        if let s = try? String(contentsOf: local, encoding: .utf8), !s.isEmpty { return s }
        let url = URL(string: "https://raw.githubusercontent.com/QwenLM/Qwen-Image-2.1/main/prompt_rewrite/prompts/\(name)")!
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let s = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "Assistant", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法下载官方 system prompt"])
        }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? data.write(to: local)
        return s
    }

    struct PEResult {
        var prompt: String
        var whRatio: String       // 例如 "3:2"，为空表示没指定
        var ratioFollow: String   // 例如 "<image1>"，仅改图
        var seconds: Double
    }

    /// 按官方参数调用：开启思考，temperature 1.0，top_p 0.95；图片按训练时的上限缩到 1MP 以内，放在文字前面
    static func rewriteOfficial(_ task: PETask, text: String, images: [URL], cacheDir: URL) async throws -> PEResult {
        let system = try await peSystemPrompt(task, cacheDir: cacheDir)
        var user: [String: Any] = ["role": "user", "content": text]
        if task == .edit { user["images"] = images.compactMap(encodeImage) }
        var options: [String: Any] = ["temperature": 1.0, "top_p": 0.95, "top_k": 20, "num_ctx": 16384, "num_predict": 8192]
        if task == .t2i { options["presence_penalty"] = 1.5 }
        let body: [String: Any] = [
            "model": peModels[task]!,
            "stream": false,
            "think": true,
            "keep_alive": "30m",
            "options": options,
            "messages": [["role": "system", "content": system], user],
        ]
        var req = URLRequest(url: endpoint.appending(path: "api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 600

        let start = Date()
        struct Reply: Decodable { struct Msg: Decodable { let content: String; let thinking: String? }; let message: Msg }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "Assistant", code: 1, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Ollama 返回错误"])
        }
        let msg = try JSONDecoder().decode(Reply.self, from: data).message
        // 有的模板不拆分思考内容，这里兼容 </think> 混在正文里的情况
        var answer = msg.content
        if let r = answer.range(of: "</think>") { answer = String(answer[r.upperBound...]) }
        guard let obj = lastJSONObject(in: answer),
              let prompt = (obj["rewritten_prompt"] ?? obj["rewrited_prompt"]) as? String,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "Assistant", code: 3, userInfo: [NSLocalizedDescriptionKey: "官方改写模型没有返回有效结果"])
        }
        return PEResult(prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                        whRatio: (obj["wh_ratio"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                        ratioFollow: (obj["ratio_follow"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                        seconds: Date().timeIntervalSince(start))
    }

    /// 从回答里找最后一个能解析的 JSON 对象
    static func lastJSONObject(in text: String) -> [String: Any]? {
        let chars = Array(text)
        var ends: [Int] = []
        for (i, c) in chars.enumerated() where c == "}" { ends.append(i) }
        for end in ends.reversed() {
            var depth = 0
            var i = end
            while i >= 0 {
                if chars[i] == "}" { depth += 1 } else if chars[i] == "{" { depth -= 1; if depth == 0 { break } }
                i -= 1
            }
            guard i >= 0 else { continue }
            let candidate = String(chars[i...end])
            if let d = candidate.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return obj }
        }
        return nil
    }

    /// 缩到 1MP 以内，转 JPEG 后 base64
    static func encodeImage(_ url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let scale = min(1, (1_048_576 / Double(w * h)).squareRoot())
        let maxSide = Int(Double(max(w, h)) * scale)
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ] as CFDictionary) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])?.base64EncodedString()
    }

    /// Ollama 拉取模型（流式进度）
    static func pull(_ name: String, progress: @escaping @MainActor (Double, String) -> Void) async throws {
        var req = URLRequest(url: endpoint.appending(path: "api/pull"))
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": name, "stream": true])
        req.timeoutInterval = 3600
        let (bytes, _) = try await URLSession.shared.bytes(for: req)
        for try await line in bytes.lines {
            guard let d = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if let err = obj["error"] as? String { throw NSError(domain: "Assistant", code: 4, userInfo: [NSLocalizedDescriptionKey: err]) }
            let status = obj["status"] as? String ?? ""
            let total = (obj["total"] as? Double) ?? 0, done = (obj["completed"] as? Double) ?? 0
            await progress(total > 0 ? done / total : 0, status)
        }
    }

    static func models() async -> [String] {
        struct Tags: Decodable { struct M: Decodable { let name: String }; let models: [M] }
        guard let (data, _) = try? await URLSession.shared.data(from: endpoint.appending(path: "api/tags")),
              let tags = try? JSONDecoder().decode(Tags.self, from: data) else { return [] }
        return tags.models.map(\.name)
    }
}
