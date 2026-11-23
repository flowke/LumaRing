import AppKit
import LumaRingCore

enum LauncherArc {
    static let inner = RingGeometry.appOuter + 7
    static let outer = inner + 68
    static let radius = (inner + outer) / 2
    static let pageSize = 6

    static func path(count: Int, anchor: Double) -> CGPath {
        RingGeometry.arcPath(count: count, anchor: anchor, inner: inner, outer: outer, corner: 12)
    }

    static func point(index: Int, count: Int, anchor: Double) -> CGPoint {
        RingGeometry.point(angle: RingGeometry.arcAngle(index: index, count: count, anchor: anchor), radius: radius)
    }
}

enum LauncherSecondaryStyle: String, Codable {
    case arc, strip

    var pageSize: Int { self == .arc ? LauncherArc.pageSize : 3 }
}

/// Positions and contours in the same coordinates as the main disk.
struct LauncherSecondaryLayout: Equatable {
    let style: LauncherSecondaryStyle
    let anchor: Double
    let count: Int
    let stripHalfWidth: Double

    init(style: LauncherSecondaryStyle, anchor: Double, count: Int, stripHalfWidth: Double = 27) {
        self.style = style
        self.anchor = anchor
        self.count = count
        self.stripHalfWidth = stripHalfWidth
    }

    static let stripStep = 48.0
    private static let endPadding = 28.0

    var replacesEntry: Bool { style == .strip && count > 0 }
    var arcPath: CGPath? {
        guard style == .arc, count > 0 else { return nil }
        return LauncherArc.path(count: count, anchor: anchor)
    }

    var surfaceBounds: CGRect {
        let bounds = diskPath.boundingBoxOfPath
        return arcPath.map { bounds.union($0.boundingBoxOfPath) } ?? bounds
    }

    private func stripRadius(_ index: Int) -> Double {
        RingGeometry.appRadius + Self.stripStep * Double(index)
    }

    func point(_ index: Int) -> CGPoint {
        if style == .arc { return LauncherArc.point(index: index, count: count, anchor: anchor) }
        return RingGeometry.point(angle: anchor, radius: stripRadius(index))
    }

    var diskPath: CGPath { Self.diskPath(with: [self]) }

    /// Adjacent strips share the space at the rim. A lone strip keeps its full width.
    static func stripWidths(childCounts: [Int]) -> [Double] {
        let anchors = childCounts.indices.map { RingGeometry.angle(index: $0, count: childCounts.count) }
        let extensions = childCounts.indices.filter { childCounts[$0] > 1 }
        return anchors.indices.map { index in
            let closest = extensions.lazy.filter { $0 != index }.map {
                let delta = anchors[$0] - anchors[index]
                return abs(atan2(sin(delta), cos(delta)))
            }.min() ?? .pi
            let available = RingGeometry.appOuter * sin(closest / 2)
            return min(27, max(9, (available - 1) / 1.48))
        }
    }

    private var joinY: Double { stripHalfWidth * (40.0 / 27) }
    private var joinAngle: Double { asin(joinY / RingGeometry.appOuter) }

    static func diskPath(with layouts: [Self]) -> CGPath {
        let strips = layouts.filter { $0.style == .strip && $0.count > 1 }
            .map { (angle: RingGeometry.normalized($0.anchor), layout: $0) }
            .sorted { $0.angle < $1.angle }
        guard let first = strips.first else { return RingGeometry.diskPath }
        let path = CGMutablePath()
        let radius = RingGeometry.appOuter
        path.move(to: RingGeometry.point(angle: first.angle - first.layout.joinAngle, radius: radius))
        for index in strips.indices {
            let strip = strips[index]
            strip.layout.addStripEdge(to: path)
            let next = strips[(index + 1) % strips.count]
            let nextAngle = next.angle + (index == strips.count - 1 ? 2 * .pi : 0)
            path.addArc(center: RingGeometry.center, radius: radius,
                        startAngle: strip.angle + strip.layout.joinAngle,
                        endAngle: nextAngle - next.layout.joinAngle, clockwise: false)
        }
        path.closeSubpath()
        return path
    }

