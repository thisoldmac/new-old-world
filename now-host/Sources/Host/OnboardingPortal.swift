import Combine
import Darwin
import Foundation

struct OnboardingEndpoint: Equatable {
    let host: String
    let httpPort: UInt16
    let wirePort: UInt16

    var pageURL: URL? {
        URL(string: "http://\(host):\(httpPort)/")
    }
}

struct OnboardingSetupImage: Equatable {
    let fileName: String
    let transferByteCount: Int64
    let diskByteCount: Int64
    let includedItems: [String]
    let builtAt: Date
}

/// A temporary, fixed-route HTTP server for getting the PPC guest onto a
/// LAN. It is intentionally not a general web server: GET/HEAD only, one
/// page, generated settings, and files already admitted by the catalog.
@MainActor
final class OnboardingPortal: ObservableObject {
    /// The port a person types on a 1993 keyboard. Stable so a bookmark or
    /// a remembered number keeps working across sessions; when something
    /// else holds it, the listener falls back to an ephemeral port rather
    /// than refusing to onboard at all.
    static let preferredPort: UInt16 = 5280

    typealias SetupImageBuilder = @Sendable (
        String, UInt16, OnboardingAssetSnapshot, OnboardingGuestFlavor)
        async throws -> Data

    enum State: Equatable {
        case stopped
        case starting
        case running(OnboardingEndpoint)
        case failed(String)
    }

    enum DependencyAcquisitionState: Equatable {
        case downloading
        case failed(String)
    }

    enum SetupImageState: Equatable {
        case notBuilt
        case building
        case ready(OnboardingSetupImage)
        case failed(String)
    }

    enum SetupImageError: LocalizedError {
        case notRunning

        var errorDescription: String? {
            "Start onboarding before creating a setup disk so its settings "
                + "can use the advertised host address."
        }
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var assets: OnboardingAssetSnapshot = .empty
    @Published private(set) var dependencyAcquisitions:
        [String: DependencyAcquisitionState] = [:]
    @Published private(set) var selectedAssetIDs: Set<String> = []
    @Published private(set) var setupImageState: SetupImageState = .notBuilt
    @Published var guestFlavor: OnboardingGuestFlavor = .powerpc

    /// The accept loop's queue; each connection then runs on its own
    /// utility work item with plain blocking I/O.
    ///
    /// This server deliberately speaks BSD sockets, not Network.framework.
    /// A packet capture (2026-08-18, G3 over 10BASE-T) showed every first
    /// transmission of every segment from the framework-backed listener
    /// vanishing and only the ~250 ms timer retransmission being ACKed -
    /// a 4-5 KB/s lockstep - while python's socket-backed http.server on
    /// the same wire, same machine, moved 300-400 KB/s. Per-flow
    /// interference with framework flows on this platform is outside our
    /// control; the socket path demonstrably is not.
    private nonisolated let transportQueue = DispatchQueue(
        label: "now.onboarding.accept")
    private nonisolated let connectionQueue = DispatchQueue(
        label: "now.onboarding.connections", attributes: .concurrent)
    private let preferredPort: UInt16
    private let catalog: OnboardingAssetCatalog
    private let dependencyAcquirer: OnboardingDependencyAcquirer
    private let setupImageBuilder: SetupImageBuilder
    private let advertisedAddress: () -> String?
    private var serverSocket: Int32 = -1
    private var generation = 0
    private var wirePort: UInt16 = SettingsModel.defaultPort
    private var knownAssetIDs: Set<String> = []
    private var setupImageData: Data?
    private var setupImageSelection: Set<String> = []
    private var setupImageFlavor: OnboardingGuestFlavor = .powerpc

