import SwiftUI
import AppKit

// MARK: - Comparison

struct CompareEntry: Identifiable {
    enum Status: String {
        case onlyLeft = "Only on the left"
        case onlyRight = "Only on the right"
        case different = "Different"
        case same = "Identical"
    }

    var id: String { relativePath }
    let relativePath: String
    let status: Status
    let leftSize: Int64?
    let rightSize: Int64?
    let leftModified: Date?
    let rightModified: Date?
    let isDirectory: Bool
}

enum FolderCompare {
    /// Walks both trees and pairs them up by relative path.
    static func run(left: URL, right: URL) -> [CompareEntry] {
        let leftFiles = index(left)
        let rightFiles = index(right)
        var entries: [CompareEntry] = []

        for (path, l) in leftFiles {
            if let r = rightFiles[path] {
                let same = l.isDirectory == r.isDirectory
                    && (l.isDirectory || (l.size == r.size && abs(l.modified.timeIntervalSince(r.modified)) < 2))
                entries.append(CompareEntry(relativePath: path,
                                            status: same ? .same : .different,
                                            leftSize: l.size, rightSize: r.size,
                                            leftModified: l.modified, rightModified: r.modified,
                                            isDirectory: l.isDirectory))
            } else {
                entries.append(CompareEntry(relativePath: path, status: .onlyLeft,
                                            leftSize: l.size, rightSize: nil,
                                            leftModified: l.modified, rightModified: nil,
                                            isDirectory: l.isDirectory))
            }
        }
        for (path, r) in rightFiles where leftFiles[path] == nil {
            entries.append(CompareEntry(relativePath: path, status: .onlyRight,
                                        leftSize: nil, rightSize: r.size,
                                        leftModified: nil, rightModified: r.modified,
                                        isDirectory: r.isDirectory))
        }
        return entries.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    private struct Entry {
        let size: Int64
        let modified: Date
        let isDirectory: Bool
    }

    private static func index(_ root: URL) -> [String: Entry] {
        // Walked by hand rather than with a prefix-stripping enumerator: the
        // enumerator reports resolved paths (/private/var) while the root may
        // be spelled /var, and the two would never line up.
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        var out: [String: Entry] = [:]
        var scanned = 0

        func walk(_ directory: URL, prefix: String) {
            guard scanned < 20000 else { return }
            let children = (try? fm.contentsOfDirectory(at: directory,
                                                        includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles])) ?? []
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                scanned += 1
                if scanned > 20000 { return }
                let values = try? child.resourceValues(forKeys: Set(keys))
                let isDirectory = values?.isDirectory ?? false
                let relative = prefix.isEmpty ? child.lastPathComponent
                                              : prefix + "/" + child.lastPathComponent
                out[relative] = Entry(size: Int64(values?.fileSize ?? 0),
                                      modified: values?.contentModificationDate ?? .distantPast,
                                      isDirectory: isDirectory)
                if isDirectory { walk(child, prefix: relative) }
            }
        }

        walk(root, prefix: "")
        return out
    }
}

/// A comparison belongs to exactly one pair of directories.
struct FolderComparison {
    let left: URL
    let right: URL
    let entries: [CompareEntry]

    func matches(left: URL?, right: URL?) -> Bool {
        guard let left, let right else { return false }
        return Transfers.sameDirectory(self.left, left) && Transfers.sameDirectory(self.right, right)
    }
}

enum FolderSync {
    struct Copy {
        let source: URL
        let destination: URL
    }

    static func plan(_ comparison: FolderComparison, fromLeft: Bool) -> [Copy] {
        let source = fromLeft ? comparison.left : comparison.right
        let target = fromLeft ? comparison.right : comparison.left
        let wanted: CompareEntry.Status = fromLeft ? .onlyLeft : .onlyRight
        var copiedDirectories: [String] = []
        var copies: [Copy] = []
        // Ancestors must be considered before their descendants, independent
        // of the display's locale-sensitive sorting order.
        let entries = comparison.entries.sorted {
            let a = $0.relativePath.split(separator: "/").count
            let b = $1.relativePath.split(separator: "/").count
            return a == b ? $0.relativePath < $1.relativePath : a < b
        }
        for entry in entries where entry.status == wanted || entry.status == .different {
            if copiedDirectories.contains(where: { entry.relativePath.hasPrefix($0 + "/") }) { continue }
            let from = source.appendingPathComponent(entry.relativePath)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: from.path) else { continue }
            copies.append(Copy(source: from, destination: target.appendingPathComponent(entry.relativePath).deletingLastPathComponent()))
            if attrs[.type] as? FileAttributeType == .typeDirectory {
                copiedDirectories.append(entry.relativePath)
            }
        }
        return copies
    }

    static func enqueue(_ copies: [Copy]) throws {
        // Validate the entire plan before starting its first filesystem operation.
        for copy in copies { try Transfers.validate([copy.source], destination: copy.destination) }
        for copy in copies {
            TransferQueue.shared.enqueue(kind: .copy, sources: [copy.source],
                                         to: copy.destination, replaceExisting: true)
        }
    }
}

// MARK: - Dialog

struct CompareDialog: View {
    @ObservedObject private var interfaceSettings = Settings.shared
    @ObservedObject var model: WindowModel
    var maxHeight: CGFloat = 340
    let onClose: () -> Void

    @State private var leftURL: URL?
    @State private var rightURL: URL?
    @State private var comparison: FolderComparison?
    @State private var comparisonGeneration = UUID()
    private var entries: [CompareEntry] { comparison?.entries ?? [] }
    @State private var scanning = false
    @State private var differencesOnly = true
    private var scanned: Bool { comparison != nil }