    private func addStripEdge(to path: CGMutablePath) {
        let radius = RingGeometry.appOuter
        let width = stripHalfWidth
        let joinX = radius * cos(joinAngle)
        let tangent = min(15, width * 0.56)
        let tangentX = tangent * sin(joinAngle), tangentY = tangent * cos(joinAngle)
        let shoulder = radius + 10
        let tip = stripRadius(count - 1) + Self.endPadding
        let corner = min(12, width)
        let transform = CGAffineTransform(translationX: RingGeometry.center.x, y: RingGeometry.center.y).rotated(by: anchor)
        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y).applying(transform) }
        path.addCurve(to: point(shoulder, -width), control1: point(joinX + tangentX, -joinY + tangentY),
                      control2: point(shoulder - 10, -width))
        path.addLine(to: point(tip - corner, -width))
        path.addQuadCurve(to: point(tip, -width + corner), control: point(tip, -width))
        path.addLine(to: point(tip, width - corner))
        path.addQuadCurve(to: point(tip - corner, width), control: point(tip, width))
        path.addLine(to: point(shoulder, width))
        path.addCurve(to: point(joinX, joinY), control1: point(shoulder - 10, width),
                      control2: point(joinX + tangentX, joinY - tangentY))
    }

    func childIndex(at point: CGPoint, isEntry: Bool, holdingShortcut: Bool = false, disk: CGPath? = nil) -> Int? {
        guard count > 0 else { return nil }
        let dx = point.x - RingGeometry.center.x, dy = point.y - RingGeometry.center.y
        let radius = hypot(dx, dy)
        if style == .arc {
            return RingGeometry.arcIndex(at: point, count: count, anchor: anchor,
                inner: LauncherArc.inner, outer: holdingShortcut ? .infinity : LauncherArc.outer)
        }
        if radius <= RingGeometry.appOuter { return isEntry ? 0 : nil }
        let longitudinal = dx * cos(anchor) + dy * sin(anchor)
        let lateral = -dx * sin(anchor) + dy * cos(anchor)
        if count == 1 {
            return holdingShortcut && longitudinal > 0 && abs(lateral) <= stripHalfWidth ? 0 : nil
        }
        // Only extend beyond the tip for release-to-select, along the strip's direction.
        let pastTip = holdingShortcut && longitudinal >= stripRadius(count - 1) + Self.endPadding
            && abs(lateral) <= stripHalfWidth
        guard pastTip || (longitudinal > 0 && abs(lateral) <= joinY && (disk ?? diskPath).contains(point)) else { return nil }
        return min(count - 1, max(1, Int(((longitudinal - stripRadius(0)) / Self.stripStep).rounded())))
    }

    func bridgesArc(at point: CGPoint) -> Bool {
        guard style == .arc else { return false }
        let radius = hypot(point.x - RingGeometry.center.x, point.y - RingGeometry.center.y)
        return radius > RingGeometry.appOuter && radius < LauncherArc.inner
            && RingGeometry.arcIndex(at: point, count: count, anchor: anchor) != nil
    }
}

struct LauncherMenuLayout: Identifiable {
    struct ChildID: Hashable {
        let parent: String
        let child: String
    }

    let record: LauncherRecord
    let slot: Int
    let layout: LauncherSecondaryLayout
    let children: ArraySlice<LauncherRecord>
    var id: String { record.id }
    var pageCount: Int { RingGeometry.pageCount(total: record.children.count, size: layout.style.pageSize) }
    var page: Int { children.startIndex / layout.style.pageSize }

    func key(_ child: LauncherRecord) -> ChildID { ChildID(parent: id, child: child.id) }

