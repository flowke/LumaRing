import AppKit
import LumaRingCore
import SwiftUI

struct LauncherSettingsView<BrowserControls: View>: View {
    enum Section: Hashable { case items, settings }
    private enum AddMenuAnchor { case preview, list }

    @Binding var options: Options
    let shortcutError: String?
    let screenCaptureGranted: Bool
    let onSelectPermissions: () -> Void
    @ViewBuilder let browserControls: (LauncherApp) -> BrowserControls

    @State private var catalog = LauncherCatalog()
    @State private var records: [LauncherRecord] = []
    @State private var section: Section = .items
    @State private var editingRing: String?
    @State private var previewingRing: String?
    @State private var browserPopover: String?
    @State private var addMenuAnchor: AddMenuAnchor?
    @State private var page = 0
    @State private var childPage = 0
    @State private var settingsPage = 0
    @State private var settingsChildPage = 0
    @Namespace private var reorderSpace
    @GestureState private var drag: LauncherReorder.Drag?
    @State private var dropRegions = LauncherReorder.DropRegions()
    @State private var pendingRemoval: LauncherRecord?

    private var ring: LauncherRecord? { records.first { $0.id == editingRing } }
    private var pageSize: Int { options.launcherPageSize }
    private var secondaryStyle: LauncherSecondaryStyle { options.launcherSecondaryStyle }
    private var groupName: String { L10n.text("常规", "Standard") }
    private var secondaryName: String { L10n.text("二级圆环", "Secondary ring") }
    private var rowRecords: [LauncherRecord] { ring?.children ?? records }

