import SwiftUI
import AppKit
import ApplicationServices
import CoreGraphics

/// Optionally consumes clicks on Finder's Dock icon and activates File Explorer
/// instead. This is deliberately separate from LaunchServices / NSFileViewer:
/// those route folder and reveal requests, while the Dock icon is owned by Dock.
final class FinderDockInterceptor: ObservableObject {
    static let shared = FinderDockInterceptor()

    private static let defaultsKey = "interceptFinderDockClick"
    private static let finderBundleID = "com.apple.finder"
    private static let applicationDockSubrole = "AXApplicationDockItem"

    @Published private(set) var enabled: Bool
    @Published private(set) var running = false
    @Published private(set) var accessibilityTrusted = false
    @Published private(set) var error: String?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    private init() {
        enabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        accessibilityTrusted = AXIsProcessTrusted()
    }

    deinit { stop() }

    func setEnabled(_ newValue: Bool) {
        enabled = newValue
        UserDefaults.standard.set(newValue, forKey: Self.defaultsKey)
        error = nil

        if newValue {
            requestAccessibilityAndStart()
        } else {
            stop()
        }
    }

    /// Called once the app has a run loop. It never prompts on launch.
    func resumeIfEnabled() {
        refreshPermission()
        guard enabled, accessibilityTrusted else { return }
        _ = start()
    }

    func refreshPermission() {
        let trusted = AXIsProcessTrusted()
        accessibilityTrusted = trusted

        if !trusted {
            if running { stop() }
            if enabled {
                error = L("Accessibility permission is required to intercept the Finder Dock icon.")
            }
        } else if enabled && !running {
            _ = start()
        }
    }

    func requestAccessibilityAndStart() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)

        guard accessibilityTrusted else {
            error = L("Allow File Explorer in Privacy & Security → Accessibility, then return here.")
            return
        }
        _ = start()
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    private func start() -> Bool {
        guard enabled else { return false }
        guard tap == nil else {
            running = true
            return true
        }
        guard AXIsProcessTrusted() else {
            accessibilityTrusted = false
            running = false
            error = L("Accessibility permission is required to intercept the Finder Dock icon.")
            return false
        }

        let mask = CGEventMask(1) << CGEventMask(CGEventType.leftMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let interceptor = Unmanaged<FinderDockInterceptor>
                .fromOpaque(refcon)
                .takeUnretainedValue()
            return interceptor.handle(type: type, event: event)
        }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            running = false
            error = L("Could not install the Dock click interceptor. Check Accessibility permission and restart File Explorer.")
            return false
        }

        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            running = false
            error = L("Could not install the Dock click interceptor.")
            return false
        }

        tap = port
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        accessibilityTrusted = true
        running = true
        error = nil
        return true
    }

    private func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        running = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type == .leftMouseDown, enabled else {
            return Unmanaged.passUnretained(event)
        }

        guard isFinderDockClick(at: event.location) else {
            return Unmanaged.passUnretained(event)
        }

        // Keep the event-tap callback short. Activating the app happens on the
        // main queue after the Finder click has already been consumed.
        DispatchQueue.main.async {
            if let model = AppState.shared.activeModel {
                AppState.shared.bringForward(model)
            } else {
                AppState.shared.openNewWindow()
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        return nil
    }

    private func isFinderDockClick(at point: CGPoint) -> Bool {
        let system = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            system, Float(point.x), Float(point.y), &hit
        ) == .success, let hit else {
            return false
        }

        let subrole = Self.stringAttribute("AXSubrole" as CFString, from: hit)
        let title = Self.stringAttribute("AXTitle" as CFString, from: hit)
        let url = Self.urlAttribute("AXURL" as CFString, from: hit)
        return Self.matchesFinderDockItem(subrole: subrole, title: title, url: url)
    }

    /// Kept pure so identity matching can be covered by the existing self-test.
    static func matchesFinderDockItem(subrole: String?, title: String?, url: URL?) -> Bool {
        guard subrole == applicationDockSubrole else { return false }

        if let url {
            if Bundle(url: url)?.bundleIdentifier == finderBundleID { return true }
            if url.lastPathComponent.caseInsensitiveCompare("Finder.app") == .orderedSame {
                return true
            }
        }

        // URL / bundle identity is preferred. Titles are only a fallback for
        // Dock versions that do not expose AXURL.
        let fallbackTitles = ["Finder", "访达"]
        return title.map { candidate in
            fallbackTitles.contains { $0.caseInsensitiveCompare(candidate) == .orderedSame }
        } ?? false
    }

    private static func stringAttribute(_ name: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value as? String
    }

    private static func urlAttribute(_ name: CFString, from element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success,
              let value else { return nil }
        if let url = value as? URL { return url }
        if let string = value as? String {
            if let url = URL(string: string), url.scheme != nil { return url }
            if string.hasPrefix("/") { return URL(fileURLWithPath: string) }
        }
        return nil
    }
}
