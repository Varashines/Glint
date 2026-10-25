import AppKit
import Carbon
import Combine
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Constants

/// Cap stored text to avoid blowing up memory / history.json with huge logs.
private let maxStoredTextLength = 100_000
/// Max thumbnail pixel width (2x for Retina, down from full-res originals).
private let thumbnailMaxPixelWidth = 400

// MARK: - Shared caches & formatters (avoid per-row I/O)

final class SharedCaches {
    static let appIcons = NSCache<NSString, NSImage>()
    static let thumbnails = NSCache<NSString, NSImage>()
    static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
    static let linkDetector: NSDataDetector? = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)
}

private func cgImage(from image: NSImage) -> CGImage? {
    var rect = NSRect(origin: .zero, size: image.size)
    return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
}

private func pngData(from cgImage: CGImage) -> Data? {
    let rep = NSBitmapImageRep(cgImage: cgImage)
    return rep.representation(using: .png, properties: [:])
}

private func scaledThumbnailCG(from cgImage: CGImage, maxWidth: Int) -> CGImage? {
    let origW = cgImage.width
    let origH = cgImage.height
    guard origW > 0, origH > 0 else { return nil }
    if origW <= maxWidth { return cgImage }
    let scale = Double(maxWidth) / Double(origW)
    let newW = maxWidth
    let newH = max(1, Int(Double(origH) * scale))
    guard let ctx = CGContext(
        data: nil, width: newW, height: newH,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
    return ctx.makeImage()
}

private func isURLString(_ trimmed: String) -> Bool {
    guard !trimmed.isEmpty, trimmed.count < 8_192 else { return false }
    let lower = trimmed.lowercased()
    guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return false }
    guard let detector = SharedCaches.linkDetector else {
        return URL(string: trimmed)?.scheme != nil
    }
    let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
    if let match = detector.firstMatch(in: trimmed, options: [], range: range) {
        // Require the link match to cover the start (allowing trailing whitespace already trimmed).
        return match.range.location == 0 && match.range.length >= min(trimmed.count, 10)
    }
    return false
}

// MARK: - Utilities
private func keyCodeToKeyEquivalent(_ keyCode: UInt32) -> String {
    switch keyCode {
    case 49: return " "
    case 36: return "\r"
    case 48: return "\t"
    default:
        if let savedText = UserDefaults.standard.string(forKey: "hotkeyText") {
            if savedText.count == 1 {
                return savedText.lowercased()
            }
        }
        return "j"
    }
}

private func carbonToNSEventModifiers(_ carbonModifiers: UInt32) -> SwiftUI.EventModifiers {
    var flags: SwiftUI.EventModifiers = []
    if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
    if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
    if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
    if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
    return flags
}

// MARK: - Global HotKey Manager
class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()
    private var hotKeyRefs: [Int: EventHotKeyRef] = [:]
    private var handlers: [Int: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?

    func unregisterAll() {
        for ref in hotKeyRefs.values { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        handlers.removeAll()
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    func register(id: Int, keyCode: UInt32, modifiers: UInt32, block: @escaping () -> Void) {
        if let oldRef = hotKeyRefs[id] { UnregisterEventHotKey(oldRef) }
        handlers[id] = block

        if eventHandler == nil {
            let eventType = [
                EventTypeSpec(
                    eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            ]
            let handlerUPP: EventHandlerUPP = { (_, event, _) -> OSStatus in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event, OSType(kEventParamDirectObject), OSType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)

                if let action = GlobalHotKeyManager.shared.handlers[Int(hotKeyID.id)] {
                    action()
                    return OSStatus(noErr)
                }
                return OSStatus(eventNotHandledErr)
            }
            InstallEventHandler(
                GetApplicationEventTarget(), handlerUPP, 1, eventType, nil, &eventHandler)
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x474C_4E54), id: UInt32(id))
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            #if DEBUG
                print("⚠️ Glint: RegisterEventHotKey failed id=\(id) status=\(status)")
            #endif
        }
        if let ref = hotKeyRef { hotKeyRefs[id] = ref }
    }
}

// MARK: - Glint Data Model
enum ContentType: String, Codable {
    case text = "TEXT"
    case url = "URL"
    case file = "FILE"
    case image = "IMAGE"
}

struct ClipboardItem: Identifiable, Equatable, Codable {
    var id = UUID()
    let text: String
    let type: ContentType
    let timestamp: Date
    let sourceApp: String?
    let bundleID: String?
    var isPinned: Bool = false
    let fileURLs: [URL]?
    let imageFileName: String?
    let originalImageName: String?

