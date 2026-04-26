//
//  EmailView.swift
//  eml-viewer
//

import SwiftUI
import WebKit
import UniformTypeIdentifiers
import AppKit

struct EmailView: View {
    let message: EMLMessage

    @State private var showAllHeaders = false
    @State private var showSource = false
    @State private var rawSource: String = ""
    let rawData: Data

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerCard
            Divider()
            if showSource {
                ScrollView {
                    Text(rawSource)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            } else {
                bodyView
            }
            if !message.attachments.isEmpty {
                Divider()
                attachmentsBar
            }
        }
        .frame(minWidth: 600, minHeight: 500)
        .onAppear { rawSource = String(data: rawData, encoding: .utf8) ?? String(data: rawData, encoding: .isoLatin1) ?? "" }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $showSource) {
                    Label("Source", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .help("Show raw source")
            }
        }
    }

    // MARK: Header card

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let subject = message.subject, !subject.isEmpty {
                Text(subject)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
            headerRow("From", message.from)
            headerRow("To", message.to)
            headerRow("Cc", message.cc)
            headerRow("Date", message.date)
            if showAllHeaders {
                ForEach(Array(message.headers.enumerated()), id: \.offset) { _, pair in
                    let (k, v) = pair
                    if !["subject","from","to","cc","date"].contains(k.lowercased()) {
                        headerRow(k, MIMEDecoder.decodeEncodedWords(v))
                    }
                }
            }
            Button(showAllHeaders ? "Hide full headers" : "Show full headers") {
                showAllHeaders.toggle()
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary)
    }

    @ViewBuilder
    private func headerRow(_ name: String, _ value: String?) -> some View {
        if let v = value, !v.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
                Text(v)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Body

    @ViewBuilder
    private var bodyView: some View {
        if let html = message.htmlBody, !html.isEmpty {
            HTMLView(html: html)
        } else if let text = message.textBody, !text.isEmpty {
            ScrollView {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        } else {
            VStack {
                Spacer()
                Text("No readable body content")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Attachments

    private var attachmentsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Image(systemName: "paperclip")
                    .foregroundStyle(.secondary)
                ForEach(message.attachments) { att in
                    AttachmentChip(attachment: att)
                }
            }
            .padding(10)
        }
        .background(.background.secondary)
    }
}

// MARK: - Attachment chip

struct AttachmentChip: View {
    let attachment: EMLAttachment

    var body: some View {
        Menu {
            Button("Save As…") { saveAs() }
            Button("Quick Look") { quickLook() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                Text(attachment.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(byteString)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.background)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var byteString: String {
        ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file)
    }

    private var iconName: String {
        let m = attachment.mimeType.lowercased()
        if m.hasPrefix("image/") { return "photo" }
        if m.hasPrefix("application/pdf") { return "doc.richtext" }
        if m.hasPrefix("text/") { return "doc.text" }
        if m.contains("zip") || m.contains("compressed") { return "doc.zipper" }
        return "doc"
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.filename
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? attachment.data.write(to: url)
        }
    }

    private func quickLook() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(attachment.filename)
        do {
            try attachment.data.write(to: tmp, options: .atomic)
            NSWorkspace.shared.open(tmp)
        } catch {
            NSSound.beep()
        }
    }
}

// MARK: - HTML view (WKWebView)

struct HTMLView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Keep remote content load-through simple; for privacy we don't block remote images by default
        // but that could be an enhancement. This app is a viewer, not a mail client.
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        let wrapped = """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: light dark; }
          html, body { margin: 0; padding: 14px; font: -apple-system-body, system-ui, sans-serif; }
          img { max-width: 100%; height: auto; }
          pre, code { white-space: pre-wrap; word-break: break-word; }
          blockquote { border-left: 3px solid #8883; padding-left: 10px; color: #666; }
          a { color: -apple-system-blue; }
        </style></head>
        <body>\(html)</body></html>
        """
        nsView.loadHTMLString(wrapped, baseURL: nil)
    }
}
