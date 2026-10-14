// OWNER: IOS-08
//
// A small strict UTF-8 JSON reader and a canonical writer for the RenderPlan wire format
// (ARCH §11.1 rule 4). Plans arrive as UTF-8 JSON bytes and are decoded off the main thread.
//
// Why not Foundation's JSONSerialization / JSONDecoder: the contract corpus must re-encode byte for
// byte (packages/danaview_editor_core/test/fixtures/render_plans/contract/README.md), which needs
//   - integers and doubles kept apart (`1` vs `1.5`, integral doubles accepted where ints are),
//   - doubles parsed with correct rounding (`Double(String)`; NSJSONSerialization may hand back
//     NSDecimalNumber for long literals),
//   - error paths identical to the Dart codec (`PlanFormatError.path`),
//   - Dart's number formatting on the way out (`PlanJSONWriter.formatDouble`).
// Unknown keys are ignored by the decoders that read these values.

import Foundation

/// A malformed plan, patch or transient (`planInvalid` natively). [path] is the JSON location in
/// the Dart codec's notation (`layers[3].map[0]`).
struct PlanFormatError: Error, Equatable, CustomStringConvertible {
    let message: String
    let path: String

    init(_ message: String, _ path: String = "") {
        self.message = message
        self.path = path
    }

    var description: String { "PlanFormatError(\(path.isEmpty ? "" : "\(path): ")\(message))" }
}

/// A decoded JSON value.
enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

/// Strict RFC 8259 reader over UTF-8 bytes (duplicate keys: last wins, as in Dart).
struct PlanJSONReader {
    private let bytes: [UInt8]
    private var i = 0

    /// Parses one JSON document.
    static func parse(_ data: Data) throws -> JSONValue {
        var reader = PlanJSONReader(bytes: [UInt8](data))
        reader.skipWhitespace()
        let value = try reader.readValue(depth: 0)
        reader.skipWhitespace()
        guard reader.i == reader.bytes.count else { throw PlanFormatError("invalid JSON: trailing characters") }
        return value
    }

    private init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    private mutating func skipWhitespace() {
        while i < bytes.count {
            switch bytes[i] {
            case 0x20, 0x09, 0x0A, 0x0D: i += 1
            default: return
            }
        }
    }

    private func fail(_ what: String) -> PlanFormatError {
        PlanFormatError("invalid JSON: \(what) at offset \(i)")
    }

    private mutating func readValue(depth: Int) throws -> JSONValue {
        guard depth < 512 else { throw fail("nesting too deep") }
        guard i < bytes.count else { throw fail("unexpected end") }
        switch bytes[i] {
        case UInt8(ascii: "{"): return try readObject(depth: depth)
        case UInt8(ascii: "["): return try readArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try readString())
        case UInt8(ascii: "t"): try expectLiteral("true"); return .bool(true)
        case UInt8(ascii: "f"): try expectLiteral("false"); return .bool(false)
        case UInt8(ascii: "n"): try expectLiteral("null"); return .null
        default: return try readNumber()
        }
    }

    private mutating func expectLiteral(_ literal: String) throws {
        for b in literal.utf8 {
            guard i < bytes.count, bytes[i] == b else { throw fail("bad literal") }
            i += 1
        }
    }

    private mutating func readObject(depth: Int) throws -> JSONValue {
        i += 1
        var out: [String: JSONValue] = [:]
        skipWhitespace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "}") {
            i += 1
            return .object(out)
        }
        while true {
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail("expected a key") }
            let key = try readString()
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw fail("expected ':'") }
            i += 1
            skipWhitespace()
            out[key] = try readValue(depth: depth + 1)
            skipWhitespace()
            guard i < bytes.count else { throw fail("unexpected end") }
            if bytes[i] == UInt8(ascii: ",") {
                i += 1
                continue
            }
            guard bytes[i] == UInt8(ascii: "}") else { throw fail("expected ',' or '}'") }
            i += 1
            return .object(out)
        }
    }

    private mutating func readArray(depth: Int) throws -> JSONValue {
        i += 1
        var out: [JSONValue] = []
        skipWhitespace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "]") {
            i += 1
            return .array(out)
        }
        while true {
            skipWhitespace()
            out.append(try readValue(depth: depth + 1))
            skipWhitespace()
            guard i < bytes.count else { throw fail("unexpected end") }
            if bytes[i] == UInt8(ascii: ",") {
                i += 1
                continue
            }
            guard bytes[i] == UInt8(ascii: "]") else { throw fail("expected ',' or ']'") }
            i += 1
            return .array(out)
        }
    }

    private mutating func readHex4() throws -> UInt32 {
        guard i + 4 <= bytes.count else { throw fail("bad \\u escape") }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let c = bytes[i]
            let d: UInt32
            switch c {
            case 0x30...0x39: d = UInt32(c - 0x30)
            case 0x41...0x46: d = UInt32(c - 0x41 + 10)
            case 0x61...0x66: d = UInt32(c - 0x61 + 10)
            default: throw fail("bad \\u escape")
            }
            v = v << 4 | d
            i += 1
        }
        return v
    }

    private mutating func readString() throws -> String {
        i += 1
        let start = i
        // Fast path: no escapes.
        while i < bytes.count {
            let c = bytes[i]
            if c == UInt8(ascii: "\"") {
                let s = String(decoding: bytes[start..<i], as: UTF8.self)
                i += 1
                return s
            }
            if c == UInt8(ascii: "\\") { break }
            if c < 0x20 { throw fail("control character in string") }
            i += 1
        }
        var out = [UInt8](bytes[start..<i])
        while i < bytes.count {
            let c = bytes[i]
            if c == UInt8(ascii: "\"") {
                i += 1
                return String(decoding: out, as: UTF8.self)
            }
            if c < 0x20 { throw fail("control character in string") }
            if c != UInt8(ascii: "\\") {
                out.append(c)
                i += 1
                continue
            }
            i += 1
            guard i < bytes.count else { break }
            let e = bytes[i]
            i += 1
            switch e {
            case UInt8(ascii: "\""): out.append(0x22)
            case UInt8(ascii: "\\"): out.append(0x5C)
            case UInt8(ascii: "/"): out.append(0x2F)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                var scalar = try readHex4()
                if (0xD800...0xDBFF).contains(scalar), i + 1 < bytes.count,
                   bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                    let save = i
                    i += 2
                    let low = try readHex4()
                    if (0xDC00...0xDFFF).contains(low) {
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        i = save
                    }
                }
                let unicode = Unicode.Scalar(scalar) ?? "\u{FFFD}"
                out.append(contentsOf: Array(String(Character(unicode)).utf8))
            default:
                throw fail("bad escape")
            }
        }
        throw fail("unterminated string")
    }

    private mutating func readNumber() throws -> JSONValue {
        let start = i
        var isDouble = false
        if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
        guard i < bytes.count, (0x30...0x39).contains(bytes[i]) else { throw fail("unexpected character") }
        if bytes[i] == 0x30 {
            i += 1
        } else {
            while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            isDouble = true
            i += 1
            guard i < bytes.count, (0x30...0x39).contains(bytes[i]) else { throw fail("bad number") }
            while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            isDouble = true
            i += 1
            if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard i < bytes.count, (0x30...0x39).contains(bytes[i]) else { throw fail("bad number") }
            while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }
        }
        let text = String(decoding: bytes[start..<i], as: UTF8.self)
        if !isDouble, let v = Int64(text) { return .int(v) }
        guard let d = Double(text) else { throw fail("bad number") }
        return .double(d)
    }
}

