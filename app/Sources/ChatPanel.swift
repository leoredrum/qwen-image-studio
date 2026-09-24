import SwiftUI
import UniformTypeIdentifiers

struct ChatPanel: View {
    @Environment(Studio.self) private var studio

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if studio.items.isEmpty {
                WelcomeView()
            } else {
                messages
            }
            Composer()
                .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text("Qwen Image Studio").font(.headline)
                Text("Qwen-Image-2.1 · 本地 · Metal").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button { studio.showModelManager = true } label: {
                Label("模型", systemImage: "cube.box")
            }
            .help("模型管理 ⇧⌘M")
            Menu {
                Button("打开输出文件夹") { NSWorkspace.shared.open(studio.outputsDir) }
                Button("查看运行日志") { studio.showLog = true }
                Divider()
                Button("清空对话记录", role: .destructive) { studio.clearHistory() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(studio.items) { item in
                        ChatRow(item: item).id(item.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
            }
            .onAppear { proxy.scrollTo(studio.items.last?.id, anchor: .bottom) }
            .onChange(of: studio.items.count) {
                withAnimation { proxy.scrollTo(studio.items.last?.id, anchor: .bottom) }
            }
        }
    }
}

// MARK: - 欢迎页

struct WelcomeView: View {
    @Environment(Studio.self) private var studio
    private let examples = [
        "一只戴着红色围巾的橘猫坐在西湖边的长椅上，夕阳，电影感摄影",
        "赛博朋克风格的上海外滩夜景，霓虹招牌写着“未来已来”，雨夜反光",
        "极简主义海报：一颗悬浮的透明玻璃苹果，柔和渐变背景，产品摄影",
        "宫崎骏风格的乡间小火车穿过向日葵花田，蓝天白云，水彩质感",
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 88, height: 88)
                    .padding(.top, 30)
                Text("想画点什么？").font(.title2.weight(.semibold))
                Text("在下面输入提示词开始生成，中英文都可以。\n添加参考图后会自动切换到改图模式。")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if studio.setupProblem != nil {
                    SetupCard().padding(.horizontal, 24)
                }
                VStack(spacing: 8) {
                    ForEach(examples, id: \.self) { e in
                        Button { studio.draft = e } label: {
                            HStack {
                                Image(systemName: "sparkles").foregroundStyle(.tint)
                                Text(e).multilineTextAlignment(.leading).foregroundStyle(.primary)
                                Spacer(minLength: 0)
                            }
                            .font(.callout)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.6)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - 首次安装

struct SetupCard: View {
    @Environment(Studio.self) private var studio

    var body: some View {
        let files = studio.recommendedFiles
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        let downloading = files.contains { studio.downloader.progress($0) != nil }
        VStack(alignment: .leading, spacing: 10) {
            Label("首次使用：下载模型", systemImage: "arrow.down.circle.fill").font(.headline)
            Text("检测到这台 Mac 有 \(studio.memoryGB)GB 内存，推荐下面这套组合。文件来自 Hugging Face（Unsloth 官方量化），下载后保存在「\(studio.root.lastPathComponent)」文件夹。")
                .font(.caption).foregroundStyle(.secondary)
            if studio.memoryGB < 16 {
                Label("内存低于 16GB，生成会很慢，也可能因内存不足失败。", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if files.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("正在获取模型列表…").font(.caption) }
            }
            ForEach(files) { f in
                HStack {
                    Image(systemName: studio.isInstalled(f) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(studio.isInstalled(f) ? .green : .secondary)
                    Text(f.name).font(.caption.monospaced())
                    Spacer()
                    if let p = studio.downloader.progress(f) {
                        ProgressView(value: p).frame(width: 90)
                        Text("\(Int(p * 100))%").font(.caption).monospacedDigit().frame(width: 34)
                    } else {
                        Text(f.sizeText).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button {
                    studio.installRecommended()
                } label: {
                    Label(downloading ? "下载中…" : "一键下载（共 \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))）",
                          systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.borderedProminent)
                .disabled(files.isEmpty || downloading)
                Button("自己选模型…") { studio.showModelManager = true }
            }
            if let e = studio.downloader.lastError {
                Text(e).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.6)))
        .task { await studio.loadInstallPlan() }
    }
}

// MARK: - 对话条目

struct ChatRow: View {
    @Environment(Studio.self) private var studio
    let item: ChatItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 用户提示词气泡
            HStack {
                Spacer(minLength: 50)
                VStack(alignment: .trailing, spacing: 6) {
                    if item.isEdit {
                        HStack(spacing: 4) {
                            ForEach(item.params.refImages, id: \.self) { r in
                                Thumb(rel: r, size: 44)
                            }
                        }
                    }
                    Text(item.params.userText ?? item.params.prompt)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.16)))
                    HStack(spacing: 4) {
                        if item.isEdit { Label("改图", systemImage: "wand.and.stars").labelStyle(.titleAndIcon) }
                        if item.params.nsfw { Text("NSFW") }
                        if item.params.transparent == true { Text("透明") }
                        if item.params.fastMode { Image(systemName: "bolt.fill") }
                        Text(item.params.summary)
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .contextMenu { rowMenu }

            if item.params.userText != nil { assistantNote }

            // 结果
            result
        }
    }

    @ViewBuilder private var result: some View {
        switch item.status {
        case .thinking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("助手正在理解你的意思…").font(.callout).foregroundStyle(.secondary)
            }
        case .queued:
            statusLine("排队中…", "clock")
        case .running:
            RunningCard()
                .onTapGesture { studio.select(item) }
        case .done:
            VStack(alignment: .leading, spacing: 6) {
                let cols = item.outputs.count == 1 ? 1 : 2
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: cols), alignment: .leading, spacing: 6) {
                    ForEach(item.outputs, id: \.self) { o in
                        let sel = studio.selectedItemID == item.id && studio.selectedOutput == o
                        Thumb(rel: o, size: cols == 1 ? 260 : 150)
                            .background { if item.params.transparent == true { Checkerboard(cell: 8).clipShape(RoundedRectangle(cornerRadius: 10)) } }
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(sel ? Color.accentColor : .clear, lineWidth: 3))
                            .onTapGesture { studio.select(item, output: o) }
                            .onDrag { NSItemProvider(contentsOf: studio.url(o)) ?? NSItemProvider() }
                    }
                }
                .frame(maxWidth: cols == 1 ? 260 : 312, alignment: .leading)
                HStack(spacing: 12) {
                    if let d = item.duration { Text("用时 \(formatDuration(d))") }
                    Button("换个 seed 再来") { studio.retry(item, newSeed: true) }
                    Button("复用参数") { studio.reuse(item) }
                }
                .font(.caption).foregroundStyle(.secondary).buttonStyle(.link)
            }
        case .failed:
            VStack(alignment: .leading, spacing: 4) {
                statusLine("生成失败", "exclamationmark.triangle.fill", .red)
                if let e = item.error { Text(e).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(4) }
                HStack {
                    Button("重试") { studio.retry(item) }
                    Button("查看日志") { studio.showLog = true }
                }.buttonStyle(.link).font(.caption)
            }
        case .cancelled:
            HStack {
                statusLine("已取消", "stop.circle")
                Button("重新生成") { studio.retry(item) }.buttonStyle(.link).font(.caption)
            }
        }
    }

