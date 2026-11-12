import AppKit

/// "Install Command Line Tool…": symlinks /usr/local/bin/jrev to the launcher script
/// bundled in JustReview.app, so `jrev [path]` works from any shell.
enum CLIInstaller {
    static let linkPath = "/usr/local/bin/jrev"

    static func install() {
        guard let script = Bundle.main.url(forResource: "jrev", withExtension: nil)?.path else {
            alert("Command line tool not found",
                  "Run JustReview.app built with ./build.sh to install the command line tool.")
            return
        }
        let fm = FileManager.default

        // Never clobber a real file someone else put there; replacing a symlink is fine.
        let existingLink = try? fm.destinationOfSymbolicLink(atPath: linkPath)
        if existingLink == nil, fm.fileExists(atPath: linkPath) {
            alert("Can’t install command line tool",
                  "\(linkPath) already exists and is not a link. Remove it and try again.")
            return
        }

        do {
            try fm.createDirectory(atPath: (linkPath as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            if existingLink != nil { try fm.removeItem(atPath: linkPath) }
            try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: script)
        } catch {
            // /usr/local/bin usually needs admin rights: ask via the standard password prompt.
            let shell = "mkdir -p /usr/local/bin && ln -sfn \(quoted(script)) \(quoted(linkPath))"
            let source = "do shell script \"\(shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
            var errorInfo: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
            if let errorInfo {
                if (errorInfo[NSAppleScript.errorNumber] as? Int) == -128 { return } // user cancelled
                alert("Can’t install command line tool",
                      errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown error.")
                return
            }
        }
        alert("Command line tool installed",
              "You can now run “jrev” in a repository to review it, or “jrev <path>”.")
    }

    private static func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }
}