    var body: some View {
        let reorder = LauncherReorder.Interaction(space: reorderSpace, drag: $drag, regions: dropRegions, move: move)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(groupName).font(.callout.weight(.semibold))
                    .padding(.horizontal, 14).frame(height: 24)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.09)))
                    .accessibilityAddTraits(.isSelected)
                Spacer(minLength: 0)
                Picker(L10n.text("启动器视图", "Launcher view"), selection: $section) {
                    Text(L10n.text("编辑项目", "Edit Items")).tag(Section.items)
                    Text(L10n.text("圆环设置", "Ring Settings")).tag(Section.settings)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            LauncherEditorSplit(space: reorderSpace) {
                preview(reorder: reorder).cardSurface()
            } panel: {
                if section == .items {
                    editor(reorder: reorder).frame(minHeight: 242, alignment: .top).padding(12).cardSurface()
                } else {
                    LauncherRingSettings(options: $options, shortcutError: shortcutError,
                        screenCaptureGranted: screenCaptureGranted, onSelectPermissions: onSelectPermissions)
                }
            }
            .coordinateSpace(name: reorderSpace)
            .onPreferenceChange(LauncherReorder.DropRegionsKey.self) { dropRegions = $0 }
            .overlay(alignment: .topLeading) {
                if let drag {
                    LauncherItemIcon(record: drag.record, size: drag.iconSize)
                        .shadow(color: .black.opacity(0.24), radius: 8, y: 3)
                        .position(drag.location)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .onChange(of: section) { _, value in
            addMenuAnchor = nil
            browserPopover = nil
            if value == .settings {
                let candidates = records[RingGeometry.pageRange(page: page, total: records.count, size: pageSize)]
                previewingRing = (ring?.children.isEmpty == false ? editingRing : nil)
                    ?? candidates.first { !$0.children.isEmpty }?.id
                    ?? records.first { !$0.children.isEmpty }?.id
                settingsPage = records.firstIndex(where: { $0.id == previewingRing }).map { $0 / pageSize } ?? page
                settingsChildPage = editingRing == previewingRing ? childPage : 0
            }
        }
        .onChange(of: options.launcherItems, initial: true) { _, newItems in
            if records.map(\.item) != newItems { records = catalog.snapshot(newItems) }
            if let editingRing, !newItems.contains(where: { $0.id == editingRing }) { closeRing() }
            let lastPage = RingGeometry.pageCount(total: records.count, size: pageSize) - 1
            page = min(page, lastPage)
            settingsPage = min(settingsPage, lastPage)
            childPage = min(childPage, RingGeometry.pageCount(total: ring?.children.count ?? 0, size: secondaryStyle.pageSize) - 1)
            let previewCount = settingsRing(on: settingsPage, size: pageSize)?.children.count ?? 0
            settingsChildPage = min(settingsChildPage, RingGeometry.pageCount(total: previewCount, size: secondaryStyle.pageSize) - 1)
        }
        .onChange(of: pageSize) { oldSize, newSize in
            let lastPage = RingGeometry.pageCount(total: records.count, size: newSize) - 1
            let editingIndex = records.firstIndex { $0.id == editingRing } ?? page * oldSize
            let selectedPreview = settingsRing(on: settingsPage, size: oldSize)
            let previewIndex = records.firstIndex { $0.id == selectedPreview?.id } ?? settingsPage * oldSize
            page = min(editingIndex / newSize, lastPage)
            settingsPage = min(previewIndex / newSize, lastPage)
            previewingRing = selectedPreview?.id
        }
        .onChange(of: secondaryStyle) { oldStyle, newStyle in
            childPage = childPage * oldStyle.pageSize / newStyle.pageSize
            settingsChildPage = settingsChildPage * oldStyle.pageSize / newStyle.pageSize
        }
        .confirmationDialog(L10n.text("移除二级圆环？", "Remove secondary ring?"), isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), titleVisibility: .visible, presenting: pendingRemoval) { record in
            Button(L10n.text("移除", "Remove"), role: .destructive) { remove(record) }
        } message: { record in
            Text(L10n.text("「\(record.name)」及其中的项目会从启动器移除。", "“\(record.name)” and its items will be removed from the launcher."))
        }
    }

    private func preview(reorder: LauncherReorder.Interaction) -> some View {
        let allowsEditing = section == .items
        let mainBinding = allowsEditing ? $page : Binding(get: { settingsPage }, set: {
            settingsPage = $0
            settingsChildPage = 0
            previewingRing = nil
        })
        let pageRange = RingGeometry.pageRange(page: mainBinding.wrappedValue, total: records.count, size: pageSize)
        let visible = Array(records[pageRange])
        let showsExample = !allowsEditing && !records.contains { !$0.children.isEmpty }
        let example = showsExample ? Array(LauncherPreviewExample.records.prefix(pageSize)) : nil
        let displayed = example ?? visible
        let expanded = allowsEditing ? ring : (example?.first { !$0.children.isEmpty } ?? settingsRing(on: settingsPage, size: pageSize))
        let childBinding = allowsEditing ? $childPage : $settingsChildPage
        let childRange = RingGeometry.pageRange(page: childBinding.wrappedValue, total: expanded?.children.count ?? 0, size: secondaryStyle.pageSize)
        let pages = RingGeometry.pageCount(total: records.count, size: pageSize)
        let childPages = RingGeometry.pageCount(total: expanded?.children.count ?? 0, size: secondaryStyle.pageSize)
        return VStack(spacing: 2) {
            LauncherPreview(records: displayed, ringID: expanded?.id,
                            childPage: childRange.lowerBound / secondaryStyle.pageSize,
                            style: secondaryStyle, showsItemNames: options.launcherShowsItemNames,
                            reorder: allowsEditing ? reorder : nil, selectRing: example == nil ? selectPreviewRing : nil)
            HStack(spacing: 16) {
                if allowsEditing {
                    addButton(at: .preview)
                    Spacer(minLength: 0)
                }
                if example != nil {
                    Text(L10n.text("示例预览", "Example preview")).font(.caption).foregroundStyle(.secondary)
                } else {
                    if pages > 1 && (!allowsEditing || editingRing == nil) { pager(page: mainBinding, count: pages) }
                    if childPages > 1 { pager(page: childBinding, count: childPages) }
                }
            }
            .frame(height: 28)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity)
    }

    private func settingsRing(on page: Int, size: Int) -> LauncherRecord? {
        let visible = records[RingGeometry.pageRange(page: page, total: records.count, size: size)]
        return visible.first { $0.id == previewingRing } ?? visible.first { !$0.children.isEmpty }
    }

    private func selectPreviewRing(_ id: String) {
        if section == .items {
            openRing(id)
        } else {
            previewingRing = id
            settingsChildPage = 0
        }
    }

    private func pager(page: Binding<Int>, count: Int) -> some View {
        HStack(spacing: 12) {
            Button { page.wrappedValue = RingGeometry.wrapped(page.wrappedValue - 1, count: count) } label: {
                Image(systemName: "chevron.left")
            }.accessibilityLabel(L10n.text("上一页", "Previous page"))
            Text("\(page.wrappedValue + 1) / \(count)").monospacedDigit().foregroundStyle(.secondary)
            Button { page.wrappedValue = RingGeometry.wrapped(page.wrappedValue + 1, count: count) } label: {
                Image(systemName: "chevron.right")
            }.accessibilityLabel(L10n.text("下一页", "Next page"))
        }.font(.caption).buttonStyle(.borderless)
    }

    private func editor(reorder: LauncherReorder.Interaction) -> some View {
        let target = reorder.target
        return VStack(alignment: .leading, spacing: 8) {
            if let ring {
                Button(action: closeRing) {
                    Label(groupName, systemImage: "chevron.left").font(.callout.weight(.medium))
                }.buttonStyle(.link)
                HStack(spacing: 8) {
                    Text(secondaryName).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    TextField(secondaryName, text: Binding(
                        get: { options.launcherItems.first { $0.id == ring.id }?.secondary?.name ?? "" },
                        set: { name in updateRing(ring.id) { $0.name = name } }
                    )).labelsHidden()
                }
                Divider()
            }
            VStack(spacing: 0) {
                ForEach(rowRecords) { record in
                    row(record, reorder: reorder, target: target)
                    if record.id != rowRecords.last?.id { Divider().padding(.leading, 37).padding(.trailing, 8) }
                }
            }
            addButton(at: .list)
        }.font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func addButton(at anchor: AddMenuAnchor) -> some View {
        let isPresented = Binding(
            get: { addMenuAnchor == anchor },
            set: { presented in
                if presented { addMenuAnchor = anchor }
                else if addMenuAnchor == anchor { addMenuAnchor = nil }
            }
        )
        return Button { isPresented.wrappedValue.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                Text(L10n.text("添加项目", "Add item")).fontWeight(.medium)
                Image(systemName: isPresented.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }.font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(maxWidth: anchor == .list ? .infinity : nil)
                .frame(height: 28)
                .foregroundStyle(Color.accentColor)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor.opacity(0.28)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: isPresented, arrowEdge: anchor == .preview ? .top : .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                addChoice(L10n.text("应用", "Application"), icon: "app") { pickDestinations(folders: false) }
                addChoice(L10n.text("文件夹", "Folder"), icon: "folder") { pickDestinations(folders: true) }
                if editingRing == nil {
                    addChoice(secondaryName, icon: "square.grid.2x2", action: addRing)
                }
            }
            .font(.system(size: 13))
            .frame(width: 144)
            .padding(6)
        }
    }

    private func addChoice(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            addMenuAnchor = nil
            action()
        } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).frame(height: 27).contentShape(Rectangle())
                .modifier(LauncherHoverHighlight())
        }.buttonStyle(.plain)
    }

    private func row(_ record: LauncherRecord, reorder: LauncherReorder.Interaction, target: LauncherReorder.Item?) -> some View {
        let index = rowRecords.firstIndex { $0.id == record.id } ?? 0
        let isRing = record.item.secondary != nil
        let parent = editingRing
        let item = LauncherReorder.Item(id: record.id, parent: parent)
        return HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal").font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary).frame(width: 18, height: 26).contentShape(Rectangle())
                .gesture(reorder.gesture(for: item, record: record, iconSize: 19))
                .help(L10n.text("拖动排序", "Drag to reorder"))
                .accessibilityHidden(true)
            if isRing {
                Button { openRing(record.id) } label: {
                    HStack(spacing: 7) {
                        LauncherItemIcon(record: record, size: 19)
                        Text(record.name).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.accentColor)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            } else {
                LauncherItemIcon(record: record, size: 19)
                Text(record.name).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(record.available ? Color.primary : Color.secondary)
                Spacer(minLength: 0)
                if editingRing == nil, let app = record.application, BrowserAdapters.supports(app.bundleID) {
                    Button { browserPopover = record.id } label: { Image(systemName: "ellipsis.circle") }
                        .buttonStyle(.borderless)
                        .help(L10n.text("浏览器设置", "Browser settings"))
                        .accessibilityLabel(L10n.text("浏览器设置", "Browser settings"))
                        .popover(isPresented: Binding(get: { browserPopover == record.id }, set: { if !$0 { browserPopover = nil } })) {
                            browserControls(app)
                        }
                }
            }
            Button {
                if isRing && !record.children.isEmpty { pendingRemoval = record }
                else { remove(record) }
            } label: { Image(systemName: "minus.circle").frame(width: 18, height: 26) }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help(L10n.text("移除 \(record.name)", "Remove \(record.name)"))
                .accessibilityLabel(L10n.text("移除 \(record.name)", "Remove \(record.name)"))
        }
        .frame(minHeight: 32)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .modifier(LauncherHoverHighlight())
        .background(target == item ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .background { reorder.slot(for: item) }
        .contextMenu {
            Button(L10n.text("上移", "Move up")) {
                if index > 0 { _ = move(record.id, rowRecords[index - 1].id, parent) }
            }.disabled(index == 0)
            Button(L10n.text("下移", "Move down")) {
                if index + 1 < rowRecords.count { _ = move(record.id, rowRecords[index + 1].id, parent) }
            }.disabled(index + 1 >= rowRecords.count)
        }
    }

    private func openRing(_ id: String) {
        guard let index = options.launcherItems.firstIndex(where: { $0.id == id && $0.secondary != nil }) else { return }
        addMenuAnchor = nil
        editingRing = id
        page = index / pageSize
        childPage = 0
    }

    private func closeRing() {
        editingRing = nil
        addMenuAnchor = nil
        childPage = 0
    }

    private func addRing() {
        let item = LauncherItem.secondary(.init(name: secondaryName))
        options.launcherItems.append(item)
        openRing(item.id)
    }

    private func updateRing(_ id: String, _ update: (inout LauncherSecondaryRing) -> Void) {
        guard let index = options.launcherItems.firstIndex(where: { $0.id == id }),
              var ring = options.launcherItems[index].secondary else { return }
        update(&ring)
        options.launcherItems[index] = .secondary(ring)
    }

    private func remove(_ record: LauncherRecord) {
        if let editingRing { updateRing(editingRing) { $0.destinations.removeAll { $0.id == record.id } } }
        else { options.launcherItems.removeAll { $0.id == record.id } }
    }

    private func move(_ sourceID: String, _ targetID: String, _ parent: String?, circular: Bool = false) -> Bool {
        if let parent {
            guard let index = options.launcherItems.firstIndex(where: { $0.id == parent }),
                  var ring = options.launcherItems[index].secondary,
                  let target = LauncherReorder.moveItem(sourceID, to: targetID, in: &ring.destinations) else { return false }
            options.launcherItems[index] = .secondary(ring)
            if parent == editingRing { childPage = target / secondaryStyle.pageSize }
        } else {
            let range = RingGeometry.pageRange(page: page, total: options.launcherItems.count, size: pageSize)
            guard let target = LauncherReorder.moveItem(sourceID, to: targetID,
                onRing: circular ? range : nil, in: &options.launcherItems) else { return false }
            let editedIndex = options.launcherItems.firstIndex { $0.id == editingRing }
            page = (editedIndex ?? target) / pageSize
        }
        records = catalog.snapshot(options.launcherItems)
        return true
    }

    private func pickDestinations(folders: Bool) {
        let parent = editingRing
        let panel = NSOpenPanel()
        panel.title = folders ? L10n.text("选择文件夹", "Choose folders") : L10n.text("选择应用", "Choose applications")
        panel.prompt = L10n.text("添加", "Add")
        panel.canChooseDirectories = folders
        panel.canChooseFiles = !folders
        panel.allowsMultipleSelection = true
        if !folders {
            panel.allowedContentTypes = [.applicationBundle]
            panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        }
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            let added: [LauncherDestination] = folders
                ? panel.urls.compactMap(LauncherFolder.init).map(LauncherDestination.folder)
                : panel.urls.compactMap(LauncherApp.read).map(LauncherDestination.application)
            if let parent {
                updateRing(parent) { ring in
                    var seen = Set(ring.destinations.map(\.id))
                    let new = added.filter { seen.insert($0.id).inserted }
                    guard !new.isEmpty else { return }
                    childPage = ring.destinations.count / secondaryStyle.pageSize
                    ring.destinations += new
                }
            } else {
                var seen = Set(options.launcherItems.map(\.id))
                let new = added.filter { seen.insert($0.id).inserted }
                guard !new.isEmpty else { return }
                page = options.launcherItems.count / pageSize
                options.launcherItems += new.map(LauncherItem.destination)
            }
        }
        if let window = NSApp.mainWindow ?? NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}