    var relativeTime: String {
        SharedCaches.relativeFormatter.localizedString(for: timestamp, relativeTo: Date())
    }

    var appIcon: NSImage? {
        guard let bundleID = bundleID else { return nil }
        if let cached = SharedCaches.appIcons.object(forKey: bundleID as NSString) {
            return cached
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        SharedCaches.appIcons.setObject(icon, forKey: bundleID as NSString)
        return icon
    }

    private func cachedImage(fileName: String?) -> NSImage? {
        guard let fileName = fileName else { return nil }
        if let cached = SharedCaches.thumbnails.object(forKey: fileName as NSString) {
            return cached
        }
        // Primary location, with fallback to the pre-migration folder for users
        // who haven't had their files moved yet (or if migration was skipped).
        let candidates = [
            GlintMonitor.shared.cacheFolder.appendingPathComponent(fileName),
            GlintMonitor.shared.legacyCacheFolder.appendingPathComponent(fileName),
        ]
        for url in candidates {
            if let img = NSImage(contentsOf: url) {
                SharedCaches.thumbnails.setObject(img, forKey: fileName as NSString)
                return img
            }
        }
        return nil
    }

    var thumbnail: NSImage? { cachedImage(fileName: imageFileName) }
    var originalImage: NSImage? { cachedImage(fileName: originalImageName) }

    enum CodingKeys: String, CodingKey {
        case id, text, type, timestamp, sourceApp, bundleID, isPinned, fileURLs, imageFileName,
            originalImageName
    }
}

// MARK: - Glint Engine
class GlintMonitor: ObservableObject {
    static let shared = GlintMonitor()

    @Published var items: [ClipboardItem] = []
    @Published var ignoredApps: [String] = []
    /// ID of the item shown in the attached preview panel. Nil = preview hidden.
    /// Single source of truth shared by the list window and the preview window.
    @Published var selectedPreviewID: UUID? = nil
    @Published var isPaused: Bool = false {
        didSet {
            if !isPaused {
                // Sync change count on resume so we don't capture whatever is currently on the clipboard
                lastChangeCount = NSPasteboard.general.changeCount
            }
        }
    }

    /// Live binding to the previewed item — never a stale struct copy.
    var selectedPreviewItem: ClipboardItem? {
        guard let id = selectedPreviewID else { return nil }
        return items.first { $0.id == id }
    }

    enum CleanupPeriod: String, CaseIterable, Codable {
        case oneDay = "1 Day"
        case oneWeek = "1 Week"
        case thirtyDays = "30 Days"
        case forever = "Forever"

        var seconds: TimeInterval? {
            switch self {
            case .oneDay: return 86400
            case .oneWeek: return 604800
            case .thirtyDays: return 2_592_000
            case .forever: return nil
            }
        }
    }

    let defaultIgnoredApps = [
        "com.agilebits.onepassword7",
        "com.1password.1password",
        "com.bitwarden.desktop",
        "com.8bit.bitwarden",
        "com.apple.keychainaccess",
        "com.apple.systempreferences",
        "com.apple.Passwords",
        "com.dashlane.Dashlane",
        "com.lastpass.LastPass",
        "com.enpass.Enpass",
        "org.keepassxc.keepassxc",
        "com.mseven.trezorbridge",
    ]

    func cleanupHistory() {
        let periodRaw = UserDefaults.standard.string(forKey: "cleanupPeriod") ?? "Forever"
        guard let period = CleanupPeriod(rawValue: periodRaw), let seconds = period.seconds else {
            return
        }

        let now = Date()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let expired = self.items.filter {
                !$0.isPinned && now.timeIntervalSince($0.timestamp) > seconds
            }
            guard !expired.isEmpty else { return }
            withAnimation {
                self.items.removeAll {
                    !$0.isPinned && now.timeIntervalSince($0.timestamp) > seconds
                }
            }
            for item in expired { self.deleteBackingFiles(for: item) }
            self.pruneOrphanFiles()
            self.saveData()
        }
    }

    private var lastChangeCount = NSPasteboard.general.changeCount
    private let monitorQueue = DispatchQueue(label: "com.glint.monitor", qos: .utility)
    private let saveQueue = DispatchQueue(label: "com.glint.save", qos: .background)
    private var pollTimer: DispatchSourceTimer?
    private var cleanupTimer: DispatchSourceTimer?

