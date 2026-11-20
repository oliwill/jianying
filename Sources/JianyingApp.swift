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
        // 支持从命令行 / Finder 传路径：拣影 --open /路径/到/照片
        if let i = CommandLine.arguments.firstIndex(of: "--open"),
           i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                    self?.library?.open(isDir.boolValue ? url : url.deletingLastPathComponent())
                    // --loupe：扫描完成后直接进入审片大图
                    if CommandLine.arguments.contains("--loupe") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                            self?.library?.enterLoupe()
                        }
                    }
                }
            }
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

            ToolbarItem(placement: .principal) {
                RatingFilterPicker(library: library)
            }

            ToolbarItem(placement: .primaryAction) {
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
        HStack(spacing: 1) {
            ForEach(RatingFilter.allCases) { mode in
                let selected = library.filter == mode
                Button {
                    library.setFilter(mode)
                } label: {
                    HStack(spacing: 4) {
                        Text(label(for: mode))
                            .font(.callout)
                            .foregroundStyle(selected ? Color.white : Color.secondary)
                        Text("\(count(for: mode))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary.opacity(0.7))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .frame(minWidth: 52)
                    .background(
                        selected ? Color.accentColor : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(helpText(for: mode))
            }
        }
        .padding(2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func label(for mode: RatingFilter) -> String {
        switch mode {
        case .all: return "全部"
        case .three: return "★★★"
        case .two: return "★★"
        case .one: return "★"
        case .unrated: return "未标"
        }
    }

    private func helpText(for mode: RatingFilter) -> String {
        switch mode {
        case .all: return "显示全部照片"
        case .three: return "只显示 3 星（已选定）"
        case .two: return "只显示 2 星（待选）"
        case .one: return "只显示 1 星（备选）"
        case .unrated: return "只显示还没标星的照片"
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

                        // 星级按钮：可点击，不只是快捷键提示
                        HStack(spacing: 4) {
                            ForEach(1...3, id: \.self) { n in
                                RatingChip(
                                    number: n,
                                    isOn: item.rating == n,
                                    help: helpFor(n)
                                ) {
                                    library.rate(n)
                                }
                            }
                            RatingChip(
                                number: 0,
                                isOn: item.rating == 0,
                                help: "取消星标（0）"
                            ) {
                                library.rate(0)
                            }
                        }

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

    private func helpFor(_ n: Int) -> String {
        switch n {
        case 1: return "标 1 星：备选（1）"
        case 2: return "标 2 星：待选（2）"
        default: return "标 3 星：选定（3）"
        }
    }

    static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

// MARK: - 星级按钮

struct RatingChip: View {
    let number: Int
    let isOn: Bool
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text("\(number)")
                .font(.caption.monospacedDigit())
                .frame(width: 20, height: 20)
                .background(
                    isOn ? Color.yellow.opacity(0.28)
                         : (hover ? Color.secondary.opacity(0.15) : Color.clear),
                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(isOn ? Color.yellow.opacity(0.7) : Color.secondary.opacity(0.3),
                                      lineWidth: 1)
                }
                .foregroundStyle(isOn ? Color.primary : Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
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
                // 胶片条跟随选中项，键盘翻页立即到位，不加缓动
                proxy.scrollTo(new, anchor: .center)
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
                .strokeBorder(isCurrent ? Color.accentColor : Color.clear, lineWidth: 3)
        }
        .padding(2)
        .background(
            isCurrent ? Color.accentColor.opacity(0.22) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .opacity(isCurrent ? 1 : 0.72)
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
                        // 键盘翻页是高频操作，滚动立即到位，不加缓动
                        proxy.scrollTo(new, anchor: .center)
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
        VStack(spacing: 5) {
            // 容器：Color.clear 定成正方形，图片放 overlay 里填满，
            // 最后对整个容器裁剪——这样横图竖图都裁到格子内，不会撑破布局
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    ZStack {
                        Color(nsColor: .controlBackgroundColor)
                        if let image {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                // 角标（在裁剪之后，贴在格子内边缘）
                .overlay(alignment: .topLeading) { topLeftBadges }
                .overlay(alignment: .topTrailing) { topRightBadge }
                // 边框
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isCurrent ? Color.accentColor
                                                : Color.white.opacity(hover ? 0.35 : 0),
                                      lineWidth: isCurrent ? 3 : 1)
                }

            // 文件名：固定单行，宽度撑满，不换行不撑高
            Text(item.url.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .center)
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

    @ViewBuilder
    private var topLeftBadges: some View {
        HStack(spacing: 3) {
            if item.isRaw {
                Text("RAW")
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.white)
            }
            if item.isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: 8))
                    .padding(3)
                    .background(.black.opacity(0.65), in: Circle())
                    .foregroundStyle(.white)
            }
        }
        .padding(5)
    }

    @ViewBuilder
    private var topRightBadge: some View {
        if item.rating > 0 {
            StarsView(rating: item.rating, size: 9)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(5)
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
