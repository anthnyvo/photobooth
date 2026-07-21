import Foundation

/// A small on-device event log, so a failure at a real event leaves evidence
/// instead of only a memory of what happened.
///
/// Deliberately local and dependency-free rather than a network error
/// reporter. This booth is designed to run with no internet at all, which is
/// exactly when things go wrong and exactly when a network reporter would
/// drop the events worth having. Writing to disk works offline, adds no SPM
/// dependency to a Swift Playgrounds package, and the attendant can export
/// the file afterwards the same way they already export leads.
///
/// Intentionally NOT a crash reporter: catching signals would mean installing
/// handlers, and an unhandled crash is the one case this can't capture. What
/// it does capture is the far more common failure shape here, where nothing
/// crashes but the camera won't connect, a capture silently fails, or a sync
/// quietly falls back to cached data.
///
/// Never records guest personal data. Lead names, emails and phone numbers
/// stay out of here on purpose: this file is meant to be exportable and
/// shareable for support without becoming a second, unmanaged copy of
/// someone's contact details.
public final class DiagnosticLog: @unchecked Sendable {

    public static let shared = DiagnosticLog()

    public enum Category: String {
        case camera
        case capture
        case sync
        case share
        case print
        case app
    }

    /// Keeps the file bounded so a long-running booth can't fill storage.
    /// When it grows past this, the oldest half is dropped.
    private let maxBytes = 256 * 1024

    private let lock = NSLock()
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private init() {}

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("diagnostics.log")
    }

    /// Appends one line. Failure to write is swallowed on purpose: logging
    /// must never take down the guest flow it's observing.
    public func log(_ category: Category, _ message: String) {
        let line = "[\(formatter.string(from: Date()))] [\(category.rawValue)] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        guard let data = line.data(using: .utf8) else { return }
        let url = fileURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
        trimIfNeededLocked(url)
    }

    /// Caller already holds the lock.
    private func trimIfNeededLocked(_ url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > maxBytes,
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.suffix(lines.count / 2).joined(separator: "\n")
        try? kept.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    /// Full log text for the export sheet. Empty string when nothing has been
    /// logged yet, so the caller can show a "nothing to export" state.
    public func exportText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    /// Writes the log to a temp file for sharing, returning nil when there's
    /// nothing worth exporting.
    public func exportFile() -> URL? {
        let text = exportText()
        guard !text.isEmpty else { return nil }
        let stamp = Int(Date().timeIntervalSince1970)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shutterglow-diagnostics-\(stamp).txt")
        guard (try? text.data(using: .utf8)?.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
