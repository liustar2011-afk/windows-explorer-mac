import AppKit
import QuickLookUI

/// Finder-style Quick Look for the file list. Space toggles the panel; arrow
/// keys keep it in sync with the current selection.
final class QuickLookPreview: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPreview()

    private var urls: [URL] = []
    private var currentIndex = 0
    private var scratch: [URL] = []

    var isVisible: Bool { QLPreviewPanel.shared()?.isVisible == true }

    func toggle(for explorer: Explorer) {
        if isVisible {
            QLPreviewPanel.shared()?.close()
            return
        }
        present(for: explorer)
    }

    func present(for explorer: Explorer) {
        let prepared = prepare(for: explorer)
        guard !prepared.urls.isEmpty else { NSSound.beep(); return }
        urls = prepared.urls
        currentIndex = prepared.index
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.updateController()
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
        if urls.indices.contains(currentIndex) {
            panel.currentPreviewItemIndex = currentIndex
        }
    }

    /// Reloads the open panel when the selection moves with the arrow keys.
    func selectionChanged(in explorer: Explorer) {
        guard isVisible else { return }
        let prepared = prepare(for: explorer)
        guard !prepared.urls.isEmpty else {
            QLPreviewPanel.shared()?.close()
            return
        }
        urls = prepared.urls
        currentIndex = prepared.index
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.reloadData()
        if urls.indices.contains(currentIndex) {
            panel.currentPreviewItemIndex = currentIndex
        }
    }

    func begin(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
    }

    func end(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
        urls = []
        currentIndex = 0
        clearScratch()
    }

    // MARK: QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }

    // MARK: QLPreviewPanelDelegate

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Let the app's own key handler drive arrow navigation and Space.
        false
    }

    // MARK: Preparation

    private func prepare(for explorer: Explorer) -> (urls: [URL], index: Int) {
        clearScratch()
        var items = explorer.selectedItems
        if items.isEmpty, let lead = explorer.tab.lead,
           let item = explorer.tab.items.first(where: { $0.id == lead }) {
            items = [item]
        }
        guard !items.isEmpty else { return ([], 0) }

        var urls: [URL] = []
        urls.reserveCapacity(items.count)
        var index = 0
        let lead = explorer.tab.lead
        for item in items {
            guard let url = resolvableURL(item, in: explorer) else { continue }
            if item.id == lead { index = urls.count }
            urls.append(url)
        }
        guard !urls.isEmpty else { return ([], 0) }
        return (urls, min(index, urls.count - 1))
    }

    /// Real files use their URL; archive entries are staged to a temp folder.
    private func resolvableURL(_ item: FileItem, in explorer: Explorer) -> URL? {
        if case .archive(let archive, let inner) = explorer.tab.location {
            if item.isDirectory && !item.isPackage { return nil }
            let entry = inner.isEmpty ? item.name : inner + "/" + item.name
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("winexp-archive")
                .appendingPathComponent(UUID().uuidString)
            if Archives.extract(archive, entries: [entry], to: root) != nil { return nil }
            let staged = root.appendingPathComponent(entry)
            guard FileManager.default.fileExists(atPath: staged.path) else {
                try? FileManager.default.removeItem(at: root)
                return nil
            }
            scratch.append(root)
            return staged
        }
        return item.url
    }

    private func clearScratch() {
        let leftovers = scratch
        scratch = []
        for url in leftovers {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
