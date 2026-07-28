enum AgentIntegrationBoundedText {
    static func prefix(_ value: String, scalars: Int) -> String {
        String(value.unicodeScalars.prefix(scalars))
    }

    static func fourCC(_ value: String?) -> String? {
        value.map { prefix($0, scalars: 4) }
    }
}
