//
//  MSGParser.swift
//  eml-viewer
//
//  Decodes a Microsoft Outlook .msg file into the same EMLMessage model
//  used for RFC 822 emails. Covers the properties needed for viewing:
//
//    * __substg1.0_<TAG><TYPE> streams at top level carry message props.
//    * __recip_version1.0_#NNNNNNNN storages hold one recipient each.
//    * __attach_version1.0_#NNNNNNNN storages hold each attachment.
//
//  Relevant MAPI property tags:
//    0x0037  PR_SUBJECT
//    0x0039  PR_CLIENT_SUBMIT_TIME (FILETIME, PT_SYSTIME 0x0040)
//    0x0042  PR_SENT_REPRESENTING_NAME
//    0x007D  PR_TRANSPORT_MESSAGE_HEADERS (RFC 822 headers, as-is)
//    0x0C1A  PR_SENDER_NAME
//    0x0C1F  PR_SENDER_EMAIL_ADDRESS
//    0x0E03  PR_DISPLAY_CC
//    0x0E04  PR_DISPLAY_TO
//    0x0E06  PR_MESSAGE_DELIVERY_TIME
//    0x1000  PR_BODY
//    0x1013  PR_BODY_HTML  (PT_UNICODE 0x001F *or* PT_BINARY 0x0102)
//    0x3001  PR_DISPLAY_NAME       (on recipient)
//    0x3003  PR_EMAIL_ADDRESS      (on recipient, legacy)
//    0x0C15  PR_RECIPIENT_TYPE     (1=To, 2=Cc, 3=Bcc)
//    0x39FE  PR_SMTP_ADDRESS
//    0x5D01  PR_SENT_REPRESENTING_SMTP_ADDRESS
//    0x3701  PR_ATTACH_DATA_BIN
//    0x3704  PR_ATTACH_FILENAME
//    0x3707  PR_ATTACH_LONG_FILENAME
//    0x370E  PR_ATTACH_MIME_TAG
//

import Foundation

enum MSGParser {

    static func isMSG(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let magic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        return [UInt8](data.prefix(8)) == magic
    }

    /// Property map keyed by tag (high 16 bits). Values decoded best-effort
    /// by type: Unicode/ANSI strings become `String`, binaries stay `Data`,
    /// integers are `Int32`, times are `Date`. We also keep a separate
    /// `binaryByTag` map so callers can fetch the raw binary variant even
    /// when a string of the same tag is already present.
    private struct Props {
        var strings: [UInt16: String] = [:]
        var binaries: [UInt16: Data] = [:]
        var ints: [UInt16: Int32] = [:]
        var dates: [UInt16: Date] = [:]
    }

    static func parse(data: Data) -> EMLMessage? {
        guard let cfb = CFBReader(data: data) else { return nil }
        let rootIdx = cfb.entries.first?.index ?? 0
        let topChildren = cfb.children(of: rootIdx)
        let topProps = collectProperties(streams: topChildren, cfb: cfb)

        var msg = EMLMessage()

        // Transport headers: if present, carry them over as a baseline.
        if let transport = topProps.strings[0x007D], !transport.isEmpty {
            msg.headers = MIMEPart.parseHeadersOnly(transport)
        }

        func setHeader(_ name: String, _ value: String?) {
            guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !v.isEmpty else { return }
            let lower = name.lowercased()
            if let idx = msg.headers.firstIndex(where: { $0.0.lowercased() == lower }) {
                msg.headers[idx] = (name, v)
            } else {
                msg.headers.append((name, v))
            }
        }

        // Subject / From / Date
        setHeader("Subject", topProps.strings[0x0037])

        let senderName  = topProps.strings[0x0C1A] ?? topProps.strings[0x0042]
        let senderEmail = topProps.strings[0x5D01]
            ?? topProps.strings[0x39FE]
            ?? topProps.strings[0x0C1F]
        if let from = formatAddress(name: senderName, email: senderEmail) {
            setHeader("From", from)
        }

        // Recipients
        var toList: [String] = []
        var ccList: [String] = []
        var bccList: [String] = []
        for stg in topChildren
            where stg.type == 1 && stg.name.hasPrefix("__recip_version1.0_") {
            let rp = collectProperties(streams: cfb.children(of: stg.index), cfb: cfb)
            let name = rp.strings[0x3001]
            let addr = rp.strings[0x39FE] ?? rp.strings[0x3003]
            guard let formatted = formatAddress(name: name, email: addr) else { continue }
            switch rp.ints[0x0C15] ?? 1 {
            case 2: ccList.append(formatted)
            case 3: bccList.append(formatted)
            default: toList.append(formatted)
            }
        }
        if !toList.isEmpty  { setHeader("To",  toList.joined(separator: ", ")) }
        if !ccList.isEmpty  { setHeader("Cc",  ccList.joined(separator: ", ")) }
        if !bccList.isEmpty { setHeader("Bcc", bccList.joined(separator: ", ")) }

        if msg.header("To") == nil {
            setHeader("To", topProps.strings[0x0E04])
        }
        if msg.header("Cc") == nil {
            setHeader("Cc", topProps.strings[0x0E03])
        }

        if let date = topProps.dates[0x0039] ?? topProps.dates[0x0E06] {
            setHeader("Date", rfc2822Date(date))
        }

        // Body
        if let text = topProps.strings[0x1000], !text.isEmpty {
            msg.textBody = text
        }
        if let html = topProps.strings[0x1013], !html.isEmpty {
            msg.htmlBody = html
        } else if let htmlBin = topProps.binaries[0x1013], !htmlBin.isEmpty {
            msg.htmlBody = String(data: htmlBin, encoding: .utf8)
                ?? String(data: htmlBin, encoding: .windowsCP1252)
                ?? String(data: htmlBin, encoding: .isoLatin1)
        }

        // Attachments
        for stg in topChildren
            where stg.type == 1 && stg.name.hasPrefix("__attach_version1.0_") {
            let ap = collectProperties(streams: cfb.children(of: stg.index), cfb: cfb)
            let name = ap.strings[0x3707] ?? ap.strings[0x3704] ?? "attachment"
            let mime = ap.strings[0x370E] ?? "application/octet-stream"
            let bytes = ap.binaries[0x3701] ?? Data()
            guard !bytes.isEmpty else { continue }
            msg.attachments.append(EMLAttachment(filename: name, mimeType: mime, data: bytes))
        }

        return msg
    }