    /// 助手的判断和改写后的提示词
    @ViewBuilder private var assistantNote: some View {
        let p = item.params
        if item.status != .thinking {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    switch p.assistantMode {
                    case "generate": Text(p.refImages.isEmpty ? "助手：文生图" : "助手：参考图 + 重新构图").fontWeight(.semibold)
                    case "edit": Text("助手：接着改").fontWeight(.semibold)
                    default: Text("助手未参与").fontWeight(.semibold)
                    }
                }
                .foregroundStyle(p.assistantMode == nil ? Color.orange : Color.purple)
                if p.assistantMode != nil {
                    Text(p.prompt).textSelection(.enabled).foregroundStyle(.primary)
                }
                if let n = p.assistantNote { Text(n).foregroundStyle(.secondary) }
            }
            .font(.caption)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.08)))
        }
    }

    private func statusLine(_ t: String, _ icon: String, _ color: Color = .secondary) -> some View {
        Label(t, systemImage: icon).font(.callout).foregroundStyle(color)
    }

    @ViewBuilder private var rowMenu: some View {
        Button("复用提示词和参数") { studio.reuse(item) }
        Button("复制提示词") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.params.prompt, forType: .string)
        }
        Button("用相同参数重新生成") { studio.retry(item) }
        Divider()
        Button("删除这条", role: .destructive) { studio.delete(item) }
    }
}

struct RunningCard: View {
    @Environment(Studio.self) private var studio

    var body: some View {
        let p = studio.progress
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                if let img = studio.previewImage {
                    Image(nsImage: img).resizable().interpolation(.high).scaledToFill()
                        .blur(radius: 2)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 84, height: 84)
            .clipped()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(p.stage).font(.callout.weight(.medium))
                    if p.imageCount > 1 { Text("第 \(p.imageIndex)/\(p.imageCount) 张").font(.caption).foregroundStyle(.secondary) }
                }
                ProgressView(value: p.fraction)
                HStack {
                    if p.total > 0 { Text("\(p.step)/\(p.total) 步") }
                    if p.secPerStep > 0 { Text(String(format: "%.1f 秒/步", p.secPerStep)) }
                    Spacer()
                    if let eta = p.eta { Text("剩余约 \(formatDuration(eta))") }
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button("停止", role: .destructive) { studio.cancel() }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: 340)
        .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.5)))
    }
}

struct Thumb: View {
    @Environment(Studio.self) private var studio
    let rel: String
    var size: CGFloat

    var body: some View {
        Group {
            if let img = studio.thumbnail(rel, size: size * 2) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 60 ? 10 : 6))
        .contentShape(Rectangle())
    }
}
