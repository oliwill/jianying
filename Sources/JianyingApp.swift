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
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { delegate.library = library }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("打开文件夹…") { library.pickFolder() }.keyboardShortcut("o")
                Button("切换网格/单页") { library.toggleViewMode() }.keyboardShortcut("g", modifiers: [.command])
                Divider()
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
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView || responder is NSTextField {
                return event
            }
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

    var body: some View {
        ZStack {
            // 主视图：单页大图 或 网格
            if library.viewMode == .loupe {
                LoupeView(library: library)
                    .transition(.opacity)
            } else {
                GridView(library: library)
                    .transition(.opacity)
            }

            // 状态栏短暂提示（无动画，不打断键盘流）
        }
        .animation(.easeInOut(duration: 0.18), value: library.viewMode)
        .onExitCommand {
            if library.viewMode == .loupe && !library.visibleItems.isEmpty {
                library.toggleViewMode()
            }
        }

        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    library.pickFolder()
                } label: { Label("打开", systemImage: "folder") }
                    .help("打开文件夹（⌘O）")

                Button {
                    library.toggleViewMode()
                } label: {
                    Image(systemName: library.viewMode == .loupe ? "square.grid.2x2" : "rectangle.maximize")
                }
                .help("切换视图（⌘G）")
                .disabled(library.visibleItems.isEmpty)

                Divider()

                Button {
                    library.move(-1)
                } label: {
                    Label("上一张", systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                }
                .help("上一张（←）")
                    .disabled(library.visibleItems.isEmpty)

                Button {
                    library.move(1)
                } label: {
                    Label("下一张", systemImage: "chevron.right")
                        .labelStyle(.iconOnly)
                }
                .help("下一张（→）")
                    .disabled(library.visibleItems.isEmpty)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                // 标记状态指示
                if let item = library.currentItem {
                    StatusBadge(status: item.status)
                }

                Divider()

                Button {
                    library.mark(.keep)
                } label: { Label("保留", systemImage: "checkmark.circle") }
                    .help("保留（空格）")
                    .disabled(library.currentItem == nil)

                Button {
                    library.mark(.reject)
                } label: { Label("弃用", systemImage: "xmark.circle") }
                    .help("弃用（X）")
                    .disabled(library.currentItem == nil)

                Divider()

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

// MARK: - 状态徽标

struct StatusBadge: View {
    let status: CullStatus

    var body: some View {
        Group {
            switch status {
            case .keep:
                Label("保留", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .reject:
                Label("弃用", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            case .unreviewed:
                Label("未筛", systemImage: "circle.dashed")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
    }
}

// MARK: - 单页大图（Loupe）

struct LoupeView: View {
    @ObservedObject var library: Library
    @State private var image: NSImage?
    @State private var loading = false
    @State private var imageSize: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // 大图区域
            ZStack {
                Color.black

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if loading {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                } else if library.currentItem != nil {
                    // 加载中：先用缩略图顶
                    if let thumb = ThumbCache.shared.object(forKey: library.currentItem!.url as NSURL) {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .opacity(0.7)
                    }
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                } else {
                    Text("没有照片")
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 底部信息栏
            if let item = library.currentItem {
                HStack(spacing: 16) {
                    Text(item.url.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let d = item.captureDate {
                        Label(Self.df.string(from: d), systemImage: "calendar")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Label(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file),
                          systemImage: "internaldrive")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !imageSize.isEmpty {
                        Text(imageSize)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    if let flash = library.statusFlash {
                        Text(flash)
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .transition(.opacity)
                    }

                    Text("\(library.currentIndex + 1) / \(library.visibleItems.count)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
        .task(id: library.currentItem?.url) {
            guard let item = library.currentItem else {
                image = nil
                return
            }

            // 1) 内存缓存
            if let cached = ThumbCache.preview.object(forKey: item.url as NSURL) {
                image = cached
                updateSize(cached)
                return
            }

            // 2) 磁盘缓存
            if let disk = ThumbDisk.loadPreview(item.url) {
                ThumbCache.preview.setObject(disk, forKey: item.url as NSURL)
                image = disk
                updateSize(disk)
                return
            }

            // 3) 先显示缩略图占位，避免空白
            if let thumb = ThumbCache.shared.object(forKey: item.url as NSURL) {
                image = thumb
            }

            loading = true

            // 4) 独立高优先级队列解码大图，不受网格负载影响
            let url = item.url
            let img = await PreviewDecoder.decode(url)
            if let img {
                ThumbCache.preview.setObject(img, forKey: url as NSURL)
                ThumbDisk.storePreview(url, img)
                image = img
                updateSize(img)
            }
            loading = false
        }
    }

    private func updateSize(_ img: NSImage) {
        imageSize = "\(Int(img.size.width))×\(Int(img.size.height))"
    }

    static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

// MARK: - 网格视图

struct GridView: View {
    @ObservedObject var library: Library

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: library.columns)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 工具条
            HStack(spacing: 12) {
                // 筛选器
                Menu {
                    ForEach(FilterMode.allCases) { mode in
                        Button {
                            library.setFilter(mode)
                        } label: {
                            HStack {
                                Text(mode.rawValue)
                                Spacer()
                                Text("\(count(for: mode))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(library.filter.rawValue)
                        Text("\(count(for: library.filter))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
                }
                .menuStyle(.borderlessButton)

                Spacer()

                Text("第 \(library.currentIndex + 1) 张，共 \(library.visibleItems.count) 张")
                    .font(.callout)
                    .foregroundStyle(.secondary)


            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)

            // 网格
            if library.visibleItems.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(Array(library.visibleItems.enumerated()), id: \.element.id) { idx, item in
                                ThumbCell(
                                    item: item,
                                    isCurrent: idx == library.currentIndex,
                                    onTap: { library.jump(to: idx) },
                                    onDoubleTap: {
                                        library.jump(to: idx)
                                        library.toggleViewMode()
                                    }
                                )
                                .id(idx)
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: library.currentIndex) { _, new in
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(new, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func count(for mode: FilterMode) -> Int {
        switch mode {
        case .all: return library.items.count
        case .unreviewed: return library.pendingCount
        case .keep: return library.keepCount
        case .reject: return library.rejectCount
        }
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
                .buttonStyle(.borderedProminent)
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
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                ProgressView().controlSize(.small)
            }

            // 状态覆盖层
            if item.status == .reject {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.black.opacity(0.5))
                Image(systemName: "xmark")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.red.opacity(0.9))
            } else if item.status == .keep {
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white, .green)
                            .shadow(radius: 2)
                    }
                    Spacer()
                }
                .padding(4)
            }

            // 角标
            VStack {
                HStack {
                    if item.isRaw {
                        Text("RAW")
                            .font(.system(size: 7, weight: .bold))
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 2))
                            .foregroundStyle(.white)
                    }
                    if item.isVideo {
                        Image(systemName: "play.fill")
                            .font(.system(size: 7))
                            .padding(2)
                            .background(.black.opacity(0.6), in: Circle())
                            .foregroundStyle(.white)
                    }
                    Spacer()
                }
                Spacer()
            }
            .padding(3)
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isCurrent ? Color.accentColor : Color.white.opacity(hover ? 0.3 : 0),
                              lineWidth: isCurrent ? 2.5 : 1)
        }
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { onDoubleTap() }
        .onTapGesture { onTap() }
        .task(id: item.url) {
            if let cached = ThumbCache.shared.object(forKey: item.url as NSURL) {
                image = cached
                return
            }
            let url = item.url

            // 磁盘缓存
            if let disk = await ThumbDecoder.load(url) {
                ThumbCache.shared.setObject(disk, forKey: url as NSURL)
                image = disk
                return
            }

            // EXIF 快速预览
            if let quick = await ThumbDecoder.fast(url) {
                ThumbCache.fast.setObject(quick, forKey: url as NSURL)
                if image == nil { image = quick }
            }

            // 清晰图
            if let sharp = await ThumbDecoder.sharp(url) {
                ThumbCache.shared.setObject(sharp, forKey: url as NSURL)
                ThumbDisk.store(url, sharp)
                image = sharp
            }
        }
        .help(item.url.lastPathComponent)
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
                Button("取消") {
                    library.cancelImport()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(radius: 20)
        }
    }
}

// MARK: - 辅助

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
