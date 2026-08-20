import Foundation

/// Transport-neutral presentation and schema data for one NOW operation.
///
/// Projection rows own this value. Protocol adapters render it; they do not
/// get to add product meaning. `ExpressibleByDictionaryLiteral` is a bounded
/// migration bridge for the existing 49 reviewed schema bodies: it accepts
/// only the five neutral presentation fields and the four effect hints that
/// have typed homes below. Unknown top-level fields fail loudly.
public struct NOWOperationDescriptor: @unchecked Sendable,
    ExpressibleByDictionaryLiteral {
    public struct EffectHints: Sendable, Equatable {
        public let readOnly: Bool
        public let destructive: Bool
        public let idempotent: Bool
        public let openWorld: Bool
    }

    public enum DescriptorError: Error, CustomStringConvertible {
        case missing(String)
        case wrongType(String)
        case unknownField(String)

        public var description: String {
            switch self {
            case .missing(let field):
                return "NOW operation descriptor is missing \(field)."
            case .wrongType(let field):
                return "NOW operation descriptor has the wrong type for \(field)."
            case .unknownField(let field):
                return "NOW operation descriptor contains unknown field \(field)."
            }
        }
    }

    public let title: String
    public let summary: String
    public let inputSchema: [String: Any]
    public let outputSchema: [String: Any]?
    public let effectHints: EffectHints
    public let stability: String?

    public init(
        title: String,
        summary: String,
        inputSchema: [String: Any],
        outputSchema: [String: Any]?,
        effectHints: EffectHints,
        stability: String? = nil
    ) {
        self.title = title
        self.summary = summary
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.effectHints = effectHints
        self.stability = stability
    }

    public init(dictionaryLiteral elements: (String, Any)...) {
        do {
            self = try Self.validating(Dictionary(uniqueKeysWithValues: elements))
        } catch {
            preconditionFailure(String(describing: error))
        }
    }

    /// Compatibility view for tests and non-MCP host presentation code that
    /// still inspect the rendered tool. Projection rows never own this shape.
    public var mcpToolDescriptor: [String: Any] {
        NOWMCPToolRenderer.baseTool(descriptor: self)
    }

    /// Used by shared descriptor helpers while their nested JSON Schemas
    /// remain ordinary dictionaries.
    public static func validating(_ fields: [String: Any]) throws -> Self {
        let allowed: Set<String> = [
            "title", "description", "inputSchema", "outputSchema",
            "annotations", "x-now-stability",
        ]
        if let unknown = Set(fields.keys).subtracting(allowed).sorted().first {
            throw DescriptorError.unknownField(unknown)
        }
        guard let title = fields["title"] as? String else {
            throw DescriptorError.missing("title")
        }
        guard let summary = fields["description"] as? String else {
            throw DescriptorError.missing("description")
        }
        guard let input = fields["inputSchema"] as? [String: Any] else {
            throw DescriptorError.missing("inputSchema")
        }
        let output: [String: Any]?
        if let raw = fields["outputSchema"] {
            guard let typed = raw as? [String: Any] else {
                throw DescriptorError.wrongType("outputSchema")
            }
            output = typed
        } else {
            output = nil
        }
        guard let annotations = fields["annotations"] as? [String: Any]
        else { throw DescriptorError.missing("annotations") }
        func hint(_ name: String) throws -> Bool {
            guard let value = annotations[name] as? Bool else {
                throw DescriptorError.missing("annotations.\(name)")
            }
            return value
        }
        guard Set(annotations.keys) == Set([
            "readOnlyHint", "destructiveHint", "idempotentHint",
            "openWorldHint",
        ]) else {
            throw DescriptorError.wrongType("annotations")
        }
        let stability: String?
        if let raw = fields["x-now-stability"] {
            guard let typed = raw as? String else {
                throw DescriptorError.wrongType("x-now-stability")
            }
            stability = typed
        } else {
            stability = nil
        }
        return try Self(
            title: title,
            summary: summary,
            inputSchema: input,
            outputSchema: output,
            effectHints: .init(
                readOnly: hint("readOnlyHint"),
                destructive: hint("destructiveHint"),
                idempotent: hint("idempotentHint"),
                openWorld: hint("openWorldHint")),
            stability: stability)
    }
}
