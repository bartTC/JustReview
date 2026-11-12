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
        let text: String
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
        return Output(status: process.terminationStatus, text: String(decoding: data, as: UTF8.self))
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

        var changes: [FileChange] = []
        let parts = r.text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
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

        let untracked = try run(["ls-files", "--others", "--exclude-standard", "-z"], in: root)
        for path in untracked.text.split(separator: "\0", omittingEmptySubsequences: true) {
            changes.append(FileChange(status: "?", path: String(path), oldPath: nil))
        }

        return changes.sorted { treeOrder($0.path, $1.path) }
    }

    /// File content at the diff base (HEAD), or nil if it doesn't exist there.
    static func show(_ path: String, in root: URL) -> String? {
        guard let r = try? run(["show", "\(base(in: root)):\(path)"], in: root), r.status == 0 else { return nil }
        return r.text
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
