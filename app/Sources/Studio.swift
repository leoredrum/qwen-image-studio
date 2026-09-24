import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class Studio {
    // MARK: 状态
    var items: [ChatItem] = []
    var selectedItemID: UUID?
    var selectedOutput: String?
    var draft = ""
    var refImages: [String] = []  // 相对 outputs/ 的路径
    var settings = Settings.load() { didSet { if settings != oldValue { settings.save() } } }

    var diffusionModels: [String] = []
    var textEncoders: [String] = []
    var vaePath: String?
    var visionPath: String?

    var runningID: UUID?
    var progress = RunProgress()
    var previewImage: NSImage?
    var logTail: [String] = []
    var showModelManager = false
    var showLog = false

    let engine = Engine()
    let downloader = Downloader()

    @ObservationIgnored private let thumbCache = NSCache<NSString, NSImage>()
    @ObservationIgnored private var previewPath: URL?
    @ObservationIgnored private var previewStamp: Date?

    // MARK: 路径
    var root: URL {
        get { URL(fileURLWithPath: UserDefaults.standard.string(forKey: "studio.root") ?? Self.defaultRoot) }
        set { UserDefaults.standard.set(newValue.path, forKey: "studio.root"); refreshModels(); loadHistory() }
    }
    var modelsDir: URL { root.appending(path: "models") }
    var outputsDir: URL { root.appending(path: "outputs") }
    /// 优先使用 app 自带的推理引擎，其次是工作目录下的 bin/sd-cli
    var sdCLI: URL {
        if let u = Bundle.main.url(forResource: "sd-cli", withExtension: nil, subdirectory: "bin") { return u }
        return root.appending(path: "bin/sd-cli")
    }

    /// 老用户沿用 ~/Documents/Qwen image，新用户使用 ~/Documents/Qwen Image Studio
    static var defaultRoot: String {
        let legacy = NSHomeDirectory() + "/Documents/Qwen image"
        if FileManager.default.fileExists(atPath: legacy + "/models") { return legacy }
        return NSHomeDirectory() + "/Documents/Qwen Image Studio"
    }

    /// 本机内存（GB）
    let memoryGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)

    /// Ollama 是否可用（提示词助手依赖它）
    var ollamaModels: [String]? = nil
    var assistantAvailable: Bool { !(ollamaModels ?? []).isEmpty }
    var historyURL: URL { outputsDir.appending(path: "history.json") }

    func url(_ rel: String) -> URL { outputsDir.appending(path: rel) }

    init() {
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        // 从网上下载的 app 内置引擎可能带隔离标记，app 本身被放行后顺手清掉，避免子进程被拦
        removexattr(sdCLI.path, "com.apple.quarantine", 0)
        refreshModels()
        loadHistory()
        downloader.onFinish = { [weak self] in self?.refreshModels() }
        Task { await checkOllama() }
    }

    func checkOllama() async {
        let models = await Assistant.models()
        ollamaModels = models
        // 设置里的模型不存在时，自动换成本机已有的 qwen 系列模型
        if !models.isEmpty && !models.contains(settings.assistantModel) {
            let preferred = models.first { $0.hasPrefix("qwen3") } ?? models.first { $0.hasPrefix("qwen") } ?? models[0]
            settings.assistantModel = preferred
        }
    }

    // MARK: 一键安装
    /// 按内存推荐的去噪模型
    var recommendedDiffusion: String {
        switch memoryGB {
        case 48...: "qwen-image-2.1-Q8_0.gguf"
        case 32..<48: "qwen-image-2.1-Q6_K.gguf"
        case 20..<32: "qwen-image-2.1-Q5_K_M.gguf"
        case 14..<20: "qwen-image-2.1-Q4_K_M.gguf"
        default: "qwen-image-2.1-Q3_K_M.gguf"
        }
    }

    var recommendedFiles: [RemoteFile] { installPlan ?? [] }
    var installPlan: [RemoteFile]?

    func loadInstallPlan() async {
        guard installPlan == nil else { return }
        let want = recommendedDiffusion
        async let d = try? Catalog.list(repo: Catalog.diffusionRepo) { $0 == want }
        async let e = try? Catalog.list(repo: Catalog.encoderRepo) { $0 == "Qwen3-VL-8B-Instruct-UD-Q4_K_XL.gguf" || $0 == "mmproj-BF16.gguf" }
        async let v = try? Catalog.list(repo: Catalog.vaeRepo, filter: { $0.hasPrefix("vae/") && $0.hasSuffix(".safetensors") }, localPrefix: "vae/")
        let all = (await d ?? []) + (await e ?? []) + (await v ?? [])
        if !all.isEmpty { installPlan = all }
    }

    func isInstalled(_ f: RemoteFile) -> Bool {
        FileManager.default.fileExists(atPath: modelsDir.appending(path: f.localRel).path)
    }

    func installRecommended() {
        for f in recommendedFiles where !isInstalled(f) { downloader.start(f, modelsDir: modelsDir) }
    }

    // MARK: 模型扫描
    func refreshModels() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: modelsDir.path)) ?? []
        let ggufs = files.filter { $0.hasSuffix(".gguf") }.sorted()
        diffusionModels = ggufs.filter { $0.lowercased().hasPrefix("qwen-image") }
        textEncoders = ggufs.filter { $0.hasPrefix("Qwen3-VL") || $0.hasPrefix("Qwen2.5-VL") }
        visionPath = ggufs.first { $0.hasPrefix("mmproj") }.map { modelsDir.appending(path: $0).path }
        let vaeDir = modelsDir.appending(path: "vae")
        let vaes = ((try? fm.contentsOfDirectory(atPath: vaeDir.path)) ?? []).filter { $0.hasSuffix(".safetensors") }
        vaePath = vaes.first.map { vaeDir.appending(path: $0).path }

        if !diffusionModels.contains(settings.diffusionModel), let f = diffusionModels.last(where: { $0.contains("Q8") }) ?? diffusionModels.first {
            settings.diffusionModel = f
        }
        if !textEncoders.contains(settings.textEncoder), let f = textEncoders.first {
            settings.textEncoder = f
        }
    }

    var setupProblem: String? {
        if !FileManager.default.isExecutableFile(atPath: sdCLI.path) { return "找不到推理引擎 sd-cli" }
        if diffusionModels.isEmpty { return "还没有去噪模型，请在「模型管理」中下载" }
        if textEncoders.isEmpty { return "还没有文本编码器，请在「模型管理」中下载" }
        if vaePath == nil { return "缺少 VAE，请在「模型管理」中下载" }
        return nil
    }

    // MARK: 历史
    func loadHistory() {
        try? FileManager.default.createDirectory(at: outputsDir.appending(path: "refs"), withIntermediateDirectories: true)
        guard let d = try? Data(contentsOf: historyURL),
              var list = try? JSONDecoder().decode([ChatItem].self, from: d) else { items = []; return }
        for i in list.indices where [.running, .queued, .thinking].contains(list[i].status) {
            list[i].status = .cancelled
        }
        items = list
        selectedItemID = items.last(where: { !$0.outputs.isEmpty })?.id
        selectedOutput = items.last(where: { !$0.outputs.isEmpty })?.outputs.first
    }

    func saveHistory() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let d = try? enc.encode(items) { try? d.write(to: historyURL, options: .atomic) }
    }

    func delete(_ item: ChatItem) {
        if item.id == runningID { cancel() }
        if item.status == .thinking { update(item.id) { $0.status = .cancelled } }
        items.removeAll { $0.id == item.id }
        if selectedItemID == item.id { selectedItemID = nil; selectedOutput = nil }
        saveHistory()
    }

    func clearHistory() {
        if runningID != nil { cancel() }
        items.removeAll()
        selectedItemID = nil
        selectedOutput = nil
        saveHistory()
    }

    var selectedItem: ChatItem? { items.first { $0.id == selectedItemID } }

    func select(_ item: ChatItem, output: String? = nil) {
        selectedItemID = item.id
        selectedOutput = output ?? item.outputs.first
    }

    // MARK: 图片
    func image(_ rel: String) -> NSImage? { NSImage(contentsOf: url(rel)) }

    func thumbnail(_ rel: String, size: CGFloat = 360) -> NSImage? {
        let key = "\(rel)@\(Int(size))" as NSString
        if let img = thumbCache.object(forKey: key) { return img }
        guard let src = CGImageSourceCreateWithURL(url(rel) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: size,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbCache.setObject(img, forKey: key)
        return img
    }

    /// 参考图统一转成 PNG 存进 outputs/refs，保证 sd-cli 能读、历史可复现
    func addReference(_ source: URL) {
        guard let img = NSImage(contentsOf: source) else { return }
        addReference(img)
    }

    func addReference(_ img: NSImage) {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let rel = "refs/\(UUID().uuidString.prefix(8)).png"
        try? png.write(to: url(rel))
        if refImages.count < 10 { refImages.append(rel) }
    }

    func useAsReference(_ rel: String) {
        if !refImages.contains(rel) && refImages.count < 10 { refImages.append(rel) }
    }

    // MARK: 连续修改
    /// 右侧当前显示的已完成图片 —— 「接着改」的底图
    var chainSource: String? {
        guard let item = selectedItem, item.status == .done, let o = selectedOutput, item.outputs.contains(o) else { return nil }
        return o
    }

    var isChaining: Bool {
        guard settings.chainEdits, let c = chainSource else { return false }
        return !refImages.contains(c)
    }

    /// 本次生成实际使用的参考图：接着改的底图 + 手动添加的参考图
    var effectiveRefs: [String] {
        isChaining ? [chainSource!] + refImages.prefix(9) : refImages
    }

    // MARK: 生成
    var targetSize: (Int, Int) {
        if settings.customSize { return (settings.width, settings.height) }
        if settings.followRefSize, let first = effectiveRefs.first, let rep = NSImageRep(contentsOf: url(first)),
           rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return fitSize(aspect: Double(rep.pixelsWide) / Double(rep.pixelsHigh), megapixels: settings.tier.megapixels)
        }
        return presetSize(settings.aspect, settings.tier)
    }

    /// 基于实测速度估算耗时（1024² / 20 步 / CFG 6 下 Q8_0 约 17.8 秒每步）
    var estimate: Double {
        let (w, h) = targetSize
        let mp = Double(w * h) / 1_048_576
        let key = "studio.speed.\(settings.diffusionModel).\(settings.cfg > 1 ? "cfg" : "nocfg")"
        let base = UserDefaults.standard.double(forKey: key)
        let perStepAt1MP = base > 0 ? base : (settings.cfg > 1 ? 17.8 : 9.5)
        return perStepAt1MP * pow(mp, 1.13) * Double(settings.steps * settings.batch) + 10
    }

    private func recordSpeed(_ p: GenParams, secPerStep: Double) {
        guard secPerStep > 0 else { return }
        let mp = Double(p.width * p.height) / 1_048_576
        let key = "studio.speed.\(p.diffusionModel).\(p.cfg > 1 ? "cfg" : "nocfg")"
        UserDefaults.standard.set(secPerStep / pow(mp, 1.13), forKey: key)
    }

    var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && setupProblem == nil }

    func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, setupProblem == nil else { return }
        var s = settings
        if !assistantAvailable { s.assistant = false }
        let (w, h) = targetSize
        var neg = s.negative.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.nsfw { neg = neg.isEmpty ? safetyNegative : neg + ", " + safetyNegative }
        let params = GenParams(
            prompt: prompt, negative: neg, width: w, height: h, steps: s.steps, cfg: s.cfg,
            seed: s.randomSeed ? Int.random(in: 0..<2_147_483_647) : s.seed,
            sampler: s.sampler, scheduler: s.scheduler, batch: s.batch,
            diffusionModel: s.diffusionModel, textEncoder: s.textEncoder,
            nsfw: s.nsfw, fastMode: s.fastMode, refImages: effectiveRefs)
        let chained = isChaining ? chainSource : nil
        draft = ""
        refImages = []
        guard s.assistant else { enqueue(params); return }

        // 先交给提示词助手理解上下文，再入队
        var item = ChatItem(params: params)
        item.params.userText = prompt
        item.status = .thinking
        items.append(item)
        selectedItemID = item.id
        selectedOutput = nil
        let id = item.id
        let previous = chained.flatMap { c in items.first { $0.outputs.contains(c) }?.params.prompt }
        Task {
            do {
                let r = try await Assistant.rewrite(text: prompt, previousPrompt: previous, model: s.assistantModel)
                update(id) { it in
                    it.params.prompt = r.prompt
                    it.params.assistantMode = r.mode
                    it.params.assistantNote = r.reason
                    // 判定为重画：不再以上一张为底图，改为文生图
                    if r.mode == "generate", let c = chained { it.params.refImages.removeAll { $0 == c } }
                }
            } catch {
                update(id) { $0.params.assistantNote = "助手不可用，已按原话生成：\(error.localizedDescription)" }
            }
            update(id) { if $0.status == .thinking { $0.status = .queued } }
            saveHistory()
            pump()
        }
    }

    func enqueue(_ params: GenParams) {
        let item = ChatItem(params: params)
        items.append(item)
        selectedItemID = item.id
        selectedOutput = nil
        saveHistory()
        pump()
    }

    func retry(_ item: ChatItem, newSeed: Bool = false) {
        var p = item.params
        if newSeed { p.seed = Int.random(in: 0..<2_147_483_647) }
        enqueue(p)
    }

    /// 把一条历史的参数和提示词填回输入框
    func reuse(_ item: ChatItem) {
        let p = item.params
        draft = p.userText ?? p.prompt
        refImages = p.refImages
        settings.steps = p.steps
        settings.cfg = p.cfg
        settings.sampler = p.sampler
        settings.scheduler = p.scheduler
        settings.nsfw = p.nsfw
        settings.fastMode = p.fastMode
        settings.seed = p.seed
        settings.randomSeed = false
        if diffusionModels.contains(p.diffusionModel) { settings.diffusionModel = p.diffusionModel }
        if textEncoders.contains(p.textEncoder) { settings.textEncoder = p.textEncoder }
        let match = Aspect.allCases.flatMap { a in SizeTier.allCases.map { (a, $0) } }
            .first { presetSize($0.0, $0.1) == (p.width, p.height) }
        if let (a, t) = match {
            settings.aspect = a; settings.tier = t; settings.customSize = false
        } else {
            settings.customSize = true; settings.width = p.width; settings.height = p.height
        }
    }

    func cancel() { engine.cancel() }

    private func pump() {
        guard runningID == nil, let item = items.first(where: { $0.status == .queued }) else { return }
        Task { await run(item.id) }
    }

    func update(_ id: UUID, _ change: (inout ChatItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }

    private func run(_ id: UUID) async {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let p = item.params
        runningID = id
        progress = RunProgress(imageCount: p.batch)
        previewImage = nil
        logTail = []
        update(id) { $0.status = .running }

        let stamp = DateFormatter.stamp.string(from: Date())
        let prefix = "\(stamp)_\(id.uuidString.prefix(4))"
        let preview = outputsDir.appending(path: ".preview/\(id.uuidString).png")
        try? FileManager.default.createDirectory(at: preview.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: preview)
        previewPath = settings.livePreview ? preview : nil
        previewStamp = nil

        var args = [
            "--diffusion-model", modelsDir.appending(path: p.diffusionModel).path,
            "--vae", vaePath ?? "",
            "--llm", modelsDir.appending(path: p.textEncoder).path,
            "-p", p.prompt,
            "--steps", "\(p.steps)",
            "--cfg-scale", "\(p.cfg)",
            "--sampling-method", p.sampler,
            "-W", "\(p.width)", "-H", "\(p.height)",
            "-s", "\(p.seed)",
            "--diffusion-fa",
            "-o", url(p.batch > 1 ? "\(prefix)_%d.png" : "\(prefix).png").path,
        ]
        if !p.negative.isEmpty { args += ["-n", p.negative] }
        if !p.scheduler.isEmpty { args += ["--scheduler", p.scheduler] }
        if p.batch > 1 { args += ["-b", "\(p.batch)"] }
        for r in p.refImages { args += ["-r", url(r).path] }
        if !p.refImages.isEmpty, let v = visionPath { args += ["--llm_vision", v] }
        if p.fastMode { args += ["--cache-mode", "easycache"] }
        if settings.livePreview { args += ["--preview", "proj", "--preview-path", preview.path] }
        if settings.vaeTiling || p.width * p.height > 3_000_000 { args += ["--vae-tiling"] }

        let start = Date()
        let code = await engine.run(executable: sdCLI, args: args, cwd: root) { [weak self] line in
            self?.handle(line)
        }
        let cancelled = engine.cancelled

        let files = ((try? FileManager.default.contentsOfDirectory(atPath: outputsDir.path)) ?? [])
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".png") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        try? FileManager.default.removeItem(at: preview)

        let dur = Date().timeIntervalSince(start)
        let speed = progress.secPerStep
        update(id) { it in
            it.outputs = files
            it.duration = dur
            if cancelled { it.status = .cancelled }
            else if code == 0 && !files.isEmpty { it.status = .done }
            else {
                it.status = .failed
                let errs = self.logTail.filter { $0.contains("ERROR") || $0.contains("error") || $0.contains("failed") }
                it.error = (errs.last ?? self.logTail.last ?? "sd-cli 退出码 \(code)")
                    .replacingOccurrences(of: "[ERROR ]", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        if !cancelled && code == 0 { recordSpeed(p, secPerStep: speed) }
        if selectedItemID == id { selectedOutput = files.first }
        runningID = nil
        previewImage = nil
        saveHistory()
        if !cancelled && code == 0 && !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        pump()
    }

    private static let stepRegex = /\|\s*(\d+)\/(\d+)\s*-\s*([\d.]+)\s*(s\/it|it\/s)/
    private static let imageRegex = /generating image:\s*(\d+)\/(\d+)/

    private func handle(_ line: String) {
        logTail.append(line)
        if logTail.count > 300 { logTail.removeFirst(logTail.count - 300) }

        if line.contains("=") || line.contains(">"), let m = line.firstMatch(of: Self.stepRegex) {
            progress.step = Int(m.1) ?? 0
            progress.total = Int(m.2) ?? 0
            let v = Double(m.3) ?? 0
            progress.secPerStep = m.4 == "s/it" ? v : (v > 0 ? 1 / v : 0)
            progress.stage = "绘制中"
            reloadPreview()
        } else if let m = line.firstMatch(of: Self.imageRegex) {
            progress.imageIndex = Int(m.1) ?? 1
            progress.imageCount = Int(m.2) ?? 1
            progress.stage = "绘制中"
        } else if line.contains("get_learned_condition") || line.contains("qwen3vl build") {
            if progress.total == 0 { progress.stage = "理解提示词" }
        } else if line.contains("decoding") {
            progress.stage = "解码图像"
        } else if line.contains("loading tensors") && progress.total == 0 {
            progress.stage = "加载模型"
        }
    }

    private func reloadPreview() {
        guard let path = previewPath,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let mod = attrs[.modificationDate] as? Date, mod != previewStamp,
              let data = try? Data(contentsOf: path), let img = NSImage(data: data) else { return }
        previewStamp = mod
        previewImage = img
    }

    // MARK: 杂项
    func revealInFinder(_ rel: String) { NSWorkspace.shared.activateFileViewerSelecting([url(rel)]) }

    func copyImage(_ rel: String) {
        guard let img = image(rel) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img, url(rel) as NSURL])
    }

    func saveAs(_ rel: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = rel
        if panel.runModal() == .OK, let dest = panel.url {
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: url(rel), to: dest)
        }
    }

    func pickReferences() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.message = "选择参考图（最多 10 张），进入改图模式"
        if panel.runModal() == .OK { panel.urls.forEach(addReference) }
    }

    func pickRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = root
        panel.message = "选择包含 bin/ models/ outputs/ 的工作目录"
        if panel.runModal() == .OK, let u = panel.url { root = u }
    }
}

extension DateFormatter {
    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
