//
//  EMLParser.swift
//  eml-viewer
//
//  A self-contained parser for RFC 822 / MIME (.eml) messages.
//  Handles:
//    - Folded headers
//    - RFC 2047 encoded-word decoding (=?charset?B|Q?...?=)
//    - Content-Transfer-Encoding: 7bit, 8bit, binary, quoted-printable, base64
//    - multipart/* with boundary parsing (recursive)
//    - Charset-aware body decoding
//
//  No external dependencies.
//

import Foundation

// MARK: - Public model

struct EMLAttachment: Identifiable, Hashable {
    let id = UUID()
    let filename: String
    let mimeType: String
    let data: Data
}

struct EMLMessage {
    /// Raw, ordered header fields as (name, rawValue) pairs.
    var headers: [(String, String)] = []
    /// Decoded plain-text body (best-effort from text/plain part).
    var textBody: String? = nil
    /// Decoded HTML body (best-effort from text/html part).
    var htmlBody: String? = nil
    /// Inline and regular attachments.
    var attachments: [EMLAttachment] = []

    func header(_ name: String) -> String? {
        let lower = name.lowercased()
        for (k, v) in headers where k.lowercased() == lower {
            return v
        }
        return nil
    }

    var subject: String? { header("Subject").map(MIMEDecoder.decodeEncodedWords) }
    var from: String? { header("From").map(MIMEDecoder.decodeEncodedWords) }
    var to: String? { header("To").map(MIMEDecoder.decodeEncodedWords) }
    var cc: String? { header("Cc").map(MIMEDecoder.decodeEncodedWords) }
    var bcc: String? { header("Bcc").map(MIMEDecoder.decodeEncodedWords) }
    var date: String? { header("Date") }
}

// MARK: - Entry point

enum EMLParser {
    static func parse(data: Data) -> EMLMessage {
        // If this is a Microsoft Outlook .msg (OLE2 compound file),
        // route it through the MSG parser. Otherwise treat as RFC 822.
        if MSGParser.isMSG(data), let msg = MSGParser.parse(data: data) {
            return msg
        }
        let part = MIMEPart.parse(data: data)
        var msg = EMLMessage()
        msg.headers = part.headers
        collect(from: part, into: &msg)
        return msg
    }

    static func parse(url: URL) throws -> EMLMessage {
        let data = try Data(contentsOf: url)
        return parse(data: data)
    }

    private static func collect(from part: MIMEPart, into msg: inout EMLMessage) {
        let ct = part.contentType.lowercased()
        let disposition = part.headerValue("Content-Disposition")?.lowercased() ?? ""
        let isAttachment = disposition.contains("attachment") || part.filename != nil

        if ct.hasPrefix("multipart/") {
            for child in part.children {
                collect(from: child, into: &msg)
            }
            return
        }

        if isAttachment {
            let name = part.filename ?? defaultName(for: ct)
            msg.attachments.append(EMLAttachment(filename: name,
                                                 mimeType: part.contentType,
                                                 data: part.decodedBody))
            return
        }

        if ct.hasPrefix("text/html") {
            if msg.htmlBody == nil {
                msg.htmlBody = part.decodedText()
            }
            return
        }

        if ct.hasPrefix("text/") {
            if msg.textBody == nil {
                msg.textBody = part.decodedText()
            }
            return
        }

        // Unknown single part: treat as attachment so nothing is lost.
        let name = part.filename ?? defaultName(for: ct)
        msg.attachments.append(EMLAttachment(filename: name,
                                             mimeType: part.contentType,
                                             data: part.decodedBody))
    }

    private static func defaultName(for mime: String) -> String {
        let ext: String
        switch mime.lowercased() {
        case let m where m.hasPrefix("image/png"): ext = "png"
        case let m where m.hasPrefix("image/jpeg"), let m where m.hasPrefix("image/jpg"): ext = "jpg"
        case let m where m.hasPrefix("image/gif"): ext = "gif"
        case let m where m.hasPrefix("application/pdf"): ext = "pdf"
        case let m where m.hasPrefix("text/"): ext = "txt"
        default: ext = "bin"
        }
        return "attachment.\(ext)"
    }
}

