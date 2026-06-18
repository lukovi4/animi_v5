/// Adapter-owned strict JSON value model, parser and object reader for the compiled `.tve`
/// schema-2 payload (Task-003 plan §5.2, §14.3).
///
/// This is **not** a re-export of `AnimiEngineCore`'s internal `StrictJSONParser`: that type is
/// `internal` to Core and the adapter owns its own schema (§14.3 lists
/// `CompiledTemplateStrictJSON.swift` here). The compiled schema additionally needs to distinguish
/// JSON **integers** from **floating** numbers at the leaf level (§5.4: "distinguish Bool, integer
/// and floating JSON numbers correctly"), because compiled geometry mixes both (frame counts and
/// ids are integers; coordinates, tangents and colors are reals). The number lexeme is therefore
/// retained verbatim and classified on demand.
///
/// All failures are `CompiledTemplateDecodingError`. There is no fallback, coercion or repair.

import Foundation

/// A strict JSON value. Object key order is preserved and duplicate keys are rejected by the parser.
/// Numbers keep their original lexeme so the reader can enforce integer-vs-float discipline and
/// reject fractions/exponents/leading-zeros where an integer is required.
indirect enum CompiledJSONValue: Equatable, Sendable {
    case object([(String, CompiledJSONValue)])   // key order preserved; duplicates rejected by parser
    case array([CompiledJSONValue])
    case string(String)
    case number(String)                          // original lexeme, e.g. "150", "-960", "314.915"
    case bool(Bool)
    case null

    static func == (lhs: CompiledJSONValue, rhs: CompiledJSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.object(let a), .object(let b)):
            guard a.count == b.count else { return false }
            for (x, y) in zip(a, b) where x.0 != y.0 || x.1 != y.1 { return false }
            return true
        case (.array(let a), .array(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.bool(let a), .bool(let b)): return a == b
        case (.null, .null): return true
        default: return false
        }
    }
}

/// A strict recursive-descent JSON parser over Unicode scalars. Rejects duplicate object keys,
/// control characters in strings, and any trailing content after the root value.
struct CompiledJSONParser {
    private let scalars: [Unicode.Scalar]
    private var index = 0

    private init(_ text: String) {
        self.scalars = Array(text.unicodeScalars)
    }

