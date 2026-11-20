import XCTest
import AppKit
import LumaRingCore
@testable import LumaRing

final class LauncherTests: XCTestCase {
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
    func testOldPreferencesDefaultToEmptyAndRoundTripPreservesOrder() throws {
        let old = try JSONDecoder().decode(Options.self, from: Data("{}".utf8))
        XCTAssertTrue(old.launcherApps.isEmpty)
        var options = old; options.launcherApps = records().map(\.app)
        let decoded = try JSONDecoder().decode(Options.self, from: JSONEncoder().encode(options))
        XCTAssertEqual(decoded.launcherApps, options.launcherApps)
        XCTAssertEqual(LauncherApp.unique(options.launcherApps + options.launcherApps), options.launcherApps)
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
        view.updateOption(pressed: true)
        XCTAssertEqual(view.visibleRingApps.count, 8)
        view.changeAppPage(3)
        XCTAssertEqual(view.visibleRingApps.map(\.id), [.favorite("test.launch.24")])
        view.changeAppPage(1); XCTAssertEqual(view.appPage, 0)
        view.launcherApps = [LauncherRecord(app: records(1)[0].app, icon: icon, available: false)]
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
        let app = records(1)[0].app
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
    @MainActor func testRenderLauncherInBothThemes() async throws {
        guard let directory = ProcessInfo.processInfo.environment["LUMARING_SNAPSHOT_DIR"] else { return }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let view = view(6)
        let samples = ["/System/Applications/Notes.app", "/System/Applications/Preview.app",
                       "/System/Applications/Utilities/Terminal.app", "/System/Library/CoreServices/Finder.app"]
        view.launcherApps = view.launcherApps.enumerated().map { index, record in
            let path = samples[index % samples.count]
            let app = LauncherApp(bundleID: record.app.bundleID, name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, path: path)
            return LauncherRecord(app: app, icon: NSWorkspace.shared.icon(forFile: path), available: true)
        }
        view.apps = view.launcherApps.enumerated().map { index, record in
            AppRecord(pid: pid_t(100 + index), bundleID: record.app.bundleID, name: record.app.name, icon: record.icon)
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
