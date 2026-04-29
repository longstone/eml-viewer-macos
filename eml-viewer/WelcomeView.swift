//
//  WelcomeView.swift
//  eml-viewer
//
//  Startup window with a drag-and-drop target for .eml files.
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct WelcomeView: View {
    @State private var isTargeted = false
    @State private var errorText: String? = nil

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 12)

            Image(systemName: "envelope.badge")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text("EML Viewer")
                    .font(.title.weight(.semibold))
                Text("Drop an .eml or .msg file here to open it")
                    .foregroundStyle(.secondary)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                    )
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(isTargeted ? "Release to open" : "Drag & drop .eml or .msg")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 180)
            .padding(.horizontal, 24)
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                handleDrop(providers: providers)
            }

            if let errorText {
                Text(errorText)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button {
                    openPanel()
                } label: {
                    Label("Open File…", systemImage: "folder")
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            Spacer(minLength: 12)

            Text("Free software, distributed as-is.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
        }
        .padding(24)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 480, idealHeight: 520)
    }

    // MARK: Actions

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                switch item {
                case let data as Data:
                    url = URL(dataRepresentation: data, relativeTo: nil)
                case let u as URL:
                    url = u
                default:
                    url = nil
                }
                guard let url else { return }
                DispatchQueue.main.async { open(url: url) }
            }
        }
        return accepted
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.emailMessage, .outlookMessage, .outlookMSG]
        if panel.runModal() == .OK, let url = panel.url {
            open(url: url)
        }
    }

    private func open(url: URL) {
        errorText = nil
        let ext = url.pathExtension.lowercased()
        guard ext == "eml" || ext == "msg" else {
            errorText = "“\(url.lastPathComponent)” isn’t an email file. EML Viewer opens .eml and .msg messages."
            return
        }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, err in
            if let err {
                errorText = "Could not open \(url.lastPathComponent): \(err.localizedDescription)"
            }
        }
    }
}

#Preview {
    WelcomeView()
}
