import SwiftUI
import AppKit

// MARK: - Right-click support (Windows-style flyouts instead of AppKit menus)

/// Routes right-clicks to the right target.
///
/// Rather than fighting AppKit hit-testing (which would also swallow the left
/// clicks SwiftUI needs), every context-menu target registers an invisible
/// marker view. A window-level monitor then picks the smallest registered
/// target under the pointer, falling back to the file-area background.
final class RightClickRouter {
    static let shared = RightClickRouter()

    private var previousClick: String?
    private var activationPress: String?

    private let targets = NSHashTable<RightClickCatcher.View>.weakObjects()
    /// Frame of each pane's file area, in root (window, top-left) coordinates.
    private var contentFrames: [ObjectIdentifier: CGRect] = [:]

    func setContentFrame(_ frame: CGRect, for owner: AnyObject) {
        contentFrames[ObjectIdentifier(owner)] = frame
    }

    func contentFrame(for owner: AnyObject) -> CGRect {
        contentFrames[ObjectIdentifier(owner)] ?? .zero
    }

    private var anyContentFrame: (CGPoint) -> Bool {
        { point in self.contentFrames.values.contains { $0.contains(point) } }
    }

    func register(_ view: RightClickCatcher.View) { targets.add(view) }
    func unregister(_ view: RightClickCatcher.View) { targets.remove(view) }

    /// Converts a window-coordinate event location into root coordinates.
    static func rootPoint(_ event: NSEvent) -> CGPoint {
        guard let content = event.window?.contentView else { return event.locationInWindow }
        let p = event.locationInWindow
        return CGPoint(x: p.x, y: content.bounds.height - p.y)
    }

    /// Read native row positions only when selection needs them.
    func itemFrames(for explorer: Explorer) -> [String: CGRect]? {
        let rows = targets.allObjects.filter { $0.selectionOwner === explorer }
        guard !rows.isEmpty else { return nil }
        var frames: [String: CGRect] = [:]
        for row in rows where !row.isHiddenOrHasHiddenAncestor {
            if let id = row.selectionID, let frame = row.rootFrame {
                frames[id] = frame
            }
        }
        return frames
    }

    /// Menu shields take precedence; otherwise pick the smallest target under the pointer.
    func target(at point: CGPoint, in window: NSWindow?) -> RightClickCatcher.View? {
        var best: RightClickCatcher.View?
        var bestArea = CGFloat.greatestFiniteMagnitude
        for view in targets.allObjects {
            guard view.window === window, !view.isHiddenOrHasHiddenAncestor,
                  let frame = view.rootFrame, frame.contains(point) else { continue }
            let area = frame.width * frame.height
            if best == nil || (view.blocksFileSelection && !best!.blocksFileSelection)
                || (view.blocksFileSelection == best!.blocksFileSelection && area < bestArea) {
                bestArea = area; best = view
            }
        }
        return best
    }

    /// Clicking files must stop editing the search/address field so file shortcuts
    /// reach the explorer. Keep inline rename fields in the normal responder chain.
    func focusFileArea(_ event: NSEvent) {
        guard let window = event.window,
              let content = window.contentView else { return }
        let point = Self.rootPoint(event)
        guard contentFrames.values.contains(where: { $0.contains(point) }) else { return }
        func hitsTextEditor(_ view: NSView) -> Bool {
            guard !view.isHiddenOrHasHiddenAncestor else { return false }
            if (view is NSTextView || view is NSTextField),
               view.convert(view.bounds, to: nil).contains(event.locationInWindow) { return true }
            return view.subviews.contains(where: hitsTextEditor)
        }
        if hitsTextEditor(content) { return }
        window.makeFirstResponder(nil)
    }

    /// Update selection on mouse-down without consuming the event: SwiftUI
    /// must still receive it for double-click activation and file dragging.
    func routeSelection(_ event: NSEvent) {
        focusFileArea(event)
        guard event.clickCount == 1,
              let view = target(at: Self.rootPoint(event), in: event.window) else { return }
        guard !view.blocksFileSelection else { return }
        view.onMouseDown?(event)
    }

