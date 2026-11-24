import AppKit
import LumaRingCore

enum RingApp {
    enum ID: Hashable { case running(pid_t), favorite(String) }
    case running(AppRecord)
    case favorite(LauncherRecord, running: AppRecord?)

    var running: AppRecord? {
        switch self { case .running(let app): app; case .favorite(_, let app): app }
    }
    var favorite: LauncherRecord? {
        if case .favorite(let record, _) = self { return record }
        return nil
    }
    var id: ID {
        switch self { case .running(let app): .running(app.pid); case .favorite(let record, _): .favorite(record.id) }
    }
    var name: String {
        switch self { case .running(let app): app.name; case .favorite(let record, _): record.name }
    }
    var icon: NSImage {
        switch self { case .running(let app): app.icon; case .favorite(let record, let app): app?.icon ?? record.icon }
    }
    var available: Bool { running != nil || favorite?.available == true }
}

@MainActor final class RingView: NSView {
    var apps: [AppRecord] = []
    var additionalFavoriteProcesses: Set<pid_t> = []
    var windows: [WindowRecord] = []
    var appPage = 0
    var windowPage = 0
    var closingWindowIDs: Set<String> = []
    var keepsSingleWindowArc = false
    var selectedApp: pid_t?
    var hoveredWindow: String?
    var message = L10n.text("悬停应用", "Point at an app")
    var loading = false
    var options = Options()
    var selectingWithShortcut = false {
        didSet { if selectingWithShortcut != oldValue { refreshArtwork() } }
    }
    var onSelectApp: ((AppRecord) -> Void)?
    var onActivateApp: ((AppRecord) -> Void)?
    var onActivateWindow: ((WindowRecord) -> Void)?
    var onCloseWindow: ((WindowRecord) -> Void)?
    var launcherApps: [LauncherRecord] = []
    var launcherPage = 0
    var runningAppPage = 0
    var hoveredLauncher: String?
    var showsLauncher = false
    var showsActionLauncher: Bool { showsLauncher && launcherInnerArtwork != nil }
    var optionPressed = false
    var launcherPinned = false
    var launcherInnerArtwork: ((Bool) -> Void)?
    var centerClickWork: DispatchWorkItem?
    private(set) var invocationClickDeadline: TimeInterval = 0
    var isContextMenuOpen = false
    var isEditingName = false
    var afterContextMenu: (() -> Void)?
    var makeWindowMenu: ((WindowRecord) -> NSMenu)?
    var onLaunchApp: ((LauncherApp) -> Void)?
    var onOpenFolder: ((LauncherFolder) -> Void)?
    var onLauncherModeEntered: (() -> Void)?
    var onLauncherModeEnded: (() -> Void)?
    var makeAppMenu: ((AppRecord) -> NSMenu)?
    var onQuitApp: ((AppRecord) -> Void)?
    var onPointerInteraction: (() -> Void)?
    var onHoverWindow: ((WindowRecord?) -> Void)?
    var onClose: (() -> Void)?
    var onSettings: (() -> Void)?
    var onVisibleAppsChanged: (() -> Void)?
    private(set) var itemCounts: [pid_t: AppItemCount] = [:]
    private var countsFromSelection: Set<pid_t> = []
    private var hoveredApp: RingApp.ID?
    private var keyboardPointer: CGPoint?
    private(set) var keyboardSecondary = false
    private var pendingSecondary = false
    private var expandedLauncherID: String?
    private var launcherChildPage = 0
    private var launcherStripPages: [String: Int] = [:]
    private var hoveredLauncherChild: LauncherMenuLayout.ChildID?
    private var collapseWork: DispatchWorkItem?
    private enum PressTarget {
        case app(RingApp, WindowRecord?, draggable: Bool)
        case window(WindowRecord)
        case close(WindowRecord)
        case background
        case launcher(LauncherRecord)
        case launcherChild(parent: String, child: String)
        case inactive
    }
    private var pressTarget: PressTarget?
    private var pressPoint = CGPoint.zero
    private var dragPoint = CGPoint.zero
    private(set) var isDraggingApp = false
    private var hoveredClose: String?
    var isPointerDown: Bool { pressTarget != nil }
    var dragWillQuit: Bool {
        isDraggingApp && hypot(dragPoint.x - RingGeometry.center.x, dragPoint.y - RingGeometry.center.y) > RingGeometry.appOuter + 18
    }
    private var draggedApp: AppRecord? {
        guard isDraggingApp, case .app(let app, _, _) = pressTarget else { return nil }
        return app.running
    }
    private let diskMaterial = RingMaterial()
    private let launcherArcMaterial = RingMaterial()
    private let diskArtwork = RingArtwork()
    private let highlightArtwork = RingArtwork()
    private let launcherArcArtwork = RingArtwork()
    private let dragArtwork = RingArtwork()
    private let arcGroup = NSView()
    private let appGroup = NSView()
    private let launcherChildGroup = NSView()
    private var appTiles: [RingApp.ID: RingTile] = [:]
    private var windowTiles: [String: RingTile] = [:]
    private var launcherChildTiles: [LauncherMenuLayout.ChildID: RingTile] = [:]
    private let accessibleItems = RingAccessibility()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        arcGroup.wantsLayer = true
        addSubview(diskMaterial)
        diskMaterial.content.addSubview(diskArtwork)
        addSubview(launcherArcMaterial)
        launcherArcMaterial.isHidden = true
        addSubview(highlightArtwork)
        addSubview(appGroup)
        addSubview(launcherArcArtwork)
        addSubview(launcherChildGroup)
        addSubview(arcGroup)
        addSubview(dragArtwork)
        diskArtwork.render = { [weak self] in self?.drawDisk() }
        highlightArtwork.render = { [weak self] in self?.drawAppHighlight() }
        launcherArcArtwork.render = { [weak self] in self?.drawLauncherArc() }
        dragArtwork.render = { [weak self] in self?.drawDrag() }
        arcGroup.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        diskMaterial.frame = bounds; diskArtwork.frame = bounds
        launcherArcMaterial.frame = bounds
        highlightArtwork.frame = bounds
        launcherArcArtwork.frame = bounds
        launcherChildGroup.frame = bounds
        dragArtwork.frame = bounds
        arcGroup.frame = bounds; appGroup.frame = bounds
        diskMaterial.setShape(diskPath)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshArtwork()
    }

    var showsWindowArc: Bool { !showsActionLauncher && !isDraggingApp && selectedApp != nil && (windows.count > 1 || (keepsSingleWindowArc && !windows.isEmpty)) }
    var arcAnchor: Double {
        let index = visibleRingApps.firstIndex { $0.running?.pid == selectedApp } ?? 0
        return RingGeometry.angle(index: index, count: visibleRingApps.count)
    }
    private var diskPath: CGPath {
        if showsActionLauncher { return CGPath(ellipseIn: CGRect(x: 42, y: 42, width: 396, height: 396), transform: nil) }
        return stripDiskPath(for: visibleLauncherMenus)
    }

    private var cachedStripLayouts: [LauncherSecondaryLayout] = []
    private var cachedStripDisk = RingGeometry.diskPath

    private func stripDiskPath(for menus: [LauncherMenuLayout]) -> CGPath {
        let layouts = menus.map(\.layout).filter { $0.replacesEntry && $0.count > 1 }
        if layouts != cachedStripLayouts {
            cachedStripLayouts = layouts
            cachedStripDisk = LauncherSecondaryLayout.diskPath(with: layouts)
        }
        return cachedStripDisk
    }
    var occupiedScreenFrame: CGRect {
        guard let window else { return .zero }
        var occupied = diskPath.boundingBoxOfPath
        if showsWindowArc {
            occupied = occupied.union(RingGeometry.arcPath(count: visibleWindows.count, anchor: arcAnchor).boundingBoxOfPath)
        }
        if let path = launcherArcPath {
            occupied = occupied.union(path.boundingBoxOfPath)
        }
        return window.convertToScreen(convert(occupied, to: nil))
    }
    func windowScreenFrame(_ id: String) -> CGRect? {
        guard let window, let index = visibleWindows.firstIndex(where: { $0.id == id }) else { return nil }
        let p = windowPoint(index)
        return window.convertToScreen(convert(NSRect(x: p.x - 35, y: p.y - 29, width: 70, height: 58), to: nil))
    }
    var appPageSize: Int {
        let range = RingGeometry.appPageSizeRange
        return min(range.upperBound, max(range.lowerBound, showsLauncher ? options.launcherPageSize : options.appPageSize))
    }
    var windowPageSize: Int {
        min(RingGeometry.windowPageSizeRange.upperBound, max(RingGeometry.windowPageSizeRange.lowerBound, options.windowPageSize))
    }
    var appIconSize: Double { min(34, LauncherTileLayout.primarySpacing(count: visibleRingApps.count) * 0.76) }
    private var appPages: Int { RingGeometry.pageCount(total: ringApps.count, size: appPageSize) }
    private var windowPages: Int { RingGeometry.pageCount(total: windows.count, size: windowPageSize) }
    private func windowPoint(_ index: Int) -> CGPoint {
        RingGeometry.point(angle: RingGeometry.arcAngle(index: index, count: visibleWindows.count, anchor: arcAnchor), radius: RingGeometry.windowRadius)
    }
    private func windowIndex(at point: CGPoint) -> Int? {
        guard showsWindowArc,
              hypot(point.x - RingGeometry.center.x, point.y - RingGeometry.center.y) > RingGeometry.appOuter else { return nil }
        return RingGeometry.arcIndex(at: point, count: visibleWindows.count, anchor: arcAnchor)
    }

    func closeButtonRect(at index: Int) -> CGRect {
        let p = windowPoint(index)
        return CGRect(x: p.x + 16, y: p.y + 10, width: 18, height: 18)
    }

    private func closeTarget(at point: CGPoint) -> WindowRecord? {
        visibleWindows.enumerated().first { closeButtonRect(at: $0.offset).contains(point) }?.element
    }

    private func appTarget(at point: CGPoint) -> RingApp? {
        let apps = visibleRingApps
        guard let index = RingGeometry.appIndex(at: point, count: apps.count) else { return nil }
        return apps[index]
    }

    private var usesLauncherStrips: Bool {
        showsLauncher && !showsActionLauncher && options.launcherSecondaryStyle == .strip
    }

    private var visibleLauncherMenus: [LauncherMenuLayout] {
        guard showsLauncher, !showsActionLauncher, usesLauncherStrips || expandedLauncherID != nil else { return [] }
        return LauncherMenuLayout.visible(records: visibleRingApps.map(\.favorite), style: options.launcherSecondaryStyle,
                                          active: expandedLauncherID) { id in
            usesLauncherStrips ? launcherStripPages[id, default: 0] : launcherChildPage
        }
    }

    private var activeLauncherMenu: LauncherMenuLayout? {
        guard let expandedLauncherID else { return nil }
        return visibleLauncherMenus.first { $0.id == expandedLauncherID }
    }

    private var launcherChildPages: Int { activeLauncherMenu?.pageCount ?? 1 }
    private var launcherArcPath: CGPath? { activeLauncherMenu?.layout.arcPath }

    private func launcherChild(at point: CGPoint, holdingShortcut: Bool = false) -> (menu: LauncherMenuLayout, child: LauncherRecord)? {
        let menus = visibleLauncherMenus
        guard !menus.isEmpty else { return nil }
        if !usesLauncherStrips {
            guard let menu = menus.first, let index = menu.layout.childIndex(at: point, isEntry: false,
                holdingShortcut: holdingShortcut) else { return nil }
            return (menu, menu.children[menu.children.startIndex + index])
        }
        let dx = point.x - RingGeometry.center.x, dy = point.y - RingGeometry.center.y
        let radius = hypot(dx, dy)
        if radius <= RingGeometry.appOuter {
            guard let slot = RingGeometry.appIndex(at: point, count: visibleRingApps.count),
                  let menu = menus.first(where: { $0.slot == slot }) else { return nil }
            return menu.children.first.map { (menu, $0) }
        }
        let angle = atan2(dy, dx)
        func distance(_ menu: LauncherMenuLayout) -> Double {
            let delta = angle - menu.layout.anchor
            return abs(atan2(sin(delta), cos(delta)))
        }
        if let menu = menus.filter({ $0.layout.count > 1 }).min(by: { distance($0) < distance($1) }),
           let index = menu.layout.childIndex(at: point, isEntry: false, disk: stripDiskPath(for: menus)) {
            return (menu, menu.children[menu.children.startIndex + index])
        }
        guard holdingShortcut, let slot = RingGeometry.index(at: point, count: visibleRingApps.count,
                inner: RingGeometry.appOuter, outer: .infinity), let menu = menus.first(where: { $0.slot == slot }),
              let index = menu.layout.childIndex(at: point, isEntry: false, holdingShortcut: true,
                                                 disk: stripDiskPath(for: menus)) else { return nil }
        return (menu, menu.children[menu.children.startIndex + index])
    }

    private var currentLauncherChild: LauncherRecord? {
        guard let key = hoveredLauncherChild, let menu = activeLauncherMenu, menu.id == key.parent else { return nil }
        return menu.children.first { $0.id == key.child }
    }

    private func resetLauncherArc() {
        expandedLauncherID = nil
        launcherChildPage = 0
        hoveredLauncherChild = nil
    }

    private func setHoveredLauncherChild(_ record: LauncherRecord?) {
        let key = record.flatMap { record in expandedLauncherID.map { LauncherMenuLayout.ChildID(parent: $0, child: record.id) } }
        guard hoveredLauncherChild != key else { return }
        hoveredLauncherChild = key
        refreshArtwork()
    }

    private func changeLauncherChildPage(_ direction: Int, parent: String? = nil) {
        let id = parent ?? expandedLauncherID
        guard let menu = visibleLauncherMenus.first(where: { $0.id == id }), menu.pageCount > 1 else { return }
        setLauncherChildPage(RingGeometry.wrapped(menu.page + direction, count: menu.pageCount), menu: menu)
        if expandedLauncherID == id { hoveredLauncherChild = nil }
        refresh()
    }

    private func setLauncherChildPage(_ page: Int, menu: LauncherMenuLayout) {
        if usesLauncherStrips { launcherStripPages[menu.id] = page }
        else { launcherChildPage = page }
    }

    func resetLauncherStripPages() { launcherStripPages.removeAll() }

    var pageControlsRect: CGRect {
        CGRect(x: RingGeometry.center.x - 22, y: RingGeometry.center.y - 32, width: 44, height: 14)
    }
    var highlightedApp: pid_t? {
        highlightedTile?.running?.pid
    }
    private var highlightedTile: RingApp? {
        if let hoveredApp { return visibleRingApps.first { $0.id == hoveredApp } }
        guard let selectedApp, hoveredWindow != nil || hoveredClose != nil else { return nil }
        return visibleRingApps.first { $0.running?.pid == selectedApp }
    }

    private var tracking: NSTrackingArea?
    private var scrollTime = 0.0

    override var acceptsFirstResponder: Bool { !(window is ActionPanel) }
    override var needsPanelToBecomeKey: Bool { window is ActionPanel ? false : super.needsPanelToBecomeKey }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        window is ActionPanel || super.acceptsFirstMouse(for: event)
    }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
    private var ringApps: [RingApp] {
        if showsLauncher {
            var running: [String: AppRecord] = [:]
            for app in apps where running[app.bundleID] == nil { running[app.bundleID] = app }
            return launcherApps.map { record in
                .favorite(record, running: record.application.flatMap { running[$0.bundleID] })
            }
        }
        let excluded = Set(options.excludedBundleIDs)
        return apps.filter { !excluded.contains($0.bundleID) && !additionalFavoriteProcesses.contains($0.pid) }.map(RingApp.running)
    }
    var visibleRingApps: [RingApp] {
        let apps = ringApps
        return Array(apps[RingGeometry.pageRange(page: appPage, total: apps.count, size: appPageSize)])
    }
    var visibleApps: [AppRecord] { visibleRingApps.compactMap(\.running) }
    func clampAppPage() { appPage = min(appPage, appPages - 1) }
    var visibleWindows: [WindowRecord] {
        guard showsWindowArc else { return [] }
        return Array(windows[RingGeometry.pageRange(page: windowPage, total: windows.count, size: windowPageSize)])
    }
    var secondaryName: String { options.contentMode(for: currentApp?.bundleID ?? "").title }
    var currentApp: AppRecord? { apps.first { $0.pid == selectedApp } }
    var currentWindow: WindowRecord? { windows.first { $0.id == hoveredWindow } }

    func reset(apps: [AppRecord], options: Options) {
        RingMotion.reset(self)
        appTiles.values.forEach { $0.removeFromSuperview() }; appTiles.removeAll()
        windowTiles.values.forEach { $0.removeFromSuperview() }; windowTiles.removeAll()
        selectingWithShortcut = false
        invocationClickDeadline = 0
        endKeyboardNavigation()
        keepsSingleWindowArc = false; closingWindowIDs.removeAll()
        centerClickWork?.cancel(); centerClickWork = nil
        launcherPinned = false
        cancelHover()
        cancelPointerInteraction()
        onHoverWindow?(nil)
        self.apps = apps; self.options = options
        additionalFavoriteProcesses.removeAll()
        showsLauncher = false; optionPressed = false; launcherApps = []; launcherPage = 0; hoveredLauncher = nil
        resetLauncherArc()
        resetLauncherStripPages()
        itemCounts.removeAll()
        countsFromSelection.removeAll()
        windows = []; appPage = 0; runningAppPage = 0; windowPage = 0
        selectedApp = nil; hoveredApp = nil; hoveredWindow = nil
        message = apps.isEmpty ? L10n.text("没有可切换的应用", "No apps available") : L10n.text("悬停应用", "Point at an app")
        loading = false
        refresh()
    }

    func cancelHover() {
        collapseWork?.cancel(); collapseWork = nil
    }

    func select(_ app: AppRecord) {
        guard let tile = visibleRingApps.first(where: { $0.running?.pid == app.pid }) else { return }
        select(tile)
    }

    private func select(_ tile: RingApp) {
        guard !showsActionLauncher, !isEditingName else { return }
        cancelHover()
        let secondary = tile.favorite?.item.secondary == nil ? nil : tile.favorite?.id
        let changedArc = expandedLauncherID != secondary
        if changedArc { resetLauncherArc() }
        guard let app = tile.running else {
            if selectedApp != nil { clearSelection(preserveKeyboard: true) }
            expandedLauncherID = secondary
            if hoveredApp != tile.id || changedArc { hoveredApp = tile.id; refresh() }
            return
        }
        if hoveredApp != tile.id { hoveredApp = tile.id; refreshArtwork() }
        guard selectedApp != app.pid else { return }
        keepsSingleWindowArc = false
        selectedApp = app.pid; windows = []; windowPage = 0
        hoveredWindow = nil
        loading = true; message = ""
        onHoverWindow?(nil)
        onSelectApp?(app)
        refresh()
    }

    func setWindows(_ result: WindowResult, for pid: pid_t) {
        guard !showsActionLauncher, !isEditingName, selectedApp == pid else { return }
        // A direct hover query takes precedence over a potentially older page-count response.
        countsFromSelection.insert(pid)
        itemCounts[pid] = AppItemCount(result, includeMinimized: options.includeMinimized)
        loading = false
        switch result {
        case .ready(let all, let limited):
            windows = WindowRecord.sortedByName(all.filter { options.includeMinimized || !$0.minimized })
            windowPage = min(windowPage, max(0, windowPages - 1))
            if let hoveredWindow, !windows.contains(where: { $0.id == hoveredWindow }) { setHoveredWindow(nil) }
            if let hoveredClose, !windows.contains(where: { $0.id == hoveredClose }) { self.hoveredClose = nil }
            message = limited ? L10n.text("已载入 \(windows.count) 个\(secondaryName) · 应用响应较慢，请重新呼出刷新", "Loaded \(windows.count) \(secondaryName.lowercased()) · Reopen to refresh") : (windows.count > 1 ? L10n.text("\(windows.count) 个\(secondaryName)", "\(windows.count) \(secondaryName.lowercased())") : L10n.text("点击切换", "Click to switch"))
            if windows.isEmpty { message = L10n.text("没有可用的窗口或标签页", "No windows or tabs available") }
        case .permissionRequired:
            windows = []; message = L10n.text("点击中心授权", "Click center for access")
        case .unavailable(let text):
            windows = []; message = text
        }
        if pendingSecondary {
            pendingSecondary = false
            enterSecondary()
        } else if keyboardSecondary, !showsWindowArc {
            keyboardSecondary = false
        }
        refresh()
    }

    func removeClosedWindow(_ record: WindowRecord) {
        guard selectedApp == record.pid, windows.contains(where: { $0.id == record.id }) else { return }
        cancelHover()
        switch pressTarget {
        case .window(let pressed), .close(let pressed):
            if pressed.id == record.id { cancelPointerInteraction() }
        case .app(_, let single, _):
            if single?.id == record.id { cancelPointerInteraction() }
        default: break
        }
        setHoveredWindow(nil)
        windows.removeAll { $0.id == record.id }
        keepsSingleWindowArc = true
        windowPage = min(windowPage, max(0, windowPages - 1))
        countsFromSelection.insert(record.pid)
        itemCounts[record.pid] = AppItemCount(.ready(windows), includeMinimized: options.includeMinimized)
        message = windows.isEmpty ? L10n.text("没有可用的窗口或标签页", "No windows or tabs available") : "\(windows.count) \(secondaryName)"
        refresh()
    }

    func setItemCount(_ count: AppItemCount?, for pid: pid_t) {
        guard visibleApps.contains(where: { $0.pid == pid }), !countsFromSelection.contains(pid) else { return }
        guard itemCounts[pid] != count else { return }
        itemCounts[pid] = count
        refreshArtwork()
        rebuildAccessibility()
    }

    func refresh() {
        arcGroup.isHidden = !showsWindowArc
        arcGroup.frame = bounds; appGroup.frame = bounds
        refreshArtwork()
        rebuildAccessibility()
    }

    func refreshArtwork() {
        diskMaterial.setShape(diskPath)
        diskArtwork.needsDisplay = true
        highlightArtwork.needsDisplay = true
        let arcPath = launcherArcPath
        if let arcPath { launcherArcMaterial.setShape(arcPath) }
        launcherArcMaterial.isHidden = arcPath == nil
        launcherArcArtwork.needsDisplay = true
        updateTiles()
        dragArtwork.needsDisplay = true
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseMoved(with event: NSEvent) {
        guard keyboardPointer != NSEvent.mouseLocation else { return }
        updateHover(at: point(event))
    }

    func updateHover(at p: CGPoint) {
        endKeyboardNavigation()
        let radius = hypot(p.x - RingGeometry.center.x, p.y - RingGeometry.center.y)
        if radius >= RingGeometry.appInner {
            centerClickWork?.cancel(); centerClickWork = nil
        }
        guard !isPointerDown, !isContextMenuOpen, !isEditingName else { return }
        if showsActionLauncher {
            let id = launcherTarget(at: p)?.id
            if id != hoveredLauncher { hoveredLauncher = id; refreshArtwork() }
            return
        }
        if windowIndex(at: p) == nil, let hit = launcherChild(at: p, holdingShortcut: selectingWithShortcut) {
            if usesLauncherStrips && expandedLauncherID != hit.menu.id,
               let tile = visibleRingApps.first(where: { $0.favorite?.id == hit.menu.id }) {
                select(tile)
            }
            setHoveredLauncherChild(hit.child)
            return
        }
        setHoveredLauncherChild(nil)
        if activeLauncherMenu?.layout.bridgesArc(at: p) == true { return }
        // Keep the menu open while the pointer crosses the inset to reach its pager.
        if launcherChildPages > 1, radius < RingGeometry.appInner { return }
        let close = selectingWithShortcut ? nil : closeTarget(at: p)
        if hoveredClose != close?.id { hoveredClose = close?.id; refreshArtwork() }
        if close != nil {
            cancelHover()
            setHoveredWindow(nil)
            return
        }
        if selectingWithShortcut {
            if radius < RingGeometry.appInner {
                if highlightedTile != nil || selectedApp != nil { clearSelection() }
                return
            }
            if showsWindowArc, let index = RingGeometry.arcIndex(at: p, count: visibleWindows.count, anchor: arcAnchor,
                inner: RingGeometry.appInner, outer: .infinity) {
                // The expanded arc owns this direction from the inner ring outward.
                // Crossing its side edges hands selection back to the app sectors.
                cancelHover()
                if radius > RingGeometry.appOuter { setHoveredWindow(visibleWindows[index]) }
                else {
                    setHoveredWindow(nil)
                    if let app = currentApp { select(app) }
                }
                return
            }
        }
        let apps = visibleRingApps
        if let index = RingGeometry.appIndex(at: p, count: apps.count) {
            if hoveredWindow != nil { setHoveredWindow(nil) }
            select(apps[index])
        } else {
            if let index = windowIndex(at: p) {
                collapseWork?.cancel(); collapseWork = nil
                setHoveredWindow(visibleWindows[index])
            } else if selectingWithShortcut, let index = RingGeometry.index(at: p, count: apps.count,
                inner: RingGeometry.appOuter, outer: .infinity) {
                // Hold-to-select extends each app's sector beyond the visible ring.
                // The expanded secondary arc above retains priority over this extension.
                setHoveredWindow(nil)
                select(apps[index])
            } else {
                let angle = atan2(p.y - RingGeometry.center.y, p.x - RingGeometry.center.x)
                let distance = abs(atan2(sin(angle - arcAnchor), cos(angle - arcAnchor)))
                if radius < RingGeometry.appInner {
                    if hoveredApp != nil { hoveredApp = nil; refreshArtwork() }
                    setHoveredWindow(nil)
                }
                let pageControl = showsWindowArc && windowPages > 1 && pageControlsRect.contains(p)
                let bridge = pageControl || (showsWindowArc && radius >= RingGeometry.appOuter && radius <= RingGeometry.windowOuter
                    && distance <= Double(visibleWindows.count) * RingGeometry.arcStep / 2 + 0.12
                )
                if !bridge {
                    let hadLauncherArc = expandedLauncherID != nil
                    resetLauncherArc()
                    if hoveredApp != nil { hoveredApp = nil; refreshArtwork() }
                    if hadLauncherArc { refresh() }
                    setHoveredWindow(nil)
                    if selectedApp != nil && collapseWork == nil {
                        let work = DispatchWorkItem { [weak self] in self?.clearSelection() }
                        collapseWork = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20, execute: work)
                    }
                } else { collapseWork?.cancel(); collapseWork = nil }
            }
        }
    }

    func clearSelection(preserveKeyboard: Bool = false) {
        guard !isEditingName else { return }
        if !preserveKeyboard { endKeyboardNavigation() }
        cancelHover()
        resetLauncherArc()
        keepsSingleWindowArc = false
        selectedApp = nil; hoveredApp = nil; windows = []; hoveredWindow = nil; hoveredClose = nil
        loading = false; message = L10n.text("悬停应用", "Point at an app")
        onHoverWindow?(nil)
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        guard keyboardPointer != NSEvent.mouseLocation else { return }
        if selectingWithShortcut { updateHover(at: point(event)); return }
        endKeyboardNavigation()
        if showsActionLauncher { hoveredLauncher = nil; refreshArtwork() }
        else if !isPointerDown && !isContextMenuOpen && !isEditingName { clearSelection() }
    }

    private func setHoveredWindow(_ window: WindowRecord?) {
        guard hoveredWindow != window?.id else { return }
        hoveredWindow = window?.id
        onHoverWindow?(window)
        refreshArtwork()
    }

    func suppressInvocationClicks(at time: TimeInterval) {
        // Trackpad release can enqueue a synthetic secondary click after the ring
        // appears. Its timestamp, not its eventual delivery time, fences it out.
        invocationClickDeadline = time + 0.22
        centerClickWork?.cancel(); centerClickWork = nil
        cancelPointerInteraction()
    }

    func acceptsPointerEvent(_ event: NSEvent) -> Bool {
        invocationClickDeadline == 0 || event.timestamp > invocationClickDeadline
    }

    override func mouseDown(with event: NSEvent) {
        guard acceptsPointerEvent(event) else { return }
        beginPointer(at: point(event), clickCount: event.clickCount)
    }
    override func mouseDragged(with event: NSEvent) { movePointer(to: point(event)) }
    override func mouseUp(with event: NSEvent) {
        guard acceptsPointerEvent(event) else { return }
        endPointer(at: point(event))
    }

    func beginPointer(at p: CGPoint, clickCount: Int = 1) {
        endKeyboardNavigation()
        guard !isEditingName else { return }
        centerClickWork?.cancel(); centerClickWork = nil
        // AppKit keeps counting rapid clicks at the same location (3, 4, ...).
        // Treat each completed pair as a double-click without requiring motion.
        if clickCount > 0, clickCount.isMultiple(of: 2), toggleLauncherFromCenter(at: p) { return }
        onPointerInteraction?()
        cancelPointerInteraction()
        cancelHover()
        pressPoint = p; dragPoint = p
        if showsActionLauncher {
            pressTarget = launcherTarget(at: p).map { .launcher($0) } ?? .inactive
            return
        }
        if let target = closeTarget(at: p) { pressTarget = .close(target) }
        else if let index = windowIndex(at: p) { pressTarget = .window(visibleWindows[index]) }
        else if let hit = launcherChild(at: p) {
            pressTarget = .launcherChild(parent: hit.menu.id, child: hit.child.id)
        }
        else if let app = appTarget(at: p), let index = visibleRingApps.firstIndex(where: { $0.id == app.id }) {
            let center = RingGeometry.appIconCenter(index: index, count: visibleRingApps.count)
            let hitSize = appIconSize + 10
            let icon = CGRect(x: center.x - hitSize / 2, y: center.y - hitSize / 2, width: hitSize, height: hitSize)
            let target = selectedApp == app.running?.pid && windows.count == 1 ? windows[0] : nil
            pressTarget = .app(app, target, draggable: app.running != nil && icon.contains(p))
        } else { pressTarget = .background }
        refreshArtwork()
    }

    func movePointer(to p: CGPoint) {
        guard case .app(_, _, let draggable) = pressTarget, draggable else { return }
        dragPoint = p
        if !isDraggingApp && hypot(p.x - pressPoint.x, p.y - pressPoint.y) >= 6 {
            isDraggingApp = true
            cancelHover()
            hoveredClose = nil
            setHoveredWindow(nil)
            refresh()
        }
        if isDraggingApp { refreshArtwork() }
    }

    func endPointer(at p: CGPoint) {
        guard let target = pressTarget else { return }
        movePointer(to: p)
        let dragged = isDraggingApp, quit = dragWillQuit
        if dragged, quit, case .app(let tile, _, _) = target, let app = tile.running,
           apps.contains(where: { $0.pid == app.pid }), let onQuitApp {
            // Hand the drop straight to dismissal; don't restore/rebuild the arc
            // for one frame before the panel disappears.
            cancelPointerInteraction()
            onQuitApp(app)
            return
        }
        cancelPointerInteraction()
        refresh()
        switch target {
        case .app(let app, let singleWindow, _):
            if dragged {
                if quit, let running = app.running, apps.contains(where: { $0.pid == running.pid }) { onQuitApp?(running) }
                else { updateHover(at: p) }
            } else if let current = appTarget(at: p), current.id == app.id {
                activateApp(current, singleWindow: current.running?.pid == app.running?.pid ? singleWindow : nil)
            }
        case .close(let record):
            if closeTarget(at: p)?.id == record.id { onCloseWindow?(record) }
        case .window(let record):
            if closeTarget(at: p) == nil, let index = windowIndex(at: p), visibleWindows[index].id == record.id {
                onActivateWindow?(record)
            }
        case .launcher(let record):
            if showsActionLauncher, launcherTarget(at: p)?.id == record.id { activateLauncherRecord(record) }
        case .launcherChild(let parent, let child):
            if windowIndex(at: p) == nil, let hit = launcherChild(at: p), hit.menu.id == parent, hit.child.id == child {
                activateLauncherRecord(hit.child)
            } else { updateHover(at: p) }
        case .inactive:
            if showsActionLauncher, launcherTarget(at: p) == nil, hypot(p.x - pressPoint.x, p.y - pressPoint.y) < 6 { activateLauncher(at: p) }
        case .background:
            // A late hover response must not turn a background press into a new target.
            if hypot(p.x - pressPoint.x, p.y - pressPoint.y) < 6,
               closeTarget(at: pressPoint) == nil, windowIndex(at: pressPoint) == nil,
               appTarget(at: pressPoint) == nil, launcherChild(at: pressPoint) == nil {
                activate(at: pressPoint)
            }
        }
    }

    func cancelPointerInteraction() {
        pressTarget = nil
        isDraggingApp = false
        hoveredClose = nil
    }

    func activate(at p: CGPoint) {
        if showsActionLauncher { activateLauncher(at: p); return }
        if let target = closeTarget(at: p) { onCloseWindow?(target); return }
        if let index = windowIndex(at: p) {
            onActivateWindow?(visibleWindows[index]); return
        }
        if let hit = launcherChild(at: p) { activateLauncherRecord(hit.child); return }
        if let app = appTarget(at: p) {
            activateApp(app, singleWindow: selectedApp == app.running?.pid && windows.count == 1 ? windows[0] : nil)
            return
        }
        let radius = hypot(p.x - RingGeometry.center.x, p.y - RingGeometry.center.y)
        if radius < RingGeometry.appInner {
            if pageControlsRect.contains(p) {
                let direction = p.x < RingGeometry.center.x ? -1 : 1
                if launcherChildPages > 1 { changeLauncherChildPage(direction) }
                else if showsWindowArc && windowPages > 1 { changeWindowPage(direction) }
                else if appPages > 1 { changeAppPage(direction) }
            } else if !AXIsProcessTrusted() || (showsLauncher && launcherApps.isEmpty) { scheduleCenterSettings() }
            return
        }
        onClose?()
    }

    private func activateApp(_ tile: RingApp, singleWindow: WindowRecord? = nil) {
        if let favorite = tile.favorite, favorite.item.secondary != nil { select(tile) }
        else if let favorite = tile.favorite, favorite.available { activateLauncherRecord(favorite) }
        else if let running = tile.running {
            if let singleWindow { onActivateWindow?(singleWindow) }
            else { onActivateApp?(running) }
        }
    }

    func contextMenu(at p: CGPoint) -> NSMenu? {
        guard !showsActionLauncher, !isPointerDown, !isEditingName else { return nil }
        if let record = closeTarget(at: p) { return makeWindowMenu?(record) }
        if let index = windowIndex(at: p) { return makeWindowMenu?(visibleWindows[index]) }
        if let app = appTarget(at: p)?.running { return makeAppMenu?(app) }
        return nil
    }

    func updateWindow(_ id: String, name: String, color: SectorColor?) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        cancelHover(); cancelPointerInteraction()
        setHoveredWindow(nil)
        windows[index].customName = WindowRecord.normalizedName(name)
        windows[index].customColor = color
        windows = WindowRecord.sortedByName(windows)
        if let position = windows.firstIndex(where: { $0.id == id }) { windowPage = position / windowPageSize }
        refresh()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard acceptsPointerEvent(event) else { return }
        guard !showsActionLauncher, !isPointerDown, !isEditingName else { return }
        guard let menu = contextMenu(at: point(event)) else { return }
        onPointerInteraction?()
        cancelHover()
        onHoverWindow?(nil)
        isContextMenuOpen = true
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        isContextMenuOpen = false
        let action = afterContextMenu; afterContextMenu = nil
        action?()
        if isEditingName { return }
        // Modifier events can be consumed by menu tracking; reconcile once it ends.
        updateOption(pressed: NSEvent.modifierFlags.contains(.option), allowEntry: false)
        if window?.isVisible == true {
            // Do not steal focus back when menu cancellation came from another app.
            if window?.isKeyWindow == true { window?.makeFirstResponder(self) }
            else { onClose?() }
        }
    }

    override func flagsChanged(with event: NSEvent) {
        updateOption(pressed: event.modifierFlags.contains(.option))
    }

    override func scrollWheel(with event: NSEvent) {
        endKeyboardNavigation()
        guard !isPointerDown, !isContextMenuOpen, !isEditingName else { return }
        guard abs(event.scrollingDeltaY) > 0.1 || abs(event.scrollingDeltaX) > 0.1 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - scrollTime > 0.22, event.momentumPhase == [] else { return }
        scrollTime = now
        let p = point(event)
        let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        let direction = delta < 0 ? 1 : -1
        if showsActionLauncher { changeLauncherPage(direction); return }
        if windowIndex(at: p) == nil, let hit = launcherChild(at: p), !usesLauncherStrips || hit.menu.pageCount > 1 {
            changeLauncherChildPage(direction, parent: hit.menu.id)
            return
        }
        if hypot(p.x - RingGeometry.center.x, p.y - RingGeometry.center.y) >= RingGeometry.windowInner, showsWindowArc {
            changeWindowPage(direction)
        } else { changeAppPage(direction) }
    }

    func changeAppPage(_ direction: Int) {
        guard !showsActionLauncher else { return }
        cancelPointerInteraction()
        guard appPages > 1 else { return }
        appPage = RingGeometry.wrapped(appPage + direction, count: appPages)
        countsFromSelection.removeAll()
        clearSelection()
        onVisibleAppsChanged?()
    }

    func changeWindowPage(_ direction: Int) {
        cancelPointerInteraction()
        guard windowPages > 1 else { return }
        windowPage = RingGeometry.wrapped(windowPage + direction, count: windowPages)
        setHoveredWindow(nil); refresh()
    }

    // Normal Escape dismissal is handled by RingController; pointer cancellation stays local.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, showsActionLauncher {
            endLauncherMode(); return
        }
        if event.keyCode == 53, isPointerDown {
            cancelPointerInteraction()
            refresh()
        }
    }

    private func endKeyboardNavigation() {
        keyboardPointer = nil
        keyboardSecondary = false
        pendingSecondary = false
    }

    func navigate(_ command: RingNavigation) {
        guard !isEditingName, !isContextMenuOpen, !isPointerDown else { return }
        cancelHover()
        centerClickWork?.cancel(); centerClickWork = nil
        keyboardPointer = NSEvent.mouseLocation
        hoveredClose = nil
        switch command {
        case .step(let direction):
            pendingSecondary = false
            if showsActionLauncher {
                let apps = actionLauncherApps
                let current = apps.firstIndex { $0.id == hoveredLauncher }
                guard let next = RingNavigation.next(current: current, pageStart: launcherPage * 12,
                    total: apps.count, direction: direction) else { return }
                launcherPage = next / 12
                hoveredLauncher = apps[next].id
                refresh()
            } else if let arc = activeLauncherMenu, keyboardSecondary || hoveredLauncherChild != nil {
                let children = arc.record.children
                let current = children.firstIndex { arc.key($0) == hoveredLauncherChild }
                guard let next = RingNavigation.next(current: current, pageStart: arc.children.startIndex,
                    total: children.count, direction: direction) else { return }
                keyboardSecondary = true
                setLauncherChildPage(next / options.launcherSecondaryStyle.pageSize, menu: arc)
                hoveredLauncherChild = arc.key(children[next])
                refresh()
            } else if keyboardSecondary || hoveredWindow != nil {
                guard showsWindowArc else { keyboardSecondary = false; return }
                keyboardSecondary = true
                let current = windows.firstIndex { $0.id == hoveredWindow }
                guard let next = RingNavigation.next(current: current, pageStart: windowPage * windowPageSize,
                    total: windows.count, direction: direction) else { return }
                let changedPage = windowPage != next / windowPageSize
                windowPage = next / windowPageSize
                // Update the arc before positioning the preview on the new page.
                if changedPage { refresh() }
                setHoveredWindow(windows[next])
            } else {
                let apps = ringApps
                let current = apps.firstIndex { $0.id == hoveredApp }
                guard let next = RingNavigation.next(current: current, pageStart: appPage * appPageSize,
                    total: apps.count, direction: direction) else { return }
                let page = next / appPageSize
                let changed = page != appPage
                if changed {
                    countsFromSelection.removeAll()
                    appPage = page
                    clearSelection(preserveKeyboard: true)
                }
                select(apps[next])
                if changed { onVisibleAppsChanged?() }
            }
        case .toggleSecondary:
            guard !showsActionLauncher else { return }
            if let arc = activeLauncherMenu {
                let entering = !keyboardSecondary && hoveredLauncherChild == nil
                keyboardSecondary = entering && !arc.children.isEmpty
                setHoveredLauncherChild(entering ? arc.children.first : nil)
            } else if keyboardSecondary || hoveredWindow != nil || pendingSecondary {
                pendingSecondary = false
                keyboardSecondary = false
                setHoveredWindow(nil)
                hoveredApp = visibleRingApps.first { $0.running?.pid == selectedApp }?.id
                refresh()
            } else if loading, selectedApp != nil {
                // Pressing again before the query finishes cancels entry.
                pendingSecondary = true
            } else { enterSecondary() }
        case .activate:
            if showsActionLauncher {
                if let record = actionLauncherApps.first(where: { $0.id == hoveredLauncher }) { activateLauncherRecord(record) }
            } else if let record = currentLauncherChild {
                activateLauncherRecord(record)
            } else if let record = currentWindow {
                if !closingWindowIDs.contains(record.id) { onActivateWindow?(record) }
            } else if let arc = activeLauncherMenu, let first = arc.children.first {
                if usesLauncherStrips { activateLauncherRecord(first) }
                else {
                    keyboardSecondary = true
                    setHoveredLauncherChild(first)
                }
            } else if let tile = highlightedTile {
                activateApp(tile)
            }
        }
    }

    private func enterSecondary() {
        guard showsWindowArc else { return }
        keyboardSecondary = true
        if currentWindow == nil { setHoveredWindow(visibleWindows.first) }
        refresh()
    }

    func activateHovered() {
        guard !isEditingName, !isContextMenuOpen, !isPointerDown, hoveredClose == nil else { return }
        if showsActionLauncher {
            if let record = actionLauncherApps.first(where: { $0.id == hoveredLauncher }), record.available {
                activateLauncherRecord(record)
            } else {
                onClose?()
            }
            return
        }
        if let record = currentLauncherChild, record.available { activateLauncherRecord(record) }
        else if usesLauncherStrips, keyboardPointer != nil, let first = activeLauncherMenu?.children.first, first.available {
            activateLauncherRecord(first)
        }
        else if expandedLauncherID != nil { onClose?() }
        else if let window = currentWindow { onActivateWindow?(window) }
        else if let tile = highlightedTile, tile.available {
            activateApp(tile, singleWindow: selectedApp == tile.running?.pid && windows.count == 1 ? windows[0] : nil)
        } else { onClose?() }
    }

    private var ink: NSColor { .labelColor }
    private var muted: NSColor { .secondaryLabelColor }
    private var accent: NSColor { .controlAccentColor }
    private var dark: Bool { diskArtwork.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    var appHighlightPath: CGPath? {
        let apps = visibleRingApps
        guard !isDraggingApp, let tile = highlightedTile, let index = apps.firstIndex(where: { $0.id == tile.id }) else { return nil }
        if usesLauncherStrips, tile.favorite?.children.isEmpty == false { return nil }
        return RingGeometry.appPetalPath(index: index, count: apps.count)
    }

    private func drawDisk() {
        if showsActionLauncher { drawLauncher(); return }
        drawCenter()
    }

    private func drawLauncherArc() {
        let menus = visibleLauncherMenus
        guard !menus.isEmpty else { return }
        let spacing = LauncherTileLayout.primarySpacing(count: visibleRingApps.count)
        let primary = LauncherTileLayout(primarySpacing: spacing, showsName: options.launcherShowsItemNames)
        for menu in menus {
            for (index, record) in menu.children.enumerated() {
                let point = menu.layout.point(index)
                let highlighted = menu.key(record) == hoveredLauncherChild
                let tile = primary.secondary(spacing: menu.layout.tileSpacing(at: index, mainSpacing: spacing))
                if highlighted, let context = NSGraphicsContext.current?.cgContext {
                    context.setFillColor(accent.withAlphaComponent(dark ? 0.35 : 0.20).cgColor)
                    context.addPath(menu.layout.highlightPath(for: tile, at: index))
                    context.fillPath()
                }
                drawLauncherName(record.name, available: record.available, highlighted: highlighted, tile: tile, at: point)
            }
        }
    }

    private func updateLauncherChildTiles(_ menus: [LauncherMenuLayout], primary: LauncherTileLayout, spacing: CGFloat) {
        let childIDs = Set(menus.flatMap { menu in menu.children.map { menu.key($0) } })
        for id in launcherChildTiles.keys.filter({ !childIDs.contains($0) }) {
            launcherChildTiles.removeValue(forKey: id)?.removeFromSuperview()
        }
        for menu in menus {
            for (index, child) in menu.children.enumerated() {
                let id = menu.key(child)
                let tile = launcherChildTiles[id] ?? RingTile(glass: false)
                if launcherChildTiles[id] == nil {
                    launcherChildTiles[id] = tile
                    launcherChildGroup.addSubview(tile)
                }
                let iconRect = primary.secondary(spacing: menu.layout.tileSpacing(at: index, mainSpacing: spacing))
                    .iconRect(at: menu.layout.point(index))
                tile.place(in: iconRect)
                tile.artwork.render = {
                    child.icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: child.available ? 1 : 0.45)
                }
                tile.update(highlighted: id == hoveredLauncherChild, animated: window?.isVisible == true)
            }
        }
    }

    private func drawAppHighlight() {
        guard !showsActionLauncher else { return }
        if let path = appHighlightPath, let context = NSGraphicsContext.current?.cgContext {
            NSGraphicsContext.saveGraphicsState()
            // Keep tint outside glass refraction, between the center inset and rim.
            context.addPath(path)
            let color = accent.blended(withFraction: dark ? 0.64 : 0.10, of: .black) ?? accent
            color.withAlphaComponent(dark ? 0.76 : 0.64).setFill()
            context.fillPath()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // Drag feedback must remain visible beyond the material's clipped contour.
    private func drawDrag() {
        if let app = draggedApp {
            let size = appIconSize
            let point = CGPoint(x: min(max(dragPoint.x, size), bounds.maxX - size), y: min(max(dragPoint.y, size), bounds.maxY - size))
            app.icon.draw(in: NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size))
            if dragWillQuit {
                let outline = NSBezierPath(ovalIn: NSRect(x: RingGeometry.center.x - RingGeometry.appOuter - 3,
                    y: RingGeometry.center.y - RingGeometry.appOuter - 3, width: (RingGeometry.appOuter + 3) * 2, height: (RingGeometry.appOuter + 3) * 2))
                NSColor.systemRed.withAlphaComponent(0.65).setStroke(); outline.lineWidth = 2; outline.stroke()
                let badge = NSRect(x: point.x + size / 2 - 8, y: point.y + size / 2 - 8, width: 16, height: 16)
                NSColor.systemRed.setFill(); NSBezierPath(ovalIn: badge).fill()
                drawSymbol("xmark", rect: badge.insetBy(dx: 4, dy: 4), color: .white)
            }
        }
    }

    private func drawBadge(_ text: String, on icon: NSRect) {
        let height = min(14, max(10, icon.width * 0.45))
        let font = NSFont.monospacedDigitSystemFont(ofSize: height * 0.7, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: dark ? NSColor.black : NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let width = max(height, size.width + 5)
        let rect = NSRect(x: icon.maxX - width + 3, y: icon.minY - 3, width: width, height: height)
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: height / 2 + 1, yRadius: height / 2 + 1)
        (dark ? NSColor.black : NSColor.white).setFill(); outline.fill()
        let badge = NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2)
        (dark ? NSColor.white : NSColor.black).setFill(); badge.fill()
        (text as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }

    private func drawWindow(_ win: WindowRecord, index: Int) {
        let selected = win.id == hoveredWindow || win.id == hoveredClose
        let p = windowPoint(index)
        let shape = RingGeometry.windowPetalPath(index: index, count: visibleWindows.count, anchor: arcAnchor)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if let color = win.customColor {
            color.color.withAlphaComponent(dark ? 0.27 : 0.14).setFill()
            context.addPath(shape); context.fillPath()
        }
        if selected {
            accent.withAlphaComponent(dark ? 0.16 : 0.08).setFill()
            context.addPath(shape); context.fillPath()
            NSColor.white.withAlphaComponent(dark ? 0.28 : 0.75).setStroke()
            context.setLineWidth(0.75); context.addPath(shape); context.strokePath()
        }
        let symbol = win.tab != nil ? "globe" : win.minimized ? "minus.rectangle" : (win.fullscreen ? "arrow.up.left.and.arrow.down.right" : "macwindow")
        drawSymbol(symbol, rect: NSRect(x: p.x - 8, y: p.y + 9, width: 16, height: 14), color: selected ? accent : muted)
        drawText(win.displayTitle, rect: NSRect(x: p.x - 32, y: p.y - 25, width: 64, height: 29),
            font: .systemFont(ofSize: 10, weight: .medium), color: ink)
        let close = closeButtonRect(at: index)
        let pending = closingWindowIDs.contains(win.id)
        let highlighted = !pending && hoveredClose == win.id
        (highlighted ? NSColor.systemRed : NSColor.labelColor.withAlphaComponent(dark ? 0.12 : 0.05)).setFill()
        NSBezierPath(ovalIn: close).fill()
        drawSymbol(pending ? "ellipsis" : "xmark", rect: close.insetBy(dx: 5, dy: 5), color: highlighted ? .white : muted)
    }

    private func drawApp(_ app: RingApp, at p: CGPoint, size: Double) {
        let iconRect = NSRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
        let dragged = draggedApp.map { $0.pid == app.running?.pid } ?? false
        app.icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: dragged ? 0.25 : (app.available ? 1 : 0.45))
        if let pid = app.running?.pid, let badge = itemCounts[pid]?.badge { drawBadge(badge, on: iconRect) }
    }

    private func drawLauncherName(_ name: String, available: Bool, highlighted: Bool,
                                  tile: LauncherTileLayout, at point: CGPoint) {
        guard tile.labelHeight > 0 else { return }
        let font = NSFont.systemFont(ofSize: tile.fontSize, weight: highlighted ? .semibold : .regular)
        RingCenterLabel.text(name, in: tile.labelRect(at: point), font: font,
                             color: available ? ink : muted, wraps: false)
    }

    private func updateTiles() {
        let menus = visibleLauncherMenus
        appGroup.isHidden = showsActionLauncher
        let apps = showsActionLauncher ? [] : visibleRingApps
        let appIDs = Set(apps.map(\.id))
        let spacing = LauncherTileLayout.primarySpacing(count: apps.count)
        let layout = LauncherTileLayout(primarySpacing: spacing, showsName: showsLauncher && options.launcherShowsItemNames)
        updateLauncherChildTiles(menus, primary: layout, spacing: spacing)
        let highlightID = isDraggingApp ? nil : highlightedTile?.id
        let replacedEntries = Set(menus.filter { $0.layout.replacesEntry }.map(\.id))
        for id in appTiles.keys.filter({ !appIDs.contains($0) }) { appTiles.removeValue(forKey: id)?.removeFromSuperview() }
        for (index, app) in apps.enumerated() {
            let fresh = appTiles[app.id] == nil
            let tile = appTiles[app.id] ?? RingTile(glass: false)
            if fresh { appTiles[app.id] = tile; appGroup.addSubview(tile) }
            tile.isHidden = app.favorite.map { replacedEntries.contains($0.id) } ?? false
            let p = RingGeometry.appIconCenter(index: index, count: apps.count)
            let side = max(layout.labelWidth + 4, layout.height + 4, layout.iconSize + 20)
            tile.place(in: CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side))
            let highlighted = app.id == highlightID
            tile.artwork.render = { [weak self] in
                let icon = layout.iconRect(at: p)
                self?.drawApp(app, at: CGPoint(x: icon.midX, y: icon.midY), size: layout.iconSize)
                self?.drawLauncherName(app.name, available: app.available, highlighted: highlighted, tile: layout, at: p)
            }
            tile.update(highlighted: highlighted, animated: window?.isVisible == true)
            if fresh, window?.isVisible == true { tile.reveal(index: index, count: apps.count) }
        }
        let windows = visibleWindows
        let windowIDs = Set(windows.map(\.id))
        for id in windowTiles.keys.filter({ !windowIDs.contains($0) }) { windowTiles.removeValue(forKey: id)?.removeFromSuperview() }
        for (index, win) in windows.enumerated() {
            let fresh = windowTiles[win.id] == nil
            let tile = windowTiles[win.id] ?? RingTile(glass: true)
            if fresh { windowTiles[win.id] = tile; arcGroup.addSubview(tile) }
            let shape = RingGeometry.windowPetalPath(index: index, count: windows.count, anchor: arcAnchor)
            tile.place(in: shape.boundingBoxOfPath.integral, shape: shape)
            tile.artwork.render = { [weak self] in self?.drawWindow(win, index: index) }
            tile.update(highlighted: win.id == hoveredWindow || win.id == hoveredClose, animated: window?.isVisible == true)
            if fresh, window?.isVisible == true { tile.reveal(index: index, count: windows.count) }
        }
    }

    func animateOpening() {
        layoutSubtreeIfNeeded()
        RingMotion.open(self)
        let apps = visibleRingApps
        for (index, app) in apps.enumerated() {
            appTiles[app.id]?.reveal(index: index, count: apps.count)
        }
    }

    private func drawCenter() {
        let c = RingGeometry.center
        let radius = RingGeometry.appCenterRadius
        let inset = NSBezierPath(ovalIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
        NSColor.labelColor.withAlphaComponent(dark ? 0.055 : 0.025).setFill(); inset.fill()
        NSColor.white.withAlphaComponent(dark ? 0.04 : 0.24).setStroke(); inset.lineWidth = 0.6; inset.stroke()
        if let app = draggedApp {
            RingCenterLabel.draw(title: app.name,
                detail: dragWillQuit ? L10n.text("松开退出应用", "Release to quit") : L10n.text("拖出轮盘退出", "Drag out to quit"),
                titleColor: ink, detailColor: dragWillQuit ? .systemRed : muted)
            return
        }
        let app = highlightedTile ?? visibleRingApps.first { $0.running?.pid == selectedApp && selectedApp != nil }
        let name = currentLauncherChild?.name ?? app?.name ?? (showsLauncher ? L10n.text("常规", "Standard") : L10n.text("运行中的应用", "Running apps"))
        let paging = launcherChildPages > 1 || (showsWindowArc && windowPages > 1) || appPages > 1
        let detail: String
        if let child = currentLauncherChild {
            detail = child.available ? "" : L10n.text("找不到项目", "Item not found")
        } else if let app {
            if let arc = activeLauncherMenu { detail = arc.children.isEmpty ? L10n.text("无项目", "No items") : "" }
            else if !app.available { detail = L10n.text("找不到项目", "Item not found") }
            else if selectingWithShortcut && highlightedTile != nil { detail = L10n.text("松开快捷键切换", "Release to switch") }
            else if app.running == nil { detail = L10n.text("点击打开", "Click to open") }
            else { detail = loading ? "" : message }
        } else if showsLauncher {
            detail = launcherApps.isEmpty ? L10n.text("点击添加 · 双击切换", "Click to add · Double-click to switch")
                : L10n.text("双击中心切换", "Double-click to switch")
        } else {
            detail = L10n.text("双击中心显示常用应用", "Double-click center for favorites")
        }
        let showsRingName = currentLauncherChild == nil && app?.favorite?.item.secondary != nil
        RingCenterLabel.draw(title: name, detail: detail, paging: paging,
                             titleLines: showsRingName ? 3 : nil, titleColor: ink, detailColor: muted)
        if paging {
            drawSymbol("chevron.left", rect: NSRect(x: c.x - 20, y: c.y - 29, width: 5, height: 8), color: muted)
            drawSymbol("chevron.right", rect: NSRect(x: c.x + 15, y: c.y - 29, width: 5, height: 8), color: muted)
            let page = launcherChildPages > 1 ? "\((activeLauncherMenu?.page ?? 0) + 1)/\(launcherChildPages)"
                : showsWindowArc && windowPages > 1 ? "\(windowPage + 1)/\(windowPages)" : "\(appPage + 1)/\(appPages)"
            RingCenterLabel.page(page, in: NSRect(x: c.x - 14, y: c.y - 32, width: 28, height: 14), color: muted)
        }
    }

    private func drawText(_ text: String, rect: NSRect, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.maximumLineHeight = font.pointSize + 3
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    private func drawSymbol(_ name: String, rect: NSRect, color: NSColor) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [color])) else { return }
        image.draw(in: rect)
    }

    private func rebuildAccessibility() {
        guard window != nil else { accessibleItems.clear(in: self); return }
        var items: [RingAccessibility.Entry] = []
        let c = RingGeometry.center
        func add(_ id: String, _ label: String, help: String, rect: NSRect, enabled: Bool = true, action: @escaping () -> Void) {
            items.append(.init(id: id, label: label, help: help, rect: rect, enabled: enabled, action: action))
        }
        if showsActionLauncher {
            for (i, record) in visibleLauncherApps.enumerated() {
                let p = launcherPoint(i)
                add("launcher:\(record.id)", record.name, help: L10n.text("打开应用", "Open app"),
                    rect: NSRect(x: p.x - 22, y: p.y - 22, width: 44, height: 44), enabled: record.available) { [weak self] in
                    guard let self, self.showsActionLauncher, record.available else { return }
                    self.activateLauncherRecord(record)
                }
            }
            if launcherPages > 1 {
                for direction in [-1, 1] {
                    add("launcher-page:\(direction)", direction < 0 ? L10n.text("上一页", "Previous page") : L10n.text("下一页", "Next page"), help: "",
                        rect: NSRect(x: direction < 0 ? 218 : 240, y: 208, width: 22, height: 14)) { [weak self] in self?.changeLauncherPage(direction) }
                }
            }
            add("actions", L10n.text("快捷操作", "Actions"), help: L10n.text("返回快捷操作", "Return to actions"),
                rect: NSRect(x: c.x - 34, y: c.y + 8, width: 68, height: 24)) { [weak self] in
                    guard let self, self.showsActionLauncher else { return }
                    self.endLauncherMode()
                }
            accessibleItems.update(items, in: self)
            return
        }
        let apps = visibleRingApps
        let menus = visibleLauncherMenus
        let replacedEntries = Set(menus.filter { $0.layout.replacesEntry }.map(\.id))
        for (i, app) in apps.enumerated() {
            if let record = app.favorite, replacedEntries.contains(record.id) { continue }
            let p = RingGeometry.appIconCenter(index: i, count: apps.count)
            let rect = NSRect(x: p.x - 24, y: p.y - 24, width: 48, height: 48)
            let id = app.favorite.map { "favorite:\($0.id)" } ?? "app:\(app.running?.pid ?? 0)"
            if let running = app.running {
                let mode = options.contentMode(for: running.bundleID).title
                let label = itemCounts[running.pid]?.badge.map { "\(app.name), \($0) \(mode)" } ?? app.name
                add(id, label, help: L10n.text("有多个\(mode)时展开圆弧；点击切换，拖出轮盘退出应用。", "Show windows or tabs. Click to switch; drag the app outside the ring to quit."), rect: rect) { [weak self] in
                    guard let self, let tile = self.visibleRingApps.first(where: { $0.id == app.id }), let running = tile.running else { return }
                    self.select(running)
                }
            } else {
                let help = app.favorite?.item.secondary != nil ? L10n.text("展开二级圆环", "Expand secondary ring") : L10n.text("打开项目", "Open item")
                add(id, app.name, help: help, rect: rect, enabled: app.available) { [weak self] in
                    guard let self, let tile = self.visibleRingApps.first(where: { $0.id == app.id }) else { return }
                    self.activateApp(tile)
                }
            }
        }
        for arc in menus {
            for (index, record) in arc.children.enumerated() {
                let p = arc.layout.point(index)
                add("launcher-child:\(arc.record.id):\(record.id)", record.name, help: L10n.text("打开项目", "Open item"),
                    rect: NSRect(x: p.x - 24, y: p.y - 24, width: 48, height: 48), enabled: record.available) { [weak self] in
                    guard let self, let current = self.visibleLauncherMenus.first(where: { $0.id == arc.id }),
                          let child = current.children.first(where: { $0.id == record.id }) else { return }
                    self.activateLauncherRecord(child)
                }
            }
        }
        for (i, win) in visibleWindows.enumerated() {
            let p = windowPoint(i)
            add("window:\(win.id)", win.displayTitle + (win.minimized ? L10n.text("，已最小化", ", minimized") : ""), help: L10n.text("切换到此\(secondaryName)", "Switch to this item"), rect: NSRect(x: p.x - 35, y: p.y - 29, width: 70, height: 58)) { [weak self] in self?.onActivateWindow?(win) }
            add("close:\(win.id)", L10n.text("关闭 \(win.displayTitle)", "Close \(win.displayTitle)"), help: L10n.text("关闭此窗口或标签页", "Close this window or tab"), rect: closeButtonRect(at: i)) { [weak self] in self?.onCloseWindow?(win) }
        }
        for menu in menus where menu.pageCount > 1 {
            let inCenter = menu.id == expandedLauncherID
            let entry = menu.layout.point(0)
            for direction in [-1, 1] {
                let title = direction < 0 ? L10n.text("上一页", "Previous page") : L10n.text("下一页", "Next page")
                let rect = inCenter ? NSRect(x: direction < 0 ? pageControlsRect.minX : c.x, y: pageControlsRect.minY, width: 22, height: 14)
                    : CGRect(x: entry.x - 14, y: entry.y - 14, width: 28, height: 28)
                add("launcher-child-page:\(menu.id):\(direction)", "\(menu.record.name) · \(title)", help: "", rect: rect) { [weak self] in
                    self?.changeLauncherChildPage(direction, parent: menu.id)
                }
            }
        }
        if launcherChildPages <= 1, showsWindowArc && windowPages > 1 {
            add("window-previous", L10n.text("上一页\(secondaryName)", "Previous \(secondaryName.lowercased())"), help: L10n.text("圆弧滚动翻页", "Scroll over the arc to change pages"), rect: NSRect(x: pageControlsRect.minX, y: pageControlsRect.minY, width: 22, height: 14)) { [weak self] in self?.changeWindowPage(-1) }
            add("window-next", L10n.text("下一页\(secondaryName)", "Next \(secondaryName.lowercased())"), help: L10n.text("圆弧滚动翻页", "Scroll over the arc to change pages"), rect: NSRect(x: c.x, y: pageControlsRect.minY, width: 22, height: 14)) { [weak self] in self?.changeWindowPage(1) }
        } else if launcherChildPages <= 1, appPages > 1 {
            add("app-previous", L10n.text("上一页应用", "Previous apps"), help: L10n.text("滚动或点击翻页", "Scroll or click to change pages"), rect: NSRect(x: pageControlsRect.minX, y: pageControlsRect.minY, width: 22, height: 14)) { [weak self] in self?.changeAppPage(-1) }
            add("app-next", L10n.text("下一页应用", "Next apps"), help: L10n.text("滚动或点击翻页", "Scroll or click to change pages"), rect: NSRect(x: c.x, y: pageControlsRect.minY, width: 22, height: 14)) { [weak self] in self?.changeAppPage(1) }
        }
        add("settings", L10n.text("设置", "Settings"), help: L10n.text("打开设置", "Open settings"), rect: NSRect(x: c.x - 30, y: c.y - 30, width: 60, height: 18)) { [weak self] in self?.onSettings?() }
        add(showsLauncher ? "running-apps" : "favorites",
            showsLauncher ? L10n.text("运行中的应用", "Running apps") : L10n.text("常用应用", "Favorites"),
            help: showsLauncher ? L10n.text("切换到当前正在运行的应用", "Show currently running apps")
                : L10n.text("切换到已配置的常用应用", "Show configured favorite apps"),
            rect: NSRect(x: c.x - 30, y: c.y + 8, width: 60, height: 18), enabled: !showsWindowArc) { [weak self] in
                self?.toggleLauncherFromCenter(at: c)
            }
        accessibleItems.update(items, in: self)
    }
}