private struct LauncherRingSettings: View {
    @Binding var options: Options
    let shortcutError: String?
    let screenCaptureGranted: Bool
    let onSelectPermissions: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            group(L10n.text("圆环显示", "Ring display")) {
                row(L10n.text("材质", "Material")) { title in
                    Picker(title, selection: $options.ringMaterial) {
                        ForEach(RingMaterialStyle.allCases, id: \.self) { style in
                            Text(style.title).tag(style).disabled(!style.isAvailable)
                        }
                    }.labelsHidden().fixedSize()
                }
                Divider()
                sliderRow(L10n.text("直径", "Diameter"), value: $options.ringSize, range: 400...560, step: 20,
                    display: "\(Int(options.ringSize * RingGeometry.appOuter * 2 / RingGeometry.canvas)) pt")
                Divider()
                stepperRow(L10n.text("中央文字字号", "Center text size"), value: $options.centerTitleSize,
                    range: Options.centerTitleSizeRange, unit: " pt")
                Divider()
                row(L10n.text("二级菜单展示方式", "Secondary menu style")) { title in
                    Picker(title, selection: $options.launcherSecondaryStyle) {
                        Text(L10n.text("圆弧", "Arc")).tag(LauncherSecondaryStyle.arc)
                        Text(L10n.text("长条", "Strip")).tag(LauncherSecondaryStyle.strip)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Divider()
                row(L10n.text("显示项目名称", "Show item names")) { title in
                    Toggle(title, isOn: $options.launcherShowsItemNames).toggleStyle(.switch).labelsHidden()
                }
            }
            group(L10n.text("每页数量", "Items per page")) {
                stepperRow(L10n.text("常规项目", "Standard items"), value: $options.launcherPageSize, range: RingGeometry.appPageSizeRange)
                Divider()
                stepperRow(L10n.text("运行中的应用", "Running apps"), value: $options.appPageSize, range: RingGeometry.appPageSizeRange)
                Divider()
                stepperRow(L10n.text("窗口 / 标签页", "Windows / tabs"), value: $options.windowPageSize, range: RingGeometry.windowPageSizeRange)
            }
            group(L10n.text("窗口预览", "Window previews")) {
                row(L10n.text("悬停时显示预览", "Show previews on hover")) { title in
                    Toggle(title, isOn: $options.previews).toggleStyle(.switch).labelsHidden()
                }
                Divider()
                sliderRow(L10n.text("大小", "Size"), value: $options.previewWidth, range: 400...960, step: 40,
                    display: "\(Int(options.previewWidth)) pt")
                    .disabled(!options.previews)
                    .help(L10n.text("预览会自动缩小以适应屏幕。最小化窗口不提供图片预览。", "Previews shrink to fit the screen. Minimized windows have no image preview."))
                if options.previews && !screenCaptureGranted {
                    Divider()
                    Button(L10n.text("设置屏幕录制权限…", "Set up Screen Recording access…"), action: onSelectPermissions)
                        .padding(.vertical, 6)
                }
            }
            group(L10n.text("轮盘操作", "Ring actions")) {
                row(L10n.text("打开轮盘快捷键", "Open ring shortcut")) { title in
                    ShortcutRecorder(shortcut: $options.shortcut).frame(width: 145, height: 30)
                        .accessibilityLabel(title)
                        .accessibilityValue(options.shortcut.display)
                        .help(L10n.text("点击录入快捷键。单键会占用该键的全局输入。", "Click to record a shortcut. A single key is reserved system-wide."))
                }
                if let warning = options.invocationConflict ? L10n.ringShortcutConflict : shortcutError {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true).padding(.bottom, 6)
                }
                Divider()
                row(L10n.text("切换方式", "Selection mode")) { title in
                    Picker(title, selection: $options.holdToSelect) {
                        Text(L10n.text("点击切换", "Click to switch")).tag(false)
                        Text(L10n.text("松手切换", "Release to switch")).tag(true)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
        }
        .font(.callout)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 12, weight: .semibold)).accessibilityAddTraits(.isHeader)
                .padding(.top, 10).padding(.bottom, 2)
            content()
        }.padding(.horizontal, 12).padding(.bottom, 5).cardSurface()
    }

    private func row<Control: View>(_ title: String, @ViewBuilder control: (String) -> Control) -> some View {
        HStack(spacing: 10) {
            Text(title).accessibilityHidden(true)
            Spacer(minLength: 8)
            control(title)
        }.frame(minHeight: 33)
    }

    private func stepperRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, unit: String = "") -> some View {
        let display = "\(value.wrappedValue)\(unit)"
        return row(title) { title in
            Text(display).monospacedDigit().accessibilityHidden(true)
            Stepper(title, value: value, in: range).labelsHidden().accessibilityValue(display)
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, display: String) -> some View {
        row(title) { title in
            Slider(value: value, in: range, step: step) { Text(title) }
                .labelsHidden().frame(maxWidth: 145).accessibilityValue(display)
            Text(display).monospacedDigit().accessibilityHidden(true)
        }
    }
}

