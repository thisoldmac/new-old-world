import Foundation

public enum NOWOperationEffect: String, Sendable, CaseIterable {
    case read
    case boundedMutation
    case disruptiveMutation
    case bulkTransfer
}

public enum NOWOperationAddressing: String, Sendable, CaseIterable {
    case hostWide
    case stableOrSessionGuest
    case exactGuestSession
}

public enum NOWOperationFace: String, Sendable, CaseIterable {
    case http
    case cli
    case mcp
    case appUI
}

public enum NOWOperationExposure: Sendable, Equatable {
    case rendered(evidence: String)
    case planned(slice: String)
    case notRendered(reason: String)
}

public enum NOWOperationAdjudication: Sendable, Equatable {
    case publicOperation(operationID: String)
    case composition(operationIDs: [String], reason: String)
    case agentOnly(reason: String)
}

/// One checked catalog row joining a neutral operation descriptor to its
/// current implementation and the deliberate disposition of its MCP tool.
public struct NOWOperationCatalogEntry: @unchecked Sendable {
    public let capability: HostCapabilityID
    public let descriptor: NOWOperationDescriptor
    public let adjudication: NOWOperationAdjudication
    public let effect: NOWOperationEffect
    public let addressing: NOWOperationAddressing
    public let exposures: [NOWOperationFace: NOWOperationExposure]
}

/// The complete 49-row adjudication of the pre-API MCP registry.
///
/// No default exists. Adding a projection without deciding whether it is a
/// public operation, composition, or agent-only convenience fails the
/// catalog gate instead of silently enlarging the developer API.
public enum NOWOperationInventory {
    public static func entry(
        for projection: any HostProjection.Type
    ) -> NOWOperationCatalogEntry? {
        guard let adjudication = adjudications[projection.capability.rawValue]
        else { return nil }
        let descriptor = projection.operationDescriptor
        let effect: NOWOperationEffect
        if bulkTransferCapabilities.contains(projection.capability.rawValue) {
            effect = .bulkTransfer
        } else if descriptor.effectHints.destructive {
            effect = .disruptiveMutation
        } else if descriptor.effectHints.readOnly {
            effect = .read
        } else {
            effect = .boundedMutation
        }
        let addressing: NOWOperationAddressing =
            projection.acceptsGuestAddressing ? .stableOrSessionGuest : .hostWide
        var exposures: [NOWOperationFace: NOWOperationExposure] = [
            .mcp: .rendered(evidence: "NOWMCPToolRenderer registry loop"),
        ]
        switch adjudication {
        case .publicOperation:
            exposures[.http] = .planned(slice: "S2-S6")
            exposures[.cli] = .planned(slice: "S3-S6")
        case .composition(_, let reason), .agentOnly(let reason):
            exposures[.http] = .notRendered(reason: reason)
            exposures[.cli] = .notRendered(reason: reason)
        }
        if let reach = projection.faces[.appUI] {
            switch reach {
            case .reached(let file, let symbol):
                exposures[.appUI] = .rendered(
                    evidence: "\(file):\(symbol)")
            case .reachedByRegistry:
                exposures[.appUI] = .rendered(evidence: "registry loop")
            case .notReached(let reason):
                exposures[.appUI] = .notRendered(reason: reason)
            }
        } else {
            exposures[.appUI] = .notRendered(
                reason: "The projection declares no app UI reach.")
        }
        return .init(
            capability: projection.capability,
            descriptor: descriptor,
            adjudication: adjudication,
            effect: effect,
            addressing: addressing,
            exposures: exposures)
    }

    /// Public operations whose domain seam is the host API itself rather than
    /// a pre-existing MCP projection. They still belong to the same checked
    /// contract; this set prevents an HTTP route from becoming an unchecked
    /// second catalog merely because it has no agent tool analogue.
    public static let apiNativeOperationIDs: Set<String> = [
        "api.identity", "commands.execute", "connections.disconnect",
        "connections.list", "guests.status", "listener.start",
        "events.watch",
        "listener.status", "listener.stop", "operations.list",
        "transfers.commit", "transfers.content", "transfers.get",
        "transfers.list", "transfers.uploadChunk",
    ]

    public static let publicOperationIDs: Set<String> = Set(
        adjudications.values.flatMap { adjudication -> [String] in
            switch adjudication {
            case .publicOperation(let operationID): return [operationID]
            case .composition(let operationIDs, _): return operationIDs
            case .agentOnly: return []
            }
        }).union(apiNativeOperationIDs)

