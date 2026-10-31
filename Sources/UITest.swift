import AppKit
import SwiftUI

/// Drives a real window with synthetic mouse and keyboard events, so each step
/// travels through the same event monitors, SwiftUI gestures and text fields a
/// user's click would. SelfTest calls the model directly and cannot catch bugs
/// that only show up in the UI, such as a rename field selecting the wrong text.
///
/// Run with WINEXP_UITEST=1; the app prints results and exits. Set
/// WINEXP_UITEST_SHOTS=<dir> to also save light and dark screenshots of the main
/// states for visual review. The window need not be frontmost: ExplorerHostingView
/// accepts first clicks during the test, so you can keep working elsewhere.
enum UITest {

    private static var passed = 0
    private static var failed = 0
    private static var steps: [(delay: Double, run: (@escaping () -> Void) -> Void)] = []
    private static var root: URL!
    private static let fm = FileManager.default

    private static var ex: Explorer { AppState.shared.active! }
    private static var window: NSWindow? {
        NSApp.windows.first { AppState.shared.explorer(for: $0) != nil && $0.isVisible }
    }

    // MARK: Entry

    static func run() {
        setvbuf(stdout, nil, _IONBF, 0)
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("winexp-uitest-\(getpid())")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        // The app lists /var paths as /private/var; match it so item ids line up.
        // (URL.resolvingSymlinksInPath strips /private again, so use realpath.)
        if let real = realpath(root.path, nil) { root = URL(fileURLWithPath: String(cString: real)); free(real) }
        for name in ["alpha.txt", "beta.txt", "gamma.txt"] {
            fm.createFile(atPath: path(name), contents: Data(name.utf8))
        }
        try? fm.createDirectory(atPath: path("Folder A"), withIntermediateDirectories: true)

        guard AppState.shared.active != nil, let window else {
            print("FAIL: no explorer window"); exit(1)
        }
        // A fixed size keeps menus and rows where the steps expect them.
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.makeKeyAndOrderFront(nil)
        Prefs.shared.viewMode = .details
        ex.go(to: root)

        newItemCases()
        renameCases()
        selectionCases()
        openCases()
        if let dir = ProcessInfo.processInfo.environment["WINEXP_UITEST_SHOTS"] {
            screenshotCases(into: URL(fileURLWithPath: dir))
        }
        step(0.1) {
            try? fm.removeItem(at: root)
            print("\n\(passed) passed, \(failed) failed")
            exit(failed == 0 ? 0 : 1)
        }
        next()
    }

    // MARK: Cases

    /// Right-click > New > each item: the file appears, rename starts with the
    /// right part selected, and typing a name plus Enter renames it.
    private static func newItemCases() {
        newItem(L("Folder"), created: "New folder", selected: "New folder",
                typed: "Projects", expect: "Projects")
        newItem(L("Text Document"), created: "New Text Document.txt", selected: "New Text Document",
                typed: "notes", expect: "notes.txt")
        newItem(L("Rich Text Document"), created: "New Rich Text Document.rtf",
                selected: "New Rich Text Document", typed: "letter", expect: "letter.rtf")
    }

    private static func newItem(_ entry: String, created: String, selected: String,
                                typed: String, expect: String) {
        openNewSubmenu()
        step { click(menuItem: entry) }
        step(0.5) {
            check("New > \(entry) creates \(created)", fm.fileExists(atPath: path(created)))
            check("New > \(entry) starts rename", ex.tab.editing == path(created))
            let (text, range) = editor()
            check("New > \(entry) selects \"\(selected)\"",
                  text.map { ($0 as NSString).substring(with: range) } == selected)
            type(typed); key(.return)
        }
        step(0.5) {
            check("New > \(entry) renames to \(expect) on Enter",
                  fm.fileExists(atPath: path(expect)) && !fm.fileExists(atPath: path(created)))
            check("New > \(entry) leaves rename mode", ex.tab.editing == nil)
        }
    }

