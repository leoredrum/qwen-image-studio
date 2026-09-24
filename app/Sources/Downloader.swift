import Foundation
import Observation

struct RemoteFile: Identifiable, Hashable {
    let repo: String
    let path: String      // 仓库内路径
    let size: Int64
    let localRel: String  // 相对 models/ 的路径
    var id: String { repo + "/" + path }
    var name: String { (path as NSString).lastPathComponent }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
}

enum Catalog {
    static let diffusionRepo = "unsloth/Qwen-Image-2.1-GGUF"
    static let encoderRepo = "unsloth/Qwen3-VL-8B-Instruct-GGUF"
    static let vaeRepo = "unsloth/Qwen-Image-2.1-FP8"

    static func note(for name: String) -> String? {
        switch true {
        case name.contains("Q8_0"): "接近原始画质 · 64GB 内存推荐"
        case name.contains("Q6_K"): "画质很好"
        case name.contains("Q5_K"): "画质与体积平衡"
        case name.contains("Q4_K_M"): "官方推荐 · 12GB 显存档"
        case name.contains("UD-Q4_K_XL"): "官方推荐编码器"
        case name.contains("Q3") || name.contains("Q2"): "体积最小 · 画质下降明显"
        case name.contains("F16") || name.contains("BF16"): "未量化 · 体积很大"
        default: nil
        }
    }

    /// 从 Hugging Face API 拉取文件列表
    static func list(repo: String, filter: (String) -> Bool, localPrefix: String = "") async throws -> [RemoteFile] {
        let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main?recursive=true")!
        let (data, _) = try await URLSession.shared.data(from: url)
        struct Entry: Decodable { let type: String; let path: String; let size: Int64? }
        return try JSONDecoder().decode([Entry].self, from: data)
            .filter { $0.type == "file" && filter($0.path) }
            .map { RemoteFile(repo: repo, path: $0.path, size: $0.size ?? 0, localRel: localPrefix + (($0.path as NSString).lastPathComponent)) }
    }
}

@MainActor
@Observable
final class Downloader: NSObject {
    struct Job { var file: RemoteFile; var dest: URL; var received: Int64 = 0; var task: URLSessionDownloadTask? }

    var jobs: [String: Job] = [:]  // key: RemoteFile.id
    var lastError: String?
    @ObservationIgnored var onFinish: (() -> Void)?
    @ObservationIgnored private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    func progress(_ f: RemoteFile) -> Double? {
        guard let j = jobs[f.id] else { return nil }
        return f.size > 0 ? Double(j.received) / Double(f.size) : 0
    }

    func start(_ f: RemoteFile, modelsDir: URL) {
        guard jobs[f.id] == nil else { return }
        let src = URL(string: "https://huggingface.co/\(f.repo)/resolve/main/\(f.path)")!
        let task = session.downloadTask(with: src)
        task.taskDescription = f.id
        jobs[f.id] = Job(file: f, dest: modelsDir.appending(path: f.localRel), task: task)
        task.resume()
    }

    func cancel(_ f: RemoteFile) {
        jobs[f.id]?.task?.cancel()
        jobs[f.id] = nil
    }
}

extension Downloader: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskDescription ?? ""
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.jobs[id]?.received = totalBytesWritten }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let id = downloadTask.taskDescription ?? ""
        // 临时文件在回调返回后就会被删除，必须同步移走
        let staging = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try? FileManager.default.moveItem(at: location, to: staging)
        let ok = (downloadTask.response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let job = self.jobs[id] else { return }
                if ok {
                    try? FileManager.default.createDirectory(at: job.dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: job.dest)
                    do { try FileManager.default.moveItem(at: staging, to: job.dest) } catch { self.lastError = error.localizedDescription }
                } else {
                    self.lastError = "\(job.file.name) 下载失败"
                }
                self.jobs[id] = nil
                self.onFinish?()
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        let id = task.taskDescription ?? ""
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.lastError = "下载失败：\(error.localizedDescription)"
                self.jobs[id] = nil
            }
        }
    }
}