struct LauncherEditorColumns {
    static let spacing: CGFloat = 12
    static let minimumSplitWidth: CGFloat = 620
    static let minimumPreviewWidth: CGFloat = 280
    static let minimumPanelWidth: CGFloat = 280
    static let defaultPanelWidth: Double = 300

    let isSplit: Bool
    let previewWidth: CGFloat
    let panelWidth: CGFloat

    var previewHeight: CGFloat { min(560, max(400, previewWidth + 58)) }

    init(width: CGFloat, preferredPanelWidth: Double, translation: CGFloat = 0) {
        isSplit = width >= Self.minimumSplitWidth
        if isSplit {
            let available = width - Self.spacing
            let limits = Self.minimumPanelWidth...(available - Self.minimumPreviewWidth)
            let startingWidth = min(limits.upperBound, max(limits.lowerBound, CGFloat(preferredPanelWidth)))
            panelWidth = min(limits.upperBound, max(limits.lowerBound, startingWidth - translation))
            previewWidth = available - panelWidth
        } else {
            previewWidth = width
            panelWidth = width
        }
    }
}

private struct LauncherEditorSplit<Preview: View, Panel: View>: View {
    let space: Namespace.ID
    @ViewBuilder let preview: () -> Preview
    @ViewBuilder let panel: () -> Panel

    @AppStorage("launcher.settings.panelWidth") private var panelWidth = LauncherEditorColumns.defaultPanelWidth
    @GestureState private var translation: CGFloat? = nil

    var body: some View {
        LauncherEditorLayout(preferredPanelWidth: panelWidth, translation: translation ?? 0) {
            preview()
            Group { panel() }.frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .overlay(alignment: .topLeading) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let columns = LauncherEditorColumns(width: width, preferredPanelWidth: panelWidth, translation: translation ?? 0)
                if columns.isSplit {
                    LauncherEditorDivider(isDragging: translation != nil)
                        .frame(width: LauncherEditorColumns.spacing, height: columns.previewHeight)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(space))
                            .updating($translation) { value, state, _ in state = value.translation.width }
                            .onEnded { value in resize(width: width, by: value.translation.width) })
                        .accessibilityElement()
                        .accessibilityLabel(L10n.text("圆环预览宽度", "Ring preview width"))
                        .accessibilityValue("\(Int((columns.previewWidth / (width - LauncherEditorColumns.spacing) * 100).rounded()))%")
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: resize(width: width, by: 16)
                            case .decrement: resize(width: width, by: -16)
                            @unknown default: break
                            }
                        }
                        .offset(x: columns.previewWidth)
                }
            }
        }
    }

    private func resize(width: CGFloat, by translation: CGFloat) {
        let columns = LauncherEditorColumns(width: width, preferredPanelWidth: panelWidth, translation: translation)
        if columns.isSplit { panelWidth = Double(columns.panelWidth) }
    }
}

private struct LauncherEditorDivider: View {
    let isDragging: Bool
    @State private var isHovered = false
    @State private var ownsCursor = false

    private var isActive: Bool { isHovered || isDragging }

    var body: some View {
        Color.clear
            .overlay {
                Capsule().fill(isActive ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 2, height: 28)
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onChange(of: isActive) { _, active in setResizeCursor(active) }
            .onDisappear { setResizeCursor(false) }
    }

    private func setResizeCursor(_ active: Bool) {
        guard active != ownsCursor else { return }
        if active { NSCursor.resizeLeftRight.push() }
        else { NSCursor.pop() }
        ownsCursor = active
    }
}

private struct LauncherEditorLayout: Layout {
    let preferredPanelWidth: Double
    let translation: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? LauncherEditorColumns.minimumSplitWidth
        let columns = LauncherEditorColumns(width: width, preferredPanelWidth: preferredPanelWidth, translation: translation)
        let panelHeight = subviews[1].sizeThatFits(ProposedViewSize(width: columns.panelWidth, height: nil)).height
        let height = columns.isSplit ? max(columns.previewHeight, panelHeight) : columns.previewHeight + LauncherEditorColumns.spacing + panelHeight
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = LauncherEditorColumns(width: bounds.width, preferredPanelWidth: preferredPanelWidth, translation: translation)
        let previewProposal = ProposedViewSize(width: columns.previewWidth, height: columns.previewHeight)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: previewProposal)
        let panelOrigin = columns.isSplit
            ? CGPoint(x: bounds.minX + columns.previewWidth + LauncherEditorColumns.spacing, y: bounds.minY)
            : CGPoint(x: bounds.minX, y: bounds.minY + columns.previewHeight + LauncherEditorColumns.spacing)
        subviews[1].place(at: panelOrigin, anchor: .topLeading, proposal: ProposedViewSize(width: columns.panelWidth, height: nil))
    }
}

