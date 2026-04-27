//
//  PreviewViewController.swift
//  QuickLookPreview
//
//  Renders an .eml or .msg message inside Finder's Quick Look panel.
//

import AppKit
import Quartz
import WebKit

final class PreviewViewController: NSViewController, QLPreviewingController {

    private var webView: WKWebView!

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.autoresizingMask = [.width, .height]

        let config = WKWebViewConfiguration()
        // No JavaScript, no remote loads beyond what WebKit fetches for CSS/imgs.
        let prefs = WKPreferences()
        prefs.javaScriptCanOpenWindowsAutomatically = false
        config.preferences = prefs

        let wv = WKWebView(frame: container.bounds, configuration: config)
        wv.autoresizingMask = [.width, .height]
        wv.setValue(false, forKey: "drawsBackground")
        container.addSubview(wv)

        self.webView = wv
        self.view = container
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let data = try Data(contentsOf: url)
        let message = EMLParser.parse(data: data)
        let html = Self.renderHTML(for: message)
        await MainActor.run {
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    private static func renderHTML(for m: EMLMessage) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")
        }

        var rows = ""
        func row(_ label: String, _ value: String?) {
            guard let v = value, !v.isEmpty else { return }
            rows += "<tr><td class=\"k\">\(esc(label))</td><td class=\"v\">\(esc(v))</td></tr>"
        }
        row("From", m.from)
        row("To", m.to)
        row("Cc", m.cc)
        row("Date", m.date)
        row("Subject", m.subject)

        let bodyHTML: String
        if let h = m.htmlBody, !h.isEmpty {
            bodyHTML = h
        } else if let t = m.textBody, !t.isEmpty {
            bodyHTML = "<pre style=\"white-space:pre-wrap;font:13px -apple-system,system-ui,sans-serif;\">\(esc(t))</pre>"
        } else {
            bodyHTML = "<p style=\"color:#888\">(no body)</p>"
        }

        var attachmentsHTML = ""
        if !m.attachments.isEmpty {
            let items = m.attachments.map { "<li>\(esc($0.filename)) <span style=\"color:#888\">(\($0.mimeType), \($0.data.count) bytes)</span></li>" }.joined()
            attachmentsHTML = "<h3 style=\"font:600 13px -apple-system;color:#555;margin:16px 0 4px\">Attachments</h3><ul>\(items)</ul>"
        }

        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <style>
          html,body{margin:0;padding:0;background:transparent;color:#111;
            font:14px -apple-system,system-ui,'Helvetica Neue',sans-serif;}
          .wrap{padding:16px 20px;}
          table.h{border-collapse:collapse;margin-bottom:12px;width:100%;}
          table.h td{padding:2px 8px 2px 0;vertical-align:top;}
          td.k{color:#666;font-weight:600;width:80px;}
          td.v{color:#111;}
          hr{border:none;border-top:1px solid #ddd;margin:8px 0 16px;}
          @media (prefers-color-scheme: dark){
            html,body{color:#eee;}
            td.k{color:#aaa;} td.v{color:#eee;}
            hr{border-top-color:#333;}
          }
        </style></head><body><div class="wrap">
          <table class="h">\(rows)</table>
          <hr>
          \(bodyHTML)
          \(attachmentsHTML)
        </div></body></html>
        """
    }
}
