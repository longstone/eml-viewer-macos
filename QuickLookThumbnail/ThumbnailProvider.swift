//
//  ThumbnailProvider.swift
//  QuickLookThumbnail
//
//  Generates Finder icons / Quick Look thumbnails for .eml and .msg files.
//

import AppKit
import QuickLookThumbnailing

final class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let url = request.fileURL
        let size = request.maximumSize

        do {
            let data = try Data(contentsOf: url)
            let m = EMLParser.parse(data: data)
            let subject = m.subject ?? "(no subject)"
            let from = m.from ?? ""

            let reply = QLThumbnailReply(contextSize: size) { ctx -> Bool in
                let rect = NSRect(origin: .zero, size: size)
                let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = nsCtx

                // Background card
                NSColor.white.setFill()
                rect.fill()
                NSColor(white: 0.85, alpha: 1).setStroke()
                let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
                border.lineWidth = 1
                border.stroke()

                // Accent bar
                NSColor.systemBlue.setFill()
                NSRect(x: 0, y: rect.height - max(4, rect.height * 0.06),
                       width: rect.width,
                       height: max(4, rect.height * 0.06)).fill()

                // Text
                let pad: CGFloat = max(6, rect.width * 0.06)
                let subjFont = NSFont.systemFont(ofSize: max(10, rect.height * 0.10), weight: .semibold)
                let fromFont = NSFont.systemFont(ofSize: max(8, rect.height * 0.08), weight: .regular)

                let subjAttrs: [NSAttributedString.Key: Any] = [
                    .font: subjFont,
                    .foregroundColor: NSColor.black
                ]
                let fromAttrs: [NSAttributedString.Key: Any] = [
                    .font: fromFont,
                    .foregroundColor: NSColor.darkGray
                ]

                let subjRect = NSRect(
                    x: pad, y: rect.height * 0.55,
                    width: rect.width - pad * 2, height: rect.height * 0.30)
                (subject as NSString).draw(in: subjRect, withAttributes: subjAttrs)

                let fromRect = NSRect(
                    x: pad, y: rect.height * 0.30,
                    width: rect.width - pad * 2, height: rect.height * 0.20)
                (from as NSString).draw(in: fromRect, withAttributes: fromAttrs)

                NSGraphicsContext.restoreGraphicsState()
                return true
            }
            handler(reply, nil)
        } catch {
            handler(nil, error)
        }
    }
}
