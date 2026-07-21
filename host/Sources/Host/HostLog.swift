import Foundation

/// This side's log: one file per launch, named for the moment it
/// started, in a `now-logs` folder.
///
/// The window already shows what is happening. What it cannot do is
/// tell you what happened before you looked, or after the app quit, or
/// while you were reading the other machine's screen — and those are
/// the times worth having. A hundred lines in memory is under a minute
/// of a busy transfer.
///
/// Written to `~/Library/Logs/now-logs`, which is where `tail -f` and
/// Console.app already look.
@MainActor
final class HostLog {
    static let shared = HostLog()

    private var handle: FileHandle?
    private(set) var url: URL?

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
            write("started")
        } catch {
            // A machine that cannot write a log must still run.
            handle = nil
        }
    }

    func write(_ text: String) {
        guard let handle else { return }
        let line = "\(Self.clock.string(from: Date())) \(text)\n"
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
