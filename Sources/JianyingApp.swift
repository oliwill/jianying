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
                Button("查看大图") { library.enterLoupe() }.keyboardShortcut(.return, modifiers: [])
                Divider()
                Button("加入相册") { library.requestImport() }.keyboardShortcut("i", modifiers: [.command])
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
        Group {
            if library.viewMode == .loupe {
                LoupeView(library: library)
            } else {
                GridView(library: library)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    library.pickFolder()
                } label: { Label("打开", systemImage: "folder") }
                    .help("打开文件夹（⌘O）")

                if let f = library.folder {
                    Text(f.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                // 星级筛选
                RatingFilterPicker(library: library)

                Spacer()

                // 加入相册
                Button {
                    library.requestImport()
                } label: {
                    Label("加入相册", systemImage: "photo.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .help("把筛选出的照片导入「照片」App（⌘I）")
                .disabled(library.visibleItems.isEmpty)
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
        // 普通提示
        .alert("拣影", isPresented: Binding(
            get: { library.alertMessage != nil },
            set: { if !$0 { library.alertMessage = nil } }
        )) {
            Button("好") { library.alertMessage = nil }
        } message: {
            Text(library.alertMessage ?? "")
        }
        // 导入确认（全部视图下区分标星/未标星）
        .alert("加入相册", isPresented: Binding(
            get: { library.importConfirm != nil },
            set: { if !$0 { library.importConfirm = nil } }
        )) {
            Button("只导入已标星的") {
                library.importConfirm = nil
                library.importStarredOnly()
            }
            Button("导入全部") {
                library.importConfirm = nil
                library.importAllVisible()
            }
            Button("取消", role: .cancel) { library.importConfirm = nil }
        } message: {
            Text(library.importConfirm ?? "")
        }
        .overlay {
            if library.isImporting { ImportOverlay(library: library) }
        }
    }
}

// MARK: - 星级筛选器

struct RatingFilterPicker: View {
    @ObservedObject var library: Library

    var body: some View {
        HStack(spacing: 2) {
            ForEach(RatingFilter.allCases) { mode in
                Button {
                    library.setFilter(mode)
                } label: {
                    HStack(spacing: 3) {
                        if mode == .all {
                            Text("全部")
                        } else if mode == .unrated {
                            Text("未标星")
                        } else {
                            Text(mode.rawValue)
                                .foregroundStyle(mode == library.filter ? Color.accentColor : Color.secondary)
                        }
                        Text("\(count(for: mode))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        library.filter == mode ? Color.accentColor.opacity(0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func count(for mode: RatingFilter) -> Int {
        switch mode {
        case .all: return library.items.count
        case .three: return library.ratingCount(3)
        case .two: return library.ratingCount(2)
        case .one: return library.ratingCount(1)
        case .unrated: return library.unratedCount
        }
    }
}

// MARK: - 星级显示

struct StarsView: View {
    let rating: Int
    var size: CGFloat = 12

    var body: some View {
        if rating > 0 {
            HStack(spacing: 1) {
                ForEach(1...rating, id: \.self) { _ in
                    Image(systemName: "star.fill")
                        .font(.system(size: size))
                }
            }
            .foregroundStyle(.yellow)
        }
    }
}

// MARK: - 单页大图（Loupe + 胶片条）

struct LoupeView: View {
    @ObservedObject var library: Library
    @State private var image: NSImage?
    @State private var loading = false

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
                    if let item = library.currentItem,
                       let thumb = ThumbCache.shared.object(forKey: item.url as NSURL) {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .opacity(0.6)
                    }
                    ProgressView().controlSize(.large).tint(.white)
                } else {
                    Text("没有照片").foregroundStyle(.white.opacity(0.5))
                }

                // 左上角：星级（大幅显示，当前照片的状态一目了然）
                if let item = library.currentItem, item.rating > 0 {
                    VStack {
                        HStack {
                            StarsView(rating: item.rating, size: 18)
                                .padding(8)
                                .background(.black.opacity(0.5), in: Capsule())
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { library.exitLoupe() }

            // 底部：胶片条 + 信息
            VStack(spacing: 0) {
                // 胶片条（横向缩略图）
                FilmstripView(library: library)

                Divider()

                // 信息栏
                if let item = library.currentItem {
                    HStack(spacing: 14) {
                        Text(item.url.lastPathComponent)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let d = item.captureDate {
                            Text(Self.df.string(from: d))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        // 星级快捷键提示
                        HStack(spacing: 6) {
                            ForEach(1...3, id: \.self) { s in
                                Text("\(s)")
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 18, height: 18)
                                    .background(
                                        item.rating == s ? Color.yellow.opacity(0.3) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 4)
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 4)
                                            .strokeBorder(Color.secondary.opacity(0.3))
                                    }
                            }
                            Text("0")
                                .font(.caption.monospacedDigit())
                                .frame(width: 18, height: 18)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 4)
                                        .strokeBorder(Color.secondary.opacity(0.3))
                                }
                        }
                        .foregroundStyle(.secondary)

                        Spacer()

                        if let flash = library.statusFlash {
                            Text(flash)
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }

                        Text("\(library.currentIndex + 1) / \(library.visibleItems.count)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.bar)
                }
            }
        }
        .background(Color.black)
        .task(id: library.currentItem?.url) {
            guard let item = library.currentItem else {
                image = nil
                return
            }

            if let cached = ThumbCache.preview.object(forKey: item.url as NSURL) {
                image = cached
                return
            }

            if let disk = ThumbDisk.loadPreview(item.url) {
                ThumbCache.preview.setObject(disk, forKey: item.url as NSURL)
                image = disk
                return
            }

            if let thumb = ThumbCache.shared.object(forKey: item.url as NSURL) {
                image = thumb
            }

            loading = true
            let url = item.url
            let img = await PreviewDecoder.decode(url)
            if let img {
                ThumbCache.preview.setObject(img, forKey: url as NSURL)
                ThumbDisk.storePreview(url, img)
                image = img
            }
            loading = false
        }
    }

    static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

// MARK: - 胶片条

struct FilmstripView: View {
    @ObservedObject var library: Library

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(Array(library.visibleItems.enumerated()), id: \.element.id) { idx, item in
                        FilmstripCell(
                            item: item,
                            isCurrent: idx == library.currentIndex,
                            onTap: { library.jump(to: idx) }
                        )
                        .id(idx)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .frame(height: 84)
            .background(.bar)
            .onChange(of: library.currentIndex) { _, new in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
        }
    }
}

struct FilmstripCell: View {
    let item: PhotoItem
    let isCurrent: Bool
    let onTap: () -> Void
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color(nsColor: .controlBackgroundColor)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            // 星级角标
            if item.rating > 0 {
                HStack(spacing: 0) {
                    ForEach(1...item.rating, id: \.self) { _ in
                        Image(systemName: "star.fill")
                            .font(.system(size: 7))
                    }
                }
                .foregroundStyle(.yellow)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                .padding(3)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isCurrent ? Color.accentColor : Color.clear, lineWidth: 2.5)
        }
        .opacity(isCurrent ? 1 : 0.65)
        .onTapGesture { onTap() }
        .task(id: item.url) {
            if let cached = ThumbCache.shared.object(forKey: item.url as NSURL) {
                image = cached
                return
            }
            let url = item.url
            if let quick = await ThumbDecoder.fast(url) {
                image = quick
            }
        }
    }
}

// MARK: - 网格视图（Finder 风格）

struct GridView: View {
    @ObservedObject var library: Library

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: library.columns)
    }

    var body: some View {
        Group {
            if library.visibleItems.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(Array(library.visibleItems.enumerated()), id: \.element.id) { idx, item in
                                GridCell(
                                    item: item,
                                    isCurrent: idx == library.currentIndex,
                                    onTap: { library.jump(to: idx) },
                                    onOpen: {
                                        library.jump(to: idx)
                                        library.enterLoupe()
                                    }
                                )
                                .id(idx)
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: library.currentIndex) { _, new in
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(new, anchor: .center)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: library.busy ? "hourglass" : "photo.on.rectangle.angled")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)
            Text(library.busy ? "正在扫描…" :
                 (library.items.isEmpty ? "选择照片文件夹开始" : "当前筛选下没有照片"))
                .font(.title3)
                .foregroundStyle(.secondary)
            if library.items.isEmpty && !library.busy {
                Text("把 SD 卡文件夹拖进窗口，或")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Button("打开文件夹…") { library.pickFolder() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct GridCell: View {
    let item: PhotoItem
    let isCurrent: Bool
    let onTap: () -> Void
    let onOpen: () -> Void
    @State private var image: NSImage?
    @State private var hover = false

    var body: some View {
        VStack(spacing: 4) {
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
                        // 星级
                        if item.rating > 0 {
                            StarsView(rating: item.rating, size: 9)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(.black.opacity(0.55), in: Capsule())
                        }
                    }
                    Spacer()
                }
                .padding(4)
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isCurrent ? Color.accentColor : Color.white.opacity(hover ? 0.3 : 0),
                                  lineWidth: isCurrent ? 2.5 : 1)
            }

            // 文件名（Finder 风格）
            Text(item.url.deletingPathExtension().lastPathComponent)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { onOpen() }
        .onTapGesture { onTap() }
        .task(id: item.url) {
            if let cached = ThumbCache.shared.object(forKey: item.url as NSURL) {
                image = cached
                return
            }
            let url = item.url

            if let disk = await ThumbDecoder.load(url) {
                ThumbCache.shared.setObject(disk, forKey: url as NSURL)
                image = disk
                return
            }

            if let quick = await ThumbDecoder.fast(url) {
                ThumbCache.fast.setObject(quick, forKey: url as NSURL)
                if image == nil { image = quick }
            }

            if let sharp = await ThumbDecoder.sharp(url) {
                ThumbCache.shared.setObject(sharp, forKey: url as NSURL)
                ThumbDisk.store(url, sharp)
                image = sharp
            }
        }
    }
}

// MARK: - 导入进度

struct ImportOverlay: View {
    @ObservedObject var library: Library

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 14) {
                Text("正在加入相册")
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
}
