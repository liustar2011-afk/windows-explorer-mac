import Foundation

/// Nonrecursive cleanup with explicit rules and recoverable deletion only.
enum JunkCleaner {
    struct Candidate {
        let url: URL
        let inode: UInt64
        let device: UInt64
        let size: UInt64
        let modified: Date
    }

    struct Result {
        var trashed: [(original: URL, trashed: URL)] = []
        var failures: [String] = []
    }

    final class Job {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    static func eligibleDirectory(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path != "/",
              !resolved.pathComponents.contains(where: { [".Trash", ".Trashes"].contains($0) }) else { return false }
        for prefix in ["/System", "/Library", "/usr", "/bin", "/sbin", "/dev"] {
            if resolved.path == prefix || resolved.path.hasPrefix(prefix + "/") { return false }
        }
        var ancestor = resolved
        while ancestor.path != "/" {
            if (try? ancestor.resourceValues(forKeys: [.isPackageKey]).isPackage) == true { return false }
            ancestor.deleteLastPathComponent()
        }
        return (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    static func candidate(_ url: URL, includeOldTemporaryFiles: Bool = false,
                          now: Date = Date()) -> Candidate? {
        let name = url.lastPathComponent
        let metadata = name == ".DS_Store" || ["thumbs.db", "desktop.ini"].contains(name.lowercased())
        let temporary = includeOldTemporaryFiles && ["tmp", "temp"].contains(url.pathExtension.lowercased())
        guard metadata || temporary,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let device = attributes[.systemNumber] as? NSNumber,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        if !metadata && now.timeIntervalSince(modified) < 30 * 24 * 60 * 60 { return nil }
        return Candidate(url: url, inode: inode.uint64Value, device: device.uint64Value,
                         size: size.uint64Value, modified: modified)
    }

    static func scan(_ directory: URL, includeOldTemporaryFiles: Bool = false,
                     now: Date = Date()) throws -> [Candidate] {
        guard eligibleDirectory(directory) else { return [] }
        let children = try FileManager.default.contentsOfDirectory(
            at: directory.resolvingSymlinksInPath(), includingPropertiesForKeys: nil)
        return children.compactMap { candidate($0, includeOldTemporaryFiles: includeOldTemporaryFiles, now: now) }
    }

    static func clean(_ directory: URL, includeOldTemporaryFiles: Bool = false,
                      job: Job, now: Date = Date(),
                      trash: (URL) throws -> URL = moveToTrash) -> Result {
        var result = Result()
        guard !job.isCancelled else { return result }
        let candidates: [Candidate]
        do { candidates = try scan(directory, includeOldTemporaryFiles: includeOldTemporaryFiles, now: now) }
        catch { result.failures.append(error.localizedDescription); return result }
        for original in candidates {
            guard !job.isCancelled, eligibleDirectory(directory) else { break }
            // Recheck type, identity and modification before moving a scanned file.
            guard let current = candidate(original.url, includeOldTemporaryFiles: includeOldTemporaryFiles, now: now),
                  current.inode == original.inode, current.device == original.device,
                  current.size == original.size, current.modified == original.modified else { continue }
            do { result.trashed.append((original.url, try trash(original.url))) }
            catch { result.failures.append("\(original.url.lastPathComponent): \(error.localizedDescription)") }
        }
        return result
    }

    private static func moveToTrash(_ url: URL) throws -> URL {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        guard let destination = resulting as URL? else { throw CocoaError(.fileWriteUnknown) }
        return destination
    }
}
