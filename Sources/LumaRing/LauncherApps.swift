import AppKit

struct LauncherApp: Codable, Equatable, Identifiable {
    var bundleID: String
    var name: String
    var path: String
    var id: String { bundleID }

    static func read(_ url: URL) -> LauncherApp? {
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: url.path),
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.isEmpty else { return nil }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        return LauncherApp(bundleID: id, name: name, path: url.path)
    }

    static func unique(_ apps: [LauncherApp]) -> [LauncherApp] {
        var seen = Set<String>()
        return apps.filter { !$0.bundleID.isEmpty && seen.insert($0.bundleID).inserted }
    }
}

struct LauncherFolder: Codable, Equatable {
    let name: String
    let path: String
    let bookmark: Data?

    init?(_ url: URL) {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        guard Self.isFolder(url) else { return nil }
        name = FileManager.default.displayName(atPath: url.path)
        path = url.path
        bookmark = try? url.bookmarkData(options: [.minimalBookmark])
    }

    func resolve() -> URL? {
        var stale = false
        if let bookmark, let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                            relativeTo: nil, bookmarkDataIsStale: &stale), Self.isFolder(url) {
            return url
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return Self.isFolder(url) ? url : nil
    }

    private static func isFolder(_ url: URL) -> Bool {
        guard url.isFileURL, let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { return false }
        return values.isDirectory == true && values.isPackage != true
    }
}

enum LauncherDestination: Codable, Equatable, Identifiable {
    case application(LauncherApp)
    case folder(LauncherFolder)

    var id: String {
        switch self {
        case .application(let app): app.id
        case .folder(let folder): "folder:\(folder.path)"
        }
    }

    var name: String {
        switch self {
        case .application(let app): app.name
        case .folder(let folder): folder.name
        }
    }

    var application: LauncherApp? {
        if case .application(let app) = self { return app }
        return nil
    }
}

struct LauncherSecondaryRing: Codable, Equatable {
    var id = UUID()
    var name: String
    var destinations: [LauncherDestination] = []
}

enum LauncherItem: Codable, Equatable, Identifiable {
    case destination(LauncherDestination)
    case secondary(LauncherSecondaryRing)

    var id: String {
        switch self {
        case .destination(let destination): destination.id
        case .secondary(let ring): "ring:\(ring.id.uuidString)"
        }
    }

    var name: String {
        switch self {
        case .destination(let destination): destination.name
        case .secondary(let ring):
            ring.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? L10n.text("二级圆环", "Secondary ring") : ring.name
        }
    }

    var application: LauncherApp? {
        if case .destination(let destination) = self { return destination.application }
        return nil
    }

    var secondary: LauncherSecondaryRing? {
        if case .secondary(let ring) = self { return ring }
        return nil
    }
}

struct LauncherRecord: Identifiable {
    let item: LauncherItem
    let icon: NSImage
    let available: Bool
    let children: [LauncherRecord]

    var id: String { item.id }
    var name: String { item.name }
    var application: LauncherApp? { item.application }

    init(item: LauncherItem, icon: NSImage, available: Bool) {
        self.item = item
        self.icon = icon
        self.available = available
        self.children = []
    }

    init(app: LauncherApp, icon: NSImage, available: Bool) {
        self.init(item: .destination(.application(app)), icon: icon, available: available)
    }

    init(secondary ring: LauncherSecondaryRing, children: [LauncherRecord]) {
        self.item = .secondary(ring)
        self.icon = Self.secondaryIcon(children)
        self.available = true
        self.children = children
    }

    private static func secondaryIcon(_ children: [LauncherRecord]) -> NSImage {
        let preview = Array(children.prefix(4))
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { bounds in
            let side = bounds.width
            NSColor.systemBlue.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: side * 0.23, yRadius: side * 0.23).fill()

            let iconSize = side * 0.45
            let spacing = iconSize + side * 0.02
            for (index, child) in preview.enumerated() {
                let row = CGFloat(index / 2)
                let column = CGFloat(index % 2)
                let x = bounds.midX + (column - 0.5) * spacing
                let y = bounds.midY + (0.5 - row) * spacing
                let rect = NSRect(x: x - iconSize / 2, y: y - iconSize / 2, width: iconSize, height: iconSize)
                let icon = child.icon.withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor])) ?? child.icon
                icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: child.available ? 1 : 0.55)
            }
            return true
        }
        image.cacheMode = .never
        return image
    }
}

@MainActor final class LauncherCatalog {
    private var icons: [String: NSImage] = [:]

    static func resolve(_ app: LauncherApp) -> URL? {
        let stored = URL(fileURLWithPath: app.path)
        if LauncherApp.read(stored)?.bundleID == app.bundleID { return stored }
        guard let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID),
              LauncherApp.read(found)?.bundleID == app.bundleID else { return nil }
        return found
    }

    func snapshot(_ items: [LauncherItem]) -> [LauncherRecord] {
        var used = Set<String>()
        func icon(at url: URL?, fallback: String) -> NSImage {
            guard let path = url?.path else {
                return NSImage(systemSymbolName: fallback, accessibilityDescription: nil)!
            }
            used.insert(path)
            if let image = icons[path] { return image }
            let image = NSWorkspace.shared.icon(forFile: path)
            icons[path] = image
            return image
        }
        func record(for item: LauncherItem) -> LauncherRecord {
            switch item {
            case .destination(.application(let app)):
                let url = Self.resolve(app)
                return LauncherRecord(item: item, icon: icon(at: url, fallback: "app.dashed"), available: url != nil)
            case .destination(.folder(let folder)):
                let url = folder.resolve()
                return LauncherRecord(item: item, icon: icon(at: url, fallback: "folder"), available: url != nil)
            case .secondary(let ring):
                return LauncherRecord(secondary: ring, children: ring.destinations.map { record(for: .destination($0)) })
            }
        }
        let records = items.map(record)
        icons = icons.filter { used.contains($0.key) }
        return records
    }
}

@MainActor final class ApplicationLauncher {
    typealias Open = (URL, NSWorkspace.OpenConfiguration, @escaping @Sendable (NSRunningApplication?, Error?) -> Void) -> Void
    private let resolve: @MainActor (LauncherApp) -> URL?
    private let open: Open

    init(resolve: @escaping @MainActor (LauncherApp) -> URL? = { LauncherCatalog.resolve($0) },
         open: @escaping Open = { url, configuration, completion in
             NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: completion)
         }) {
        self.resolve = resolve; self.open = open
    }

    func launch(_ app: LauncherApp, completion: @escaping (Bool) -> Void) {
        guard let url = resolve(app) else { completion(false); return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.createsNewApplicationInstance = false
        config.addsToRecentItems = false
        config.promptsUserIfNeeded = false
        open(url, config) { running, error in
            DispatchQueue.main.async {
                completion(error == nil && running != nil)
            }
        }
    }
}
