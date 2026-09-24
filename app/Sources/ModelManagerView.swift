import SwiftUI

struct ModelManagerView: View {
    @Environment(Studio.self) private var studio
    @Environment(\.dismiss) private var dismiss
    @State private var diffusion: [RemoteFile] = []
    @State private var encoders: [RemoteFile] = []
    @State private var extras: [RemoteFile] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var pendingDelete: RemoteFile?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("模型管理").font(.title3.weight(.semibold))
                    Text("文件来自 Hugging Face · Unsloth 官方量化").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            Form {
                Section("工作目录") {
                    LabeledContent("位置") {
                        HStack {
                            Text(studio.root.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Button("更改…") { studio.pickRoot() }
                            Button("打开") { NSWorkspace.shared.open(studio.root) }
                        }
                    }
                }

                if loading {
                    HStack { ProgressView().controlSize(.small); Text("正在获取模型列表…") }
                } else if let e = loadError {
                    Label("无法获取在线列表：\(e)", systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
                }

                Section {
                    ForEach(diffusion) { f in row(f, active: studio.settings.diffusionModel == f.localRel) { studio.settings.diffusionModel = f.localRel } }
                } header: {
                    Text("去噪模型（Qwen-Image-2.1，决定画质和速度）")
                }

                Section {
                    ForEach(encoders) { f in row(f, active: studio.settings.textEncoder == f.localRel) { studio.settings.textEncoder = f.localRel } }
                } header: {
                    Text("文本编码器（Qwen3-VL-8B，负责理解提示词）")
                }

                Section {
                    ForEach(extras) { f in row(f, active: false, use: nil) }
                } header: {
                    Text("必需组件")
                } footer: {
                    Text("VAE 必须要有；mmproj 是视觉模块，改图时用来理解参考图。").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            if let e = studio.downloader.lastError {
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption).padding(.bottom, 8)
            }
        }
        .frame(width: 640, height: 720)
        .task { await load() }
        .confirmationDialog("把 \(pendingDelete?.name ?? "") 移到废纸篓？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("移到废纸篓", role: .destructive) {
                if let f = pendingDelete {
                    try? FileManager.default.trashItem(at: studio.modelsDir.appending(path: f.localRel), resultingItemURL: nil)
                    studio.refreshModels()
                }
                pendingDelete = nil
            }
        }
    }

    private func installed(_ f: RemoteFile) -> Bool {
        FileManager.default.fileExists(atPath: studio.modelsDir.appending(path: f.localRel).path)
    }

    @ViewBuilder
    private func row(_ f: RemoteFile, active: Bool, use: (() -> Void)?) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(f.name.replacingOccurrences(of: ".gguf", with: "")).font(.body.monospaced())
                    if active { Text("使用中").font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.accentColor.opacity(0.2))) }
                }
                HStack(spacing: 6) {
                    Text(f.sizeText)
                    if let n = Catalog.note(for: f.name) { Text("· \(n)") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let p = studio.downloader.progress(f) {
                ProgressView(value: p).frame(width: 110)
                Text("\(Int(p * 100))%").font(.caption).monospacedDigit().frame(width: 36)
                Button { studio.downloader.cancel(f) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
            } else if installed(f) {
                if let use, !active { Button("使用", action: use) }
                if !active { Button { pendingDelete = f } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("移到废纸篓") }
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button { studio.downloader.start(f, modelsDir: studio.modelsDir) } label: { Label("下载", systemImage: "arrow.down.circle") }
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            async let d = Catalog.list(repo: Catalog.diffusionRepo) { $0.hasSuffix(".gguf") }
            async let e = Catalog.list(repo: Catalog.encoderRepo) { $0.hasSuffix(".gguf") && !$0.contains("mmproj") && !$0.contains("/") }
            async let v = Catalog.list(repo: Catalog.vaeRepo, filter: { $0.hasPrefix("vae/") && $0.hasSuffix(".safetensors") }, localPrefix: "vae/")
            async let m = Catalog.list(repo: Catalog.encoderRepo) { $0 == "mmproj-BF16.gguf" }
            let sizeSort: (RemoteFile, RemoteFile) -> Bool = { $0.size < $1.size }
            diffusion = try await d.sorted(by: sizeSort)
            encoders = try await e.sorted(by: sizeSort)
            extras = try await v + m
        } catch {
            loadError = error.localizedDescription
        }
    }
}
