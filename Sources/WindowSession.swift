import AppKit

/// Session data uses stable location identifiers, independent of interface language.
struct SavedLocation: Codable {
    var kind: String
    var path: String?
    var innerPath: String?

    init(_ location: Location) {
        switch location {
        case .home: kind = "home"
        case .gallery: kind = "gallery"
        case .thisPC: kind = "thisPC"
        case .network: kind = "network"
        case .recycleBin: kind = "recycleBin"
        case .folder(let url): kind = "folder"; path = url.path
        case .archive(let url, let inner): kind = "archive"; path = url.path; innerPath = inner
        }
    }

    var location: Location {
        switch kind {
        case "gallery": return .gallery
        case "thisPC": return .thisPC
        case "network": return .network
        case "recycleBin": return .recycleBin
        case "folder":
            guard let path else { return .home }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory),
                  directory.boolValue else { return .home }
            return .folder(URL(fileURLWithPath: path))
        case "archive":
            guard let path, FileManager.default.fileExists(atPath: path) else { return .home }
            return .archive(URL(fileURLWithPath: path), innerPath ?? "")
        default: return .home
        }
    }
}

struct SavedPane: Codable {
    var locations: [SavedLocation]
    var active: Int

    init(_ explorer: Explorer) {
        locations = explorer.tabs.map { SavedLocation($0.location) }
        active = explorer.active
    }

    func restore(into explorer: Explorer) {
        explorer.tabs = locations.isEmpty ? [TabState()] : locations.map {
            var tab = TabState()
            tab.history = [$0.location]
            return tab
        }
        explorer.active = min(max(0, active), explorer.tabs.count - 1)
        explorer.reload()
    }
}

struct SavedWindow: Codable {
    var left: SavedPane
    var right: SavedPane?
    var activeSide: String
    var splitRatio: Double
    var frame: String

    init(window: NSWindow, model: WindowModel) {
        left = SavedPane(model.left)
        right = model.right.map { SavedPane($0) }
        activeSide = model.activeSide.rawValue
        splitRatio = Double(model.splitRatio)
        frame = NSStringFromRect(window.frame)
    }

    func restore(into model: WindowModel) {
        left.restore(into: model.left)
        if model.dual != (right != nil) { model.toggleDual() }
        if let right, let pane = model.right { right.restore(into: pane) }
        model.splitRatio = splitRatio.isFinite ? CGFloat(min(max(splitRatio, 0.2), 0.8)) : 0.5
        model.activate(PaneSide(rawValue: activeSide) ?? .left)
    }
}

enum WindowSession {
    static var saved: [SavedWindow] {
        get {
            guard let data = Store.defaults.data(forKey: "lastWindowSession"),
                  let windows = try? JSONDecoder().decode([SavedWindow].self, from: data)
            else { return [] }
            return windows
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            Store.defaults.set(data, forKey: "lastWindowSession")
        }
    }
}
