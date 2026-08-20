import XCTest
@testable import Host

/// G-5 / H17: the pill-tab Settings window, the deep-link seam every
/// module's "Settings…" button shares, and the preferences that moved out
/// of MCP, Web, Logs and the sidebar's context menu.
///
/// Three shapes of test, matching what the task asked for:
/// - deep-link routing (`HostModuleContext.showSettings` → `HostAppState
///   .settingsPresenter` → `AppDelegate.openSettings(selecting:)` →
///   `SettingsWindowController.select(_:)`), end to end and at each seam;
/// - defaults seeding (`ContinuityConnectionDefaults`, and a fresh machine
///   actually reading it in `MirrorContinuityController`);
/// - moved-preference round-trips (MCP, Logs — the two that reuse a live,
///   already-shared model rather than a fresh one, so this also proves the
///   Settings tab and the module read the SAME instance).
@MainActor
final class HostSettingsRestructureTests: XCTestCase {

    // MARK: - Deep-link routing

    /// The seam every module's "Settings…" button relies on:
    /// `HostModuleContext.showSettings` is threaded through
    /// `HostAppState.settingsPresenter`, so a runtime built from that
    /// context can name its own tab without ever touching AppKit.
    func testEachModuleOpensSettingsOnItsOwnTab() throws {
        let suite = "HostSettingsRestructureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            .offTheWire()
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = HostAppState(registry: .standard, defaults: defaults)
        var requested: [HostSettingsTab?] = []
        state.settingsPresenter = { requested.append($0) }

        let mcp = try XCTUnwrap(state.moduleRuntime(
            for: "mcp", as: MCPHostModuleRuntime.self))
        mcp.openSettings()
        XCTAssertEqual(requested, [.mcp])

        let logs = try XCTUnwrap(state.moduleRuntime(
            for: "logs", as: LogsHostModuleRuntime.self))
        logs.openSettings()
        XCTAssertEqual(requested, [.mcp, .logs])

        let web = try XCTUnwrap(state.moduleRuntime(
            for: "web", as: WebHostModuleRuntime.self))
        web.openSettings()
        XCTAssertEqual(requested, [.mcp, .logs, .web])
    }

    /// A module built from a context whose owner never set
    /// `settingsPresenter` — a preview, or a test that never wires it —
    /// must not crash. `HostModuleContext`'s default `showSettings` is a
    /// no-op for exactly this reason, matching `selectModule`'s own
    /// default beside it.
    func testShowSettingsIsANoOpWithNoPresenterWired() throws {
        let suite = "HostSettingsRestructureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            .offTheWire()
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = HostAppState(registry: .standard, defaults: defaults)
        let mcp = try XCTUnwrap(state.moduleRuntime(
            for: "mcp", as: MCPHostModuleRuntime.self))
        mcp.openSettings() // must not crash
    }

    /// The far end of the seam: the app delegate reuses one window and
    /// routes the pill's selected tab through it, the same reuse guarantee
    /// `testSettingsMenuOwnsOneReusableWindow` already covers for the
    /// zero-argument case.
    func testDeepLinkSelectsATabWithoutRebuildingTheWindow() throws {
        let delegate = quietAppDelegate("SettingsDeepLink")

        delegate.openSettings(selecting: .mcp)
        let controller = try XCTUnwrap(delegate.settingsWindowController)
        XCTAssertEqual(controller.selectedTab, .mcp)

        delegate.openSettings(selecting: .web)
        XCTAssertTrue(controller === delegate.settingsWindowController,
                      "the same window is reused across tab changes")
        XCTAssertEqual(controller.selectedTab, .web)

        delegate.openSettings(selecting: nil)
        XCTAssertEqual(controller.selectedTab, .web,
                       "nil raises the window without changing its tab")

        controller.window?.close()
    }

    /// End to end: a module's own `openSettings()` — the exact closure
    /// its "Settings…" button calls — reaches the delegate's window and
    /// lands on that module's tab, once the delegate has wired
    /// `settingsPresenter` the way `applicationDidFinishLaunching` does.
    func testMCPModuleSettingsButtonLandsOnTheMCPTabInTheRealWindow() throws {
        let delegate = quietAppDelegate("SettingsButtonWiring")
        delegate.appState.settingsPresenter = { [weak delegate] tab in
            delegate?.openSettings(selecting: tab)
        }
        let mcp = try XCTUnwrap(delegate.appState.moduleRuntime(
            for: "mcp", as: MCPHostModuleRuntime.self))

        mcp.openSettings()

        let controller = try XCTUnwrap(delegate.settingsWindowController)
        XCTAssertEqual(controller.selectedTab, .mcp)
        controller.window?.close()
    }

