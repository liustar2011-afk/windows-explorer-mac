import SwiftUI
import AppKit

// Fluent-inspired surfaces, accents and typography for the native Mac interface.
enum Win {

    // MARK: - Appearance

    static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private static func c(_ hex: UInt32, _ a: Double = 1) -> Color {
        Color(.sRGB,
              red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255,
              opacity: a)
    }

    /// Picks between a dark-theme and light-theme value.
    static func dyn(_ dark: Color, _ light: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(dark) : NSColor(light)
        })
    }

    // MARK: - Surfaces

    /// Mica-like tab strip behind the caption buttons.
    static let tabStrip     = dyn(c(0x1C1D20), c(0xE8EBF0))
    /// The selected tab, which visually merges into the toolbar.
    static let tabActive    = dyn(c(0x2D3036), c(0xFFFFFF))
    static let tabHover     = dyn(c(0x272727), c(0xF2F2F2))
    /// Address-bar row + command bar.
    static let chrome       = dyn(c(0x25272C), c(0xF4F6F9))
    static let sidebar      = dyn(c(0x23252A), c(0xF1F3F7))
    static let content      = dyn(c(0x1C1E22), c(0xFFFFFF))
    static let statusBar    = dyn(c(0x23252A), c(0xF4F6F9))
    static let flyout       = dyn(c(0x2C2C2C), c(0xF9F9F9))
    static let dialog       = dyn(c(0x272727), c(0xF9F9F9))

    // MARK: - Controls

    /// Address bar / search box field fill.
    static let field        = dyn(c(0x30333A), c(0xFFFFFF))
    static let fieldHover   = dyn(c(0x323232), c(0xFAFAFA))
    static let fieldFocus   = dyn(c(0x1F1F1F), c(0xFFFFFF))
    static let controlFill  = dyn(c(0xFFFFFF, 0.061), c(0xFFFFFF, 0.70))

    /// Subtle button states (toolbar buttons, list rows).
    static let subtleHover  = dyn(c(0xFFFFFF, 0.061), c(0x000000, 0.037))
    static let subtlePress  = dyn(c(0xFFFFFF, 0.042), c(0x000000, 0.024))
    static let alternatingRow = dyn(c(0xFFFFFF, 0.045), c(0x000000, 0.028))
    /// Distinct from alternating stripes while staying quieter than selection.
    static let fileRowHover = dyn(c(0xFFFFFF, 0.10), c(0x000000, 0.07))
    static var selected: Color { accent.opacity(isDark ? 0.18 : 0.10) }
    static var selectedHover: Color { accent.opacity(isDark ? 0.24 : 0.16) }

    // MARK: - Strokes

    static let stroke       = dyn(c(0xFFFFFF, 0.093), c(0x000000, 0.073))
    static let strokeStrong = dyn(c(0xFFFFFF, 0.16), c(0x000000, 0.16))
    static let divider      = dyn(c(0xFFFFFF, 0.083), c(0x000000, 0.060))
    static let cardStroke   = dyn(c(0x000000, 0.20), c(0x000000, 0.058))

    // MARK: - Text

    static let text         = dyn(c(0xFFFFFF), c(0x000000, 0.894))
    static let textSecondary = dyn(c(0xFFFFFF, 0.786), c(0x000000, 0.606))
    static let textTertiary = dyn(c(0xFFFFFF, 0.544), c(0x000000, 0.446))
    static let textDisabled = dyn(c(0xFFFFFF, 0.363), c(0x000000, 0.362))
    static let textOnAccent = dyn(c(0x000000), c(0xFFFFFF))

    // MARK: - Accent

    static var accent: Color {
        let a = Settings.shared.accent
        return dyn(Color(hex: a.dark), Color(hex: a.light))
    }
    static var accentSecondary: Color { accent.opacity(0.88) }
    static var accentText: Color { accent }

    // MARK: - Caption buttons

    static let captionHover = dyn(c(0xFFFFFF, 0.0605), c(0x000000, 0.0373))
    static let closeHover   = c(0xC42B1C)
    static let closePress   = c(0xC42B1C, 0.9)

    // MARK: - Semantic

    static let folderTop    = c(0xFFD75E)
    static let folderBody   = c(0xFFCE44)
    static let folderTab    = c(0xE0A100)
    static let danger       = dyn(c(0xFF99A4), c(0xC42B1C))

    // MARK: - Metrics (device-independent points)

    enum M {
        static let tabStripHeight: CGFloat = 40
        static let navBarHeight: CGFloat = 48
        static let commandBarHeight: CGFloat = 48
        static let statusBarHeight: CGFloat = 26
        static let sidebarWidth: CGFloat = 190
        static let rowHeight: CGFloat = 24
        static let corner: CGFloat = 6
        static let cardCorner: CGFloat = 8
    }

    // MARK: - Type ramp

    /// System typography provides consistent Latin and Chinese font fallback.
    static func body(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static let uiFontName: String = {
        for candidate in ["Segoe UI Variable Text", "Segoe UI", "SF Pro Text", "Helvetica Neue"] {
            if NSFont(name: candidate, size: 12) != nil { return candidate }
        }
        return "Helvetica Neue"
    }()
}

/// Rounded rect matching Win11's corner radii.
struct WinRR: Shape, InsettableShape {
    var radius: CGFloat = Win.M.corner
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect.insetBy(dx: insetAmount, dy: insetAmount),
             cornerRadius: max(0, radius - insetAmount), style: .continuous)
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}
