import Foundation

/// 运行 sd-cli 子进程，逐行回传输出（进度条用 \r 刷新，所以 \r 和 \n 都当作分行）
final class Engine: @unchecked Sendable {
    private var process: Process?
    private(set) var cancelled = false

    func run(executable: URL, args: [String], cwd: URL, onLine: @escaping @MainActor (String) -> Void) async -> Int32 {
        cancelled = false
        let p = Process()
        p.executableURL = executable
        p.arguments = args
        p.currentDirectoryURL = cwd
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { return }
            for line in buffer.feed(data) {
                DispatchQueue.main.async { MainActor.assumeIsolated { onLine(line) } }
            }
        }

        return await withCheckedContinuation { cont in
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                var lines = buffer.feed(rest)
                if let tail = buffer.flush() { lines.append(tail) }
                let status = proc.terminationStatus
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { lines.forEach(onLine) }
                    cont.resume(returning: status)
                }
            }
            do {
                try p.run()
                self.process = p
            } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { onLine("[ERROR] 无法启动 sd-cli: \(error.localizedDescription)") }
                    cont.resume(returning: -1)
                }
            }
        }
    }

    func cancel() {
        cancelled = true
        process?.terminate()
    }
}

private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()

    func feed(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        var out: [String] = []
        while let i = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            let chunk = pending[pending.startIndex..<i]
            pending = Data(pending[(i + 1)...])
            if let s = String(data: chunk, encoding: .utf8)?.replacingOccurrences(of: "\u{1B}[K", with: ""),
               !s.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(s)
            }
        }
        return out
    }

    func flush() -> String? {
        lock.lock(); defer { lock.unlock() }
        defer { pending = Data() }
        let s = String(data: pending, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty ?? true) ? nil : s
    }
}
