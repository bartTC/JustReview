import AppKit
import SwiftUI

// MARK: - File list

/// The Changes and the Files tab: the files as a tree, the shown file selected. Each tab has a
/// list of its own (see `FileListPanes`), so nothing carries over from one to the other.
struct FileListView: View {
    @ObservedObject var model: RepoModel
    let handle: WindowHandle
    let panes: FileListPanes
    /// Files tab: unchanged files are listed too.
    let showAll: Bool
    @AppStorage(FontPrefs.listFamily) private var family = ""
    @AppStorage(FontPrefs.listSize) private var size = FontPrefs.defaultListSize

    var body: some View {
        FileOutline(panes: panes, showAll: showAll, root: model.root, changes: model.changes,
                    unchanged: showAll ? model.unchanged : [], selection: model.selection,
                    font: FontPrefs.listFont(family: family, size: size),
                    select: { model.selection = $0 },
                    // Right-click or ⌘-click: the file's diff in a window of its own (no file
                    // list, no annotations pane).
                    openInNewWindow: { path in
                        guard let root = model.root else { return }
                        WindowRouter.shared.openFileWindow(root: root, file: path)
                    })
        // Sidebar controls live in the sidebar's part of the toolbar (right-aligned).
        .toolbar {
            ToolbarItemGroup {
                Spacer()
                WorktreeMenu(model: model, handle: handle)
                OpenRepositoryButton(handle: handle)
            }
        }
        .overlay {
            if model.root == nil {
                NoRepositoryView(handle: handle)
            } else if model.changes.isEmpty && !showAll {
                ContentUnavailableView("No Changes", systemImage: "checkmark.circle",
                                       description: Text("Nothing differs from HEAD."))
            }
        }
    }
}

/// The two file lists of a window, Changes and Files. They live as long as the window's
/// sidebar, so each keeps its scroll position and folded folders while another tab is shown.
@MainActor
final class FileListPanes: ObservableObject {
    fileprivate let changes = FileOutlinePane(showAll: false)
    fileprivate let files = FileOutlinePane(showAll: true)
}

// MARK: - File tree

struct FileTreeNode {
    let path: String
    let name: String
    let change: FileChange?          // nil for folders
    var children: [FileTreeNode] = []
    var hasChanges = false
}

enum FileTree {
    private final class Folder {
        var folders: [String: Folder] = [:]
        var files: [FileChange] = []
    }

    static func build(_ files: [FileChange]) -> [FileTreeNode] {
        let root = Folder()
        for file in files {
            var folder = root
            for part in file.path.split(separator: "/").dropLast().map(String.init) {
                if folder.folders[part] == nil { folder.folders[part] = Folder() }
                folder = folder.folders[part]!
            }
            folder.files.append(file)
        }
        return nodes(root, prefix: "")
    }

    private static func nodes(_ folder: Folder, prefix: String) -> [FileTreeNode] {
        var result: [FileTreeNode] = []
        for name in folder.folders.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            var sub = folder.folders[name]!
            var label = name
            // Compact chains of single-child folders: "src/utils/mcp-oauth".
            while sub.files.isEmpty, sub.folders.count == 1, let (next, nextFolder) = sub.folders.first {
                label += "/" + next
                sub = nextFolder
            }
            let path = prefix + label
            let children = nodes(sub, prefix: path + "/")
            result.append(FileTreeNode(path: path, name: label, change: nil, children: children,
                                       hasChanges: children.contains { $0.hasChanges }))
        }
        for file in folder.files.sorted(by: { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }) {
            result.append(FileTreeNode(path: file.path, name: file.fileName, change: file,
                                       hasChanges: !file.isUnchanged))
        }
        return result
    }
}

// MARK: - Outline view (AppKit)

/// Shows the list of the current tab. The lists are AppKit outline views, the control macOS
/// has for trees, filled and reloaded by us: a SwiftUI `List` left rows of the list shown
/// before drawn over the new ones when its rows changed wholesale.
private struct FileOutline: NSViewRepresentable {
    let panes: FileListPanes
    let showAll: Bool
    let root: URL?
    let changes: [FileChange]
    let unchanged: [FileChange]
    let selection: String?
    let font: NSFont
    let select: (String) -> Void
    let openInNewWindow: (String) -> Void

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        for pane in [panes.changes, panes.files] {
            pane.scrollView.removeFromSuperview() // from the container of an earlier visit
            pane.scrollView.frame = container.bounds
            pane.scrollView.autoresizingMask = [.width, .height]
            pane.scrollView.isHidden = true
            container.addSubview(pane.scrollView)
        }
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let shown = showAll ? panes.files : panes.changes
        let other = showAll ? panes.changes : panes.files
        shown.select = select
        shown.openInNewWindow = openInNewWindow
        shown.update(root: root, changes: changes, unchanged: unchanged, selection: selection, font: font)
        guard shown.scrollView.isHidden else { return }
        // The keyboard stays in the file list when it was there.
        let hadFocus = other.outline.window?.firstResponder === other.outline
        other.scrollView.isHidden = true
        shown.scrollView.isHidden = false
        if hadFocus { shown.outline.window?.makeFirstResponder(shown.outline) }
    }
}

