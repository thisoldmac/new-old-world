import Foundation

struct CKProjectDocument: Equatable, Sendable {
    let version: Int
    let id: ProjectID
    let name: String
    let records: [(key: String, value: String)]

    static func == (lhs: CKProjectDocument, rhs: CKProjectDocument) -> Bool {
        lhs.version == rhs.version && lhs.id == rhs.id && lhs.name == rhs.name
            && lhs.records.elementsEqual(rhs.records, by: { $0 == $1 })
    }

    static func parse(_ data: Data) throws -> CKProjectDocument {
        guard data.count <= 131_072,
              let text = String(data: data, encoding: .utf8) else {
            throw ProjectStoreError.invalidProject("Project.ckp must be UTF-8 and at most 128 KiB.")
        }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard lines.first == "CKPROJECT 1" else {
            throw ProjectStoreError.invalidProject("The header must be CKPROJECT 1.")
        }
        var records: [(String, String)] = []
        for line in lines.dropFirst() where !line.isEmpty {
            guard let equals = line.firstIndex(of: "="), equals != line.startIndex else {
                throw ProjectStoreError.invalidProject("A record is not key=value.")
            }
            let key = String(line[..<equals])
            let value = String(line[line.index(after: equals)...])
            guard !value.contains("\0") else {
                throw ProjectStoreError.invalidProject("A value contains NUL.")
            }
            records.append((key, value))
        }
        func one(_ key: String) throws -> String {
            let values = records.filter { $0.0 == key }.map(\.1)
            guard values.count == 1, let value = values.first, !value.isEmpty else {
                throw ProjectStoreError.invalidProject("Exactly one \(key) record is required.")
            }
            return value
        }
        guard let id = ProjectID(rawValue: try one("id")) else {
            throw ProjectStoreError.invalidProject("The id is not 32 lower-case hexadecimal characters.")
        }
        let name = try one("name")
        guard name.unicodeScalars.count <= 64 else {
            throw ProjectStoreError.invalidProject("The name is longer than 64 characters.")
        }
        for required in ["target", "configuration", "toolchain", "product", "file"] {
            guard records.contains(where: { $0.0 == required && !$0.1.isEmpty }) else {
                throw ProjectStoreError.invalidProject("At least one \(required) record is required.")
            }
        }
        for (key, value) in records where ["product", "file", "entry", "include"].contains(key) {
            try ProjectPath.validate(value)
        }
        for (_, value) in records where value.count > 4096 {
            throw ProjectStoreError.invalidProject("A record exceeds 4096 characters.")
        }
        return CKProjectDocument(version: 1, id: id, name: name, records: records)
    }

    func replacingID(_ newID: ProjectID) -> Data {
        var lines = ["CKPROJECT 1"]
        lines += records.map { key, value in
            "\(key)=\(key == "id" ? newID.rawValue : value)"
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}

enum ProjectPath {
    static func validate(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasSuffix("/"),
              !path.contains("\\"), !path.contains("\0") else {
            throw ProjectStoreError.invalidPath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ProjectStoreError.invalidPath(path)
        }
    }

    static func checkedURL(_ path: String, under root: URL,
                           fileManager: FileManager = .default) throws -> URL {
        try validate(path)
        var cursor = root
        for component in path.split(separator: "/") {
            cursor.appendPathComponent(String(component), isDirectory: false)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: cursor.path, isDirectory: &isDirectory) {
                let values = try cursor.resourceValues(forKeys: [.isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    throw ProjectStoreError.linkEscape(path)
                }
            }
        }
        let standardizedRoot = root.standardizedFileURL.path + "/"
        guard cursor.standardizedFileURL.path.hasPrefix(standardizedRoot) else {
            throw ProjectStoreError.invalidPath(path)
        }
        return cursor
    }
}
