import SwiftUI
import UniformTypeIdentifiers

struct Composer: View {
    @Environment(Studio.self) private var studio
    @State private var showMore = false
    @State private var dropping = false

    var body: some View {
        @Bindable var studio = studio
        VStack(alignment: .leading, spacing: 8) {
            chainBar
            if !studio.refImages.isEmpty { refStrip }

            ZStack(alignment: .topLeading) {
                PromptEditor(text: $studio.draft) { studio.send() }
                    .frame(height: 84)
                if studio.draft.isEmpty {
                    Text(studio.isChaining ? "哪里不满意？比如「背景换成雪山」「让它笑一下」「换成水彩风格」…"
                         : studio.refImages.isEmpty ? "描述你想生成的画面…（↩ 发送，⇧↩ 换行）" : "描述你想怎么改这张图，比如「把背景换成雪山」…")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                }
            }

            chips
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(dropping ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: dropping ? 2 : 1)
        )
        .onDrop(of: [.fileURL, .image], isTargeted: $dropping) { providers in
            for p in providers {
                if p.canLoadObject(ofClass: URL.self) {
                    _ = p.loadObject(ofClass: URL.self) { u, _ in
                        if let u { DispatchQueue.main.async { studio.addReference(u) } }
                    }
                } else if p.canLoadObject(ofClass: NSImage.self) {
                    _ = p.loadObject(ofClass: NSImage.self) { img, _ in
                        if let img = img as? NSImage { DispatchQueue.main.async { studio.addReference(img) } }
                    }
                }
            }
            return true
        }
    }

