import SwiftUI
import ServiceManagement
import Carbon

struct SettingsView: View {
    @AppStorage("historyLimit") private var historyLimit = 100
    @AppStorage("cleanupPeriod") private var cleanupPeriod = "Forever"
    @AppStorage("enableHaptics") private var enableHaptics = true
    @AppStorage("enableSounds") private var enableSounds = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var tempLimitString: String = ""
    @State private var toastMessage: String? = nil

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView {
                generalTab
                    .tabItem { Label("General", systemImage: "gearshape") }
                
                ignoredAppsTab
                    .tabItem { Label("Blocked Apps", systemImage: "nosign") }
                
                shortcutsTab
                    .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            }
            .frame(width: 440, height: 440)
            .background(WindowAccessor { window in
                // Elevate settings window level so it stays on top of the main floating app
                window.level = .floating
                window.isMovableByWindowBackground = true
                window.makeKeyAndOrderFront(nil)
            })
            
            if let message = toastMessage {
                Text(message)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.accentColor)
                    .cornerRadius(20)
                    .shadow(radius: 4)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear {
            tempLimitString = String(historyLimit)
        }
    }

    private func showToast(_ message: String) {
        withAnimation(.spring()) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation {
                if toastMessage == message {
                    toastMessage = nil
                }
            }
        }
    }

    private func validateLimit() {
        if let value = Int(tempLimitString) {
            if value > 500 {
                historyLimit = 500
                showToast("Capped at max 500")
            } else if value < 10 {
                historyLimit = 10
                showToast("Adjusted to min 10")
            } else {
                historyLimit = value
            }
        } else {
            // If empty or non-numeric, reset to 100
            historyLimit = 100
            showToast("Reset to default 100")
        }
        tempLimitString = String(historyLimit)
    }

    @State private var newAppIdentifier: String = ""
    @ObservedObject var monitor = GlintMonitor.shared

    private var ignoredAppsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Blocked Applications")
                .font(.headline)
            Text("Glint will ignore all clipboard content copied from these apps (identified by Bundle ID).")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            HStack {
                TextField("com.apple.Music", text: $newAppIdentifier)
                    .textFieldStyle(.roundedBorder)
                
                Button(action: {
                    if !newAppIdentifier.isEmpty && !monitor.ignoredApps.contains(newAppIdentifier) {
                        monitor.ignoredApps.append(newAppIdentifier)
                        monitor.saveData()
                        newAppIdentifier = ""
                    }
                }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .help("Add Bundle ID manually")

                Button(action: {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    panel.canCreateDirectories = false
                    panel.canChooseFiles = true
                    panel.allowedContentTypes = [.application]
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    
                    if panel.runModal() == .OK, let url = panel.url {
                        if let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier {
                            if !monitor.ignoredApps.contains(bid) {
                                monitor.ignoredApps.append(bid)
                                monitor.saveData()
                            }
                        } else {
                            // Fallback if Bundle(url:) fails (some apps are weird)
                            let bid = url.deletingPathExtension().lastPathComponent
                            print("⚠️ Could not find Bundle ID, using name: \(bid)")
                        }
                    }
                }) {
                    Label("Choose App...", systemImage: "apps.ipad.landscape")
                }
                .buttonStyle(.bordered)
            }

            List {
                ForEach(monitor.ignoredApps, id: \.self) { bid in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(appName(from: bid))
                                .font(.system(size: 13, weight: .semibold))
                            Text(bid)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(action: {
                            monitor.ignoredApps.removeAll { $0 == bid }
                            monitor.saveData()
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1), lineWidth: 1))

            HStack {
                Button("Reset to Defaults") {
                    monitor.resetIgnoredApps()
                }
                .buttonStyle(.bordered)
                .foregroundColor(.accentColor)
                
                Spacer()
                Text("\(monitor.ignoredApps.count) apps blocked").font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
        .padding(24)
    }

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Glint Behavior")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 16) {
                    settingRow(title: "History Limit", subtitle: "Number of snippets to remember (Max 500).") {
                        HStack(spacing: 8) {
                            TextField("", text: $tempLimitString)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.center)
                                .frame(width: 60)
                                .onSubmit {
                                    validateLimit()
                                }
                        }
                    }
                    
                    Divider().opacity(0.3)

                    settingRow(title: "Keep History For", subtitle: "Automatically delete old snippets.") {
                        Picker("", selection: $cleanupPeriod) {
                            ForEach(GlintMonitor.CleanupPeriod.allCases, id: \.self) { period in
                                Text(period.rawValue).tag(period.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 100)
                        .onChange(of: cleanupPeriod) { _ in
                            GlintMonitor.shared.cleanupHistory()
                        }
                    }
                    
                    Divider().opacity(0.3)
                    
                    settingRow(title: "Launch at Login", subtitle: "Start Glint when you log in.") {
                        Toggle("", isOn: Binding(
                            get: { launchAtLogin },
                            set: { newValue in
                                do {
                                    if newValue { try SMAppService.mainApp.register() }
                                    else { try SMAppService.mainApp.unregister() }
                                    launchAtLogin = newValue
                                } catch { print(error) }
                            }
                        )).toggleStyle(.switch).labelsHidden()
                    }
                }
                .padding(16)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06), lineWidth: 1))

                Text("Sensory Feedback")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 16) {
                    settingRow(title: "Haptic Feedback", subtitle: "Physical trackpad click on actions.") {
                        Toggle("", isOn: $enableHaptics).toggleStyle(.switch).labelsHidden()
                    }
                    
                    Divider().opacity(0.3)
                    
                    settingRow(title: "Sound Effects", subtitle: "Subtle audio on copy and paste.") {
                        Toggle("", isOn: $enableSounds).toggleStyle(.switch).labelsHidden()
                    }
                }
                .padding(16)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06), lineWidth: 1))
                
                Spacer()
            }
            .padding(24)
        }
    }

    private func settingRow<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
            content()
        }
    }

    private func appName(from bid: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            let name = FileManager.default.displayName(atPath: url.path)
            return name.replacingOccurrences(of: ".app", with: "")
        }
        // Fallback to a cleaner version of the bundle ID if app not found
        return bid.components(separatedBy: ".").last?.capitalized ?? bid
    }

    private var shortcutsTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Global Shortcut")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 16) {
                Text("Record a custom global shortcut to show Glint from anywhere.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 24) {
                    ShortcutRecorder()
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("To change:")
                            .font(.system(size: 11, weight: .bold))
                        Text("Click the field and press your new keys.")
                            .font(.system(size: 11))
                        Text("Modifier keys (⌘, ⌥, ⇧, ⌃) are required.")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06), lineWidth: 1))
                
                Text("Tip: A combination like Option + Space or Command + Shift + V works best.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.8))
            }
            
            Spacer()
        }
        .padding(24)
    }

    private func shortcutStep(n: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n).").font(.system(size: 12, weight: .bold)).foregroundColor(.accentColor).frame(width: 18, alignment: .leading)
            Text(text).font(.system(size: 12)).foregroundColor(.primary.opacity(0.8))
        }
    }
}