    init(catalog: OnboardingAssetCatalog = .live(),
         preferredPort: UInt16 = OnboardingPortal.preferredPort,
         dependencyAcquirer: OnboardingDependencyAcquirer? = nil,
         setupImageBuilder: @escaping SetupImageBuilder = {
             host, port, assets, flavor in
             try await ClassicSetupImageBuilder().build(
                 host: host, wirePort: port, assets: assets, flavor: flavor)
         },
         advertisedAddress: @escaping () -> String? = {
             HostAddressDetector.primaryIPv4()
         }) {
        self.catalog = catalog
        self.preferredPort = preferredPort
        self.dependencyAcquirer = dependencyAcquirer ?? .live()
        self.setupImageBuilder = setupImageBuilder
        self.advertisedAddress = advertisedAddress
        refreshAssets()
    }

    var endpoint: OnboardingEndpoint? {
        guard case .running(let endpoint) = state else { return nil }
        return endpoint
    }

    func start(wirePort: UInt16) {
        if let endpoint, endpoint.wirePort == wirePort {
            refreshAssets()
            return
        }
        stop()
        self.wirePort = wirePort
        setupImageData = nil
        setupImageSelection = []
        setupImageState = .notBuilt
        refreshAssets()
        state = .starting
        generation += 1
        beginListening()
    }

    private func beginListening() {
        let run = generation
        // The preferred port being held (another host instance, an
        // earlier session) is an expected state, not a failure: fall
        // back to an ephemeral port, then report honestly.
        var bound = bindAndListen(port: preferredPort)
        if bound == nil { bound = bindAndListen(port: 0) }
        guard let (socket, actualPort) = bound else {
            state = .failed("Could not start onboarding: no listening "
                            + "socket could be bound.")
            return
        }
        guard let host = advertisedAddress() else {
            close(socket)
            state = .failed("No active LAN IPv4 address was found. "
                            + "Connect this Mac to the same LAN first.")
            return
        }
        serverSocket = socket
        state = .running(OnboardingEndpoint(
            host: host, httpPort: actualPort, wirePort: wirePort))
        Task { @MainActor [weak self] in
            try? await self?.rebuildSetupImage()
        }
        transportQueue.async { [weak self] in
            self?.acceptLoop(socket: socket, run: run)
        }
    }