/// A folder or a file in the outline view. One object per path for as long as it's listed, so
/// the outline view knows a row again after a reload.
private final class FileOutlineItem: NSObject {
    var path = ""
    var name = ""
    var change: FileChange?          // nil for folders
    var hasChanges = false
    var children: [FileOutlineItem] = []
    weak var parent: FileOutlineItem?

    var isFolder: Bool { change == nil }
}

/// One file list: its outline view, and what it shows.
@MainActor
fileprivate final class FileOutlinePane: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    /// Files tab: unchanged files are listed too, and folders without changes start folded.
    let showAll: Bool
    let scrollView = NSScrollView()
    let outline = FileOutlineView()
    var select: (String) -> Void = { _ in }
    var openInNewWindow: (String) -> Void = { _ in }

    private var loaded = false
    private var root: URL?
    private var changes: [FileChange] = []
    private var unchanged: [FileChange] = []
    private var font: NSFont?
    /// The file shown in the diff area: its row is the selected one.
    private var selection: String?
    private var roots: [FileOutlineItem] = []
    private var folders: [String: FileOutlineItem] = [:]
    private var files: [String: FileOutlineItem] = [:]
    /// Folders the user folded or unfolded by hand; the others follow `wantsExpanded`.
    private var expansion: [String: Bool] = [:]
    /// The shown file wasn't listed yet when it was to be scrolled to: again once it is.
    private var pendingReveal = false
    /// The outline view is being changed by us, not by the user.
    private var applying = false

    init(showAll: Bool) {
        self.showAll = showAll
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .custom
        outline.indentationPerLevel = 13
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.backgroundColor = .clear
        outline.setAccessibilityLabel(showAll ? "Files" : "Changes")
        outline.dataSource = self
        outline.delegate = self
        outline.commandClicked = { [weak self] path in self?.openInNewWindow(path) }
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
    }

    // MARK: Showing the model's state

    func update(root: URL?, changes: [FileChange], unchanged: [FileChange], selection: String?, font: NSFont) {
        let otherRepository = root != self.root
        let filesChanged = !loaded || otherRepository || changes != self.changes || unchanged != self.unchanged
        let fontChanged = font != self.font
        let selectionChanged = !loaded || selection != self.selection
        guard filesChanged || fontChanged || selectionChanged else { return }
        loaded = true
        self.selection = selection
        if otherRepository {
            self.root = root
            expansion = [:]
            folders = [:]
            files = [:]
        }
        if fontChanged {
            self.font = font
            outline.rowHeight = ceil(NSLayoutManager().defaultLineHeight(for: font)) + 12
        }
        if filesChanged {
            self.changes = changes
            self.unchanged = unchanged
            rebuild()
        }
        if filesChanged || fontChanged { reload() }
        if selectionChanged || (filesChanged && pendingReveal) { reveal() } else { syncSelection() }
    }

    /// The tree of the listed files, with the item objects of the paths listed before.
    private func rebuild() {
        // Every path once: a file listed twice would be one row object in two places.
        var seen = Set<String>()
        let listed = (changes + unchanged).filter { seen.insert($0.path).inserted }
        var folders: [String: FileOutlineItem] = [:]
        var files: [String: FileOutlineItem] = [:]
        func items(_ nodes: [FileTreeNode], parent: FileOutlineItem?) -> [FileOutlineItem] {
            nodes.map { node in
                let isFolder = node.change == nil
                let item = (isFolder ? self.folders[node.path] : self.files[node.path]) ?? FileOutlineItem()
                item.path = node.path
                item.name = node.name
                item.change = node.change
                item.hasChanges = node.hasChanges
                item.parent = parent
                item.children = items(node.children, parent: item)
                if isFolder { folders[node.path] = item } else { files[node.path] = item }
                return item
            }
        }
        roots = items(FileTree.build(listed), parent: nil)
        self.folders = folders
        self.files = files
    }

    private func reload() {
        applying = true
        defer { applying = false }
        let position = scrollView.contentView.bounds.origin
        outline.reloadData()
        applyExpansion(to: roots)
        if scrollView.contentView.bounds.origin != position { outline.scroll(position) }
    }

    /// Folders start unfolded when they contain changes (always, on the Changes tab).
    private func wantsExpanded(_ folder: FileOutlineItem) -> Bool {
        expansion[folder.path] ?? (folder.hasChanges || !showAll)
    }

    /// Folds and unfolds the folders among `items` (and inside the unfolded ones) as they should be.
    private func applyExpansion(to items: [FileOutlineItem]) {
        for folder in items where folder.isFolder {
            let expanded = wantsExpanded(folder)
            if expanded != outline.isItemExpanded(folder) {
                if expanded { outline.expandItem(folder) } else { outline.collapseItem(folder) }
            }
            if expanded { applyExpansion(to: folder.children) }
        }
    }

    /// Selects the shown file's row; no row when the file isn't listed or is in a folded folder.
    private func syncSelection() {
        let row = selection.flatMap { files[$0] }.map { outline.row(forItem: $0) } ?? -1
        if outline.selectedRow != row {
            applying = true
            outline.selectRowIndexes(row >= 0 ? [row] : [], byExtendingSelection: false)
            applying = false
        }
        updateCellColors()
    }

    /// Unfolds the folders leading to the shown file, selects its row and scrolls it into view.
    private func reveal() {
        guard let selection, let item = files[selection] else {
            pendingReveal = selection != nil // not in the list yet: again once it has loaded
            syncSelection()
            return
        }
        pendingReveal = false
        var path: [FileOutlineItem] = []
        var parent = item.parent
        while let folder = parent {
            path.insert(folder, at: 0)
            parent = folder.parent
        }
        applying = true
        for folder in path where !outline.isItemExpanded(folder) {
            expansion[folder.path] = true
            outline.expandItem(folder)
            applyExpansion(to: folder.children)
        }
        applying = false
        syncSelection()
        let row = outline.row(forItem: item)
        if row >= 0 { outline.scrollRowToVisible(row) }
    }

    /// Unchanged files are dimmed, except in the selected row (see `FileCellView`).
    private func updateCellColors() {
        outline.enumerateAvailableRowViews { rowView, _ in
            (rowView.view(atColumn: 0) as? FileCellView)?.updateColors()
        }
    }

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? FileOutlineItem)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? FileOutlineItem)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileOutlineItem)?.isFolder ?? false
    }

    // MARK: NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? FileOutlineItem, let font else { return nil }
        if let change = item.change {
            let cell = outlineView.makeView(withIdentifier: FileCellView.reuseID, owner: nil) as? FileCellView
                ?? FileCellView()
            cell.configure(change, font: font)
            return cell
        }
        let cell = outlineView.makeView(withIdentifier: FolderCellView.reuseID, owner: nil) as? FolderCellView
            ?? FolderCellView()
        cell.configure(name: item.name, hasChanges: item.hasChanges, font: font)
        return cell
    }

    /// Only files are selected, and a click on a folder or below the last row keeps the file.
    func outlineView(_ outlineView: NSOutlineView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        let files = proposed.filter { (outlineView.item(atRow: $0) as? FileOutlineItem)?.isFolder == false }
        return files.isEmpty ? outlineView.selectedRowIndexes : IndexSet(files)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !applying else { return }
        if let item = outline.item(atRow: outline.selectedRow) as? FileOutlineItem, !item.isFolder {
            guard item.path != selection else { return }
            selection = item.path
            updateCellColors()
            select(item.path)
        } else {
            syncSelection() // e.g. the folder took over the selection when it was folded
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !applying, let folder = notification.userInfo?["NSObject"] as? FileOutlineItem else { return }
        expansion[folder.path] = true
        applying = true
        applyExpansion(to: folder.children)
        applying = false
        syncSelection()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !applying, let folder = notification.userInfo?["NSObject"] as? FileOutlineItem else { return }
        expansion[folder.path] = false
        syncSelection()
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let item = outline.item(atRow: outline.clickedRow) as? FileOutlineItem, !item.isFolder else { return }
        let path = item.path
        menu.addItem(ActionMenuItem("Open in New Window") { [weak self] in self?.openInNewWindow(path) })
        guard let root, FileActions.exists(path, in: root) else { return }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Open in Default App") { FileActions.openInDefaultApp(path, in: root) })
        let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        let apps = FileActions.apps(for: path, in: root)
        let submenu = NSMenu()
        for (index, app) in apps.enumerated() {
            submenu.addItem(ActionMenuItem(FileActions.appName(app) + (index == 0 ? " (default)" : "")) {
                FileActions.open(path, in: root, with: app)
            })
            if index == 0 && apps.count > 1 { submenu.addItem(.separator()) }
        }
        openWith.submenu = submenu
        menu.addItem(openWith)
        menu.addItem(ActionMenuItem("Reveal in Finder") { FileActions.revealInFinder(path, in: root) })
    }
}

