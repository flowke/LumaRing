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

    func testLauncherDropReordersWithinTheSourceRingWhenAnAppAppearsInBoth() {
        let apps = records().compactMap(\.application)
        let original = apps.map(LauncherDestination.application)
        var primary = original.map(LauncherItem.destination)
        var secondary = original
        let ringID = "ring:\(UUID())"
        let reorder = LauncherReorder(scope: "launcher-test") { source, target, parent in
            if parent == ringID {
                return LauncherReorder.moveItem(source, to: target, in: &secondary) != nil
            }
            return LauncherReorder.moveItem(source, to: target, in: &primary) != nil
        }
        let first = apps[0].id, last = apps[2].id
        let mainPayload = reorder.payload(for: first, parent: nil)
        let secondaryPayload = reorder.payload(for: last, parent: ringID)

        XCTAssertFalse(reorder.accept([mainPayload], target: last, parent: ringID))
        XCTAssertFalse(reorder.accept([secondaryPayload], target: first, parent: nil))
        XCTAssertFalse(reorder.accept([mainPayload], target: first, parent: nil))
        XCTAssertTrue(reorder.accept([mainPayload], target: last, parent: nil))
        XCTAssertEqual(primary.map(\.id), [apps[1].id, last, first])
        XCTAssertEqual(secondary, original)
        XCTAssertTrue(reorder.accept([secondaryPayload], target: first, parent: ringID))
        XCTAssertEqual(secondary.map(\.id), [last, first, apps[1].id])
        XCTAssertEqual(primary.map(\.id), [apps[1].id, last, first])
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
