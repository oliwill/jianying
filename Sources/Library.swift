import Foundation
import AppKit
import ImageIO
import Photos
import AVFoundation

// MARK: - 数据模型

struct PhotoItem: Identifiable, Hashable {
    let url: URL
    let fileSize: Int64
    var captureDate: Date?
    let isRaw: Bool
    let isVideo: Bool
    var rating: Int  // 0=未标 1/2/3 星

    var id: URL { url }
}

enum RatingFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case three = "★★★"
    case two = "★★"
    case one = "★"
    case unrated = "未标星"
    var id: String { rawValue }

    func matches(_ rating: Int) -> Bool {
        switch self {
        case .all: return true
        case .three: return rating == 3
        case .two: return rating == 2
        case .one: return rating == 1
        case .unrated: return rating == 0
        }
    }
}

enum ViewMode: String {
    case grid = "网格"
    case loupe = "单页"
}

// MARK: - 缓存

final class ThumbCache {
    static let shared = NSCache<NSURL, NSImage>()      // 网格清晰版
    static let preview = NSCache<NSURL, NSImage>()     // 大图
    static let fast = NSCache<NSURL, NSImage>()        // EXIF 小预览

    static func configure() {
        shared.countLimit = 3000
        preview.countLimit = 30
        preview.totalCostLimit = 200 * 1024 * 1024
        fast.countLimit = 6000
    }
}

// MARK: - 解码队列

/// 缩略图解码：低优先级
final class ThumbDecoder {
    private static let sem = DispatchSemaphore(value: 4)

    static func load(_ url: URL) async -> NSImage? {
        await run { ThumbDisk.load(url) }
    }

    static func fast(_ url: URL) async -> NSImage? {
        await run { Media.fastThumb(url) }
    }

    static func sharp(_ url: URL) async -> NSImage? {
        await run { Media.thumbnail(url, maxPixel: 360) }
    }

    private static func run<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                sem.wait()
                let result = work()
                sem.signal()
                cont.resume(returning: result)
            }
        }
    }
}

/// 大图预览解码：独立高优先级队列，不跟缩略图抢资源
final class PreviewDecoder {
    private static let sem = DispatchSemaphore(value: 2)

    static func decode(_ url: URL) async -> NSImage? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInteractive).async {
                sem.wait()
                let result = Media.bigImage(url, maxPixel: 2560)
                sem.signal()
                cont.resume(returning: result)
            }
        }
    }
}

// MARK: - 磁盘缓存

enum ThumbDisk {
    static let queue = DispatchQueue(label: "jianying.thumbdisk", qos: .utility)

    static let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("com.alma.jianying/thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static let previewDir: URL = {
        let d = dir.deletingLastPathComponent().appendingPathComponent("previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func key(_ url: URL) -> String {
        var stamp = ""
        if let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) {
            stamp = "\(v.fileSize ?? 0)-\(Int((v.contentModificationDate ?? .distantPast).timeIntervalSince1970))"
        }
        let raw = "\(url.path)|\(stamp)"
        var hash: UInt64 = 1469598103934665603
        for b in raw.utf8 { hash = (hash ^ UInt64(b)) &* 1099511628211 }
        return String(hash, radix: 36)
    }

    static func path(for url: URL) -> URL {
        dir.appendingPathComponent(key(url)).appendingPathExtension("jpg")
    }

    static func previewPath(for url: URL) -> URL {
        previewDir.appendingPathComponent(key(url)).appendingPathExtension("jpg")
    }

    static func load(_ url: URL) -> NSImage? {
        let p = path(for: url)
        guard let data = try? Data(contentsOf: p, options: .mappedIfSafe),
              let img = NSImage(data: data) else { return nil }
        return img
    }

    static func loadPreview(_ url: URL) -> NSImage? {
        let p = previewPath(for: url)
        guard let data = try? Data(contentsOf: p, options: .mappedIfSafe),
              let img = NSImage(data: data) else { return nil }
        return img
    }

    static func store(_ url: URL, _ image: NSImage) {
        store(image, to: path(for: url))
    }

    static func storePreview(_ url: URL, _ image: NSImage) {
        store(image, to: previewPath(for: url))
    }

