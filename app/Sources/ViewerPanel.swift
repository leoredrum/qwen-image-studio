import SwiftUI

struct ViewerPanel: View {
    @Environment(Studio.self) private var studio
    @State private var actualSize = false
    @State private var showInfo = true

    var body: some View {
        let item = studio.selectedItem
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                canvas(item)
            }
            if let item, item.outputs.count > 1 { strip(item) }
            if let item { bottomBar(item) }
        }
    }

    // MARK: 画布
    @ViewBuilder private func canvas(_ item: ChatItem?) -> some View {
        if let item, [.running, .queued, .thinking].contains(item.status) {
            runningView(item)
        } else if let rel = studio.selectedOutput, let img = studio.image(rel) {
            imageView(img, rel: rel)
        } else if let item, item.status == .failed {
            ContentUnavailableView("生成失败", systemImage: "exclamationmark.triangle", description: Text(item.error ?? ""))
        } else {
            ContentUnavailableView("还没有图片", systemImage: "photo.on.rectangle.angled",
                                   description: Text("在左侧输入提示词，生成的图片会显示在这里"))
        }
    }

    private func imageView(_ img: NSImage, rel: String) -> some View {
        Group {
            if actualSize {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: img).interpolation(.high)
                }
            } else {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
                    .padding(28)
            }
        }
        .onTapGesture(count: 2) { actualSize.toggle() }
        .onDrag { NSItemProvider(contentsOf: studio.url(rel)) ?? NSItemProvider() }
        .contextMenu { imageMenu(rel) }
        .help("双击切换 适应窗口 / 原始尺寸，可直接拖出图片")
    }

    private func runningView(_ item: ChatItem) -> some View {
        let p = studio.progress
        let aspect = CGFloat(item.params.width) / CGFloat(item.params.height)
        return VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5))
                if item.status == .running, let img = studio.previewImage {
                    Image(nsImage: img).resizable().interpolation(.high)
                        .blur(radius: 6)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .animation(.easeInOut(duration: 0.4), value: img)
                }
                if studio.previewImage == nil || item.status != .running {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(item.status == .thinking ? "助手正在理解你的意思…" : item.status == .queued ? "排队中" : p.stage).foregroundStyle(.secondary)
                    }
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: 720, maxHeight: 620)

            if item.status == .running {
                VStack(spacing: 6) {
                    ProgressView(value: p.fraction).frame(maxWidth: 420)
                    HStack(spacing: 14) {
                        Text(p.stage)
                        if p.total > 0 { Text("\(p.step)/\(p.total) 步") }
                        if p.imageCount > 1 { Text("第 \(p.imageIndex)/\(p.imageCount) 张") }
                        if let eta = p.eta { Text("剩余约 \(formatDuration(eta))") }
                    }
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    Button("停止生成", role: .destructive) { studio.cancel() }
                        .keyboardShortcut(".", modifiers: .command)
                }
            }
        }
        .padding(28)
    }

    // MARK: 多图缩略条
    private func strip(_ item: ChatItem) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(item.outputs, id: \.self) { o in
                    Thumb(rel: o, size: 64)
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(studio.selectedOutput == o ? Color.accentColor : .clear, lineWidth: 3))
                        .onTapGesture { studio.selectedOutput = o }
                }
            }
            .padding(10)
        }
        .background(.bar)
    }

    // MARK: 底栏
    private func bottomBar(_ item: ChatItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if showInfo {
                Text(item.params.userText ?? item.params.prompt)
                    .font(.callout)
                    .lineLimit(3)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    Text(item.params.summary)
                    Text(item.params.sampler)
                    if item.params.nsfw { Text("NSFW") }
                    if let d = item.duration { Text("用时 \(formatDuration(d))") }
                    Text(item.date.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack(spacing: 4) {
                Button { showInfo.toggle() } label: { Image(systemName: "info.circle") }.help("显示/隐藏信息")
                if let rel = studio.selectedOutput, item.status == .done {
                    Button { actualSize.toggle() } label: {
                        Image(systemName: actualSize ? "arrow.down.right.and.arrow.up.left" : "1.magnifyingglass")
                    }.help(actualSize ? "适应窗口" : "原始尺寸")
                    Divider().frame(height: 16)
                    Button { studio.useAsReference(rel) } label: { Label("改这张图", systemImage: "wand.and.stars") }
                        .help("把这张图加为参考图，然后在左侧输入修改指令")
                    Button { studio.retry(item, newSeed: true) } label: { Label("再来一张", systemImage: "arrow.clockwise") }
                    Button { studio.reuse(item) } label: { Label("复用参数", systemImage: "arrow.uturn.left") }
                    Spacer()
                    Button { studio.copyImage(rel) } label: { Image(systemName: "doc.on.doc") }.help("复制图片")
                    Button { studio.saveAs(rel) } label: { Image(systemName: "square.and.arrow.down") }.help("另存为…")
                    Button { studio.revealInFinder(rel) } label: { Image(systemName: "folder") }.help("在 Finder 中显示")
                    ShareLink(item: studio.url(rel)) { Image(systemName: "square.and.arrow.up") }.help("分享")
                } else {
                    Spacer()
                }
            }
            .buttonStyle(.borderless)
            .labelStyle(.titleAndIcon)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder private func imageMenu(_ rel: String) -> some View {
        Button("改这张图") { studio.useAsReference(rel) }
        Button("复制图片") { studio.copyImage(rel) }
        Button("另存为…") { studio.saveAs(rel) }
        Button("在 Finder 中显示") { studio.revealInFinder(rel) }
    }
}

// MARK: - 日志

struct LogView: View {
    @Environment(Studio.self) private var studio
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("运行日志").font(.headline)
                Spacer()
                Button("复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(studio.logTail.joined(separator: "\n"), forType: .string)
                }
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                Text(studio.logTail.isEmpty ? "（暂无日志，日志只保留最近一次生成）" : studio.logTail.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .padding()
        .frame(width: 760, height: 480)
    }
}
