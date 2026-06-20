import Combine
import Foundation

// Background, observable download of the optional large model (typer-1l.gguf) straight from
// HuggingFace into the Models directory. The menu + onboarding observe `state` to show progress.
// One download at a time. The finished file is validated as a real GGUF (size + magic) before it
// is moved into place, so a 404 HTML body or a truncated transfer never masquerades as a model.
final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    enum State: Equatable {
        case idle
        case downloading(Double)        // fraction 0...1 (or <0 when total size is unknown)
        case done
        case failed(String)
    }

    static let shared = ModelDownloader()

    @Published private(set) var state: State = .idle

    private var destination: URL?
    private var onDone: ((Bool) -> Void)?
    private lazy var session: URLSession = URLSession(
        configuration: .default, delegate: self, delegateQueue: nil)

    var isDownloading: Bool { if case .downloading = state { return true }; return false }

    // Start downloading `urlString` to `dest`. No-op (completion false) if one is already running.
    func download(urlString: String, to dest: URL, completion: @escaping (Bool) -> Void) {
        guard !isDownloading, let url = URL(string: urlString) else { completion(false); return }
        destination = dest
        onDone = completion
        DispatchQueue.main.async { self.state = .downloading(0) }
        session.downloadTask(with: url).resume()
    }

    private func finish(_ ok: Bool, _ newState: State) {
        let cb = onDone
        onDone = nil
        DispatchQueue.main.async { self.state = newState; cb?(ok) }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData _: Int64, totalBytesWritten written: Int64,
                    totalBytesExpectedToWrite total: Int64) {
        let frac = total > 0 ? Double(written) / Double(total) : -1
        DispatchQueue.main.async { self.state = .downloading(frac) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The temp file is only valid for the duration of this callback — validate + move now.
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(false, .failed("HTTP \(http.statusCode)"))
            return
        }
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: location.path)
        let size = (attrs?[.size] as? Int) ?? 0
        let magic = (try? FileHandle(forReadingFrom: location))
            .flatMap { fh -> String? in defer { try? fh.close() }; return (try? fh.read(upToCount: 4)).flatMap { String(data: $0, encoding: .ascii) } }
        guard size > 100_000_000, magic == "GGUF" else {
            finish(false, .failed("downloaded file is not a valid GGUF"))
            return
        }
        guard let dest = destination else { finish(false, .failed("no destination")); return }
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: location, to: dest)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
            finish(true, .done)
        } catch {
            finish(false, .failed(error.localizedDescription))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Success is handled in didFinishDownloadingTo; only surface real errors here.
        if let error = error { finish(false, .failed(error.localizedDescription)) }
    }
}