    let cacheFolder: URL = {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appPath = paths[0].appendingPathComponent("Glint/Cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: appPath, withIntermediateDirectories: true)
        return appPath
    }()

    /// Pre-migration cache location (`Application Support/GlintCache`). Kept for
    /// fallback reads; files are moved to `cacheFolder` on launch.
    let legacyCacheFolder: URL = {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent("GlintCache", isDirectory: true)
    }()

    /// Move any files left in the old `GlintCache` folder into the new `Glint/Cache`.
    /// This repairs image previews for history created before the folder move.
    private func migrateLegacyCache() {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: legacyCacheFolder.path, isDirectory: &isDir), isDir.boolValue
        else { return }
        guard let files = try? fm.contentsOfDirectory(
            at: legacyCacheFolder, includingPropertiesForKeys: nil) else { return }
        guard !files.isEmpty else {
            try? fm.removeItem(at: legacyCacheFolder)
            return
        }
        var moved = 0
        for src in files {
            let dst = cacheFolder.appendingPathComponent(src.lastPathComponent)
            if fm.fileExists(atPath: dst.path) {
                // Already migrated (e.g. duplicate launch); drop the stale copy.
                try? fm.removeItem(at: src)
                continue
            }
            do {
                try fm.moveItem(at: src, to: dst)
                moved += 1
            } catch {
                // Fall back to copy+delete so we don't lose user data on cross-volume moves.
                if (try? fm.copyItem(at: src, to: dst)) != nil {
                    try? fm.removeItem(at: src)
                    moved += 1
                }
            }
        }
        if let remaining = try? fm.contentsOfDirectory(atPath: legacyCacheFolder.path),
            remaining.isEmpty
        {
            try? fm.removeItem(at: legacyCacheFolder)
        }
        #if DEBUG
            print("Glint: migrated \(moved) legacy cache files")
        #endif
    }

