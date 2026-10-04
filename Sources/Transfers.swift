import Foundation
import AppKit
import Darwin

// MARK: - Model

struct TransferJob: Identifiable {
    enum Kind: String { case copy = "Copying", move = "Moving", delete = "Deleting" }
    enum State: Equatable { case waiting, running, finished, cancelled, failed(String) }

    let id = UUID()
    let kind: Kind
    let sources: [URL]
    let destination: URL?
    var replaceExisting = false
    var state: State = .waiting
    var bytesTotal: Int64 = 0
    var bytesDone: Int64 = 0
    var filesTotal: Int = 0
    var filesDone: Int = 0
    var currentName: String = ""
    var startedAt: Date? = nil
    /// Paths produced by the job, for undo.
    var created: [URL] = []
    var moved: [(from: URL, to: URL)] = []

    var fraction: Double {
        guard bytesTotal > 0 else { return state == .finished ? 1 : 0 }
        return min(1, Double(bytesDone) / Double(bytesTotal))
    }

    var isActive: Bool { state == .waiting || state == .running }

    /// "12.4 MB of 300 MB", the way Explorer's copy dialog reads.
    var sizeText: String {
        LF("{0} of {1}", FileItem.friendlySize(bytesDone), FileItem.friendlySize(bytesTotal))
    }

    var rateText: String {
        guard let startedAt, state == .running else { return "" }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 0.6, bytesDone > 0 else { return "" }
        let perSecond = Double(bytesDone) / elapsed
        let remaining = Double(bytesTotal - bytesDone) / max(perSecond, 1)
        return LF("{0}/s, {1} left", FileItem.friendlySize(Int64(perSecond)), TransferJob.timeText(remaining))
    }

    static func timeText(_ seconds: Double) -> String {
        if seconds < 60 { return LF("{0} seconds", Int(seconds.rounded())) }
        if seconds < 3600 { return LF("{0} minutes", Int((seconds / 60).rounded())) }
        return String(format: L("%.1f hours"), seconds / 3600)
    }
}

// MARK: - Queue

final class TransferQueue: ObservableObject {
    static let shared = TransferQueue()

    @Published private(set) var jobs: [TransferJob] = []
    @Published var panelOpen = false

    private let worker = DispatchQueue(label: "com.winexplorer.transfers", qos: .userInitiated)
    private var cancelled = Set<UUID>()
    private var completion: [UUID: (TransferJob) -> Void] = [:]
    private var running = false

    var active: [TransferJob] { jobs.filter(\.isActive) }
    var hasActive: Bool { !active.isEmpty }

    var overallFraction: Double {
        let running = active
        guard !running.isEmpty else { return 0 }
        return running.map(\.fraction).reduce(0, +) / Double(running.count)
    }

    var summary: String {
        let running = active
        guard let first = running.first else { return "" }
        if running.count > 1 { return LF("{0} {1} sets of items", L(first.kind.rawValue), running.count) }
        return LF("{0} {1} of {2} items", L(first.kind.rawValue), first.filesDone, first.filesTotal)
    }

    // MARK: Submitting work

    func enqueue(kind: TransferJob.Kind, sources: [URL], to destination: URL?,
                 replaceExisting: Bool = false, onFinish: ((TransferJob) -> Void)? = nil) {
        var job = TransferJob(kind: kind, sources: sources, destination: destination)
        job.replaceExisting = replaceExisting
        job.filesTotal = sources.count
        jobs.append(job)
        if let onFinish { completion[job.id] = onFinish }
        pump()
    }

    func cancel(_ id: UUID) {
        cancelled.insert(id)
        if let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state == .waiting {
            jobs[i].state = .cancelled
            completion.removeValue(forKey: id)?(jobs[i])
            cancelled.remove(id)
        }
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
    }

    // MARK: Running

