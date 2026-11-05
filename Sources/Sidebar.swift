import SwiftUI
import AppKit

struct NavNode: Identifiable {
    let id: String
    let title: String
    let icon: Icon
    let accent: PlaceAccent
    let location: Location?
    let url: URL?
    let level: Int
    let expandable: Bool
    let pinned: Bool
    var sectionTitle: String? = nil
}

struct NavPane: View {
    @ObservedObject private var interfaceSettings = Settings.shared
    @ObservedObject var ex: Explorer
    @ObservedObject var menus: MenuController
    @State private var hoverID: String?

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(nodes) { node in
                    if let title = node.sectionTitle {
                        Text(L(title))
                            .font(Win.font(.caption, weight: .semibold))
                            .foregroundStyle(Win.textSecondary)
                            .padding(.leading, 24)
                            .padding(.top, title == "Common locations" ? 2 : 16)
                            .padding(.bottom, 6)
                    }
                    NavRow(node: node, ex: ex, menus: menus,
                           selected: isSelected(node),
                           expanded: ex.navExpanded.contains(node.id))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: .infinity)
        .background {
            BackdropMaterial(material: .sidebar)
                .overlay(Win.sidebar.opacity(0.96))
        }
    }

    private func isSelected(_ node: NavNode) -> Bool {
        guard let loc = node.location else { return false }
        return loc == ex.tab.location
    }

    private var nodes: [NavNode] {
        var out: [NavNode] = []
        let original = Places.sidebar
        func section(_ place: Place) -> String {
            if place.special == .thisPC || place.special == .network || place.special == .recycleBin {
                return "Devices"
            }
            if place.special == .home || place.special == .gallery || place.id == "onedrive"
                || place.url.map({ Places.defaultPinnedPaths.contains($0.path) || $0.path == "/Applications" }) == true {
                return "Common locations"
            }
            return "Project favorites"
        }
        // Group the display only; never rewrite Finder's or the user's saved ordering.
        let places = ["Common locations", "Project favorites", "Devices"].flatMap { group in
            original.filter { section($0) == group }
        }
        var previousSection: String?

        func children(of url: URL, level: Int, parentID: String) {
            let dirs = Loader.contents(of: url, showHidden: Prefs.shared.showHidden)
                .filter { $0.isDirectory && !$0.isPackage }
            for d in dirs.prefix(60) {
                let id = "\(parentID)/\(d.name)"
                out.append(NavNode(id: id, title: d.name, icon: .folderOutline, accent: .neutral,
                                   location: .folder(d.url), url: d.url, level: level,
                                   expandable: true, pinned: false))
                if ex.navExpanded.contains(id) { children(of: d.url, level: level + 1, parentID: id) }
            }
        }

        for p in places {
            let loc: Location? = {
                switch p.special {
                case .home: return .home
                case .gallery: return .gallery
                case .thisPC: return .thisPC
                case .network: return .network
                case .recycleBin: return .recycleBin
                case nil: return p.url.map { .folder($0) }
                }
            }()
            let group = section(p)
            let heading = previousSection == group ? nil : group
            previousSection = group
            out.append(NavNode(id: p.id, title: p.title, icon: p.icon, accent: p.accent,
                               location: loc, url: p.url, level: 0,
                               expandable: p.special != .home, pinned: p.special == nil,
                               sectionTitle: heading))
            if ex.navExpanded.contains(p.id) {
                if p.special == .thisPC {
                    for v in Loader.volumes() {
                        let id = "thispc/\(v.name)"
                        out.append(NavNode(id: id, title: Places.displayName(for: v.url), icon: .drive,
                                           accent: .neutral, location: .folder(v.url), url: v.url,
                                           level: 1, expandable: true, pinned: false))
                        if ex.navExpanded.contains(id) { children(of: v.url, level: 2, parentID: id) }
                    }
                } else if let u = p.url {
                    children(of: u, level: 1, parentID: p.id)
                }
            }
        }
        return out
    }
}

