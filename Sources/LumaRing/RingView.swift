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
        switch self { case .running(let app): .running(app.pid); case .favorite(let record, _): .favorite(record.app.id) }
    }
    var name: String {
        switch self { case .running(let app): app.name; case .favorite(let record, _): record.app.name }
    }
    var icon: NSImage {
        switch self { case .running(let app): app.icon; case .favorite(let record, let app): app?.icon ?? record.icon }
    }
    var available: Bool { running != nil || favorite?.available == true }
}

@MainActor final class RingView: NSView {
    private static let centerRadius = 52.0
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
    private var collapseWork: DispatchWorkItem?
    private enum PressTarget {
        case app(RingApp, WindowRecord?, draggable: Bool)
        case window(WindowRecord)
        case close(WindowRecord)
        case background
        case launcher(LauncherRecord)
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
    private let diskArtwork = RingArtwork()
    private let highlightArtwork = RingArtwork()
    private let dragArtwork = RingArtwork()
    private let arcGroup = NSView()
    private let appGroup = NSView()
    private var appTiles: [RingApp.ID: RingTile] = [:]
    private var windowTiles: [String: RingTile] = [:]
    private let accessibleItems = RingAccessibility()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        arcGroup.wantsLayer = true
        addSubview(diskMaterial)
        diskMaterial.content.addSubview(diskArtwork)
        addSubview(highlightArtwork)
        addSubview(appGroup)
        addSubview(arcGroup)
        addSubview(dragArtwork)
        diskArtwork.render = { [weak self] in self?.drawDisk() }
        highlightArtwork.render = { [weak self] in self?.drawAppHighlight() }
        dragArtwork.render = { [weak self] in self?.drawDrag() }
        arcGroup.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        diskMaterial.frame = bounds; diskArtwork.frame = bounds
        highlightArtwork.frame = bounds
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
        showsActionLauncher
            ? CGPath(ellipseIn: CGRect(x: 42, y: 42, width: 396, height: 396), transform: nil)
            : RingGeometry.diskPath
    }
    var occupiedScreenFrame: CGRect {
        guard let window else { return .zero }
        var occupied = diskPath.boundingBoxOfPath
        if showsWindowArc {
            occupied = occupied.union(RingGeometry.arcPath(count: visibleWindows.count, anchor: arcAnchor).boundingBoxOfPath)
        }
        return window.convertToScreen(convert(occupied, to: nil))
    }
    func windowScreenFrame(_ id: String) -> CGRect? {
        guard let window, let index = visibleWindows.firstIndex(where: { $0.id == id }) else { return nil }
        let p = windowPoint(index)
        return window.convertToScreen(convert(NSRect(x: p.x - 35, y: p.y - 29, width: 70, height: 58), to: nil))
    }
    var appPageSize: Int { min(24, max(4, options.appPageSize)) }
    var windowPageSize: Int {
        min(RingGeometry.windowPageSizeRange.upperBound, max(RingGeometry.windowPageSizeRange.lowerBound, options.windowPageSize))
    }
    var appIconSize: Double { min(34, 2 * RingGeometry.appRadius * sin(.pi / Double(max(visibleRingApps.count, 2))) * 0.76) }
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
            return launcherApps.map { .favorite($0, running: running[$0.app.bundleID]) }
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
        guard let app = tile.running else {
            if selectedApp != nil { clearSelection(preserveKeyboard: true) }
            if hoveredApp != tile.id { hoveredApp = tile.id; refreshArtwork() }
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
        diskMaterial.setShape(diskPath)
        refreshArtwork()
        rebuildAccessibility()
    }