    private func pump() {
        guard !running, let next = jobs.firstIndex(where: { $0.state == .waiting }) else { return }
        running = true
        let job = jobs[next]
        jobs[next].state = .running
        jobs[next].startedAt = Date()

        worker.async { [weak self] in
            guard let self else { return }
            let result = self.perform(job)
            DispatchQueue.main.async {
                if let i = self.jobs.firstIndex(where: { $0.id == job.id }) {
                    self.jobs[i] = result
                }
                self.cancelled.remove(job.id)
                self.completion.removeValue(forKey: job.id)?(result)
                self.running = false
                self.pump()
                if !self.hasActive {
                    // Tidy finished rows away once the queue drains.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                        if !self.hasActive && !self.panelOpen { self.clearFinished() }
                    }
                }
            }
        }
    }

    private func isCancelled(_ id: UUID) -> Bool {
        var result = false
        DispatchQueue.main.sync { result = self.cancelled.contains(id) }
        return result
    }

    private func update(_ id: UUID, _ change: @escaping (inout TransferJob) -> Void) {
        DispatchQueue.main.async {
            guard let i = self.jobs.firstIndex(where: { $0.id == id }) else { return }
            change(&self.jobs[i])
        }
    }

    private enum CopyError: Error { case cancelled }

    private func checkCancellation(_ id: UUID) throws {
        if isCancelled(id) { throw CopyError.cancelled }
    }

    private func perform(_ submitted: TransferJob) -> TransferJob {
        var job = submitted
        let fm = FileManager.default
        do {
            if job.kind != .delete {
                guard let destination = job.destination else { throw CocoaError(.fileNoSuchFile) }
                try Transfers.validate(job.sources, destination: destination)
            }
            job.filesTotal = 0
            for url in job.sources {
                try checkCancellation(job.id)
                let (bytes, files) = Transfers.measure(url)
                job.bytesTotal += bytes
                job.filesTotal += files
            }
            let bytes = job.bytesTotal, files = job.filesTotal
            update(job.id) { $0.bytesTotal = bytes; $0.filesTotal = files }

            for source in job.sources {
                try checkCancellation(job.id)
                if job.kind == .delete {
                    let (bytes, files) = Transfers.measure(source)
                    try fm.removeItem(at: source)
                    job.bytesDone += bytes
                    job.filesDone += files
                    continue
                }
                let destination = job.destination!
                if job.kind == .move && Transfers.sameDirectory(source.deletingLastPathComponent(), destination) {
                    continue
                }
                let target = job.replaceExisting
                    ? destination.appendingPathComponent(source.lastPathComponent)
                    : Ops.uniqueURL(for: source.lastPathComponent, in: destination,
                                    copySuffix: Transfers.sameDirectory(source.deletingLastPathComponent(), destination))
                if job.kind == .move && Transfers.sameVolume(source, destination) {
                    try fm.moveItem(at: source, to: target)
                    job.moved.append((source, target))
                    let (bytes, files) = Transfers.measure(target)
                    job.bytesDone += bytes
                    job.filesDone += files
                } else {
                    // Own an isolated staging directory so errors/cancellation never
                    // expose a partial destination or remove an unrelated existing file.
                    let staging = destination.appendingPathComponent(".winexp-transfer-" + UUID().uuidString)
                    try fm.createDirectory(at: staging, withIntermediateDirectories: false)
                    defer { try? fm.removeItem(at: staging) }
                    let staged = staging.appendingPathComponent(source.lastPathComponent)
                    try copyTree(source, to: staged, job: &job)
                    try checkCancellation(job.id)
                    let replaced = job.replaceExisting && (try? fm.attributesOfItem(atPath: target.path)) != nil
                        ? try Ops.trashChecked([target]) : []
                    do {
                        try fm.moveItem(at: staged, to: target)
                    } catch {
                        try? Ops.movePairs(replaced.map { (from: $0.trashed, to: $0.original) })
                        throw error
                    }
                    if job.kind == .move {
                        // Cancellation here leaves a complete copy and the original.
                        // It must never delete the original after an incomplete copy.
                        do {
                            try checkCancellation(job.id)
                            try fm.removeItem(at: source)
                        } catch {
                            job.created.append(target)
                            throw error
                        }
                        job.moved.append((source, target))
                    } else {
                        job.created.append(target)
                    }
                }
                let done = job.bytesDone, count = job.filesDone
                update(job.id) {
                    $0.bytesDone = done; $0.filesDone = count
                    $0.currentName = source.lastPathComponent
                }
            }
            job.state = .finished
            job.bytesDone = job.bytesTotal
        } catch CopyError.cancelled {
            job.state = .cancelled
        } catch {
            job.state = .failed(error.localizedDescription)
        }
        return job
    }

    private func copyTree(_ source: URL, to target: URL, job: inout TransferJob) throws {
        try checkCancellation(job.id)
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: source.path)
        let type = attributes[.type] as? FileAttributeType
        if type == .typeSymbolicLink {
            // Do not dereference links, including links to directories or missing targets.
            let link = try fm.destinationOfSymbolicLink(atPath: source.path)
            try fm.createSymbolicLink(atPath: target.path, withDestinationPath: link)
            job.filesDone += 1
        } else if type == .typeDirectory {
            try fm.createDirectory(at: target, withIntermediateDirectories: false)
            let children = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            for child in children {
                try copyTree(child, to: target.appendingPathComponent(child.lastPathComponent), job: &job)
            }
            try copyMetadata(source, to: target)
            job.filesDone += 1
        } else if type == .typeRegular {
            try copyFile(source, to: target, job: &job)
        } else {
            try fm.copyItem(at: source, to: target)
            job.filesDone += 1
        }
        try checkCancellation(job.id)
    }

    private func copyMetadata(_ source: URL, to target: URL) throws {
        let flags = copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW_SRC | COPYFILE_NOFOLLOW_DST)
        guard copyfile(source.path, target.path, nil, flags) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func copyFile(_ source: URL, to target: URL, job: inout TransferJob) throws {
        let id = job.id
        update(id) { $0.currentName = source.lastPathComponent }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let descriptor = open(target.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? output.close() }
        var sinceUpdate: Int64 = 0
        while true {
            try checkCancellation(id)
            guard let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            job.bytesDone += Int64(chunk.count)
            sinceUpdate += Int64(chunk.count)
            if sinceUpdate >= 4 << 20 {
                let done = job.bytesDone
                sinceUpdate = 0
                update(id) { $0.bytesDone = done }
            }
        }
        try output.synchronize()
        try checkCancellation(id)
        try copyMetadata(source, to: target)
        job.filesDone += 1
        let done = job.bytesDone, files = job.filesDone
        update(id) { $0.bytesDone = done; $0.filesDone = files }
    }

}

