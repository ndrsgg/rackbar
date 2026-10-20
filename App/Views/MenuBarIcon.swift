import AppKit

/// The menu bar glyph from Brand/menubar.svg: three rack units, each with its
/// LED knocked out. A problem cuts a notch into the top unit and puts a badge
/// in it. It is a template image, so macOS supplies the colour and the
/// highlighted state, and a badge is the only way to signal anything.
@MainActor
enum MenuBarIcon {
    static let normal = make(problem: false)
    static let problem = make(problem: true)

    /// Drawn on an 18 pt canvas in the SVG's coordinates; every edge lands on
    /// a whole point, so it is sharp at @2x.
    private static func make(problem: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { @Sendable _ in
            draw(problem: problem)
        }
        image.isTemplate = true
        return image
    }

    // AppKit may call this on any thread, whenever it needs a new scale.
    private nonisolated static func draw(problem: Bool) -> Bool {
        guard let context = NSGraphicsContext.current?.cgContext else { return false }
        context.setFillColor(NSColor.black.cgColor)
        for top in [1.0, 7, 13] {
            context.addPath(CGPath(roundedRect: CGRect(x: 2, y: top, width: 14, height: 4),
                                   cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
        }
        context.fillPath()

        context.setBlendMode(.clear)
        for led in [3.0, 9, 15] {
            context.fillEllipse(in: CGRect(x: 3.75, y: led - 1, width: 2, height: 2))
        }
        if problem {
            context.fillEllipse(in: CGRect(x: 11.25, y: -0.75, width: 7.5, height: 7.5))
            context.setBlendMode(.normal)
            context.fillEllipse(in: CGRect(x: 12.5, y: 0.5, width: 5, height: 5))
        }
        return true
    }
}
