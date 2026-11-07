import SwiftUI
import AppKit

// Liquid glass for the window frame: the desktop blurs through the chrome, and a
// specular highlight slides toward the pointer. The file list stays opaque so
// names remain readable. Turn it off in Settings → Appearance, or with
// WINEXP_LIQUID_GLASS=0. Reduced Transparency draws the solid WinUI surfaces.

enum GlassRole {
    case titlebar, toolbar, sidebar, workspace, status, menu, dialog

    var solid: Color {
        switch self {
        case .titlebar: return Win.tabStrip
        case .toolbar: return Win.chrome
        case .sidebar: return Win.sidebar
        case .workspace: return Win.workspace
        case .status: return Win.statusBar
        case .menu: return Win.flyout
        case .dialog: return Win.dialog
        }
    }

    var material: NSVisualEffectView.Material {
        switch self {
        case .titlebar, .toolbar, .status: return .hudWindow
        case .sidebar: return .sidebar
        case .workspace: return .underWindowBackground
        case .menu, .dialog: return .popover
        }
    }

    /// How much of the WinUI colour sits on top of the blur.
    var tintAlpha: Double {
        let dark = Win.isDark
        switch self {
        case .titlebar: return dark ? 0.66 : 0.74
        case .toolbar: return dark ? 0.62 : 0.70
        case .sidebar: return dark ? 0.68 : 0.74
        case .workspace: return dark ? 0.42 : 0.50
        case .status: return dark ? 0.68 : 0.76
        case .menu: return dark ? 0.74 : 0.82
        case .dialog: return dark ? 0.72 : 0.80
        }
    }

    var sheen: Double {
        switch self {
        case .titlebar, .toolbar, .menu, .dialog: return 1
        case .sidebar: return 0.85
        case .workspace: return 0.65
        case .status: return 0.55
        }
    }

    /// Floating plates get a rim. Full-bleed bars stay quiet so the frame reads as one sheet.
    var rim: GlassRim {
        switch self {
        case .menu, .dialog: return .rounded
        case .titlebar, .toolbar, .sidebar, .workspace, .status: return .none
        }
    }
}

enum GlassRim { case none, rounded }

enum LiquidGlass {
    /// True when the setting is on and the system is not asking for solid surfaces.
    static func enabled(_ settings: Settings) -> Bool {
        settings.liquidGlass && !DisplayAccess.shared.reduceTransparency
    }
}

/// Tracks the pointer in window coordinates whose origin is the top-left,
/// matching the "root" SwiftUI space.
final class LiquidPointer: ObservableObject {
    static let shared = LiquidPointer()
    @Published private(set) var points: [ObjectIdentifier: CGPoint] = [:]
    private var monitor: Any?
    private var lastStamp: [ObjectIdentifier: TimeInterval] = [:]

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        ) { [weak self] event in
            self?.ingest(event)
            return event
        }
    }

    func point(for window: ObjectIdentifier?) -> CGPoint? {
        guard let window else { return nil }
        return points[window]
    }

    private func ingest(_ event: NSEvent) {
        guard Settings.shared.liquidGlass else { return }
        guard let window = event.window as? ExplorerWindow else { return }
        guard let height = window.contentView?.bounds.height, height > 0 else { return }
        let id = ObjectIdentifier(window)
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastStamp[id], now - last < 1.0 / 45 { return }
        let next = CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
        if let previous = points[id], hypot(previous.x - next.x, previous.y - next.y) < 1.2 { return }
        lastStamp[id] = now
        points[id] = next
    }
}

final class DisplayAccess: ObservableObject {
    static let shared = DisplayAccess()
    @Published private(set) var reduceTransparency: Bool
    @Published private(set) var reduceMotion: Bool
    private var observer: NSObjectProtocol?

    private init() {
        let workspace = NSWorkspace.shared
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        observer = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
            self.reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        }
    }
}

private struct ExplorerWindowIDKey: EnvironmentKey {
    static let defaultValue: ObjectIdentifier? = nil
}

extension EnvironmentValues {
    var explorerWindowID: ObjectIdentifier? {
        get { self[ExplorerWindowIDKey.self] }
        set { self[ExplorerWindowIDKey.self] = newValue }
    }
}

/// Full-bleed or clipped fill. Draws the previous solid (or lightly blurred)
/// surface when Liquid Glass is off.
struct GlassPlate: View {
    var role: GlassRole
    var radius: CGFloat = 0

    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var display = DisplayAccess.shared

    private var glass: Bool { settings.liquidGlass && !display.reduceTransparency }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            if glass {
                BackdropMaterial(material: role.material, emphasized: true)
                shape.fill(role.solid.opacity(role.tintAlpha))
                GlassSheen(strength: role.sheen)
                rim(shape)
            } else {
                legacy
            }
        }
        .clipShape(shape)
        .allowsHitTesting(false)
    }

    @ViewBuilder private var legacy: some View {
        switch role {
        case .titlebar:
            BackdropMaterial(material: .titlebar)
                .overlay(Win.tabStrip.opacity(0.94))
        case .sidebar:
            BackdropMaterial(material: .sidebar)
                .overlay(Win.sidebar.opacity(0.96))
        default:
            role.solid
        }
    }

    @ViewBuilder private func rim(_ shape: RoundedRectangle) -> some View {
        if role.rim == .rounded {
            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(Win.isDark ? 0.42 : 0.82),
                        Color.white.opacity(Win.isDark ? 0.06 : 0.18),
                        Color.white.opacity(Win.isDark ? 0.22 : 0.45)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        }
    }
}

