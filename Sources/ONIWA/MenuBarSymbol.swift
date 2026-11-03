import AppKit

/// ONIWA's four-stone mark, simplified for a macOS menu bar template image.
///
/// Drawn as vector shapes (no PNG scaling or antialiased black background).
/// The image uses opaque black as the mask and has a transparent background;
/// isTemplate lets macOS choose the proper ink color in light/dark appearances.
/// Deliberately omit the fine sand ripples, which disappear at menu bar size.
@MainActor
enum MenuBarSymbol {
    static func makeImage() -> NSImage {
        let icon = NSImage(
            size: NSSize(width: 18, height: 18),
            flipped: false
        ) { rect in
            NSColor.black.setFill()

            // Paths below use a 100×100 top-left-origin reference design.
            // This keeps the proportions identical at both 1× and Retina sizes.
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(
                    x: rect.minX + rect.width * x / 100,
                    y: rect.maxY - rect.height * y / 100
                )
            }

            // The larger upper-left stone: one organically rounded inner edge.
            let upperLeft = NSBezierPath()
            upperLeft.move(to: point(10, 57))
            upperLeft.line(to: point(37, 57))
            upperLeft.curve(
                to: point(55, 38),
                controlPoint1: point(48, 57),
                controlPoint2: point(55, 49)
            )
            upperLeft.line(to: point(55, 11))
            upperLeft.curve(
                to: point(54, 10),
                controlPoint1: point(55, 10.33),
                controlPoint2: point(54.67, 10)
            )
            upperLeft.line(to: point(29, 10))
            upperLeft.curve(
                to: point(10, 29),
                controlPoint1: point(18, 10),
                controlPoint2: point(10, 18)
            )
            upperLeft.close()
            upperLeft.fill()

            // Small upper-right stone with its rounded lower-left corner.
            let upperRight = NSBezierPath()
            upperRight.move(to: point(59, 10))
            upperRight.line(to: point(71, 10))
            upperRight.curve(
                to: point(90, 29),
                controlPoint1: point(82, 10),
                controlPoint2: point(90, 18)
            )
            upperRight.line(to: point(90, 34))
            upperRight.curve(
                to: point(88, 36),
                controlPoint1: point(90, 35.33),
                controlPoint2: point(89.33, 36)
            )
            upperRight.line(to: point(70, 36))
            upperRight.curve(
                to: point(59, 26),
                controlPoint1: point(63, 36),
                controlPoint2: point(59, 32)
            )
            upperRight.close()
            upperRight.fill()

            // Lower-left stone; keep a clear negative-space gap between tiles.
            let lowerLeft = NSBezierPath()
            lowerLeft.move(to: point(10, 61))
            lowerLeft.line(to: point(33, 61))
            lowerLeft.curve(
                to: point(50, 78),
                controlPoint1: point(45, 61),
                controlPoint2: point(50, 69)
            )
            lowerLeft.line(to: point(50, 89))
            lowerLeft.curve(
                to: point(49, 90),
                controlPoint1: point(50, 89.67),
                controlPoint2: point(49.67, 90)
            )
            lowerLeft.line(to: point(29, 90))
            lowerLeft.curve(
                to: point(10, 71),
                controlPoint1: point(18, 90),
                controlPoint2: point(10, 82)
            )
            lowerLeft.close()
            lowerLeft.fill()

            // Larger lower-right stone. No sand ripples at 18 pt.
            let lowerRight = NSBezierPath()
            lowerRight.move(to: point(53, 90))
            lowerRight.line(to: point(71, 90))
            lowerRight.curve(
                to: point(90, 71),
                controlPoint1: point(82, 90),
                controlPoint2: point(90, 82)
            )
            lowerRight.line(to: point(90, 40))
            lowerRight.curve(
                to: point(88, 38),
                controlPoint1: point(90, 38.67),
                controlPoint2: point(89.33, 38)
            )
            lowerRight.line(to: point(73, 38))
            lowerRight.curve(
                to: point(53, 58),
                controlPoint1: point(62, 38),
                controlPoint2: point(53, 46)
            )
            lowerRight.close()
            lowerRight.fill()

            return true
        }
        icon.isTemplate = true
        return icon
    }
}