    private static func renameCases() {
        // Clicking elsewhere commits, as in Explorer.
        openNewSubmenu()
        step { click(menuItem: L("Text Document")) }
        step(0.5) { type("committed") }
        step { click(emptySpace()) }
        step(0.5) {
            check("clicking away commits the rename", fm.fileExists(atPath: path("committed.txt")))
            check("clicking away leaves rename mode", ex.tab.editing == nil)
        }

        // F2 then Esc keeps the old name.
        step { click(row("alpha.txt")) }
        step { key(.f2) }
        step(0.4) {
            check("F2 starts rename on the selected file", ex.tab.editing == path("alpha.txt"))
            type("changed"); key(.escape)
        }
        step(0.4) {
            check("Esc cancels rename", ex.tab.editing == nil
                  && fm.fileExists(atPath: path("alpha.txt")) && !fm.fileExists(atPath: path("changed.txt")))
        }
    }

    private static func selectionCases() {
        step { click(row("alpha.txt")) }
        step { click(row("gamma.txt"), modifiers: .command) }
        step {
            check("click selects and Cmd-click adds",
                  ex.tab.selection == [path("alpha.txt"), path("gamma.txt")])
        }
        step { click(emptySpace()) }
        step { check("clicking empty space clears the selection", ex.tab.selection.isEmpty) }

        // A band dragged from empty space across rows selects them.
        step {
            guard let a = row("alpha.txt"), let b = row("beta.txt") else {
                check("rows for the selection band", false); return
            }
            let start = CGPoint(x: a.x + 260, y: emptySpace()!.y)
            mouse(.leftMouseDown, at: start)
            mouse(.leftMouseDragged, at: CGPoint(x: start.x - 20, y: (a.y + b.y) / 2))
            mouse(.leftMouseDragged, at: CGPoint(x: start.x - 40, y: a.y))
            mouse(.leftMouseUp, at: CGPoint(x: start.x - 40, y: a.y))
        }
        step(0.4) {
            check("dragging a band selects the rows it crosses",
                  ex.tab.selection.contains(path("alpha.txt")) && ex.tab.selection.contains(path("beta.txt")))
        }
    }

