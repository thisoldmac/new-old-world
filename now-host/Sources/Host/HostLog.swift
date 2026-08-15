import Foundation
import NOWAgentIntegration

/// This side's log: an in-memory ring the Logs module dumps, plus, when
/// disk is on, one file per launch in `~/Library/Logs/now-logs` — where
/// `tail -f` and Console.app already look.
///
/// The window shows what is happening now; the log is for what happened
/// before you looked, after the app quit, or while you were reading the
/// other machine's screen. The in-memory ring is always live; the file is
/// a switch, because a Mac that is not crashing does not always need one.
@MainActor
final class HostLog: ObservableObject {
    static let shared = HostLog()

    struct Line: Identifiable, Equatable {
        let id: Int
        let text: String
        /// The area this line was written under, kept BESIDE the formatted
        /// text rather than recovered from it.
        ///
        /// `now_host_log_tail` filters by area, and the alternative is to
        /// slice the tag back out of `text` at an offset only `write` knows —
        /// a second statement of this line's format, free to disagree with
        /// the first the day the format moves. Padded and truncated exactly
        /// as the tag is, so what a caller filters on is what a reader sees.
        let area: String
    }

    /// The scrollback the Logs page reads, oldest first, capped so a busy
    /// run cannot grow it without bound. Mirrors the guest's ring size.
    @Published private(set) var lines: [Line] = []
    /// Readable by tests, which otherwise have to assert the ring's
    /// behaviour against a number they have hardcoded a second time.
    ///
    /// **Stated in `AgentIntegrationHostLogPolicy` and read here**, not the
    /// other way round: `now_host_log_tail` publishes this number as its
    /// maximum count and lives in a module the app depends on, so the policy
    /// is the only place both sides can read one copy.
    static let ringCapacity = AgentIntegrationHostLogPolicy.ringCapacity

    /// Whether a line also reaches the file. Reflects the ACTUAL state — a
    /// failed open leaves it false — so the Logs switch cannot claim a
    /// file it does not have.
    private(set) var persistsToDisk = false
    private(set) var url: URL?
    private var handle: FileHandle?
    private var nextID = 0

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return f
    }()
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private init() {
        // The ring is live from the first line; the file waits for the
        // saved switch, applied by LogsModel at launch.
        write(.info, "app", "started")
    }

    /// One line, in the format docs/logging.md defines:
    /// `HH:MM:SS area   [!?] message`. Both machines write the same shape
    /// so the two files can be read as one. It always reaches the ring;
    /// it reaches the file only when disk is on.
    func write(_ level: LogLevel = .info, _ area: String = "host",
               _ text: String) {
        let mark = level == .error ? "! " : (level == .warn ? "? " : "")
        let tag = area.padding(
            toLength: AgentIntegrationHostLogPolicy.areaTagScalars,
            withPad: " ", startingAt: 0)
        let body = "\(Self.clock.string(from: Date())) \(tag) \(mark)\(text)"

        lines.append(Line(id: nextID, text: body, area: tag))
        nextID += 1
        if lines.count > Self.ringCapacity {
            lines.removeFirst(lines.count - Self.ringCapacity)
        }

        if let handle {
            try? handle.write(contentsOf: Data((body + "\n").utf8))
        }
    }

    /// Turn the file on or off. Idempotent; opening starts a fresh
    /// per-launch file, closing keeps the ring untouched.
    func setPersistsToDisk(_ on: Bool) {
        if on == (handle != nil) {
            persistsToDisk = handle != nil
            return
        }
        if on {
            openFile()
            if handle != nil {
                write(.info, "app", "disk logging on")
            }
        } else {
            write(.info, "app", "disk logging off")   // last line to the file
            try? handle?.close()
            handle = nil
        }
        persistsToDisk = handle != nil
    }

    private func openFile() {
        guard let logs = FileManager.default.urls(for: .libraryDirectory,
                                                  in: .userDomainMask).first?
            .appendingPathComponent("Logs/now-logs") else { return }
        do {
            try FileManager.default.createDirectory(
                at: logs, withIntermediateDirectories: true)
            let file = logs.appendingPathComponent(
                "\(Self.stamp.string(from: Date())).log")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            handle = try FileHandle(forWritingTo: file)
            url = file
        } catch {
            // A machine that cannot write a log must still run.
            handle = nil
            url = nil
        }
    }

    enum LogLevel {
        case info, warn, error
    }
}