enum LauncherReorder {
    struct Item: Hashable {
        let id: String
        let parent: String?

        func accepts(_ source: Self) -> Bool { parent == source.parent && id != source.id }
    }

    struct Slot: Equatable {
        let item: Item
        let frame: CGRect
        var circular: Bool = false
        var groupDropID: String? = nil
    }

    struct DropTarget: Equatable {
        let item: Item
        let circular: Bool
    }

    struct Track: Equatable {
        let items: [Item]
        var layout: LauncherSecondaryLayout? = nil

        func dropTarget(at point: CGPoint, from source: Item) -> DropTarget? {
            guard items.count > 1, let sourceIndex = items.firstIndex(of: source),
                  let progress = position(at: point) else { return nil }
            let previous = min(items.count - 1, Int(progress))
            let next = (previous + 1) % items.count
            guard sourceIndex != previous, sourceIndex != next else { return nil }
            let linearDestination = sourceIndex < previous || next == 0 ? previous : next
            guard layout == nil else { return DropTarget(item: items[linearDestination], circular: false) }
            let clockwise = RingGeometry.wrapped(previous - sourceIndex, count: items.count)
            let counterclockwise = RingGeometry.wrapped(sourceIndex - next, count: items.count)
            let destination = clockwise == counterclockwise ? linearDestination : (clockwise < counterclockwise ? previous : next)
            return DropTarget(item: items[destination], circular: true)
        }

        func groupAtGap(at point: CGPoint) -> Item? {
            guard layout?.style == .strip, let parent = items.first?.parent,
                  position(at: point) != nil else { return nil }
            return Item(id: parent, parent: nil)
        }

        private func position(at point: CGPoint) -> Double? {
            let dx = point.x - RingGeometry.center.x
            let dy = point.y - RingGeometry.center.y
            let radius = hypot(dx, dy)
            let angle = atan2(dy, dx)

            guard let layout else {
                guard (RingGeometry.appCenterRadius...RingGeometry.appOuter).contains(radius) else { return nil }
                let clockwise = RingGeometry.normalized(.pi / 2 - angle)
                return clockwise / (.pi * 2) * Double(items.count)
            }

            let relative = layout.anchor - angle
            let progress: Double
            switch layout.style {
            case .arc:
                guard (LauncherArc.inner...LauncherArc.outer).contains(radius) else { return nil }
                progress = atan2(sin(relative), cos(relative)) / RingGeometry.arcStep + Double(items.count - 1) / 2
            case .strip:
                guard abs(radius * sin(relative)) <= layout.stripHalfWidth else { return nil }
                progress = (radius * cos(relative) - RingGeometry.appRadius) / LauncherSecondaryLayout.stripStep
            }
            return (0..<Double(items.count - 1)).contains(progress) ? progress : nil
        }
    }

    struct Preview: Equatable {
        let toRingCoordinates: CGAffineTransform
        let tracks: [Track]

        func dropTarget(at location: CGPoint, from source: Item) -> DropTarget? {
            let point = location.applying(toRingCoordinates)
            if source.parent == nil, let group = tracks.lazy.compactMap({ $0.groupAtGap(at: point) }).first {
                return group.accepts(source) ? DropTarget(item: group, circular: true) : nil
            }
            return tracks.lazy.compactMap { $0.dropTarget(at: point, from: source) }.first
        }
    }

    struct DropRegions: Equatable {
        var slots: [Slot] = []
        var preview: Preview?
    }

    struct DropRegionsKey: PreferenceKey {
        static let defaultValue = DropRegions()

        static func reduce(value: inout DropRegions, nextValue: () -> DropRegions) {
            let regions = nextValue()
            value.slots.append(contentsOf: regions.slots)
            if let preview = regions.preview { value.preview = preview }
        }
    }

    struct Drag {
        let item: Item
        let record: LauncherRecord
        let iconSize: CGFloat
        let location: CGPoint
    }

    struct Interaction {
        let space: Namespace.ID
        let drag: GestureState<Drag?>
        let regions: DropRegions
        let move: (String, String, String?, Bool) -> Bool

        var source: Item? { drag.wrappedValue?.item }
        var resolvedTarget: DropTarget? {
            guard let active = drag.wrappedValue else { return nil }
            return target(at: active.location, from: active.item)
        }
        var target: Item? { resolvedTarget?.item }

        private func target(at location: CGPoint, from item: Item) -> DropTarget? {
            LauncherReorder.dropTarget(at: location, from: item, in: regions.slots, preview: regions.preview)
        }

        func slot(for item: Item, circular: Bool = false, groupDropID: String? = nil) -> some View {
            GeometryReader { geometry in
                Color.clear.preference(key: DropRegionsKey.self,
                    value: DropRegions(slots: [Slot(item: item, frame: geometry.frame(in: .named(space)),
                                                    circular: circular, groupDropID: groupDropID)]))
            }
            .allowsHitTesting(false)
        }

        func gesture(for item: Item, record: LauncherRecord, iconSize: CGFloat) -> some Gesture {
            DragGesture(minimumDistance: 5, coordinateSpace: .named(space))
                .updating(drag) { value, state, _ in
                    state = Drag(item: item, record: record, iconSize: iconSize, location: value.location)
                }
                .onEnded { value in
                    if let target = target(at: value.location, from: item) {
                        _ = move(item.id, target.item.id, item.parent, target.circular)
                    }
                }
        }
    }

