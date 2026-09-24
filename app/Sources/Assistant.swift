import Foundation

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
       - 有上一张图时：如果用户想改变构图、视角、主体位置、场景布局，或者不满意想整体重来 → mode=generate，结合上一张图的提示词和用户意见，写一段完整独立的新画面描述（80~150 字），保留上一张中用户没有要求改变的元素（主体、风格、质感等）。
       - 有上一张图，且只是局部改动（改颜色、增减物品、改表情或动作、换风格、换光线、换背景）→ mode=edit，prompt 写成一句简洁的编辑指令，结尾加“其余保持不变”。
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

    static func models() async -> [String] {
        struct Tags: Decodable { struct M: Decodable { let name: String }; let models: [M] }
        guard let (data, _) = try? await URLSession.shared.data(from: endpoint.appending(path: "api/tags")),
              let tags = try? JSONDecoder().decode(Tags.self, from: data) else { return [] }
        return tags.models.map(\.name)
    }
}
