import CoreServices
import Foundation

/// Watches a repository directory tree with FSEvents and calls `onChange` (on the main queue)
/// when something relevant changes. Events are coalesced by FSEvents' latency window.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let rootPath: String
    private let onChange: () -> Void

    init(root: URL, latency: TimeInterval = 0.3, onChange: @escaping () -> Void) {
        self.rootPath = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path
            : root.standardizedFileURL.path + "/"
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            if changed.contains(where: watcher.isRelevant) { watcher.onChange() }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, callback, &context, [rootPath] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// Working-tree changes count; inside .git only HEAD/index (the .git dir itself) and refs matter,
    /// so object-database churn doesn't trigger reloads.
    private func isRelevant(_ path: String) -> Bool {
        var p = path
        if !p.hasSuffix("/") { p += "/" }
        guard p.hasPrefix(rootPath) else { return true }
        let rel = String(p.dropFirst(rootPath.count))
        if rel.hasPrefix(".git/") {
            return rel == ".git/" || rel.hasPrefix(".git/refs/")
        }
        return true
    }
}
