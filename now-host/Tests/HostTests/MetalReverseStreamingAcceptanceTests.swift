import Combine
import Darwin
import Foundation
import XCTest
@testable import Host

/// An opt-in, disposable PowerBook acceptance harness for guest-to-host files.
///
/// The canonical guest remains the bootstrap: it creates one uniquely named
/// folder inside its configured share, receives a separately named MacBinary,
/// and launches it. The experimental copy uses compile-time connection
/// defaults and dials a second listener, so no guest preference is edited.
///
///     NOW_METAL_REVERSE=1 \
///     NOW_METAL_ARTIFACT=/tmp/NOW\ RS\ 695d02b.bin \
///     swift test --filter MetalReverseStreamingAcceptanceTests
@MainActor
final class MetalReverseStreamingAcceptanceTests: XCTestCase {
    private let appName = "NOW RS 695d02b"
    private var bootstrap: GuestListener?
    private var isolated: GuestListener?
    private var deployFolder: String?
    private var dataFolder: String?
    private var hostFolder: URL?
    private var cleanupNotes: [String] = []

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            env["NOW_METAL_REVERSE"] != nil,
            "set NOW_METAL_REVERSE=1 for the disposable PowerBook run")
        try XCTSkipUnless(
            env["NOW_METAL_ARTIFACT"] != nil,
            "NOW_METAL_ARTIFACT must name the separately stamped MacBinary")
    }

    override func tearDown() async throws {
        if let folder = dataFolder, let isolated,
           case .connected = isolated.state {
            if let result = try? await trash(folder, with: isolated) {
                cleanupNotes.append(
                    "guest data folder -> Trash as \(result.trashedAs ?? "?")")
                dataFolder = nil
            }
        }

        if let isolated, case .connected = isolated.state {
            if let process = try? await allProcesses(on: isolated)
                .first(where: { $0.name == appName }),
               let high = process.psnHigh, let low = process.psnLow {
                _ = try? await driveQuit(high: high, low: low, on: isolated)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        isolated?.stop()

        if let folder = deployFolder, let bootstrap,
           case .connected = bootstrap.state {
            if let result = try? await trash(folder, with: bootstrap) {
                cleanupNotes.append(
                    "guest deploy folder -> Trash as \(result.trashedAs ?? "?")")
                deployFolder = nil
            }
        }
        bootstrap?.stop()

        if let hostFolder {
            try? FileManager.default.removeItem(at: hostFolder)
        }
        for note in cleanupNotes {
            print("=== cleanup: \(note)")
        }
        if let dataFolder {
            print("=== cleanup WARNING: guest data folder remains: \(dataFolder)")
        }
        if let deployFolder {
            print("=== cleanup WARNING: guest deploy folder remains: \(deployFolder)")
        }
    }

    func testIncreasingReverseTransfersFidelityAndCancellation() async throws {
        let env = ProcessInfo.processInfo.environment
        let artifact = try XCTUnwrap(env["NOW_METAL_ARTIFACT"])
        let artifactURL = URL(fileURLWithPath: artifact)
        let artifactBytes = try Data(contentsOf: artifactURL)
        let run = env["NOW_METAL_RUN_ID"]
            ?? String(Int(Date().timeIntervalSince1970) % 1_000_000)
        let reuse = env["NOW_METAL_REUSE"] != nil
        let deploy = "NOW RS Deploy \(run)"
        let data = "NOW RS Data \(run)"
        deployFolder = deploy

        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("NOW Reverse Streaming \(run)")
        if reuse {
            try? FileManager.default.removeItem(at: local)
        }
        try FileManager.default.createDirectory(
            at: local, withIntermediateDirectories: false)
        hostFolder = local

        let isolated = GuestListener(
            identity: .init(version: "0.5-rs-metal", name: "RS Metal 5252"))
        self.isolated = isolated
        isolated.start(port: 5252)
        try await waitForListening(isolated, port: 5252)

        let bootstrap = GuestListener(
            identity: .init(version: "0.5-rs-bootstrap",
                            name: "RS Bootstrap 5250"))
        self.bootstrap = bootstrap
        bootstrap.start(port: 5250)
        let bootstrapName = try await waitForGuest(bootstrap, seconds: 90)
        let bootstrapRoot = try await root(of: bootstrap)
        print("=== bootstrap guest: \(bootstrapName), share \(bootstrapRoot)")

        if reuse {
            let retryDeadline = Date().addingTimeInterval(3)
            while Date() < retryDeadline {
                if case .connected = isolated.state { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        if case .connected = isolated.state, reuse {
            print("=== reusing the already-running disposable guest")
            if env["NOW_METAL_DEPLOY_ALREADY_TRASHED"] != nil {
                deployFolder = nil
            }
        } else {
            if let process = try await allProcesses(on: bootstrap)
                .first(where: { $0.name == appName }),
               let high = process.psnHigh, let low = process.psnLow {
                print("=== quitting stale disposable guest before redeploy")
                _ = try await driveQuit(
                    high: high, low: low, on: bootstrap)
                try await Task.sleep(nanoseconds: 1_500_000_000)
            }
            _ = try await makeFolder(deploy, with: bootstrap)
            try await put(
                name: appName, folder: deploy, container: "macbinary",
                bytes: artifactBytes, overwrite: false, with: bootstrap,
                timeout: 180)
            let launchPath = join(root: bootstrapRoot,
                                  components: [deploy, appName])
            let launch = try await command(
                "launch", args: ["target": launchPath], on: bootstrap,
                timeout: 30)
            XCTAssertTrue(
                launch.ok,
                "launch failed: \(String(describing: launch.error))")
            print("=== launched \(launchPath)")
        }

        let guestName = try await waitForGuest(isolated, seconds: 90)
        let isolatedRoot = try await root(of: isolated)
        print("=== isolated guest machine: \(guestName), share \(isolatedRoot)")

        let volumes = try await census("volumes", on: isolated)
        print("=== disk preflight: \(volumes.rows)")
        let freeMB = freeMegabytes(in: volumes)
        try XCTSkipUnless(
            freeMB >= 8,
            "boot volume reports only \(freeMB) MB free; no safe metal ladder")

        if reuse, let result = try? await trash(data, with: isolated) {
            print("=== preflight cleanup: old data folder -> Trash as "
                  + "\(result.trashedAs ?? "?")")
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        _ = try await makeFolder(data, with: isolated)
        dataFolder = data

        var sizes = [32 * 1024 - 1, 32 * 1024, 32 * 1024 + 1,
                     256 * 1024, 1024 * 1024]
        if freeMB >= 16 {
            sizes.append(4 * 1024 * 1024)
        } else {
            sizes.append(2 * 1024 * 1024)
        }

        let beforePartition = try await processPartition(on: isolated)
        print("=== guest process partition before: \(beforePartition) KB")
        var memoryRows: [(size: Int, rssBase: UInt64, rssPeak: UInt64,
                          heapBase: UInt64, heapPeak: UInt64)] = []
        var lastSize = 0

        for size in sizes {
            let expectedCRC = try await seedPattern(
                size: size, folder: data, name: "payload.bin",
                overwrite: lastSize != 0, on: isolated)
            lastSize = size

            let destination = local.appendingPathComponent(
                "payload-\(size).bin")
            let sample = try await pull(
                path: "\(data):payload.bin", to: destination, on: isolated)
            let actualCRC = try verifyPatternFile(destination, size: size)
            XCTAssertEqual(actualCRC, expectedCRC,
                           "independent CRC differs for \(size) bytes")
            XCTAssertEqual(sample.delivery.staged.byteCount, size)
            XCTAssertEqual(sample.delivery.container, "data")
            memoryRows.append((
                size, sample.baselineRSS, sample.peakRSS,
                sample.baselineHeap, sample.peakHeap))
            print(String(
                format: "=== reverse %8d B: %6.2fs, %.1f KB/s, "
                    + "RSS %.1f->%.1f MB (delta %.1f), "
                    + "live heap %.1f->%.1f MB (delta %.1f)",
                size, Double(sample.delivery.transferMs) / 1000.0,
                Double(size) / 1024.0
                    / max(Double(sample.delivery.transferMs) / 1000.0, 0.001),
                Double(sample.baselineRSS) / 1_048_576.0,
                Double(sample.peakRSS) / 1_048_576.0,
                Double(sample.peakRSS - sample.baselineRSS) / 1_048_576.0,
                Double(sample.baselineHeap) / 1_048_576.0,
                Double(sample.peakHeap) / 1_048_576.0,
                Double(sample.peakHeap - sample.baselineHeap) / 1_048_576.0))
            try FileManager.default.removeItem(at: destination)
            try assertNoParts(in: local)
            XCTAssertConnected(isolated, after: "the \(size)-byte pull")
        }

        let textBytes = try XCTUnwrap(
            "café\rline two\r".data(using: .macOSRoman))
        try await put(
            name: "classic.txt", folder: data, container: "data",
            bytes: textBytes, fileType: "TEXT", creator: "ttxt",
            overwrite: false, with: isolated)
        let textURL = local.appendingPathComponent("classic.txt")
        let textPull = try await pull(
            path: "\(data):classic.txt", to: textURL, on: isolated)
        XCTAssertEqual(
            try String(contentsOf: textURL, encoding: .utf8),
            "café\nline two\n")
        XCTAssertEqual(textPull.delivery.container, "data")
        print("=== classic text: MacRoman and CR converted to UTF-8 and LF")
        try FileManager.default.removeItem(at: textURL)

        let macBinary = makeMacBinary(
            name: "Classic Forks", dataBytes: 131_071, resourceBytes: 65_537)
        try await put(
            name: "Classic Forks", folder: data, container: "macbinary",
            bytes: macBinary, overwrite: false, with: isolated)
        let mbURL = local.appendingPathComponent("Classic Forks.bin")
        let mbPull = try await pull(
            path: "\(data):Classic Forks", container: "macbinary",
            to: mbURL, on: isolated)
        XCTAssertEqual(mbPull.delivery.container, "macbinary")
        try verifyMacBinary(mbURL, name: "Classic Forks",
                            dataBytes: 131_071, resourceBytes: 65_537)
        print("=== MacBinary: header CRC and both fork payloads verified")
        try FileManager.default.removeItem(at: mbURL)

        try await exerciseCancellation(
            path: "\(data):payload.bin", staging: local, on: isolated)
        try assertNoParts(in: local)
        XCTAssertConnected(isolated, after: "cancelled reverse pull")
        let postCancel = try await command("gestalt", on: isolated, timeout: 20)
        XCTAssertTrue(postCancel.ok, "guest did not answer after cancellation")
        print("=== cancellation: host partial removed; session answered gestalt")

        let afterPartition = try await processPartition(on: isolated)
        XCTAssertEqual(afterPartition, beforePartition)
        print("=== guest process partition after: \(afterPartition) KB")

        let liveDeltas = memoryRows.map { $0.heapPeak - $0.heapBase }
        let maxLiveDelta = liveDeltas.max() ?? 0
        XCTAssertLessThan(
            maxLiveDelta, 2 * 1024 * 1024,
            "reverse receive live heap rose beyond the bounded-frame allowance")
        let memoryReport = memoryRows.map { row -> String in
            let rss = Double(row.rssPeak - row.rssBase) / 1_048_576.0
            let heap = Double(row.heapPeak - row.heapBase) / 1_048_576.0
            return "\(row.size)=RSS \(String(format: "%.2f", rss))MB/"
                + "live \(String(format: "%.2f", heap))MB"
        }.joined(separator: ", ")
        print("=== host reverse memory deltas by size: \(memoryReport)")
    }

    private struct PullSample {
        var delivery: GuestListener.FileDelivery
        var baselineRSS: UInt64
        var peakRSS: UInt64
        var baselineHeap: UInt64
        var peakHeap: UInt64
    }

    private func pull(path: String, container: String? = nil,
                      to destination: URL,
                      on listener: GuestListener) async throws -> PullSample {
        var result: Result<GuestListener.FileDelivery,
                           GuestListener.FileFailure>?
        let baseline = residentBytes()
        let baselineHeap = liveHeapBytes()
        var peak = baseline
        var peakHeap = baselineHeap
        listener.getFile(
            path: path, container: container,
            stagingDirectory: destination.deletingLastPathComponent()) {
                result = $0
            }
        let deadline = Date().addingTimeInterval(300)
        while result == nil, Date() < deadline {
            peak = max(peak, residentBytes())
            peakHeap = max(peakHeap, liveHeapBytes())
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let delivery = try XCTUnwrap(result, "reverse pull timed out").get()
        peak = max(peak, residentBytes())
        peakHeap = max(peakHeap, liveHeapBytes())
        try FileConverter.materialize(
            name: delivery.name, container: delivery.container,
            fileType: delivery.fileType, staged: delivery.staged,
            to: destination)
        return PullSample(
            delivery: delivery, baselineRSS: baseline, peakRSS: peak,
            baselineHeap: baselineHeap, peakHeap: peakHeap)
    }

    private func exerciseCancellation(path: String, staging: URL,
                                      on listener: GuestListener) async throws {
        var result: Result<GuestListener.FileDelivery,
                           GuestListener.FileFailure>?
        var didCancel = false
        let watch = listener.$captureProgress.sink { progress in
            guard !didCancel, let progress, progress.received >= 64 * 1024,
                  progress.received < progress.expected else { return }
            didCancel = true
            /* A real cancel is a later UI event, not a reentrant call from
               inside Session.consume's progress callback. */
            Task { @MainActor in listener.cancelFile() }
        }
        defer { watch.cancel() }
        listener.getFile(path: path, stagingDirectory: staging) { result = $0 }
        let deadline = Date().addingTimeInterval(60)
        while result == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let failure = try XCTUnwrap(result, "cancel did not settle").failure
        XCTAssertTrue(didCancel, "transfer completed before cancellation point")
        XCTAssertEqual(failure?.code, "cancelled")
        try await Task.sleep(nanoseconds: 1_000_000_000)
    }

    private func seedPattern(size: Int, folder: String, name: String,
                             overwrite: Bool,
                             on listener: GuestListener) async throws -> UInt32 {
        var payload: Data? = pattern(size)
        let crc = TransferIdentity.crc32(try XCTUnwrap(payload))
        try await put(name: name, folder: folder, container: "data",
                      bytes: try XCTUnwrap(payload), overwrite: overwrite,
                      with: listener, timeout: 600)
        payload = nil
        try await Task.sleep(nanoseconds: 250_000_000)
        return crc
    }

    private func pattern(_ size: Int) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(size)
        for index in 0..<size {
            let mixed = (index &* 31) &+ (index / 251) &+ 7
            bytes.append(UInt8(mixed & 0xFF))
        }
        return Data(bytes)
    }

    private func verifyPatternFile(_ url: URL, size: Int) throws -> UInt32 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var offset = 0
        var crc = TransferIdentity.CRC32()
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            for (index, byte) in chunk.enumerated() {
                let absolute = offset + index
                let expected = UInt8(
                    ((absolute &* 31) &+ (absolute / 251) &+ 7) & 0xFF)
                if byte != expected {
                    XCTFail("content differs at byte \(absolute)")
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
            crc.update(chunk)
            offset += chunk.count
        }
        XCTAssertEqual(offset, size)
        return crc.checksum
    }

    private func makeMacBinary(name: String, dataBytes: Int,
                               resourceBytes: Int) -> Data {
        var header = [UInt8](repeating: 0, count: 128)
        let nameBytes = Array(name.data(using: .macOSRoman)!)
        header[1] = UInt8(nameBytes.count)
        for (index, byte) in nameBytes.enumerated() {
            header[index + 2] = byte
        }
        Array("APPL".utf8).enumerated().forEach { header[65 + $0] = $1 }
        Array("ttxt".utf8).enumerated().forEach { header[69 + $0] = $1 }
        put32(dataBytes, into: &header, at: 83)
        put32(resourceBytes, into: &header, at: 87)
        header[122] = 129
        header[123] = 129
        let crc = crc16(header[0..<124])
        header[124] = UInt8(crc >> 8)
        header[125] = UInt8(crc & 0xFF)
        return Data(header)
            + Data(repeating: 0x31, count: padded(dataBytes))
            + Data(repeating: 0x79, count: padded(resourceBytes))
    }

    private func verifyMacBinary(_ url: URL, name: String, dataBytes: Int,
                                 resourceBytes: Int) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = [UInt8](try handle.read(upToCount: 128) ?? Data())
        XCTAssertEqual(header.count, 128)
        XCTAssertEqual(
            String(data: Data(header[2..<(2 + Int(header[1]))]),
                   encoding: .macOSRoman), name)
        XCTAssertEqual(read32(header, at: 83), dataBytes)
        XCTAssertEqual(read32(header, at: 87), resourceBytes)
        XCTAssertEqual(
            crc16(header[0..<124]),
            UInt16(header[124]) << 8 | UInt16(header[125]))
        try verifyRepeated(handle, count: dataBytes, byte: 0x31)
        let dataPadding = padded(dataBytes) - dataBytes
        if dataPadding > 0 {
            try verifyRepeated(handle, count: dataPadding, byte: 0)
        }
        try verifyRepeated(handle, count: resourceBytes, byte: 0x79)
    }

    private func verifyRepeated(_ handle: FileHandle, count: Int,
                                byte: UInt8) throws {
        var remaining = count
        while remaining > 0 {
            let chunk = try handle.read(
                upToCount: min(remaining, 64 * 1024)) ?? Data()
            guard !chunk.isEmpty else {
                XCTFail("fork ended with \(remaining) bytes still expected")
                throw CocoaError(.fileReadCorruptFile)
            }
            XCTAssertTrue(chunk.allSatisfy { $0 == byte })
            remaining -= chunk.count
        }
    }

    private func put32(_ value: Int, into bytes: inout [UInt8], at index: Int) {
        bytes[index] = UInt8((value >> 24) & 0xFF)
        bytes[index + 1] = UInt8((value >> 16) & 0xFF)
        bytes[index + 2] = UInt8((value >> 8) & 0xFF)
        bytes[index + 3] = UInt8(value & 0xFF)
    }

    private func read32(_ bytes: [UInt8], at index: Int) -> Int {
        (Int(bytes[index]) << 24) | (Int(bytes[index + 1]) << 16)
            | (Int(bytes[index + 2]) << 8) | Int(bytes[index + 3])
    }

    private func padded(_ count: Int) -> Int { (count + 127) / 128 * 128 }

    private func crc16<C: Collection>(_ bytes: C) -> UInt16
        where C.Element == UInt8 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = crc & 0x8000 != 0
                    ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size
                / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_,
                              task_flavor_t(MACH_TASK_BASIC_INFO),
                              $0, &count)
                }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    private func liveHeapBytes() -> UInt64 {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return UInt64(statistics.size_in_use)
    }

    private func freeMegabytes(in report: CensusReport) -> Int {
        for row in report.rows where row.count >= 3 {
            let words = row[2].split(separator: " ")
            if let freeIndex = words.firstIndex(of: "free"),
               freeIndex >= 2, words[freeIndex - 1] == "MB",
               let value = Int(words[freeIndex - 2]) {
                return value
            }
        }
        return 0
    }

    private func processPartition(on listener: GuestListener) async throws
        -> Int {
        let rows = try await allProcesses(on: listener)
        return try XCTUnwrap(
            rows.first(where: { $0.name == appName })?.sizeKB,
            "experimental guest is absent from process.list")
    }

    private func allProcesses(on listener: GuestListener) async throws
        -> [ProcessEntry] {
        var rows: [ProcessEntry] = []
        var cursor: Int? = 1
        repeat {
            var result: Result<ProcessListing, GuestListener.FileFailure>?
            listener.listProcesses(cursor: cursor) { result = $0 }
            let deadline = Date().addingTimeInterval(30)
            while result == nil, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let page = try XCTUnwrap(result, "process.list timed out").get()
            rows += page.processes
            cursor = page.more ? page.cursor : nil
        } while cursor != nil
        return rows
    }

    private func waitForListening(_ listener: GuestListener,
                                  port: UInt16) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if listener.boundPort == port { return }
            if case .failed(let reason) = listener.state {
                XCTFail("listener \(port) failed: \(reason)")
                throw URLError(.cannotConnectToHost)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("listener \(port) did not bind")
    }

    private func waitForGuest(_ listener: GuestListener,
                              seconds: TimeInterval) async throws -> String {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if case .connected(let name) = listener.state {
                try await Task.sleep(nanoseconds: 500_000_000)
                return name
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw XCTSkip("no PowerBook guest dialled within \(Int(seconds))s")
    }

    private func root(of listener: GuestListener) async throws -> String {
        var result: Result<FileListing, GuestListener.FileFailure>?
        listener.listFiles(path: "") { result = $0 }
        let deadline = Date().addingTimeInterval(20)
        while result == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try XCTUnwrap(
            try XCTUnwrap(result, "file.list timed out").get().root,
            "guest did not name its share root")
    }

    private func makeFolder(_ path: String,
                            with listener: GuestListener) async throws
        -> FileResult {
        var result: Result<FileResult, GuestListener.FileFailure>?
        listener.makeFolder(path: path) { result = $0 }
        let deadline = Date().addingTimeInterval(30)
        while result == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try XCTUnwrap(result, "mkdir timed out").get()
    }

    private func trash(_ path: String,
                       with listener: GuestListener) async throws -> FileResult {
        var result: Result<FileResult, GuestListener.FileFailure>?
        listener.trashFile(path: path) { result = $0 }
        let deadline = Date().addingTimeInterval(30)
        while result == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try XCTUnwrap(result, "trash timed out").get()
    }

    private func put(name: String, folder: String, container: String,
                     bytes: Data, fileType: String? = nil,
                     creator: String? = nil, overwrite: Bool,
                     with listener: GuestListener,
                     timeout: TimeInterval = 300) async throws {
        var result: Result<Void, GuestListener.FileFailure>?
        listener.putFile(
            name: name, into: folder, container: container, bytes: bytes,
            fileType: fileType, creator: creator, overwrite: overwrite) {
                result = $0
            }
        let deadline = Date().addingTimeInterval(timeout)
        while result == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        _ = try XCTUnwrap(result, "put \(name) timed out").get()
    }

    private func command(_ name: String, args: [String: String]? = nil,
                         on listener: GuestListener,
                         timeout: TimeInterval) async throws -> CommandResult {
        var result: CommandResult?
        listener.runCommand(name, args: args) { result = $0 }
        let deadline = Date().addingTimeInterval(timeout)
        while result == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try XCTUnwrap(result, "\(name) timed out")
    }

    private func census(_ probe: String,
                        on listener: GuestListener) async throws
        -> CensusReport {
        var report: CensusReport?
        listener.requestCensus(probe: probe) { report = $0 }
        let deadline = Date().addingTimeInterval(30)
        while report == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try XCTUnwrap(report, "census \(probe) timed out")
    }

    private func driveQuit(high: Int, low: Int,
                           on listener: GuestListener) async throws
        -> ProcessResult {
        var result: Result<ProcessResult, GuestListener.FileFailure>?
        listener.driveProcess(
            psnHigh: high, psnLow: low, verb: .quit) { result = $0 }
        let deadline = Date().addingTimeInterval(20)
        while result == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try XCTUnwrap(result, "process.quit timed out").get()
    }

    private func join(root: String, components: [String]) -> String {
        (root.hasSuffix(":") ? root : root + ":")
            + components.joined(separator: ":")
    }

    private func assertNoParts(in folder: URL,
                               file: StaticString = #filePath,
                               line: UInt = #line) throws {
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".part")
                || $0.lastPathComponent.hasSuffix(".convert") }
        XCTAssertTrue(leftovers.isEmpty,
                      "temporary files remain: \(leftovers)",
                      file: file, line: line)
    }

    private func XCTAssertConnected(_ listener: GuestListener, after: String,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) {
        guard case .connected = listener.state else {
            return XCTFail("guest disconnected after \(after)",
                           file: file, line: line)
        }
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
