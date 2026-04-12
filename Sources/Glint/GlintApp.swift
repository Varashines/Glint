import Foundation
import Combine
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Carbon

// MARK: - Global HotKey Manager
class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    func register(keyCode: UInt32, modifiers: UInt32, block: @escaping () -> Void) {
        unregister()
        
        let hotKeyID = EventHotKeyID(signature: OSType(0x474C4E54), id: 1) // "GLNT"
        let eventType = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))]
        
        let ptr = UnsafeMutableRawPointer(Unmanaged.passRetained(block as AnyObject).toOpaque())
        
        let handler: EventHandlerUPP = { (_, event, userData) -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let block = Unmanaged<AnyObject>.fromOpaque(userData).takeUnretainedValue() as! () -> Void
            block()
            return OSStatus(noErr)
        }
        
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, eventType, ptr, &eventHandler)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

// MARK: - Glint Data Model
enum ContentType: String, Codable {
    case text = "TEXT", url = "URL", file = "FILE", image = "IMAGE"
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
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).flatMap { NSWorkspace.shared.icon(forFile: $0.path) }
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
        case id, text, type, timestamp, sourceApp, bundleID, isPinned, fileURLs, imageFileName, originalImageName
    }
}

// MARK: - Glint Engine
class GlintMonitor: ObservableObject {
    static let shared = GlintMonitor()
    
    @Published var items: [ClipboardItem] = []
    @Published var ignoredApps: [String] = []
    
    enum CleanupPeriod: String, CaseIterable, Codable {
        case oneDay = "1 Day", oneWeek = "1 Week", thirtyDays = "30 Days", forever = "Forever"
        
        var seconds: TimeInterval? {
            switch self {
            case .oneDay: return 86400
            case .oneWeek: return 604800
            case .thirtyDays: return 2592000
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
        "com.mseven.trezorbridge"
    ]
    
    func cleanupHistory() {
        let periodRaw = UserDefaults.standard.string(forKey: "cleanupPeriod") ?? "Forever"
        guard let period = CleanupPeriod(rawValue: periodRaw), let seconds = period.seconds else { return }
        
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
        try? FileManager.default.createDirectory(atPath: appPath.path, withIntermediateDirectories: true)
        return appPath
    }()
    
    private init() {
        loadData()
        if ignoredApps.isEmpty {
            ignoredApps = defaultIgnoredApps
        }
        startMonitoring()
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
        let pb = NSPasteboard.general
        if pb.changeCount == lastChangeCount { return }
        
        if let types = pb.types {
            let sensitiveTypes = [
                "org.nspasteboard.ConcealedType", 
                "com.agilebits.onepassword",
                "org.nspasteboard.TransientType",
                "org.nspasteboard.AutoGeneratedType"
            ]
            for type in sensitiveTypes {
                if types.contains(NSPasteboard.PasteboardType(type)) {
                    lastChangeCount = pb.changeCount; return
                }
            }
        }
        
        lastChangeCount = pb.changeCount
        var newItem: ClipboardItem?
        let frontApp = NSWorkspace.shared.frontmostApplication
        
        if let bid = frontApp?.bundleIdentifier, ignoredApps.contains(bid) { return }

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            let fileURLs = urls.filter { $0.isFileURL }
            if let first = fileURLs.first {
                let desc = fileURLs.count == 1 ? first.lastPathComponent : "\(first.lastPathComponent) and \(fileURLs.count - 1) more"
                var imgName: String? = nil
                var origName: String? = nil
                if fileURLs.count == 1, let type = UTType(filenameExtension: first.pathExtension), type.conforms(to: .image) {
                    if let img = NSImage(contentsOf: first) {
                        if let saved = saveThumbnail(img) {
                            imgName = saved.thumb
                            origName = saved.original
                        }
                    }
                }
                newItem = ClipboardItem(text: desc, type: .file, timestamp: Date(), sourceApp: frontApp?.localizedName, bundleID: frontApp?.bundleIdentifier, isPinned: false, fileURLs: fileURLs, imageFileName: imgName, originalImageName: origName)
            }
        }
        
        if newItem == nil, let img = NSImage(pasteboard: pb) {
            var imgName: String? = nil
            var origName: String? = nil
            if let saved = saveThumbnail(img) {
                imgName = saved.thumb
                origName = saved.original
            }
            newItem = ClipboardItem(text: "Image (\(Int(img.size.width))x\(Int(img.size.height)))", type: .image, timestamp: Date(), sourceApp: frontApp?.localizedName, bundleID: frontApp?.bundleIdentifier, isPinned: false, fileURLs: nil, imageFileName: imgName, originalImageName: origName)
        }
        
        if newItem == nil, let str = pb.string(forType: .string) {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let isURL = URL(string: trimmed)?.scheme != nil && (trimmed.hasPrefix("http") || trimmed.hasPrefix("https"))
                newItem = ClipboardItem(text: trimmed, type: isURL ? .url : .text, timestamp: Date(), sourceApp: frontApp?.localizedName, bundleID: frontApp?.bundleIdentifier, isPinned: false, fileURLs: nil, imageFileName: nil, originalImageName: nil)
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
                            // For files, compare the actual URLs, not just the filename
                            return existing.fileURLs == item.fileURLs
                        } else {
                            // For text/urls/images, compare the content/text
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
                    
                    let limit = UserDefaults.standard.integer(forKey: "historyLimit")
                    let actualLimit = limit > 0 ? limit : 100
                    while self.items.filter({ !$0.isPinned }).count > actualLimit {
                        if let lastIdx = self.items.lastIndex(where: { !$0.isPinned }) { self.items.remove(at: lastIdx) } else { break }
                    }
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
        
        // Save Original
        if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: originalUrl)
        } else { return nil }
        
