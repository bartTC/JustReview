import Foundation

/// One file in the list, relative to HEAD. Read-only: we never write to the repo.
struct FileChange: Identifiable, Hashable {
    /// Git status letter (M, A, D, R, C, T, U), "?" for untracked, " " for unchanged
    /// (only listed when "Show All Files" is on).
    let status: Character
    let path: String
    let oldPath: String?

    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
    var isUntracked: Bool { status == "?" }
    var isUnchanged: Bool { status == " " }

    var statusLabel: String {
        switch status {
        case "?": return "U" // untracked
        case "U": return "!" // merge conflict (git's own letter would clash with untracked)
        default: return String(status)
        }
    }

    var statusDescription: String {
        switch status {
        case "M": return "Modified"
        case "A": return "Added"
        case "D": return "Deleted"
        case "R": return "Renamed"
        case "C": return "Copied"
        case "T": return "Type changed"
        case "U": return "Conflicted"
        case "?": return "New (untracked)"
        case " ": return "Unchanged"
        default: return String(status)
        }
    }
}

struct GitError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Thin wrapper around the git CLI. Only read-only commands are used.
enum Git {
    struct Output {
        let status: Int32
        let data: Data
        var text: String { String(decoding: data, as: UTF8.self) }
    }

    static func run(_ args: [String], in dir: URL) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-c", "core.quotepath=off"] + args
        process.currentDirectoryURL = dir

