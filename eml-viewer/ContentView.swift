//
//  ContentView.swift
//  eml-viewer
//
//  Created by Pascal on 23.04.2026.
//

import SwiftUI

struct ContentView: View {
    let document: EMLDocument

    var body: some View {
        EmailView(message: document.message, rawData: document.rawData)
    }
}

#Preview {
    ContentView(document: EMLDocument())
}
