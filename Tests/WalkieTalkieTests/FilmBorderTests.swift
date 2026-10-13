import AppKit
import XCTest
@testable import WalkieTalkie

final class FilmBorderTests: XCTestCase {
    /// `FILM_BORDER_PNG=<dir> swift test --filter FilmBorderTests` — the recording
    /// badge's top-right corner, dot lit, over a light and a dark page.
    func testRenderForReview() throws {
        guard let dir = ProcessInfo.processInfo.environment["FILM_BORDER_PNG"] else { return }
        let size = CGSize(width: 1728, height: 1117), scale: CGFloat = 2
        let view = FilmBorder.content(size: size, menuBar: 33, scale: scale)
        for (name, grey) in [("light", 0.95), ("dark", 0.12)] {
            let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
            ctx.setFillColor(NSColor(white: grey, alpha: 1).cgColor)
            ctx.fill(CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale)))
            ctx.scaleBy(x: scale, y: scale)
            view.layer!.render(in: ctx)
            let full = ctx.makeImage()!
            // The top-right 520 × 200 pt.
            let crop = full.cropping(to: CGRect(x: (size.width - 520) * scale, y: 0, width: 520 * scale, height: 200 * scale))!
            try NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("film-badge-\(name).png"))
        }
    }
}
