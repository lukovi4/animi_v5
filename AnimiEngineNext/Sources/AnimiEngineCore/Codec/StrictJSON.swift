/// A minimal, strict JSON value model and parser used by the canonical project codec
/// (Task-002 plan, §11.2).
///
/// This parser intentionally does **not** use `JSONSerialization`/`JSONDecoder`, because the
/// canonical contract requires rejecting duplicate object keys and preserving exact integer text —
/// behavior the stdlib parsers do not guarantee. Numbers are kept as their original lexeme so the
/// reader can enforce "integers only, no fraction/exponent".
indirect enum StrictJSONValue: Equatable {
    case object([(String, StrictJSONValue)])     // key order preserved; duplicates rejected by parser
    case array([StrictJSONValue])
    case string(String)
    case number(String)                          // original lexeme
    case bool(Bool)
    case null

    static func == (lhs: StrictJSONValue, rhs: StrictJSONValue) -> Bool {
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

/// A strict recursive-descent JSON parser over UTF-8 scalars. Rejects duplicate object keys.
struct StrictJSONParser {
    private let scalars: [Unicode.Scalar]
    private var index = 0

    init(_ text: String) {
        self.scalars = Array(text.unicodeScalars)
    }

    static func parse(_ data: [UInt8]) throws -> StrictJSONValue {
        var text = ""
        var decoder = UTF8()
        var iterator = data.makeIterator()
        decodeLoop: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar): text.unicodeScalars.append(scalar)
            case .emptyInput: break decodeLoop
            case .error:
                throw ProjectDecodingError.malformedJSON(reason: "not valid UTF-8")
            }
        }
        var parser = StrictJSONParser(text)
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.index == parser.scalars.count else {
            throw ProjectDecodingError.malformedJSON(reason: "trailing content after JSON value")
        }
        return value
    }

    private mutating func parseValue() throws -> StrictJSONValue {
        skipWhitespace()
        guard let c = peek() else {
            throw ProjectDecodingError.malformedJSON(reason: "unexpected end of input")
        }
        switch c {
        case "{": return try parseObject()
        case "[": return try parseArray()
        case "\"": return .string(try parseString())
        case "t", "f": return .bool(try parseBool())
        case "n": try parseNull(); return .null
        case "-", "0"..."9": return .number(try parseNumber())
        default:
            throw ProjectDecodingError.malformedJSON(reason: "unexpected character '\(c)'")
        }
    }

    private mutating func parseObject() throws -> StrictJSONValue {
        try expect("{")
        var pairs: [(String, StrictJSONValue)] = []
        var seenKeys = Set<String>()
        skipWhitespace()
        if peek() == "}" { advance(); return .object(pairs) }
        while true {
            skipWhitespace()
            guard peek() == "\"" else {
                throw ProjectDecodingError.malformedJSON(reason: "expected object key string")
            }
            let key = try parseString()
            guard seenKeys.insert(key).inserted else {
                throw ProjectDecodingError.duplicateKey(path: "<object>", key: key)
            }
            skipWhitespace()
            try expect(":")
            let value = try parseValue()
            pairs.append((key, value))
            skipWhitespace()
            guard let c = peek() else {
                throw ProjectDecodingError.malformedJSON(reason: "unterminated object")
            }
            if c == "," { advance(); continue }
            if c == "}" { advance(); break }
            throw ProjectDecodingError.malformedJSON(reason: "expected ',' or '}' in object")
        }
        return .object(pairs)
    }

    private mutating func parseArray() throws -> StrictJSONValue {
        try expect("[")
        var elements: [StrictJSONValue] = []
        skipWhitespace()
        if peek() == "]" { advance(); return .array(elements) }
        while true {
            let value = try parseValue()
            elements.append(value)
            skipWhitespace()
            guard let c = peek() else {
                throw ProjectDecodingError.malformedJSON(reason: "unterminated array")
            }
            if c == "," { advance(); continue }
            if c == "]" { advance(); break }
            throw ProjectDecodingError.malformedJSON(reason: "expected ',' or ']' in array")
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
                    throw ProjectDecodingError.malformedJSON(reason: "unterminated escape")
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
                case "u":
                    let scalar = try parseUnicodeEscape()
                    result.append(scalar)
                default:
                    throw ProjectDecodingError.malformedJSON(reason: "invalid escape '\\\(esc)'")
                }
            } else if c.value < 0x20 {
                throw ProjectDecodingError.malformedJSON(reason: "control character in string")
            } else {
                result.append(c)
            }
        }
        throw ProjectDecodingError.malformedJSON(reason: "unterminated string")
    }

    private mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
        func hex4() throws -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let c = peek(), let digit = c.hexDigitValue else {
                    throw ProjectDecodingError.malformedJSON(reason: "invalid \\u escape")
                }
                advance()
                value = value * 16 + UInt32(digit)
            }
            return value
        }
        let first = try hex4()
        if (0xD800...0xDBFF).contains(first) {
            // High surrogate; require a low surrogate.
            guard peek() == "\\" else {
                throw ProjectDecodingError.malformedJSON(reason: "unpaired surrogate")
            }
            advance()
            guard peek() == "u" else {
                throw ProjectDecodingError.malformedJSON(reason: "unpaired surrogate")
            }
            advance()
            let low = try hex4()
            guard (0xDC00...0xDFFF).contains(low) else {
                throw ProjectDecodingError.malformedJSON(reason: "invalid low surrogate")
            }
            let combined = 0x10000 + ((first - 0xD800) << 10) + (low - 0xDC00)
            guard let scalar = Unicode.Scalar(combined) else {
                throw ProjectDecodingError.malformedJSON(reason: "invalid surrogate pair")
            }
            return scalar
        }
        guard let scalar = Unicode.Scalar(first) else {
            throw ProjectDecodingError.malformedJSON(reason: "invalid \\u scalar")
        }
        return scalar
    }

    private mutating func parseNumber() throws -> String {
        let startIndex = index
        if peek() == "-" { advance() }
        while let c = peek(), ("0"..."9").contains(c) || c == "." || c == "e" || c == "E" || c == "+" || c == "-" {
            advance()
        }
        let lexeme = String(String.UnicodeScalarView(scalars[startIndex..<index]))
        guard !lexeme.isEmpty, lexeme != "-" else {
            throw ProjectDecodingError.malformedJSON(reason: "malformed number")
        }
        return lexeme
    }

    private mutating func parseBool() throws -> Bool {
        if matchKeyword("true") { return true }
        if matchKeyword("false") { return false }
        throw ProjectDecodingError.malformedJSON(reason: "malformed boolean")
    }

    private mutating func parseNull() throws {
        guard matchKeyword("null") else {
            throw ProjectDecodingError.malformedJSON(reason: "malformed null")
        }
    }

    // MARK: - Lexer helpers

    private func peek() -> Unicode.Scalar? {
        index < scalars.count ? scalars[index] : nil
    }

    private mutating func advance() {
        index += 1
    }

    private mutating func expect(_ scalar: Unicode.Scalar) throws {
        guard peek() == scalar else {
            throw ProjectDecodingError.malformedJSON(reason: "expected '\(scalar)'")
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
