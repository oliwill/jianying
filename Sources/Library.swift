import Foundation
import AppKit
import ImageIO
import Photos

// MARK: - 数据模型

enum CullStatus: String {
    case unreviewed = "未筛"
    case keep = "保留"
    case reject = "弃用"
}

struct PhotoItem: Identifiable, Hashable {
    let url: URL
    let fileSize: Int64
    var captureDate: Date?
    let isRaw: Bool
    let isVideo: Bool
    var status: CullStatus

    var id: URL { url }
}

enum FilterMode: String, CaseIterable, Identifiable {
    case all = "全部"
    case unreviewed = "未筛"
    case keep = "保留"
    case reject = "弃用"
    var id: String { rawValue }
}

// MARK: - 缩略图缓存

final class ThumbCache {
    static let shared = NSCache<NSURL, NSImage>()      // 清晰版
    static let preview = NSCache<NSURL, NSImage>()     // 大图
    static let fast = NSCache<NSURL, NSImage>()        // EXIF 小预览

    static func configure() {
        shared.countLimit = 3000
        preview.countLimit = 24
        fast.countLimit = 6000
    }
}

/// 限制同时解码的数量，避免 LazyVGrid 一次涌入几百个任务把 IO/CPU 打满
final class DecodeGate {
    static let shared = DecodeGate(limit: max(3, ProcessInfo.processInfo.activeProcessorCount - 1))
    private let sem: DispatchSemaphore

    init(limit: Int) { sem = DispatchSemaphore(value: limit) }

    func run<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                self.sem.wait()
                let result = work()
                self.sem.signal()
                cont.resume(returning: result)
            }
        }
    }
}

/// 磁盘缩略图缓存 —— SD 卡读一张 320px 要 230ms，缓存后是 2ms。
/// 这是专业筛片软件（Bridge / Photo Mechanic）的标准做法。
enum ThumbDisk {
    static let queue = DispatchQueue(label: "jianying.thumbdisk", qos: .utility)