    func refreshArtwork() {
        diskArtwork.needsDisplay = true
        highlightArtwork.needsDisplay = true
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
            let id = launcherTarget(at: p)?.app.id
            if id != hoveredLauncher { hoveredLauncher = id; refreshArtwork() }
            return
        }
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
                    if hoveredApp != nil { hoveredApp = nil; refreshArtwork() }
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
        else if let app = appTarget(at: p), let index = visibleRingApps.firstIndex(where: { $0.id == app.id }) {
            let center = RingGeometry.point(angle: RingGeometry.angle(index: index, count: visibleRingApps.count), radius: RingGeometry.appRadius)
            let hitSize = appIconSize + 12
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
            if showsActionLauncher, record.available, launcherTarget(at: p)?.app.id == record.app.id { onLaunchApp?(record.app) }
        case .inactive:
            if showsActionLauncher, launcherTarget(at: p) == nil, hypot(p.x - pressPoint.x, p.y - pressPoint.y) < 6 { activateLauncher(at: p) }
        case .background:
            // A late hover response must not turn a background press into a new target.
            if hypot(p.x - pressPoint.x, p.y - pressPoint.y) < 6,
               closeTarget(at: pressPoint) == nil, windowIndex(at: pressPoint) == nil, appTarget(at: pressPoint) == nil {
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
        if let app = appTarget(at: p) {
            activateApp(app, singleWindow: selectedApp == app.running?.pid && windows.count == 1 ? windows[0] : nil)
            return
        }
        let radius = hypot(p.x - RingGeometry.center.x, p.y - RingGeometry.center.y)
        if radius < RingGeometry.appInner {
            if pageControlsRect.contains(p) {
                if showsWindowArc && windowPages > 1 { changeWindowPage(p.x < RingGeometry.center.x ? -1 : 1) }
                else if appPages > 1 { changeAppPage(p.x < RingGeometry.center.x ? -1 : 1) }
            } else if !AXIsProcessTrusted() || (showsLauncher && launcherApps.isEmpty) { scheduleCenterSettings() }
            return
        }
        onClose?()
    }

    private func activateApp(_ tile: RingApp, singleWindow: WindowRecord? = nil) {
        if let favorite = tile.favorite, favorite.available { onLaunchApp?(favorite.app) }
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
                let current = launcherApps.firstIndex { $0.app.id == hoveredLauncher }
                guard let next = RingNavigation.next(current: current, pageStart: launcherPage * 12,
                    total: launcherApps.count, direction: direction) else { return }
                launcherPage = next / 12
                hoveredLauncher = launcherApps[next].app.id
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
            if keyboardSecondary || hoveredWindow != nil || pendingSecondary {
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
                if let record = launcherApps.first(where: { $0.app.id == hoveredLauncher }), record.available {
                    onLaunchApp?(record.app)
                }
            } else if let record = currentWindow {
                if !closingWindowIDs.contains(record.id) { onActivateWindow?(record) }
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
            if let record = launcherApps.first(where: { $0.app.id == hoveredLauncher }), record.available {
                onLaunchApp?(record.app)
            } else {
                onClose?()
            }
            return
        }
        if let window = currentWindow { onActivateWindow?(window) }
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
        let inner = Self.centerRadius + 0.5, outer = RingGeometry.appOuter - 0.75
        if selectingWithShortcut, showsWindowArc, tile.running?.pid == selectedApp,
           RingGeometry.arcHalfAngle(count: visibleWindows.count) > .pi / Double(apps.count) {
            return RingGeometry.arcPath(count: visibleWindows.count, anchor: arcAnchor,
                inner: inner, outer: outer)
        }
        return RingGeometry.sectorPath(index: index, count: apps.count, inner: inner, outer: outer)
    }

    private func drawDisk() {
        if showsActionLauncher { drawLauncher(); return }
        drawCenter()
    }

    private func drawAppHighlight() {
        guard !showsActionLauncher else { return }
        if let path = appHighlightPath, let context = NSGraphicsContext.current?.cgContext {
            NSGraphicsContext.saveGraphicsState()
            // Keep tint outside glass refraction, between the center inset and rim.
            // Floating icons retain their independent lift animation.
            context.addPath(path)
            NSColor.controlAccentColor.withAlphaComponent(dark ? 0.09 : 0.045).setFill()
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

    private func drawApp(_ app: RingApp, at p: CGPoint, size: Double, highlighted: Bool) {
        let iconRect = NSRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
        if highlighted {
            let plate = NSBezierPath(roundedRect: iconRect.insetBy(dx: -4, dy: -4), xRadius: 10, yRadius: 10)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.28 : 0.16)
            shadow.shadowBlurRadius = 5; shadow.shadowOffset = NSSize(width: 0, height: -2); shadow.set()
            NSColor.white.withAlphaComponent(dark ? 0.15 : 0.55).setFill(); plate.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.withAlphaComponent(dark ? 0.22 : 0.8).setStroke(); plate.lineWidth = 0.7; plate.stroke()
        }
        let dragged = draggedApp.map { $0.pid == app.running?.pid } ?? false
        app.icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: dragged ? 0.25 : (app.available ? 1 : 0.45))
        if let pid = app.running?.pid, let badge = itemCounts[pid]?.badge { drawBadge(badge, on: iconRect) }
    }

    private func updateTiles() {
        appGroup.isHidden = showsActionLauncher
        let apps = showsActionLauncher ? [] : visibleRingApps
        let appIDs = Set(apps.map(\.id))
        let size = appIconSize
        let highlightID = isDraggingApp ? nil : highlightedTile?.id
        for id in appTiles.keys.filter({ !appIDs.contains($0) }) { appTiles.removeValue(forKey: id)?.removeFromSuperview() }
        for (index, app) in apps.enumerated() {
            let fresh = appTiles[app.id] == nil
            let tile = appTiles[app.id] ?? RingTile(glass: false)
            if fresh { appTiles[app.id] = tile; appGroup.addSubview(tile) }
            let p = RingGeometry.point(angle: RingGeometry.angle(index: index, count: apps.count), radius: RingGeometry.appRadius)
            let side = size + 20
            tile.place(in: CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side))
            let highlighted = app.id == highlightID
            tile.artwork.render = { [weak self] in self?.drawApp(app, at: p, size: size, highlighted: highlighted) }
            tile.update(highlighted: highlighted, animated: window?.isVisible == true)
            if fresh, window?.isVisible == true { tile.reveal(index: index, count: apps.count, secondary: false) }
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
            if fresh, window?.isVisible == true { tile.reveal(index: index, count: windows.count, secondary: true) }
        }
    }

