import Foundation
import AppKit
import Combine

struct FinderFavorite: Equatable {
    let url: URL
    let name: String?
}

/// Read Finder's saved bookmarks without modifying its shared list.
enum FinderFavoritesReader {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")
    static let filenames = ["sfl4", "sfl3", "sfl2"].map {
        "com.apple.LSSharedFileList.FavoriteItems.\($0)"
    }

    static func source(in directory: URL = directory) -> URL? {
        filenames.map { directory.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func decode(_ data: Data) throws -> [FinderFavorite] {
        let classes: [AnyClass] = [NSDictionary.self, NSArray.self, NSString.self,
                                  NSNumber.self, NSData.self, NSDate.self, NSURL.self]
        guard let root = try NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else {
            throw CocoaError(.coderReadCorrupt)
        }
        var favorites: [FinderFavorite] = []
        var seen = Set<String>()
        for item in items {
            guard let bookmark = item["Bookmark"] as? Data else { continue }
            var stale = false
            guard let resolved = try? URL(resolvingBookmarkData: bookmark,
                options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
                resolved.isFileURL else { continue }
            let url = resolved.standardizedFileURL
            // Finder also stores smart locations that cannot be opened as folders.
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false { continue }
            guard seen.insert(url.path).inserted else { continue }
            favorites.append(FinderFavorite(url: url, name: item["Name"] as? String))
        }
        return favorites
    }
}

final class FinderFavoritesSync {
    static let shared = FinderFavoritesSync()
    private let queue = DispatchQueue(label: "com.winexplorer.finder-favorites", qos: .utility)
    private var watcher: DirectoryWatcher?
    private var timer: DispatchSourceTimer?
    private var preference: AnyCancellable?
    private var lastData: Data?
    private var lastCount = 0
    private var started = false

    func start() {
        guard !started else { return }
        let env = ProcessInfo.processInfo.environment
        guard env["WINEXP_SELFTEST"] == nil, env["WINEXP_UITEST"] == nil, env["WINEXP_DEMO"] == nil,
              env["WINEXP_SNAPSHOT"] == nil, env["WINEXP_OPEN_REPORT"] == nil else { return }
        started = true
        watcher = DirectoryWatcher(url: FinderFavoritesReader.directory) { [weak self] in self?.refresh() }
        // Also catches archive replacement and a shared-list directory created later.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(300))
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        self.timer = timer
        preference = Settings.shared.$syncFinderFavorites.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh(force: true) }
        }
        refresh()
    }

    static func validAccessSelection(_ url: URL) -> Bool {
        let selected = url.standardizedFileURL
        let directory = FinderFavoritesReader.directory.standardizedFileURL
        return selected == directory || (selected.deletingLastPathComponent() == directory
            && FinderFavoritesReader.filenames.contains(selected.lastPathComponent))
    }

    func requestReadAccess() {
        let panel = NSOpenPanel()
        panel.title = L("Allow reading Finder favorites")
        panel.message = L("Select the Finder favorites file or its containing folder to allow read access.")
        panel.prompt = L("Allow read access")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FinderFavoritesReader.directory
        panel.nameFieldStringValue = FinderFavoritesReader.filenames[0]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            guard Self.validAccessSelection(url) else {
                Settings.shared.finderSyncStatus = L("Select the Finder favorites file or its containing folder.")
                return
            }
            do {
                let bookmark = try (try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess]))
                    ?? url.bookmarkData()
                Store.defaults.set(bookmark, forKey: "finderFavoritesReadBookmark")
                self.refresh(force: true)
            } catch {
                Settings.shared.finderSyncStatus = LF("Could not read Finder favorites: {0}", error.localizedDescription)
            }
        }
    }

    private func authorizedLocation() -> URL? {
        guard let data = Store.defaults.data(forKey: "finderFavoritesReadBookmark") else { return nil }
        var stale = false
        let url = (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                           relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                         relativeTo: nil, bookmarkDataIsStale: &stale))
        guard let url, Self.validAccessSelection(url) else { return nil }
        return url
    }

    static func nativeFavorites() throws -> [FinderFavorite] {
        var error: NSError?
        guard let entries = FEFinderFavorites(&error) else { throw error ?? CocoaError(.fileReadUnknown) }
        return entries.compactMap { entry in
            guard let url = entry["url"] as? URL else { return nil }
            return FinderFavorite(url: url, name: entry["name"] as? String)
        }
    }

    func change(_ url: URL, operation: String, neighbor: URL? = nil, completion: @escaping () -> Void = {}) {
        let settings = Settings.shared
        guard settings.syncFinderFavorites, settings.bidirectionalFinderFavorites,
              !settings.finderWritePending else { return }
        settings.finderWritePending = true
        settings.finderWriteError = nil
        queue.async {
            var error: NSError?
            let success = FEChangeFinderFavorite(url, operation, neighbor, &error)
            let favorites = success ? try? Self.nativeFavorites() : nil
            DispatchQueue.main.async {
                settings.finderWritePending = false
                if success, let favorites {
                    settings.finderFavorites = favorites
                    settings.finderSyncStatus = LF("Synced {0} Finder favorites.", favorites.count)
                    completion()
                } else {
                    settings.finderWriteError = LF("Could not update Finder favorites: {0}",
                        error?.localizedDescription ?? L("Unknown error"))
                }
            }
        }
    }

    func move(_ url: URL, offset: Int) {
        guard let items = Settings.shared.finderFavorites,
              let index = items.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }),
              items.indices.contains(index + offset) else { return }
        change(url, operation: offset < 0 ? "before" : "after", neighbor: items[index + offset].url)
    }

    func refresh(force: Bool = false) {
        guard Settings.shared.syncFinderFavorites else { return }
        let native = Settings.shared.bidirectionalFinderFavorites
        queue.async { [weak self] in
            guard let self else { return }
            if native {
                do {
                    let favorites = try Self.nativeFavorites()
                    DispatchQueue.main.async {
                        guard Settings.shared.syncFinderFavorites, Settings.shared.bidirectionalFinderFavorites else { return }
                        if Settings.shared.finderFavorites != favorites { Settings.shared.finderFavorites = favorites }
                        Settings.shared.finderSyncStatus = LF("Synced {0} Finder favorites.", favorites.count)
                    }
                    return
                } catch { /* Older systems can still read their saved archive. */ }
            }
            let authorized = self.authorizedLocation()
            let accessing = authorized?.startAccessingSecurityScopedResource() ?? false
            defer { if accessing { authorized?.stopAccessingSecurityScopedResource() } }
            do {
                let selectedFile = authorized.flatMap { FinderFavoritesReader.filenames.contains($0.lastPathComponent) ? $0 : nil }
                guard let source = selectedFile ?? FinderFavoritesReader.source(in: authorized ?? FinderFavoritesReader.directory)
                    else { throw CocoaError(.fileReadNoSuchFile) }
                let data = try Data(contentsOf: source)
                if !force && data == self.lastData {
                    let count = self.lastCount
                    DispatchQueue.main.async {
                        guard Settings.shared.syncFinderFavorites else { return }
                        let message = LF("Synced {0} Finder favorites.", count)
                        if Settings.shared.finderSyncStatus != message { Settings.shared.finderSyncStatus = message }
                    }
                    return
                }
                let favorites = try FinderFavoritesReader.decode(data)
                self.lastData = data
                self.lastCount = favorites.count
                DispatchQueue.main.async {
                    let settings = Settings.shared
                    guard settings.syncFinderFavorites else { return }
                    if settings.finderFavorites != favorites { settings.finderFavorites = favorites }
                    let message = LF("Synced {0} Finder favorites.", favorites.count)
                    if settings.finderSyncStatus != message { settings.finderSyncStatus = message }
                }
            } catch {
                DispatchQueue.main.async {
                    guard Settings.shared.syncFinderFavorites else { return }
                    let message = LF("Could not read Finder favorites: {0}", error.localizedDescription)
                    if Settings.shared.finderSyncStatus != message { Settings.shared.finderSyncStatus = message }
                }
            }
        }
    }
}
