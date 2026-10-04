import AppKit
import CoreServices
import UniformTypeIdentifiers

/// External requests navigate to folders and select files, never execute them.
struct ExternalTarget {
    let directory: URL
    let selection: URL?

    enum InvalidRequest: LocalizedError {
        case invalidURL, missingPath, inaccessible(String)
        var errorDescription: String? {
            switch self {
            case .invalidURL: return L("Only local file paths and file-explorer links are supported.")
            case .missingPath: return L("The link must contain an absolute path.")
            case .inaccessible(let path): return LF("The path does not exist or cannot be accessed: {0}", path)
            }
        }
    }

    static func parse(_ incoming: URL, revealDirectory: Bool = false) throws -> ExternalTarget {
        var url = incoming
        var reveal = revealDirectory
        if incoming.scheme?.lowercased() == "file-explorer" {
            guard let parts = URLComponents(url: incoming, resolvingAgainstBaseURL: false),
                  ["open", "reveal"].contains(parts.host ?? ""),
                  parts.user == nil, parts.password == nil, parts.port == nil,
                  let path = parts.queryItems?.first(where: { $0.name == "path" })?.value,
                  path.hasPrefix("/"), !path.contains("\0") else { throw InvalidRequest.missingPath }
            url = URL(fileURLWithPath: path)
            reveal = parts.host == "reveal"
        }
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
            throw InvalidRequest.invalidURL
        }
        url = url.standardizedFileURL
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
              values.isDirectory != nil else { throw InvalidRequest.inaccessible(url.path) }
        url = URL(fileURLWithPath: url.path, isDirectory: values.isDirectory == true)
        if values.isDirectory == true && values.isPackage != true && !reveal {
            return ExternalTarget(directory: URL(fileURLWithPath: url.path, isDirectory: true), selection: nil)
        }
        return ExternalTarget(directory: url.deletingLastPathComponent(), selection: url)
    }

    static func commandLine(_ arguments: [String]) -> [(URL, Bool)] {
        let reveal = arguments.contains("--reveal")
        return arguments.compactMap { argument in
            if argument.hasPrefix("file-explorer:") || argument.hasPrefix("file:") {
                return URL(string: argument).map { ($0, reveal) }
            }
            if argument.hasPrefix("/") || argument.hasPrefix("~") || argument.hasPrefix("./")
                || FileManager.default.fileExists(atPath: argument) {
                return (URL(fileURLWithPath: (argument as NSString).expandingTildeInPath), reveal)
            }
            return nil
        }
    }
}

final class SystemIntegration: ObservableObject {
    static let shared = SystemIntegration()

    private static let finderBundleID = "com.apple.finder"
    private static let handledContentTypes = ["public.folder", "public.directory"]

    @Published private(set) var currentApplication: URL?
    @Published private(set) var fileViewerBundleID: String?
    @Published private(set) var changing = false
    @Published private(set) var error: String?
    @Published private(set) var succeeded = false

    private var appBundleID: String? { Bundle.main.bundleIdentifier }

    var folderHandlerIsFileExplorer: Bool {
        guard let appBundleID else { return false }
        return currentApplication.flatMap { Bundle(url: $0)?.bundleIdentifier } == appBundleID
    }

    var revealHandlerIsFileExplorer: Bool {
        guard let appBundleID else { return false }
        return fileViewerBundleID == appBundleID
    }

    /// "Replace Finder" is active only when both normal folder opens and
    /// Reveal/Show-in-Finder requests are routed to this app.
    var isDefault: Bool { folderHandlerIsFileExplorer && revealHandlerIsFileExplorer }

    var currentName: String {
        guard let currentApplication else { return L("Unknown") }
        if folderHandlerIsFileExplorer { return L("File Explorer") }
        if Bundle(url: currentApplication)?.bundleIdentifier == Self.finderBundleID { return "Finder" }
        return currentApplication.deletingPathExtension().lastPathComponent
    }

