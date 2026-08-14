import Foundation

/// Fulfils Finder file promises without ever opening a second guest transfer
/// lane. AppKit creates one promise per dragged row and may ask all of them at
/// once; this queue makes that concurrency explicit and walks folder promises
/// recursively over the existing `file.list` / `file.get` contract.
@MainActor
final class GuestFilePromiseExporter {
    typealias ListPage = (
        _ path: String,
        _ cursor: Int?,
        _ completion: @escaping (Result<FileListing, Error>) -> Void
    ) -> Void
    typealias FetchFile = (
        _ row: FileRow,
        _ destination: URL,
        _ completion: @escaping (Result<Void, Error>) -> Void
    ) -> Void
    typealias FailureReporter = (_ error: Error) -> Void

    private struct Request {
        let id = UUID()
        var row: FileRow
        var destination: URL
        var completion: (Result<Void, Error>) -> Void
        var ownsDestinationOnFailure = false
    }

    private final class Budget {
        var count = 0
    }

    private final class ListingAccumulator {
        var entries: [FileEntry] = []
    }

    enum ExportError: LocalizedError {
        case cancelled(String)
        case malformedListing(String)
        case tooManyItems(Int)
        case exportFailed(name: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .cancelled(let reason): return reason
            case .malformedListing(let reason): return reason
            case .tooManyItems(let limit):
                return "That folder contains more than \(limit) items."
            case .exportFailed(let name, let reason):
                return "Could not export \(name): \(reason)"
            }
        }
    }

    /// Same bounded shape as a folder sent in the other direction. A drag
    /// that expands into hours of wire traffic is refused before it grows
    /// without limit in this process.
    static let itemLimit = FilesModuleModel.dropFileLimit

    private let listPage: ListPage
    private let fetchFile: FetchFile
    private let onFailure: FailureReporter
    private let fileManager: FileManager
    private var pending: ArraySlice<Request> = []
    private var active: Request?
    private var generation = 0

    init(listPage: @escaping ListPage,
         fetchFile: @escaping FetchFile,
         onFailure: @escaping FailureReporter = { _ in },
         fileManager: FileManager = .default) {
        self.listPage = listPage
        self.fetchFile = fetchFile
        self.onFailure = onFailure
        self.fileManager = fileManager
    }

    func enqueue(_ row: FileRow, to destination: URL,
                 completion: @escaping (Result<Void, Error>) -> Void) {
        pending.append(Request(row: row, destination: destination,
                               completion: completion))
        startNextIfIdle()
    }

    /// A queued drag belongs to the guest that was visible when it began.
    /// Switching machines invalidates the active traversal and every promise
    /// behind it rather than letting their paths resolve on a different disk.
    func cancelAll(reason: String) {
        generation += 1
        let failure = ExportError.cancelled(reason)
        if let active {
            if active.ownsDestinationOnFailure {
                try? fileManager.removeItem(at: active.destination)
            }
            active.completion(.failure(failure))
        }
        for request in pending {
            request.completion(.failure(failure))
        }
        active = nil
        pending.removeAll()
    }

    private func startNextIfIdle() {
        guard active == nil, let request = pending.popFirst() else { return }
        active = request
        let token = generation
        if request.row.isFolder {
            exportFolder(request, token: token)
        } else {
            exportFile(request.row, to: request.destination,
                       token: token) { [weak self] result in
                self?.finish(request, result: result, token: token)
            }
        }
    }

    private func exportFolder(_ request: Request, token: Int) {
        do {
            try fileManager.createDirectory(
                at: request.destination, withIntermediateDirectories: false)
            if active?.id == request.id {
                active?.ownsDestinationOnFailure = true
            }
        } catch {
            finish(request, result: .failure(error), token: token)
            return
        }
        exportDirectory(path: request.row.path,
                        destination: request.destination,
                        budget: Budget(), token: token) { [weak self] result in
            self?.finish(request, result: result, token: token)
        }
    }

    private func exportDirectory(
        path: String,
        destination: URL,
        budget: Budget,
        token: Int,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        readAllPages(path: path, cursor: nil,
                     accumulated: ListingAccumulator(), budget: budget,
                     token: token) {
            [weak self] result in
            guard let self, token == self.generation else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let entries):
                self.export(entries, at: 0, parentPath: path,
                            destination: destination, budget: budget,
                            token: token, completion: completion)
            }
        }
    }

    private func readAllPages(
        path: String,
        cursor: Int?,
        accumulated: ListingAccumulator,
        budget: Budget,
        token: Int,
        completion: @escaping (Result<[FileEntry], Error>) -> Void
    ) {
        listPage(path, cursor) { [weak self] result in
            guard let self, token == self.generation else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let listing):
                guard listing.path == path else {
                    completion(.failure(ExportError.malformedListing(
                        "The guest listed \(listing.path) while \(path) was requested.")))
                    return
                }
                accumulated.entries.append(contentsOf: listing.entries)
                budget.count += listing.entries.count
                guard budget.count <= Self.itemLimit else {
                    completion(.failure(
                        ExportError.tooManyItems(Self.itemLimit)))
                    return
                }
                guard listing.more else {
                    completion(.success(accumulated.entries))
                    return
                }
                guard let next = listing.cursor,
                      next > (cursor ?? 0) else {
                    completion(.failure(ExportError.malformedListing(
                        "The guest repeated a folder listing position.")))
                    return
                }
                self.readAllPages(path: path, cursor: next,
                                  accumulated: accumulated, budget: budget,
                                  token: token,
                                  completion: completion)
            }
        }
    }

    private func export(
        _ entries: [FileEntry],
        at index: Int,
        parentPath: String,
        destination: URL,
        budget: Budget,
        token: Int,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard token == generation else { return }
        guard index < entries.count else {
            completion(.success(()))
            return
        }
        let entry = entries[index]
        let path = FileChangeNames.join(parentPath, entry.name)
        let localURL = destination.appendingPathComponent(
            LocalFileName.sanitized(entry.name), isDirectory: entry.isFolder)
        let next: (Result<Void, Error>) -> Void = { [weak self] result in
            guard let self, token == self.generation else { return }
            switch result {
            case .failure:
                completion(result)
            case .success:
                self.export(entries, at: index + 1,
                            parentPath: parentPath,
                            destination: destination, budget: budget,
                            token: token, completion: completion)
            }
        }

        if entry.isFolder {
            do {
                try fileManager.createDirectory(
                    at: localURL, withIntermediateDirectories: false)
            } catch {
                completion(.failure(error))
                return
            }
            exportDirectory(path: path, destination: localURL,
                            budget: budget, token: token, completion: next)
        } else {
            exportFile(FileRow(entry: entry, path: path), to: localURL,
                       token: token, completion: next)
        }
    }

    /// Fetch into a private sibling, then publish with one no-overwrite move.
    /// A destination created by another process while the guest is fetching
    /// is therefore never overwritten or removed by our failure cleanup.
    private func exportFile(
        _ row: FileRow,
        to destination: URL,
        token: Int,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".now-promise-\(UUID().uuidString)")
        fetchFile(row, staging) { [weak self] result in
            guard let self else { return }
            defer { try? self.fileManager.removeItem(at: staging) }
            guard token == self.generation else { return }
            switch result {
            case .failure:
                completion(result)
            case .success:
                do {
                    try self.fileManager.moveItem(at: staging,
                                                  to: destination)
                    completion(.success(()))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    private func finish(_ request: Request,
                        result: Result<Void, Error>, token: Int) {
        guard token == generation, active?.id == request.id else {
            return
        }
        if case .failure(let error) = result {
            if active?.ownsDestinationOnFailure == true {
                try? fileManager.removeItem(at: request.destination)
            }
            onFailure(ExportError.exportFailed(
                name: request.row.name, reason: error.localizedDescription))
        }
        active = nil
        request.completion(result)
        startNextIfIdle()
    }
}

/// Guest names use HFS rules; APFS paths cannot use slash and leading dots
/// disappear from ordinary Finder views. This is the same projection used by
/// direct downloads and promised folder children.
enum LocalFileName {
    static func sanitized(_ name: String) -> String {
        var output = name.replacingOccurrences(of: "/", with: ":")
        if output.hasPrefix(".") { output = "_" + output.dropFirst() }
        return output.isEmpty ? "Untitled" : output
    }
}