    /// JSON history file (migrated off UserDefaults which isn't meant for large blobs).
    var storeURL: URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let dir = paths[0].appendingPathComponent("Glint", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private init() {
        migrateLegacyCache()
        loadData()
        if ignoredApps.isEmpty {
            ignoredApps = defaultIgnoredApps
        }
        startMonitoring()
        enforceLimit()
        pruneOrphanFiles()
    }

    deinit {
        pollTimer?.cancel()
        cleanupTimer?.cancel()
    }

    func enforceLimit() {
        let limit = UserDefaults.standard.integer(forKey: "historyLimit")
        let actualLimit = limit > 0 ? limit : 500

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Single-pass partition: pinned always kept, unpinned truncated to limit.
            let pinned = self.items.filter { $0.isPinned }
            var unpinned = self.items.filter { !$0.isPinned }
            guard unpinned.count > actualLimit else { return }
            // items are kept newest-first; drop the tail.
            let dropped = Array(unpinned.suffix(unpinned.count - actualLimit))
            unpinned = Array(unpinned.prefix(actualLimit))
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                self.items = pinned + unpinned
                self.sortItems()
            }
            for item in dropped { self.deleteBackingFiles(for: item) }
            self.saveData()
        }
    }

    func resetIgnoredApps() {
        ignoredApps = defaultIgnoredApps
        saveData()
    }

    private func startMonitoring() {
        // Poll timer (clipboard has no push API; changeCount polling is standard).
        let poll = DispatchSource.makeTimerSource(queue: monitorQueue)
        poll.schedule(deadline: .now() + 0.5, repeating: 0.5)
        poll.setEventHandler { [weak self] in self?.check() }
        poll.resume()
        pollTimer = poll

        // Background cleanup monitor (every hour).
        let cleanup = DispatchSource.makeTimerSource(queue: monitorQueue)
        cleanup.schedule(deadline: .now() + 3600, repeating: 3600)
        cleanup.setEventHandler { [weak self] in self?.cleanupHistory() }
        cleanup.resume()
        cleanupTimer = cleanup

        // Immediate cleanup on start
        cleanupHistory()
    }

    func check() {
        if isPaused { return }
        let pb = NSPasteboard.general
        if pb.changeCount == lastChangeCount { return }

        if let types = pb.types {
            let sensitiveTypes = [
                "org.nspasteboard.ConcealedType",
                "com.agilebits.onepassword",
                "org.nspasteboard.TransientType",
                "org.nspasteboard.AutoGeneratedType",
                "com.typeit4me.clipping",
                "de.petermaurer.popclip.no-record",
                "Pasteboard Type Password",
                "PasswordPboardType",
                "com.apple.mobilesafari.private",
                "com.brave.browser.private",
                "org.mozilla.firefox.private",
                "com.google.chrome.private",
                "com.apple.Safari.Stay-Private",
            ]
            for type in sensitiveTypes {
                if types.contains(NSPasteboard.PasteboardType(type)) {
                    lastChangeCount = pb.changeCount
                    return
                }
            }
        }

        lastChangeCount = pb.changeCount
        var newItem: ClipboardItem?
        let frontApp = NSWorkspace.shared.frontmostApplication

        if let bid = frontApp?.bundleIdentifier, ignoredApps.contains(bid) { return }

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
            !urls.isEmpty
        {
            let fileURLs = urls.filter { $0.isFileURL }
            if let first = fileURLs.first {
                let desc =
                    fileURLs.count == 1
                    ? first.lastPathComponent
                    : "\(first.lastPathComponent) and \(fileURLs.count - 1) more"
                var imgName: String? = nil
                var origName: String? = nil
                if fileURLs.count == 1, let type = UTType(filenameExtension: first.pathExtension),
                    type.conforms(to: .image)
                {
                    if let img = NSImage(contentsOf: first) {
                        if let saved = saveThumbnail(img) {
                            imgName = saved.thumb
                            origName = saved.original
                        }
                    }
                }
                newItem = ClipboardItem(
                    text: String(desc.prefix(maxStoredTextLength)), type: .file, timestamp: Date(),
                    sourceApp: frontApp?.localizedName,
                    bundleID: frontApp?.bundleIdentifier, isPinned: false, fileURLs: fileURLs,
                    imageFileName: imgName, originalImageName: origName)
            }
        }

        if newItem == nil, let img = NSImage(pasteboard: pb) {
            var imgName: String? = nil
            var origName: String? = nil
            if let saved = saveThumbnail(img) {
                imgName = saved.thumb
                origName = saved.original
            }
            newItem = ClipboardItem(
                text: "Image (\(Int(img.size.width))x\(Int(img.size.height)))", type: .image,
                timestamp: Date(), sourceApp: frontApp?.localizedName,
                bundleID: frontApp?.bundleIdentifier, isPinned: false, fileURLs: nil,
                imageFileName: imgName, originalImageName: origName)
        }

        if newItem == nil, let str = pb.string(forType: .string) {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let stored =
                    trimmed.count > maxStoredTextLength
                    ? String(trimmed.prefix(maxStoredTextLength)) : trimmed
                newItem = ClipboardItem(
                    text: stored, type: isURLString(trimmed) ? .url : .text, timestamp: Date(),
                    sourceApp: frontApp?.localizedName, bundleID: frontApp?.bundleIdentifier,
                    isPinned: false, fileURLs: nil, imageFileName: nil, originalImageName: nil)
            }
        }

        if let item = newItem {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.hapticFeedback()

                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    // Smart De-duplication
                    let existingIdx = self.items.firstIndex { existing in
                        if existing.type != item.type { return false }
                        if item.type == .file {
                            return existing.fileURLs == item.fileURLs
                        } else {
                            return existing.text == item.text
                        }
                    }

                    var wasPinned = false
                    if let idx = existingIdx {
                        wasPinned = self.items[idx].isPinned
                        // If the dupe had backing files that the new item doesn't reuse, clean them.
                        let old = self.items[idx]
                        if old.imageFileName != item.imageFileName
                            || old.originalImageName != item.originalImageName
                        {
                            self.deleteBackingFiles(for: old)
                        }
                        self.items.remove(at: idx)
                    }

                    var finalItem = item
                    finalItem.isPinned = wasPinned

                    self.items.insert(finalItem, at: 0)
                    self.sortItems()

                    self.enforceLimit()
                }
                self.saveData()
            }
        }
    }

    /// Thread-safe thumbnail generation (CoreGraphics/ImageIO only, no lockFocus).
    private func saveThumbnail(_ image: NSImage) -> (thumb: String, original: String)? {
        guard let cg = cgImage(from: image) else { return nil }
        let originalName = "\(UUID().uuidString)_orig.png"
        let thumbName = "\(UUID().uuidString)_thumb.png"

        let originalUrl = cacheFolder.appendingPathComponent(originalName)
        let thumbUrl = cacheFolder.appendingPathComponent(thumbName)

        guard let originalPNG = pngData(from: cg) else { return nil }
        do {
            try originalPNG.write(to: originalUrl, options: .atomic)
        } catch {
            return nil
        }

        let thumbCG = scaledThumbnailCG(from: cg, maxWidth: thumbnailMaxPixelWidth) ?? cg
        guard let thumbPNG = pngData(from: thumbCG) else {
            try? FileManager.default.removeItem(at: originalUrl)
            return nil
        }
        do {
            try thumbPNG.write(to: thumbUrl, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: originalUrl)
            return nil
        }
        return (thumb: thumbName, original: originalName)
    }

    func deleteBackingFiles(for item: ClipboardItem) {
        SharedCaches.thumbnails.removeObject(forKey: (item.imageFileName ?? "") as NSString)
        SharedCaches.thumbnails.removeObject(forKey: (item.originalImageName ?? "") as NSString)
        if let f = item.imageFileName {
            try? FileManager.default.removeItem(at: cacheFolder.appendingPathComponent(f))
            try? FileManager.default.removeItem(at: legacyCacheFolder.appendingPathComponent(f))
        }
        if let f = item.originalImageName {
            try? FileManager.default.removeItem(at: cacheFolder.appendingPathComponent(f))
            try? FileManager.default.removeItem(at: legacyCacheFolder.appendingPathComponent(f))
        }
    }

    /// Remove cached PNGs with no referencing item (fixes historical disk leak).
    func pruneOrphanFiles() {
        saveQueue.async { [weak self] in
            guard let self = self else { return }
            let referenced: Set<String> = Set(
                self.items.flatMap { [$0.imageFileName, $0.originalImageName].compactMap { $0 } })
            guard
                let files = try? FileManager.default.contentsOfDirectory(atPath: self.cacheFolder
                    .path)
            else { return }
            for file in files where (file.hasSuffix("_thumb.png") || file.hasSuffix("_orig.png"))
                && !referenced.contains(file)
            {
                try? FileManager.default.removeItem(
                    at: self.cacheFolder.appendingPathComponent(file))
            }
        }
    }

    func clearHistory() {
        hapticFeedback()
        let removed: [ClipboardItem]
        removed = items.filter { !$0.isPinned }
        withAnimation { self.items.removeAll { !$0.isPinned } }
        for item in removed { deleteBackingFiles(for: item) }
        saveData()
    }

    func deleteItem(_ item: ClipboardItem) {
        hapticFeedback()
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            _ = withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                items.remove(at: idx)
            }
            deleteBackingFiles(for: item)
            saveData()
        }
    }

    func togglePin(for item: ClipboardItem) {
        hapticFeedback()
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                items[idx].isPinned.toggle()
                sortItems()
            }
            saveData()
        }
    }

    private func sortItems() {
        items.sort { (lhs, rhs) in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.timestamp > rhs.timestamp
        }
    }

    private func hapticFeedback() {
        let isEnabled = UserDefaults.standard.object(forKey: "enableHaptics") as? Bool ?? true
        if isEnabled {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }

    func playSound() {
        let isEnabled = UserDefaults.standard.object(forKey: "enableSounds") as? Bool ?? true
        if isEnabled {
            if let sound = NSSound(named: "Pop") {
                sound.play()
            } else {
                NSSound.beep()
            }
        }
    }
    func select(_ item: ClipboardItem) {
        copyToClipboard(item, hideApp: true)
    }

    func copyToClipboard(_ item: ClipboardItem, hideApp: Bool = false) {
        hapticFeedback()
        let pb = NSPasteboard.general
        pb.clearContents()
        if let urls = item.fileURLs {
            pb.writeObjects(urls as [NSURL])
        } else if item.type == .image || item.originalImageName != nil || item.imageFileName != nil {
            // Lossless-ish restore: write original PNG bytes + TIFF so targets get real image types.
            var wrote = false
            if let name = item.originalImageName ?? item.imageFileName {
                let candidates = [
                    cacheFolder.appendingPathComponent(name),
                    legacyCacheFolder.appendingPathComponent(name),
                ]
                let url = candidates.first(where: {
                    FileManager.default.fileExists(atPath: $0.path)
                }) ?? candidates[0]
                if let data = try? Data(contentsOf: url) {
                    pb.setData(data, forType: .png)
                    wrote = true
                }
                if let tiff = NSImage(contentsOf: url)?.tiffRepresentation {
                    pb.setData(tiff, forType: .tiff)
                    wrote = true
                }
            }
            if !wrote {
                pb.setString(item.text, forType: .string)
            }
        } else {
            pb.setString(item.text, forType: .string)
        }
        self.lastChangeCount = pb.changeCount

        if hideApp {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.hide(nil)
            }
        }
    }

    func saveData() {
        let itemsToSave = self.items
        let ignoredToSave = self.ignoredApps
        let url = self.storeURL
        saveQueue.async {
            if let data = try? JSONEncoder().encode(itemsToSave) {
                try? data.write(to: url, options: .atomic)
            }
            UserDefaults.standard.set(ignoredToSave, forKey: "ignoredApps")
        }
    }

    func loadData() {
        // Prefer file store; one-time migrate legacy UserDefaults blob.
        if let data = try? Data(contentsOf: storeURL),
            let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data)
        {
            let items = decoded
            DispatchQueue.main.async {
                self.items = items
                self.sortItems()
            }
        } else if let data = UserDefaults.standard.data(forKey: "savedGlintItems"),
            let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data)
        {
            let items = decoded
            DispatchQueue.main.async {
                self.items = items
                self.sortItems()
            }
            // Migrate to file, drop legacy key.
            saveQueue.async { [storeURL] in
                if let fresh = try? JSONEncoder().encode(items) {
                    try? fresh.write(to: storeURL, options: .atomic)
                }
                UserDefaults.standard.removeObject(forKey: "savedGlintItems")
            }
        }
        if let savedIgnored = UserDefaults.standard.stringArray(forKey: "ignoredApps") {
            DispatchQueue.main.async { self.ignoredApps = savedIgnored }
        }
    }
}