    /// Use AppKit's click count, independent of SwiftUI row redraws and drag gestures.
    /// Open on release only when both clicks and the release belong to the same file.
    @discardableResult
    func routeActivation(_ event: NSEvent) -> Bool {
        func key(_ view: RightClickCatcher.View?) -> String? {
            guard let view, !view.blocksFileSelection, view.onDoubleClick != nil,
                  let owner = view.selectionOwner, let id = view.selectionID else { return nil }
            return "\(event.windowNumber):\(ObjectIdentifier(owner)):\(owner.tab.id):\(id)"
        }
        switch event.type {
        case .leftMouseDown:
            let clicked = key(target(at: Self.rootPoint(event), in: event.window))
            activationPress = event.clickCount == 2 && clicked == previousClick ? clicked : nil
            previousClick = clicked
        case .leftMouseDragged:
            activationPress = nil
            previousClick = nil
        case .leftMouseUp:
            let pressed = activationPress
            activationPress = nil
            guard event.clickCount == 2, let pressed,
                  let view = target(at: Self.rootPoint(event), in: event.window),
                  key(view) == pressed else { return false }
            view.onDoubleClick?()
            return true
        default: break
        }
        return false
    }

    /// Handles a right-click. Returns true when it was consumed.
    @discardableResult
    func route(_ event: NSEvent) -> Bool {
        focusFileArea(event)
        let point = RightClickRouter.rootPoint(event)
        if let view = target(at: point, in: event.window) {
            view.onClick?(point)
            return true
        }
        if anyContentFrame(point) {
            NotificationCenter.default.post(name: .backgroundContextMenu, object: point)
            return true
        }
        return false
    }
}

struct RightClickCatcher: NSViewRepresentable {
    @ObservedObject private var interfaceSettings = Settings.shared
    let onClick: (CGPoint) -> Void
    var onMouseDown: ((NSEvent) -> Void)? = nil
    var onDoubleClick: (() -> Void)? = nil
    var blocksFileSelection = false
    var selectionOwner: Explorer? = nil
    var selectionID: String? = nil

    final class View: NSView {
        var onClick: ((CGPoint) -> Void)?
        var onMouseDown: ((NSEvent) -> Void)?
        var onDoubleClick: (() -> Void)?
        var blocksFileSelection = false
        weak var selectionOwner: Explorer?
        var selectionID: String?
        override var isFlipped: Bool { true }

        /// Invisible to hit-testing: the router dispatches to it explicitly.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { RightClickRouter.shared.unregister(self) }
            else { RightClickRouter.shared.register(self) }
        }

        /// This view's bounds in root (window, top-left origin) coordinates.
        var rootFrame: CGRect? {
            guard let window, let content = window.contentView else { return nil }
            let inWindow = convert(bounds, to: nil)
            return CGRect(x: inWindow.minX,
                          y: content.bounds.height - inWindow.maxY,
                          width: inWindow.width, height: inWindow.height)
        }
    }

    func makeNSView(context: Context) -> View {
        let v = View(); v.onClick = onClick; v.onMouseDown = onMouseDown; v.onDoubleClick = onDoubleClick
        v.blocksFileSelection = blocksFileSelection
        v.selectionOwner = selectionOwner
        v.selectionID = selectionID
        return v
    }
    func updateNSView(_ nsView: View, context: Context) {
        nsView.onClick = onClick
        nsView.onMouseDown = onMouseDown
        nsView.onDoubleClick = onDoubleClick
        nsView.blocksFileSelection = blocksFileSelection
        nsView.selectionOwner = selectionOwner
        nsView.selectionID = selectionID
    }
}

