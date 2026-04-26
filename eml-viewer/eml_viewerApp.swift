//
//  eml_viewerApp.swift
//  eml-viewer
//
//  Created by Pascal on 23.04.2026.
//

import SwiftUI
import AppKit

@main
struct eml_viewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("EML Viewer", id: "welcome") {
            WelcomeView()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        DocumentGroup(viewing: EMLDocument.self) { file in
            ContentView(document: file.document)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Prevent the default "Open…" panel / untitled document from appearing at launch;
    // the Welcome window handles that instead.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // Re-show the welcome window when the user clicks the Dock icon with no windows open.
            for w in sender.windows where w.identifier?.rawValue == "welcome" {
                w.makeKeyAndOrderFront(nil)
                return false
            }
        }
        return true
    }
}
