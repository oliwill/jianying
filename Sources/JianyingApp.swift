import SwiftUI
import Photos
import AppKit
import UniformTypeIdentifiers

@main
struct 拣影App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var library = Library()

    var body: some Scene {
        WindowGroup {
            ContentView(library: library)
                .frame(minWidth: 980, minHeight: 620)
                .onAppear { delegate.library = library }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("打开文件夹…") { library.pickFolder() }.keyboardShortcut("o")
                Button("导入标记为「保留」的照片") {
                    Task { await library.importKept() }
                }.keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var library: Library?
    private var monitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        ThumbCache.configure()

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let lib = self?.library else { return event }
            // 只处理本窗口、且不在输入控件里
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView || responder is NSTextField {
                return event
            }
            // handleKey 只改 @Published 状态，可以直接在当前 runloop 里同步判断
            let consumed = lib.handleKey(event)
            return consumed ? nil : event
        }
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - 根视图

struct ContentView: View {
    @ObservedObject var library: Library
    @State private var showPreview = true

    var body: some View {
        HSplitView {
            SidebarView(library: library)
                .frame(minWidth: 210, idealWidth: 230, maxWidth: 300)

            VStack(spacing: 0) {
                GridView(library: library)
                StatusBar(library: library)
            }
            .frame(minWidth: 380)

            if showPreview {
                PreviewPane(library: library)
                    .frame(minWidth: 300, idealWidth: 460)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    library.pickFolder()
                } label: { Label("打开", systemImage: "folder") }
                    .help("打开文件夹（⌘O）")

                Divider()

                Button {
                    library.move(-1)
                } label: { Image(systemName: "chevron.left") }
                    .help("上一张（←）")
                    .disabled(library.visibleItems.isEmpty)

                Button {
                    library.move(1)
                } label: { Image(systemName: "chevron.right") }
                    .help("下一张（→）")
                    .disabled(library.visibleItems.isEmpty)

                Divider()

                Button {
                    library.mark(.keep)
                } label: { Label("保留", systemImage: "checkmark.circle") }
                    .help("保留（空格）")

                Button {
                    library.mark(.reject)
                } label: { Label("弃用", systemImage: "xmark.circle") }
                    .help("弃用（X）")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $library.autoAdvance) {
                    Label("自动跳下一张", systemImage: "arrow.right.to.line")
                }
                .toggleStyle(.button)
                .help("标记后自动跳到下一张")

                Toggle(isOn: $showPreview) {
                    Label("预览", systemImage: "sidebar.right")
                }
                .toggleStyle(.button)
                .help("显示 / 隐藏大图预览")

                Button {
                    Task { await library.importKept() }
                } label: {
                    Label("导入相册", systemImage: "photo.on.rectangle.angled")
                }
                .help("把标记为「保留」的照片导入「照片」App")
                .disabled(library.keepCount == 0)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    library.open(isDir ? url : url.deletingLastPathComponent())
                }
            }
            return true
        }
        .alert("拣影", isPresented: Binding(
            get: { library.alertMessage != nil },
            set: { if !$0 { library.alertMessage = nil } }
        )) {
            Button("好") { library.alertMessage = nil }
        } message: {
            Text(library.alertMessage ?? "")
        }
        .overlay {
            if library.isImporting { ImportOverlay(library: library) }
        }
    }
}

// MARK: - 侧边栏

struct SidebarView: View {
    @ObservedObject var library: Library

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let f = library.folder {
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                    Text(f.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)
            } else {
                Text("未选择文件夹")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
            }