    // MARK: - Property collection

    private static func collectProperties(streams: [CFBDirEntry], cfb: CFBReader) -> Props {
        var out = Props()
        for e in streams
            where e.type == 2 && e.name.hasPrefix("__substg1.0_") && e.name.count >= 20 {
            // Name format: __substg1.0_TTTTUUUU[...]. TTTT = tag, UUUU = type.
            let suffix = e.name.dropFirst("__substg1.0_".count)
            guard suffix.count >= 8,
                  let tag  = UInt16(suffix.prefix(4), radix: 16),
                  let type = UInt16(suffix.dropFirst(4).prefix(4), radix: 16) else { continue }
            let data = cfb.readStream(e)
            switch type {
            case 0x001F:  // PT_UNICODE
                if let s = String(data: data, encoding: .utf16LittleEndian) {
                    out.strings[tag] = stripTrailingNull(s)
                }
            case 0x001E:  // PT_STRING8
                let s = String(data: data, encoding: .windowsCP1252)
                    ?? String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
                if let s { out.strings[tag] = stripTrailingNull(s) }
            case 0x0102:  // PT_BINARY
                out.binaries[tag] = data
            case 0x0003:  // PT_LONG (int32) — normally stored in __properties_version1.0, but
                          // some writers also dump it as a substream.
                if data.count >= 4 {
                    out.ints[tag] = Int32(bitPattern: data.u32LE(at: 0))
                }
            case 0x0040:  // PT_SYSTIME (FILETIME, 8 bytes)
                if data.count >= 8, let date = filetimeToDate(data.u64LE(at: 0)) {
                    out.dates[tag] = date
                }
            default:
                break
            }
        }

        // Recipient type / PR_CLIENT_SUBMIT_TIME usually live in the fixed
        // properties stream. Parse it so ints / dates are available.
        if let propsEntry = streams.first(where: { $0.type == 2 && $0.name == "__properties_version1.0" }) {
            let bytes = cfb.readStream(propsEntry)
            mergeFixedProperties(bytes, into: &out)
        }

        return out
    }

    /// Parses the `__properties_version1.0` stream. Layout: 8-byte or 32-byte
    /// header, followed by 16-byte fixed-size property entries. We only
    /// decode PT_LONG and PT_SYSTIME entries (the rest live in their own
    /// substg streams).
    private static func mergeFixedProperties(_ data: Data, into props: inout Props) {
        // Heuristic: for attachment / recipient / embedded msg, header is 8 bytes.
        // For the top-level message it is 32 bytes. Try both offsets.
        for headerLen in [32, 24, 8] {
            if data.count >= headerLen + 16, parseFixedPropsBlock(data, offset: headerLen, into: &props) {
                return
            }
        }
    }

    @discardableResult
    private static func parseFixedPropsBlock(_ data: Data, offset: Int, into props: inout Props) -> Bool {
        var off = offset
        var anyDecoded = false
        while off + 16 <= data.count {
            let type = data.u16LE(at: off)
            let tag  = data.u16LE(at: off + 2)
            // Sanity: property tag=0 is invalid, break out.
            if tag == 0 && type == 0 { break }
            switch type {
            case 0x0003:
                props.ints[tag] = Int32(bitPattern: data.u32LE(at: off + 8))
                anyDecoded = true
            case 0x0040:
                if let date = filetimeToDate(data.u64LE(at: off + 8)) {
                    props.dates[tag] = date
                    anyDecoded = true
                }
            default:
                break
            }
            off += 16
        }
        return anyDecoded
    }

    // MARK: - Helpers

    private static func stripTrailingNull(_ s: String) -> String {
        var out = s
        while out.hasSuffix("\u{0000}") { out.removeLast() }
        return out
    }

    private static func filetimeToDate(_ ticks: UInt64) -> Date? {
        guard ticks > 0 else { return nil }
        let seconds = Double(ticks) / 10_000_000.0
        let epochDelta = 11_644_473_600.0 // seconds from 1601-01-01 to 1970-01-01
        return Date(timeIntervalSince1970: seconds - epochDelta)
    }

    private static let rfc2822Formatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return df
    }()

    private static func rfc2822Date(_ date: Date) -> String {
        rfc2822Formatter.string(from: date)
    }

    private static func formatAddress(name: String?, email: String?) -> String? {
        let n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let e = (email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch (n.isEmpty, e.isEmpty) {
        case (true, true):   return nil
        case (false, true):  return n
        case (true, false):  return e
        case (false, false): return "\(n) <\(e)>"
        }
    }
}

// MARK: - MIMEPart headers-only helper

extension MIMEPart {
    /// Parses a chunk of plain RFC 822 headers (no body) into ordered pairs.
    static func parseHeadersOnly(_ text: String) -> [(String, String)] {
        var raw = Data(text.utf8)
        raw.append(contentsOf: [0x0D, 0x0A, 0x0D, 0x0A])
        let part = MIMEPart.parse(data: raw)
        return part.headers
    }
}
