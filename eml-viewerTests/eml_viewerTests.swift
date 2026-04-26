//
//  eml_viewerTests.swift
//  eml-viewerTests
//
//  Created by Pascal on 23.04.2026.
//

import Testing
import Foundation
@testable import eml_viewer

struct eml_viewerTests {

    @Test func parsesSimplePlainTextMessage() async throws {
        let raw = """
        From: Alice <alice@example.com>\r
        To: Bob <bob@example.com>\r
        Subject: Hello world\r
        Date: Mon, 1 Jan 2024 10:00:00 +0000\r
        MIME-Version: 1.0\r
        Content-Type: text/plain; charset="utf-8"\r
        \r
        Hello Bob, this is the body.\r
        """
        let msg = EMLParser.parse(data: Data(raw.utf8))
        #expect(msg.subject == "Hello world")
        #expect(msg.from == "Alice <alice@example.com>")
        #expect(msg.to == "Bob <bob@example.com>")
        #expect(msg.textBody?.contains("Hello Bob") == true)
        #expect(msg.htmlBody == nil)
        #expect(msg.attachments.isEmpty)
    }

    @Test func decodesQuotedPrintableBody() async throws {
        let raw = """
        Subject: QP\r
        Content-Type: text/plain; charset="utf-8"\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        Caf=C3=A9 na=C3=AFve\r
        """
        let msg = EMLParser.parse(data: Data(raw.utf8))
        #expect(msg.textBody?.contains("Café naïve") == true)
    }

    @Test func decodesBase64Attachment() async throws {
        let payload = "Hello, attachment!".data(using: .utf8)!
        let b64 = payload.base64EncodedString()
        let raw = """
        Subject: Attached\r
        MIME-Version: 1.0\r
        Content-Type: multipart/mixed; boundary="BOUND"\r
        \r
        --BOUND\r
        Content-Type: text/plain; charset="utf-8"\r
        \r
        See attachment.\r
        --BOUND\r
        Content-Type: text/plain; name="hello.txt"\r
        Content-Disposition: attachment; filename="hello.txt"\r
        Content-Transfer-Encoding: base64\r
        \r
        \(b64)\r
        --BOUND--\r
        """
        let msg = EMLParser.parse(data: Data(raw.utf8))
        #expect(msg.textBody?.contains("See attachment.") == true)
        #expect(msg.attachments.count == 1)
        #expect(msg.attachments.first?.filename == "hello.txt")
        #expect(msg.attachments.first?.data == payload)
    }

    @Test func decodesEncodedWordSubject() async throws {
        let raw = """
        Subject: =?utf-8?B?SGVsbG8sIOS4lueVjA==?=\r
        \r
        body\r
        """
        let msg = EMLParser.parse(data: Data(raw.utf8))
        #expect(msg.subject == "Hello, 世界")
    }

    @Test func detectsMSGMagicBytes() async throws {
        let cfbMagic = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Data(count: 512)
        #expect(MSGParser.isMSG(cfbMagic))
        let plainEml = Data("From: a@b\r\n\r\nbody".utf8)
        #expect(!MSGParser.isMSG(plainEml))
        // Parser dispatch falls through to the RFC 822 path for non-CFB bytes.
        let msg = EMLParser.parse(data: plainEml)
        #expect(msg.from?.contains("a@b") == true)
    }

    @Test func msgParserReturnsNilForTruncatedCFB() async throws {
        // Magic header without any valid FAT / directory — parser must not crash.
        let bogus = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Data(count: 512)
        let result = MSGParser.parse(data: bogus)
        // Either nil or an empty message is acceptable; mustn't throw / crash.
        if let r = result {
            #expect(r.attachments.isEmpty)
            #expect(r.textBody == nil || r.textBody?.isEmpty == true)
        }
    }

    @Test func prefersHtmlAlternativeWhenPresent() async throws {
        let raw = """
        Subject: Multi\r
        Content-Type: multipart/alternative; boundary="X"\r
        \r
        --X\r
        Content-Type: text/plain; charset="utf-8"\r
        \r
        plain version\r
        --X\r
        Content-Type: text/html; charset="utf-8"\r
        \r
        <p>html version</p>\r
        --X--\r
        """
        let msg = EMLParser.parse(data: Data(raw.utf8))
        #expect(msg.textBody?.contains("plain version") == true)
        #expect(msg.htmlBody?.contains("html version") == true)
    }
}
