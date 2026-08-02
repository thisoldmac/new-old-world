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
        registry: HostProjectionRegistry = .hostFaces
    ) -> [ChatToolDescriptor] {
        registry.projections.compactMap { projection in
            let descriptor = projection.mcpDescriptor
            let schema = (descriptor["inputSchema"] as? [String: Any])
                ?? ["type": "object"]
            guard let schemaJSON = try? JSONSerialization.data(
                withJSONObject: schema) else { return nil }
            return ChatToolDescriptor(
                name: projection.capability.rawValue,
                description: descriptor["description"] as? String ?? "",
                inputSchemaJSON: schemaJSON)
        }
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
