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
    static func descriptors(
        registry: HostProjectionRegistry = .hostFaces,
        include: (String) -> Bool = { _ in true }
    ) -> [ChatToolDescriptor] {
        registry.projections.compactMap { projection in
            guard include(projection.capability.rawValue) else { return nil }
            let descriptor = projection.mcpDescriptor
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
