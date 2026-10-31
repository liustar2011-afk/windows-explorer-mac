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

    // Quiet neutrals: warm paper in light mode, graphite in dark. Hierarchy
    // comes from tone and soft shadow rather than lines; colour is reserved
    // for the accent. Three tiers: tab strip, workspace, then toolbar and card.

    /// Tab strip behind the caption buttons, tinted like a Chrome frame.
    static let tabStrip     = dyn(c(0x1B1A1A), c(0xEFE3DB))
    /// Active tab, address row and command bar share one colour, as in Chrome.
    static let tabActive    = dyn(c(0x2E2C2B), c(0xFDFAF8))
    static let tabHover     = dyn(c(0xFFFFFF, 0.06), c(0xFFFFFF, 0.50))
    static let tabSeparator = dyn(c(0xFFFFFF, 0.14), c(0x5A4034, 0.22))
    static let chrome       = dyn(c(0x2E2C2B), c(0xFDFAF8))
    static let commandBar   = dyn(c(0x2E2C2B), c(0xFDFAF8))
    static let listHeader   = dyn(c(0x1D1D20), c(0xFFFFFF))
    static let sidebar      = dyn(c(0x19191B), c(0xF3F2EF))
    static let workspace    = dyn(c(0x19191B), c(0xF3F2EF))
    static let surfaceShadow = dyn(c(0x000000, 0.40), c(0x3A3428, 0.07))
    static let content      = dyn(c(0x1D1D20), c(0xFFFFFF))
    static let statusBar    = dyn(c(0x19191B), c(0xF3F2EF))
    static let flyout       = dyn(c(0x2A2A2D), c(0xFDFDFC))
    static let dialog       = dyn(c(0x262629), c(0xFDFDFC))

    // MARK: - Controls

    /// Address bar / search box: borderless wells; a stroke appears only on focus.
    static let field        = dyn(c(0xFFFFFF, 0.06), c(0x000000, 0.04))
    static let fieldHover   = dyn(c(0xFFFFFF, 0.09), c(0x000000, 0.06))
    static let fieldFocus   = dyn(c(0x18181A), c(0xFFFFFF))
    static let controlFill  = dyn(c(0xFFFFFF, 0.06), c(0xFFFFFF, 0.70))

    /// Subtle button states (toolbar buttons, list rows).
    static let subtleHover  = dyn(c(0xFFFFFF, 0.055), c(0x000000, 0.04))
    static let subtlePress  = dyn(c(0xFFFFFF, 0.04), c(0x000000, 0.03))
    static let alternatingRow = dyn(c(0xFFFFFF, 0.018), c(0x000000, 0.018))
    /// Selection is a soft accent wash; text keeps its own colour.
    static var currentRow: Color { accent.opacity(isDark ? 0.26 : 0.14) }
    static let selectionText = dyn(c(0xF4F4F5), c(0x17191C))
    static let fileRowHover = dyn(c(0xFFFFFF, 0.045), c(0x000000, 0.03))
    static var selected: Color { accent.opacity(isDark ? 0.18 : 0.10) }
    static var selectedHover: Color { accent.opacity(isDark ? 0.24 : 0.16) }
    /// Sidebar selection stays neutral; the accent marker carries the colour.
    static let navSelected  = dyn(c(0xFFFFFF, 0.08), c(0x000000, 0.055))

    // MARK: - Strokes

    static let stroke       = dyn(c(0xFFFFFF, 0.08), c(0x000000, 0.07))
    static let strokeStrong = dyn(c(0xFFFFFF, 0.14), c(0x000000, 0.14))
    static let divider      = dyn(c(0xFFFFFF, 0.07), c(0x000000, 0.06))
    static let cardStroke   = dyn(c(0xFFFFFF, 0.06), c(0x000000, 0.06))

    // MARK: - Text

    static let text         = dyn(c(0xECECEE), c(0x1F2124))
    static let textSecondary = dyn(c(0xA9AAB0), c(0x5E6066))
    static let fileMetadata = dyn(c(0x8E9096), c(0x7B7D83))
    static let textTertiary = dyn(c(0xFFFFFF, 0.50), c(0x000000, 0.45))
    static let textDisabled = dyn(c(0xFFFFFF, 0.32), c(0x000000, 0.30))
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

    /// Named text roles, so each role's size is set in one place.
    enum TextStyle {
        /// Hints, paths, counts and timestamps.
        case caption
        /// Descriptions, settings section labels and the status bar.
        case secondary
        /// Labels on dialog and settings buttons.
        case control
        /// Window chrome, sidebar, command bar and file metadata.
        case body
        /// File and folder names.
        case item
        /// Section headings.
        case heading
        /// Page titles.
        case title

        var size: CGFloat {
            switch self {
            case .caption: return 11
            case .secondary, .control: return 12
            case .body: return 13
            case .item, .heading: return 14
            case .title: return 16
            }
        }
    }

    /// Multiplier from the Text size setting.
    static var textScale: CGFloat { Settings.shared.textSize.scale }

    /// System typography provides consistent Latin and Chinese font fallback.
    static func font(_ style: TextStyle, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: style.size * textScale, weight: weight, design: design)
    }

    /// The AppKit equivalent of `font(_:)`, for text fields.
    static func nsFont(_ style: TextStyle) -> NSFont {
        .systemFont(ofSize: style.size * textScale)
    }

    /// Scales a height that holds a line of text, so larger text keeps its room.
    static func scaled(_ value: CGFloat) -> CGFloat {
        (value * textScale).rounded()
    }
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
