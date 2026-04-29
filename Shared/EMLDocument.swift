//
//  EMLDocument.swift
//  eml-viewer
//

import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// RFC 822 email message. Already known to the system; exposed here for use
    /// with DocumentGroup / NSOpenPanel.
    static let emailMessage: UTType = UTType("public.email-message")
        ?? UTType(importedAs: "public.email-message")

    /// Microsoft Outlook .msg (CFB / OLE2 compound file). Declared as an
    /// imported type in Info.plist so the app advertises it to Launch Services.
    static let outlookMessage: UTType = UTType("com.microsoft.outlook.mail-message")
        ?? UTType(importedAs: "com.microsoft.outlook.mail-message")

    /// Alternate Outlook .msg identifier registered by some macOS setups.
    static let outlookMSG: UTType = UTType("com.microsoft.outlook.msg")
        ?? UTType(importedAs: "com.microsoft.outlook.msg")
}

struct EMLDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.emailMessage, .outlookMessage, .outlookMSG] }

    let message: EMLMessage
    let rawData: Data

    init(message: EMLMessage = EMLMessage(), rawData: Data = Data()) {
        self.message = message
        self.rawData = rawData
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        self.rawData = data
        self.message = EMLParser.parse(data: data)
    }

    // Viewer-only: write back the original bytes untouched.
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: rawData)
    }
}