        // Save Thumbnail
        let targetSize = NSSize(width: 200, height: 200 * (image.size.height / image.size.width))
        let newImage = NSImage(size: targetSize)
        newImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: targetSize), from: .zero, operation: .copy, fraction: 1.0)
        newImage.unlockFocus()
        if let tiff = newImage.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
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
        items.sort { (lhs, rhs) -> Bool in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }
            // Within categories, sort by most recent
            return lhs.timestamp > rhs.timestamp
        }
    }
    
    /// Provides subtle haptic feedback using the macOS Taptic Engine
    private func hapticFeedback() {
        let isEnabled = UserDefaults.standard.object(forKey: "enableHaptics") as? Bool ?? true
        if isEnabled {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }
    
    /// Plays a subtle system sound for audio confirmation
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
        if let urls = item.fileURLs { pb.writeObjects(urls as [NSURL]) }
        else if let original = item.originalImage { pb.writeObjects([original]) }
        else if let thumb = item.thumbnail { pb.writeObjects([thumb]) }
        else { pb.setString(item.text, forType: .string) }
        self.lastChangeCount = pb.changeCount
        
        // Delay hide slightly to ensure sound/haptics are felt/heard
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
           let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data) {
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
        super.init(contentRect: contentRect, styleMask: [.resizable, .fullSizeContentView, .titled, .nonactivatingPanel], backing: backing, defer: flag)
        self.isFloatingPanel = true; self.level = .floating; self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; self.titleVisibility = .hidden; self.titlebarAppearsTransparent = true; self.isMovableByWindowBackground = true; self.hasShadow = true; self.backgroundColor = .clear
    }
    override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { true }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: GlintPanel?; var statusItem: NSStatusItem?
    
    private func applyRoundedCorners(to image: NSImage, radius: CGFloat) -> NSImage {
        let size = image.size
        let rect = NSRect(origin: .zero, size: size)
        let roundedImage = NSImage(size: size)
        
        roundedImage.lockFocus()
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.addClip()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        roundedImage.unlockFocus()
        
        return roundedImage
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            // Load the newly created image set from the bundle
            let originalIcon = Bundle.module.image(forResource: "MenuBarIcon")
                     ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Glint")

            if let icon = originalIcon {
                icon.size = NSSize(width: 18, height: 18)
                // Apply circular corners (radius = half of size for a circle, or a smaller value for rounded)
                let finalIcon = applyRoundedCorners(to: icon, radius: 4)
                finalIcon.isTemplate = false
                button.image = finalIcon
            }

            button.action = #selector(showGlint)
            button.target = self
        }

        setupMenu()

        // Register Global HotKey
        registerHotKey()

        // Listen for changes
        NotificationCenter.default.addObserver(forName: NSNotification.Name("HotKeyChanged"), object: nil, queue: .main) { [weak self] _ in
            self?.registerHotKey()
            self?.setupMenu()
        }

        window = GlintPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 450), backing: .buffered, defer: false)
        window?.center(); window?.contentView = NSHostingView(rootView: ContentView().environmentObject(GlintMonitor.shared)); showGlint()
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in NSApp.hide(nil) }
    }

    private func registerHotKey() {
        // Delay slightly to ensure UserDefaults have persisted if this is called from a notification
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let keyCode = UserDefaults.standard.object(forKey: "hotkeyCode") as? UInt32 ?? 49
            let modifiers = UserDefaults.standard.object(forKey: "hotkeyModifiers") as? UInt32 ?? UInt32(optionKey)
            
            GlobalHotKeyManager.shared.register(keyCode: keyCode, modifiers: modifiers) { [weak self] in
                DispatchQueue.main.async { self?.showGlint() }
            }
        }
    }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    private func setupMenu() {
        let keyCode = UserDefaults.standard.object(forKey: "hotkeyCode") as? UInt32 ?? 49
        let modifiers = UserDefaults.standard.object(forKey: "hotkeyModifiers") as? UInt32 ?? UInt32(optionKey)

        let mainMenu = NSMenu(); let appMenu = NSMenu()
        let showItem = NSMenuItem(title: "Show Glint", action: #selector(showGlint), keyEquivalent: keyCodeToKeyEquivalent(keyCode))
        showItem.keyEquivalentModifierMask = carbonToNSEventModifiers(modifiers)

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        let quitItem = NSMenuItem(title: "Quit Glint", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(showItem); appMenu.addItem(settingsItem); appMenu.addItem(NSMenuItem.separator()); appMenu.addItem(quitItem)
        let appMenuItem = NSMenuItem(); appMenuItem.submenu = appMenu; mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu; statusItem?.menu = appMenu
    }

    private func keyCodeToKeyEquivalent(_ keyCode: UInt32) -> String {
        switch keyCode {
        case 49: return " "
        case 36: return "\r"
        case 48: return "\t"
        default:
            // Use the saved hotkey text if available, or fallback to lowercase for menu bar
            if let savedText = UserDefaults.standard.string(forKey: "hotkeyText") {
                if savedText.count == 1 {
                    return savedText.lowercased()
                }
            }
            return "j" // Absolute fallback
        }
    }

    private func carbonToNSEventModifiers(_ carbonModifiers: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }    
    @objc func showGlint() { 
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil) 
    }
    @objc func showSettings() { window?.orderOut(nil); NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil); NSApp.activate(ignoringOtherApps: true) }
}

@main
struct GlintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { Settings { SettingsView() } }
}