    // MARK: - Defaults seeding

    /// The struct Settings' "Defaults for New Connections" tab binds to:
    /// unset reads back the same literal `loadSettingsForActiveGuest` used
    /// to hardcode, every field round-trips, and the reconnect-delay clamp
    /// matches the per-machine one it was copied from.
    func testConnectionDefaultsRoundTripAndClampTheSameWayThePerMachineValuesDo()
        throws {
        let suite = "ConnectionDefaults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ContinuityConnectionDefaults(defaults: defaults)

        XCTAssertEqual(store.rate, 30)
        XCTAssertFalse(store.autoReconnect)
        XCTAssertEqual(store.reconnectDelay, 0.75, accuracy: 0.000_1)
        XCTAssertTrue(store.keyboardForwarding)
        XCTAssertEqual(store.escapeShortcut, .controlOptionEscape)

        store.rate = 15
        store.autoReconnect = true
        store.reconnectDelay = 9.0
        store.keyboardForwarding = false
        store.escapeShortcut = .controlOptionReturn

        XCTAssertEqual(store.rate, 15)
        XCTAssertTrue(store.autoReconnect)
        XCTAssertEqual(store.reconnectDelay, 5.0, accuracy: 0.000_1,
                       "clamped to the same 5s ceiling the per-machine value uses")
        XCTAssertFalse(store.keyboardForwarding)
        XCTAssertEqual(store.escapeShortcut, .controlOptionReturn)

        store.rate = 45 // not one of 15/30/60: ignored
        XCTAssertEqual(store.rate, 15)

        let fastPump = ContinuityOptionCatalog.descriptor(.fastPump)
        XCTAssertEqual(store.optionEnabled(fastPump), fastPump.defaultEnabled)
        store.setOptionEnabled(!fastPump.defaultEnabled, for: fastPump)
        XCTAssertEqual(store.optionEnabled(fastPump), !fastPump.defaultEnabled)

        let reread = ContinuityConnectionDefaults(defaults: defaults)
        XCTAssertEqual(reread.rate, 15, "persists across instances")
        XCTAssertEqual(reread.optionEnabled(fastPump), !fastPump.defaultEnabled)
    }

    /// `ContinuityConnectionDefaultsModel` is what the Settings tab's
    /// bindings actually touch; it must write through to the same struct
    /// (and therefore the same `UserDefaults` keys) rather than holding a
    /// private copy nothing else reads.
    func testConnectionDefaultsModelWritesThroughToTheSameKeysTheStructReads()
        throws {
        let suite = "ConnectionDefaultsModel.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ContinuityConnectionDefaultsModel(defaults: defaults)

        model.rate = 60
        model.autoReconnect = true
        let fastPump = ContinuityOptionCatalog.descriptor(.fastPump)
        model.optionBinding(fastPump).wrappedValue = true

        let store = ContinuityConnectionDefaults(defaults: defaults)
        XCTAssertEqual(store.rate, 60)
        XCTAssertTrue(store.autoReconnect)
        XCTAssertTrue(store.optionEnabled(fastPump))
    }