    func animateOpening() {
        layoutSubtreeIfNeeded()
        RingMotion.open(self)
        let apps = visibleRingApps
        for (index, app) in apps.enumerated() {
            appTiles[app.id]?.reveal(index: index, count: apps.count, secondary: false)
        }
    }

    private func drawCenter() {
        let c = RingGeometry.center
        let radius = Self.centerRadius
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
        let name = app?.name ?? (showsLauncher ? L10n.text("常用应用", "Favorites") : L10n.text("运行中的应用", "Running apps"))
        let paging = (showsWindowArc && windowPages > 1) || appPages > 1
        let detail: String
        if let app {
            if !app.available { detail = L10n.text("找不到应用", "App not found") }
            else if selectingWithShortcut && highlightedTile != nil { detail = L10n.text("松开快捷键切换", "Release to switch") }
            else if app.running == nil { detail = L10n.text("点击打开", "Click to open") }
            else { detail = loading ? "" : message }
        } else if showsLauncher {
            detail = launcherApps.isEmpty ? L10n.text("点击添加 · 双击切换", "Click to add · Double-click to switch")
                : L10n.text("双击中心切换", "Double-click to switch")
        } else {
            detail = L10n.text("双击中心显示常用应用", "Double-click center for favorites")
        }
        RingCenterLabel.draw(title: name, detail: detail,
                             paging: paging, titleColor: ink, detailColor: muted)
        if paging {
            drawSymbol("chevron.left", rect: NSRect(x: c.x - 20, y: c.y - 29, width: 5, height: 8), color: muted)
            drawSymbol("chevron.right", rect: NSRect(x: c.x + 15, y: c.y - 29, width: 5, height: 8), color: muted)
            let page = showsWindowArc && windowPages > 1 ? "\(windowPage + 1)/\(windowPages)" : "\(appPage + 1)/\(appPages)"
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
                add("launcher:\(record.app.id)", record.app.name, help: L10n.text("打开应用", "Open app"),
                    rect: NSRect(x: p.x - 22, y: p.y - 22, width: 44, height: 44), enabled: record.available) { [weak self] in
                    guard let self, self.showsActionLauncher, record.available else { return }
                    self.onLaunchApp?(record.app)
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
        for (i, app) in apps.enumerated() {
            let p = RingGeometry.point(angle: RingGeometry.angle(index: i, count: apps.count), radius: RingGeometry.appRadius)
            let rect = NSRect(x: p.x - 24, y: p.y - 24, width: 48, height: 48)
            let id = app.favorite.map { "favorite:\($0.app.id)" } ?? "app:\(app.running?.pid ?? 0)"
            if let running = app.running {
                let mode = options.contentMode(for: running.bundleID).title
                let label = itemCounts[running.pid]?.badge.map { "\(app.name), \($0) \(mode)" } ?? app.name
                add(id, label, help: L10n.text("有多个\(mode)时展开圆弧；点击切换，拖出轮盘退出应用。", "Show windows or tabs. Click to switch; drag the app outside the ring to quit."), rect: rect) { [weak self] in
                    guard let self, let tile = self.visibleRingApps.first(where: { $0.id == app.id }), let running = tile.running else { return }
                    self.select(running)
                }
            } else {
                add(id, app.name, help: L10n.text("打开应用", "Open app"), rect: rect, enabled: app.available) { [weak self] in
                    guard let self, let tile = self.visibleRingApps.first(where: { $0.id == app.id }) else { return }
                    self.activateApp(tile)
                }
            }
        }
        for (i, win) in visibleWindows.enumerated() {
            let p = windowPoint(i)
            add("window:\(win.id)", win.displayTitle + (win.minimized ? L10n.text("，已最小化", ", minimized") : ""), help: L10n.text("切换到此\(secondaryName)", "Switch to this item"), rect: NSRect(x: p.x - 35, y: p.y - 29, width: 70, height: 58)) { [weak self] in self?.onActivateWindow?(win) }
            add("close:\(win.id)", L10n.text("关闭 \(win.displayTitle)", "Close \(win.displayTitle)"), help: L10n.text("关闭此窗口或标签页", "Close this window or tab"), rect: closeButtonRect(at: i)) { [weak self] in self?.onCloseWindow?(win) }
        }
        if showsWindowArc && windowPages > 1 {
            add("window-previous", L10n.text("上一页\(secondaryName)", "Previous \(secondaryName.lowercased())"), help: L10n.text("圆弧滚动翻页", "Scroll over the arc to change pages"), rect: NSRect(x: pageControlsRect.minX, y: pageControlsRect.minY, width: 22, height: 14)) { [weak self] in self?.changeWindowPage(-1) }
            add("window-next", L10n.text("下一页\(secondaryName)", "Next \(secondaryName.lowercased())"), help: L10n.text("圆弧滚动翻页", "Scroll over the arc to change pages"), rect: NSRect(x: c.x, y: pageControlsRect.minY, width: 22, height: 14)) { [weak self] in self?.changeWindowPage(1) }
        } else if appPages > 1 {
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