/// An encoded JSON value with ordered object keys (canonical output).
indirect enum JSONOut {
    case int(Int64)
    case double(Double)
    case string(String)
    case bool(Bool)
    case array([JSONOut])
    case object([(String, JSONOut)])

    /// Canonical number: integral finite doubles below 2^53 become ints (Dart `_num`).
    static func num(_ d: Double) -> JSONOut {
        if d.isFinite, d == d.rounded(.towardZero), abs(d) < 9_007_199_254_740_992 { return .int(Int64(d)) }
        return .double(d)
    }
}

/// Compact JSON writer matching Dart's `jsonEncode` byte for byte.
enum PlanJSONWriter {
    static func data(_ value: JSONOut) -> Data {
        var out = ""
        out.reserveCapacity(4096)
        write(value, into: &out)
        return Data(out.utf8)
    }

    static func string(_ value: JSONOut) -> String {
        var out = ""
        write(value, into: &out)
        return out
    }

    private static func write(_ value: JSONOut, into out: inout String) {
        switch value {
        case .int(let v): out += String(v)
        case .double(let d): out += formatDouble(d)
        case .bool(let b): out += b ? "true" : "false"
        case .string(let s): writeString(s, into: &out)
        case .array(let items):
            out += "["
            for (n, item) in items.enumerated() {
                if n > 0 { out += "," }
                write(item, into: &out)
            }
            out += "]"
        case .object(let pairs):
            out += "{"
            for (n, pair) in pairs.enumerated() {
                if n > 0 { out += "," }
                writeString(pair.0, into: &out)
                out += ":"
                write(pair.1, into: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x09: out += "\\t"
            case 0x0A: out += "\\n"
            case 0x0C: out += "\\f"
            case 0x0D: out += "\\r"
            case 0..<0x20:
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }

    /// Dart's `double.toString()` (the ECMAScript Number::toString algorithm) for a non-integral
    /// or very large double: shortest round-trip digits, exponent form below 1e-6 and from 1e21.
    static func formatDouble(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
        if d == 0 { return d.sign == .minus ? "-0.0" : "0.0" }
        let negative = d < 0
        // Swift's description is the shortest round-trip form too; only its layout differs.
        let text = abs(d).description
        var mantissa = Substring(text)
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = text[..<e]
            exponent = Int(text[text.index(after: e)...]) ?? 0
        }
        var digits = ""
        var pointPos: Int
        if let dot = mantissa.firstIndex(of: ".") {
            let intPart = mantissa[..<dot]
            let fracPart = mantissa[mantissa.index(after: dot)...]
            digits = String(intPart) + String(fracPart)
            pointPos = intPart.count + exponent
        } else {
            digits = String(mantissa)
            pointPos = digits.count + exponent
        }
        while digits.hasPrefix("0"), digits.count > 1 {
            digits.removeFirst()
            pointPos -= 1
        }
        while digits.hasSuffix("0"), digits.count > 1 { digits.removeLast() }
        let k = digits.count
        let n = pointPos
        var result: String
        if k <= n && n <= 21 {
            result = digits + String(repeating: "0", count: n - k) + ".0"
        } else if 0 < n && n <= 21 {
            let idx = digits.index(digits.startIndex, offsetBy: n)
            result = String(digits[..<idx]) + "." + String(digits[idx...])
        } else if -6 < n && n <= 0 {
            result = "0." + String(repeating: "0", count: -n) + digits
        } else {
            let e = n - 1
            let sign = e < 0 ? "-" : "+"
            let head = String(digits.prefix(1))
            let tail = String(digits.dropFirst())
            result = (tail.isEmpty ? head : head + "." + tail) + "e" + sign + String(abs(e))
        }
        return negative ? "-" + result : result
    }
}
