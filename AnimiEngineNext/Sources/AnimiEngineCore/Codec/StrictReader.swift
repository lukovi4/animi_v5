/// A strict object reader that enforces "exactly the schema fields, no more" with path tracking
/// (Task-002 plan, §11.2 steps 2–3).
///
/// Each field access marks the key as consumed; after reading all expected fields the caller calls
/// ``finish()`` to reject any leftover (unknown) field. Numbers are parsed from their original
/// lexeme so non-integer text is rejected as a malformed integer.
struct StrictObjectReader {
    let path: String
    private let pairs: [(String, StrictJSONValue)]
    private var consumed = Set<String>()

    init(_ value: StrictJSONValue, path: String) throws {
        guard case .object(let pairs) = value else {
            throw ProjectDecodingError.wrongType(path: path, expected: "object")
        }
        self.path = path
        self.pairs = pairs
    }

    private func raw(_ key: String) -> StrictJSONValue? {
        pairs.first { $0.0 == key }?.1
    }

    private func childPath(_ key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }

    mutating func value(_ key: String) throws -> StrictJSONValue {
        consumed.insert(key)
        guard let value = raw(key) else {
            throw ProjectDecodingError.missingField(path: path, field: key)
        }
        return value
    }

    mutating func optionalValue(_ key: String) -> StrictJSONValue? {
        consumed.insert(key)
        guard let value = raw(key), value != .null else { return nil }
        return value
    }

    mutating func int(_ key: String) throws -> Int64 {
        let value = try value(key)
        guard case .number(let lexeme) = value else {
            throw ProjectDecodingError.wrongType(path: childPath(key), expected: "integer")
        }
        return try Self.parseInteger(lexeme, path: childPath(key))
    }

    mutating func intValue(_ key: String) throws -> Int {
        let raw = try int(key)
        guard let narrowed = Int(exactly: raw) else {
            throw ProjectDecodingError.malformedInteger(path: childPath(key))
        }
        return narrowed
    }

    mutating func string(_ key: String) throws -> String {
        let value = try value(key)
        guard case .string(let string) = value else {
            throw ProjectDecodingError.wrongType(path: childPath(key), expected: "string")
        }
        return string
    }

    mutating func bool(_ key: String) throws -> Bool {
        let value = try value(key)
        guard case .bool(let bool) = value else {
            throw ProjectDecodingError.wrongType(path: childPath(key), expected: "boolean")
        }
        return bool
    }

    mutating func object(_ key: String) throws -> StrictObjectReader {
        try StrictObjectReader(try value(key), path: childPath(key))
    }

    mutating func optionalObject(_ key: String) throws -> StrictObjectReader? {
        guard let value = optionalValue(key) else { return nil }
        return try StrictObjectReader(value, path: childPath(key))
    }

    /// Distinguishes ABSENT (returns nil) from explicit JSON `null` (throws). For fields whose absence
    /// has exactly ONE canonical representation — the key omitted (Slice 001: audio clip `videoLayer`).
    /// Unlike ``optionalObject``, an explicit `"key":null` is REJECTED, not treated as absent.
    mutating func optionalObjectRejectingNull(_ key: String) throws -> StrictObjectReader? {
        consumed.insert(key)
        guard let value = raw(key) else { return nil }              // absent → nil
        if value == .null {
            throw ProjectDecodingError.explicitNull(path: childPath(key))   // explicit null → reject
        }
        return try StrictObjectReader(value, path: childPath(key))
    }

    mutating func array(_ key: String) throws -> [StrictJSONValue] {
        let value = try value(key)
        guard case .array(let elements) = value else {
            throw ProjectDecodingError.wrongType(path: childPath(key), expected: "array")
        }
        return elements
    }

    /// Rejects any field present in the object but not consumed (unknown field, recursive).
    func finish() throws {
        for (key, _) in pairs where !consumed.contains(key) {
            throw ProjectDecodingError.unknownField(path: path, field: key)
        }
    }

    /// Parses a base-10 integer lexeme, rejecting fractions, exponents, leading zeros, and overflow.
    static func parseInteger(_ lexeme: String, path: String) throws -> Int64 {
        // Reject fraction/exponent markers explicitly.
        if lexeme.contains(".") || lexeme.lowercased().contains("e") {
            throw ProjectDecodingError.malformedInteger(path: path)
        }
        // Reject leading-zero / lone-sign / non-canonical forms.
        var body = Substring(lexeme)
        var negative = false
        if body.first == "-" { negative = true; body = body.dropFirst() }
        guard !body.isEmpty, body.allSatisfy({ $0.isNumber }) else {
            throw ProjectDecodingError.malformedInteger(path: path)
        }
        if body.count > 1 && body.first == "0" {
            throw ProjectDecodingError.malformedInteger(path: path)   // no leading zeros
        }
        if negative && body == "0" {
            throw ProjectDecodingError.malformedInteger(path: path)   // no "-0"
        }
        guard let value = Int64(lexeme) else {
            throw ProjectDecodingError.malformedInteger(path: path)   // out of Int64 range
        }
        return value
    }
}

/// Helpers for reading typed arrays of objects with element-indexed paths.
extension StrictJSONValue {
    func requireObject(path: String) throws -> StrictObjectReader {
        try StrictObjectReader(self, path: path)
    }

    func requireString(path: String) throws -> String {
        guard case .string(let s) = self else {
            throw ProjectDecodingError.wrongType(path: path, expected: "string")
        }
        return s
    }

    func requireInteger(path: String) throws -> Int64 {
        guard case .number(let lexeme) = self else {
            throw ProjectDecodingError.wrongType(path: path, expected: "integer")
        }
        return try StrictObjectReader.parseInteger(lexeme, path: path)
    }
}