    static func dropTarget(at location: CGPoint, from source: Item, in slots: [Slot], preview: Preview? = nil) -> DropTarget? {
        func distance(_ slot: Slot) -> CGFloat {
            hypot(location.x - slot.frame.midX, location.y - slot.frame.midY)
        }
        let nearest = slots.lazy.filter { $0.frame.contains(location) }
            .min { distance($0) < distance($1) }
        if let nearest {
            if nearest.item.accepts(source) {
                return DropTarget(item: nearest.item, circular: nearest.circular)
            }
            if let id = nearest.groupDropID {
                let group = Item(id: id, parent: nil)
                if group.accepts(source) { return DropTarget(item: group, circular: true) }
            }
            return nil
        }
        return preview?.dropTarget(at: location, from: source)
    }

    static func previewOrder<Item: Identifiable>(_ items: [Item], from source: String, to target: String,
                                                  circular: Bool = false) -> [Item] where Item.ID == String {
        var ordered = items
        _ = moveItem(source, to: target, onRing: circular ? items.indices : nil, in: &ordered)
        return ordered
    }

    static func moveItem<Item: Identifiable>(_ sourceID: String, to targetID: String,
                                             onRing range: Range<Int>? = nil, in items: inout [Item]) -> Int? where Item.ID == String {
        guard sourceID != targetID,
              let source = items.firstIndex(where: { $0.id == sourceID }),
              let target = items.firstIndex(where: { $0.id == targetID }) else { return nil }
        guard let range, range.contains(source), range.contains(target) else {
            items.move(fromOffsets: IndexSet(integer: source), toOffset: target + (source < target ? 1 : 0))
            return target
        }
        let clockwise = RingGeometry.wrapped(target - source, count: range.count)
        let counterclockwise = range.count - clockwise
        let step = clockwise == counterclockwise ? (source < target ? 1 : -1) : (clockwise < counterclockwise ? 1 : -1)
        let dragged = items[source]
        var vacancy = source
        while vacancy != target {
            let next = range.lowerBound + RingGeometry.wrapped(vacancy - range.lowerBound + step, count: range.count)
            items[vacancy] = items[next]
            vacancy = next
        }
        items[target] = dragged
        return target
    }

    static func nearestAngle(_ angle: Double, to reference: Double) -> Double {
        let delta = angle - reference
        return reference + atan2(sin(delta), cos(delta))
    }
}

private struct LauncherHoverHighlight: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(isHovered ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .onHover { isHovered = $0 }
    }
}

enum LauncherPreviewFit {
    static func transform(surfaceBounds: CGRect, tiles: [CGRect], in size: CGSize) -> CGAffineTransform {
        let bounds = tiles.reduce(surfaceBounds) { $0.union($1) }
        let scale = max(0.01, min((size.width - 12) / bounds.width, (size.height - 12) / bounds.height))
        return CGAffineTransform(a: scale, b: 0, c: 0, d: -scale,
            tx: size.width / 2 - bounds.midX * scale, ty: size.height / 2 + bounds.midY * scale)
    }
}

struct LauncherPreview: View {
    private static let handleCornerRadius: CGFloat = 5

    struct Tile: Identifiable {
        let id: LauncherReorder.Item
        let record: LauncherRecord
        let layout: LauncherTileLayout
        let point: CGPoint
        let angle: Double
        let highlighted: Bool
        let selectRingID: String?
        var handleSide: CGFloat? = nil

        var size: CGSize {
            if let handleSide { return CGSize(width: handleSide, height: handleSide) }
            return CGSize(width: max(layout.labelWidth, layout.iconSize + 4),
                          height: max(layout.height, layout.iconSize + 4))
        }
    }

    private struct TilePosition: ViewModifier, Animatable {
        var angle: Double
        var radius: Double
        let transform: CGAffineTransform

        var animatableData: AnimatablePair<Double, Double> {
            get { AnimatablePair(angle, radius) }
            set { (angle, radius) = (newValue.first, newValue.second) }
        }

        func body(content: Content) -> some View {
            content.position(RingGeometry.point(angle: angle, radius: radius).applying(transform))
        }
    }