    private static func store(_ image: NSImage, to path: URL) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { return }
        try? data.write(to: path, options: .atomic)
    }

    static func warm(_ urls: [URL], maxPixel: CGFloat, progress: (@Sendable (Int) -> Void)? = nil) {
        queue.async {
            var n = 0
            let lock = NSLock()
            let chunk = max(1, urls.count / 8)

            DispatchQueue.concurrentPerform(iterations: (urls.count + chunk - 1) / chunk) { block in
                let start = block * chunk
                let end = min(start + chunk, urls.count)
                guard start < end else { return }
                var done = 0
                for i in start..<end {
                    let u = urls[i]
                    if FileManager.default.fileExists(atPath: path(for: u).path) { continue }
                    if let img = Media.thumbnail(u, maxPixel: maxPixel) {
                        store(u, img)
                        done += 1
                    }
                }
                if done > 0 {
                    lock.lock(); n += done; lock.unlock()
                    progress?(n)
                }
            }
        }
    }
}

// MARK: - 媒体工具

enum Media {
    static let imageExts: Set<String> = [
        "jpg", "jpeg", "jpe", "heic", "heif", "png", "tif", "tiff", "gif", "bmp", "webp",
        "dng", "arw", "sr2", "srf", "cr2", "cr3", "crw", "nef", "nrw", "raf", "orf",
        "rw2", "rwl", "srw", "pef", "x3f", "3fr", "fff", "iiq", "mos", "mrw", "erf",
        "kdc", "dcr", "raw", "rwz", "mef"
    ]
    static let videoExts: Set<String> = ["mov", "mp4", "m4v", "avi", "3gp", "mts", "m2ts"]
    static let rawExts: Set<String> = [
        "dng", "arw", "sr2", "srf", "cr2", "cr3", "crw", "nef", "nrw", "raf", "orf",
        "rw2", "rwl", "srw", "pef", "x3f", "3fr", "fff", "iiq", "mos", "mrw", "erf",
        "kdc", "dcr", "raw", "rwz", "mef"
    ]

    nonisolated static func fastThumb(_ url: URL) -> NSImage? {
        if videoExts.contains(url.pathExtension.lowercased()) {
            return videoThumb(url, maxPixel: 320)
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 320
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// 视频首帧：CGImageSource 做不了 .mov/.mp4，必须走 AVFoundation
    nonisolated static func videoThumb(_ url: URL, maxPixel: CGFloat) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        // 跳过开头 1 秒，避开黑场
        guard let cg = try? gen.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600),
                                            actualTime: nil) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    nonisolated static func thumbnail(_ url: URL, maxPixel: CGFloat) -> NSImage? {
        // 视频走 AVFoundation
        if videoExts.contains(url.pathExtension.lowercased()) {
            return videoThumb(url, maxPixel: maxPixel)
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }

        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        var factor = 4
        if let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue, w > 0 {
            factor = max(1, Int((w / (maxPixel * 2)).rounded(.down)))
        }

        let opts: [CFString: Any] = [
            kCGImageSourceSubsampleFactor: factor,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }

        let fallback: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg2 = CGImageSourceCreateThumbnailAtIndex(src, 0, fallback as CFDictionary) else {
            return fastThumb(url)
        }
        return NSImage(cgImage: cg2, size: NSSize(width: cg2.width, height: cg2.height))
    }