    var revealViewerName: String {
        guard let bundleID = fileViewerBundleID else { return L("Finder (system default)") }
        if bundleID == appBundleID { return L("File Explorer") }
        if bundleID == Self.finderBundleID { return "Finder" }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return app.deletingPathExtension().lastPathComponent
        }
        return bundleID
    }

    func refresh() {
        currentApplication = NSWorkspace.shared.urlForApplication(toOpen: UTType.folder)
        fileViewerBundleID = Self.globalFileViewerBundleID()
    }

    func useFileExplorer() {
        guard let bundleID = appBundleID else {
            error = L("File Explorer has no bundle identifier.")
            return
        }
        change(folderHandlerBundleID: bundleID, fileViewerBundleID: bundleID, replacingFinder: true)
    }

    func restoreFinder() {
        change(folderHandlerBundleID: Self.finderBundleID, fileViewerBundleID: nil, replacingFinder: false)
    }

    private func change(folderHandlerBundleID: String,
                        fileViewerBundleID: String?,
                        replacingFinder: Bool) {
        guard !changing else { return }
        changing = true
        succeeded = false
        error = nil

        // LaunchServices owns the default handler for folders. The global
        // NSFileViewer preference is separately consulted by many apps for
        // "Reveal in Finder" / "Show in Finder", so both must be updated.
        var failures: [String] = []
        for contentType in Self.handledContentTypes {
            let status = LSSetDefaultRoleHandlerForContentType(
                contentType as CFString, .all, folderHandlerBundleID as CFString)
            if status != noErr { failures.append("\(contentType): \(status)") }
        }
        Self.setGlobalFileViewer(fileViewerBundleID)

        // LaunchServices and already-running apps can cache these values.
        // Refresh shortly after the write so the UI shows what macOS currently
        // reports, while still telling the user when a relaunch/sign-out is needed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.changing = false
            self.refresh()

            if !failures.isEmpty {
                self.error = LF("The system could not update Finder routing: {0}",
                                failures.joined(separator: ", "))
                return
            }

            if replacingFinder {
                if self.isDefault {
                    self.succeeded = true
                } else {
                    self.error = L("Finder routing was updated, but macOS or an already-running app is still using cached settings. Sign out or restart, then check again.")
                }
            } else {
                let folderIsFinder = self.currentApplication.flatMap {
                    Bundle(url: $0)?.bundleIdentifier
                } == Self.finderBundleID
                let revealIsSystemDefault = self.fileViewerBundleID == nil
                    || self.fileViewerBundleID == Self.finderBundleID
                if folderIsFinder && revealIsSystemDefault {
                    self.succeeded = true
                } else {
                    self.error = L("Finder routing was restored, but macOS is still reporting cached settings. Sign out or restart, then check again.")
                }
            }
        }
    }

    private static func globalFileViewerBundleID() -> String? {
        CFPreferencesCopyValue(
            "NSFileViewer" as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? String
    }

    private static func setGlobalFileViewer(_ bundleID: String?) {
        CFPreferencesSetValue(
            "NSFileViewer" as CFString,
            bundleID as CFString?,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        CFPreferencesSynchronize(
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
    }
}

extension Explorer {
    /// Reveal explicitly requested hidden items without changing the hidden-files preference.
    func revealExternal(_ files: [URL]) {
        var requested: Set<String> = []
        let uniqueFiles = files.filter { requested.insert($0.standardizedFileURL.path).inserted }
        let missing = uniqueFiles.filter { url in !tab.items.contains { $0.url.standardizedFileURL.path == url.path } }
        tab.items.append(contentsOf: missing.compactMap { Loader.item(at: $0) })
        resort()
        let found = tab.items.filter { requested.contains($0.url.standardizedFileURL.path) }
        tab.selection = Set(found.map(\.id))
        tab.lead = found.first?.id
        tab.anchor = found.first?.id
        tab.scrollTarget = found.first?.id
    }
}

extension AppState {
    func openExternal(_ targets: [ExternalTarget]) {
        guard !targets.isEmpty else { return }
        if activeModel == nil { openNewWindow() }
        guard let model = activeModel else { return }
        let explorer = model.active
        // Preserve request order and group files in the same folder into one tab.
        var directories: [URL] = []
        for target in targets where !directories.contains(target.directory) { directories.append(target.directory) }
        for directory in directories {
            explorer.filterKind = nil
            explorer.openTab(.folder(directory))
            explorer.sheet = nil
            explorer.revealExternal(targets.filter { $0.directory == directory }.compactMap(\.selection))
        }
        bringForward(model)
    }
}