    let records: [LauncherRecord]
    let ringID: String?
    let childPage: Int
    let style: LauncherSecondaryStyle
    let showsItemNames: Bool
    let reorder: LauncherReorder.Interaction?
    let selectRing: ((String) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func previewRecords(from source: LauncherReorder.Item?, to target: LauncherReorder.DropTarget?) -> [LauncherRecord] {
        guard let source, let target else { return records }
        if let parent = source.parent {
            return records.map { record in
                guard record.id == parent, let ring = record.item.secondary else { return record }
                let children = LauncherReorder.previewOrder(record.children, from: source.id, to: target.item.id)
                return LauncherRecord(secondary: ring, children: children)
            }
        }
        return LauncherReorder.previewOrder(records, from: source.id, to: target.item.id, circular: target.circular)
    }

    private func menus(for records: [LauncherRecord]) -> [LauncherMenuLayout] {
        LauncherMenuLayout.visible(records: records.map(Optional.some), style: style, active: ringID) { id in
            id == ringID ? childPage : 0
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let ringIndex = records.firstIndex { $0.id == ringID }
            let originalMenus = menus(for: records)
            let originalDisk = LauncherSecondaryLayout.diskPath(with: originalMenus.map(\.layout))
            let originalArc = style == .arc ? originalMenus.first?.layout.arcPath : nil
            let diskBounds = originalDisk.boundingBoxOfPath
            let surfaceBounds = originalArc.map { diskBounds.union($0.boundingBoxOfPath) } ?? diskBounds
            let targets = tiles(for: records, menus: originalMenus, showsGroupHandles: reorder != nil)
            let tileBounds = targets.map { tile in
                let size = tile.size
                return CGRect(x: tile.point.x - size.width / 2, y: tile.point.y - size.height / 2,
                              width: size.width, height: size.height)
            }
            let transform = LauncherPreviewFit.transform(surfaceBounds: surfaceBounds, tiles: tileBounds, in: geometry.size)
            let source = reorder?.source
            let target = reorder?.resolvedTarget
            let displayed = previewRecords(from: source, to: target)
            let displayedMenus = target == nil ? originalMenus : menus(for: displayed)
            let displayedRingIndex = displayed.firstIndex { $0.id == ringID }
            let disk = target == nil ? originalDisk : LauncherSecondaryLayout.diskPath(with: displayedMenus.map(\.layout))
            let arc = style == .arc ? displayedMenus.first?.layout.arcPath : nil
            let scale = transform.a
            let surface = Path { path in
                path.addPath(Path(disk), transform: transform)
                if let arc { path.addPath(Path(arc), transform: transform) }
            }
            let holeSide = RingGeometry.appCenterRadius * 2 * scale
            let originalAngles = Dictionary(targets.map { ($0.id, $0.angle) }, uniquingKeysWith: { first, _ in first })
            let displayedTiles = target == nil ? targets : tiles(for: displayed, menus: displayedMenus, showsGroupHandles: reorder != nil)
            ZStack {
                if let reorder {
                    let origin = geometry.frame(in: .named(reorder.space)).origin
                    Color.clear.preference(key: LauncherReorder.DropRegionsKey.self, value: LauncherReorder.DropRegions(
                        preview: dropPreview(menus: originalMenus, transform: transform, origin: origin)
                    ))
                    .allowsHitTesting(false)
                }
                surface.fill(Color.primary.opacity(0.075))
                surface.stroke(Color.primary.opacity(0.10), lineWidth: 0.6)
                if let displayedRingIndex, !displayedMenus.contains(where: { $0.slot == displayedRingIndex && $0.layout.replacesEntry }) {
                    Path(RingGeometry.sectorPath(index: displayedRingIndex, count: records.count, inner: RingGeometry.appCenterRadius, outer: RingGeometry.appOuter))
                        .applying(transform).fill(Color.accentColor.opacity(0.12))
                }
                Circle().fill(Color(nsColor: .controlBackgroundColor)).frame(width: holeSide, height: holeSide)
                    .position(RingGeometry.center.applying(transform))
                if ringIndex != nil || (style == .strip && !originalMenus.isEmpty) {
                    Text(ringIndex.map { records[$0].name } ?? L10n.text("常规", "Standard"))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        .frame(width: holeSide * 0.82).position(RingGeometry.center.applying(transform))
                }
                ForEach(displayedTiles) { tile in
                    let angle = originalAngles[tile.id].map { LauncherReorder.nearestAngle(tile.angle, to: $0) } ?? tile.angle
                    let draggedGroup = source.map { $0.parent == nil && tile.id.parent == $0.id } ?? false
                    tileArtwork(tile, scale: scale)
                        .opacity(tile.id == source || draggedGroup ? 0.22 : 1)
                        .modifier(TilePosition(angle: angle,
                            radius: hypot(tile.point.x - RingGeometry.center.x, tile.point.y - RingGeometry.center.y),
                            transform: transform))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: tile.point)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                ForEach(targets) { tile in
                    tileTarget(tile, scale: scale).position(tile.point.applying(transform))
                }
            }
        }
        .clipped()
    }

    private func dropPreview(menus: [LauncherMenuLayout], transform: CGAffineTransform, origin: CGPoint) -> LauncherReorder.Preview {
        let primary = LauncherReorder.Track(items: records.map { .init(id: $0.id, parent: nil) })
        let secondary = menus.map { menu in
            LauncherReorder.Track(items: menu.children.map { .init(id: $0.id, parent: menu.id) }, layout: menu.layout)
        }
        let toEditor = transform.concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
        return LauncherReorder.Preview(toRingCoordinates: toEditor.inverted(), tracks: [primary] + secondary)
    }

    func tiles(for records: [LauncherRecord], menus: [LauncherMenuLayout], showsGroupHandles: Bool) -> [Tile] {
        let spacing = LauncherTileLayout.primarySpacing(count: records.count)
        let layout = LauncherTileLayout(primarySpacing: spacing, showsName: showsItemNames)
        let replacedSlots = Set(menus.filter(\.layout.replacesEntry).map(\.slot))
        let primary = records.enumerated().compactMap { index, record -> Tile? in
            guard !replacedSlots.contains(index) else { return nil }
            let item = LauncherReorder.Item(id: record.id, parent: nil)
            return Tile(id: item, record: record, layout: layout,
                        point: RingGeometry.appIconCenter(index: index, count: records.count),
                        angle: RingGeometry.angle(index: index, count: records.count), highlighted: record.id == ringID,
                        selectRingID: record.item.secondary == nil ? nil : record.id)
        }
        let secondary = menus.flatMap { menu in
            menu.children.enumerated().map { index, record in
                let child = LauncherReorder.Item(id: record.id, parent: menu.id)
                let angle = style == .arc
                    ? RingGeometry.arcAngle(index: index, count: menu.children.count, anchor: menu.layout.anchor)
                    : menu.layout.anchor
                return Tile(id: child, record: record, layout: layout.secondary(spacing: menu.layout.tileSpacing(at: index, mainSpacing: spacing)),
                            point: menu.layout.point(index), angle: angle, highlighted: false,
                            selectRingID: style == .strip && menu.id != ringID ? menu.id : nil)
            }
        }
        let handles: [Tile] = showsGroupHandles ? menus.compactMap { menu in
            guard menu.layout.replacesEntry, let first = menu.children.first else { return nil }
            let angle = menu.layout.anchor
            let side = min(26, 72 * sin(.pi / Double(max(records.count, 2)))) * 0.7
            let firstLayout = layout.secondary(spacing: menu.layout.tileSpacing(at: 0, mainSpacing: spacing))
            let firstPoint = menu.layout.point(0)
            let point = LauncherIconOutline.forImage(first.icon).handlePoint(angle: angle, side: side,
                cornerRadius: Self.handleCornerRadius, iconFrame: firstLayout.iconRect(at: firstPoint),
                labelFrame: firstLayout.labelRect(at: firstPoint))
            return Tile(id: .init(id: menu.id, parent: nil), record: menu.record, layout: layout,
                        point: point, angle: angle, highlighted: menu.id == ringID,
                        selectRingID: menu.id, handleSide: side)
        } : []
        return primary + secondary + handles
    }

    @ViewBuilder
    private func tileArtwork(_ tile: Tile, scale: CGFloat) -> some View {
        let layout = tile.layout
        if let side = tile.handleSide {
            let shape = RoundedRectangle(cornerRadius: Self.handleCornerRadius * scale, style: .circular)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: side * 0.46 * scale, weight: .semibold))
                .foregroundStyle(tile.highlighted ? Color.accentColor : Color.secondary)
                .frame(width: side * scale, height: side * scale)
                .background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.7))
        } else {
            VStack(spacing: layout.gap * scale) {
                LauncherItemIcon(record: tile.record, size: layout.iconSize * scale)
                    .background(tile.highlighted ? Color.accentColor.opacity(0.17) : .clear, in: RoundedRectangle(cornerRadius: 5))
                if showsItemNames {
                    Text(tile.record.name).font(.system(size: layout.fontSize * scale, weight: tile.highlighted ? .semibold : .regular))
                        .lineLimit(1)
                        .foregroundStyle(tile.highlighted ? Color.accentColor : Color.secondary)
                        .frame(width: layout.labelWidth * scale, height: layout.labelHeight * scale)
                }
            }
            .frame(width: tile.size.width * scale, height: tile.size.height * scale)
        }
    }

    private func tileTarget(_ tile: Tile, scale: CGFloat) -> some View {
        let handleShape = RoundedRectangle(cornerRadius: Self.handleCornerRadius * scale, style: .circular)
        let hitArea = Rectangle().fill(.clear)
            .frame(width: tile.size.width * scale, height: tile.size.height * scale)
            .contentShape(tile.handleSide == nil ? AnyShape(Rectangle()) : AnyShape(handleShape))
        let label = tile.handleSide == nil ? tile.record.name
            : L10n.text("移动「\(tile.record.name)」分组", "Move the “\(tile.record.name)” group")
        let control = Group {
            if let groupID = tile.selectRingID, let selectRing {
                if reorder == nil {
                    Button { selectRing(groupID) } label: { hitArea }.buttonStyle(.plain)
                } else {
                    hitArea.onTapGesture { selectRing(groupID) }
                        .focusable(interactions: .activate)
                        .onKeyPress(.space) {
                            selectRing(groupID)
                            return .handled
                        }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { selectRing(groupID) }
                }
            } else {
                hitArea.accessibilityElement()
            }
        }
        .accessibilityLabel(label)
        .help(label)
        return Group {
            if let reorder {
                control.gesture(reorder.gesture(for: tile.id, record: tile.record,
                                                iconSize: tile.layout.iconSize * scale))
                    .background {
                        reorder.slot(for: tile.id, circular: tile.id.parent == nil,
                                     groupDropID: style == .strip ? tile.id.parent : nil)
                    }
            } else {
                control
            }
        }
    }
}