    /// Parses raw payload bytes into a single root value. The byte stream must be exactly one JSON
    /// document — leading/trailing whitespace is allowed; trailing non-whitespace is rejected
    /// (length-ambiguity defence, §5.2).
    static func parse(_ data: Data) throws -> CompiledJSONValue {
        var text = ""
        text.reserveCapacity(data.count)
        var decoder = UTF8()
        var iterator = data.makeIterator()
        decodeLoop: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar): text.unicodeScalars.append(scalar)
            case .emptyInput: break decodeLoop
            case .error:
                throw CompiledTemplateDecodingError.payloadNotUTF8
            }
        }
        var parser = CompiledJSONParser(text)
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.index == parser.scalars.count else {
            throw CompiledTemplateDecodingError.trailingPayloadContent
        }
        return value
    }

    private mutating func parseValue() throws -> CompiledJSONValue {
        skipWhitespace()
        guard let c = peek() else {
            throw CompiledTemplateDecodingError.malformedJSON(reason: "unexpected end of input")
        }
        switch c {
        case "{": return try parseObject()
        case "[": return try parseArray()
        case "\"": return .string(try parseString())
        case "t", "f": return .bool(try parseBool())
        case "n": try parseNull(); return .null
        case "-", "0"..."9": return .number(try parseNumber())
        default:
            throw CompiledTemplateDecodingError.malformedJSON(reason: "unexpected character '\(c)'")
        }
    }

    private mutating func parseObject() throws -> CompiledJSONValue {
        try expect("{")
        var pairs: [(String, CompiledJSONValue)] = []
        var seenKeys = Set<String>()
        skipWhitespace()
        if peek() == "}" { advance(); return .object(pairs) }
        while true {
            skipWhitespace()
            guard peek() == "\"" else {
                throw CompiledTemplateDecodingError.malformedJSON(reason: "expected object key string")
            }
            let key = try parseString()
            guard seenKeys.insert(key).inserted else {
                throw CompiledTemplateDecodingError.duplicateKey(key: key)
            }
            skipWhitespace()
            try expect(":")
            let value = try parseValue()
            pairs.append((key, value))
            skipWhitespace()
            guard let c = peek() else {
                throw CompiledTemplateDecodingError.malformedJSON(reason: "unterminated object")
            }
            if c == "," { advance(); continue }
            if c == "}" { advance(); break }
            throw CompiledTemplateDecodingError.malformedJSON(reason: "expected ',' or '}' in object")
        }
        return .object(pairs)
    }

    private mutating func parseArray() throws -> CompiledJSONValue {
        try expect("[")
        var elements: [CompiledJSONValue] = []
        skipWhitespace()
        if peek() == "]" { advance(); return .array(elements) }
        while true {
            let value = try parseValue()
            elements.append(value)
            skipWhitespace()
            guard let c = peek() else {
                throw CompiledTemplateDecodingError.malformedJSON(reason: "unterminated array")
            }
            if c == "," { advance(); continue }
            if c == "]" { advance(); break }
            throw CompiledTemplateDecodingError.malformedJSON(reason: "expected ',' or ']' in array")
        }
        return .array(elements)
    }

    private mutating func parseString() throws -> String {
        try expect("\"")
        var result = String.UnicodeScalarView()
        while let c = peek() {
            advance()
            if c == "\"" {
                return String(result)
            } else if c == "\\" {
                guard let esc = peek() else {
                    throw CompiledTemplateDecodingError.malformedJSON(reason: "unterminated escape")
                }
                advance()
                switch esc {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "/": result.append("/")
                case "b": result.append("\u{08}")
                case "f": result.append("\u{0C}")
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "u": result.append(try parseUnicodeEscape())
                default:
                    throw CompiledTemplateDecodingError.malformedJSON(reason: "invalid escape '\\\(esc)'")
                }
            } else if c.value < 0x20 {
                throw CompiledTemplateDecodingError.malformedJSON(reason: "control character in string")
            } else {
                result.append(c)
            }
        }
        throw CompiledTemplateDecodingError.malformedJSON(reason: "unterminated string")
    }

    private mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
        func hex4() throws -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let c = peek(), let digit = c.hexDigitValue else {
                    throw CompiledTemplateDecodingError.malformedJSON(reason: "invalid \\u escape")
                }
                advance()
                value = value * 16 + UInt32(digit)
            }
            return value
        }
        let first = try hex4()
        if (0xD800...0xDBFF).contains(first) {
            guard peek() == "\\" else {
                throw CompiledTemplateDecodingError.malformedJSON(reason: "unpaired surrogate")
            }
            advance()
            guard peek() == "u" else {
                throw CompiledTemplateDecodingError.malformedJSON(reason: "unpaired surrogate")
            }
            advance()
            let low = try hex4()
            guard (0xDC00...0xDFFF).contains(low) else {
                throw CompiledTemplateDecodingError.malformedJSON(reason: "invalid low surrogate")
            }
            let combined = 0x10000 + ((first - 0xD800) << 10) + (low - 0xDC00)
            guard let scalar = Unicode.Scalar(combined) else {
                throw CompiledTemplateDecodingError.malformedJSON(reason: "invalid surrogate pair")
            }
            return scalar
        }
        guard let scalar = Unicode.Scalar(first) else {
            throw CompiledTemplateDecodingError.malformedJSON(reason: "invalid \\u scalar")
        }
        return scalar
    }

    /// Lexes a JSON number token enforcing the exact RFC 8259 grammar:
    ///
    /// ```text
    ///   -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
    /// ```
    ///
    /// Malformed tokens are rejected here, during parsing, regardless of the eventual destination
    /// field. This bans leading zeros (`01`), bare/leading decimal points (`1.`, `-.1`), leading `+`
    /// (`+1`), a sign with no digits, incomplete exponents (`1e`, `1e+`), and a `.`/`e` after the
    /// exponent — so token concatenation such as `1.e2` or `1..2` cannot survive lexing.
    private mutating func parseNumber() throws -> String {
        let startIndex = index

        func fail() -> Error {
            let lexeme = String(String.UnicodeScalarView(scalars[startIndex..<index]))
            return CompiledTemplateDecodingError.malformedJSON(reason: "malformed number '\(lexeme)'")
        }
        func isDigit(_ c: Unicode.Scalar) -> Bool { ("0"..."9").contains(c) }

        // optional minus
        if peek() == "-" { advance() }

        // integer part: 0 | [1-9][0-9]*
        guard let first = peek(), isDigit(first) else { throw fail() }
        if first == "0" {
            advance()
            // A leading zero must not be followed by another digit (no "00", "01").
            if let c = peek(), isDigit(c) { throw fail() }
        } else {
            while let c = peek(), isDigit(c) { advance() }
        }

        // optional fraction: \.[0-9]+
        if peek() == "." {
            advance()
            guard let c = peek(), isDigit(c) else { throw fail() }   // at least one digit after '.'
            while let d = peek(), isDigit(d) { advance() }
        }

        // optional exponent: [eE][+-]?[0-9]+
        if let c = peek(), c == "e" || c == "E" {
            advance()
            if let s = peek(), s == "+" || s == "-" { advance() }
            guard let d = peek(), isDigit(d) else { throw fail() }   // at least one exponent digit
            while let d = peek(), isDigit(d) { advance() }
        }

        // No trailing numeric continuation (a second '.', 'e', or sign is token concatenation).
        if let c = peek(), c == "." || c == "e" || c == "E" || c == "+" {
            throw fail()
        }

        return String(String.UnicodeScalarView(scalars[startIndex..<index]))
    }

    private mutating func parseBool() throws -> Bool {
        if matchKeyword("true") { return true }
        if matchKeyword("false") { return false }
        throw CompiledTemplateDecodingError.malformedJSON(reason: "malformed boolean")
    }

    private mutating func parseNull() throws {
        guard matchKeyword("null") else {
            throw CompiledTemplateDecodingError.malformedJSON(reason: "malformed null")
        }
    }

    // MARK: - Lexer helpers

    private func peek() -> Unicode.Scalar? {
        index < scalars.count ? scalars[index] : nil
    }

    private mutating func advance() { index += 1 }

    private mutating func expect(_ scalar: Unicode.Scalar) throws {
        guard peek() == scalar else {
            throw CompiledTemplateDecodingError.malformedJSON(reason: "expected '\(scalar)'")
        }
        advance()
    }

    private mutating func matchKeyword(_ keyword: String) -> Bool {
        let kw = Array(keyword.unicodeScalars)
        guard index + kw.count <= scalars.count else { return false }
        for (offset, expected) in kw.enumerated() where scalars[index + offset] != expected {
            return false
        }
        index += kw.count
        return true
    }

    private mutating func skipWhitespace() {
        while let c = peek(), c == " " || c == "\t" || c == "\n" || c == "\r" {
            advance()
        }
    }
}

