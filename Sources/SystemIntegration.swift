import AppKit
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
    @Published private(set) var currentApplication: URL?
    @Published private(set) var changing = false
    @Published private(set) var error: String?
    @Published private(set) var succeeded = false

    var isDefault: Bool {
        currentApplication.flatMap { Bundle(url: $0)?.bundleIdentifier } == Bundle.main.bundleIdentifier
            && Bundle.main.bundleIdentifier != nil
    }

    var currentName: String {
        guard let currentApplication else { return L("Unknown") }
        if isDefault { return L("File Explorer") }
        if Bundle(url: currentApplication)?.bundleIdentifier == "com.apple.finder" { return "Finder" }
        return currentApplication.deletingPathExtension().lastPathComponent
    }

    func refresh() {
        currentApplication = NSWorkspace.shared.urlForApplication(toOpen: UTType.folder)
    }

    func useFileExplorer() { change(to: Bundle.main.bundleURL) }

    func restoreFinder() {
        guard let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else {
            error = L("Finder could not be found.")
            return
        }
        change(to: finder)
    }

    private func change(to application: URL) {
        guard !changing else { return }
        changing = true; succeeded = false; error = nil
        // Only ordinary folders. Document and application associations stay intact.
        NSWorkspace.shared.setDefaultApplication(at: application, toOpen: UTType.folder) { failure in
            DispatchQueue.main.async {
                self.changing = false
                self.refresh()
                if let failure {
                    let nsError = failure as NSError
                    let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
                    if (nsError.domain == NSOSStatusErrorDomain && nsError.code == -50)
                        || (underlying?.domain == NSOSStatusErrorDomain && underlying?.code == -50) {
                        self.error = L("This macOS version does not allow changing the default folder app through this interface. Finder remains the default; external open and reveal still work.")
                    } else {
                        self.error = LF("The system could not change the default folder app: {0}", failure.localizedDescription)
                    }
                } else if self.currentApplication.flatMap({ Bundle(url: $0)?.bundleIdentifier })
                            == Bundle(url: application)?.bundleIdentifier {
                    self.succeeded = true
                } else {
                    self.error = L("The system has not applied the folder association. Refresh the status and try again.")
                }
            }
        }
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
        if activeModel == nil { openNewWindow(at: .folder(targets[0].directory)) }
        guard let model = activeModel else { return }
        let explorer = model.active
        // Preserve request order and group files in the same folder into one tab.
        var directories: [URL] = []
        for target in targets where !directories.contains(target.directory) { directories.append(target.directory) }
        for directory in directories {
            if let existing = explorer.tabs.firstIndex(where: { $0.location.url?.standardizedFileURL.path == directory.standardizedFileURL.path }) {
                explorer.selectTab(existing)
            } else {
                explorer.go(to: directory, newTab: explorer.tab.location != .home)
            }
            explorer.filterKind = nil
            explorer.go(to: directory)
            explorer.sheet = nil
            explorer.revealExternal(targets.filter { $0.directory == directory }.compactMap(\.selection))
        }
        bringForward(model)
    }
}
