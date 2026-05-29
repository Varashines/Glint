import SwiftUI

struct ContentView: View {
    @EnvironmentObject var monitor: GlintMonitor
    @State private var searchText: String = ""
    @FocusState private var isSearchFocused: Bool

    var filteredItems: [ClipboardItem] {
        if searchText.isEmpty { return monitor.items }
        return monitor.items.filter { item in
            item.text.localizedCaseInsensitiveContains(searchText) || (item.sourceApp?.localizedCaseInsensitiveContains(searchText) ?? false) || item.type.rawValue.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            if filteredItems.isEmpty {
                emptyState
            } else {
                ZStack {
                    keyboardShortcuts
                    ScrollView(showsIndicators: true) {
                        LazyVStack(spacing: 8) {
                            ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                                GlintRow(item: item, index: index)
                                    .onTapGesture { monitor.select(item) }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                        .padding(.bottom, 12)
                    }
                    .scrollIndicators(.visible)
                }
            }
            footer
        }
        .frame(width: 600, height: 450)
        .background(
            ZStack {
                VisualEffectView(material: .popover, blendingMode: .behindWindow)
                Color(NSColor.windowBackgroundColor).opacity(0.4)
            }
            .ignoresSafeArea()
        )
        .onAppear { isSearchFocused = true }
        .onExitCommand { 
            NSApp.windows.first { $0 is GlintPanel }?.orderOut(nil)
        }
    }
    
    private var searchHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.7))
                
                TextField("Search history...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .medium))
                    .focused($isSearchFocused)
                
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.primary.opacity(0.03))
            .cornerRadius(10)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)
            
            Divider().opacity(0.1)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: monitor.isPaused ? "pause.circle" : "doc.on.clipboard")
                .font(.system(size: 40, weight: .thin))
                .opacity(0.15)
            Text(monitor.isPaused ? "Monitoring Paused" : (searchText.isEmpty ? "No history yet" : "No matches found"))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary.opacity(0.6))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var footer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.1)
            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    Label("\(monitor.items.count) items", systemImage: "tray.full.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.5))
                    
                    if monitor.isPaused {
                        Text("• PAUSED")
                            .font(.system(size: 9, weight: .black))
                            .foregroundColor(.orange.opacity(0.8))
                    }
                }
                
                Spacer()
                
                HStack(spacing: 14) {
                    Button(action: { 
                        monitor.isPaused.toggle()
                        let message = monitor.isPaused ? "Monitoring Paused" : "Monitoring Resumed"
                        NotificationCenter.default.post(name: NSNotification.Name("GlintShowHUD"), object: message)
                    }) {
                        Image(systemName: monitor.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(monitor.isPaused ? .green.opacity(0.7) : .orange.opacity(0.7))
                    .help(monitor.isPaused ? "Resume monitoring" : "Pause monitoring")

                    Button(action: { monitor.clearHistory() }) {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red.opacity(0.7))
                    .help("Clear history (unpinned items)")

                    Button(action: { NSApp.terminate(nil) }) {
                        Image(systemName: "power")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary.opacity(0.6))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.02))
        }
    }
private var keyboardShortcuts: some View {
    Group {
        ForEach(0..<min(filteredItems.count, 9), id: \.self) { i in
            Button("") { 
                monitor.playSound()
                monitor.select(filteredItems[i]) 
            }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
        }
    }
    .opacity(0).allowsHitTesting(false)
}
}

struct GlintRow: View {
    let item: ClipboardItem
    let index: Int
    @EnvironmentObject var monitor: GlintMonitor
    @State private var isHovering: Bool = false
    
    var body: some View {
        HStack(spacing: 12) {
            // Icon Area
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .bottomTrailing) {
                    if let thumb = item.thumbnail {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                    } else if let icon = item.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: item.type == .url ? "link" : "doc.text")
                            .font(.system(size: 16))
                            .foregroundColor(.accentColor.opacity(0.7))
                    }
                }
                .frame(width: 40, height: 40)
                .background(Color.primary.opacity(0.04))
                .cornerRadius(8)
                
                // Pin Button
                Button(action: { monitor.togglePin(for: item) }) {
                    if item.isPinned || isHovering {
                        Image(systemName: item.isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(item.isPinned ? .white : .primary.opacity(0.4))
                            .frame(width: 14, height: 14)
                            .background(item.isPinned ? Color.accentColor : Color.primary.opacity(0.1))
                            .clipShape(Circle())
                            .offset(x: -5, y: -5)
                            .shadow(color: .black.opacity(0.1), radius: 1)
                    }
                }
                .buttonStyle(.plain)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center) {
                    Text(item.text)
                        .lineLimit(1)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary.opacity(0.85))
                    
                    Spacer()
                    
                    HStack(spacing: 8) {
                        if isHovering {
                            if item.type == .url, let url = URL(string: item.text) {
                                Button(action: { NSWorkspace.shared.open(url) }) {
                                    Image(systemName: "safari.fill")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.blue.opacity(0.7))
                                        .frame(width: 20, height: 20)
                                        .background(Color.blue.opacity(0.1))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                            }
                            
                            Button(action: { monitor.deleteItem(item) }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.red.opacity(0.7))
                                    .frame(width: 20, height: 20)
                                    .background(Color.red.opacity(0.1))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .transition(.opacity.combined(with: .scale))
                        } else if index < 9 {
                            Text("⌘\(index + 1)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(item.isPinned ? .accentColor.opacity(0.6) : .secondary.opacity(0.3))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.primary.opacity(0.03))
                                .cornerRadius(4)
                        }
                    }
                }
                
                HStack(spacing: 6) {
                    badge(for: item.type)
                    
                    Text(item.sourceApp ?? "Unknown")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.accentColor.opacity(0.8))
                    Text("• \(item.relativeTime)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.5))
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovering ? Color(NSColor.controlBackgroundColor).opacity(0.8) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(item.isPinned ? Color.accentColor.opacity(0.2) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering } }
    }
    
    private func badge(for type: ContentType) -> some View {
        Text(type.rawValue).font(.system(size: 8, weight: .black)).padding(.horizontal, 4).padding(.vertical, 1)
            .background(badgeColor(for: type).opacity(0.15)).foregroundColor(badgeColor(for: type)).cornerRadius(3)
    }
    
    private func badgeColor(for type: ContentType) -> Color {
        switch type { case .text: return .blue; case .url: return .green; case .file: return .orange; case .image: return .purple }
    }
}