// MARK: - Number classification

extension CompiledJSONValue {
    /// Parses a base-10 integer lexeme, rejecting fractions, exponents, leading zeros, lone signs,
    /// `-0`, and `Int64` overflow. Mirrors the canonical-codec rule (Task-002 §11.2) so integer
    /// fields are byte-for-byte canonical.
    static func parseStrictInteger(_ lexeme: String, path: String) throws -> Int64 {
        if lexeme.contains(".") || lexeme.lowercased().contains("e") {
            throw CompiledTemplateDecodingError.malformedInteger(path: path)
        }
        var body = Substring(lexeme)
        var negative = false
        if body.first == "-" { negative = true; body = body.dropFirst() }
        guard !body.isEmpty, body.allSatisfy({ $0.isNumber }) else {
            throw CompiledTemplateDecodingError.malformedInteger(path: path)
        }
        if body.count > 1 && body.first == "0" {
            throw CompiledTemplateDecodingError.malformedInteger(path: path)   // no leading zeros
        }
        if negative && body == "0" {
            throw CompiledTemplateDecodingError.malformedInteger(path: path)   // no "-0"
        }
        guard let value = Int64(lexeme) else {
            throw CompiledTemplateDecodingError.malformedInteger(path: path)   // out of Int64 range
        }
        return value
    }

    /// Parses a numeric lexeme as a finite `Double`, rejecting NaN/infinity (the JSON grammar cannot
    /// produce them, but `strtod`-style parses must still be guarded) and any non-finite result.
    /// Used for the render-only real leaves the adapter retains verbatim (it does **not** convert
    /// them to render units here — that is §17 step 6+).
    static func parseStrictDouble(_ lexeme: String, path: String) throws -> Double {
        guard let value = Double(lexeme), value.isFinite else {
            throw CompiledTemplateDecodingError.malformedNumber(path: path)
        }
        return value
    }
}

// MARK: - Strict object reader

/// Reads an object's fields, marking each consumed key. After reading every expected field the
/// caller invokes ``finish()`` to reject any leftover (unknown) field — recursively, because every
/// nested object is read through its own reader.
struct CompiledObjectReader {
    let path: String
    private let pairs: [(String, CompiledJSONValue)]
    private var consumed = Set<String>()

    init(_ value: CompiledJSONValue, path: String) throws {
        guard case .object(let pairs) = value else {
            throw CompiledTemplateDecodingError.wrongType(path: path, expected: "object")
        }
        self.path = path
        self.pairs = pairs
    }

