import AppKit
import Carbon
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

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
        RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
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
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: timestamp, relativeTo: Date())
    }

    var appIcon: NSImage? {
        guard let bundleID = bundleID else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).flatMap {
            NSWorkspace.shared.icon(forFile: $0.path)
        }
    }

    var thumbnail: NSImage? {
        guard let fileName = imageFileName else { return nil }
        let url = GlintMonitor.shared.cacheFolder.appendingPathComponent(fileName)
        return NSImage(contentsOf: url)
    }

    var originalImage: NSImage? {
        guard let fileName = originalImageName else { return nil }
        let url = GlintMonitor.shared.cacheFolder.appendingPathComponent(fileName)
        return NSImage(contentsOf: url)
    }

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
    @Published var isPaused: Bool = false {
        didSet {
            if !isPaused {
                // Sync change count on resume so we don't capture whatever is currently on the clipboard
                lastChangeCount = NSPasteboard.general.changeCount
            }
        }
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
            withAnimation {
                self.items.removeAll { item in
                    !item.isPinned && now.timeIntervalSince(item.timestamp) > seconds
                }
            }
            self.saveData()
        }
    }

    private var lastChangeCount = NSPasteboard.general.changeCount
    private let monitorQueue = DispatchQueue(label: "com.glint.monitor", qos: .default)
    private let saveQueue = DispatchQueue(label: "com.glint.save", qos: .background)

    let cacheFolder: URL = {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appPath = paths[0].appendingPathComponent("GlintCache")
        try? FileManager.default.createDirectory(
            atPath: appPath.path, withIntermediateDirectories: true)
        return appPath
    }()

    private init() {
        loadData()
        if ignoredApps.isEmpty {
            ignoredApps = defaultIgnoredApps
        }
        startMonitoring()
        enforceLimit()
    }

    func enforceLimit() {
        let limit = UserDefaults.standard.integer(forKey: "historyLimit")
        let actualLimit = limit > 0 ? limit : 500
        print("📊 Glint: Enforcing limit \(actualLimit) (Raw: \(limit))")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let unpinnedCount = self.items.filter { !$0.isPinned }.count
            if unpinnedCount > actualLimit {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    while self.items.filter({ !$0.isPinned }).count > actualLimit {
                        if let lastIdx = self.items.lastIndex(where: { !$0.isPinned }) {
                            self.items.remove(at: lastIdx)
                        } else {
                            break
                        }
                    }
                }
                self.saveData()
            }
        }
    }

    func resetIgnoredApps() {
        ignoredApps = defaultIgnoredApps
        saveData()
    }

    private func startMonitoring() {
        // Main clipboard monitor
        monitorQueue.async { [weak self] in
            let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
                self?.check()
            }
            RunLoop.current.add(timer, forMode: .common)
            RunLoop.current.run()
        }

        // Background cleanup monitor (every hour)
        monitorQueue.async { [weak self] in
            let timer = Timer(timeInterval: 3600, repeats: true) { _ in
                self?.cleanupHistory()
            }
            RunLoop.current.add(timer, forMode: .common)
            RunLoop.current.run()
        }

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
                    text: desc, type: .file, timestamp: Date(), sourceApp: frontApp?.localizedName,
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
                let isURL =
                    URL(string: trimmed)?.scheme != nil
                    && (trimmed.hasPrefix("http") || trimmed.hasPrefix("https"))
                newItem = ClipboardItem(
                    text: trimmed, type: isURL ? .url : .text, timestamp: Date(),
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

    private func saveThumbnail(_ image: NSImage) -> (thumb: String, original: String)? {
        let originalName = "\(UUID().uuidString)_orig.png"
        let thumbName = "\(UUID().uuidString)_thumb.png"

        let originalUrl = cacheFolder.appendingPathComponent(originalName)
        let thumbUrl = cacheFolder.appendingPathComponent(thumbName)

        if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        {
            try? png.write(to: originalUrl)
        } else {
            return nil
        }

        let targetSize = NSSize(width: 200, height: 200 * (image.size.height / image.size.width))
        let newImage = NSImage(size: targetSize)
        newImage.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: targetSize), from: .zero, operation: .copy,
            fraction: 1.0)
        newImage.unlockFocus()
        if let tiff = newImage.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        {
            try? png.write(to: thumbUrl)
            return (thumb: thumbName, original: originalName)
        }
        return nil
    }

    func clearHistory() {
        hapticFeedback()
        withAnimation { self.items.removeAll { !$0.isPinned } }
        saveData()
    }

    func deleteItem(_ item: ClipboardItem) {
        hapticFeedback()
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            _ = withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                items.remove(at: idx)
            }
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
        hapticFeedback()
        let pb = NSPasteboard.general
        pb.clearContents()
        if let urls = item.fileURLs {
            pb.writeObjects(urls as [NSURL])
        } else if let original = item.originalImage {
            pb.writeObjects([original])
        } else if let thumb = item.thumbnail {
            pb.writeObjects([thumb])
        } else {
            pb.setString(item.text, forType: .string)
        }
        self.lastChangeCount = pb.changeCount

        // Standard hide for clipboard managers
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.hide(nil)
        }
    }

    func saveData() {
        let itemsToSave = self.items
        let ignoredToSave = self.ignoredApps
        saveQueue.async {
            if let data = try? JSONEncoder().encode(itemsToSave) {
                UserDefaults.standard.set(data, forKey: "savedGlintItems")
            }
            UserDefaults.standard.set(ignoredToSave, forKey: "ignoredApps")
        }
    }

    func loadData() {
        if let data = UserDefaults.standard.data(forKey: "savedGlintItems"),
            let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data)
        {
            DispatchQueue.main.async {
                self.items = decoded
                self.sortItems()
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
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
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
    var hudWindow: HUDPanel?
    private var hudTimer: Timer?

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
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 450), backing: .buffered,
            defer: false)
        window?.center()
        window?.contentView = NSHostingView(
            rootView: ContentView().environmentObject(GlintMonitor.shared))

        // Don't show immediately on finish, wait for hotkey or manual trigger
        // showGlint()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.window?.orderOut(nil)
        }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
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
        window?.center()
        window?.makeKeyAndOrderFront(nil)
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