extension View {
    /// Marks this view as a context-menu target. The marker sits behind the
    /// content and is invisible to SwiftUI hit-testing, so taps, drags and
    /// drops keep working exactly as before.
    func onRightClick(mouseDown: ((NSEvent) -> Void)? = nil,
                      doubleClick: (() -> Void)? = nil,
                      blocksFileSelection: Bool = false,
                      selectionOwner: Explorer? = nil,
                      selectionID: String? = nil,
                      perform: @escaping (CGPoint) -> Void) -> some View {
        background(RightClickCatcher(onClick: perform, onMouseDown: mouseDown, onDoubleClick: doubleClick,
                                     blocksFileSelection: blocksFileSelection,
                                     selectionOwner: selectionOwner,
                                     selectionID: selectionID).allowsHitTesting(false))
    }
}

// MARK: - Content area

struct FileArea: View {
    @ObservedObject private var interfaceSettings = Settings.shared
    @ObservedObject var ex: Explorer
    @ObservedObject var menus: MenuController
    @ObservedObject var prefs = Prefs.shared
    @State private var dropTargeted = false

    var body: some View {
        ZStack {
            Win.content
            if case .home = ex.tab.location, !ex.tab.searching {
                HomeView(ex: ex, menus: menus)
            } else if ex.tab.items.isEmpty {
                EmptyFolderView(ex: ex, menus: menus)
            } else {
                switch prefs.viewMode {
                case .details:
                    DetailsView(ex: ex, menus: menus)
                case .list:
                    ListFlowView(ex: ex, menus: menus)
                case .tiles, .content:
                    TilesView(ex: ex, menus: menus, mode: prefs.viewMode)
                default:
                    IconGridView(ex: ex, menus: menus)
                }
            }
        }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { RightClickRouter.shared.setContentFrame(g.frame(in: .named("root")), for: ex) }
                .onChange(of: g.frame(in: .named("root"))) { _, f in
                    RightClickRouter.shared.setContentFrame(f, for: ex)
                }
        })
        .overlay(
            Rectangle()
                .strokeBorder(Win.accent.opacity(dropTargeted ? 0.85 : 0), lineWidth: 2)
                .animation(.easeOut(duration: 0.15), value: dropTargeted)
                .allowsHitTesting(false)
        )
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let dir = ex.currentDirectory else { return false }
            dropTargeted = false
            return DropHandler.handle(providers: providers, into: dir, ex: ex)
        }
        .onReceive(NotificationCenter.default.publisher(for: .backgroundContextMenu)) { note in
            guard let point = note.object as? CGPoint else { return }
            // Only the pane the click landed in answers.
            guard RightClickRouter.shared.contentFrame(for: ex).contains(point) else { return }
            ex.onInteract?()
            ex.selectNone()
            menus.show(id: "bg", anchor: .zero, entries: ContextMenus.background(ex),
                       width: 250, iconRow: nil, point: point)
        }
    }
}

extension Notification.Name {
    static let backgroundContextMenu = Notification.Name("winexp.bgContextMenu")
}