    private static func openCases() {
        step { doubleClick(row("Folder A")) }
        step(0.5) { check("double-clicking a folder opens it", ex.currentDirectory?.path == path("Folder A")) }
        step { ex.back() }
        step(0.4) { check("back returns to the parent", ex.currentDirectory?.path == root.path) }

        // Switching tabs must respond at once, not after a double-click timeout.
        step { ex.openTab(.folder(URL(fileURLWithPath: path("Folder A")))) }
        asyncStep(0.5) { done in
            let first = ex.tabs.firstIndex { $0.location == .folder(root) } ?? 0
            click(anchor("tab:\(root.lastPathComponent)"))
            waitUntil({ ex.active == first }) { elapsed in
                let ms = elapsed.map { Int($0 * 1000) }
                check("clicking a tab switches to it within 150 ms [\(ms.map { "\($0) ms" } ?? "never")]",
                      (ms ?? .max) <= 150)
                done()
            }
        }
        step { ex.closeTab(ex.tabs.count - 1) }

        // A big folder must not make the switch wait on the disk either.
        step {
            let big = root.appendingPathComponent("Big")
            try? fm.createDirectory(at: big, withIntermediateDirectories: true)
            for i in 0..<3000 { fm.createFile(atPath: big.appendingPathComponent("file \(i).txt").path, contents: nil) }
            ex.openTab(.folder(big))
        }
        asyncStep(0.8) { done in
            let first = ex.tabs.firstIndex { $0.location == .folder(root) } ?? 0
            ex.selectTab(first)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let bigTab = ex.tabs.count - 1
                click(anchor("tab:Big"))
                waitUntil({ ex.active == bigTab }) { elapsed in
                    let ms = elapsed.map { Int($0 * 1000) }
                    check("switching to a tab with 3,000 files takes under 110 ms [\(ms.map { "\($0) ms" } ?? "never")]",
                          (ms ?? .max) <= 110)
                    // The background refresh must still land.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        check("the big tab still lists all 3,000 files after the refresh", ex.tab.items.count == 3000)
                        done()
                    }
                }
            }
        }
        step(0.5) { ex.closeTab(ex.tabs.count - 1); try? fm.removeItem(at: root.appendingPathComponent("Big")) }
    }

    /// States worth eyeballing after a design change, in both themes.
    private static func screenshotCases(into dir: URL) {
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Several tabs show the active tab's outline and the dividers between others.
        step {
            for loc in [Location.folder(URL(fileURLWithPath: path("Folder A"))), .thisPC, .gallery] { ex.openTab(loc) }
            ex.selectTab(0)
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            // Set directly rather than through Settings, so the user's theme is not overwritten.
            step { NSApp.appearance = NSAppearance(named: appearance) }
            step(0.6) { snapshot(dir.appendingPathComponent("\(name)-list.png")) }
            step { click(row("alpha.txt")) }
            step { click(row("gamma.txt"), modifiers: .command) }
            step(0.4) { snapshot(dir.appendingPathComponent("\(name)-selection.png")) }
            step { rightClick(emptySpace()) }
            step { click(menuItem: L("New")) }
            step(0.4) { snapshot(dir.appendingPathComponent("\(name)-menu.png")) }
            step { key(.escape) }
            step { click(emptySpace()) }
        }
        step { NSApp.appearance = Settings.shared.theme.appearance }
    }

    private static func openNewSubmenu() {
        step { rightClick(emptySpace()) }
        step { click(menuItem: L("New")) }
    }

    // MARK: Step runner

    private static func step(_ delay: Double = 0.3, _ run: @escaping () -> Void) {
        steps.append((delay, { done in run(); done() }))
    }

    /// A step that finishes when it calls `done`, for waiting on a condition.
    private static func asyncStep(_ delay: Double = 0.3, _ run: @escaping (@escaping () -> Void) -> Void) {
        steps.append((delay, run))
    }

    private static func next() {
        guard !steps.isEmpty else { return }
        let s = steps.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + s.delay) {
            s.run { next() }
        }
    }

    /// Polls until `condition` holds, then reports how long it took.
    private static func waitUntil(timeout: Double = 1.5, _ condition: @escaping () -> Bool,
                                  then report: @escaping (Double?) -> Void) {
        let start = CACurrentMediaTime()
        func poll() {
            let elapsed = CACurrentMediaTime() - start
            if condition() { report(elapsed); return }
            if elapsed > timeout { report(nil); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.005, execute: poll)
        }
        poll()
    }

    private static func check(_ name: String, _ condition: Bool) {
        if condition { passed += 1; print("  PASS  \(name)") }
        else { failed += 1; print("  FAIL  \(name)") }
    }

    // MARK: Locating things (root coordinates: window content, top-left origin)

    private static func path(_ name: String) -> String { root.appendingPathComponent(name).path }

    /// Centre of a file row's name, from the frames rows register for hit-testing.
    private static func row(_ name: String) -> CGPoint? {
        guard let frame = RightClickRouter.shared.itemFrames(for: ex)?[path(name)] else {
            if ProcessInfo.processInfo.environment["WINEXP_UITEST_VERBOSE"] != nil {
                print("        no row \(path(name)); dir=\(ex.currentDirectory?.path ?? "-") items=\(ex.tab.items.map(\.id)) frames=\(RightClickRouter.shared.itemFrames(for: ex)?.keys.sorted() ?? [])")
            }
            return nil
        }
        return CGPoint(x: frame.minX + 60, y: frame.midY)
    }

    /// A point in the file area below the last row.
    private static func emptySpace() -> CGPoint? {
        let area = RightClickRouter.shared.contentFrame(for: ex)
        guard area.height > 0 else { return nil }
        return CGPoint(x: area.minX + area.width * 0.35, y: area.maxY - 40)
    }

    /// Centre of a view marked with `.testAnchor(id)`.
    private static func anchor(_ id: String) -> CGPoint? {
        guard let view = TestAnchor.views.object(forKey: id as NSString),
              !view.isHiddenOrHasHiddenAncestor, view.window === window,
              let content = window?.contentView else { return nil }
        let r = view.convert(view.bounds, to: nil)
        return CGPoint(x: r.midX, y: content.bounds.height - r.midY)
    }

    private static func editor() -> (String?, NSRange) {
        guard let tv = window?.firstResponder as? NSTextView else { return (nil, NSRange()) }
        return (tv.string, tv.selectedRange())
    }

    // MARK: Synthetic input

    private static func mouse(_ type: NSEvent.EventType, at p: CGPoint,
                              clicks: Int = 1, modifiers: NSEvent.ModifierFlags = []) {
        guard let window, let content = window.contentView,
              let e = NSEvent.mouseEvent(with: type, location: NSPoint(x: p.x, y: content.bounds.height - p.y),
                                         modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                         clickCount: clicks, pressure: 1) else { return }
        NSApp.postEvent(e, atStart: false)
    }

    private static func click(_ p: CGPoint?, modifiers: NSEvent.ModifierFlags = []) {
        guard let p else { check("target is on screen", false); return }
        mouse(.leftMouseDown, at: p, modifiers: modifiers)
        mouse(.leftMouseUp, at: p, modifiers: modifiers)
    }

    private static func doubleClick(_ p: CGPoint?) {
        guard let p else { check("target is on screen", false); return }
        mouse(.leftMouseDown, at: p, clicks: 1); mouse(.leftMouseUp, at: p, clicks: 1)
        mouse(.leftMouseDown, at: p, clicks: 2); mouse(.leftMouseUp, at: p, clicks: 2)
    }

    private static func rightClick(_ p: CGPoint?) {
        guard let p else { check("target is on screen", false); return }
        mouse(.rightMouseDown, at: p)
        mouse(.rightMouseUp, at: p)
    }

    private static func click(menuItem label: String) {
        guard let p = anchor("menu:\(label)") else { check("menu item \"\(label)\" is on screen", false); return }
        click(p)
    }

    private enum Key {
        case `return`, escape, f2
        var code: UInt16 { switch self { case .return: 36; case .escape: 53; case .f2: 120 } }
        var chars: String {
            switch self {
            case .return: "\r"
            case .escape: "\u{1b}"
            case .f2: String(Character(UnicodeScalar(NSF2FunctionKey)!))
            }
        }
    }

    private static func key(_ k: Key) { keyEvent(k.chars, code: k.code) }

    private static func type(_ text: String) {
        for ch in text { keyEvent(String(ch), code: 0) }
    }

    private static func keyEvent(_ chars: String, code: UInt16) {
        guard let window else { return }
        for t in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
            else { continue }
            if NSApp.keyWindow === window {
                NSApp.postEvent(e, atStart: false)
                continue
            }
            // An inactive app has no key window, so queued keystrokes go nowhere.
            // Hand them over the way the app would: shortcuts to the same handler
            // its key monitor uses, everything else to the window's responder.
            let r = window.firstResponder
            let editingText = r is NSTextView || r is NSTextField
            if t == .keyDown, Keys.handle(e, ex: ex, editingText: editingText) { continue }
            window.sendEvent(e)
        }
    }

    private static func snapshot(_ url: URL) {
        guard let view = window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// Lets UI tests find a view by id. Inert, and adds nothing to the view tree,
/// unless WINEXP_UITEST is set.
struct TestAnchor: NSViewRepresentable {
    static let enabled = ProcessInfo.processInfo.environment["WINEXP_UITEST"] != nil
    static let views = NSMapTable<NSString, NSView>.strongToWeakObjects()

    let id: String

    final class Marker: NSView {
        var id = ""
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { TestAnchor.views.setObject(self, forKey: id as NSString) }
        }
    }

    func makeNSView(context: Context) -> Marker { let m = Marker(); m.id = id; return m }
    func updateNSView(_ view: Marker, context: Context) {
        view.id = id
        if view.window != nil { TestAnchor.views.setObject(view, forKey: id as NSString) }
    }
}

extension View {
    @ViewBuilder
    func testAnchor(_ id: String) -> some View {
        if TestAnchor.enabled { background(TestAnchor(id: id)) } else { self }
    }
}