    private func raw(_ key: String) -> CompiledJSONValue? {
        pairs.first { $0.0 == key }?.1
    }

    func childPath(_ key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }

    /// Reads a **required, non-nullable** field. Absent → `missingField`; explicit `null` →
    /// `explicitNull` (no field in the owned schema is documented nullable, so a literal `null` is
    /// always malformed, never treated as absent — item 5 of the Stage-4 correction).
    mutating func value(_ key: String) throws -> CompiledJSONValue {
        consumed.insert(key)
        guard let value = raw(key) else {
            throw CompiledTemplateDecodingError.missingField(path: path, field: key)
        }
        if value == .null {
            throw CompiledTemplateDecodingError.explicitNull(path: childPath(key))
        }
        return value
    }

    /// Reads an **optional (may be absent)** field. Absent → `nil`. A present `null` is rejected
    /// (`explicitNull`): the producer omits absent optionals via `encodeIfPresent`, so a literal
    /// `null` is never a valid encoding of "absent" and must fail closed.
    mutating func optionalValue(_ key: String) throws -> CompiledJSONValue? {
        consumed.insert(key)
        guard let value = raw(key) else { return nil }
        if value == .null {
            throw CompiledTemplateDecodingError.explicitNull(path: childPath(key))
        }
        return value
    }

    /// True iff `key` is present with a literal `null`. Used only for nullable-array elements
    /// (e.g. `keyframeEasing: [KeyframeEasing?]`) that are read element-by-element, never for
    /// object fields.
    func isExplicitNull(_ value: CompiledJSONValue) -> Bool { value == .null }

    mutating func int(_ key: String) throws -> Int64 {
        let v = try value(key)
        guard case .number(let lexeme) = v else {
            throw CompiledTemplateDecodingError.wrongType(path: childPath(key), expected: "integer")
        }
        return try CompiledJSONValue.parseStrictInteger(lexeme, path: childPath(key))
    }

    /// Reads an integer narrowed to `Int`; out-of-range is a malformed integer.
    mutating func intValue(_ key: String) throws -> Int {
        let raw = try int(key)
        guard let narrowed = Int(exactly: raw) else {
            throw CompiledTemplateDecodingError.malformedInteger(path: childPath(key))
        }
        return narrowed
    }

    /// Reads any JSON number as a finite `Double` (integer or floating lexeme both accepted).
    mutating func double(_ key: String) throws -> Double {
        let v = try value(key)
        guard case .number(let lexeme) = v else {
            throw CompiledTemplateDecodingError.wrongType(path: childPath(key), expected: "number")
        }
        return try CompiledJSONValue.parseStrictDouble(lexeme, path: childPath(key))
    }

    mutating func string(_ key: String) throws -> String {
        let v = try value(key)
        guard case .string(let s) = v else {
            throw CompiledTemplateDecodingError.wrongType(path: childPath(key), expected: "string")
        }
        return s
    }

    mutating func bool(_ key: String) throws -> Bool {
        let v = try value(key)
        guard case .bool(let b) = v else {
            throw CompiledTemplateDecodingError.wrongType(path: childPath(key), expected: "boolean")
        }
        return b
    }

    mutating func object(_ key: String) throws -> CompiledObjectReader {
        try CompiledObjectReader(try value(key), path: childPath(key))
    }

    mutating func optionalObject(_ key: String) throws -> CompiledObjectReader? {
        guard let v = try optionalValue(key) else { return nil }
        return try CompiledObjectReader(v, path: childPath(key))
    }

    mutating func array(_ key: String) throws -> [CompiledJSONValue] {
        let v = try value(key)
        guard case .array(let elements) = v else {
            throw CompiledTemplateDecodingError.wrongType(path: childPath(key), expected: "array")
        }
        return elements
    }

    // MARK: Optional typed readers (field may be absent; explicit null rejected)

    mutating func optionalInt(_ key: String) throws -> Int? {
        guard let v = try optionalValue(key) else { return nil }
        guard case .number(let lexeme) = v else {
            throw CompiledTemplateDecodingError.wrongType(path: childPath(key), expected: "integer")
        }
        let raw = try CompiledJSONValue.parseStrictInteger(lexeme, path: childPath(key))
        guard let narrowed = Int(exactly: raw) else {
            throw CompiledTemplateDecodingError.malformedInteger(path: childPath(key))
        }
        return narrowed
    }

