import Foundation

/// On-device diagnostic log, kept as permanent infrastructure.
///
/// Built during the double-booking investigation and deliberately not
/// removed with the rest of that instrumentation. Two things were learned
/// the expensive way and are worth keeping available:
///
/// 1. **`print` alone is not a diagnostic channel on a real device.**
///    Reading it needs a live `devicectl --console` session, which is
///    tied to one process lifetime — and that failed twice, once to the
///    streaming session's own timeout and once when the app was simply
///    backgrounded and relaunched. Both produced an empty capture, which
///    is indistinguishable from "the bug didn't happen." For an
///    intermittent bug that ambiguity costs entire reproduction sessions.
/// 2. **Bugs in this scheduler surface as state, not crashes.** Silent
///    drains, phantom placements and double-books leave no trace unless
///    something wrote one at the time.
///
/// Its only current caller is the overlap rejection in
/// `ScheduleReviewViewModel.insertSchedulerBlock`, which should never
/// fire — a line in this file means the scheduler tried to double-book
/// and was stopped, and is worth investigating rather than ignoring.
/// Adding a temporary call site for the next investigation costs one line.
///
/// Appends to a file inside the app's own Documents directory, pulled
/// afterwards with:
///
///     xcrun devicectl device copy from --device <id> \
///       --domain-type appDataContainer \
///       --domain-identifier com.jimbo.NoteForLater \
///       --source Documents --destination <dir>
///
/// A file in the container survives app restarts, backgrounding, screen
/// locks, and needs no live tunnel — so a capture can span as long as it
/// needs to, and nothing is lost to a dropped session.
enum DiagFileLog {
    /// Serial, so concurrent writers can't interleave mid-line or race
    /// the file handle — the scheduling walks that call into this can run
    /// from several independent tasks.
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