/// A menu item that runs a closure.
private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

/// The outline view of a file list: a click anywhere on a folder folds or unfolds it, ⌘-click
/// opens a file in a window of its own, and ↑/↓ step from file to file, past the folders.
fileprivate final class FileOutlineView: NSOutlineView {
    var commandClicked: (String) -> Void = { _ in }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0, let item = item(atRow: row) as? FileOutlineItem, !frameOfOutlineCell(atRow: row).contains(point) {
            if item.isFolder {
                if isItemExpanded(item) { animator().collapseItem(item) } else { animator().expandItem(item) }
                return
            }
            if event.modifierFlags.contains(.command) {
                commandClicked(item.path) // this window keeps its file
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.isEmpty, event.keyCode == 125 || event.keyCode == 126 {
            selectFile(after: selectedRow, down: event.keyCode == 125)
        } else {
            super.keyDown(with: event)
        }
    }

    private func selectFile(after row: Int, down: Bool) {
        var next = row >= 0 ? row : (down ? -1 : numberOfRows)
        while true {
            next += down ? 1 : -1
            guard next >= 0, next < numberOfRows else { return }
            if let item = item(atRow: next) as? FileOutlineItem, !item.isFolder { break }
        }
        selectRowIndexes([next], byExtendingSelection: false)
        scrollRowToVisible(next)
    }
}

// MARK: - Rows

/// A file's row: its name, and the status badge at the right for a changed file.
private final class FileCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("FileCell")
    private let label = NSTextField(labelWithString: "")
    private let badge = StatusBadgeView()
    private var badgeWidth: NSLayoutConstraint!
    private var badgeHeight: NSLayoutConstraint!
    private var isUnchanged = false

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseID
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(badge)
        // Not the cell's `textField`: a source list sets that in bold in the selected row.
        badgeWidth = badge.widthAnchor.constraint(equalToConstant: 0)
        badgeHeight = badge.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -7),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeWidth, badgeHeight,
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ change: FileChange, font: NSFont) {
        label.stringValue = change.fileName
        label.font = font
        isUnchanged = change.isUnchanged
        badge.isHidden = change.isUnchanged
        badge.configure(label: change.statusLabel, size: font.pointSize)
        let box = change.isUnchanged ? 0 : StatusBadgeView.box(for: font.pointSize)
        badgeWidth.constant = box
        badgeHeight.constant = box
        toolTip = "\(change.statusDescription): \(change.oldPath.map { "\($0) → " } ?? "")\(change.path)"
        updateColors()
    }

    /// Not passed on to the name: a source list would set the selected row's name in bold.
    private var style = NSView.BackgroundStyle.normal
    override var backgroundStyle: NSView.BackgroundStyle {
        get { style }
        set {
            style = newValue
            updateColors()
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateColors()
    }

    /// Unchanged files are dimmed, except in the selected row: there the name reads like the
    /// others' (white on the selection color).
    func updateColors() {
        let isSelected = (superview as? NSTableRowView)?.isSelected ?? false
        let isEmphasized = style == .emphasized
        label.textColor = isEmphasized ? .alternateSelectedControlTextColor
            : (isUnchanged && !isSelected ? .secondaryLabelColor : .labelColor)
        badge.isEmphasized = isEmphasized
    }
}