// MARK: - Floating Panel
class GlintPanel: NSPanel {
    init(contentRect: NSRect, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(
            contentRect: contentRect,
            styleMask: [.resizable, .fullSizeContentView, .titled, .nonactivatingPanel],
            backing: backing, defer: flag)
        self.isFloatingPanel = true
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
        self.hasShadow = true
        self.backgroundColor = .clear
        self.setFrameAutosaveName("GlintPanel")
        self.minSize = NSSize(width: 550, height: 360)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Let the very first click act on a control even when Glint was summoned while
    /// another app was active (without this, that click only activates the panel).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Attached Preview Panel
/// Separate window docked beside the main list. The main window never changes size,
/// so the list can never stretch — only this panel fades/slides in and out.
class GlintPreviewPanel: NSPanel {
    static let width: CGFloat = 300

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 480),
            styleMask: [.fullSizeContentView, .titled, .nonactivatingPanel],
            backing: .buffered, defer: false)
        self.isFloatingPanel = true
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
        self.hasShadow = true
        self.backgroundColor = .clear
        self.minSize = NSSize(width: Self.width, height: 200)
        self.maxSize = NSSize(width: Self.width, height: 10_000)
        self.isReleasedWhenClosed = false
        // No autosave: position is always computed from the main window.
    }
    // Key-able (like the main panel) so ⌘C on selected preview text works.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Let the very first click act on a control even when Glint was summoned while
    /// another app was active (without this, that click only activates the panel).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Return keyboard focus to the main list window (no-op if it isn't visible).