    nonisolated static func bigImage(_ url: URL, maxPixel: CGFloat) -> NSImage? {
        if videoExts.contains(url.pathExtension.lowercased()) {
            return videoThumb(url, maxPixel: maxPixel)
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            guard let cg2 = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            return NSImage(cgImage: cg2, size: NSSize(width: cg2.width, height: cg2.height))
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.timeZone = TimeZone.current
        return f
    }()

    nonisolated static func captureDate(_ url: URL) -> Date? {
        let srcOpts: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldAllowFloat: false
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOpts as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return nil }

        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
           let d = exifFormatter.date(from: s) {
            return d
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let s = tiff[kCGImagePropertyTIFFDateTime] as? String,
           let d = exifFormatter.date(from: s) {
            return d
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let d = attrs[.creationDate] as? Date {
            return d
        }
        return nil
    }

    nonisolated static func quickScan(_ root: URL) -> [PhotoItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let en = fm.enumerator(at: root,
                                     includingPropertiesForKeys: keys,
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        var out: [PhotoItem] = []
        out.reserveCapacity(8000)
        for case let u as URL in en {
            let name = u.lastPathComponent
            if name.hasPrefix("._") || name == ".DS_Store" { continue }
            let ext = u.pathExtension.lowercased()
            let isVideo = videoExts.contains(ext)
            guard imageExts.contains(ext) || isVideo else { continue }
            let vals = try? u.resourceValues(forKeys: Set(keys))
            if vals?.isRegularFile == false { continue }
            out.append(PhotoItem(url: u,
                                 fileSize: Int64(vals?.fileSize ?? 0),
                                 captureDate: nil,
                                 isRaw: rawExts.contains(ext),
                                 isVideo: isVideo,
                                 rating: 0))
        }

        out.sort { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        return out
    }

    nonisolated static func extractDates(_ items: [PhotoItem],
                                         chunkSize: Int = 300,
                                         onChunk: @escaping ([Int: Date]) -> Void) {
        guard !items.isEmpty else { return }
        let lanes = 4
        let per = max(1, (items.count + lanes - 1) / lanes)
        let lock = NSLock()
        var all: [Int: Date] = [:]

        DispatchQueue.concurrentPerform(iterations: lanes) { lane in
            let lo = lane * per
            let hi = min(lo + per, items.count)
            guard lo < hi else { return }

            var pending: [Int: Date] = [:]
            let total = hi - lo

            for i in lo..<hi {
                let it = items[i]
                if !it.isVideo, let d = captureDate(it.url) {
                    pending[i] = d
                }
                let done = i - lo + 1
                if pending.count >= chunkSize || done == total {
                    if !pending.isEmpty {
                        let batch = pending
                        pending.removeAll(keepingCapacity: true)
                        lock.lock()
                        for (k, v) in batch { all[k] = v }
                        lock.unlock()
                        onChunk(batch)
                    }
                }
            }
        }
    }
}

// MARK: - 主数据层

@MainActor
final class Library: ObservableObject {
    @Published var folder: URL?
    @Published var items: [PhotoItem] = []
    @Published var currentIndex: Int = 0
    @Published var filter: RatingFilter = .all
    @Published var viewMode: ViewMode = .grid
    @Published var statusLine = "选一个文件夹开始 — 或者直接把 SD 卡文件夹拖进窗口"
    @Published var busy = false
    @Published var autoAdvance = true
    @Published var columns = 5

    @Published var warmCount = 0
    @Published var dateCount = 0
    @Published var datesReady = false
    @Published var isImporting = false
    @Published var importDone = 0
    @Published var importTotal = 0
    @Published var alertMessage: String?

    /// 标星后的短暂状态提示（无动画，显示在信息栏）
    @Published var statusFlash: String?

    /// 导入前确认：非空时弹确认框
    @Published var importConfirm: String?

    var visibleItems: [PhotoItem] {
        items.filter { filter.matches($0.rating) }
    }

    var currentItem: PhotoItem? {
        let v = visibleItems
        guard !v.isEmpty else { return nil }
        return v[min(max(0, currentIndex), v.count - 1)]
    }

    func ratingCount(_ r: Int) -> Int { items.filter { $0.rating == r }.count }
    var unratedCount: Int { ratingCount(0) }
    var starredCount: Int { items.count - unratedCount }

    // MARK: 视图切换

    func enterLoupe() {
        guard !visibleItems.isEmpty else { return }
        viewMode = .loupe
    }

    func exitLoupe() {
        viewMode = .grid
    }

    // MARK: 打开 / 扫描

    func open(_ url: URL) {
        folder = url
        items = []
        currentIndex = 0
        filter = .all
        viewMode = .grid
        busy = true
        warmCount = 0
        dateCount = 0
        datesReady = false
        statusLine = "扫描中…"
        ThumbCache.shared.removeAllObjects()
        ThumbCache.preview.removeAllObjects()
        ThumbCache.fast.removeAllObjects()

        Task.detached(priority: .userInitiated) {
            let found = Media.quickScan(url)
            await MainActor.run {
                self.items = found
                self.busy = false
                self.statusLine = found.isEmpty
                    ? "这个文件夹里没找到照片"
                    : "\(found.count) 张 · 正在读取拍摄时间…"
            }
            guard !found.isEmpty else { return }

            let snapshot = found
            Media.extractDates(snapshot) { batch in
                Task { @MainActor in
                    guard self.folder == url else { return }
                    for (idx, date) in batch {
                        guard idx < self.items.count,
                              self.items[idx].url == snapshot[idx].url else { continue }
                        self.items[idx].captureDate = date
                        self.dateCount += 1
                    }
                    if self.dateCount >= found.count {
                        self.sortByDate()
                        self.statusLine = "\(found.count) 张 · 已按拍摄时间排序"
                        self.datesReady = true
                    }
                }
            }

            let urls = found.map { $0.url }
            ThumbDisk.warm(urls, maxPixel: 360) { done in
                Task { @MainActor in
                    guard self.folder == url else { return }
                    self.warmCount = done
                }
            }
        }
    }

    func sortByDate() {
        items.sort { a, b in
            let da = a.captureDate ?? .distantPast
            let db = b.captureDate ?? .distantPast
            if da == db { return a.url.path.localizedStandardCompare(b.url.path) == .orderedAscending }
            return da < db
        }
    }

    // MARK: 导航

    func move(_ delta: Int) {
        let n = visibleItems.count
        guard n > 0 else { return }
        currentIndex = min(max(0, currentIndex + delta), n - 1)
    }

    func jump(to index: Int) {
        let n = visibleItems.count
        guard n > 0 else { return }
        currentIndex = min(max(0, index), n - 1)
    }

    // MARK: 标星

    func rate(_ stars: Int) {
        let v = visibleItems
        guard !v.isEmpty, currentIndex < v.count else { return }
        let url = v[currentIndex].url
        guard let idx = items.firstIndex(where: { $0.url == url }) else { return }

        let old = items[idx].rating
        items[idx].rating = stars

        if stars == 0 {
            flashStatus("已取消星标")
            return  // 取消星标不跳下一张，留在原地看清
        }

        if stars != old {
            flashStatus("已标 \(stars) 星")
        }

        if autoAdvance {
            let after = visibleItems
            if after.isEmpty {
                currentIndex = 0
            } else if currentIndex >= after.count {
                currentIndex = after.count - 1
            }
        }
    }

    func rateAllFiltered(_ stars: Int) {
        let urls = Set(visibleItems.map { $0.url })
        for i in items.indices where urls.contains(items[i].url) {
            items[i].rating = stars
        }
    }

    private func flashStatus(_ text: String) {
        statusFlash = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.statusFlash = nil
        }
    }

    func setFilter(_ f: RatingFilter) {
        filter = f
        currentIndex = 0
    }

    // MARK: 键盘

    func handleKey(_ e: NSEvent) -> Bool {
        guard !isImporting else { return false }
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.option) || flags.contains(.control) {
            return false
        }

        // Esc：单页回网格
        if e.keyCode == 53 {
            if viewMode == .loupe { exitLoupe(); return true }
            return false
        }

        // 空格 / 回车：网格 → 单页
        if e.keyCode == 49 || e.keyCode == 36 {
            if viewMode == .grid {
                enterLoupe()
                return true
            }
            return false
        }

        switch e.keyCode {
        case 123: move(-1); return true
        case 124: move(1); return true
        case 126:
            if viewMode == .grid { move(-columns); return true }
            return false
        case 125:
            if viewMode == .grid { move(columns); return true }
            return false
        default: break
        }

        guard let ch = e.charactersIgnoringModifiers?.lowercased(), !ch.isEmpty else { return false }
        switch ch {
        case "1": rate(1); return true
        case "2": rate(2); return true
        case "3": rate(3); return true
        case "0": rate(0); return true
        case "j": move(1); return true
        case "k": move(-1); return true
        case "g":
            if viewMode == .grid { enterLoupe() } else { exitLoupe() }
            return true
        default: return false
        }
    }

    // MARK: 导入「照片」App

    /// 弹确认 → 用户确认后调用 importFilteredConfirmed
    func requestImport() {
        let urls = visibleItems
        guard !urls.isEmpty else {
            alertMessage = "当前筛选下没有照片。先标星，再筛选。"
            return
        }
        if filter == .all && unratedCount > 0 {
            importConfirm = "当前是「全部」视图，包含 \(unratedCount) 张未标星的照片。\n\n要导入全部 \(urls.count) 张，还是只导入已标星的 \(starredCount) 张？"
        } else {
            Task { await importSet(urls.map { $0.url }) }
        }
    }

    /// 只导已标星的（「全部」视图下的选项）
    func importStarredOnly() {
        let urls = items.filter { $0.rating > 0 }.map { $0.url }
        guard !urls.isEmpty else {
            alertMessage = "还没有标星的照片。"
            return
        }
        Task { await importSet(urls) }
    }

    /// 导入全部可见的（「全部」视图下的选项）
    func importAllVisible() {
        Task { await importSet(visibleItems.map { $0.url }) }
    }

    private var importCancelled = false

    func cancelImport() {
        importCancelled = true
        statusLine = "已取消导入"
    }

    private func importSet(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }

        isImporting = true
        importCancelled = false
        importDone = 0
        importTotal = urls.count
        defer { isImporting = false }

        let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard auth == .authorized || auth == .limited else {
            alertMessage = "还没有写入「照片」的权限。\n\n打开 系统设置 → 隐私与安全性 → 照片，勾选「拣影」后重试。"
            return
        }

        var failed: [String] = []
        let lookup = Dictionary(uniqueKeysWithValues: items.map { ($0.url, $0) })

        for url in urls {
            if importCancelled {
                statusLine = "已取消导入（\(importDone)/\(urls.count)）"
                alertMessage = "导入已取消，已导入 \(importDone) 张。"
                return
            }
            let item = lookup[url]
            do {
                try await Self.addAsset(url: url, isVideo: item?.isVideo ?? false)
                importDone += 1
            } catch {
                var retried = false
                if item?.isRaw == true {
                    retried = (try? await Self.addRawAlternate(url: url)) != nil
                }
                if retried {
                    importDone += 1
                } else {
                    failed.append(url.lastPathComponent)
                }
            }
        }

        if failed.isEmpty {
            statusLine = "已导入 \(importDone) 张到「照片」"
            alertMessage = "搞定，\(importDone) 张已经进「照片」App 了。"
        } else {
            statusLine = "导入 \(importDone) 张，\(failed.count) 张失败"
            let head = failed.prefix(6).joined(separator: "\n")
            alertMessage = "导入 \(importDone) 张，失败 \(failed.count) 张：\n\n\(head)"
        }
    }

    private static func addAsset(url: URL, isVideo: Bool) async throws {
        let type: PHAssetResourceType = isVideo ? .video : .photo
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            let opt = PHAssetResourceCreationOptions()
            opt.originalFilename = url.lastPathComponent
            req.addResource(with: type, fileURL: url, options: opt)
        }
    }