    private nonisolated func bindAndListen(port: UInt16)
        -> (Int32, UInt16)? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes,
                   socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            return nil
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            close(fd)
            return nil
        }
        return (fd, UInt16(bigEndian: actual.sin_port))
    }

    private nonisolated func acceptLoop(socket serverFD: Int32, run: Int) {
        while true {
            var peer = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(serverFD, $0, &length)
                }
            }
            guard client >= 0 else { return }   // closed by stop()
            connectionQueue.async { [weak self] in
                guard let self else { close(client); return }
                self.serve(client: client, run: run)
                close(client)
            }
        }
    }

    func stop() {
        generation += 1
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        state = .stopped
    }

    func refreshAssets() {
        assets = catalog.snapshot()
        let available = selectableAssets.map(\.id)
        let availableIDs = Set(available)
        selectedAssetIDs.formIntersection(availableIDs)
        selectedAssetIDs.formUnion(availableIDs.subtracting(knownAssetIDs))
        if let application = assets.application {
            selectedAssetIDs.insert(application.id)
        }
        if let application68K = assets.application68K {
            selectedAssetIDs.insert(application68K.id)
        }
        knownAssetIDs = availableIDs
    }

    // Both flavors' applications stay selectable so a discovered asset is
    // auto-selected whichever pill is active; what a flavor OFFERS is the
    // page's and image's decision, made per request from `guestFlavor`.
    var selectableAssets: [OnboardingAsset] {
        [assets.application, assets.application68K, assets.codeKitten,
         assets.extensionComponent].compactMap { $0 }
            + OnboardingDependencyCatalog.setupAssets(in: assets)
    }

    var hasPendingSetupImageChanges: Bool {
        setupImageData != nil
            && (setupImageSelection != selectedAssetIDs
                || setupImageFlavor != guestFlavor)
    }

    func isSelected(_ asset: OnboardingAsset) -> Bool {
        selectedAssetIDs.contains(asset.id)
    }

    func setSelected(_ selected: Bool, asset: OnboardingAsset) {
        if asset.kind == .application || asset.kind == .application68K {
            return
        }
        var selection = selectedAssetIDs
        if selected {
            selection.insert(asset.id)
        } else {
            selection.remove(asset.id)
        }
        selectedAssetIDs = selection
    }

    func preparePackagesFolder() throws -> URL {
        let url = try catalog.prepareWritableRoot()
        refreshAssets()
        return url
    }

    func acquire(_ dependency: OnboardingDependency) {
        if dependencyAcquisitions[dependency.id] == .downloading { return }
        dependencyAcquisitions[dependency.id] = .downloading
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await dependencyAcquirer.acquire(
                    dependency, catalog: catalog)
                dependencyAcquisitions[dependency.id] = nil
                refreshAssets()
            } catch {
                dependencyAcquisitions[dependency.id] = .failed(
                    error.localizedDescription)
            }
        }
    }

    @discardableResult
    func rebuildSetupImage() async throws -> OnboardingSetupImage {
        guard let endpoint else { throw SetupImageError.notRunning }
        refreshAssets()
        setupImageState = .building
        do {
            let selection = selectedAssetIDs
            let flavor = guestFlavor
            let selected = selectedAssets(selection: selection)
            let image = try await setupImageBuilder(
                endpoint.host, endpoint.wirePort, selected, flavor)
            let summary = setupImageSummary(image, assets: selected,
                                            flavor: flavor)
            setupImageData = image
            setupImageSelection = selection
            setupImageFlavor = flavor
            setupImageState = .ready(summary)
            return summary
        } catch {
            setupImageState = .failed(error.localizedDescription)
            throw error
        }
    }

    func currentSetupImage() -> Data? {
        setupImageData
    }

    private func selectedAssets(selection: Set<String>)
        -> OnboardingAssetSnapshot {
        OnboardingAssetSnapshot(
            application: assets.application.flatMap {
                selection.contains($0.id) ? $0 : nil
            },
            application68K: assets.application68K.flatMap {
                selection.contains($0.id) ? $0 : nil
            },
            codeKitten: assets.codeKitten.flatMap {
                selection.contains($0.id) ? $0 : nil
            },
            extensionComponent: assets.extensionComponent.flatMap {
                selection.contains($0.id) ? $0 : nil
            },
            dependencies: assets.dependencies.filter {
                selection.contains($0.id)
            })
    }

    private func setupImageSummary(_ image: Data,
                                   assets: OnboardingAssetSnapshot,
                                   flavor: OnboardingGuestFlavor)
        -> OnboardingSetupImage {
        let diskBytes = (try? MacBinaryFile.decode(image))
            .map { Int64($0.dataFork.count) } ?? 0
        var items: [String]
        switch flavor {
        case .powerpc:
            items = ["New Old World", "Host settings", "Read Me First"]
            if assets.codeKitten != nil { items.append("CodeKitten") }
            if assets.extensionComponent != nil {
                items.append("NOW Extension")
            }
            items += OnboardingDependencyCatalog.setupAssets(in: assets)
                .map { asset in
                    OnboardingDependencyCatalog.all.first(
                        where: { $0.matches(asset) })?.displayName
                        ?? asset.fileName
                }
        case .m68k:
            // No settings: NOW-68K ships no preferences as a product
            // property. No CodeKitten or CarbonLib: both are Carbon.
            items = ["NOW-68K", "Read Me First"]
            if assets.extensionComponent != nil {
                items.append("NOW Extension")
            }
        }
        return OnboardingSetupImage(
            fileName: ClassicSetupImageBuilder.classicImageName(for: flavor),
            transferByteCount: Int64(image.count), diskByteCount: diskBytes,
            includedItems: items, builtAt: Date())
    }

    /// One connection, blocking I/O, on a utility work item: read the
    /// request (bounded, with a receive timeout so a stalled peer cannot
    /// pin the thread), route it on the MainActor where the portal's
    /// state lives, then write the response to the wire.
    private nonisolated func serve(client: Int32, run: Int) {
        var yes: Int32 = 1
        // A peer that aborts mid-transfer must cost one connection, not
        // the process: without NOSIGPIPE the write loop's first EPIPE
        // arrives as SIGPIPE and kills the app with no crash report.
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes,
                   socklen_t(MemoryLayout<Int32>.size))
        setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &yes,
                   socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))
        // Per-write progress timeout: a slow classic reader keeps making
        // progress and is never cut off; a peer that vanished without an
        // RST stops the transfer in one minute instead of holding the
        // connection thread forever.
        var sendTimeout = timeval(tv_sec: 60, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout,
                   socklen_t(MemoryLayout<timeval>.size))

        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 2_048)
        while request.count <= 8_192 {
            let got = read(client, &buffer, buffer.count)
            if got <= 0 { break }
            request.append(contentsOf: buffer[0..<got])
            if request.range(of: Data("\r\n\r\n".utf8)) != nil
                || request.range(of: Data("\n\n".utf8)) != nil {
                break
            }
        }
        if request.count > 8_192 {
            write(response: .plain(status: 431,
                                   reason: "Request Header Too Large",
                                   text: "Request header too large.\r\n"),
                  headOnly: false, to: client, path: "-")
            return
        }

        guard let text = String(data: request, encoding: .isoLatin1),
              let firstLine = text.split(whereSeparator: \.isNewline).first
        else {
            write(response: .plain(status: 400, reason: "Bad Request",
                                   text: "Bad request.\r\n"),
                  headOnly: false, to: client, path: "-")
            return
        }
        let fields = firstLine.split(separator: " ",
                                     omittingEmptySubsequences: true)
        guard fields.count >= 2 else {
            write(response: .plain(status: 400, reason: "Bad Request",
                                   text: "Bad request.\r\n"),
                  headOnly: false, to: client, path: "-")
            return
        }
        let method = String(fields[0]).uppercased()
        guard method == "GET" || method == "HEAD" else {
            write(response: .plain(
                      status: 405, reason: "Method Not Allowed",
                      text: "Only GET and HEAD are supported.\r\n",
                      extraHeaders: ["Allow: GET, HEAD"]),
                  headOnly: method == "HEAD", to: client, path: "-")
            return
        }

        let path = requestPath(String(fields[1]))
        // Every guest-browser experiment so far had been interpreted from
        // memory of what the browser probably did. The log line is the
        // evidence: which route the guest actually fetched, and as whom.
        let userAgent = text.split(whereSeparator: \.isNewline)
            .first { $0.lowercased().hasPrefix("user-agent:") }
            .map { $0.dropFirst("user-agent:".count)
                .trimmingCharacters(in: .whitespaces) } ?? "-"
        Task { @MainActor in
            HostLog.shared.write(.info, "onboarding",
                                 "\(method) \(path) ua=\(userAgent)")
        }

        let localHost = localAddress(of: client)
        let response = routed(path: path, localHost: localHost, run: run)
        write(response: response, headOnly: method == "HEAD", to: client,
              path: path)
    }

    /// Hop to the MainActor for routing - the portal's published state
    /// lives there - and block this connection's thread until the
    /// response exists. The image route may build the image first.
    private nonisolated func routed(path: String, localHost: String?,
                                    run: Int) -> HTTPResponse {
        final class Box: @unchecked Sendable {
            var response = HTTPResponse.plain(
                status: 500, reason: "Internal Server Error",
                text: "The host did not answer.\r\n")
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor [weak self] in
            defer { done.signal() }
            guard let self, self.generation == run else { return }
            let host = localHost
                ?? self.endpoint?.host
                ?? self.advertisedAddress()
                ?? "127.0.0.1"
            if path == "/now/setup.img" || path == "/now/setup.img.bin" {
                box.response = await self.setupImageResponse(
                    envelopeFallback: path.hasSuffix(".bin"))
            } else {
                box.response = self.response(for: path, host: host)
            }
        }
        done.wait()
        return box.response
    }

    /// A plain write loop - partial writes and EINTR are the whole
    /// story - with the transfer's drain rate logged for anything big
    /// enough to be a package: the wire number that settles slow-path
    /// questions, recorded by the server itself.
    private nonisolated func write(response: HTTPResponse, headOnly: Bool,
                                   to client: Int32, path: String) {
        var header = "HTTP/1.0 \(response.status) \(response.reason)\r\n"
        header += "Content-Type: \(response.contentType)\r\n"
        header += "Content-Length: \(response.body.count)\r\n"
        header += "Connection: close\r\n"
        for line in response.extraHeaders { header += "\(line)\r\n" }
        header += "\r\n"
        var message = Data(header.utf8)
        if !headOnly { message.append(response.body) }

        let started = Date()
        var failure: Int32 = 0
        message.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < bytes.count {
                let wrote = Darwin.write(
                    client, bytes.baseAddress! + offset,
                    bytes.count - offset)
                if wrote > 0 {
                    offset += wrote
                } else if wrote < 0 && errno == EINTR {
                    continue
                } else {
                    failure = errno != 0 ? errno : ETIMEDOUT
                    return
                }
            }
        }
        let bytes = message.count
        if bytes > 64 * 1_024 || failure != 0 {
            let seconds = max(0.001, Date().timeIntervalSince(started))
            let rate = Double(bytes) / seconds / 1_024
            let line = String(
                format: "sent %@ %dB in %.1fs (%.0f KB/s)%@", path,
                bytes, seconds, rate,
                failure != 0 ? " errno=\(failure)" : "")
            Task { @MainActor in
                HostLog.shared.write(failure == 0 ? .info : .warn,
                                     "onboarding", line)
            }
        }
        // Let the peer drain before close tears the window down: shutdown
        // sends FIN, and the bounded read waits for the peer's own close
        // (SO_RCVTIMEO caps each read; the count caps a chatty peer).
        shutdown(client, SHUT_WR)
        var drain = [UInt8](repeating: 0, count: 1_024)
        var drains = 0
        while drains < 64, read(client, &drain, drain.count) > 0 {
            drains += 1
        }
    }

    private nonisolated func localAddress(of client: Int32) -> String? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(client, $0, &length)
            }
        }
        guard named == 0, address.sin_family == sa_family_t(AF_INET)
        else { return nil }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var raw = address.sin_addr
        guard inet_ntop(AF_INET, &raw, &text,
                        socklen_t(INET_ADDRSTRLEN)) != nil else {
            return nil
        }
        let value = String(cString: text)
        return value == "0.0.0.0" ? nil : value
    }

    private func setupImageResponse(envelopeFallback: Bool) async
        -> HTTPResponse {
        do {
            let image: Data
            if let cached = setupImageData {
                image = cached
            } else if case .building = setupImageState {
                return .plain(
                    status: 503, reason: "Service Unavailable",
                    text: "The install image is still being built. "
                        + "Try the download again in a moment.\r\n",
                    extraHeaders: ["Retry-After: 2"])
            } else {
                _ = try await rebuildSetupImage()
                guard let built = setupImageData else {
                    throw SetupImageError.notRunning
                }
                image = built
            }
            if envelopeFallback {
                return .download(
                    data: image,
                    fileName: ClassicSetupImageBuilder.downloadFileName(
                        for: setupImageFlavor),
                    contentType: "application/macbinary")
            }
            // The 68K image is a Disk Copy 4.2 container - data-fork-only
            // by design - so the plain route serves it BARE: a browser
            // with no MacBinary decoder (MacWeb) saves a byte-perfect,
            // openable image. The PPC image is NDIF, whose bcem resource
            // only survives inside MacBinary, so its plain route stays an
            // envelope in the one standard spelling classic browsers map.
            if setupImageFlavor == .m68k {
                let container = try MacBinaryFile.decode(image).dataFork
                return .download(
                    data: container,
                    fileName: ClassicSetupImageBuilder.classicImageName(
                        for: .m68k),
                    contentType: "application/octet-stream")
            }
            return .download(
                data: image,
                fileName: ClassicSetupImageBuilder.downloadFileName(
                    for: setupImageFlavor),
                contentType: "application/macbinary")
        } catch {
            return .plain(status: 500, reason: "Internal Server Error",
                          text: error.localizedDescription + "\r\n")
        }
    }

    private func response(for path: String, host: String) -> HTTPResponse {
        refreshAssets()
        switch path {
        case "/", "/now", "/now/":
            let setupImage: OnboardingSetupImage?
            if case .ready(let image) = setupImageState {
                setupImage = image
            } else {
                setupImage = nil
            }
            let page = OnboardingPage.render(host: host,
                                             wirePort: wirePort,
                                             assets: assets,
                                             flavor: guestFlavor,
                                             setupImage: setupImage)
            return .data(status: 200, reason: "OK",
                         contentType: "text/html; charset=utf-8",
                         data: Data(page.utf8))
        case "/now/settings.bin":
            guard let data = OnboardingPreferences.macBinary(
                host: host, port: wirePort) else {
                return .plain(status: 500, reason: "Internal Server Error",
                              text: "Could not make the settings file.\r\n")
            }
            return .download(data: data,
                             fileName: "New Old World Prefs.bin",
                             contentType: "application/macbinary")
        case "/now/application.bin":
            return assetResponse(assets.application(for: guestFlavor))
        case "/now/codekitten.bin":
            return assetResponse(assets.codeKitten)
        case "/now/extension.bin":
            return assetResponse(assets.extensionComponent)
        default:
            if path.hasPrefix("/now/dependencies/") {
                let encoded = String(path.dropFirst(
                    "/now/dependencies/".count))
                let name = encoded.removingPercentEncoding ?? encoded
                return assetResponse(assets.dependencies.first {
                    $0.fileName == name
                })
            }
            return .plain(status: 404, reason: "Not Found",
                          text: "Not found.\r\n")
        }
    }

    private func assetResponse(_ asset: OnboardingAsset?) -> HTTPResponse {
        guard let asset else {
            return .plain(status: 404, reason: "Not Found",
                          text: "That package is not installed on this "
                              + "host.\r\n")
        }
        do {
            let data = try Data(contentsOf: asset.fileURL,
                                options: [.mappedIfSafe])
            return .download(data: data, fileName: asset.fileName,
                             contentType: contentType(for: asset.fileURL))
        } catch {
            return .plain(status: 500, reason: "Internal Server Error",
                          text: "The host could not read that package.\r\n")
        }
    }

    private nonisolated func requestPath(_ target: String) -> String {
        if target.hasPrefix("http://") || target.hasPrefix("https://"),
           let parts = URLComponents(string: target) {
            return parts.percentEncodedPath.isEmpty
                ? "/" : parts.percentEncodedPath
        }
        return String(target.split(separator: "?", maxSplits: 1,
                                   omittingEmptySubsequences: false)[0])
    }

    private nonisolated func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "bin": return "application/macbinary"
        case "sit": return "application/x-stuffit"
        case "hqx": return "application/mac-binhex40"
        case "img", "dsk": return "application/octet-stream"
        default: return "application/octet-stream"
        }
    }
}

private struct HTTPResponse: Sendable {
    let status: Int
    let reason: String
    let contentType: String
    let body: Data
    let extraHeaders: [String]

    static func data(status: Int, reason: String, contentType: String,
                     data: Data, extraHeaders: [String] = []) -> HTTPResponse {
        HTTPResponse(status: status, reason: reason,
                     contentType: contentType, body: data,
                     extraHeaders: extraHeaders)
    }

    static func plain(status: Int, reason: String, text: String,
                      extraHeaders: [String] = []) -> HTTPResponse {
        data(status: status, reason: reason,
             contentType: "text/plain; charset=us-ascii",
             data: Data(text.utf8), extraHeaders: extraHeaders)
    }

    static func download(data: Data, fileName: String,
                         contentType: String) -> HTTPResponse {
        let safe = fileName.map { character -> Character in
            character == "\"" || character == "\r" || character == "\n"
                ? "_" : character
        }
        return self.data(
            status: 200, reason: "OK", contentType: contentType, data: data,
            extraHeaders: [
                "Content-Disposition: attachment; filename=\"\(String(safe))\""
            ])
    }
}