    /// 「接着改」：以右侧当前图片为底图继续修改
    @ViewBuilder private var chainBar: some View {
        if let src = studio.chainSource, !studio.refImages.contains(src) {
            if studio.settings.chainEdits {
                HStack(spacing: 8) {
                    Thumb(rel: src, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("接着改这张").font(.callout.weight(.semibold))
                        Text("在右侧或历史里点别的图可切换底图").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { studio.settings.chainEdits = false } label: {
                        Label("画新图", systemImage: "xmark")
                    }
                    .buttonStyle(.borderless).font(.caption)
                    .help("不基于当前图，重新生成一张全新的")
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.12)))
            } else {
                Button { studio.settings.chainEdits = true } label: {
                    Label("基于右侧这张图接着改", systemImage: "arrow.triangle.branch")
                }
                .buttonStyle(.borderless).font(.caption)
            }
        }
    }

    private var refStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(studio.refImages, id: \.self) { r in
                        Thumb(rel: r, size: 58)
                            .overlay(alignment: .topTrailing) {
                                Button { studio.refImages.removeAll { $0 == r } } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .buttonStyle(.plain).padding(2)
                            }
                    }
                }
            }
            Label(studio.visionPath == nil ? "改图模式 · 未安装视觉模块 mmproj，模型看不懂参考图" : "改图模式 · \(studio.refImages.count) 张参考图",
                  systemImage: "wand.and.stars")
                .font(.caption)
                .foregroundStyle(studio.visionPath == nil ? .orange : .accentColor)
        }
    }

    private var chips: some View {
        @Bindable var studio = studio
        let (w, h) = studio.targetSize
        return HStack(spacing: 6) {
            Button { studio.pickReferences() } label: {
                Image(systemName: "photo.badge.plus")
            }
            .buttonStyle(ChipStyle())
            .help("添加参考图（改图模式），也可以直接把图片拖进来")

            // 模型
            Menu {
                Picker("去噪模型", selection: $studio.settings.diffusionModel) {
                    ForEach(studio.diffusionModels, id: \.self) { m in
                        Text(m.replacingOccurrences(of: "qwen-image-2.1-", with: "").replacingOccurrences(of: ".gguf", with: "")).tag(m)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Button("管理 / 下载更多模型…") { studio.showModelManager = true }
            } label: {
                Label(studio.settings.diffusionModel.replacingOccurrences(of: "qwen-image-2.1-", with: "").replacingOccurrences(of: ".gguf", with: ""),
                      systemImage: "cpu")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .modifier(ChipLook())
            .help("切换模型量化版本")

            // 比例 + 分辨率
            Menu {
                Picker("分辨率", selection: $studio.settings.tier) {
                    ForEach(SizeTier.allCases) { t in Text(verbatim: "\(t.rawValue) — \(t.detail)").tag(t) }
                }
                .pickerStyle(.inline)
                Divider()
                Picker("比例", selection: $studio.settings.aspect) {
                    ForEach(Aspect.allCases) { a in
                        let (pw, ph) = presetSize(a, studio.settings.tier)
                        Label(String("\(a.rawValue)   \(pw)×\(ph)"), systemImage: a.symbol).tag(a)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("有参考图时跟随原图比例", isOn: $studio.settings.followRefSize)
                Toggle("自定义宽高（在 ⚙︎ 里设置）", isOn: $studio.settings.customSize)
            } label: {
                Label(String("\(w)×\(h)"), systemImage: studio.settings.aspect.symbol)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .modifier(ChipLook())
            .help("分辨率与比例")

            // 画质
            Menu {
                Picker("画质", selection: $studio.settings.steps) {
                    ForEach(QualityPreset.all) { q in Text("\(q.name) — \(q.detail)").tag(q.steps) }
                    if !QualityPreset.all.contains(where: { $0.steps == studio.settings.steps }) {
                        Text("自定义 — \(studio.settings.steps) 步").tag(studio.settings.steps)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("⚡ 加速（EasyCache 跳步）", isOn: $studio.settings.fastMode)
            } label: {
                Label(QualityPreset.label(for: studio.settings.steps), systemImage: studio.settings.fastMode ? "bolt.fill" : "sparkles")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .modifier(ChipLook())
            .help("画质（采样步数）")

            // NSFW
            Toggle(isOn: $studio.settings.nsfw) {
                Text("NSFW")
            }
            .toggleStyle(ChipToggleStyle(onColor: .green, offColor: .red))
            .help(studio.settings.nsfw ? "NSFW 已开启：不添加任何内容限制" : "NSFW 已关闭：自动加入安全负面提示词")

            Toggle(isOn: Binding(get: { studio.settings.assistant && studio.assistantAvailable },
                                 set: { studio.settings.assistant = $0 })) {
                Label("助手", systemImage: "sparkles")
            }
            .toggleStyle(ChipToggleStyle(onColor: .purple, offColor: .secondary))
            .disabled(!studio.assistantAvailable)
            .help(!studio.assistantAvailable ? "提示词助手需要本地安装 Ollama（ollama.com），详见 ⚙︎ 更多参数"
                  : studio.settings.assistant ? "提示词助手已开启：先由本地大模型理解你的话、判断重画还是局部修改，再改写成图像模型易懂的描述" : "提示词助手已关闭：原话直接发给图像模型")

            Button { showMore.toggle() } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(ChipStyle())
            .help("更多参数")
            .popover(isPresented: $showMore, arrowEdge: .top) {
                MoreSettings().environment(studio)
            }

            Spacer(minLength: 4)

            if studio.runningID == nil {
                Text("≈ \(formatDuration(studio.estimate))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .help("按实测速度估算的耗时")
            } else if studio.items.contains(where: { $0.status == .queued }) {
                Text("排队 \(studio.items.filter { $0.status == .queued }.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if studio.runningID != nil && studio.draft.isEmpty {
                Button { studio.cancel() } label: {
                    Image(systemName: "stop.fill").frame(width: 30, height: 30)
                        .background(Circle().fill(.red.opacity(0.85))).foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("停止 ⌘.")
            } else {
                Button { studio.send() } label: {
                    Image(systemName: "arrow.up").font(.body.weight(.bold)).frame(width: 30, height: 30)
                        .background(Circle().fill(studio.canSend ? Color.accentColor : Color.secondary.opacity(0.3)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(!studio.canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help(studio.runningID == nil ? "生成 ↩" : "加入队列 ↩")
            }
        }
        .font(.callout)
    }
}

// MARK: - 更多参数

struct MoreSettings: View {
    @Environment(Studio.self) private var studio

    var body: some View {
        @Bindable var studio = studio
        Form {
            Section("尺寸") {
                Toggle("自定义宽高", isOn: $studio.settings.customSize)
                if studio.settings.customSize {
                    HStack {
                        TextField("宽", value: $studio.settings.width, format: .number).frame(width: 80)
                        Text("×")
                        TextField("高", value: $studio.settings.height, format: .number).frame(width: 80)
                        Text("需为 32 的倍数").font(.caption).foregroundStyle(.secondary)
                    }
                    .onSubmit {
                        studio.settings.width = max(256, min(4096, studio.settings.width / 32 * 32))
                        studio.settings.height = max(256, min(4096, studio.settings.height / 32 * 32))
                    }
                }
                Toggle("有参考图时跟随原图比例", isOn: $studio.settings.followRefSize)
            }

            Section("采样") {
                LabeledContent("步数 \(studio.settings.steps)") {
                    Slider(value: Binding(get: { Double(studio.settings.steps) }, set: { studio.settings.steps = Int($0) }), in: 4...60, step: 1)
                }
                LabeledContent("CFG \(studio.settings.cfg, format: .number.precision(.fractionLength(1)))") {
                    Slider(value: $studio.settings.cfg, in: 1...10, step: 0.5)
                }
                Text("sd.cpp 推荐 6.0。设为 1.0 会关闭 CFG，速度约快一倍，但负面提示词会失效。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("采样器", selection: $studio.settings.sampler) {
                    ForEach(samplers, id: \.self) { Text($0).tag($0) }
                }
                Picker("调度器", selection: $studio.settings.scheduler) {
                    ForEach(schedulers, id: \.self) { Text($0.isEmpty ? "自动（推荐）" : $0).tag($0) }
                }
                Toggle("⚡ 加速（EasyCache，复用相邻步计算）", isOn: $studio.settings.fastMode)
            }

            Section("随机种子与数量") {
                Toggle("随机 seed", isOn: $studio.settings.randomSeed)
                if !studio.settings.randomSeed {
                    TextField("seed", value: $studio.settings.seed, format: .number.grouping(.never))
                }
                Stepper("一次生成 \(studio.settings.batch) 张", value: $studio.settings.batch, in: 1...8)
            }

            Section("负面提示词") {
                TextEditor(text: $studio.settings.negative)
                    .font(.callout)
                    .frame(height: 56)
                Toggle("NSFW 内容", isOn: $studio.settings.nsfw)
                Text(studio.settings.nsfw
                     ? "已开启：不添加任何内容限制。"
                     : "已关闭：自动在负面提示词里加入裸露、色情、血腥等屏蔽词（提示词层面的引导，不是硬过滤）。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("提示词助手（本地 Ollama）") {
                if studio.assistantAvailable {
                    Toggle("开启提示词助手", isOn: $studio.settings.assistant)
                    Picker("语言模型", selection: $studio.settings.assistantModel) {
                        ForEach(Array(Set((studio.ollamaModels ?? []) + [studio.settings.assistantModel])).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    Text("未检测到 Ollama。安装 ollama.com 后，在终端运行 `ollama pull qwen3.5:9b`，再点重新检测。")
                        .font(.caption)
                    Button("重新检测") { Task { await studio.checkOllama() } }
                }
                Text("理解对话上下文：大改（视角、构图、位置）自动重画，小改（颜色、配饰、表情）以上一张为底图局部修改；并把否定句、纠错句改写成图像模型能理解的正面描述。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("模型与性能") {
                Picker("文本编码器", selection: $studio.settings.textEncoder) {
                    ForEach(studio.textEncoders, id: \.self) { Text($0.replacingOccurrences(of: ".gguf", with: "")).tag($0) }
                }
                Toggle("生成时实时预览", isOn: $studio.settings.livePreview)
                Toggle("VAE 分块解码（省内存，超大图自动开启）", isOn: $studio.settings.vaeTiling)
            }

            Button("恢复默认参数") {
                let keep = (studio.settings.diffusionModel, studio.settings.textEncoder)
                studio.settings = Settings()
                (studio.settings.diffusionModel, studio.settings.textEncoder) = keep
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 620)
        .task { await studio.checkOllama() }
    }
}

// MARK: - 胶囊按钮样式

struct ChipLook: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(.quaternary.opacity(0.7)))
    }
}

struct ChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(.quaternary.opacity(configuration.isPressed ? 1 : 0.7)))
            .contentShape(Capsule())
    }
}

struct ChipToggleStyle: ToggleStyle {
    var onColor: Color
    var offColor: Color
    func makeBody(configuration: Configuration) -> some View {
        let color = configuration.isOn ? onColor : offColor
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 7, height: 7)
                configuration.label
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.15)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
