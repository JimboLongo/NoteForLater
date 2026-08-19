import Foundation

/// TEMPORARY DIAGNOSTIC INFRASTRUCTURE (docs/double-booking-plan.md
/// step 1) — remove along with its call sites once the double-booking
/// cause is confirmed.
///
/// Appends diagnostic lines to a file inside the app's own Documents
/// directory, to be pulled afterwards with:
///
///     xcrun devicectl device copy from --device <id> \
///       --domain-type appDataContainer \
///       --domain-identifier com.jimbo.NoteForLater \
///       --source Documents --destination <dir>
///
/// Replaces streaming over `devicectl ... --console`, which failed twice
/// for different reasons: once when the streaming session's own timeout
/// SIGTERM'd the app mid-session, and once when the app exited cleanly
/// (backgrounded) and iOS relaunched it, silently orphaning the capture
/// so an entire reproduction attempt recorded nothing. Both failures look
/// identical to "the bug didn't reproduce," which is the worst possible
/// ambiguity for an intermittent bug.
///
/// A file in the container survives app restarts, backgrounding, screen
/// locks, and needs no live tunnel — so a reproduction attempt can take
/// as long as it takes.
enum DiagFileLog {
    /// Serial, so concurrent walks — the very thing under investigation —
    /// can't interleave mid-line or race the file handle.
    private static let queue = DispatchQueue(label: "com.jimbo.NoteForLater.diaglog")

    private static let fileURL: URL? = {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("diag.log")
    }()

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// Marks a fresh app launch, so a pulled log makes session boundaries
    /// obvious rather than reading as one continuous run.
    static func markLaunch() {
        write("──────── app launch ────────")
    }

    static func write(_ line: String) {
        let stamped = "\(timestampFormatter.string(from: Date())) \(line)\n"
        // Mirrored to stdout so an attached console still works when one
        // happens to be running; the file is the reliable copy.
        print(stamped, terminator: "")
        queue.async {
            guard let fileURL, let data = stamped.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: fileURL.path) {
                guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
}