            List(selection: Binding(
                get: { library.filter },
                set: { library.setFilter($0 ?? .all) }
            )) {
                Section("筛选") {
                    row(.all, "全部", "square.grid.2x2", library.items.count)
                    row(.unreviewed, "未筛", "circle.dashed", library.pendingCount)
                    row(.keep, "保留", "checkmark.circle.fill", library.keepCount)
                    row(.reject, "弃用", "xmark.circle.fill", library.rejectCount)
                }
            }
            .listStyle(.sidebar)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Group {
                    Label("空格 / S — 保留", systemImage: "space")
                    Label("X — 弃用", systemImage: "xmark")
                    Label("← → ↑ ↓ — 移动", systemImage: "arrow.left.and.right")
                    Label("Delete — 撤销标记", systemImage: "delete.left")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(14)

            Divider()

            VStack(spacing: 8) {
                Button {
                    Task { await library.importKept() }
                } label: {
                    Label("导入「照片」(\(library.keepCount))", systemImage: "photo.badge.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(library.keepCount == 0)

                Button {
                    library.pickCopyDestination()
                } label: {
                    Label("复制到文件夹…", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(library.keepCount == 0)
            }
            .padding(12)
        }
        .background(VisualEffect(material: .sidebar))
    }

    @ViewBuilder
    private func row(_ mode: FilterMode, _ title: String, _ icon: String, _ count: Int) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
        }
        .tag(mode)
    }
}

// MARK: - 网格

struct GridView: View {
    @ObservedObject var library: Library

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: library.columns)
    }

    var body: some View {
        Group {
            if library.visibleItems.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(Array(library.visibleItems.enumerated()), id: \.element.id) { idx, item in
                                ThumbCell(
                                    item: item,
                                    isCurrent: idx == library.currentIndex,
                                    onTap: { library.jump(to: idx) },
                                    onDoubleTap: {
                                        library.jump(to: idx)
                                        library.mark(.keep)
                                    }
                                )
                                .id(idx)
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: library.currentIndex) { _, new in
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(new, anchor: .center)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: library.busy ? "hourglass" : "photo.stack")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
            Text(library.busy ? "正在扫描…" : (library.items.isEmpty ? "把 SD 卡文件夹拖进窗口" : "这个筛选下没有照片"))
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("打开文件夹…") { library.pickFolder() }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ThumbCell: View {
    let item: PhotoItem
    let isCurrent: Bool
    let onTap: () -> Void
    let onDoubleTap: () -> Void
    @State private var image: NSImage?
    @State private var hover = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                ProgressView().controlSize(.small)
            }

            if item.status == .reject {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.black.opacity(0.45))
                Image(systemName: "xmark")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.red.opacity(0.9))
            }

            VStack {
                HStack {
                    if item.isRaw {
                        Text("RAW")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.white)
                    }
                    if item.isVideo {
                        Image(systemName: "play.fill")
                            .font(.system(size: 8))
                            .padding(3)
                            .background(.black.opacity(0.55), in: Circle())
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    if item.status == .keep {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white, .green)
                    }
                }
                Spacer()
            }
            .padding(5)
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isCurrent ? Color.accentColor : Color.white.opacity(hover ? 0.25 : 0),
                              lineWidth: isCurrent ? 3 : 1)
        }
        .scaleEffect(isCurrent ? 1.0 : 0.97)
        .animation(.easeOut(duration: 0.12), value: isCurrent)
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { onDoubleTap() }
        .onTapGesture { onTap() }
        .task(id: item.url) {
            // 1) 内存清晰版
            if let cached = ThumbCache.shared.object(forKey: item.url as NSURL) {
                image = cached
                return
            }
            let url = item.url

            // 2) 磁盘缓存（0.1ms，二次打开秒出）
            if let disk = await DecodeGate.shared.run({ ThumbDisk.load(url) }) {
                ThumbCache.shared.setObject(disk, forKey: url as NSURL)
                image = disk
                return
            }

            // 3) 没缓存：先上 EXIF 小预览，别让格子空着
            if let quick = ThumbCache.fast.object(forKey: url as NSURL) {
                image = quick
            } else if let q = await DecodeGate.shared.run({ Media.fastThumb(url) }) {
                ThumbCache.fast.setObject(q, forKey: url as NSURL)
                if image == nil { image = q }
            }

            // 4) 后台换成清晰图，同时落盘
            let sharp = await DecodeGate.shared.run { Media.thumbnail(url, maxPixel: 360) }
            if let sharp {
                ThumbCache.shared.setObject(sharp, forKey: url as NSURL)
                ThumbDisk.store(url, sharp)
                image = sharp
            }
        }
        .help(item.url.lastPathComponent)
    }
}

// MARK: - 大图预览

struct PreviewPane: View {
    @ObservedObject var library: Library
    @State private var image: NSImage?
    @State private var loading = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                } else if loading {
                    ProgressView()
                } else {
                    Text("没有照片").foregroundStyle(.tertiary)
                }
            }

            Divider()

            if let item = library.currentItem {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.url.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 12) {
                        Label(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file),
                              systemImage: "internaldrive")
                        if let d = item.captureDate {
                            Label(Self.df.string(from: d), systemImage: "calendar")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Button {
                            library.mark(.keep)
                        } label: { Label("保留", systemImage: "checkmark") }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)

                        Button {
                            library.mark(.reject)
                        } label: { Label("弃用", systemImage: "xmark") }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)

                        Button {
                            library.mark(.unreviewed)
                        } label: { Image(systemName: "arrow.counterclockwise") }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.regular)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: library.currentItem?.url) {
            guard let item = library.currentItem else {
                image = nil
                return
            }
            if let cached = ThumbCache.preview.object(forKey: item.url as NSURL) {
                image = cached
                return
            }
            loading = true
            image = nil
            let url = item.url
            let img = await DecodeGate.shared.run { Media.bigImage(url, maxPixel: 2400) }
            if let img { ThumbCache.preview.setObject(img, forKey: url as NSURL) }
            image = img
            loading = false
        }
    }

    static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

// MARK: - 状态栏

struct StatusBar: View {
    @ObservedObject var library: Library

    var body: some View {
        HStack(spacing: 12) {
            Text(library.statusLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if library.warmCount > 0 && library.warmCount < library.items.count {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle")
                        .font(.caption2)
                    Text("缓存 \(library.warmCount)")
                        .font(.caption.monospacedDigit())
                }
                .foregroundStyle(.tertiary)
                .help("正在后台生成缩略图缓存，完成后滚动更快")
            }

            if library.items.isEmpty == false {
                Text("\(min(library.currentIndex + 1, library.visibleItems.count)) / \(library.visibleItems.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Stepper(value: $library.columns, in: 2...10) {
                Image(systemName: "square.grid.3x3")
                    .foregroundStyle(.secondary)
            }
            .labelsHidden()
            .help("调整缩略图列数")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - 导入进度

struct ImportOverlay: View {
    @ObservedObject var library: Library

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 14) {
                Text("正在导入「照片」")
                    .font(.headline)
                ProgressView(value: Double(library.importDone),
                             total: Double(max(library.importTotal, 1)))
                    .frame(width: 260)
                Text("\(library.importDone) / \(library.importTotal)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(radius: 20)
        }
    }
}

// MARK: - 辅助

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

extension Library {
    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "打开"
        panel.message = "选照片所在的文件夹（SD 卡里的 DCIM 也可以）"
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    func pickCopyDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "复制到这里"
        panel.message = "选一个目标文件夹，会按拍摄日期建子文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            copyKept(to: url)
        }
    }
}
