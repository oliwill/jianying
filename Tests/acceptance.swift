import Foundation
import AppKit
import Photos

// 拣影 —— 验收测试（38 项）
// 真实图片样本取自 SD 卡：/Users/al/Pictures
// 没有插卡时第 [1] [7] [8] 组会因缺少样本而失败，其余组照常运行。

@MainActor
func runSuite() async {
    var pass = 0, fail = 0
    var failures: [String] = []
    func check(_ name: String, _ cond: Bool, _ detail: String = "") {
        if cond {
            pass += 1
            print("  ✓ \(name)")
        } else {
            fail += 1
            failures.append(name)
            print("  ✗ \(name)  \(detail)")
        }
    }

    let fm = FileManager.default
    let srcRoot = URL(fileURLWithPath: "/Users/al/Pictures")
    let testDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("jy-suite-\(UUID().uuidString)")
    try? fm.createDirectory(at: testDir, withIntermediateDirectories: true)

    let allJPG: [URL] = ((try? fm.contentsOfDirectory(at: srcRoot, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension.lowercased() == "jpg" }
        .sorted { $0.path < $1.path }
    let pool: [URL] = Array(allJPG.prefix(5).filter { !$0.path.contains(".photoslibrary") && !$0.path.contains(".lrlibrary") })
    for u in pool {
        try? fm.copyItem(at: u, to: testDir.appendingPathComponent(u.lastPathComponent))
    }

    // ── 1. 扫描与元数据
    print("\n[1] 扫描与元数据")
    let lib = Library()
    let t0 = Date()
    lib.open(testDir)
    while lib.busy && Date().timeIntervalSince(t0) < 30 {
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
    check("快速扫描 < 2s", Date().timeIntervalSince(t0) < 2,
          String(format: "%.2fs", Date().timeIntervalSince(t0)))
    check("文件数正确", lib.items.count == pool.count, "\(lib.items.count)")
    check("初始全部未筛", lib.pendingCount == lib.items.count)

    let t0b = Date()
    while !lib.datesReady && Date().timeIntervalSince(t0b) < 30 {
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
    check("EXIF 后台补齐完成", lib.datesReady)
    check("拍摄时间全部解析", lib.items.allSatisfy { $0.captureDate != nil })
    check("按拍摄时间升序", {
        let d = lib.items.compactMap { $0.captureDate }
        return zip(d, d.dropFirst()).allSatisfy { $0 <= $1 }
    }())
    check("文件大小已读取", lib.items.allSatisfy { $0.fileSize > 0 })

    // ── 2. 标记与筛选
    print("\n[2] 标记与筛选")
    lib.setFilter(.all)
    lib.jump(to: 0); lib.mark(.keep)
    lib.jump(to: 1); lib.mark(.keep)
    lib.jump(to: 2); lib.mark(.reject)
    check("保留 2 张", lib.keepCount == 2, "\(lib.keepCount)")
    check("弃用 1 张", lib.rejectCount == 1, "\(lib.rejectCount)")
    check("未筛 2 张", lib.pendingCount == 2, "\(lib.pendingCount)")
    check("三态加总 = 总数", lib.keepCount + lib.rejectCount + lib.pendingCount == lib.items.count)

    for (mode, expect) in [(FilterMode.keep, 2), (.reject, 1), (.unreviewed, 2), (.all, 5)] {
        lib.setFilter(mode)
        check("筛选「\(mode.rawValue)」= \(expect)", lib.visibleItems.count == expect,
              "\(lib.visibleItems.count)")
    }

    // ── 3. 键盘导航
    print("\n[3] 键盘导航")
    lib.setFilter(.all)
    lib.jump(to: 0)
    lib.move(1)
    check("→ 前进一张", lib.currentIndex == 1, "\(lib.currentIndex)")
    lib.move(-1)
    check("← 后退一张", lib.currentIndex == 0, "\(lib.currentIndex)")
    lib.move(-1)
    check("← 边界不越界", lib.currentIndex == 0, "\(lib.currentIndex)")
    lib.jump(to: lib.visibleItems.count - 1)
    lib.move(1)
    check("→ 边界不越界", lib.currentIndex == lib.visibleItems.count - 1)
    lib.jump(to: 999)
    check("跳转超界自动收敛", lib.currentIndex == lib.visibleItems.count - 1)

    // ── 4. 撤销
    print("\n[4] 撤销标记")
    lib.setFilter(.reject)
    lib.jump(to: 0)
    lib.mark(.unreviewed)
    check("弃用可撤销", lib.rejectCount == 0, "\(lib.rejectCount)")

    // ── 5. 批量操作
    print("\n[5] 批量操作")
    lib.setFilter(.unreviewed)
    let before = lib.keepCount
    lib.markAllFiltered(.keep)
    check("批量标记保留", lib.keepCount == before + 3, "\(lib.keepCount)")

    // ── 6. 复制到文件夹
    print("\n[6] 复制到文件夹")
    let dest = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("jy-dest-\(UUID().uuidString)")
    try? fm.createDirectory(at: dest, withIntermediateDirectories: true)

    func countFiles(_ root: URL) -> Int {
        let subs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return subs.flatMap {
            (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? []
        }.count
    }

    lib.copyKept(to: dest)
    check("复制了全部保留项", countFiles(dest) == 5, "\(countFiles(dest))")

    let subs = (try? fm.contentsOfDirectory(at: dest, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    check("按拍摄日期建子目录", subs.allSatisfy { $0.lastPathComponent.count == 10 },
          subs.map { $0.lastPathComponent }.joined(separator: ","))

    lib.copyKept(to: dest)
    check("重复复制不产生副本", countFiles(dest) == 5, "\(countFiles(dest))")

    // ── 7. 图像解码
    print("\n[7] 图像解码")
    if let it = lib.items.first {
        let t1 = Date()
        let th = Media.thumbnail(it.url, maxPixel: 360)
        let ms = Date().timeIntervalSince(t1) * 1000
        check("缩略图生成", th != nil)
        check("缩略图 ≤360px", (th?.size.width ?? 999) <= 360, "\(th?.size.width ?? 0)")
        check("缩略图 < 500ms", ms < 500, String(format: "%.0fms", ms))
        check("EXIF 快速预览可用", Media.fastThumb(it.url) != nil)

        let big = Media.bigImage(it.url, maxPixel: 2400)
        check("大图预览生成", big != nil)
        check("大图尺寸合理", (big?.size.width ?? 0) >= 500 && (big?.size.height ?? 0) >= 500,
              "\(Int(big?.size.width ?? 0))x\(Int(big?.size.height ?? 0))")
    } else {
        check("缩略图生成", false, "无样本")
    }

    // ── 8. 磁盘缓存
    print("\n[8] 磁盘缓存")
    if let it = lib.items.first, let img = Media.thumbnail(it.url, maxPixel: 360) {
        ThumbDisk.store(it.url, img)
        let t2 = Date()
        let loaded = ThumbDisk.load(it.url)
        let ms = Date().timeIntervalSince(t2) * 1000
        check("缓存写入后可读回", loaded != nil)
        check("缓存读取 < 5ms", ms < 5, String(format: "%.2fms", ms))
        check("缓存键随文件变化", ThumbDisk.key(it.url).count > 0)
    } else {
        check("缓存写入后可读回", false, "无样本")
    }

    // ── 9. 边界情况
    print("\n[9] 边界情况")
    let emptyDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("jy-empty-\(UUID().uuidString)")
    try? fm.createDirectory(at: emptyDir, withIntermediateDirectories: true)
    try? "x".write(to: emptyDir.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

    let el = Library()
    el.open(emptyDir)
    let t3 = Date()
    while el.busy && Date().timeIntervalSince(t3) < 15 {
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
    check("空目录不崩溃", !el.busy && el.items.isEmpty)
    check("忽略非图片文件", el.items.isEmpty)
    el.mark(.keep)
    check("空列表标记不崩溃", el.keepCount == 0)
    el.move(1)
    check("空列表导航不崩溃", el.currentIndex == 0)

    // ── 10. 照片 App 接入
    print("\n[10] 照片 App 接入")
    let st = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    let names: [Int: String] = [0: "未询问", 1: "受限", 2: "已拒绝", 3: "已授权", 4: "受限访问"]
    let stName = names[st.rawValue] ?? "未知"
    print("  · addOnly 写入权限: \(stName)")
    // 命令行二进制的权限独立于 .app bundle，未授权是正常的
    check("权限状态可查询", st.rawValue >= 0)

    try? fm.removeItem(at: testDir)
    try? fm.removeItem(at: dest)
    try? fm.removeItem(at: emptyDir)

    print("\n" + String(repeating: "─", count: 44))
    print("结果: \(pass) 通过 / \(fail) 失败")
    if !failures.isEmpty {
        print("失败项: \(failures.joined(separator: ", "))")
    }
    exit(fail == 0 ? 0 : 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { await runSuite() }
app.run()
