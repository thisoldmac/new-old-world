import SwiftUI
import XCTest
@testable import Host

@MainActor
final class HostModuleRuntimeTests: XCTestCase {
    private enum ConstructionError: Error {
        case expected
    }

    private final class RecordingRuntime: HostModuleRuntime {
        var focused: [GuestConnectionState] = []
        var departed: [GuestKey] = []
        var shutdownCount = 0

        func focus(on connection: GuestConnectionState) {
            focused.append(connection)
        }

        func guestLeft(_ key: GuestKey) {
            departed.append(key)
        }

        func shutDown() {
            shutdownCount += 1
        }
    }

    private func listener() -> GuestListener {
        GuestListener(identity: .init(version: "test", name: "Test Host"))
    }

    private func definition(
        id: String = "test-module",
        featureID: ProductFeatureID? = nil,
        factory: @escaping HostModuleDefinition.RuntimeFactory
    ) -> HostModuleDefinition {
        HostModuleDefinition(
            descriptor: ModuleDescriptor(
                id: id,
                title: "Test",
                symbol: "testtube.2",
                summary: "Test module",
                featureID: featureID),
            makeRuntime: factory,
            makeView: { _, _ in AnyView(EmptyView()) })
    }

    private func store(
        definition: HostModuleDefinition,
        connection: @escaping () -> GuestConnectionState = { .disconnected }
    ) -> HostModuleRuntimeStore {
        let listener = listener()
        return HostModuleRuntimeStore(
            registry: ModuleRegistry(definitions: [definition]),
            context: HostModuleContext(
                listener: listener,
                currentConnection: connection))
    }

    func testRuntimeIsLazyAndReceivesCurrentFocusAfterConstruction() {
        let runtime = RecordingRuntime()
        var constructions = 0
        let selected = GuestConnectionState.connected(named: "PowerBook 1400")
        let store = store(definition: definition { _ in
            constructions += 1
            return runtime
        }, connection: { selected })

        XCTAssertFalse(store.isConstructed("test-module"))
        XCTAssertEqual(constructions, 0)

        XCTAssertEqual(store.resolution(for: "test-module"), .available)
        XCTAssertTrue(store.isConstructed("test-module"))
        XCTAssertEqual(constructions, 1)
        XCTAssertEqual(runtime.focused, [selected])

        XCTAssertEqual(store.resolution(for: "test-module"), .available)
        XCTAssertEqual(constructions, 1, "selection must reuse the one runtime")
    }

    func testThrowingFactoryRollsBackAndMayBeRetried() {
        let runtime = RecordingRuntime()
        var attempts = 0
        let store = store(definition: definition { _ in
            attempts += 1
            if attempts == 1 { throw ConstructionError.expected }
            return runtime
        })

        guard case .constructionFailed = store.resolution(for: "test-module") else {
            return XCTFail("the first construction should fail")
        }
        XCTAssertFalse(store.isConstructed("test-module"))

        XCTAssertEqual(store.resolution(for: "test-module"), .available)
        XCTAssertTrue(store.isConstructed("test-module"))
        XCTAssertEqual(attempts, 2)
    }

    func testPolicyDenialDoesNotConstructRuntime() {
        var constructions = 0
        let store = store(definition: definition(
            featureID: .classicPreCarbon
        ) { _ in
            constructions += 1
            return RecordingRuntime()
        })

        guard case .disabled(let reason) = store.resolution(for: "test-module") else {
            return XCTFail("classic.pre-carbon is excluded from this profile")
        }
        XCTAssertTrue(reason.contains("Excluded"))
        XCTAssertEqual(constructions, 0)
        XCTAssertFalse(store.isConstructed("test-module"))
    }

    func testOnlyConstructedRuntimesReceiveFocusAndDeparture() {
        let runtime = RecordingRuntime()
        let store = store(definition: definition { _ in runtime })
        let first = GuestConnectionState.connected(named: "Quadra 950")
        let second = GuestConnectionState.connected(named: "PowerBook 1400")
        let departed = second.key!

        store.focus(on: first)
        store.guestLeft(departed)
        XCTAssertTrue(runtime.focused.isEmpty)
        XCTAssertTrue(runtime.departed.isEmpty)

        XCTAssertEqual(store.resolution(for: "test-module"), .available)
        store.focus(on: second)
        store.guestLeft(departed)
        XCTAssertEqual(runtime.focused, [.disconnected, second])
        XCTAssertEqual(runtime.departed, [departed])
    }

    func testShutdownIsExactlyOnceAndPreventsReconstruction() {
        let runtime = RecordingRuntime()
        var constructions = 0
        let store = store(definition: definition { _ in
            constructions += 1
            return runtime
        })
        XCTAssertEqual(store.resolution(for: "test-module"), .available)

        store.shutDown()
        store.shutDown()

        XCTAssertEqual(runtime.shutdownCount, 1)
        XCTAssertFalse(store.isConstructed("test-module"))
        guard case .constructionFailed(let reason) =
                store.resolution(for: "test-module") else {
            return XCTFail("a shut-down store must not reconstruct modules")
        }
        XCTAssertTrue(reason.contains("already shut down"))
        XCTAssertEqual(constructions, 1)
    }
}