    private static func addRawAlternate(url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            let opt = PHAssetResourceCreationOptions()
            opt.originalFilename = url.lastPathComponent
            req.addResource(with: .alternatePhoto, fileURL: url, options: opt)
        }
    }

    // MARK: 复制到文件夹

    func copyVisible(to dest: URL) {
        let set = visibleItems
        guard !set.isEmpty else {
            alertMessage = "当前筛选下没有照片。"
            return
        }

        let fm = FileManager.default
        var ok = 0
        var skipped = 0
        var failed: [String] = []

        let subFormatter = DateFormatter()
        subFormatter.locale = Locale(identifier: "en_US_POSIX")
        subFormatter.dateFormat = "yyyy-MM-dd"

        for item in set {
            let day = item.captureDate.map { subFormatter.string(from: $0) } ?? "未分类"
            let dir = dest.appendingPathComponent(day, isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

            var target = dir.appendingPathComponent(item.url.lastPathComponent)
            if fm.fileExists(atPath: target.path) {
                let existingSize = (try? fm.attributesOfItem(atPath: target.path))?[.size] as? Int64
                if existingSize == item.fileSize {
                    skipped += 1
                    continue
                }
                let base = item.url.deletingPathExtension().lastPathComponent
                let ext = item.url.pathExtension
                var n = 1
                while fm.fileExists(atPath: target.path) {
                    target = dir.appendingPathComponent("\(base)_\(n).\(ext)")
                    n += 1
                    if n > 999 { break }
                }
            }

            do {
                try fm.copyItem(at: item.url, to: target)
                ok += 1
            } catch {
                if (try? fm.attributesOfItem(atPath: target.path)[.size] as? Int64) == item.fileSize {
                    skipped += 1
                } else {
                    failed.append(item.url.lastPathComponent)
                }
            }
        }

        statusLine = "复制 \(ok) 张 · 跳过 \(skipped) · 失败 \(failed.count)"
        if failed.isEmpty {
            alertMessage = "已复制 \(ok) 张到 \(dest.lastPathComponent)。"
        } else {
            alertMessage = "复制 \(ok) 张，失败 \(failed.count) 张。\n\n\(failed.prefix(6).joined(separator: "\n"))"
        }
    }
}