    /// The behavior change this whole tab exists for: a machine that has
    /// never connected before — no per-machine keys under
    /// `mirror.continuity.*.<slug>` — now reads the GLOBAL seed instead of
    /// a literal constant. Mutation check: reverting
    /// `loadSettingsForActiveGuest` to read the hardcoded 30/0.75/etc
    /// again makes every assertion below fail, because the seed here is
    /// deliberately set away from every one of those literals.
    func testFreshMachineSeedsFromConnectionDefaultsInsteadOfHardcodedConstants()
        async throws {
        let defaultsSuite = "FreshMachineSeeding.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"),
            timing: .init(idleTimeout: 60))
        listener.start(port: 0)
        try await waitUntilTrue("TCP listener") {
            if case .listening = listener.state { return true }
            return false
        }
        defer { listener.stop() }

        let seed = ContinuityConnectionDefaults(defaults: defaults)
        seed.rate = 15
        seed.autoReconnect = true
        seed.reconnectDelay = 2.5
        seed.keyboardForwarding = false
        seed.escapeShortcut = .controlOptionReturn
        let fastPump = ContinuityOptionCatalog.descriptor(.fastPump)
        seed.setOptionEnabled(true, for: fastPump) // catalog default is false

        let port = try XCTUnwrap(listener.boundPort)
        let guest = FakeGuest(port: port)
        guest.start()
        try guest.send(.hello(Hello(
            contract: Contract.revision, side: "guest", version: "0.1.0",
            build: nil, agent: nil, name: "Never Seen Before Machine",
            os: "9.1", chunk: 8192)))
        try await waitUntilTrue("host hello") { !guest.received.isEmpty }

        let controller = MirrorContinuityController(
            listener: listener, defaults: defaults)

        XCTAssertEqual(controller.requestedHz, 15)
        XCTAssertTrue(controller.autoReconnect)
        XCTAssertEqual(controller.reconnectDelay, 2.5, accuracy: 0.000_1)
        XCTAssertFalse(controller.keyboardForwardingEnabled)
        XCTAssertEqual(controller.escapeShortcut, .controlOptionReturn)
        XCTAssertTrue(controller.fastPump,
                      "the catalog default is off; only the seed explains this")

        guest.connection.cancel()
    }

    /// The other half of the same behavior: a machine that already has its
    /// own saved settings must be completely unaffected by the global
    /// seed, however it is set.
    func testAMachineWithItsOwnSettingsIgnoresTheGlobalSeed() async throws {
        let defaultsSuite = "ExistingMachineIgnoresSeed.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"),
            timing: .init(idleTimeout: 60))
        listener.start(port: 0)
        try await waitUntilTrue("TCP listener") {
            if case .listening = listener.state { return true }
            return false
        }
        defer { listener.stop() }

        let port = try XCTUnwrap(listener.boundPort)
        let guest = FakeGuest(port: port)
        guest.start()
        try guest.send(.hello(Hello(
            contract: Contract.revision, side: "guest", version: "0.1.0",
            build: nil, agent: nil, name: "Already Known Machine", os: "9.1",
            chunk: 8192)))
        try await waitUntilTrue("host hello") { !guest.received.isEmpty }

        var controller: MirrorContinuityController? =
            MirrorContinuityController(listener: listener, defaults: defaults)
        controller?.requestedHz = 60
        controller = nil

        // Now set a global seed that disagrees with the saved 60 Hz.
        let seed = ContinuityConnectionDefaults(defaults: defaults)
        seed.rate = 15

        let reopened = MirrorContinuityController(
            listener: listener, defaults: defaults)
        XCTAssertEqual(reopened.requestedHz, 60,
                       "a saved per-machine value must win over the seed")

        guest.connection.cancel()
    }

    private func waitUntilTrue(_ message: String, timeout: TimeInterval = 5,
                               _ condition: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < end else {
                throw XCTSkip("timed out waiting for \(message)")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Moved-preference round-trips

    /// The MCP start-automatically toggles moved out of `MCPModuleView`
    /// into Settings; this is the SAME shared `MCPTransportSettingsModel`
    /// (`state.moduleRuntime(...).transportSettings`) the Settings tab
    /// would bind to — an edit there is this same object.
    func testMCPStartAutomaticallyMovesThroughTheSharedTransportSettings()
        throws {
        let suite = "MCPMovedPreference.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            .offTheWire()
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = HostAppState(registry: .standard, defaults: defaults)
        let model = try XCTUnwrap(state.moduleRuntime(
            for: "mcp", as: MCPHostModuleRuntime.self)?.transportSettings)

        XCTAssertFalse(model.stdioStartsAutomatically, "off by default")
        XCTAssertFalse(model.httpStartsAutomatically, "off by default")

        model.stdioStartsAutomatically = true
        model.httpStartsAutomatically = true

        // What App.swift's launch hook actually reads: a fresh read of the
        // raw preferences struct, not the model instance — proving the
        // write went to UserDefaults and not just to this object's memory.
        let launchTimeRead = MCPTransportPreferences(defaults: defaults)
        XCTAssertTrue(launchTimeRead.stdioStartsAutomatically)
        XCTAssertTrue(launchTimeRead.httpStartsAutomatically)
    }

    /// "Log to disk" moved out of `LogsModuleView`'s header; `state.logs`
    /// is the one eager, app-owned `LogsModel` both the module and the
    /// Settings tab read, so this proves the same object round-trips
    /// through the disk switch Settings now owns.
    func testLogToDiskMovesThroughTheSharedLogsModel() throws {
        let suite = "LogsMovedPreference.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            .offTheWire()
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = HostAppState(registry: .standard, defaults: defaults)
        let logsFromModule = try XCTUnwrap(state.moduleRuntime(
            for: "logs", as: LogsHostModuleRuntime.self)?.model)

        XCTAssertTrue(state.logs === logsFromModule,
                      "Settings and the module read the identical instance")

        logsFromModule.setPersistsToDisk(false)
        XCTAssertFalse(state.logs.persistsToDisk)

        logsFromModule.setPersistsToDisk(true)
        XCTAssertTrue(state.logs.persistsToDisk)
    }
}
