import XCTest
import AppKit
import LumaRingCore
@testable import LumaRing

final class LauncherTests: XCTestCase {
    private final class ExitedApplication: NSRunningApplication, @unchecked Sendable {
        override var isTerminated: Bool { true }
        override var bundleIdentifier: String? { nil }
    }

    private let icon = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)!
    private var primary: AppRecord { AppRecord(pid: 100, bundleID: "test.primary", name: "Primary", icon: icon) }
    private func records(_ count: Int = 3) -> [LauncherRecord] {
        (0..<count).map { LauncherRecord(app: LauncherApp(bundleID: "test.launch.\($0)", name: "App \($0)", path: "/missing/\($0).app"), icon: icon, available: true) }
    }
    @MainActor private func view(_ count: Int = 3) -> RingView {
        let view = RingView(frame: NSRect(x: 0, y: 0, width: 480, height: 480))
        view.reset(apps: [primary], options: Options())
        view.launcherApps = records(count)
        return view
    }
    private func point(_ index: Int, count: Int) -> CGPoint {
        RingGeometry.point(angle: RingGeometry.angle(index: index, count: count), radius: RingGeometry.appRadius)
    }

    func testLauncherDropUsesTheHoveredSlotInTheSourceRing() throws {
        let apps = records().compactMap(\.application)
        let original = apps.map(LauncherDestination.application)
        var primary = original.map(LauncherItem.destination)
        let source = LauncherReorder.Item(id: apps[0].id, parent: nil)
        let destination = LauncherReorder.Item(id: apps[2].id, parent: nil)
        let child = LauncherReorder.Item(id: destination.id, parent: "ring:tools")
        let slots = [
            LauncherReorder.Slot(item: source, frame: CGRect(x: 0, y: 0, width: 30, height: 30)),
            .init(item: destination, frame: CGRect(x: 40, y: 0, width: 30, height: 30)),
            .init(item: child, frame: CGRect(x: 68, y: 0, width: 30, height: 30)),
            .init(item: destination, frame: CGRect(x: 150, y: 0, width: 120, height: 32))
        ]

        XCTAssertNil(LauncherReorder.dropTarget(at: CGPoint(x: 15, y: 15), from: source, in: slots))
        XCTAssertNil(LauncherReorder.dropTarget(at: CGPoint(x: 69.5, y: 15), from: source, in: slots))
        XCTAssertNil(LauncherReorder.dropTarget(at: CGPoint(x: 100, y: 50), from: source, in: slots))
        let listDrop = LauncherReorder.dropTarget(at: CGPoint(x: 200, y: 15), from: source, in: slots)
        XCTAssertEqual(listDrop, .init(item: destination, circular: false))

        let target = try XCTUnwrap(LauncherReorder.dropTarget(at: CGPoint(x: 56, y: 15), from: source, in: slots)?.item)
        let preview = LauncherReorder.previewOrder(primary, from: source.id, to: target.id)
        XCTAssertEqual(primary.map(\.id), apps.map(\.id))
        XCTAssertEqual(preview.map(\.id), [apps[1].id, destination.id, source.id])
        XCTAssertEqual(LauncherReorder.moveItem(source.id, to: target.id, in: &primary), 2)
        XCTAssertEqual(primary, preview)
    }

    func testReorderPreviewMovesASecondaryGroupWithoutSavingUntilDrop() {
        let children = records(3)
        let group = LauncherRecord(secondary: .init(name: "Tools"), children: children)
        let apps = records(4)
        var saved = [apps[0], group, apps[1], apps[2], apps[3]]
        let original = saved.map(\.id)
        let preview = LauncherReorder.previewOrder(saved, from: group.id, to: apps[3].id)

        XCTAssertEqual(preview.map(\.id), [apps[0].id, apps[1].id, apps[2].id, apps[3].id, group.id])
        XCTAssertEqual(preview.last?.children.map(\.id), children.map(\.id))
        XCTAssertEqual(saved.map(\.id), original)

        XCTAssertEqual(LauncherReorder.moveItem(group.id, to: apps[3].id, in: &saved), 4)
        XCTAssertEqual(saved.map(\.id), preview.map(\.id))
        XCTAssertEqual(LauncherReorder.previewOrder(saved, from: "off-page", to: apps[1].id).map(\.id), saved.map(\.id))
    }

    func testCircularDropAcrossTheTopMovesOnlyItemsOnTheShortArc() throws {
        let apps = records(7)
        let items = apps.map { LauncherReorder.Item(id: $0.id, parent: nil) }
        for (source, destination, expected) in [
            (0, 1, [1, 0, 2, 3, 4, 5, 6]),
            (0, 6, [6, 1, 2, 3, 4, 5, 0]),
            (6, 0, [6, 1, 2, 3, 4, 5, 0]),
            (0, 5, [6, 1, 2, 3, 4, 0, 5]),
            (0, 2, [1, 2, 0, 3, 4, 5, 6])
        ] {
            let slot = LauncherReorder.Slot(item: items[destination], frame: CGRect(x: 0, y: 0, width: 30, height: 30),
                circular: true)
            let drop = try XCTUnwrap(LauncherReorder.dropTarget(at: CGPoint(x: 15, y: 15), from: items[source], in: [slot]))
            let preview = LauncherReorder.previewOrder(apps, from: items[source].id, to: drop.item.id, circular: drop.circular)
            XCTAssertEqual(preview.map(\.id), expected.map { apps[$0].id })
        }
    }

    func testCircularPreviewAndDropUseTheSamePageWithoutChangingOtherPages() {
        let apps = records(15)
        let page = 7..<14
        let preview = LauncherReorder.previewOrder(Array(apps[page]), from: apps[7].id, to: apps[13].id, circular: true)
        var saved = apps
        XCTAssertEqual(LauncherReorder.moveItem(apps[7].id, to: apps[13].id, onRing: page, in: &saved), 13)
        XCTAssertEqual(saved[page].map(\.id), preview.map(\.id))
        XCTAssertEqual(saved[..<page.lowerBound].map(\.id), apps[..<page.lowerBound].map(\.id))
        XCTAssertEqual(saved[page.upperBound...].map(\.id), apps[page.upperBound...].map(\.id))
    }

    func testCircularGapUsesTheShortArcAndKeepsBothNeighbors() throws {
        let apps = records(7)
        let items = apps.map { LauncherReorder.Item(id: $0.id, parent: nil) }
        let track = LauncherReorder.Track(items: items)
        let angle = (RingGeometry.angle(index: 5, count: items.count) + RingGeometry.angle(index: 6, count: items.count)) / 2
        let gap = RingGeometry.point(angle: angle, radius: RingGeometry.appRadius)
        let drop = try XCTUnwrap(track.dropTarget(at: gap, from: items[0]))
        let preview = LauncherReorder.previewOrder(apps, from: items[0].id, to: drop.item.id, circular: drop.circular)
        XCTAssertEqual(preview.map(\.id), [6, 1, 2, 3, 4, 5, 0].map { apps[$0].id })
    }

    func testAcrossTopAnimationUsesTheAdjacentAngle() {
        let top = RingGeometry.angle(index: 0, count: 7)
        let last = RingGeometry.angle(index: 6, count: 7)
        let step = 2 * Double.pi / 7
        XCTAssertEqual(LauncherReorder.nearestAngle(top, to: last) - last, -step, accuracy: 0.000_001)
        XCTAssertEqual(LauncherReorder.nearestAngle(last, to: top) - top, step, accuracy: 0.000_001)
    }

    func testLauncherColumnsTradeWidthAndClampAtBothEnds() {
        let initial = LauncherEditorColumns(width: 740, preferredPanelWidth: 320)
        let wider = LauncherEditorColumns(width: 740, preferredPanelWidth: 320, translation: 30)
        XCTAssertEqual(wider.previewWidth, initial.previewWidth + 30)
        XCTAssertEqual(wider.panelWidth, initial.panelWidth - 30)
        XCTAssertGreaterThan(wider.previewHeight, initial.previewHeight)

        let committed = LauncherEditorColumns(width: 740, preferredPanelWidth: Double(wider.panelWidth))
        XCTAssertEqual(committed.previewWidth, wider.previewWidth)
        let leftLimit = LauncherEditorColumns(width: 740, preferredPanelWidth: 320, translation: -1_000)
        let rightLimit = LauncherEditorColumns(width: 740, preferredPanelWidth: 320, translation: 1_000)
        XCTAssertEqual(leftLimit.previewWidth, LauncherEditorColumns.minimumPreviewWidth)
        XCTAssertEqual(rightLimit.panelWidth, LauncherEditorColumns.minimumPanelWidth)

        let stacked = LauncherEditorColumns(width: 520, preferredPanelWidth: 320)
        XCTAssertFalse(stacked.isSplit)
        XCTAssertEqual(stacked.previewWidth, 520)
        XCTAssertEqual(stacked.panelWidth, 520)
    }

    func testPreviewFitsTheVisibleMenuAndTileBounds() {
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 390)
        let disk = RingGeometry.diskPath.boundingBoxOfPath
        for style in [LauncherSecondaryStyle.arc, .strip] {
            let menu = LauncherSecondaryLayout(style: style, anchor: 0, count: style.pageSize)
            let bounds = menu.surfaceBounds
            let tile = CGRect(x: bounds.maxX - 30, y: bounds.midY, width: 36, height: 24)
            let transform = LauncherPreviewFit.transform(surfaceBounds: bounds, tiles: [tile], in: viewport.size)
            XCTAssertTrue(viewport.contains(disk.applying(transform)))
            XCTAssertTrue(viewport.contains(tile.applying(transform)))
            let fitted = bounds.union(tile).applying(transform)
            XCTAssertEqual(fitted.midX, viewport.midX, accuracy: 0.001)
            XCTAssertEqual(fitted.midY, viewport.midY, accuracy: 0.001)
            XCTAssertEqual(max(fitted.width / (viewport.width - 12), fitted.height / (viewport.height - 12)), 1, accuracy: 0.001)
        }
    }

    func testMainRingGapInsertsBetweenItsNeighborsFromEitherDirection() throws {
        let apps = records(5)
        let items = apps.map { LauncherReorder.Item(id: $0.id, parent: nil) }
        let toEditor = CGAffineTransform(a: 2, b: 0, c: 0, d: -2, tx: 37, ty: 540)
        let preview = LauncherReorder.Preview(toRingCoordinates: toEditor.inverted(), tracks: [.init(items: items)])
        let slots = items.enumerated().map { index, item in
            let center = point(index, count: items.count).applying(toEditor)
            return LauncherReorder.Slot(item: item, frame: CGRect(x: center.x - 38, y: center.y - 38, width: 76, height: 76),
                circular: true)
        }
        let angle = (RingGeometry.angle(index: 1, count: items.count) + RingGeometry.angle(index: 2, count: items.count)) / 2
        let gap = RingGeometry.point(angle: angle, radius: RingGeometry.appRadius).applying(toEditor)

        XCTAssertFalse(slots.contains { $0.frame.contains(gap) })
        for (source, destination, expected) in [(0, 1, [1, 0, 2, 3, 4]), (4, 2, [0, 1, 4, 2, 3])] {
            let target = try XCTUnwrap(LauncherReorder.dropTarget(at: gap, from: items[source], in: slots, preview: preview))
            XCTAssertEqual(target, .init(item: items[destination], circular: true))
            let projected = LauncherReorder.previewOrder(apps, from: items[source].id, to: target.item.id, circular: target.circular)
            XCTAssertEqual(projected.map(\.id), expected.map { apps[$0].id })
            var saved = apps
            XCTAssertEqual(LauncherReorder.moveItem(items[source].id, to: target.item.id, onRing: saved.indices, in: &saved), destination)
            XCTAssertEqual(saved.map(\.id), projected.map(\.id))
        }
        XCTAssertNil(LauncherReorder.dropTarget(at: gap, from: items[1], in: slots, preview: preview))
        let onIcon = point(2, count: items.count).applying(toEditor)
        XCTAssertEqual(LauncherReorder.dropTarget(at: onIcon, from: items[0], in: slots, preview: preview),
            .init(item: items[2], circular: true))
        let foreignSlot = LauncherReorder.Slot(item: .init(id: items[2].id, parent: "group"),
            frame: CGRect(x: gap.x - 10, y: gap.y - 10, width: 20, height: 20))
        XCTAssertNil(LauncherReorder.dropTarget(at: gap, from: items[0], in: slots + [foreignSlot], preview: preview))
    }

    func testMainRingGapWrapsAtTheTopAndRejectsPointsOutsideTheRing() {
        let items = records(5).map { LauncherReorder.Item(id: $0.id, parent: nil) }
        let track = LauncherReorder.Track(items: items)
        let angle = .pi / 2 + .pi / Double(items.count)
        let gap = RingGeometry.point(angle: angle, radius: RingGeometry.appRadius)
        XCTAssertEqual(track.dropTarget(at: gap, from: items[1]), .init(item: items[0], circular: true))
        XCTAssertEqual(track.dropTarget(at: gap, from: items[3]), .init(item: items[4], circular: true))
        XCTAssertNil(track.dropTarget(at: RingGeometry.center, from: items[2]))
        XCTAssertNil(track.dropTarget(at: RingGeometry.point(angle: angle, radius: RingGeometry.appOuter + 1), from: items[2]))
    }

    func testSecondaryMenuGapsStayWithinTheirOwnTrack() {
        let items = records(3).map { LauncherReorder.Item(id: $0.id, parent: "tools") }
        for style in [LauncherSecondaryStyle.arc, .strip] {
            let anchor = -.pi * 0.95
            let layout = LauncherSecondaryLayout(style: style, anchor: anchor, count: items.count)
            let track = LauncherReorder.Track(items: items, layout: layout)
            let gap = style == .arc
                ? RingGeometry.point(angle: anchor + RingGeometry.arcStep / 2, radius: LauncherArc.radius)
                : RingGeometry.point(angle: anchor, radius: RingGeometry.appRadius + LauncherSecondaryLayout.stripStep / 2)
            XCTAssertEqual(track.dropTarget(at: gap, from: items[2]), .init(item: items[1], circular: false))
            XCTAssertNil(track.dropTarget(at: gap, from: .init(id: items[2].id, parent: nil)))
            XCTAssertNil(track.dropTarget(at: layout.point(items.count), from: items[0]))
        }
    }

    func testChildDragTargetsStayInTheirOwnMenu() {
        let main = LauncherReorder.Item(id: "app", parent: nil)
        let first = LauncherReorder.Item(id: "app", parent: "group:first")
        let next = LauncherReorder.Item(id: "another-app", parent: first.parent)
        let second = LauncherReorder.Item(id: "another-app", parent: "group:second")

        XCTAssertTrue(next.accepts(first))
        XCTAssertFalse(first.accepts(first))
        XCTAssertFalse(main.accepts(first))
        XCTAssertFalse(first.accepts(main))
        XCTAssertFalse(second.accepts(first))
    }

    func testChildDropUsesItsOwnMenuSlotsInBothStyles() {
        let children = records()
        let parent = "ring:tools"
        let source = LauncherReorder.Item(id: children[0].id, parent: parent)
        let expected = LauncherReorder.Item(id: children[2].id, parent: parent)
        for style in [LauncherSecondaryStyle.arc, .strip] {
            let layout = LauncherSecondaryLayout(style: style, anchor: 0, count: children.count)
            let slots = children.enumerated().map { index, child in
                let point = layout.point(index)
                return LauncherReorder.Slot(item: .init(id: child.id, parent: parent),
                    frame: CGRect(x: point.x - 17, y: point.y - 17, width: 34, height: 34))
            }
            XCTAssertEqual(LauncherReorder.dropTarget(at: layout.point(2), from: source, in: slots),
                .init(item: expected, circular: false))
            XCTAssertNil(LauncherReorder.dropTarget(at: layout.point(2), from: .init(id: source.id, parent: nil), in: slots))
            XCTAssertNil(LauncherReorder.dropTarget(at: RingGeometry.center, from: source, in: slots))
        }
    }

    func testStripIconAndGroupHandleResolveDifferentDragTargets() {
        let parent = "ring:code"
        let children = records(3).map { LauncherReorder.Item(id: $0.id, parent: parent) }
        let group = LauncherReorder.Item(id: parent, parent: nil)
        let frame = CGRect(x: 40, y: 40, width: 34, height: 34)
        let icon = CGPoint(x: frame.midX, y: frame.midY)
        let slots = [
            LauncherReorder.Slot(item: children[1], frame: frame, groupDropID: parent),
            LauncherReorder.Slot(item: group, frame: CGRect(x: 0, y: 40, width: 24, height: 34), circular: true)
        ]

        XCTAssertEqual(LauncherReorder.dropTarget(at: icon, from: children[0], in: slots),
                       .init(item: children[1], circular: false))
        XCTAssertEqual(LauncherReorder.dropTarget(at: icon, from: .init(id: "other", parent: nil), in: slots),
                       .init(item: group, circular: true))
        XCTAssertNil(LauncherReorder.dropTarget(at: icon, from: group, in: slots))
    }

    @MainActor func testStripPreviewKeepsVisibleChildrenDraggableAndAddsSeparateInwardHandle() throws {
        let artwork = CGRect(x: 6, y: 10, width: 50, height: 48)
        let artworkCorner: CGFloat = 12
        let paddedIcon = NSImage(size: CGSize(width: 64, height: 64), flipped: false) { bounds in
            NSColor.black.withAlphaComponent(0.15).setFill()
            NSBezierPath(rect: bounds).fill()
            NSColor.black.setFill()
            NSBezierPath(roundedRect: artwork, xRadius: artworkCorner, yRadius: artworkCorner).fill()
            return true
        }
        let children = records(3).map { LauncherRecord(item: $0.item, icon: paddedIcon, available: true) }
        let group = LauncherRecord(secondary: .init(name: "Code"), children: children)
        let apps = records(7)
        for slot in 0...apps.count {
            var mainRing = apps
            mainRing.insert(group, at: slot)
            let menus = LauncherMenuLayout.visible(records: mainRing.map(Optional.some), style: .strip, active: nil) { _ in 0 }
            for showsNames in [false, true] {
                let preview = LauncherPreview(records: mainRing, ringID: nil, childPage: 0, style: .strip,
                                              showsItemNames: showsNames, reorder: nil, selectRing: nil)
                let tiles = preview.tiles(for: mainRing, menus: menus, showsGroupHandles: true)
                let handle = try XCTUnwrap(tiles.first { $0.id.id == group.id && $0.id.parent == nil })
                let childTiles = tiles.filter { $0.id.parent == group.id }
                let handleSide = try XCTUnwrap(handle.handleSide)
                XCTAssertEqual(childTiles.map(\.id.id), children.map(\.id))
                XCTAssertEqual(tiles.filter { $0.id.parent == nil && $0.handleSide == nil }.map(\.id.id), apps.map(\.id))

                let firstChild = try XCTUnwrap(childTiles.first)
                let iconFrame = firstChild.layout.iconRect(at: firstChild.point)
                let iconScale = iconFrame.width / 64
                let visibleIcon = artwork.applying(CGAffineTransform(scaleX: iconScale, y: iconScale))
                    .offsetBy(dx: iconFrame.minX, dy: iconFrame.minY)
                let handleFrame = CGRect(x: handle.point.x - handleSide / 2, y: handle.point.y - handleSide / 2,
                                         width: handleSide, height: handleSide)
                let handleCorner = min(5, handleSide / 2)
                let handleCore = handleFrame.insetBy(dx: handleCorner, dy: handleCorner)
                let iconCorner = artworkCorner * iconScale
                let iconCore = visibleIcon.insetBy(dx: iconCorner, dy: iconCorner)
                let labelFrame = firstChild.layout.labelRect(at: firstChild.point)
                func distance(to frame: CGRect) -> CGFloat {
                    let horizontal = max(0, abs(frame.midX - handleCore.midX) - (frame.width + handleCore.width) / 2)
                    let vertical = max(0, abs(frame.midY - handleCore.midY) - (frame.height + handleCore.height) / 2)
                    return hypot(horizontal, vertical)
                }
                let iconGap = distance(to: iconCore) - iconCorner - handleCorner
                let labelGap = showsNames ? distance(to: labelFrame) - handleCorner : .infinity
                XCTAssertEqual(min(iconGap, labelGap), 2, accuracy: 0.35, "slot \(slot), names: \(showsNames)")
                XCTAssertEqual(handle.size.width, handleSide)
                XCTAssertLessThan(hypot(handle.point.x - RingGeometry.center.x, handle.point.y - RingGeometry.center.y),
                                  RingGeometry.appRadius)
                let handleIndex = try XCTUnwrap(tiles.firstIndex { $0.id == handle.id })
                let childIndex = try XCTUnwrap(tiles.firstIndex { $0.id == firstChild.id })
                XCTAssertGreaterThan(handleIndex, childIndex)
                XCTAssertFalse(preview.tiles(for: mainRing, menus: menus, showsGroupHandles: false)
                    .contains { $0.handleSide != nil })
            }
        }
    }

    func testStripGapMovesGroupButKeepsChildReorderingWithinItsOwnTrack() {
        let tools = records(3).map { LauncherReorder.Item(id: $0.id, parent: "tools") }
        let code = records(3).map { LauncherReorder.Item(id: $0.id, parent: "code") }
        let toolsLayout = LauncherSecondaryLayout(style: .strip, anchor: 0, count: tools.count)
        let codeLayout = LauncherSecondaryLayout(style: .strip, anchor: .pi / 2, count: code.count)
        let preview = LauncherReorder.Preview(toRingCoordinates: .identity, tracks: [
            LauncherReorder.Track(items: tools, layout: toolsLayout),
            LauncherReorder.Track(items: code, layout: codeLayout)
        ])
        let gap = RingGeometry.point(angle: codeLayout.anchor,
                                     radius: RingGeometry.appRadius + LauncherSecondaryLayout.stripStep / 2)

        XCTAssertEqual(preview.dropTarget(at: gap, from: .init(id: "tools", parent: nil)),
                       .init(item: .init(id: "code", parent: nil), circular: true))
        XCTAssertNil(preview.dropTarget(at: gap, from: tools[0]))
        let toolsGap = RingGeometry.point(angle: toolsLayout.anchor,
                                          radius: RingGeometry.appRadius + LauncherSecondaryLayout.stripStep * 1.5)
        XCTAssertEqual(preview.dropTarget(at: toolsGap, from: tools[0])?.item, tools[1])
    }

    func testSecondaryTileIconsMatchThePrimaryRingInBothStyles() {
        for count in RingGeometry.appPageSizeRange {
            for showsName in [false, true] {
                let spacing = LauncherTileLayout.primarySpacing(count: count)
                let primary = LauncherTileLayout(primarySpacing: spacing, showsName: showsName)
                for style in [LauncherSecondaryStyle.arc, .strip] {
                    let menu = LauncherSecondaryLayout(style: style, anchor: 0, count: style.pageSize, stripHalfWidth: 9)
                    for index in 0..<menu.count {
                        let child = primary.secondary(spacing: menu.tileSpacing(at: index, mainSpacing: spacing))
                        XCTAssertEqual(child.iconRect(at: menu.point(index)).size, primary.iconRect(at: .zero).size)
                        XCTAssertEqual(child.labelHeight > 0, showsName)
                    }
                }
            }
        }
    }

    func testLegacyFavoritesMigrateInOrderAndAnEmptyNewListTakesPrecedence() throws {
        struct LegacyOptions: Encodable { let launcherApps: [LauncherApp]; let launcherItems: [LauncherItem]? }
        let apps = records().compactMap(\.application).reversed()
        let legacyApps = Array(apps) + apps.prefix(1)
        let old = try JSONEncoder().encode(LegacyOptions(launcherApps: legacyApps, launcherItems: nil))
        let migrated = try JSONDecoder().decode(Options.self, from: old)
        XCTAssertEqual(migrated.launcherApps, Array(apps))

        let folder = try XCTUnwrap(LauncherFolder(FileManager.default.temporaryDirectory))
        var options = migrated
        options.launcherItems.insert(.destination(.folder(folder)), at: 1)
        let firstApp = try XCTUnwrap(apps.first)
        options.launcherItems.insert(.secondary(.init(name: "Tools", destinations: [.folder(folder), .application(firstApp)])), at: 2)
        let saved = try JSONEncoder().encode(options)
        XCTAssertEqual(try JSONDecoder().decode(Options.self, from: saved).launcherItems, options.launcherItems)

        let cleared = try JSONEncoder().encode(LegacyOptions(launcherApps: legacyApps, launcherItems: []))
        XCTAssertTrue(try JSONDecoder().decode(Options.self, from: cleared).launcherItems.isEmpty)
    }

    @MainActor func testSecondaryRingKeepsHoverAcrossGapAndRequiresSameChildOnClick() async throws {
        let view = view(1)
        let folder = try XCTUnwrap(LauncherFolder(FileManager.default.temporaryDirectory))
        let folderItem = LauncherItem.destination(.folder(folder))
        let folderRecord = LauncherRecord(item: folderItem, icon: icon, available: true)
        let child = records(1)[0]
        let group = LauncherSecondaryRing(name: "Tools", destinations: [.application(try XCTUnwrap(child.application)), .folder(folder)])
        view.launcherApps.insert(LauncherRecord(secondary: group, children: [child, folderRecord]), at: 0)
        view.launcherApps.append(folderRecord)
        view.enterDefaultLauncherMode()
        let anchor = RingGeometry.angle(index: 0, count: 3)
        let first = LauncherArc.point(index: 0, count: 2, anchor: anchor)
        let second = LauncherArc.point(index: 1, count: 2, anchor: anchor)
        let gap = RingGeometry.point(angle: anchor, radius: LauncherArc.inner - 5)
        var opened: [String] = []
        view.onLaunchApp = { opened.append($0.id) }
        view.onOpenFolder = { opened.append($0.path) }

        view.updateHover(at: point(0, count: 3)); view.updateHover(at: gap)
        view.beginPointer(at: first); view.endPointer(at: second)
        XCTAssertTrue(opened.isEmpty)
        view.beginPointer(at: second); view.endPointer(at: second)
        XCTAssertEqual(opened, [folder.path])
        view.beginPointer(at: point(2, count: 3)); view.endPointer(at: point(2, count: 3))
        XCTAssertEqual(opened, [folder.path, folder.path])

        view.selectingWithShortcut = true
        view.updateHover(at: point(0, count: 3)); view.updateHover(at: gap)
        view.updateHover(at: first)
        view.activateHovered()
        XCTAssertEqual(opened.last, child.id)
        view.selectingWithShortcut = false
        view.updateHover(at: point(0, count: 3))
        view.navigate(.toggleSecondary)
        view.navigate(.step(1))
        view.navigate(.activate)
        XCTAssertEqual(opened.last, folder.path)
        XCTAssertTrue(view.toggleLauncherFromCenter(at: RingGeometry.center))
        view.activate(at: second)
        XCTAssertEqual(opened, [folder.path, folder.path, child.id, folder.path])
    }

    func testStripUsesTheEntrySlotAndKeepsOneContinuousContour() {
        for index in 0..<24 {
            let anchor = RingGeometry.angle(index: index, count: 24)
            let single = LauncherSecondaryLayout(style: .strip, anchor: anchor, count: 1)
            XCTAssertEqual(single.diskPath, RingGeometry.diskPath)
            XCTAssertEqual(single.point(0), point(index, count: 24))
            XCTAssertEqual(single.childIndex(at: single.point(0), isEntry: true), 0)
            XCTAssertNil(single.childIndex(at: single.point(0), isEntry: false))
            for count in 2...LauncherSecondaryStyle.strip.pageSize {
                let strip = LauncherSecondaryLayout(style: .strip, anchor: anchor, count: count)
                XCTAssertNil(strip.arcPath)
                XCTAssertTrue(CGRect(x: 0, y: 0, width: 480, height: 480).contains(strip.surfaceBounds))
                for step in 0...96 {
                    let radius = RingGeometry.appRadius + Double(step)
                    guard radius <= RingGeometry.appRadius + Double(count - 1) * LauncherSecondaryLayout.stripStep else { break }
                    let position = RingGeometry.point(angle: anchor, radius: radius)
                    XCTAssertTrue(strip.diskPath.contains(position))
                    XCTAssertNotNil(strip.childIndex(at: position, isEntry: true))
                }
                for child in 0..<count {
                    XCTAssertEqual(strip.childIndex(at: strip.point(child), isEntry: child == 0), child)
                }
                let beside = RingGeometry.point(angle: anchor + .pi / 3, radius: 145)
                XCTAssertFalse(strip.diskPath.contains(beside))
                XCTAssertNil(strip.childIndex(at: beside, isEntry: false))
            }
        }
    }

    func testStripContourLeavesPaddingAroundHoveredIconsAtEachAngle() {
        let slotCount = 8
        let spacing = LauncherTileLayout.primarySpacing(count: slotCount)
        for childCount in 2...LauncherSecondaryStyle.strip.pageSize {
            let children = records(childCount)
            for slot in 0..<slotCount {
                let entries = (0..<slotCount).map { index -> LauncherRecord? in
                    guard index == slot || index == (slot + 1) % slotCount else { return nil }
                    return LauncherRecord(secondary: .init(name: "Group \(index)"), children: children)
                }
                let menus = LauncherMenuLayout.visible(records: entries, style: .strip, active: nil) { _ in 0 }
                let disk = LauncherSecondaryLayout.diskPath(with: menus.map(\.layout))
                for menu in menus {
                    let strip = menu.layout.diskPath
                    for showsName in [false, true] {
                        let primary = LauncherTileLayout(primarySpacing: spacing, showsName: showsName)
                        for index in 1..<menu.layout.count {
                            let tile = primary.secondary(spacing: menu.layout.tileSpacing(at: index, mainSpacing: spacing))
                            let highlight = menu.layout.highlightPath(for: tile, at: index, padding: showsName ? 2 : 3)
                            XCTAssertTrue(highlight.subtracting(strip).isEmpty,
                                          "Single strip at slot \(menu.slot), child \(index), names \(showsName)")
                            XCTAssertTrue(highlight.subtracting(disk).isEmpty,
                                          "Slot \(menu.slot), child \(index), names \(showsName)")
                        }
                    }
                }
            }
        }
    }

    func testStripShoulderDoesNotNarrowBeforeTheStraightEdge() {
        let strip = LauncherSecondaryLayout(style: .strip, anchor: 0, count: 2)
        let disk = strip.diskPath
        let straightEdge = strip.stripHalfWidth - 0.1
        for distance in stride(from: RingGeometry.appOuter - 5, through: RingGeometry.appOuter + 10, by: 0.5) {
            for side in [-1.0, 1.0] {
                let point = CGPoint(x: RingGeometry.center.x + distance, y: RingGeometry.center.y + side * straightEdge)
                XCTAssertTrue(disk.contains(point), "Shoulder at \(distance), side \(side)")
            }
        }
    }

    @MainActor func testStripActivatesTheChildInTheEntryAndKeepsInputAcrossPages() async {
        let view = view(2)
        view.options.launcherSecondaryStyle = .strip
        let children = records(5)
        let group = LauncherSecondaryRing(name: "Tools", destinations: children.compactMap(\.application).map(LauncherDestination.application))
        view.launcherApps.insert(LauncherRecord(secondary: group, children: children), at: 0)
        view.enterDefaultLauncherMode()
        let layout = LauncherSecondaryLayout(style: .strip, anchor: RingGeometry.angle(index: 0, count: 3), count: 3)
        let entry = layout.point(0), outer = layout.point(1)
        var opened: [String] = []
        view.onLaunchApp = { opened.append($0.id) }
        // Both positions must be clickable immediately, with no mouse-move event.
        view.beginPointer(at: entry); view.endPointer(at: outer)
        XCTAssertTrue(opened.isEmpty)
        view.beginPointer(at: entry); view.endPointer(at: entry)
        view.beginPointer(at: outer); view.endPointer(at: outer)
        XCTAssertEqual(opened, children.prefix(2).map(\.id))

        view.updateHover(at: outer)
        let nextPage = CGPoint(x: view.pageControlsRect.maxX - 2, y: view.pageControlsRect.midY)
        view.updateHover(at: RingGeometry.center)
        view.updateHover(at: nextPage)
        view.beginPointer(at: nextPage); view.endPointer(at: nextPage)
        view.beginPointer(at: entry); view.endPointer(at: entry)
        XCTAssertEqual(opened.last, children[3].id)
        view.updateHover(at: outer)
        view.navigate(.step(1))
        view.navigate(.activate)
        XCTAssertEqual(opened.last, children[0].id)

        view.selectingWithShortcut = true
        view.updateHover(at: point(2, count: 3))
        view.updateHover(at: layout.point(2))
        view.activateHovered()
        XCTAssertEqual(opened.last, children[2].id)
    }

    @MainActor func testAdjacentStripsOpenTogetherAndKeepSharedItemsDistinct() async throws {
        let view = view(2)
        view.options.launcherSecondaryStyle = .strip
        let shared = records(1)[0]
        let first = LauncherSecondaryRing(name: "First")
        let second = LauncherSecondaryRing(name: "Second")
        let singleton = LauncherSecondaryRing(name: "Single")
        view.launcherApps.insert(contentsOf: [
            LauncherRecord(secondary: first, children: [records(2)[1], shared]),
            LauncherRecord(secondary: second, children: [records(3)[2], shared]),
            LauncherRecord(secondary: singleton, children: [shared])
        ], at: 0)
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 480),
                             styleMask: .borderless, backing: .buffered, defer: true)
        panel.contentView = view
        view.enterDefaultLauncherMode()
        let firstTip = RingGeometry.point(angle: RingGeometry.angle(index: 0, count: 5), radius: 158)
        let secondTip = RingGeometry.point(angle: RingGeometry.angle(index: 1, count: 5), radius: 158)
        let oneChildTip = RingGeometry.point(angle: RingGeometry.angle(index: 2, count: 5), radius: 158)
        let bounds = view.occupiedScreenFrame
        for tip in [firstTip, secondTip] {
            XCTAssertTrue(bounds.contains(panel.convertPoint(toScreen: tip)))
        }
        var opened: [String] = []
        view.onLaunchApp = { opened.append($0.id) }
        let children = try XCTUnwrap(view.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertEqual(children.filter { $0.accessibilityLabel() == shared.name }.count, 4)
        view.beginPointer(at: firstTip); view.endPointer(at: secondTip)
        XCTAssertTrue(opened.isEmpty)
        view.clearSelection()
        view.beginPointer(at: firstTip); view.endPointer(at: firstTip)
        view.updateHover(at: point(3, count: 5))
        view.beginPointer(at: secondTip); view.endPointer(at: secondTip)
        view.beginPointer(at: oneChildTip); view.endPointer(at: oneChildTip)
        view.beginPointer(at: point(2, count: 5)); view.endPointer(at: point(2, count: 5))
        XCTAssertEqual(opened, Array(repeating: shared.id, count: 3))
        XCTAssertEqual(view.occupiedScreenFrame, bounds)
    }
    @MainActor func testInvocationOptionRequiresReleaseAndFreshPress() async {
        let view = view()
        view.optionPressed = true // Held by Option + Tab when the panel opens.
        view.updateOption(pressed: true)
        XCTAssertFalse(view.showsLauncher)
        view.updateOption(pressed: false)
        view.updateOption(pressed: true)
        XCTAssertTrue(view.showsLauncher)
        view.updateOption(pressed: false)
        XCTAssertFalse(view.showsLauncher)
    }
    @MainActor func testVisibleSecondaryRingAndDragAndMenuBlockEntry() async {
        let view = view()
        view.select(primary)
        let windows = (0..<2).map { WindowRecord(id: "w\($0)", pid: 100, title: "Window", minimized: false, fullscreen: false, frame: .zero, element: AXUIElementCreateApplication(100)) }
        view.setWindows(.ready(windows), for: 100)
        view.updateOption(pressed: true)
        XCTAssertTrue(view.showsWindowArc); XCTAssertFalse(view.showsLauncher)
        view.clearSelection()
        view.updateOption(pressed: true)
        XCTAssertFalse(view.showsLauncher, "Closing an arc while held does not synthesize a new press")
        view.updateOption(pressed: false)
        view.beginPointer(at: RingGeometry.point(angle: .pi / 2, radius: 88))
        view.updateOption(pressed: true)
        XCTAssertFalse(view.showsLauncher)
        view.cancelPointerInteraction(); view.updateOption(pressed: false)
        view.isContextMenuOpen = true; view.updateOption(pressed: true)
        XCTAssertFalse(view.showsLauncher)
    }
    @MainActor func testSwitchingGroupsClearsRunningSelectionAndIgnoresItsLateResult() async {
        let view = view()
        view.select(primary)
        view.onSelectApp = { _ in XCTFail("A stopped favorite has no window query") }
        view.updateOption(pressed: true)
        view.setWindows(.ready([]), for: 100)
        XCTAssertNil(view.selectedApp); XCTAssertTrue(view.showsLauncher)
        view.updateHover(at: point(0, count: 3)); view.select(primary)
        XCTAssertNil(view.selectedApp); XCTAssertTrue(view.showsLauncher)
    }
    @MainActor func testFavoriteClickRequiresSameAppAndHoldingOptionThroughRelease() async {
        let view = view()
        var launched: [String] = []
        view.onLaunchApp = { launched.append($0.id) }
        view.updateOption(pressed: true)
        view.beginPointer(at: point(0, count: 3)); view.endPointer(at: point(1, count: 3))
        XCTAssertTrue(launched.isEmpty)
        view.beginPointer(at: point(0, count: 3)); view.updateOption(pressed: false)
        view.endPointer(at: RingGeometry.point(angle: .pi / 2, radius: 88))
        XCTAssertTrue(launched.isEmpty)
        view.updateOption(pressed: true)
        view.beginPointer(at: point(1, count: 3)); view.endPointer(at: point(1, count: 3))
        XCTAssertEqual(launched, ["test.launch.1"])
    }
    @MainActor func testPagingEmptyMissingAppsAndReset() async {
        let view = view(25)
        view.options.appPageSize = 8
        view.options.launcherPageSize = 12
        XCTAssertEqual(view.appPageSize, 8)
        view.updateOption(pressed: true)
        XCTAssertEqual(view.visibleRingApps.count, 12)
        view.changeAppPage(2)
        XCTAssertEqual(view.visibleRingApps.map(\.id), [.favorite("test.launch.24")])
        view.changeAppPage(1); XCTAssertEqual(view.appPage, 0)
        view.updateOption(pressed: false)
        XCTAssertEqual(view.appPageSize, 8)
        view.updateOption(pressed: true)
        view.launcherApps = [LauncherRecord(app: records(1)[0].application!, icon: icon, available: false)]
        view.onLaunchApp = { _ in XCTFail("Missing app must not open") }
        view.activate(at: point(0, count: 1))
        view.reset(apps: [], options: Options())
        XCTAssertFalse(view.showsLauncher); XCTAssertTrue(view.launcherApps.isEmpty)
        view.updateOption(pressed: true)
        XCTAssertTrue(view.showsLauncher)
        XCTAssertTrue(view.visibleRingApps.isEmpty)
    }

    @MainActor func testBothGroupsUseSameAppGeometryAndHoverHighlight() async throws {
        let view = view(1)
        view.launcherApps = [favorite(for: primary)]
        let target = point(0, count: 1)
        view.updateHover(at: target)
        let runningHighlight = try XCTUnwrap(view.appHighlightPath)
        let runningSize = view.appIconSize
        XCTAssertTrue(view.toggleLauncherFromCenter(at: RingGeometry.center))
        view.updateHover(at: target)
        XCTAssertEqual(view.appIconSize, runningSize)
        XCTAssertEqual(view.appHighlightPath, runningHighlight)
        XCTAssertEqual(view.highlightedApp, primary.pid)
    }

    @MainActor func testRunningFavoriteExpandsTabsAndOpensThroughLauncher() async {
        let view = view(2)
        view.launcherApps.insert(favorite(for: primary), at: 1)
        view.options.excludedBundleIDs = [primary.bundleID]
        var queries: [pid_t] = [], launches: [String] = [], selections: [String] = []
        view.onSelectApp = { queries.append($0.pid) }
        view.onLaunchApp = { launches.append($0.id) }
        view.onActivateWindow = { selections.append($0.id) }
        view.enterDefaultLauncherMode()
        let running = point(1, count: 3)
        view.updateHover(at: running)
        XCTAssertEqual(queries, [primary.pid])
        let tabs = (0..<2).map { index -> WindowRecord in
            let tab = BrowserTab(bundleID: primary.bundleID, windowID: "1", id: "\(index)",
                                 title: "Tab \(index)", url: "", windowIndex: 1, index: index + 1, minimized: false)
            return WindowRecord(id: tab.id, pid: primary.pid, title: tab.title, minimized: false, fullscreen: false,
                                frame: .zero, element: AXUIElementCreateApplication(primary.pid), tab: tab)
        }
        view.setWindows(.ready(tabs), for: primary.pid)
        XCTAssertTrue(view.showsWindowArc)
        XCTAssertEqual(view.arcAnchor, RingGeometry.angle(index: 1, count: 3))
        view.navigate(.toggleSecondary); view.navigate(.activate)
        XCTAssertEqual(selections, [tabs[0].id])
        view.beginPointer(at: running); view.endPointer(at: running)
        XCTAssertEqual(launches, [primary.bundleID])
        view.updateHover(at: point(2, count: 3))
        XCTAssertFalse(view.showsWindowArc)
        XCTAssertNotNil(view.appHighlightPath)
        view.selectingWithShortcut = true
        view.activateHovered()
        XCTAssertEqual(launches, [primary.bundleID, "test.launch.1"])
        view.endLauncherMode()
        XCTAssertTrue(view.visibleRingApps.isEmpty, "The filter still applies to the running group")
    }

    private func favorite(for app: AppRecord) -> LauncherRecord {
        LauncherRecord(app: LauncherApp(bundleID: app.bundleID, name: app.name, path: "/fixture.app"), icon: icon, available: true)
    }
    @MainActor func testActionPanelLauncherKeepsFocusAndRestoresActionPage() async throws {
        let launcher = view()
        let ordinary = RingPanel(contentRect: CGRect(x: -10000, y: -10000, width: 520, height: 520), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        ordinary.contentView = launcher
        let actions = ActionRingView(frame: CGRect(x: 0, y: 0, width: 480, height: 480))
        actions.actions = (0..<8).map { AppAction(id: "action.\($0)", name: "Action \($0)", shortcut: Shortcut()) }
        actions.ready = true; actions.turnPage(1)
        let panel = ActionPanel(contentRect: ordinary.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = actions
        let source = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 400, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let field = NSSearchField(frame: CGRect(x: 20, y: 20, width: 300, height: 24))
        field.stringValue = "fixture query"; source.contentView?.addSubview(field)
        source.makeKeyAndOrderFront(nil); source.makeFirstResponder(field)
        let editor = try XCTUnwrap(field.currentEditor()); editor.selectedRange = NSRange(location: 2, length: 3)
        defer { panel.orderOut(nil); ordinary.orderOut(nil); source.orderOut(nil) }
        panel.orderFrontRegardless()

        var launched: [String] = []
        launcher.onLaunchApp = { launched.append($0.id) }
        actions.onAction = { _ in XCTFail("Underlying action must not fire") }
        launcher.updateOption(pressed: true)
        panel.setLauncherVisible(true, launcher: launcher, actions: actions, restoreTo: ordinary)
        XCTAssertTrue(panel.contentView === launcher); XCTAssertNil(ordinary.contentView)
        XCTAssertTrue(launcher.showsLauncher)
        XCTAssertNotNil(launcher.launcherInnerArtwork)
        launcher.beginPointer(at: RingGeometry.point(angle: .pi / 2, radius: 82))
        launcher.endPointer(at: RingGeometry.point(angle: .pi / 2, radius: 82))
        XCTAssertTrue(launched.isEmpty)
        XCTAssertFalse(panel.isKeyWindow); XCTAssertFalse(launcher.acceptsFirstResponder)
        XCTAssertFalse(launcher.needsPanelToBecomeKey); XCTAssertTrue(launcher.acceptsFirstMouse(for: nil))
        XCTAssertTrue(source.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange, NSRange(location: 2, length: 3))
        launcher.beginPointer(at: launcher.launcherPoint(1)); launcher.endPointer(at: launcher.launcherPoint(1))
        XCTAssertEqual(launched, ["test.launch.1"])

        // Releasing Option before mouse-up retracts the outer ring and cancels
        // the click; it cannot fall through to either underlying primary ring.
        launcher.beginPointer(at: launcher.launcherPoint(0))
        launcher.updateOption(pressed: false)
        panel.setLauncherVisible(false, launcher: launcher, actions: actions, restoreTo: ordinary)
        launcher.endPointer(at: launcher.launcherPoint(0))
        actions.end(at: RingGeometry.point(angle: .pi / 2, radius: 88))
        XCTAssertEqual(launched, ["test.launch.1"])
        XCTAssertTrue(panel.contentView === actions); XCTAssertTrue(ordinary.contentView === launcher)
        XCTAssertNil(launcher.launcherInnerArtwork)
        XCTAssertEqual(actions.page, 1); XCTAssertTrue(actions.ready)
        XCTAssertEqual(actions.visible.map(\.id), ["action.6", "action.7"])
        XCTAssertTrue(source.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange, NSRange(location: 2, length: 3))
        XCTAssertEqual(launcher.bounds.size, CGSize(width: 480, height: 480))
    }

    @MainActor func testCenterSwitchFromActionLauncherRestoresActionPage() async {
        let launcher = view()
        let ordinary = RingPanel(contentRect: CGRect(x: -10000, y: -10000, width: 520, height: 520), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        ordinary.contentView = launcher
        let actions = ActionRingView(frame: CGRect(x: 0, y: 0, width: 480, height: 480))
        actions.actions = (0..<8).map { AppAction(id: "action.\($0)", name: "Action \($0)", shortcut: Shortcut()) }
        actions.turnPage(1)
        let panel = ActionPanel(contentRect: ordinary.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = actions
        defer { panel.orderOut(nil); ordinary.orderOut(nil) }

        launcher.onLauncherModeEnded = {
            panel.setLauncherVisible(false, launcher: launcher, actions: actions, restoreTo: ordinary)
        }
        launcher.updateOption(pressed: true)
        panel.setLauncherVisible(true, launcher: launcher, actions: actions, restoreTo: ordinary)
        XCTAssertTrue(panel.contentView === launcher)

        launcher.beginPointer(at: RingGeometry.center, clickCount: 2)
        launcher.endPointer(at: RingGeometry.center)
        XCTAssertFalse(launcher.showsLauncher)
        XCTAssertTrue(panel.contentView === actions)
        XCTAssertTrue(ordinary.contentView === launcher)
        XCTAssertNil(launcher.launcherInnerArtwork)
        XCTAssertEqual(actions.page, 1)
    }

    @MainActor func testKeyboardLauncherEntryIsNotAPointerClick() async {
        let launcher = view()
        var pointerInteractions = 0, entries = 0
        launcher.onPointerInteraction = { pointerInteractions += 1 }
        launcher.onLauncherModeEntered = { entries += 1 }
        launcher.updateOption(pressed: true)
        XCTAssertEqual(entries, 1); XCTAssertEqual(pointerInteractions, 0)
        launcher.updateOption(pressed: false)
        XCTAssertTrue(launcher.toggleLauncherFromCenter(at: RingGeometry.center))
        XCTAssertEqual(pointerInteractions, 1)
    }

    @MainActor func testLaunchFailureDoesNotFallBackToAnotherApp() async {
        let app = records(1)[0].application!
        let missing = ApplicationLauncher(resolve: { _ in nil }, open: { _, _, _ in XCTFail("Unresolved app") })
        missing.launch(app) { XCTAssertFalse($0) }
        let failed = expectation(description: "failed launch")
        let launcher = ApplicationLauncher(resolve: { _ in URL(fileURLWithPath: app.path) }, open: { url, config, reply in
            XCTAssertEqual(url.path, app.path)
            XCTAssertTrue(config.activates); XCTAssertFalse(config.createsNewApplicationInstance)
            XCTAssertFalse(config.promptsUserIfNeeded); XCTAssertFalse(config.addsToRecentItems)
            reply(nil, NSError(domain: "Test", code: 1))
        })
        launcher.launch(app) { XCTAssertFalse($0); failed.fulfill() }
        await fulfillment(of: [failed], timeout: 1)
    }

    @MainActor func testLaunchSucceedsWhenWorkspaceReturnsAnExitedApplication() async {
        let app = LauncherApp(bundleID: "com.apple.apps.launcher", name: "Apps", path: "/System/Applications/Apps.app")
        let launched = expectation(description: "successful launch")
        let launcher = ApplicationLauncher(resolve: { _ in URL(fileURLWithPath: app.path) }, open: { _, _, reply in
            reply(ExitedApplication(), nil)
        })
        launcher.launch(app) { success in
            XCTAssertTrue(success)
            launched.fulfill()
        }
        await fulfillment(of: [launched], timeout: 1)
    }

    @MainActor func testRenderLauncherInBothThemes() async throws {
        guard let directory = ProcessInfo.processInfo.environment["LUMARING_SNAPSHOT_DIR"] else { return }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let view = view(6)
        let samples = ["/System/Applications/Notes.app", "/System/Applications/Preview.app",
                       "/System/Applications/Utilities/Terminal.app", "/System/Library/CoreServices/Finder.app"]
        view.launcherApps = view.launcherApps.enumerated().map { index, record in
            let path = samples[index % samples.count]
            let app = LauncherApp(bundleID: record.application!.bundleID, name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, path: path)
            return LauncherRecord(app: app, icon: NSWorkspace.shared.icon(forFile: path), available: true)
        }
        view.apps = view.launcherApps.enumerated().map { index, record in
            AppRecord(pid: pid_t(100 + index), bundleID: record.application!.bundleID, name: record.application!.name, icon: record.icon)
        }
        let panel = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.contentView = view
        for group in ["favorites", "running"] {
            if group == "favorites" { view.enterDefaultLauncherMode() } else { view.endLauncherMode() }
            for theme in [NSAppearance.Name.aqua, .darkAqua] {
                view.appearance = NSAppearance(named: theme)
                view.updateHover(at: point(1, count: view.visibleRingApps.count))
                view.refresh(); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(group)-\(theme.rawValue).png"))
            }
        }
        panel.contentView = nil
    }
}