func focusGlintMain() {
    if let main = NSApp.windows.first(where: { $0 is GlintPanel }), main.isVisible {
        main.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Floating HUD for Notifications
struct HUDView: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
    }
}

class HUDPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 40),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.isFloatingPanel = true
        self.level = .statusBar
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: GlintPanel?
    var previewWindow: GlintPreviewPanel?
    var hudWindow: HUDPanel?
    private var hudTimer: Timer?
    private var didInitialPosition = false
    private var selectionCancellable: AnyCancellable?
    private var windowObservers: [NSObjectProtocol] = []
    private var previewGeneration = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        registerHotKey()

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("HotKeyChanged"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.registerHotKey()
        }

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("GlintShowHUD"), object: nil, queue: .main
        ) { [weak self] notification in
            if let message = notification.object as? String {
                self?.showHUD(message: message)
            }
        }

        window = GlintPanel(
            contentRect: NSRect(x: 0, y: 0, width: 550, height: 480), backing: .buffered,
            defer: false)
        // One-time normalize: pre-auto-width installs autosaved 850pt. Shrink to the
        // fixed 550pt list width (keeping center) so no empty gap remains.
        if let main = window, abs(main.frame.width - 550) > 1 {
            var frame = main.frame
            frame.origin.x += (frame.width - 550) / 2
            frame.size.width = 550
            main.setFrame(frame, display: false)
        }
        // setFrameAutosaveName restores the last position; only center on very first launch.
        if let savedFrame = window?.frame, savedFrame.origin.x != 0 || savedFrame.origin.y != 0 {
            didInitialPosition = true
        } else {
            window?.center()
            didInitialPosition = true
        }
        window?.contentView = NSHostingView(
            rootView: ContentView().environmentObject(GlintMonitor.shared))

        // Attached preview panel: docked beside main, follows it as a child window.
        previewWindow = GlintPreviewPanel()
        previewWindow?.contentView = NSHostingView(
            rootView: ContentView.PreviewHostView().environmentObject(GlintMonitor.shared))
        if let main = window, let preview = previewWindow {
            main.addChildWindow(preview, ordered: .above)
        }

        // Preview visibility follows selection (fade/slide handled inside).
        selectionCancellable = GlintMonitor.shared.$selectedPreviewID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in self?.syncPreviewVisibility(selectedID: id) }

        // Keep preview docked + height-matched while the main window is resized.
        if let main = window {
            windowObservers.append(
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification, object: main, queue: .main
                ) { [weak self] _ in self?.followMainWindow() })
        }

        // Don't show immediately on finish, wait for hotkey or manual trigger
        // showGlint()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.previewGeneration += 1
            self?.window?.orderOut(nil)
            self?.previewWindow?.orderOut(nil)
        }
    }

    // MARK: - Attached preview window

    private func previewFrame(for main: NSWindow) -> NSRect {
        let gap: CGFloat = 8
        let w = GlintPreviewPanel.width
        var frame = NSRect(
            x: main.frame.maxX + gap, y: main.frame.minY,
            width: w, height: main.frame.height)
        if let screen = main.screen ?? NSScreen.main {
            let vis = screen.visibleFrame
            if frame.maxX > vis.maxX {
                // No room on the right — dock to the left instead.
                frame.origin.x = main.frame.minX - gap - w
            }
            if frame.height > vis.height { frame.size.height = vis.height }
            if frame.minY < vis.minY { frame.origin.y = vis.minY }
            if frame.maxY > vis.maxY { frame.origin.y = vis.maxY - frame.height }
        }
        return frame
    }

    private func followMainWindow() {
        guard let main = window, let preview = previewWindow, preview.isVisible else { return }
        preview.setFrame(previewFrame(for: main), display: true)
    }

    private func syncPreviewVisibility(selectedID: UUID?) {
        guard window != nil, previewWindow != nil else { return }
        // Defensive: selection pointing at a deleted item → clear + hide.
        if let id = selectedID,
            GlintMonitor.shared.items.first(where: { $0.id == id }) == nil
        {
            GlintMonitor.shared.selectedPreviewID = nil
            hidePreviewWindow()
            return
        }
        if selectedID != nil, window?.isVisible == true {
            showPreviewWindow()
        } else {
            hidePreviewWindow()
        }
    }

    private func showPreviewWindow() {
        guard let main = window, let preview = previewWindow else { return }
        previewGeneration += 1
        let gen = previewGeneration
        let final = previewFrame(for: main)
        if preview.isVisible {
            // Already open (e.g. content swap) — just glide to the docked position.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                preview.animator().setFrame(final, display: true)
            }
            return
        }
        var start = final
        start.origin.x += 12
        preview.setFrame(start, display: false)
        preview.alphaValue = 0
        preview.orderFront(nil)
        NSAnimationContext.runAnimationGroup(
            { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                preview.animator().setFrame(final, display: true)
                preview.animator().alphaValue = 1
            },
            completionHandler: { [weak self] in
                guard gen == self?.previewGeneration else { return }
                preview.alphaValue = 1
            })
    }

    private func hidePreviewWindow() {
        guard let preview = previewWindow, preview.isVisible else { return }
        previewGeneration += 1
        let gen = previewGeneration
        NSAnimationContext.runAnimationGroup(
            { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                preview.animator().alphaValue = 0
            },
            completionHandler: { [weak self] in
                guard gen == self?.previewGeneration else { return }
                preview.orderOut(nil)
                preview.alphaValue = 1
            })
    }

    func showHUD(message: String) {
        hudTimer?.invalidate()
        if hudWindow == nil {
            hudWindow = HUDPanel()
        }

        let view = HUDView(message: message).fixedSize()
        let hostingView = NSHostingView(rootView: view)

        // Use intrinsicContentSize for better measurement of SwiftUI views
        var size = hostingView.intrinsicContentSize
        size.width += 10  // Extra buffer for shadows/padding

        hudWindow?.setFrame(NSRect(origin: .zero, size: size), display: true)
        hudWindow?.contentView = hostingView

        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            let x = screenRect.origin.x + (screenRect.width - size.width) / 2
            let y = screenRect.origin.y + 100
            hudWindow?.setFrameOrigin(NSPoint(x: x, y: y))
        }

        hudWindow?.alphaValue = 0
        hudWindow?.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            hudWindow?.animator().alphaValue = 1
        }

        hudTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = 0.4
                    self?.hudWindow?.animator().alphaValue = 0
                },
                completionHandler: {
                    self?.hudWindow?.orderOut(nil)
                })
        }
    }

    func registerHotKey() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            let keyCode = UserDefaults.standard.object(forKey: "hotkeyCode") as? UInt32 ?? 49
            let modifiers =
                UserDefaults.standard.object(forKey: "hotkeyModifiers") as? UInt32
                ?? UInt32(optionKey)

            GlobalHotKeyManager.shared.register(id: 1, keyCode: keyCode, modifiers: modifiers) {
                [weak self] in
                DispatchQueue.main.async { self?.showGlint() }
            }

            let pauseKeyCode =
                UserDefaults.standard.object(forKey: "pauseHotkeyCode") as? UInt32 ?? 35
            let pauseModifiers =
                UserDefaults.standard.object(forKey: "pauseHotkeyModifiers") as? UInt32
                ?? UInt32(optionKey | cmdKey)

            GlobalHotKeyManager.shared.register(
                id: 2, keyCode: pauseKeyCode, modifiers: pauseModifiers
            ) {
                DispatchQueue.main.async {
                    GlintMonitor.shared.isPaused.toggle()
                    GlintMonitor.shared.playSound()
                    let message =
                        GlintMonitor.shared.isPaused ? "Monitoring Paused" : "Monitoring Resumed"
                    NotificationCenter.default.post(
                        name: NSNotification.Name("GlintShowHUD"), object: message)
                }
            }
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    @objc func showGlint() {
        NSApp.activate(ignoringOtherApps: true)
        guard let window else { return }
        // Remember position via autosave name; only re-center if off-screen (e.g. display removed).
        if !didInitialPosition {
            window.center()
            didInitialPosition = true
        } else {
            let visible = NSScreen.screens.contains { screen in
                screen.frame.intersects(window.frame)
            }
            if !visible {
                // Prefer the screen with the mouse for multi-monitor setups.
                if let mouseScreen = NSScreen.screens.first(where: {
                    NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
                }) {
                    let frame = window.frame
                    let x = mouseScreen.frame.midX - frame.width / 2
                    let y = mouseScreen.frame.midY - frame.height / 2
                    window.setFrameOrigin(NSPoint(x: x, y: y))
                } else {
                    window.center()
                }
            }
        }
        window.makeKeyAndOrderFront(nil)
        syncPreviewVisibility(selectedID: GlintMonitor.shared.selectedPreviewID)
    }
}

@main
struct GlintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("hotkeyCode") private var hotkeyCode: Int = 49
    @AppStorage("hotkeyModifiers") private var hotkeyModifiers: Int = Int(optionKey)

    @AppStorage("pauseHotkeyCode") private var pauseHotkeyCode: Int = 35  // 'P'
    @AppStorage("pauseHotkeyModifiers") private var pauseHotkeyModifiers: Int = Int(
        optionKey | cmdKey)

    var body: some Scene {
        MenuBarExtra {
            Button("Show Glint") {
                appDelegate.showGlint()
            }
            .keyboardShortcut(
                KeyEquivalent(Character(keyCodeToKeyEquivalent(UInt32(hotkeyCode)))),
                modifiers: carbonToNSEventModifiers(UInt32(hotkeyModifiers)))

            SettingsLink {
                Text("Settings...")
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button("Quit Glint") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        } label: {
            if let nsImage = NSImage(named: "MenuBarIcon") {
                let _ = nsImage.isTemplate = true
                let _ = nsImage.size = NSSize(width: 18, height: 18)
                Image(nsImage: nsImage)
            } else {
                Image(systemName: "sparkles")
            }
        }

        Settings {
            SettingsView()
        }
    }
}