/// A folder's row: the folder symbol and its name ("src/utils" for a chain of single folders).
private final class FolderCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("FolderCell")
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var iconWidth: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseID
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(label)
        imageView = icon
        textField = label
        iconWidth = icon.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidth,
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(name: String, hasChanges: Bool, font: NSFont) {
        let size = font.pointSize
        icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size * 0.9, weight: .regular))
        iconWidth.constant = (size * 1.15).rounded()
        label.stringValue = name
        label.font = font
        label.textColor = hasChanges ? .labelColor : .secondaryLabelColor
        toolTip = name
    }
}

/// Muted status letter (M, A, D, R, U…) in a small outlined box, scaled to the list font.
private final class StatusBadgeView: NSView {
    private var label = ""
    private var size = FontPrefs.defaultListSize
    /// In the selected row of the list that has the keyboard: light on the selection color.
    var isEmphasized = false {
        didSet { if isEmphasized != oldValue { needsDisplay = true } }
    }

    static func box(for size: Double) -> CGFloat { (size * 1.15).rounded() - 2 }

    func configure(label: String, size: Double) {
        self.label = label
        self.size = size
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor = isEmphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                               xRadius: bounds.width * 0.22, yRadius: bounds.width * 0.22)
        box.lineWidth = 1
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(0.5)
        color.setStroke()
        box.stroke()
        NSGraphicsContext.restoreGraphicsState()

        let pointSize = size * 0.68 - 1
        let system = NSFont.systemFont(ofSize: pointSize, weight: .semibold)
        let font = system.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: pointSize) } ?? system
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: color])
        let textSize = text.size()
        text.draw(at: NSPoint(x: (bounds.width - textSize.width) / 2, y: (bounds.height - textSize.height) / 2))
    }
}