    static let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("com.alma.jianying/thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// 路径 + 大小 + 修改时间 组成键：文件被替换后自动失效
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

    static func load(_ url: URL) -> NSImage? {
        let p = path(for: url)
        guard let data = try? Data(contentsOf: p, options: .mappedIfSafe),
              let img = NSImage(data: data) else { return nil }
        return img
    }

    static func store(_ url: URL, _ image: NSImage) {
        let p = path(for: url)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
        else { return }
        try? data.write(to: p, options: .atomic)
    }

    /// 后台预热：扫描完后把所有缩略图逐张落盘，之后滚动就是纯本地读取
    static func warm(_ urls: [URL], maxPixel: CGFloat, progress: (@Sendable (Int) -> Void)? = nil) {
        queue.async {
            var n = 0
            let lock = NSLock()
            let chunk = max(1, urls.count / (max(2, ProcessInfo.processInfo.activeProcessorCount) * 2))

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

    /// 快速占位图：直接取相机内嵌的 EXIF 预览（约 160x120，0.6ms）
    /// 用于网格先立刻显示内容，避免空白等待
    nonisolated static func fastThumb(_ url: URL) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 320
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// 清晰缩略图：走 subsample 快路径从主图重采样
    /// 比 Always 全解码快约 3 倍（238ms → 81ms）
    nonisolated static func thumbnail(_ url: URL, maxPixel: CGFloat) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }

        // JPEG 走 DCT 缩放快路径。factor 按目标尺寸估，4 对应大约 1/4 边长
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

        // 老路径兜底（某些 RAW 不认 subsample）
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
            // 没有预览图的 RAW，退回嵌入式 JPEG
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
        // 关键：options 字典要显式关掉浮点解码和缓存，否则 ImageIO 会做完整解码（4.8ms → 0.3ms 的差距）
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

    /// 快速扫描：只枚举文件和属性，不读 EXIF。
    /// SD 卡上 5400 张只要 0.5 秒，用户能立刻看到缩略图。
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
                                 status: .unreviewed))
        }

        // 没有 EXIF 时先按文件名排，通常相机就是递增编号，已经近似时间序
        out.sort { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        return out
    }

    /// 给一批照片补 EXIF 拍摄时间。分块并行（4 条道最优），边算边回调。
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
    @Published var filter: FilterMode = .all
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

    var visibleItems: [PhotoItem] {
        switch filter {
        case .all: return items
        case .unreviewed: return items.filter { $0.status == .unreviewed }
        case .keep: return items.filter { $0.status == .keep }
        case .reject: return items.filter { $0.status == .reject }
        }
    }

    var currentItem: PhotoItem? {
        let v = visibleItems
        guard !v.isEmpty else { return nil }
        return v[min(max(0, currentIndex), v.count - 1)]
    }

    var keepCount: Int { items.filter { $0.status == .keep }.count }
    var rejectCount: Int { items.filter { $0.status == .reject }.count }
    var pendingCount: Int { items.filter { $0.status == .unreviewed }.count }

    // MARK: 打开 / 扫描

    func open(_ url: URL) {
        folder = url
        items = []
        currentIndex = 0
        filter = .all
        busy = true
        warmCount = 0
        dateCount = 0
        statusLine = "扫描中…"
        ThumbCache.shared.removeAllObjects()
        ThumbCache.preview.removeAllObjects()
        ThumbCache.fast.removeAllObjects()

        Task.detached(priority: .userInitiated) {
            // 第一步：只枚举文件（SD 卡 5400 张约 0.5s），立刻让用户看到照片
            let found = Media.quickScan(url)
            await MainActor.run {
                self.items = found
                self.busy = false
                self.statusLine = found.isEmpty
                    ? "这个文件夹里没找到照片"
                    : "\(found.count) 张 · 正在读取拍摄时间…"
            }
            guard !found.isEmpty else { return }

            // 第二步：后台补 EXIF 拍摄时间，分批回传，不阻塞浏览
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
                    // 全部读完后按拍摄时间重排一次（编号顺序通常已经接近，视觉跳动很小）
                    if self.dateCount >= found.count {
                        self.sortByDate()
                        self.statusLine = "\(found.count) 张 · 已按拍摄时间排序"
                        self.datesReady = true
                    }
                }
            }

            // 第三步：预热缩略图进磁盘缓存
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

    // MARK: 标记

    func mark(_ s: CullStatus) {
        let v = visibleItems
        guard !v.isEmpty, currentIndex < v.count else { return }
        let url = v[currentIndex].url
        guard let idx = items.firstIndex(where: { $0.url == url }) else { return }
        items[idx].status = s

        if autoAdvance && s != .unreviewed {
            let after = visibleItems
            if after.isEmpty {
                currentIndex = 0
            } else if currentIndex >= after.count {
                currentIndex = after.count - 1
            }
        }
    }

    func markAllFiltered(_ s: CullStatus) {
        let urls = Set(visibleItems.map { $0.url })
        for i in items.indices where urls.contains(items[i].url) {
            items[i].status = s
        }
    }

    func setFilter(_ f: FilterMode) {
        filter = f
        currentIndex = 0
    }

    // MARK: 键盘

    /// 返回 true 表示已消费这个按键
    func handleKey(_ e: NSEvent) -> Bool {
        guard !isImporting else { return false }
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.option) || flags.contains(.control) {
            return false
        }

        switch e.keyCode {
        case 123: move(-1); return true          // ←
        case 124: move(1); return true           // →
        case 126: move(-columns); return true    // ↑
        case 125: move(columns); return true     // ↓
        case 49:  mark(.keep); return true       // space
        case 51, 117: mark(.unreviewed); return true // delete
        default: break
        }

        guard let ch = e.charactersIgnoringModifiers?.lowercased(), !ch.isEmpty else { return false }
        switch ch {
        case "x": mark(.reject); return true
        case "s": mark(.keep); return true
        case "j": move(1); return true
        case "k": move(-1); return true
        case "1": mark(.keep); return true
        case "2": mark(.reject); return true
        case "0": mark(.unreviewed); return true
        default: return false
        }
    }

    // MARK: 导入「照片」App

    func importKept(into photosApp: Bool = true) async {
        let urls = items.filter { $0.status == .keep }.map { $0.url }
        guard !urls.isEmpty else {
            alertMessage = "还没有标记为「保留」的照片。按空格键标一下。"
            return
        }

        isImporting = true
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

        for (_, url) in urls.enumerated() {
            let item = lookup[url]
            do {
                try await Self.addAsset(url: url, isVideo: item?.isVideo ?? false)
                importDone += 1
            } catch {
                // RAW 失败时再试一次 alternatePhoto
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

    func copyKept(to dest: URL) {
        let kept = items.filter { $0.status == .keep }
        guard !kept.isEmpty else {
            alertMessage = "还没有标记为「保留」的照片。"
            return
        }

        let fm = FileManager.default
        var ok = 0
        var skipped = 0
        var failed: [String] = []

        let subFormatter = DateFormatter()
        subFormatter.locale = Locale(identifier: "en_US_POSIX")
        subFormatter.dateFormat = "yyyy-MM-dd"

        for item in kept {
            let day = item.captureDate.map { subFormatter.string(from: $0) } ?? "未分类"
            let dir = dest.appendingPathComponent(day, isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

            var target = dir.appendingPathComponent(item.url.lastPathComponent)
            if fm.fileExists(atPath: target.path) {
                // 先判断是不是同一个文件（大小相同即认为是重复），重复就跳过，不产生副本
                let existingSize = (try? fm.attributesOfItem(atPath: target.path))?[.size] as? Int64
                if existingSize == item.fileSize {
                    skipped += 1
                    continue
                }
                // 同名但内容不同：加序号，避免默默覆盖
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
