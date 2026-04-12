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
                        LazyVStack(spacing: 10) {
                            ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                                GlintRow(item: item, index: index)
                                    .onTapGesture { monitor.select(item) }
                            }
                        }
                        .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 12)
                    }
                    .scrollIndicators(.visible)
                }
            }
            footer
        }
        .frame(width: 600, height: 450)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow).ignoresSafeArea())
        .onAppear { isSearchFocused = true }
        .onExitCommand { NSApp.hide(nil) }
    }
    
    private var searchHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 15) {
                Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .semibold)).foregroundColor(.secondary)
                TextField("Search history...", text: $searchText).textFieldStyle(.plain).font(.system(size: 18, weight: .medium)).focused($isSearchFocused)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) { Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundColor(.secondary.opacity(0.6)) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 20)
            Divider().opacity(0.15)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "doc.on.clipboard").font(.system(size: 48, weight: .thin)).opacity(0.1)
            Text(searchText.isEmpty ? "No history yet" : "No matches found").font(.system(size: 14, weight: .medium)).foregroundColor(.secondary.opacity(0.5))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var footer: some View {
        HStack(spacing: 20) {
            Label("\(monitor.items.count) items", systemImage: "tray.full.fill").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary.opacity(0.6))
            Spacer()
            HStack(spacing: 16) {
                // RED TRASH ICON ONLY
                Button(action: { monitor.clearHistory() }) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundColor(.red.opacity(0.8))
                .help("Clear history (unpinned items)")

                Button(action: { NSApp.terminate(nil) }) { Image(systemName: "power").font(.system(size: 11, weight: .bold)) }.buttonStyle(.plain).foregroundColor(.secondary.opacity(0.8))
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12).background(Color.primary.opacity(0.02))
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
        HStack(spacing: 14) {
            // CREATIVE PIN PLACEMENT: Top-Left Corner of the Icon Area
            ZStack(alignment: .topLeading) {
                // Main Icon/Thumbnail Area
                ZStack(alignment: .bottomTrailing) {
                    if let thumb = item.thumbnail {
                        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8)).shadow(radius: 1)
                    } else if let icon = item.appIcon {
                        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).frame(width: 32, height: 32)
                    } else {
                        Image(systemName: item.type == .url ? "link" : "doc.text").font(.system(size: 18)).foregroundColor(.accentColor.opacity(0.6))
                    }
                    
                    if item.imageFileName != nil && item.fileURLs != nil {
                        Text("✨").font(.system(size: 8)).offset(x: 4, y: 4)
                    }
                }
                .frame(width: 44, height: 44)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(8)
                
                // THE CREATIVE PIN
                Button(action: { monitor.togglePin(for: item) }) {
                    ZStack {
                        // Background "Corner Fold" effect
                        if item.isPinned || isHovering {
                            Image(systemName: item.isPinned ? "pin.fill" : "pin")
                                .font(.system(size: 8, weight: .black))
                                .foregroundColor(item.isPinned ? .white : .primary.opacity(0.4))
                                .frame(width: 16, height: 16)
                                .background(item.isPinned ? Color.accentColor : Color.primary.opacity(0.1))
                                .clipShape(Circle())
                                .offset(x: -6, y: -6)
                                .shadow(color: .black.opacity(0.1), radius: 2)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(width: 44, height: 44)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.text).lineLimit(1).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundColor(.primary.opacity(0.9))
                    Spacer()
                    if index < 9 { 
                        Text("⌘\(index + 1)")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .foregroundColor(item.isPinned ? .accentColor : .secondary.opacity(0.3))
                    }
                }
                HStack(spacing: 8) {
                    badge(for: item.type)
                    Text(item.sourceApp ?? "Unknown").font(.system(size: 10, weight: .bold)).foregroundColor(.accentColor)
                    Text("• \(item.relativeTime)").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.6))
                }
            }
        }
        .padding(.all, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isHovering ? Color.primary.opacity(0.05) : Color.white.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(item.isPinned ? Color.accentColor.opacity(0.3) : (isHovering ? Color.accentColor.opacity(0.2) : Color.clear), lineWidth: item.isPinned ? 2 : 1)
        )
        .onHover { isHovering = $0 }
    }
    
    private func badge(for type: ContentType) -> some View {
        Text(type.rawValue).font(.system(size: 8, weight: .black)).padding(.horizontal, 4).padding(.vertical, 1)
            .background(badgeColor(for: type).opacity(0.15)).foregroundColor(badgeColor(for: type)).cornerRadius(3)
    }
    
    private func badgeColor(for type: ContentType) -> Color {
        switch type { case .text: return .blue; case .url: return .green; case .file: return .orange; case .image: return .purple }
    }
}
