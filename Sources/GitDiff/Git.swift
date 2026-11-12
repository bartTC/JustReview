import Foundation

/// One changed file, relative to HEAD. Read-only: we never write to the repo.
struct FileChange: Identifiable, Hashable {
    /// Git status letter (M, A, D, R, C, T, U), or "?" for untracked.
    let status: Character
    let path: String
    let oldPath: String?

    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
    var isUntracked: Bool { status == "?" }

    var statusLabel: String { status == "?" ? "N" : String(status) }

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

        return changes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func diff(for change: FileChange, in root: URL) throws -> String {
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
}
