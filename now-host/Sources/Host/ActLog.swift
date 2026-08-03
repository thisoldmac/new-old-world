import Foundation

/// A line per act: what was sent, what came back, and how long it took.
///
/// The gap this closes is specific. On 2026-08-03 a full day of driving
/// the mirror repeatedly could not distinguish three different things
/// that look identical from the outside:
///
///   - the act never left (nothing was dispatched at all)
///   - the act was refused, with a reason nobody saw
///   - the act worked and the machine simply took twenty seconds
///
/// All three present as "I clicked and nothing happened", and each wants
/// a different fix. Several wrong calls that day - a title-bar drag
/// scored as broken, an icon-open scored as failed, a modal alert
/// scored as undismissable when the click HAD dismissed it - came out of
/// exactly that ambiguity.
///
/// Deliberately a file and not just an in-memory ring: the interesting
/// act is usually several minutes and a dozen screenshots ago by the
/// time it turns out to matter.
enum ActLog {
    /// `~/Library/Logs/NewOldWorld/acts.log`, or nothing if it cannot be
    /// made — a logger that throws is worse than one that is quiet.
    private static let url: URL? = {
        guard let base = FileManager.default.urls(
            for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("Logs/NewOldWorld",
                                              isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir.appendingPathComponent("acts.log")
    }()

    private static let queue = DispatchQueue(label: "dev.newoldworld.actlog")

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func note(action: String, outcome: String, ms: Int) {
        /* The outcome is written verbatim, refusal codes and all. A
           logger that tidied `no-such-process` into "failed" would be
           throwing away the only part that says WHY. */
        let line = "\(stamp.string(from: Date()))  \(ms)ms  \(outcome)\n"
            + "    \(action)\n"
        queue.async {
            guard let url else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