    mutating func optionalDouble(_ key: String) throws -> Double? {
        guard let v = try optionalValue(key) else { return nil }
        guard case .number(let lexeme) = v else {
            throw CompiledTemplateDecodingError.wrongType(path: childPath(key), expected: "number")
        }
        return try CompiledJSONValue.parseStrictDouble(lexeme, path: childPath(key))
    }

    mutating func optionalString(_ key: String) throws -> String? {
        guard let v = try optionalValue(key) else { return nil }
        guard case .string(let s) = v else {
            throw CompiledTemplateDecodingError.wrongType(path: childPath(key), expected: "string")
        }
        return s
    }

    mutating func optionalBool(_ key: String) throws -> Bool? {
        guard let v = try optionalValue(key) else { return nil }
        guard case .bool(let b) = v else {
            throw CompiledTemplateDecodingError.wrongType(path: childPath(key), expected: "boolean")
        }
        return b
    }

    mutating func optionalArray(_ key: String) throws -> [CompiledJSONValue]? {
        guard let v = try optionalValue(key) else { return nil }
        guard case .array(let elements) = v else {
            throw CompiledTemplateDecodingError.wrongType(path: childPath(key), expected: "array")
        }
        return elements
    }

    /// Reads a required closed-enum string field. Unknown tags throw `unknownEnumTag`.
    mutating func enumValue<E: RawRepresentable>(_ key: String, _ type: E.Type) throws -> E
    where E.RawValue == String {
        let tag = try string(key)
        guard let value = E(rawValue: tag) else {
            throw CompiledTemplateDecodingError.unknownEnumTag(path: childPath(key), tag: tag)
        }
        return value
    }

    /// Reads an optional closed-enum string field (absent → nil, explicit null rejected,
    /// unknown tag → `unknownEnumTag`).
    mutating func optionalEnum<E: RawRepresentable>(_ key: String, _ type: E.Type) throws -> E?
    where E.RawValue == String {
        guard let tag = try optionalString(key) else { return nil }
        guard let value = E(rawValue: tag) else {
            throw CompiledTemplateDecodingError.unknownEnumTag(path: childPath(key), tag: tag)
        }
        return value
    }

    /// Reads a required closed-enum integer field. Unknown codes throw `unknownEnumCode`.
    mutating func enumIntValue<E: RawRepresentable>(_ key: String, _ type: E.Type) throws -> E
    where E.RawValue == Int {
        let code = try intValue(key)
        guard let value = E(rawValue: code) else {
            throw CompiledTemplateDecodingError.unknownEnumCode(path: childPath(key), code: code)
        }
        return value
    }

    /// The object's key/value pairs in source order (for free-form maps such as `comps` or
    /// `mergedAssetIndex.byId` whose keys are data, not a fixed schema). Marking the whole object
    /// consumed is the caller's responsibility via ``markAllConsumed()``.
    var entries: [(String, CompiledJSONValue)] { pairs }

    /// Marks every key consumed — used for free-form maps read through ``entries`` so ``finish()``
    /// does not then reject the data keys as "unknown".
    mutating func markAllConsumed() {
        for (key, _) in pairs { consumed.insert(key) }
    }

    /// Rejects any present-but-unconsumed field (unknown field). Recursive by construction.
    func finish() throws {
        for (key, _) in pairs where !consumed.contains(key) {
            throw CompiledTemplateDecodingError.unknownField(path: path, field: key)
        }
    }
}

extension CompiledJSONValue {
    func requireObject(path: String) throws -> CompiledObjectReader {
        try CompiledObjectReader(self, path: path)
    }

    func requireString(path: String) throws -> String {
        guard case .string(let s) = self else {
            throw CompiledTemplateDecodingError.wrongType(path: path, expected: "string")
        }
        return s
    }

    func requireInteger(path: String) throws -> Int64 {
        guard case .number(let lexeme) = self else {
            throw CompiledTemplateDecodingError.wrongType(path: path, expected: "integer")
        }
        return try CompiledJSONValue.parseStrictInteger(lexeme, path: path)
    }

    func requireDouble(path: String) throws -> Double {
        guard case .number(let lexeme) = self else {
            throw CompiledTemplateDecodingError.wrongType(path: path, expected: "number")
        }
        return try CompiledJSONValue.parseStrictDouble(lexeme, path: path)
    }
}

private extension Unicode.Scalar {
    var hexDigitValue: Int? {
        switch self {
        case "0"..."9": return Int(value - 0x30)
        case "a"..."f": return Int(value - 0x61 + 10)
        case "A"..."F": return Int(value - 0x41 + 10)
        default: return nil
        }
    }
}
