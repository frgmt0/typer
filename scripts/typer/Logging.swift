import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

let typerLogURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Typer.log")

// When false (default), content-bearing logs (typed text, buffer/context/suggestion
// snippets) are suppressed so the log is not a plaintext keystroke transcript.
var debugLoggingEnabled = false

// The previous generation of the log, kept so a crash report still has the run before
// last to look at. Two files is the whole scheme: at most ~16 MB on disk, ever.
let typerLogArchiveURL = typerLogURL.appendingPathExtension("1")

// A single long-lived handle written on a serial queue, so logging never re-opens the
// file or blocks the (often main-thread) caller — the old open/seek/write/close per
// call ran several times per keystroke on the hot path.
let typerLogQueue = DispatchQueue(label: "typer.log", qos: .utility)

// Everything below is confined to `typerLogQueue`: opened lazily on the first write and
// mutated only there, so no locking is needed.
private let typerLogMaxBytes = 8_000_000
private var typerLogHandle: FileHandle?
private var typerLogOpened = false
private var typerLogSize = 0

private func typerLogOpen() {
    let fm = FileManager.default
    if !fm.fileExists(atPath: typerLogURL.path) {
        fm.createFile(atPath: typerLogURL.path, contents: nil,
                      attributes: [.posixPermissions: 0o600])
    }
    // Unconditionally, not just on create: the log is a transcript of what the user was
    // doing, and every path that can produce the file — a create here, a rotate that had
    // to fall back to rewriting it, an operator's `touch`, a restore from a backup — must
    // end with it owner-readable only. Re-applying costs one chmod per process launch.
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: typerLogURL.path)
    typerLogHandle = try? FileHandle(forWritingTo: typerLogURL)
    if let h = typerLogHandle, let end = try? h.seekToEnd() { typerLogSize = Int(end) }
    else { typerLogSize = 0 }
}

// Rotate at the cap instead of growing without bound — the log was a plain append-only
// file and had reached 16 MB in the field. The running size is tracked in memory as
// lines are written, so the hot path never stats the file.
private func typerLogRotate() {
    let fm = FileManager.default
    try? typerLogHandle?.close()
    typerLogHandle = nil
    try? fm.removeItem(at: typerLogArchiveURL)
    do { try fm.moveItem(at: typerLogURL, to: typerLogArchiveURL) } catch {
        // Couldn't rotate (permissions, a deleted directory) — truncate in place rather
        // than let the file keep growing. `Data().write(options: .atomic)` writes a temp
        // file and renames it over the target, so the result is a BRAND NEW inode with
        // the process umask's permissions (0644 by default) — the 0600 the original was
        // created with does not survive. Restore it immediately, before typerLogOpen()
        // starts appending the next run's keystroke-adjacent lines to a world-readable
        // file.
        try? Data().write(to: typerLogURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: typerLogURL.path)
    }
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: typerLogArchiveURL.path)
    typerLogOpen()
}

func log(_ message: String) {
    let line = "\(Date()) \(message)\n"
    typerLogQueue.async {
        if !typerLogOpened { typerLogOpened = true; typerLogOpen() }
        guard let h = typerLogHandle else { return }
        let bytes = Data(line.utf8)
        try? h.write(contentsOf: bytes)
        typerLogSize += bytes.count
        if typerLogSize > typerLogMaxBytes { typerLogRotate() }
    }
}

// Content-bearing log: only written when debug logging is explicitly enabled, so the
// log never becomes a plaintext record of what the user typed.
func dlog(_ message: @autoclosure () -> String) {
    if debugLoggingEnabled { log(message()) }
}