    private static let workspaceReason =
        "This tool resolves chat-workspace authority; applications supply "
        + "bytes or transfer handles to the public files.put operation."
    private static let chunkReason =
        "MCP chunk staging composes the public files.put operation and is "
        + "not the public binary transfer protocol."
    private static let hostAgentReason =
        "This is host chat or development-agent orchestration, not a guest "
        + "or host administration contract for third-party applications."

    private static let adjudications: [String: NOWOperationAdjudication] = [
        "now_projects": .agentOnly(reason: hostAgentReason),
        "now_chats": .agentOnly(reason: hostAgentReason),
        "now_development_environment": .agentOnly(reason: hostAgentReason),
        "now_development": .agentOnly(reason: hostAgentReason),
        "now_list_machines": .publicOperation(operationID: "guests.list"),
        "now_session_capabilities": .publicOperation(operationID: "guests.capabilities"),
        "now_hardware_census": .publicOperation(operationID: "guests.census"),
        "now_machine_facts": .publicOperation(operationID: "guests.facts"),
        "now_list_processes": .publicOperation(operationID: "processes.list"),
        "now_observe_elements": .publicOperation(operationID: "interface.observe"),
        "now_semantic_ui_start": .publicOperation(operationID: "mirror.start"),
        "now_semantic_ui_status": .publicOperation(operationID: "mirror.status"),
        "now_semantic_ui_snapshot": .publicOperation(operationID: "mirror.snapshot"),
        "now_semantic_ui_find": .publicOperation(operationID: "mirror.find"),
        "now_semantic_ui_wait": .publicOperation(operationID: "mirror.wait"),
        "now_semantic_ui_metrics": .publicOperation(operationID: "mirror.metrics"),
        "now_semantic_ui_lifecycle": .publicOperation(operationID: "mirror.lifecycle"),
        "now_semantic_ui_journal": .publicOperation(operationID: "mirror.journal"),
        "now_semantic_ui_wait_for_settlement": .publicOperation(operationID: "mirror.waitForSettlement"),
        "now_semantic_ui_act": .publicOperation(operationID: "mirror.act"),
        "now_guest_log_tail": .publicOperation(operationID: "logs.guest.tail"),
        "now_host_log_tail": .publicOperation(operationID: "logs.host.tail"),
        "now_capture_screen": .publicOperation(operationID: "screen.capture"),
        "now_stream_screen": .publicOperation(operationID: "screen.stream"),
        "now_catalog_search": .publicOperation(operationID: "catalog.search"),
        "now_framebuffer_probe": .publicOperation(operationID: "diagnostics.framebuffer"),
        "now_capture_diagnostics": .publicOperation(operationID: "diagnostics.capture"),
        "now_transfer_diagnostics": .publicOperation(operationID: "diagnostics.transfer"),
        "now_software_inventory": .publicOperation(operationID: "software.list"),
        "now_launch_software": .publicOperation(operationID: "software.launch"),
        "now_reveal_item": .publicOperation(operationID: "files.reveal"),
        "now_bring_to_front": .publicOperation(operationID: "processes.activate"),
        "now_request_quit": .publicOperation(operationID: "processes.quit"),
        "now_window_act": .publicOperation(operationID: "interface.window.act"),
        "now_control_act": .publicOperation(operationID: "interface.control.act"),
        "now_menu_act": .publicOperation(operationID: "interface.menu.act"),
        "now_text_get": .publicOperation(operationID: "interface.text.get"),
        "now_text_set": .publicOperation(operationID: "interface.text.set"),
        "now_transfer_approved_artifact": .agentOnly(reason: workspaceReason),
        "now_transfer_cancel": .publicOperation(operationID: "transfers.cancel"),
        "now_guest_files_capabilities": .publicOperation(operationID: "files.capabilities"),
        "now_guest_files_list": .publicOperation(operationID: "files.list"),
        "now_guest_files_stat": .publicOperation(operationID: "files.stat"),
        "now_guest_files_download": .publicOperation(operationID: "files.get"),
        "now_guest_files_mutate": .publicOperation(operationID: "files.mutate"),
        "now_guest_files_upload_begin": .composition(operationIDs: ["files.put"], reason: chunkReason),
        "now_guest_files_upload_append": .composition(operationIDs: ["files.put"], reason: chunkReason),
        "now_guest_files_upload_commit": .composition(operationIDs: ["files.put"], reason: chunkReason),
        "now_guest_files_upload_file": .agentOnly(reason: workspaceReason),
    ]

    private static let bulkTransferCapabilities: Set<String> = [
        "now_transfer_approved_artifact", "now_guest_files_download",
        "now_guest_files_upload_begin", "now_guest_files_upload_append",
        "now_guest_files_upload_commit", "now_guest_files_upload_file",
    ]
}