struct ShortcutRecorder: View {
    @AppStorage("hotkeyCode") private var hotkeyCode = 49
    @AppStorage("hotkeyModifiers") private var hotkeyModifiers = Int(optionKey)
    @AppStorage("hotkeyText") private var hotkeyText = "Space"
    @State private var isRecording = false
    
    var body: some View {
        Button(action: { isRecording.toggle() }) {
            HStack {
                Text(isRecording ? "Press keys..." : currentShortcutText)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(isRecording ? .accentColor : .primary)
                if isRecording {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(isRecording ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.05))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isRecording ? Color.accentColor : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .background(ShortcutManager(isRecording: $isRecording, keyCode: $hotkeyCode, modifiers: $hotkeyModifiers, shortcutText: $hotkeyText))
    }
    
    private var currentShortcutText: String {
        var result = ""
        let mods = UInt32(hotkeyModifiers)
        if mods & UInt32(controlKey) != 0 { result += "⌃" }
        if mods & UInt32(optionKey) != 0 { result += "⌥" }
        if mods & UInt32(shiftKey) != 0 { result += "⇧" }
        if mods & UInt32(cmdKey) != 0 { result += "⌘" }
        
        result += hotkeyText
        return result
    }
}

struct ShortcutManager: NSViewRepresentable {
    @Binding var isRecording: Bool
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    @Binding var shortcutText: String
    
    func makeNSView(context: Context) -> NSView {
        let view = ShortcutNSView()
        view.onEvent = { event in
            if isRecording {
                let newModifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
                if !newModifiers.isEmpty || event.keyCode == 49 || event.keyCode == 36 {
                    self.keyCode = Int(event.keyCode)
                    self.modifiers = Int(translateModifiers(event.modifierFlags))
                    
                    // Capture display text
                    if event.keyCode == 49 { self.shortcutText = "Space" }
                    else if event.keyCode == 36 { self.shortcutText = "Return" }
                    else if event.keyCode == 48 { self.shortcutText = "Tab" }
                    else { self.shortcutText = event.charactersIgnoringModifiers?.uppercased() ?? "???" }
                    
                    self.isRecording = false
                    NotificationCenter.default.post(name: NSNotification.Name("HotKeyChanged"), object: nil)
                }
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
    
    private func translateModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbonModifiers: UInt32 = 0
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        return carbonModifiers
    }
}

class ShortcutNSView: NSView {
    var onEvent: ((NSEvent) -> Void)?
    
    override var acceptsFirstResponder: Bool { true }
    
    override func keyDown(with event: NSEvent) {
        onEvent?(event)
    }
}

// MARK: - Window Accessor for Settings Elevation
struct WindowAccessor: NSViewRepresentable {
    var onWindowCaptured: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowHelperView()
        view.onWindowCaptured = onWindowCaptured
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

class WindowHelperView: NSView {
    var onWindowCaptured: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = window {
            onWindowCaptured?(window)
        }
    }
}
