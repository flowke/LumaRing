import AppKit
import LumaRingCore
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var dragScope = UUID().uuidString
    @State private var pendingRemoval: LauncherRecord?

    private var ring: LauncherRecord? { records.first { $0.id == editingRing } }
    private var pageSize: Int { options.launcherPageSize }
    private var secondaryStyle: LauncherSecondaryStyle { options.launcherSecondaryStyle }
    private var groupName: String { L10n.text("常规", "Standard") }
    private var secondaryName: String { L10n.text("二级圆环", "Secondary ring") }
    private var rowRecords: [LauncherRecord] { ring?.children ?? records }

    var body: some View {
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
            LauncherEditorLayout(showsSettings: section == .settings) {
                preview.cardSurface()
                Group {
                    if section == .items {
                        editor.frame(minHeight: 242, alignment: .top).padding(12).cardSurface()
                    } else {
                        LauncherRingSettings(options: $options, shortcutError: shortcutError,
                            screenCaptureGranted: screenCaptureGranted, onSelectPermissions: onSelectPermissions)
                    }
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
            records = catalog.snapshot(newItems)
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

    private var preview: some View {
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
        let alternateStyle: LauncherSecondaryStyle = secondaryStyle == .arc ? .strip : .arc
        let alternatePage = childRange.lowerBound / alternateStyle.pageSize
        let alternateCount = RingGeometry.pageRange(page: alternatePage, total: expanded?.children.count ?? 0, size: alternateStyle.pageSize).count
        return VStack(spacing: 2) {
            LauncherPreview(records: displayed, ringID: expanded?.id,
                            childPage: childRange.lowerBound / secondaryStyle.pageSize,
                            alternateChildCount: alternateCount,
                            style: secondaryStyle, showsItemNames: options.launcherShowsItemNames, reorder: allowsEditing ? reorder : nil,
                            selectRing: example == nil ? selectPreviewRing : nil)
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
        .frame(height: 400)
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

    private var reorder: LauncherReorder {
        LauncherReorder(scope: dragScope, move: move)
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

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                    row(record)
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

    private func row(_ record: LauncherRecord) -> some View {
        let index = rowRecords.firstIndex { $0.id == record.id } ?? 0
        let isRing = record.item.secondary != nil
        let parent = editingRing
        return HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal").font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary).frame(width: 18, height: 26).contentShape(Rectangle())
                .draggable(reorder.payload(for: record.id, parent: parent))
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
        .modifier(LauncherDropTarget(reorder: reorder, id: record.id, parent: parent))
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

    private func move(_ sourceID: String, _ targetID: String, _ parent: String?) -> Bool {
        if let parent {
            guard let index = options.launcherItems.firstIndex(where: { $0.id == parent }),
                  var ring = options.launcherItems[index].secondary,
                  let target = LauncherReorder.moveItem(sourceID, to: targetID, in: &ring.destinations) else { return false }
            options.launcherItems[index] = .secondary(ring)
            childPage = target / secondaryStyle.pageSize
        } else {
            guard let target = LauncherReorder.moveItem(sourceID, to: targetID, in: &options.launcherItems) else { return false }
            let editedIndex = options.launcherItems.firstIndex { $0.id == editingRing }
            page = (editedIndex ?? target) / pageSize
        }
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

private struct LauncherEditorLayout: Layout {
    let showsSettings: Bool
    private let spacing: CGFloat = 12
    private let twoColumnMinimum: CGFloat = 620

    private func widths(for width: CGFloat) -> (preview: CGFloat, list: CGFloat) {
        guard width >= twoColumnMinimum else { return (width, width) }
        let list = showsSettings ? min(500, (width - spacing) * 0.57) : min(340, max(228, (width - spacing) * 0.38))
        return (width - spacing - list, list)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? twoColumnMinimum
        let available = widths(for: width)
        let preview = subviews[0].sizeThatFits(ProposedViewSize(width: available.preview, height: nil))
        let list = subviews[1].sizeThatFits(ProposedViewSize(width: available.list, height: nil))
        let height = width < twoColumnMinimum ? preview.height + spacing + list.height : max(preview.height, list.height)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = widths(for: bounds.width)
        let previewProposal = ProposedViewSize(width: width.preview, height: nil)
        let listProposal = ProposedViewSize(width: width.list, height: nil)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: previewProposal)
        let listOrigin = bounds.width < twoColumnMinimum
            ? CGPoint(x: bounds.minX, y: bounds.minY + subviews[0].sizeThatFits(previewProposal).height + spacing)
            : CGPoint(x: bounds.minX + width.preview + spacing, y: bounds.minY)
        subviews[1].place(at: listOrigin, anchor: .topLeading, proposal: listProposal)
    }
}

struct LauncherReorder {
    let scope: String
    let move: (String, String, String?) -> Bool

    func payload(for id: String, parent: String?) -> String { prefix(parent) + id }

    func accept(_ payloads: [String], target: String, parent: String?) -> Bool {
        let prefix = prefix(parent)
        guard let payload = payloads.first, payload.hasPrefix(prefix) else { return false }
        return move(String(payload.dropFirst(prefix.count)), target, parent)
    }

    private func prefix(_ parent: String?) -> String { "\(scope):\(parent ?? "main"):" }

    static func moveItem<Item: Identifiable>(_ sourceID: String, to targetID: String, in items: inout [Item]) -> Int? where Item.ID == String {
        guard sourceID != targetID,
              let source = items.firstIndex(where: { $0.id == sourceID }),
              let target = items.firstIndex(where: { $0.id == targetID }) else { return nil }
        items.move(fromOffsets: IndexSet(integer: source), toOffset: target + (source < target ? 1 : 0))
        return target
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

private struct LauncherDropTarget: ViewModifier {
    let reorder: LauncherReorder
    let id: String
    let parent: String?
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .background(targeted ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .dropDestination(for: String.self) { payloads, _ in
                reorder.accept(payloads, target: id, parent: parent)
            } isTargeted: { targeted = $0 }
    }
}

private struct LauncherPreview: View {
    let records: [LauncherRecord]
    let ringID: String?
    let childPage: Int
    let alternateChildCount: Int
    let style: LauncherSecondaryStyle
    let showsItemNames: Bool
    let reorder: LauncherReorder?
    let selectRing: ((String) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            let ringIndex = records.firstIndex { $0.id == ringID }
            let anchor = ringIndex.map { RingGeometry.angle(index: $0, count: records.count) } ?? 0
            let entries = records.map(Optional.some)
            let menus = LauncherMenuLayout.visible(records: entries, style: style, active: ringID) { id in
                id == ringID ? childPage : 0
            }
            let strips = style == .strip ? menus : LauncherMenuLayout.visible(records: entries, style: .strip, active: nil) { id in
                id == ringID ? childPage * LauncherSecondaryStyle.arc.pageSize / LauncherSecondaryStyle.strip.pageSize : 0
            }
            let stripDisk = LauncherSecondaryLayout.diskPath(with: strips.map(\.layout))
            let disk = style == .strip ? stripDisk : RingGeometry.diskPath
            let arc = style == .arc ? menus.first?.layout.arcPath : nil
            let alternateArc = style == .strip ? LauncherArc.path(count: alternateChildCount, anchor: anchor) : arc
            let frame = stripDisk.boundingBoxOfPath
            let bounds = alternateArc.map { $0.isEmpty ? frame : frame.union($0.boundingBoxOfPath) } ?? frame
            let replacedSlots = Set(strips.map(\.slot))
            let scale = max(0.01, min((geometry.size.width - 12) / bounds.width, (geometry.size.height - 12) / bounds.height))
            let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale,
                tx: geometry.size.width / 2 - bounds.midX * scale,
                ty: geometry.size.height / 2 + bounds.midY * scale)
            let surface = Path { path in
                path.addPath(Path(disk), transform: transform)
                if let arc { path.addPath(Path(arc), transform: transform) }
            }
            let holeSide = RingGeometry.appCenterRadius * 2 * scale
            let primarySpacing = 2 * RingGeometry.appRadius * sin(.pi / Double(max(records.count, 2)))
            ZStack {
                surface.fill(Color.primary.opacity(0.075))
                surface.stroke(Color.primary.opacity(0.10), lineWidth: 0.6)
                if let ringIndex, style == .arc || !replacedSlots.contains(ringIndex) {
                    Path(RingGeometry.sectorPath(index: ringIndex, count: records.count, inner: RingGeometry.appCenterRadius, outer: RingGeometry.appOuter))
                        .applying(transform).fill(Color.accentColor.opacity(0.12))
                }
                Circle().fill(Color(nsColor: .controlBackgroundColor)).frame(width: holeSide, height: holeSide)
                    .position(RingGeometry.center.applying(transform))
                if ringIndex != nil || (style == .strip && !strips.isEmpty) {
                    Text(ringIndex.map { records[$0].name } ?? L10n.text("常规", "Standard"))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        .frame(width: holeSide * 0.82).position(RingGeometry.center.applying(transform))
                }
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    if style == .arc || !replacedSlots.contains(index) {
                        let point = RingGeometry.appIconCenter(index: index, count: records.count).applying(transform)
                        previewTile(record, spacing: primarySpacing, scale: scale, maxIconSize: 34,
                                    highlighted: index == ringIndex, parent: nil).position(point)
                    }
                }
                ForEach(menus) { menu in
                    ForEach(Array(menu.children.enumerated()), id: \.element.id) { index, record in
                        let point = menu.layout.point(index).applying(transform)
                        let inPrimarySlot = menu.layout.replacesEntry && index == 0
                        let spacing = menu.layout.tileSpacing(at: index, mainSpacing: primarySpacing)
                        let dragAsGroup = inPrimarySlot && menu.id != ringID
                        previewTile(record, spacing: spacing, scale: scale, maxIconSize: 28,
                                    highlighted: false, parent: dragAsGroup ? nil : menu.id,
                                    groupEntry: dragAsGroup ? menu.id : nil,
                                    allowsDrag: menu.id == ringID || dragAsGroup).position(point)
                    }
                }
            }
        }
    }

    private func previewTile(_ record: LauncherRecord, spacing: CGFloat, scale: CGFloat, maxIconSize: CGFloat,
                             highlighted: Bool, parent: String?,
                             groupEntry: String? = nil, allowsDrag: Bool = true) -> some View {
        let isSecondary = record.item.secondary != nil
        let layout = LauncherTileLayout(spacing: spacing, maxIconSize: maxIconSize, showsName: showsItemNames)
        let width = max(layout.labelWidth, layout.iconSize + 4) * scale
        let tile = VStack(spacing: layout.gap * scale) {
            LauncherItemIcon(record: record, size: layout.iconSize * scale)
                .background(highlighted ? Color.accentColor.opacity(0.17) : .clear, in: RoundedRectangle(cornerRadius: 5))
            if showsItemNames {
                Text(record.name).font(.system(size: layout.fontSize * scale, weight: highlighted ? .semibold : .regular))
                    .lineLimit(1)
                    .foregroundStyle(highlighted ? Color.accentColor : Color.secondary)
                    .frame(width: layout.labelWidth * scale, height: layout.labelHeight * scale)
            }
        }
        .frame(width: width, height: max(layout.height, layout.iconSize + 4) * scale)
        .contentShape(Rectangle())

        let control = Group {
            if let groupID = groupEntry ?? (isSecondary ? record.id : nil), let selectRing {
                Button { selectRing(groupID) } label: { tile }.buttonStyle(.plain)
            } else { tile }
        }
        .accessibilityLabel(record.name)
        .help(record.name)
        return Group {
            if let reorder, allowsDrag {
                let id = groupEntry ?? record.id
                control.draggable(reorder.payload(for: id, parent: parent))
                    .modifier(LauncherDropTarget(reorder: reorder, id: id, parent: parent))
            } else { control }
        }
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