struct NavRow: View {
    @ObservedObject private var interfaceSettings = Settings.shared
    let node: NavNode
    @ObservedObject var ex: Explorer
    @ObservedObject var menus: MenuController
    let selected: Bool
    let expanded: Bool
    @State private var hovering = false
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            // Expander chevron
            Group {
                if node.expandable {
                    Button {
                        if expanded { ex.navExpanded.remove(node.id) }
                        else { ex.navExpanded.insert(node.id) }
                    } label: {
                        Glyph(icon: expanded ? .chevronDown : .chevronRight,
                              size: 11, color: Win.textSecondary, weight: 1.3)
                            .frame(width: 20, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(hovering || expanded || selected ? 1 : 0.0)
                } else {
                    Color.clear.frame(width: 20, height: 22)
                }
            }
            .padding(.leading, CGFloat(node.level) * 14)

            if let url = node.url, Settings.shared.style(for: url) != nil {
                FolderGlyph(url: url, size: 16)
            } else if node.icon == .folderOutline {
                FolderIcon(size: 16)
            } else {
                Glyph(icon: node.icon, size: 16,
                      color: selected ? Win.accent : Win.textSecondary)
            }

            Text(node.title)
                .font(Win.font(.body, weight: selected ? .medium : .regular))
                .foregroundStyle(Win.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 8)

            Spacer(minLength: 4)

            if node.pinned && (hovering || selected) {
                Glyph(icon: .pin, size: 12, color: Win.textTertiary, weight: 1.2)
                    .padding(.trailing, 6)
            }
        }
        .frame(height: Win.scaled(30))
        .padding(.leading, 4)
        .background(
            WinRR(radius: 7)
                .fill(selected ? Win.navSelected : (hovering ? Win.subtleHover : .clear))
        )
        .overlay(alignment: .leading) {
            if selected {
                Capsule().fill(Win.accent)
                    .frame(width: 3, height: 16)
                    .padding(.leading, 1)
            }
        }
        .dropHighlight(dropTargeted)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if let loc = node.location { ex.go(to: loc) }
        }
        .onDrop(of: [.fileURL], isTargeted: node.url != nil ? $dropTargeted : nil) { providers in
            guard let dest = node.url else { return false }
            dropTargeted = false
            return DropHandler.handle(providers: providers, into: dest, ex: ex)
        }
        .onRightClick { p in
            menus.show(id: "nav-\(node.id)", anchor: .zero, entries: menuEntries(), width: 250, point: p)
        }
    }

    private func menuEntries() -> [MenuEntry] {
        var entries: [MenuEntry] = []
        if let loc = node.location {
            entries.append(MenuEntry(title: L("Open"), icon: .openWith) { ex.go(to: loc) })
            entries.append(MenuEntry(title: L("Open in new tab"), icon: .plus) { ex.go(to: loc, newTab: true) })
            entries.append(MenuEntry(title: L("Open in new window")) { AppState.shared.openNewWindow(at: loc) })
        }
        guard let url = node.url else { return entries }
        if ExternalVolumes.canEject(url) {
            entries.append(.sep())
            entries.append(MenuEntry(title: L("Eject")) {
                ExternalVolumes.eject(url, explorer: ex)
            })
        }
        let settings = Settings.shared
        let pinned = settings.isPinned(url) && !settings.hiddenPlaces.contains(url.path)
        entries.append(.sep())
        entries.append(MenuEntry(title: (settings.isFinderFavorite(url) && !settings.bidirectionalFinderFavorites) ? L("Managed by Finder") : (pinned ? L("Unpin from Quick access") : L("Pin to Quick access")),
                                 icon: pinned ? .unpin : .pin, enabled: !settings.finderWritePending && (!settings.isFinderFavorite(url) || settings.bidirectionalFinderFavorites)) {
            if pinned { settings.unpin(url) } else { settings.pin(url) }
        })
        entries.append(MenuEntry(title: L("Change icon…"), icon: .palette) {
            if let i = Loader.item(at: url) { ex.sheet = .folderIcon(i) }
        })
        entries.append(.sep())
        entries.append(MenuEntry(title: L("Copy as path"), icon: .copy) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        })
        entries.append(MenuEntry(title: L("Properties"), icon: .properties) {
            if let i = Loader.item(at: url) { ex.sheet = .properties([i]) }
        })
        return entries
    }
}

// MARK: - Shared drop handling

enum DropHandler {
    static func handle(providers: [NSItemProvider], into dest: URL, ex: Explorer) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        for p in providers where p.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            // Dropping a folder onto itself or into its own subtree would loop.
            let valid = urls.filter { !dest.path.hasPrefix($0.path + "/") && $0.path != dest.path }
            guard !valid.isEmpty else { NSSound.beep(); return }
            let flags = NSEvent.modifierFlags
            // Windows: Ctrl forces copy, Shift forces move; otherwise move within a
            // volume and copy across volumes.
            let forceCopy = flags.contains(.control) || flags.contains(.option)
            let forceMove = flags.contains(.shift) || flags.contains(.command)
            let sameVolume = valid.allSatisfy { volumeID(of: $0) == volumeID(of: dest) }
            let kind: TransferJob.Kind =
                (forceCopy || (!forceMove && !sameVolume)) ? .copy : .move
            ex.transfer(kind: kind, sources: valid, to: dest)
        }
        return true
    }

    private static func volumeID(of url: URL) -> String {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))
            .flatMap { $0.volumeIdentifier as? NSObject }?.description ?? ""
    }
}