    static func visible(records: [LauncherRecord?], style: LauncherSecondaryStyle,
                        active: String?, page: (String) -> Int) -> [Self] {
        let ranges = records.map { record in
            record.map { RingGeometry.pageRange(page: page($0.id), total: $0.children.count, size: style.pageSize) } ?? 0..<0
        }
        let widths = style == .strip ? LauncherSecondaryLayout.stripWidths(childCounts: ranges.map(\.count)) : []
        return records.enumerated().compactMap { index, record in
            guard let record, record.item.secondary != nil else { return nil }
            let range = ranges[index]
            guard style == .strip ? !range.isEmpty : record.id == active else { return nil }
            let layout = LauncherSecondaryLayout(style: style, anchor: RingGeometry.angle(index: index, count: records.count),
                                                 count: range.count, stripHalfWidth: style == .strip ? widths[index] : 27)
            return Self(record: record, slot: index, layout: layout, children: record.children[range])
        }
    }
}

extension RingView {
    var actionLauncherApps: [LauncherRecord] { launcherApps.filter { $0.application != nil } }
    var launcherPages: Int { RingGeometry.pageCount(total: actionLauncherApps.count, size: 12) }
    var visibleLauncherApps: [LauncherRecord] {
        let apps = actionLauncherApps
        return Array(apps[RingGeometry.pageRange(page: launcherPage, total: apps.count, size: 12)])
    }
    func launcherPoint(_ index: Int) -> CGPoint {
        RingGeometry.point(angle: RingGeometry.angle(index: index, count: visibleLauncherApps.count), radius: RingGeometry.windowRadius)
    }
    func launcherTarget(at point: CGPoint) -> LauncherRecord? {
        guard showsActionLauncher, let index = RingGeometry.index(at: point, count: visibleLauncherApps.count,
            inner: RingGeometry.windowInner, outer: RingGeometry.windowOuter) else { return nil }
        return visibleLauncherApps[index]
    }
    func updateOption(pressed: Bool, allowEntry: Bool = true) {
        guard pressed != optionPressed else { return }
        optionPressed = pressed
        if !pressed { if showsLauncher && !launcherPinned { endLauncherMode() }; return }
        guard allowEntry, !isEditingName, !showsWindowArc, !isPointerDown, !isContextMenuOpen else { return }
        guard !showsLauncher else { return }
        enterLauncherMode(pinned: false)
    }
    func enterLauncherMode(pinned: Bool) {
        centerClickWork?.cancel(); centerClickWork = nil
        // A keyboard hold is not a pointer interaction: keep the double-tap
        // recognizer independent of keyboard-driven launcher presentation.
        if pinned { onPointerInteraction?() }
        clearSelection()
        resetLauncherStripPages()
        runningAppPage = appPage
        appPage = 0
        launcherPinned = pinned
        showsLauncher = true; launcherPage = 0; hoveredLauncher = nil
        onLauncherModeEntered?()
        refresh()
    }