    private var shown: [CompareEntry] {
        differencesOnly ? entries.filter { $0.status != .same } : entries
    }

    private var counts: (left: Int, right: Int, diff: Int) {
        (entries.filter { $0.status == .onlyLeft }.count,
         entries.filter { $0.status == .onlyRight }.count,
         entries.filter { $0.status == .different }.count)
    }

    var body: some View {
        WinDialog(title: L("Compare and sync folders"), width: 680, onClose: onClose) {
            VStack(alignment: .leading, spacing: 0) {
                folderPickers
                Divider().overlay(Win.divider)
                results
            }
        } footer: {
            WinDialogButton(title: L("Copy right"), enabled: canSync) {
                sync(fromLeft: true)
            }
            WinDialogButton(title: L("Copy left"), enabled: canSync) {
                sync(fromLeft: false)
            }
            WinDialogButton(title: L("Close"), primary: true, action: onClose)
        }
        .onAppear {
            leftURL = model.left.currentDirectory
            rightURL = model.right?.currentDirectory
        }
        .onChange(of: leftURL) { _, _ in invalidateComparison() }
        .onChange(of: rightURL) { _, _ in invalidateComparison() }
    }

    private var canSync: Bool {
        comparison?.matches(left: leftURL, right: rightURL) == true
            && !shown.isEmpty && !scanning
    }

    private var folderPickers: some View {
        VStack(spacing: 10) {
            FolderPickerRow(title: L("Left"), url: $leftURL).disabled(scanning)
            FolderPickerRow(title: L("Right"), url: $rightURL).disabled(scanning)
            HStack(spacing: 12) {
                WinDialogButton(title: scanning ? L("Comparing…") : L("Compare"),
                                primary: true,
                                enabled: leftURL != nil && rightURL != nil && !scanning) {
                    compare()
                }
                HStack(spacing: 7) {
                    WinCheckbox(checked: differencesOnly) { differencesOnly.toggle() }
                    Text(L("Differences only")).font(Win.body(12)).foregroundStyle(Win.text)
                }
                Spacer()
                if scanned {
                    Text(LF("{0} only left · {1} only right · {2} differ", counts.left, counts.right, counts.diff))
                        .font(Win.body(11)).foregroundStyle(Win.textSecondary)
                }
            }
        }
        .padding(16)
    }

    private var results: some View {
        Group {
            if !scanned {
                Text(L("Pick two folders and compare them."))
                    .font(Win.body(12)).foregroundStyle(Win.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else if shown.isEmpty {
                Text(differencesOnly ? L("The folders match.") : L("Both folders are empty."))
                    .font(Win.body(12)).foregroundStyle(Win.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(shown) { entry in
                            HStack(spacing: 10) {
                                Glyph(icon: entry.isDirectory ? .folderOutline : .document,
                                      size: 14, color: Win.textSecondary, weight: 1.15)
                                Text(entry.relativePath)
                                    .font(Win.body(12)).foregroundStyle(Win.text)
                                    .lineLimit(1)
                                Spacer(minLength: 12)
                                Text(L(entry.status.rawValue))
                                    .font(Win.body(11))
                                    .foregroundStyle(colour(entry.status))
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 26)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(height: min(260, maxHeight - 60))
            }
        }
    }

    private func colour(_ status: CompareEntry.Status) -> Color {
        switch status {
        case .onlyLeft, .onlyRight: return Win.accent
        case .different: return Win.danger
        case .same: return Win.textTertiary
        }
    }

    private func compare() {
        guard let left = leftURL, let right = rightURL else { return }
        scanning = true
        comparisonGeneration = UUID()
        let generation = comparisonGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let result = FolderCompare.run(left: left, right: right)
            DispatchQueue.main.async {
                guard comparisonGeneration == generation, leftURL == left, rightURL == right else { return }
                comparison = FolderComparison(left: left, right: right, entries: result)
                scanning = false
            }
        }
    }

    private func invalidateComparison() {
        comparisonGeneration = UUID()
        comparison = nil
        scanning = false
    }

    private func sync(fromLeft: Bool) {
        guard let comparison, comparison.matches(left: leftURL, right: rightURL), !scanning else { return }
        let copies = FolderSync.plan(comparison, fromLeft: fromLeft)
        guard !copies.isEmpty else { NSSound.beep(); return }
        do {
            try FolderSync.enqueue(copies)
            onClose()
        } catch {
            model.active.sheet = .error(error.localizedDescription)
        }
    }

}

struct FolderPickerRow: View {
    @ObservedObject private var interfaceSettings = Settings.shared
    let title: String
    @Binding var url: URL?

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(Win.body(12)).foregroundStyle(Win.textSecondary)
                .frame(width: 44, alignment: .leading)
            Text(url?.path ?? L("Choose a folder"))
                .font(Win.body(12))
                .foregroundStyle(url == nil ? Win.textTertiary : Win.text)
                .lineLimit(1).truncationMode(.head)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .background(WinRR(radius: 4).fill(Win.field))
                .overlay(WinRR(radius: 4).stroke(Win.stroke, lineWidth: 1))
            WinButton(padding: 10, height: 28) {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.prompt = L("Choose")
                panel.begin { response in
                    if response == .OK, let picked = panel.url { url = picked }
                }
            } content: {
                Text(L("Browse")).font(Win.body(11)).foregroundStyle(Win.text)
            }
            .overlay(WinRR(radius: 4).stroke(Win.stroke, lineWidth: 1))
        }
    }
}
