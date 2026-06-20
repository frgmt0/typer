import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

final class LlamaClient {
    private let cfg: TyperConfig
    // When set, this client always serves this exact .gguf (the ModelRouter spawns one
    // client per model). When nil, it falls back to findModel(cfg) — the original
    // single-model behaviour.
    private let explicitModelPath: String?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var readBuffer = Data()   // leftover bytes past the last newline (chunked reads)
    private let lock = NSLock()
    // Requests are serialized by `lock`, so sharing one encoder/decoder is safe and
    // avoids re-allocating both on every request (and per streamed line's decode).
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(cfg: TyperConfig, modelPath: String? = nil) {
        self.cfg = cfg
        self.explicitModelPath = modelPath
    }

    // Locate the GGUF model: an explicit config path if set, otherwise the first
    // .gguf found in the Models directory (so the exact filename doesn't matter).
    static func findModel(_ cfg: TyperConfig) -> String? {
        let fm = FileManager.default
        if !cfg.modelPath.isEmpty, fm.fileExists(atPath: cfg.modelPath) { return cfg.modelPath }
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/typer/Models")
        let ggufs = (try? fm.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".gguf") }.sorted()
        return ggufs?.first.map { dir.appendingPathComponent($0).path }
    }

    func start() throws {
        if process?.isRunning == true { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let llamaHelper = home + "/.local/share/typer/typer-llama-server"
        guard FileManager.default.isExecutableFile(atPath: llamaHelper) else {
            throw NSError(domain: "Typer", code: 3, userInfo: [NSLocalizedDescriptionKey: "helper not found at \(llamaHelper); run install.sh"])
        }
        guard let model = explicitModelPath ?? LlamaClient.findModel(cfg) else {
            throw NSError(domain: "Typer", code: 4, userInfo: [NSLocalizedDescriptionKey: "no .gguf model found in Models directory; run install.sh"])
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: llamaHelper)
        p.arguments = ["--model-path", model]
        log("starting GGUF helper: \(llamaHelper) model=\((model as NSString).lastPathComponent)")
        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.standardError
        try p.run()
        log("helper pid=\(p.processIdentifier)")
        process = p
        input = inPipe.fileHandleForWriting
        output = outPipe.fileHandleForReading
        readBuffer.removeAll(keepingCapacity: true)
    }

    // Reads one '\n'-terminated line from the helper, reading in CHUNKS (not a syscall
    // per byte) and buffering any bytes past the newline for the next call. macOS
    // energy impact is dominated by CPU wakeups, so the old byte-at-a-time poll/read
    // (≈2 syscalls per character of a streamed response) was a real, avoidable drain.
    private func readResponseLine(timeoutMs: Int32 = 8000) throws -> Data? {
        guard let fd = output?.fileDescriptor else { return nil }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while true {
            if let nl = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer.subdata(in: readBuffer.startIndex..<nl)
                readBuffer.removeSubrange(readBuffer.startIndex...nl)
                return line
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            let r = poll(&pfd, 1, remaining)
            if r == 0 { throw NSError(domain: "Typer", code: 5, userInfo: [NSLocalizedDescriptionKey: "helper read timeout"]) }
            if r < 0 { if errno == EINTR { continue }; throw NSError(domain: "Typer", code: 6, userInfo: [NSLocalizedDescriptionKey: "poll failed"]) }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)
            if n < 0 { if errno == EINTR { continue }; throw NSError(domain: "Typer", code: 7, userInfo: [NSLocalizedDescriptionKey: "read failed"]) }
            if n == 0 { return readBuffer.isEmpty ? nil : { let d = readBuffer; readBuffer.removeAll(); return d }() }
            readBuffer.append(contentsOf: chunk[0..<n])
        }
    }

    // Sends one request and reads the streaming response. `onPartial` is invoked
    // (on this background thread) for each partial completion; the final suggestion
    // is returned.
    // `lowPriority` (speculative prefetch) yields the helper instead of waiting: if a
    // foreground request already holds the lock, the prefetch is skipped rather than
    // queued, so it can never delay real input.
    func request(task: String, context: String, maxWords: Int, lexicon: String = "",
                 lowPriority: Bool = false,
                 onPartial: ((String, Double?) -> Void)? = nil) throws -> HelperSuggestion? {
        if lowPriority {
            guard lock.try() else { return nil }
        } else {
            lock.lock()
        }
        defer { lock.unlock() }
        try start()
        let req = HelperRequest(task: task, context: context, max_words: maxWords, lexicon: lexicon)
        dlog("request task=\(task) chars=\(context.count) suffix=\(String(context.suffix(40)).replacingOccurrences(of: "\n", with: "\\n"))")
        let data = try encoder.encode(req) + Data([0x0A])
        do {
            try input?.write(contentsOf: data)
            while true {
                guard let line = try readResponseLine(), !line.isEmpty else {
                    throw NSError(domain: "Typer", code: 1, userInfo: [NSLocalizedDescriptionKey: "helper exited"])
                }
                let res = try decoder.decode(StreamLine.self, from: line)
                if let p = res.p { onPartial?(p, res.conf); continue }      // partial token update
                if res.ok == false {
                    throw NSError(domain: "Typer", code: 2, userInfo: [NSLocalizedDescriptionKey: res.error ?? "Unknown error"])
                }
                dlog("response kind=\(res.suggestion?.kind ?? "nil") text=\((res.suggestion?.text ?? res.suggestion?.replacement ?? "nil").prefix(80))")
                return res.suggestion                              // final line
            }
        } catch {
            // On exit/timeout/parse error, kill the (possibly hung) helper so the next
            // request spawns a fresh one instead of blocking on a dead pipe.
            process?.terminate()
            process = nil; input = nil; output = nil
            throw error
        }
    }

    // Lock-safe warm-up so the launch-time start() can't double-spawn against the
    // first real request().
    func warmUp() { lock.lock(); defer { lock.unlock() }; try? start() }

    // Kill the helper process (used when switching models — the next client spawns fresh).
    func stop() {
        lock.lock(); defer { lock.unlock() }
        process?.terminate()
        process = nil; input = nil; output = nil
    }
}