struct EmptyFolderView: View {
    @ObservedObject private var interfaceSettings = Settings.shared
    @ObservedObject var ex: Explorer
    @ObservedObject var menus: MenuController
    var body: some View {
        VStack(spacing: 6) {
            Text(ex.tab.searching ? L("No items match your search.") : L("This folder is empty."))
                .font(Win.font(.item))
                .foregroundStyle(Win.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}

// MARK: - Selection & activation helpers shared by every view mode

struct ItemInteraction: ViewModifier {
    @ObservedObject private var interfaceSettings = Settings.shared
    @ObservedObject var ex: Explorer
    @ObservedObject var menus: MenuController
    let item: FileItem
    @State private var dropTargeted = false

    private var acceptsDrop: Bool { item.isDirectory && !item.isPackage }

    func body(content: Content) -> some View {
        content
            .dropHighlight(dropTargeted)
            .contentShape(Rectangle())
            // Controls inside a row retain SwiftUI's normal click handling.
            .simultaneousGesture(TapGesture(count: 1).onEnded {
                guard Prefs.shared.itemCheckBoxes || ex.tab.editing == item.id,
                      (NSApp.currentEvent?.clickCount ?? 1) == 1 else { return }
                let f = NSEvent.modifierFlags
                ex.select(item,
                          extend: f.contains(.shift),
                          toggle: f.contains(.control) || f.contains(.command))
            })
            .onRightClick(mouseDown: { event in
                guard !Prefs.shared.itemCheckBoxes, ex.tab.editing != item.id else { return }
                let f = event.modifierFlags
                ex.select(item, extend: f.contains(.shift),
                          toggle: f.contains(.control) || f.contains(.command))
            }, doubleClick: ex.tab.editing == item.id ? nil : { ex.open(item) },
               selectionOwner: ex, selectionID: item.id) { p in
                if !ex.tab.selection.contains(item.id) {
                    ex.select(item, extend: false, toggle: false)
                }
                menus.show(id: "item", anchor: .zero,
                           entries: ContextMenus.item(ex),
                           width: 260,
                           iconRow: ContextMenus.iconRow(ex),
                           point: p)
            }
            .onDrag {
                if !ex.tab.selection.contains(item.id) {
                    ex.select(item, extend: false, toggle: false)
                }
                return NSItemProvider(object: item.url as NSURL)
            }
            .onDrop(of: [.fileURL], isTargeted: acceptsDrop ? $dropTargeted : nil) { providers in
                guard acceptsDrop else { return false }
                dropTargeted = false
                return DropHandler.handle(providers: providers, into: item.url, ex: ex)
            }
    }
}

/// The accent wash and outline Explorer paints on whatever you are about to
/// drop onto.
struct DropHighlight: ViewModifier {
    @ObservedObject private var interfaceSettings = Settings.shared
    static var forceOn = false
    let active: Bool
    var radius: CGFloat = 4

    func body(content: Content) -> some View {
        let highlighted = active || DropHighlight.forceOn
        content
            .background {
                if highlighted { WinRR(radius: radius).fill(Win.accent.opacity(0.22)) }
            }
            .overlay {
                if highlighted {
                    WinRR(radius: radius)
                        .strokeBorder(Win.accent.opacity(0.95), lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
            .scaleEffect(highlighted ? 1.012 : 1)
            .animation(.easeOut(duration: 0.15), value: active)
    }
}

extension View {
    func dropHighlight(_ active: Bool, radius: CGFloat = 4) -> some View {
        modifier(DropHighlight(active: active, radius: radius))
    }
}

extension View {
    func itemInteraction(_ ex: Explorer, _ menus: MenuController, _ item: FileItem) -> some View {
        modifier(ItemInteraction(ex: ex, menus: menus, item: item))
    }
}

// MARK: - Details view

struct DetailsView: View {
    @ObservedObject private var interfaceSettings = Settings.shared
    @ObservedObject var ex: Explorer
    @ObservedObject var menus: MenuController
    @ObservedObject var prefs = Prefs.shared

    @AppStorage("details.nameWidth", store: Store.defaults) private var nameWidth: Double = 420
    @AppStorage("details.dateWidth", store: Store.defaults) private var dateWidth: Double = 150
    @AppStorage("details.typeWidth", store: Store.defaults) private var typeWidth: Double = 140
    @AppStorage("details.sizeWidth", store: Store.defaults) private var sizeWidth: Double = 90

    private var rowHeight: CGFloat { Win.scaled(prefs.compactMode ? 24 : 34) }

    var body: some View {
        GeometryReader { geo in
            content(columns: DetailColumns(available: geo.size.width,
                                           preferredName: nameWidth,
                                           date: dateWidth, type: typeWidth, size: sizeWidth))
        }
    }

    private func content(columns: DetailColumns) -> some View {
        let items = ex.tab.items
        let indexedItems = items.indices.lazy.map { (index: $0, item: items[$0]) }
        return VStack(spacing: 0) {
            header(columns: columns)
            Divider().overlay(Win.divider)
            ScrollViewReader { proxy in
                List {
                    ForEach(indexedItems, id: \.item.id) { index, item in
                        DetailsRow(ex: ex, menus: menus, item: item,
                                   height: rowHeight, columns: columns,
                                   alternating: prefs.alternatingRowBackgrounds && !index.isMultiple(of: 2))
                            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    Color.clear.frame(height: 40)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, rowHeight)
                .scrollContentBackground(.hidden)
                .marqueeZone(ex)
                .onChange(of: ex.tab.scrollTarget) { _, target in
                    if let t = target { withAnimation(.linear(duration: 0.08)) { proxy.scrollTo(t, anchor: .center) } }
                }
            }
        }
    }

    private func header(columns: DetailColumns) -> some View {
        HStack(spacing: 0) {
            ColumnHeader(title: L("Name"), key: .name, width: $nameWidth,
                         effective: columns.name, ex: ex, leading: 34)
            if columns.date != nil {
                ColumnHeader(title: L("Date modified"), key: .modified, width: $dateWidth, ex: ex)
            }
            if columns.type != nil {
                ColumnHeader(title: L("Type"), key: .type, width: $typeWidth, ex: ex)
            }
            if columns.size != nil {
                ColumnHeader(title: L("Size"), key: .size, width: $sizeWidth, ex: ex, trailing: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(height: 30)
        .background(Win.listHeader)
        .coordinateSpace(name: "detailColumnHeader")
    }
}

struct ColumnHeader: View {
    @ObservedObject private var interfaceSettings = Settings.shared
    let title: String
    let key: SortKey
    @Binding var width: Double
    /// The width actually used for layout, which may be clamped to fit.
    var effective: CGFloat? = nil
    @ObservedObject var ex: Explorer
    var leading: CGFloat = 10
    var trailing: Bool = false
    @State private var hovering = false
    @State private var dragStartWidth: Double?
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .top) {
                HStack(spacing: 0) {
                    if trailing { Spacer(minLength: 0) }
                    Text(title)
                        .font(Win.font(.secondary, weight: .medium))
                        .foregroundStyle(Win.textSecondary)
                        .lineLimit(1)
                    if !trailing { Spacer(minLength: 0) }
                }
                .padding(.leading, trailing ? 6 : leading)
                .padding(.trailing, trailing ? 10 : 6)

                if prefs.sortKey == key {
                    Glyph(icon: prefs.sortAscending ? .sortAsc : .sortDesc,
                          size: 10, color: Win.accent)
                        .offset(y: -3)
                }
            }
            .frame(width: effective ?? width, height: 26)
            .background(WinRR(radius: 4).fill(hovering ? Win.subtleHover : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture {
                if prefs.sortKey == key { prefs.sortAscending.toggle() }
                else { prefs.sortKey = key; prefs.sortAscending = true }
                ex.resort()
            }

            Rectangle()
                .fill(Color.clear)
                .frame(width: 6, height: 20)
                .overlay(Rectangle().fill(Win.divider).frame(width: 1, height: 12))
                .contentShape(Rectangle())
                .onHover { NSCursor.resizeLeftRight.set(); if !$0 { NSCursor.arrow.set() } }
                .gesture(DragGesture(coordinateSpace: .named("detailColumnHeader"))
                    .onChanged { g in
                        if dragStartWidth == nil { dragStartWidth = Double(effective ?? CGFloat(width)) }
                        width = max(key == .name ? Double(DetailColumns.minimumName) : 60,
                                    dragStartWidth! + Double(g.translation.width))
                    }
                    .onEnded { _ in dragStartWidth = nil })
        }
    }
}

/// Which columns the Details view has room for. Columns drop out as the pane
/// narrows rather than overflowing it, which would shove the whole window
/// layout sideways. Date survives longest after Name, then Size, then Type.
struct DetailColumns: Equatable {
    static let minimumName: CGFloat = 120
    static let padding: CGFloat = 26

    var name: CGFloat
    var date: CGFloat? = nil
    var type: CGFloat? = nil
    var size: CGFloat? = nil

    init(name: CGFloat) { self.name = name }

    init(available: CGFloat, preferredName: CGFloat,
         date dateWidth: CGFloat, type typeWidth: CGFloat, size sizeWidth: CGFloat) {
        var remaining = available - DetailColumns.padding
        name = DetailColumns.minimumName
        if remaining >= DetailColumns.minimumName + dateWidth {
            date = dateWidth; remaining -= dateWidth
        }
        if remaining >= DetailColumns.minimumName + sizeWidth {
            size = sizeWidth; remaining -= sizeWidth
        }
        if remaining >= DetailColumns.minimumName + typeWidth {
            type = typeWidth; remaining -= typeWidth
        }
        name = max(DetailColumns.minimumName, min(preferredName, remaining))
    }

    /// Everything the row will actually lay out, padding included.
    var totalWidth: CGFloat {
        name + (date ?? 0) + (type ?? 0) + (size ?? 0) + DetailColumns.padding
    }
}

struct DetailsRow: View {
    @ObservedObject private var interfaceSettings = Settings.shared
    @ObservedObject var ex: Explorer
    @ObservedObject var menus: MenuController
    let item: FileItem
    let height: CGFloat
    let columns: DetailColumns
    var alternating = false
    @ObservedObject private var prefs = Prefs.shared

    private var selected: Bool { ex.tab.selection.contains(item.id) }
    private var highlighted: Bool { selected }
    private var cutOut: Bool { Clipboard.cutPaths.contains(item.url.path) }

    var body: some View {
        // Names and metadata differ in size, so align their baselines rather than their centres.
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            HStack(spacing: 10) {
                if prefs.itemCheckBoxes {
                    WinCheckbox(checked: selected) {
                        ex.select(item, extend: false, toggle: true)
                    }
                }
                ItemIcon(item: item, size: 16)
                    .opacity(cutOut ? 0.45 : 1)
                if ex.tab.editing == item.id {
                    RenameField(ex: ex, item: item)
                        .frame(height: Win.scaled(20))
                } else {
                    Text(item.displayName)
                        .font(Win.font(.item))
                        .foregroundStyle(highlighted ? Win.selectionText : (item.isHidden ? Win.textTertiary : Win.text))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .opacity(cutOut ? 0.45 : 1)
                }
            }
            .padding(.leading, 10)
            .frame(width: columns.name, alignment: .leading)

            if let width = columns.date {
                Text(item.modifiedText)
                    .font(Win.font(.body)).monospacedDigit().foregroundStyle(highlighted ? Win.selectionText : Win.fileMetadata)
                    .lineLimit(1)
                    .padding(.leading, 6)
                    .frame(width: width, alignment: .leading)
            }

            if let width = columns.type {
                Text(item.typeName)
                    .font(Win.font(.body)).foregroundStyle(highlighted ? Win.selectionText : Win.fileMetadata)
                    .lineLimit(1)
                    .padding(.leading, 6)
                    .frame(width: width, alignment: .leading)
            }

            if let width = columns.size {
                Text(item.sizeText)
                    .font(Win.font(.body)).monospacedDigit().foregroundStyle(highlighted ? Win.selectionText : Win.fileMetadata)
                    .lineLimit(1)
                    .padding(.trailing, 10)
                    .frame(width: width, alignment: .trailing)
            }

            Spacer(minLength: 0)
        }
        .frame(height: height)
        .background(
            Rectangle().fill(
                highlighted ? Win.currentRow : (alternating ? Win.alternatingRow : .clear))
        )
        .itemInteraction(ex, menus, item)
    }
}

struct RenameField: View {
    @ObservedObject private var interfaceSettings = Settings.shared
    @ObservedObject var ex: Explorer
    let item: FileItem
    @State private var text: String

    init(ex: Explorer, item: FileItem) {
        self.ex = ex
        self.item = item
        _text = State(initialValue: Prefs.shared.showExtensions ? item.name : item.displayName)
    }

    var body: some View {
        WinField(text: $text, style: .item,
                 selectStem: !item.isDirectory,
                 selectAll: item.isDirectory,
                 onCommit: { s in ex.commitRename(item, to: s) },
                 onCancel: { ex.tab.editing = nil },
                 // Enter and Esc clear `editing` first, so only a click-away commits here.
                 onEndEditing: { s in
                     if ex.tab.editing == item.id { ex.commitRename(item, to: s) }
                 })
            .padding(.horizontal, 4)
            .background(WinRR(radius: 3).fill(Win.fieldFocus))
            .overlay(WinRR(radius: 3).stroke(Win.accent, lineWidth: 1))
    }
}

// MARK: - Icon grid

struct IconGridView: View {
    @ObservedObject private var interfaceSettings = Settings.shared
    @ObservedObject var ex: Explorer
    @ObservedObject var menus: MenuController
    @ObservedObject var prefs = Prefs.shared

    var body: some View {
        let base = prefs.viewMode.cellSize
        let cell = CGSize(width: Win.scaled(base.width), height: Win.scaled(base.height))
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: cell.width, maximum: cell.width * 1.4),
                                             spacing: 4, alignment: .top)],
                          alignment: .leading, spacing: 4) {
                    ForEach(ex.tab.items) { item in
                        IconCell(ex: ex, menus: menus, item: item,
                                 size: prefs.viewMode.iconSize, cell: cell)
                            .id(item.id)
                    }
                }
                .padding(12)
            }
            .marqueeZone(ex)
            .onChange(of: ex.tab.scrollTarget) { _, t in
                if let t { proxy.scrollTo(t, anchor: .center) }
            }
        }
    }
}

struct IconCell: View {
    @ObservedObject private var interfaceSettings = Settings.shared
    @ObservedObject var ex: Explorer
    @ObservedObject var menus: MenuController
    let item: FileItem
    let size: CGFloat
    let cell: CGSize
    @ObservedObject private var fileHover = FileHover.shared
    private var hovering: Bool { fileHover.isHovered(item.id, in: ex) }
    @ObservedObject private var prefs = Prefs.shared

    private var selected: Bool { ex.tab.selection.contains(item.id) }
    private var highlighted: Bool { selected }
    private var cutOut: Bool { Clipboard.cutPaths.contains(item.url.path) }

    var body: some View {
        VStack(spacing: 6) {
            ItemIcon(item: item, size: size)
                .opacity(cutOut ? 0.45 : 1)
            if ex.tab.editing == item.id {
                RenameField(ex: ex, item: item).frame(height: Win.scaled(20)).padding(.horizontal, 4)
            } else {
                Text(item.displayName)
                    .font(Win.font(.item))
                    .foregroundStyle(highlighted ? Win.selectionText : Win.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .padding(.horizontal, 4)
                    .opacity(cutOut ? 0.45 : 1)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
        .frame(width: cell.width, height: cell.height)
        .background(
            WinRR(radius: 8).fill(
                highlighted ? Win.currentRow : .clear)
        )
        .overlay(alignment: .topLeading) {
            if prefs.itemCheckBoxes && (hovering || selected) {
                WinCheckbox(checked: selected) {
                    ex.select(item, extend: false, toggle: true)
                }
                .padding(6)
            }
        }
        .itemInteraction(ex, menus, item)
    }
}

// MARK: - List view (columns flow top-to-bottom, as in Explorer)

struct ListFlowView: View {
    @ObservedObject private var interfaceSettings = Settings.shared
    @ObservedObject var ex: Explorer
    @ObservedObject var menus: MenuController

    var body: some View {
        GeometryReader { geo in
            let rowH = Win.scaled(22)
            let columnWidth = Win.scaled(220)
            let perColumn = max(1, Int((geo.size.height - 24) / rowH))
            let items = ex.tab.items
            let columnCount = (items.count + perColumn - 1) / perColumn
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 0) {
                    ForEach(0..<columnCount, id: \.self) { column in
                        let start = column * perColumn
                        let end = min(start + perColumn, items.count)
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(items[start..<end]) { item in
                                SmallRow(ex: ex, menus: menus, item: item, width: columnWidth, height: rowH)
                            }
                        }
                        .frame(width: columnWidth)
                    }
                }
                .padding(12)
            }
            .marqueeZone(ex)
        }
    }
}

struct SmallRow: View {
    @ObservedObject private var interfaceSettings = Settings.shared
    @ObservedObject var ex: Explorer
    @ObservedObject var menus: MenuController
    let item: FileItem
    let width: CGFloat
    let height: CGFloat
    private var selected: Bool { ex.tab.selection.contains(item.id) }
    private var highlighted: Bool { selected }

    var body: some View {
        HStack(spacing: 8) {
            ItemIcon(item: item, size: 16)
            if ex.tab.editing == item.id {
                RenameField(ex: ex, item: item).frame(height: Win.scaled(18))
            } else {
                Text(item.displayName)
                    .font(Win.font(.item)).foregroundStyle(highlighted ? Win.selectionText : Win.text)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(width: width, height: height)
        .background(WinRR(radius: 8).fill(highlighted ? Win.currentRow : .clear))
        .itemInteraction(ex, menus, item)
    }
}

// MARK: - Tiles / Content

struct TilesView: View {
    @ObservedObject private var interfaceSettings = Settings.shared
    @ObservedObject var ex: Explorer
    @ObservedObject var menus: MenuController
    let mode: ViewMode

    var body: some View {
        ScrollView(.vertical) {
            if mode == .tiles {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 6)],
                          alignment: .leading, spacing: 6) {
                    ForEach(ex.tab.items) { item in
                        TileCell(ex: ex, menus: menus, item: item)
                    }
                }
                .padding(12)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(ex.tab.items) { item in
                        ContentRow(ex: ex, menus: menus, item: item)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .marqueeZone(ex)
    }
}

struct TileCell: View {
    @ObservedObject private var interfaceSettings = Settings.shared
    @ObservedObject var ex: Explorer
    @ObservedObject var menus: MenuController
    let item: FileItem
    private var selected: Bool { ex.tab.selection.contains(item.id) }
    private var highlighted: Bool { selected }

    var body: some View {
        HStack(spacing: 10) {
            ItemIcon(item: item, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                if ex.tab.editing == item.id {
                    RenameField(ex: ex, item: item).frame(height: Win.scaled(20))
                } else {
                    Text(item.displayName).font(Win.font(.item)).foregroundStyle(highlighted ? Win.selectionText : Win.text).lineLimit(1)
                }
                Text(item.typeName).font(Win.font(.body)).foregroundStyle(highlighted ? Win.selectionText : Win.textSecondary).lineLimit(1)
                if !item.sizeText.isEmpty {
                    Text(item.sizeText).font(Win.font(.body)).monospacedDigit().foregroundStyle(highlighted ? Win.selectionText : Win.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(height: Win.scaled(72))
        .background(WinRR(radius: 8).fill(highlighted ? Win.currentRow : .clear))
        .itemInteraction(ex, menus, item)
    }
}

struct ContentRow: View {
    @ObservedObject private var interfaceSettings = Settings.shared
    @ObservedObject var ex: Explorer
    @ObservedObject var menus: MenuController
    let item: FileItem
    private var selected: Bool { ex.tab.selection.contains(item.id) }
    private var highlighted: Bool { selected }

    var body: some View {
        HStack(spacing: 12) {
            ItemIcon(item: item, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                if ex.tab.editing == item.id {
                    RenameField(ex: ex, item: item).frame(height: Win.scaled(20))
                } else {
                    Text(item.displayName).font(Win.font(.item)).foregroundStyle(highlighted ? Win.selectionText : Win.text).lineLimit(1)
                }
                Text(item.modifiedText).font(Win.font(.body)).monospacedDigit().foregroundStyle(highlighted ? Win.selectionText : Win.textSecondary)
            }
            Spacer(minLength: 0)
            Text(item.sizeText).font(Win.font(.body)).monospacedDigit().foregroundStyle(highlighted ? Win.selectionText : Win.textSecondary)
        }
        .padding(.horizontal, 10)
        .frame(height: Win.scaled(56))
        .background(WinRR(radius: 8).fill(highlighted ? Win.currentRow : .clear))
        .itemInteraction(ex, menus, item)
    }
}