    /// The ordinary ring opens on the configured favorites group. Keep this
    /// pinned so the invocation shortcut's Option release does not dismiss it.
    func enterDefaultLauncherMode() {
        guard !isEditingName, !isContextMenuOpen, !isPointerDown else { return }
        enterLauncherMode(pinned: true)
    }
    @discardableResult func toggleLauncherFromCenter(at point: CGPoint) -> Bool {
        guard !isEditingName, !isContextMenuOpen, !isPointerDown, !showsWindowArc,
              hypot(point.x - RingGeometry.center.x, point.y - RingGeometry.center.y) < RingGeometry.appInner,
              !pageControlsRect.contains(point) else { return false }
        centerClickWork?.cancel(); centerClickWork = nil
        if showsLauncher { onPointerInteraction?(); endLauncherMode() }
        else { enterLauncherMode(pinned: true) }
        return true
    }
    func scheduleCenterSettings() {
        // Leave the first click available for a double-click before opening settings.
        centerClickWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.window?.isVisible == true, !self.showsActionLauncher,
                  !self.isEditingName, !self.isContextMenuOpen, !self.isPointerDown else { return }
            self.centerClickWork = nil
            self.onSettings?()
        }
        centerClickWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }
    func endLauncherMode() {
        cancelPointerInteraction()
        launcherPinned = false
        showsLauncher = false; hoveredLauncher = nil
        appPage = runningAppPage
        clampAppPage()
        clearSelection()
        refresh()
        onLauncherModeEnded?()
    }
    func changeLauncherPage(_ direction: Int) {
        guard showsLauncher, !isPointerDown else { return }
        launcherPage = RingGeometry.wrapped(launcherPage + direction, count: launcherPages)
        hoveredLauncher = nil
        refresh()
    }
    func activateLauncher(at point: CGPoint) {
        if let record = launcherTarget(at: point) {
            activateLauncherRecord(record)
        } else if CGRect(x: 218, y: 208, width: 44, height: 14).contains(point), launcherPages > 1 {
            changeLauncherPage(point.x < RingGeometry.center.x ? -1 : 1)
        } else if hypot(point.x - RingGeometry.center.x, point.y - RingGeometry.center.y) > RingGeometry.windowOuter {
            onClose?()
        }
    }

    func activateLauncherRecord(_ record: LauncherRecord) {
        guard record.available else { return }
        switch record.item {
        case .destination(.application(let app)): onLaunchApp?(app)
        case .destination(.folder(let folder)): onOpenFolder?(folder)
        case .secondary: break
        }
    }
    func changeContentMode(_ mode: AppContentMode, for app: AppRecord) {
        guard BrowserAdapters.supports(app.bundleID), !showsActionLauncher else { return }
        options.appContentModes[app.bundleID] = mode
        clearSelection()
        select(app)
        onVisibleAppsChanged?()
    }

    func drawLauncher() {
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let center = RingGeometry.center
        let disk = NSBezierPath(ovalIn: NSRect(x: center.x - 118, y: center.y - 118, width: 236, height: 236))
        launcherInnerArtwork?(launcherPages > 1)
        (dark ? NSColor.darkGray : NSColor.lightGray)
            .withAlphaComponent(launcherInnerArtwork == nil ? 0.85 : 0.30).setFill(); disk.fill()
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
        func text(_ value: String, rect: NSRect, size: CGFloat, color: NSColor = .labelColor) {
            (value as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: paragraph])
        }
        let title = visibleLauncherApps.first { $0.id == hoveredLauncher }?.name ?? L10n.text("常用应用", "Favorites")
        if launcherInnerArtwork == nil { RingCenterLabel.draw(title: title,
            detail: actionLauncherApps.isEmpty ? L10n.text("在设置中添加应用", "Add apps in Settings") : (launcherPinned ? L10n.text("双击中心显示运行中应用", "Double-click for running apps") : L10n.text("松开 ⌥ 返回", "Release ⌥")),
            paging: launcherPages > 1) }
        if launcherPages > 1 { RingCenterLabel.page("‹  \(launcherPage + 1)/\(launcherPages)  ›", in: NSRect(x: 215, y: 207, width: 50, height: 15)) }
        for (index, record) in visibleLauncherApps.enumerated() {
            if record.id == hoveredLauncher, let context = NSGraphicsContext.current?.cgContext {
                NSGraphicsContext.saveGraphicsState()
                NSColor.controlAccentColor.withAlphaComponent(dark ? 0.25 : 0.12).setFill()
                context.addPath(RingGeometry.sectorPath(index: index, count: visibleLauncherApps.count,
                    inner: RingGeometry.windowInner, outer: RingGeometry.windowOuter)); context.fillPath()
                NSGraphicsContext.restoreGraphicsState()
            }
            let p = launcherPoint(index)
            record.icon.draw(in: NSRect(x: p.x - 17, y: p.y - 12, width: 34, height: 34),
                from: .zero, operation: .sourceOver, fraction: record.available ? 1 : 0.25)
            text(record.name, rect: NSRect(x: p.x - 32, y: p.y - 29, width: 64, height: 13), size: 9,
                 color: record.available ? .labelColor : .tertiaryLabelColor)
        }
    }
}