        var env = ProcessInfo.processInfo.environment
        // Don't take index.lock for `git status` refreshes; we only read.
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_PAGER"] = "cat"
        process.environment = env

        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        try process.run()
        // Drain stdout before waiting, otherwise large diffs fill the pipe and deadlock.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, data: data)
    }

    static func toplevel(for url: URL) throws -> URL {
        let r = try run(["rev-parse", "--show-toplevel"], in: url)
        guard r.status == 0 else {
            throw GitError(message: "“\(url.path)” is not inside a git repository.")
        }
        return URL(fileURLWithPath: r.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func branch(in root: URL) -> String {
        if let r = try? run(["symbolic-ref", "--short", "-q", "HEAD"], in: root), r.status == 0 {
            return r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let r = try? run(["rev-parse", "--short", "HEAD"], in: root), r.status == 0 {
            return "detached at " + r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    /// git's well-known empty tree, used as the base in a repo with no commits yet.
    private static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    static func base(in root: URL) -> String {
        if let r = try? run(["rev-parse", "--verify", "-q", "HEAD"], in: root), r.status == 0 { return "HEAD" }
        return emptyTree
    }

    /// Everything that differs from HEAD (staged or not), plus untracked files.
    static func changes(in root: URL) throws -> [FileChange] {
        let base = base(in: root)
        let r = try run(["diff", base, "--name-status", "-z", "-M", "--no-ext-diff"], in: root)
        guard r.status == 0 else { throw GitError(message: "git diff failed.") }

        var changes = parseNameStatus(r.text)

        let untracked = try run(["ls-files", "--others", "--exclude-standard", "-z"], in: root)
        for path in untracked.text.split(separator: "\0", omittingEmptySubsequences: true) {
            changes.append(FileChange(status: "?", path: String(path), oldPath: nil))
        }

        return changes.sorted { treeOrder($0.path, $1.path) }
    }

    /// File content at the diff base (HEAD), or nil if it doesn't exist there.
    static func show(_ path: String, in root: URL) -> String? {
        showData(path, in: root).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The file's content at HEAD, as raw bytes (for binary files such as images).
    static func showData(_ path: String, in root: URL) -> Data? {
        guard let r = try? run(["show", "\(base(in: root)):\(path)"], in: root), r.status == 0 else { return nil }
        return r.data
    }

    /// Every tracked or untracked (not ignored) file in the working tree.
    static func allFiles(in root: URL) throws -> [String] {
        let r = try run(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: root)
        guard r.status == 0 else { throw GitError(message: "git ls-files failed.") }
        return Array(Set(r.text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)))
    }

    /// Order matching the file tree: at each level folders before files, then by name.
    static func treeOrder(_ a: String, _ b: String) -> Bool {
        let x = a.split(separator: "/"), y = b.split(separator: "/")
        var i = 0
        while i < min(x.count, y.count) - 1, x[i] == y[i] { i += 1 }
        let xIsDir = i < x.count - 1, yIsDir = i < y.count - 1
        if xIsDir != yIsDir { return xIsDir }
        return x[i].localizedStandardCompare(y[i]) == .orderedAscending
    }

    static func diff(for change: FileChange, in root: URL) throws -> String {
        if change.isUnchanged { return fullFile(change.path, in: root) }
        var args = ["diff", "--no-color", "--no-ext-diff", "-M"]
        if change.isUntracked {
            args += ["--no-index", "--", "/dev/null", change.path]
        } else {
            args += [base(in: root), "--"]
            if let old = change.oldPath { args.append(old) }
            args.append(change.path)
        }
        return try run(args, in: root).text
    }

    /// An unchanged file presented as one all-context hunk, so it renders (and can be
    /// annotated) like any diff.
    private static func fullFile(_ path: String, in root: URL) -> String {
        guard let data = FileManager.default.contents(atPath: root.appendingPathComponent(path).path) else {
            return ""
        }
        if data.prefix(8000).contains(0) { return "Binary files differ\n" }
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard !lines.isEmpty else { return "" }
        return "@@ -1,\(lines.count) +1,\(lines.count) @@\n" + lines.map { " " + $0 }.joined(separator: "\n")
    }
}

// MARK: - History

/// One commit in the history list.
struct Commit: Identifiable, Hashable {
    let id: String          // full hash
    let shortHash: String
    let author: String
    let date: Date
    let subject: String
    /// Branch and tag names pointing at the commit ("HEAD -> main", "tag: v1.0.0", …).
    let refs: [String]
}

/// A commit with its full message and its changes, one diff per file.
struct CommitDetails {
    let hash: String
    let parents: [String]
    let author: String
    let email: String
    let date: Date
    let subject: String
    let body: String
    let files: [(change: FileChange, patch: String)]
}

extension Git {
    private static let fieldSep = "\u{1f}", recordSep = "\u{1e}"

    /// The newest `limit` commits reachable from HEAD (empty in a repo without commits).
    static func log(in root: URL, limit: Int) throws -> [Commit] {
        let r = try run(["log", "-n", String(limit), "--no-color",
                         "--format=%H%x1f%h%x1f%an%x1f%at%x1f%D%x1f%s%x1e"], in: root)
        guard r.status == 0 else { return [] }
        return r.text.components(separatedBy: recordSep).compactMap { record in
            let f = record.trimmingCharacters(in: .newlines).components(separatedBy: fieldSep)
            guard f.count == 6 else { return nil }
            let refs = f[4].isEmpty ? [] : f[4].components(separatedBy: ", ")
            return Commit(id: f[0], shortHash: f[1], author: f[2],
                          date: Date(timeIntervalSince1970: TimeInterval(f[3]) ?? 0),
                          subject: f[5], refs: refs)
        }
    }

    /// The commit's message and per-file diffs against its first parent (all files added for the
    /// root commit).
    static func commitDetails(_ hash: String, in root: URL) throws -> CommitDetails {
        let info = try run(["show", "-s", "--no-color",
                            "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s%x1f%b", hash], in: root)
        guard info.status == 0 else { throw GitError(message: "Commit \(hash) not found.") }
        let f = info.text.components(separatedBy: fieldSep)
        guard f.count >= 7 else { throw GitError(message: "Commit \(hash) not found.") }

        let diffArgs = ["--format=", "--diff-merges=first-parent", "-M", "--no-color", "--no-ext-diff"]
        let names = try run(["show"] + diffArgs + ["--name-status", "-z", hash], in: root)
        let patch = try run(["show"] + diffArgs + ["-p", hash], in: root)
        let changes = parseNameStatus(names.text)
        let chunks = splitPatch(patch.text)
        // Both come from the same diff, in the same order; pair them up.
        let files = changes.enumerated().map { i, change in
            (change: change, patch: chunks[safe: i] ?? "")
        }
        return CommitDetails(hash: f[0], parents: f[1].split(separator: " ").map(String.init),
                             author: f[2], email: f[3],
                             date: Date(timeIntervalSince1970: TimeInterval(f[4]) ?? 0),
                             subject: f[5], body: f[6...].joined(separator: fieldSep)
                                .trimmingCharacters(in: .whitespacesAndNewlines),
                             files: files)
    }

    /// A file's content at a revision, or nil if it doesn't exist there.
    static func show(_ path: String, at rev: String, in root: URL) -> String? {
        guard let r = try? run(["show", "\(rev):\(path)"], in: root), r.status == 0 else { return nil }
        return r.text
    }

    /// `--name-status -z` output as file changes (renames/copies carry their old path).
    static func parseNameStatus(_ text: String) -> [FileChange] {
        var changes: [FileChange] = []
        let parts = text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var i = 0
        while i < parts.count {
            guard let status = parts[i].first else { i += 1; continue }
            if status == "R" || status == "C", i + 2 < parts.count {
                changes.append(FileChange(status: status, path: parts[i + 2], oldPath: parts[i + 1]))
                i += 3
            } else if i + 1 < parts.count {
                changes.append(FileChange(status: status, path: parts[i + 1], oldPath: nil))
                i += 2
            } else {
                break
            }
        }
        return changes
    }

    /// A multi-file patch cut into one piece per file (each starting at its "diff --git" line).
    static func splitPatch(_ text: String) -> [String] {
        var chunks: [String] = []
        var current: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") || line.hasPrefix("diff --cc ") {
                if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
                current = []
            }
            current.append(line)
        }
        if !current.isEmpty, current.contains(where: { $0.hasPrefix("diff ") }) {
            chunks.append(current.joined(separator: "\n"))
        }
        return chunks
    }
}