@MainActor
private final class LauncherIconOutline {
    private static let cache: NSCache<NSImage, LauncherIconOutline> = {
        let cache = NSCache<NSImage, LauncherIconOutline>()
        cache.countLimit = 128
        return cache
    }()

    private let rows: [CGRect]

    static func forImage(_ image: NSImage) -> LauncherIconOutline {
        if let outline = cache.object(forKey: image) { return outline }
        let outline = LauncherIconOutline(image: image)
        cache.setObject(outline, forKey: image)
        return outline
    }

    private init(image: NSImage) {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let resolution = 96
        let scale = CGFloat(resolution)
        let format = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard image.size.width > 0, image.size.height > 0,
              let artwork = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let mask = CGContext(data: nil, width: resolution, height: resolution, bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: format),
              let pixels = mask.data?.assumingMemoryBound(to: UInt8.self) else {
            rows = [unit]
            return
        }
        let fit = scale / max(image.size.width, image.size.height)
        let width = image.size.width * fit
        let height = image.size.height * fit
        mask.clear(CGRect(x: 0, y: 0, width: scale, height: scale))
        mask.draw(artwork, in: CGRect(x: (scale - width) / 2, y: (scale - height) / 2, width: width, height: height))
        let silhouette = (0..<resolution).compactMap { row -> CGRect? in
            let rowStart = pixels + row * mask.bytesPerRow
            let columns = 0..<resolution
            func isVisible(_ column: Int) -> Bool { rowStart[column * 4 + 3] >= 128 }
            guard let left = columns.first(where: isVisible),
                  let right = columns.last(where: isVisible) else { return nil }
            return CGRect(x: CGFloat(left) / scale, y: CGFloat(resolution - 1 - row) / scale,
                          width: CGFloat(right - left + 1) / scale, height: 1 / scale)
        }
        rows = silhouette.isEmpty ? [unit] : silhouette
    }

    func handlePoint(angle: Double, side: CGFloat, cornerRadius: CGFloat, iconFrame: CGRect, labelFrame: CGRect) -> CGPoint {
        let corner = min(cornerRadius, side / 2)
        let clearance = corner + 2
        let coreSide = side - 2 * corner
        let toIconCoordinates = CGAffineTransform(translationX: -iconFrame.minX, y: -iconFrame.minY)
            .concatenating(CGAffineTransform(scaleX: 1 / iconFrame.width, y: 1 / iconFrame.height))
        let localClearance = clearance / iconFrame.width

        var near: CGFloat = 0
        var far = RingGeometry.appRadius - side / 2 - 2
        for _ in 0..<12 {
            let radius = (near + far) / 2
            let point = RingGeometry.point(angle: angle, radius: radius)
            let core = CGRect(x: point.x - coreSide / 2, y: point.y - coreSide / 2, width: coreSide, height: coreSide)
            let localCore = core.applying(toIconCoordinates)
            let reachesIcon = rows.contains { Self.within(localClearance, $0, localCore) }
            let reachesLabel = !labelFrame.isEmpty && Self.within(clearance, labelFrame, core)
            if reachesIcon || reachesLabel { far = radius } else { near = radius }
        }
        return RingGeometry.point(angle: angle, radius: near)
    }

    private static func within(_ distance: CGFloat, _ first: CGRect, _ second: CGRect) -> Bool {
        let horizontal = max(0, first.minX - second.maxX, second.minX - first.maxX)
        let vertical = max(0, first.minY - second.maxY, second.minY - first.maxY)
        return horizontal * horizontal + vertical * vertical <= distance * distance
    }
}

private enum LauncherPreviewExample {
    static var records: [LauncherRecord] {
        let children = [
            item("terminal", L10n.text("终端", "Terminal")),
            item("plus.forwardslash.minus", L10n.text("计算器", "Calculator")),
            item("folder", L10n.text("项目资料", "Projects"))
        ]
        let group = LauncherSecondaryRing(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
            name: L10n.text("工具", "Tools"))
        return [item("safari", "Safari"), LauncherRecord(secondary: group, children: children),
                item("envelope", L10n.text("邮件", "Mail")), item("note.text", L10n.text("备忘录", "Notes")),
                item("calendar", L10n.text("日历", "Calendar")), item("music.note", L10n.text("音乐", "Music")),
                item("gearshape", L10n.text("设置", "Settings"))]
    }

    private static func item(_ symbol: String, _ name: String) -> LauncherRecord {
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 16, height: 16))
        return LauncherRecord(app: LauncherApp(bundleID: "example.\(symbol)", name: name, path: ""), icon: icon, available: true)
    }
}

private struct LauncherItemIcon: View {
    let record: LauncherRecord
    let size: CGFloat

    var body: some View {
        Image(nsImage: record.icon).resizable().scaledToFit().opacity(record.available ? 1 : 0.45)
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}

private extension View {
    func cardSurface() -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.09)).allowsHitTesting(false))
    }
}