// MARK: - MIME part

final class MIMEPart {
    var headers: [(String, String)] = []
    var body: Data = Data()
    var children: [MIMEPart] = []

    var contentType: String {
        let v = headerValue("Content-Type") ?? "text/plain"
        return (v.split(separator: ";").first.map(String.init) ?? v)
            .trimmingCharacters(in: .whitespaces)
    }

    var contentTypeParameters: [String: String] {
        parseParameters(headerValue("Content-Type") ?? "")
    }

    var contentDispositionParameters: [String: String] {
        parseParameters(headerValue("Content-Disposition") ?? "")
    }

    var charset: String {
        contentTypeParameters["charset"]?.lowercased() ?? "utf-8"
    }

    var transferEncoding: String {
        (headerValue("Content-Transfer-Encoding") ?? "7bit")
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
    }

    var filename: String? {
        if let n = contentDispositionParameters["filename"] {
            return MIMEDecoder.decodeEncodedWords(n)
        }
        if let n = contentTypeParameters["name"] {
            return MIMEDecoder.decodeEncodedWords(n)
        }
        return nil
    }

    func headerValue(_ name: String) -> String? {
        let lower = name.lowercased()
        for (k, v) in headers where k.lowercased() == lower { return v }
        return nil
    }

    /// Decoded bytes after applying the part's transfer encoding.
    var decodedBody: Data {
        switch transferEncoding {
        case "base64":
            let cleaned = String(data: body, encoding: .ascii)?
                .components(separatedBy: .whitespacesAndNewlines).joined() ?? ""
            return Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters) ?? Data()
        case "quoted-printable":
            return MIMEDecoder.decodeQuotedPrintable(body)
        default:
            return body
        }
    }

    /// Body decoded and interpreted as text using the declared charset.
    func decodedText() -> String {
        let data = decodedBody
        let enc = MIMEDecoder.stringEncoding(forCharset: charset)
        if let s = String(data: data, encoding: enc) { return s }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }

    // MARK: Parsing

    static func parse(data: Data) -> MIMEPart {
        let (headers, body) = splitHeadersAndBody(data)
        let part = MIMEPart()
        part.headers = headers
        part.body = body
        let ct = part.contentType.lowercased()
        if ct.hasPrefix("multipart/"), let boundary = part.contentTypeParameters["boundary"] {
            part.children = splitMultipart(body: body, boundary: boundary).map { MIMEPart.parse(data: $0) }
        } else if ct == "message/rfc822" {
            // Nested message: parse as a single child so its parts surface.
            part.children = [MIMEPart.parse(data: body)]
        }
        return part
    }

    private static func splitHeadersAndBody(_ data: Data) -> ([(String, String)], Data) {
        // Find the first CRLF CRLF or LF LF.
        let bytes = [UInt8](data)
        var sep: (Int, Int)? = nil
        var i = 0
        while i < bytes.count {
            if i + 3 < bytes.count,
               bytes[i] == 0x0D, bytes[i+1] == 0x0A, bytes[i+2] == 0x0D, bytes[i+3] == 0x0A {
                sep = (i, i + 4); break
            }
            if i + 1 < bytes.count, bytes[i] == 0x0A, bytes[i+1] == 0x0A {
                sep = (i, i + 2); break
            }
            i += 1
        }
        let headerEnd = sep?.0 ?? bytes.count
        let bodyStart = sep?.1 ?? bytes.count
        let headerData = data.subdata(in: 0..<headerEnd)
        let bodyData = bodyStart < data.count ? data.subdata(in: bodyStart..<data.count) : Data()
        let headerString = String(data: headerData, encoding: .ascii)
            ?? String(data: headerData, encoding: .isoLatin1)
            ?? ""
        return (parseHeaders(headerString), bodyData)
    }

    private static func parseHeaders(_ text: String) -> [(String, String)] {
        var out: [(String, String)] = []
        var current: (String, String)? = nil
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        for rawLine in lines {
            let line = String(rawLine)
            if line.isEmpty { continue }
            if let first = line.first, first == " " || first == "\t" {
                if current != nil {
                    current!.1 += " " + line.trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            if let colon = line.firstIndex(of: ":") {
                if let c = current { out.append(c) }
                let name = String(line[..<colon])
                var value = String(line[line.index(after: colon)...])
                if value.hasPrefix(" ") { value.removeFirst() }
                current = (name, value)
            }
        }
        if let c = current { out.append(c) }
        return out
    }

    private static func splitMultipart(body: Data, boundary: String) -> [Data] {
        let delim = "--" + boundary
        guard let delimData = delim.data(using: .ascii) else { return [] }
        var parts: [Data] = []
        var searchStart = body.startIndex
        var ranges: [Range<Data.Index>] = []
        while searchStart < body.endIndex,
              let r = body.range(of: delimData, in: searchStart..<body.endIndex) {
            ranges.append(r)
            searchStart = r.upperBound
        }
        guard ranges.count >= 2 else { return [] }
        for i in 0..<(ranges.count - 1) {
            var start = ranges[i].upperBound
            let end = ranges[i + 1].lowerBound
            // Each delimiter line ends with CRLF; skip it.
            if start < end, body[start] == 0x0D { start = body.index(after: start) }
            if start < end, body[start] == 0x0A { start = body.index(after: start) }
            // Closing delimiter starts with "--" after boundary; check end marker on current range
            let afterBoundary = ranges[i].upperBound
            if afterBoundary + 1 < body.endIndex,
               body[afterBoundary] == 0x2D, body[afterBoundary + 1] == 0x2D {
                // this is closing boundary; nothing after
                break
            }
            // Trim trailing CRLF before next boundary.
            var realEnd = end
            if realEnd > start, body[body.index(before: realEnd)] == 0x0A {
                realEnd = body.index(before: realEnd)
            }
            if realEnd > start, body[body.index(before: realEnd)] == 0x0D {
                realEnd = body.index(before: realEnd)
            }
            if start < realEnd {
                parts.append(body.subdata(in: start..<realEnd))
            } else {
                parts.append(Data())
            }
        }
        return parts
    }

    private func parseParameters(_ value: String) -> [String: String] {
        var result: [String: String] = [:]
        let parts = splitRespectingQuotes(value, separator: ";")
        for (i, raw) in parts.enumerated() where i > 0 {
            let kv = raw.trimmingCharacters(in: .whitespaces)
            guard let eq = kv.firstIndex(of: "=") else { continue }
            let key = kv[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var val = String(kv[kv.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 {
                val.removeFirst(); val.removeLast()
            }
            result[key] = val
        }
        return result
    }

    private func splitRespectingQuotes(_ s: String, separator: Character) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuotes = false
        for ch in s {
            if ch == "\"" { inQuotes.toggle(); current.append(ch); continue }
            if ch == separator && !inQuotes {
                out.append(current); current = ""; continue
            }
            current.append(ch)
        }
        out.append(current)
        return out
    }
}

// MARK: - Decoders

enum MIMEDecoder {
    static func stringEncoding(forCharset charset: String) -> String.Encoding {
        switch charset.lowercased() {
        case "utf-8", "utf8": return .utf8
        case "us-ascii", "ascii": return .ascii
        case "iso-8859-1", "latin1", "latin-1": return .isoLatin1
        case "iso-8859-2": return .isoLatin2
        case "utf-16": return .utf16
        case "utf-16be": return .utf16BigEndian
        case "utf-16le": return .utf16LittleEndian
        case "windows-1252", "cp1252": return .windowsCP1252
        case "windows-1251", "cp1251": return .windowsCP1251
        case "windows-1250", "cp1250": return .windowsCP1250
        default:
            let cfName = charset as CFString
            let enc = CFStringConvertIANACharSetNameToEncoding(cfName)
            if enc != kCFStringEncodingInvalidId {
                let ns = CFStringConvertEncodingToNSStringEncoding(enc)
                return String.Encoding(rawValue: ns)
            }
            return .utf8
        }
    }

    static func decodeQuotedPrintable(_ data: Data) -> Data {
        var out = Data()
        var i = 0
        let bytes = [UInt8](data)
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x3D { // '='
                if i + 2 < bytes.count {
                    let h1 = bytes[i+1]; let h2 = bytes[i+2]
                    if h1 == 0x0D && h2 == 0x0A { i += 3; continue } // soft line break
                    if h1 == 0x0A { i += 2; continue }
                    if let v = hexPair(h1, h2) { out.append(v); i += 3; continue }
                }
                // malformed; emit literal
                out.append(b); i += 1
            } else {
                out.append(b); i += 1
            }
        }
        return out
    }

    private static func hexPair(_ a: UInt8, _ b: UInt8) -> UInt8? {
        guard let ha = hexVal(a), let hb = hexVal(b) else { return nil }
        return (ha << 4) | hb
    }

    private static func hexVal(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x41 + 10
        case 0x61...0x66: return b - 0x61 + 10
        default: return nil
        }
    }

    /// Decodes RFC 2047 encoded-words in a header value string.
    static func decodeEncodedWords(_ s: String) -> String {
        // Pattern:  =?charset?B|Q?text?=
        guard s.contains("=?") else { return s }
        var result = ""
        var i = s.startIndex
        while i < s.endIndex {
            if let start = s.range(of: "=?", range: i..<s.endIndex) {
                // Emit text before the token; collapse whitespace between adjacent encoded words.
                result.append(contentsOf: s[i..<start.lowerBound])
                // find ?= terminator
                var scan = start.upperBound
                // charset
                guard let q1 = s.range(of: "?", range: scan..<s.endIndex) else {
                    result.append(contentsOf: s[start.lowerBound..<s.endIndex])
                    return result
                }
                let charset = String(s[scan..<q1.lowerBound])
                scan = q1.upperBound
                guard let q2 = s.range(of: "?", range: scan..<s.endIndex) else {
                    result.append(contentsOf: s[start.lowerBound..<s.endIndex])
                    return result
                }
                let enc = String(s[scan..<q2.lowerBound]).uppercased()
                scan = q2.upperBound
                guard let end = s.range(of: "?=", range: scan..<s.endIndex) else {
                    result.append(contentsOf: s[start.lowerBound..<s.endIndex])
                    return result
                }
                let payload = String(s[scan..<end.lowerBound])
                let decoded = decodeEncodedWordPayload(payload, encoding: enc, charset: charset) ?? String(s[start.lowerBound..<end.upperBound])
                result.append(decoded)
                i = end.upperBound
                // RFC 2047: whitespace between adjacent encoded-words is ignored.
                var look = i
                while look < s.endIndex, s[look] == " " || s[look] == "\t" { look = s.index(after: look) }
                if look < s.endIndex, s[look..<s.endIndex].hasPrefix("=?") { i = look }
            } else {
                result.append(contentsOf: s[i..<s.endIndex])
                break
            }
        }
        return result
    }

    private static func decodeEncodedWordPayload(_ payload: String, encoding: String, charset: String) -> String? {
        let strEnc = stringEncoding(forCharset: charset)
        switch encoding {
        case "B":
            guard let d = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else { return nil }
            return String(data: d, encoding: strEnc) ?? String(data: d, encoding: .utf8)
        case "Q":
            // Q encoding: '_' means space, '=XX' hex.
            let replaced = payload.replacingOccurrences(of: "_", with: " ")
            guard let raw = replaced.data(using: .ascii) else { return nil }
            let decoded = decodeQuotedPrintable(raw)
            return String(data: decoded, encoding: strEnc) ?? String(data: decoded, encoding: .utf8)
        default:
            return nil
        }
    }
}