// MARK: - Helpers

enum Transfers {
    /// Resolve aliases in the parent directory without dereferencing the entry
    /// itself: two symlinks to one target are still distinct selectable files.
    static func entryPath(_ url: URL) -> String {
        url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
    }

    static func sameDirectory(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Validate every entry point, not just drag-and-drop. Resolve directory
    /// aliases so a symlink to a descendant cannot bypass the containment check.
    static func validate(_ sources: [URL], destination: URL) throws {
        let fm = FileManager.default
        guard (try destination.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let dest = destination.resolvingSymlinksInPath().standardizedFileURL.path
        for source in sources {
            let attributes = try fm.attributesOfItem(atPath: source.path)
            if attributes[.type] as? FileAttributeType == .typeDirectory {
                let path = source.resolvingSymlinksInPath().standardizedFileURL.path
                if dest == path || dest.hasPrefix(path == "/" ? "/" : path + "/") {
                    throw NSError(domain: "FileExplorer.Transfer", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: L("A folder cannot be copied or moved into itself.")])
                }
            }
        }
    }

    static func measure(_ url: URL) -> (bytes: Int64, files: Int) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           attrs[.type] as? FileAttributeType == .typeSymbolicLink {
            return (0, 1)
        }
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return (0, 0) }
        if !isDir.boolValue {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return (Int64(size), 1)
        }
        var bytes: Int64 = 0, files = 1
        let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey],
                                   options: [], errorHandler: { _, _ in true })
        while let child = walker?.nextObject() as? URL {
            let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey])
            files += 1
            if values?.isDirectory == true { continue }
            if values?.isSymbolicLink != true { bytes += Int64(values?.fileSize ?? 0) }
        }
        return (bytes, max(files, 1))
    }

    static func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let idA = (try? a.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        let idB = (try? b.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        guard let x = idA as? NSObject, let y = idB as? NSObject else { return false }
        return x == y
    }
}