/// Menus and other floating panels: glass fill, rim, and a soft ground shadow.
struct FloatingGlass: View {
    var role: GlassRole = .menu
    var radius: CGFloat = 8
    var shadowColor: Color = Win.menuShadow
    var shadowRadius: CGFloat = 10
    var shadowY: CGFloat = 4

    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var display = DisplayAccess.shared

    private var glass: Bool { settings.liquidGlass && !display.reduceTransparency }

    var body: some View {
        ZStack {
            if glass {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.black.opacity(Win.isDark ? 0.40 : 0.16))
                    .blur(radius: 14)
                    .offset(y: 8)
                GlassPlate(role: role, radius: radius)
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(role.solid)
                    .shadow(color: shadowColor, radius: shadowRadius, y: shadowY)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .stroke(Win.stroke, lineWidth: 1)
                    )
            }
        }
        .allowsHitTesting(false)
    }
}

/// Specular blob and lip highlight. Each plate clips its own copy, so adjacent
/// bars reconstruct one continuous highlight.
struct GlassSheen: View {
    var strength: Double = 1
    @ObservedObject private var pointer = LiquidPointer.shared
    @ObservedObject private var display = DisplayAccess.shared
    @Environment(\.explorerWindowID) private var windowID

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .named("root"))
            let size = geo.size
            let target = pointer.point(for: windowID)
                ?? CGPoint(x: frame.minX + size.width * 0.32, y: frame.minY + min(22, size.height * 0.4))
            let local = CGPoint(
                x: min(max(target.x - frame.minX, 0), max(size.width, 1)),
                y: min(max(target.y - frame.minY, 0), max(size.height, 1))
            )
            let near = proximity(of: target, to: frame) * strength
            let dark = Win.isDark
            ZStack {
                LinearGradient(
                    colors: [Color.white.opacity((dark ? 0.07 : 0.22) * strength), .clear],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.72)
                )
                Ellipse()
                    .fill(RadialGradient(
                        colors: [
                            Color.white.opacity((dark ? 0.20 : 0.48) * near),
                            Color.white.opacity(0)
                        ],
                        center: .center, startRadius: 0, endRadius: 120
                    ))
                    .frame(width: 300, height: 170)
                    .blur(radius: 12)
                    .position(local)
                Capsule()
                    .fill(LinearGradient(
                        colors: [
                            .clear,
                            Color.white.opacity((dark ? 0.55 : 0.85) * near),
                            .clear
                        ],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(width: min(max(size.width * 0.38, 42), 260), height: 2)
                    .blur(radius: 0.5)
                    .position(x: local.x, y: size.height < 72 ? 1.1 : local.y)
            }
            .animation(display.reduceMotion ? nil : .spring(response: 0.52, dampingFraction: 0.78),
                       value: local.x)
            .animation(display.reduceMotion ? nil : .spring(response: 0.52, dampingFraction: 0.78),
                       value: local.y)
        }
        .clipped()
        .allowsHitTesting(false)
    }

    private func proximity(of point: CGPoint, to frame: CGRect) -> Double {
        let dx = max(frame.minX - point.x, point.x - frame.maxX, CGFloat.zero)
        let dy = max(frame.minY - point.y, point.y - frame.maxY, CGFloat.zero)
        let distance = hypot(dx, dy)
        if distance <= 28 { return 1 }
        return max(0.18, 1 - Double(distance) / 520)
    }
}

/// Inset well for the address bar and search field.
struct GlassField: View {
    var radius: CGFloat = 8
    var hovering: Bool
    var focused: Bool

    var body: some View {
        let dark = Win.isDark
        let fill: Color = {
            if focused { return dark ? Color.black.opacity(0.42) : Color.white.opacity(0.84) }
            if hovering { return dark ? Color.white.opacity(0.10) : Color.white.opacity(0.58) }
            return dark ? Color.white.opacity(0.06) : Color.black.opacity(0.045)
        }()
        WinRR(radius: radius)
            .fill(fill)
            .overlay(
                WinRR(radius: radius).stroke(
                    focused ? Win.accent.opacity(0.85) : Color.white.opacity(dark ? 0.18 : 0.62),
                    lineWidth: focused ? 1.25 : 0.8
                )
            )
            .overlay {
                WinRR(radius: radius)
                    .stroke(Color.white.opacity(dark ? 0.10 : 0.45), lineWidth: 0.6)
                    .padding(0.6)
                    .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center))
            }
            .allowsHitTesting(false)
    }
}

struct GlassCardRim: View {
    var radius: CGFloat
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var display = DisplayAccess.shared

    var body: some View {
        let shape = WinRR(radius: radius)
        if settings.liquidGlass && !display.reduceTransparency {
            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(Win.isDark ? 0.34 : 0.82),
                        Win.cardStroke,
                        Color.white.opacity(Win.isDark ? 0.08 : 0.24)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        } else {
            shape.strokeBorder(Win.cardStroke, lineWidth: 1)
        }
    }
}
