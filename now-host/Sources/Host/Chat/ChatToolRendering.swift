import Foundation
import NOWAgentIntegration

/* The registry rendered for a model, and outcomes rendered back. Both
   halves mirror the MCP face (NOWMCPServer.tools / toolResponse) with
   one deliberate divergence: NO `guest` parameter is injected into any
   schema. The chat face pins addressing per conversation — a guest's
   chat drives that guest's own session and the host pane drives the
   driven machine — so which Mac a call is about is never the model's
   to choose. */

enum ChatToolRendering {
    /// One descriptor per registry row, in registry order.
    ///
    /// `mode` is the gate: a turn that may not act is handed only the
    /// rows that declare themselves read-only. The declaration comes
    /// from each projection's OWN `readOnlyHint` — the one every face
    /// already publishes — rather than from a list kept here, because a
    /// second table of what is safe is a second place to be wrong and
    /// the first row added without a line in it would be silently
    /// writable.
    static func descriptors(
        registry: HostProjectionRegistry = .hostFaces,
        mode: ChatMode = .build,
        include: (String) -> Bool = { _ in true }
    ) -> [ChatToolDescriptor] {
        registry.projections.compactMap { projection in
            guard include(projection.capability.rawValue) else { return nil }
            guard mode.mayAct || isReadOnly(projection) else { return nil }
            let descriptor = projection.operationDescriptor.mcpToolDescriptor
            let schema = apiSafeSchema(
                (descriptor["inputSchema"] as? [String: Any])
                    ?? ["type": "object"])
            guard let schemaJSON = try? JSONSerialization.data(
                withJSONObject: schema) else { return nil }
            return ChatToolDescriptor(
                name: projection.capability.rawValue,
                description: descriptor["description"] as? String ?? "",
                inputSchemaJSON: schemaJSON)
        }
    }

    /// A row's own claim about itself. ABSENT reads as "not read-only":
    /// a row that forgot to say must not be handed to a turn that may
    /// not act, because the safe reading of silence is the restrictive
    /// one — the same rule the mode field itself follows on the wire.
    static func isReadOnly(_ projection: any HostProjection.Type) -> Bool {
        isReadOnly(descriptor: projection.operationDescriptor.mcpToolDescriptor)
    }

    /// The reading, over a descriptor rather than a type, so the rule
    /// about SILENCE can be tested. Every row in the registry declares
    /// the hint today, which means a permissive default would sit there
    /// looking correct until the first row that forgot — and that row
    /// would be handed to a turn that may not act, once, quietly.
    static func isReadOnly(descriptor: [String: Any]) -> Bool {
        let annotations = descriptor["annotations"] as? [String: Any]
        return annotations?["readOnlyHint"] as? Bool == true
    }

    /// What a provider's tool validator accepts. MCP tolerates a
    /// top-level oneOf/anyOf/allOf/not; the Anthropic API rejects them
    /// (metal, 2026-08-02: now_launch_software's exactly-one-of rule
    /// 400ed every turn). The combinators are dropped from the SCHEMA
    /// only - the projection's own validation still enforces the rule,
    /// and a model that sends a wrong combination reads the refusal.
    static func apiSafeSchema(_ schema: [String: Any]) -> [String: Any] {
        var out = schema
        var dropped = false
        for combinator in ["oneOf", "anyOf", "allOf", "not"] {
            if out.removeValue(forKey: combinator) != nil {
                dropped = true
            }
        }
        if dropped {
            let note = "Argument combinations are checked by the tool "
                + "itself; a refusal names what was wrong."
            if let existing = out["description"] as? String, !existing.isEmpty {
                out["description"] = existing + " " + note
            } else {
                out["description"] = note
            }
        }
        if out["type"] == nil {
            out["type"] = "object"
        }
        return out
    }

    /// One tool result, in harness vocabulary. A refusal or a consent
    /// denial is an isError result the model reads and relays — an
    /// answer, never an exception that ends the chat.
    static func toolResult(
        id: String, outcome: HostProjectionOutcome?
    ) -> ChatContent {
        switch outcome {
        case .value(let value):
            var text = "{}"
            if let structured = try? structuredText(value) {
                text = structured
            }
            var image: Data?
            if case .image(let bytes, let mimeType)? = value.attachment,
                mimeType == "image/png" {
                image = bytes
            }
            return .toolResult(id: id, text: text, imagePNG: image, isError: false)
        case .invalidArguments(let message):
            return .toolResult(
                id: id, text: message, imagePNG: nil, isError: true)
        case .deniedByConsent(let denial):
            return .toolResult(
                id: id, text: denial.message, imagePNG: nil, isError: true)
        case nil:
            return .toolResult(
                id: id, text: "Unknown tool", imagePNG: nil, isError: true)
        }
    }

    private static func structuredText(
        _ value: HostProjectionValue
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try JSONSerialization.jsonObject(
            with: value.encoded(using: encoder))
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
