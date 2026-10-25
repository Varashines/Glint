import SwiftUI

enum ContentFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case text = "Text"
    case url = "URLs"
    case image = "Photos"
    case file = "Files"

    var id: String { self.rawValue }

    var systemImage: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .text: return "doc.text"
        case .url: return "link"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    var contentType: ContentType? {
        switch self {
        case .all: return nil
        case .text: return .text
        case .url: return .url
        case .image: return .image
        case .file: return .file
        }
    }

    /// Shown in tooltips; ⇧⌘1–5 switch filters.
    var shortcutHint: String {
        guard let index = Self.allCases.firstIndex(of: self) else { return "" }
        return " (⇧⌘\(index + 1))"
    }
}

// Global Badge Helpers — native SF Symbols, adaptive system colors (dark-mode safe).
func typeBadge(for type: ContentType) -> some View {
    Label(badgeLabel(for: type), systemImage: badgeSystemImage(for: type))
        .font(.system(size: 9, weight: .bold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(typeBadgeColor(for: type).opacity(0.16))
        .foregroundColor(typeBadgeColor(for: type))
        .cornerRadius(4)
}

func badgeLabel(for type: ContentType) -> String {
    switch type {
    case .text: return "TEXT"
    case .url: return "URL"
    case .image: return "PHOTO"
    case .file: return "FILE"
    }
}

func badgeSystemImage(for type: ContentType) -> String {
    switch type {
    case .text: return "doc.text"
    case .url: return "link"
    case .image: return "photo"
    case .file: return "doc"
    }
}

func typeBadgeColor(for type: ContentType) -> Color {
    switch type {
    case .text: return .blue
    case .url: return .green
    case .file: return .orange
    case .image: return .purple
    }
}

/// Single-line, bounded preview for rows (avoids laying out 100KB strings).
func rowPreviewText(_ text: String) -> String {
    let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        .first.map(String.init) ?? ""
    if firstLine.count > 200 {
        return String(firstLine.prefix(200)) + "…"
    }
    return firstLine.isEmpty ? text.prefix(200).description : firstLine
}

private let previewCountFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f
}()

/// "5m ago • 1,234 characters" style meta line for the preview header.
func previewMetaText(_ item: ClipboardItem) -> String {
    let detail: String
    switch item.type {
    case .text, .url:
        let n = item.text.count
        let num = previewCountFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
        detail = n == 1 ? "1 character" : "\(num) characters"
    case .image:
        detail = "PNG image"
    case .file:
        let n = item.fileURLs?.count ?? 0
        detail = n == 1 ? "1 file" : "\(n) files"
    }
    return "\(item.relativeTime) • \(detail)"
}

struct ContentView: View {
    @EnvironmentObject var monitor: GlintMonitor
    @State private var searchText: String = ""
    @FocusState private var isSearchFocused: Bool
    @State private var selectedFilter: ContentFilter = .all
    @State private var hoveredFilter: ContentFilter? = nil
    @Namespace private var filterAnimation

    // Dropdown App Filter State
    @State private var selectedApps: Set<String> = []
    @State private var showAppFilterPopover: Bool = false
    @State private var appSearchText: String = ""

    // Bumped whenever filters change so the list jumps back to the top.
    @State private var scrollResetToken = 0

    // Preview selection lives in the shared monitor — single source of truth for
    // the list window and the attached preview window. Main window never resizes.
    private var selectedID: UUID? { monitor.selectedPreviewID }
    // Keyboard navigation index into filteredItems.
    @State private var keyboardIndex: Int? = nil

    private func matchesSearch(_ item: ClipboardItem) -> Bool {
        guard !searchText.isEmpty else { return true }
        return item.text.localizedCaseInsensitiveContains(searchText)
            || (item.sourceApp?.localizedCaseInsensitiveContains(searchText) ?? false)
            || item.type.rawValue.localizedCaseInsensitiveContains(searchText)
    }

    private func matchesAppFilter(_ item: ClipboardItem) -> Bool {
        selectedApps.isEmpty || selectedApps.contains(item.sourceApp ?? "Unknown")
    }

    var filteredItems: [ClipboardItem] {
        monitor.items.filter { item in
            (selectedFilter.contentType == nil || item.type == selectedFilter.contentType)
                && matchesAppFilter(item)
                && matchesSearch(item)
        }
    }

    /// True whenever the visible list is narrower than the full history.
    var isFiltering: Bool {
        selectedFilter != .all || !selectedApps.isEmpty || !searchText.isEmpty
    }

    /// Live binding to the monitor's item — never a stale struct copy.
    var selectedPreviewItem: ClipboardItem? { monitor.selectedPreviewItem }

    var availableApps: [String] {
        var apps = Set(monitor.items.compactMap { $0.sourceApp })
        // Items with no recorded source are displayed as "Unknown"; let them be filtered too.
        if monitor.items.contains(where: { $0.sourceApp == nil }) { apps.insert("Unknown") }
        apps.formUnion(selectedApps)
        return apps.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// App names narrowed by the popover's own search field.
    private var filteredApps: [String] {
        guard !appSearchText.isEmpty else { return availableApps }
        return availableApps.filter { $0.localizedCaseInsensitiveContains(appSearchText) }
    }

    private func appIcon(for appName: String) -> NSImage? {
        guard appName != "Unknown",
            let item = monitor.items.first(where: { ($0.sourceApp ?? "Unknown") == appName })
        else { return nil }
        return item.appIcon
    }

    /// Count shown on a type chip: respects the active search and app filters so the
    /// number always matches what clicking the chip will actually show.
    private func itemCount(for filter: ContentFilter) -> Int {
        monitor.items.filter { item in
            (filter.contentType == nil || item.type == filter.contentType)
                && matchesAppFilter(item)
                && matchesSearch(item)
        }.count
    }

    /// Count shown next to an app in the filter popover.
    private func appCount(for appName: String) -> Int {
        monitor.items.filter { item in
            (item.sourceApp ?? "Unknown") == appName
                && (selectedFilter.contentType == nil || item.type == selectedFilter.contentType)
                && matchesSearch(item)
        }.count
    }

    private func selectFilter(_ filter: ContentFilter) {
        guard selectedFilter != filter else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            selectedFilter = filter
        }
        keyboardIndex = filteredItems.isEmpty ? nil : 0
        scrollResetToken += 1
    }

    private func clearAllFilters() {
        withAnimation(.easeOut(duration: 0.18)) {
            searchText = ""
            selectedFilter = .all
            selectedApps.removeAll()
        }
        keyboardIndex = filteredItems.isEmpty ? nil : 0
        scrollResetToken += 1
    }

    private func togglePreview(for item: ClipboardItem) {
        if monitor.selectedPreviewID == item.id {
            closePreview()
        } else {
            openPreview(item)
        }
    }

    // Showing/hiding the attached preview window is owned by AppDelegate (fade +
    // slide on the preview window only). Main window layout never changes, so the
    // list can never stretch — these just flip shared state, instantly, no timers.
    private func openPreview(_ item: ClipboardItem) {
        if monitor.selectedPreviewID == item.id { return }
        // Do NOT touch keyboardIndex here: that drives the list's scroll-to-selection,
        // which made clicking the chevron jump/scroll the main list.
        monitor.selectedPreviewID = item.id
    }

    private func closePreview() {
        monitor.selectedPreviewID = nil
    }

    private func paste(_ item: ClipboardItem) {
        monitor.playSound()
        monitor.select(item)
    }

    private func clampKeyboardIndex() {
        guard !filteredItems.isEmpty else { keyboardIndex = nil; return }
        if let i = keyboardIndex {
            keyboardIndex = min(max(i, 0), filteredItems.count - 1)
        }
    }

    private func listRow(index: Int, item: ClipboardItem) -> some View {
        GlintRow(
            item: item,
            index: index,
            searchText: searchText,
            isSelected: selectedID == item.id,
            isKeyboardFocused: keyboardIndex == index,
            onPreviewToggle: { togglePreview(for: item) }
        )
        .id(item.id)
        .onTapGesture {
            keyboardIndex = index
            paste(item)
        }
    }

    private let listWidth: CGFloat = 550

    var body: some View {
        HStack(spacing: 0) {
            // Main clipboard list column
            VStack(spacing: 0) {
                searchHeader
                if filteredItems.isEmpty {
                    emptyState
                } else {
                    ZStack {
                        keyboardShortcuts
                        ScrollViewReader { proxy in
                            ScrollView(showsIndicators: true) {
                                LazyVStack(spacing: 8) {
                                    Color.clear.frame(height: 1).id("listTop")
                                    ForEach(Array(filteredItems.enumerated()), id: \.element.id) { pair in
                                        listRow(index: pair.offset, item: pair.element)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.top, 4)
                                .padding(.bottom, 12)
                            }
                            .scrollIndicators(.visible)
                            .onChange(of: keyboardIndex) { _, newValue in
                                // Instant follow (no smooth-scroll chase): stays responsive
                                // when holding ↑/↓, which smooth scrolling made feel laggy.
                                guard let i = newValue, filteredItems.indices.contains(i) else { return }
                                proxy.scrollTo(filteredItems[i].id, anchor: .center)
                            }
                            .onChange(of: scrollResetToken) { _, _ in
                                proxy.scrollTo("listTop", anchor: .top)
                            }
                        }
                    }
                }
                footer
            }
            .frame(width: listWidth)
        }
        // Fixed width, always. The preview lives in its own attached window, so this
        // layout never changes size — nothing here can stretch, ever.
        .frame(width: listWidth)
        .frame(minHeight: 400, idealHeight: 480)
        .background(filterShortcuts)
        .background(
            ZStack {
                VisualEffectView(material: .popover, blendingMode: .behindWindow)
                Color(NSColor.windowBackgroundColor).opacity(0.4)
            }
            .ignoresSafeArea()
        )
        .onAppear {
            isSearchFocused = true
            if keyboardIndex == nil && !filteredItems.isEmpty { keyboardIndex = 0 }
        }
        .onChange(of: filteredItems.count) { _, _ in clampKeyboardIndex() }
        .onChange(of: searchText) { _, _ in
            keyboardIndex = filteredItems.isEmpty ? nil : 0
            scrollResetToken += 1
        }
        .onChange(of: selectedApps) { _, _ in
            keyboardIndex = filteredItems.isEmpty ? nil : 0
            scrollResetToken += 1
        }
        .onExitCommand {
            // First Esc closes preview, second closes the panel.
            if selectedID != nil {
                closePreview()
            } else {
                NSApp.windows.first { $0 is GlintPanel }?.orderOut(nil)
            }
        }
        // Arrow-key navigation (bubbles from single-line search field for up/down).
        .onKeyPress(.upArrow) {
            clampKeyboardIndex()
            if let i = keyboardIndex, i > 0 {
                keyboardIndex = i - 1
            } else if !filteredItems.isEmpty {
                keyboardIndex = 0
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            clampKeyboardIndex()
            if let i = keyboardIndex, i < filteredItems.count - 1 {
                keyboardIndex = i + 1
            } else if !filteredItems.isEmpty {
                keyboardIndex = 0
            }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            // Open preview for the keyboard-selected row.
            let idx = keyboardIndex ?? 0
            if filteredItems.indices.contains(idx) {
                let item = filteredItems[idx]
                if selectedID != item.id {
                    openPreview(item)
                    return .handled
                }
            }
            return .ignored
        }
        .onKeyPress(.leftArrow) {
            // Collapse preview.
            if selectedID != nil {
                closePreview()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.return) {
            // If search is focused, onSubmit handles it; this covers list focus.
            let idx = keyboardIndex ?? 0
            if filteredItems.indices.contains(idx) {
                paste(filteredItems[idx])
                return .handled
            }
            return .ignored
        }
        .onKeyPress(phases: .down) { press in
            if press.key == KeyEquivalent("p") && press.modifiers.contains(.command) {
                let idx = keyboardIndex ?? 0
                if filteredItems.indices.contains(idx) {
                    monitor.togglePin(for: filteredItems[idx])
                    return .handled
                }
                return .ignored
            }
            if press.key == KeyEquivalent.delete && press.modifiers.contains(.command) {
                let idx = keyboardIndex ?? 0
                if filteredItems.indices.contains(idx) {
                    let item = filteredItems[idx]
                    if selectedID == item.id { closePreview() }
                    monitor.deleteItem(item)
                    clampKeyboardIndex()
                    return .handled
                }
                return .ignored
            }
            return .ignored
        }
    }

    private var searchHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField("Search clipboard history…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium))
                    .focused($isSearchFocused)
                    .onSubmit { pasteFirstMatch() }

                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                } else {
                    keyHintStrip
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(isSearchFocused ? 0.07 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        Color.accentColor.opacity(isSearchFocused ? 0.45 : 0.08), lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.15), value: isSearchFocused)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)

            filterBar
            if !selectedApps.isEmpty { activeAppFilters }
            Divider().opacity(0.12)
        }
    }

    private func pasteFirstMatch() {
        // ⏎ pastes the keyboard selection (or the top hit) — core keyboard flow.
        let idx = keyboardIndex ?? 0
        if filteredItems.indices.contains(idx) {
            paste(filteredItems[idx])
        } else if let first = filteredItems.first {
            paste(first)
        }
    }

    private var keyHintStrip: some View {
        HStack(spacing: 4) {
            keyHint("↑↓", help: "Navigate with arrow keys")
            keyHint("⏎", help: "Paste the selected clip")
            keyHint("→", help: "Open the preview panel")
        }
    }

    private func keyHint(_ label: String, help: String) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary.opacity(0.85))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .help(help)
    }

    // MARK: Filter bar

    private var filterBar: some View {
        HStack(spacing: 6) {
            ForEach(ContentFilter.allCases) { filter in
                filterChip(filter)
            }

            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(width: 1, height: 20)

            appFilterButton
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func filterChip(_ filter: ContentFilter) -> some View {
        let isActive = selectedFilter == filter
        let count = itemCount(for: filter)
        let isHovered = hoveredFilter == filter

        return Button(action: { selectFilter(filter) }) {
            HStack(spacing: 5) {
                Image(systemName: filter.systemImage)
                    .font(.system(size: 10, weight: .bold))

                Text(filter.rawValue)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text("\(count)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(isActive ? Color.white.opacity(0.95) : Color.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(
                            isActive
                                ? Color.white.opacity(0.22) : Color.primary.opacity(0.07))
                    )
            }
            .foregroundStyle(
                isActive ? Color.white : Color.primary.opacity(count == 0 ? 0.45 : 0.85)
            )
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(
                ZStack {
                    if isActive {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor)
                            .shadow(color: Color.accentColor.opacity(0.35), radius: 3, y: 1)
                            .matchedGeometryEffect(id: "activeFilterPill", in: filterAnimation)
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(isHovered ? 0.09 : 0.045))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        Color.primary.opacity(isActive ? 0 : (isHovered ? 0.16 : 0.08)),
                        lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel("\(filter.rawValue), \(count) items")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .help("Show \(filter.rawValue.lowercased()) clips\(filter.shortcutHint)")
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                if hovering {
                    hoveredFilter = filter
                } else if hoveredFilter == filter {
                    hoveredFilter = nil
                }
            }
        }
    }

    /// Chips for the active application filters, so the state is never invisible.
    private var activeAppFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("APPS")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary.opacity(0.8))

                ForEach(selectedApps.sorted(), id: \.self) { appName in
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { _ = selectedApps.remove(appName) }
                    } label: {
                        HStack(spacing: 4) {
                            if let icon = appIcon(for: appName) {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 12, height: 12)
                            }
                            Text(appName)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        .overlay(Capsule().stroke(Color.accentColor.opacity(0.25), lineWidth: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Remove \(appName) filter")
                }

                if selectedApps.count > 1 {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { selectedApps.removeAll() }
                    } label: {
                        Text("Clear all")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 8)
    }

    private var appFilterButton: some View {
        Button(action: { showAppFilterPopover.toggle() }) {
            ZStack {
                if selectedApps.count == 1,
                    let appName = selectedApps.first,
                    let icon = appIcon(for: appName)
                {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                } else if selectedApps.count > 1 {
                    HStack(spacing: 2) {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.system(size: 9, weight: .bold))
                        Text("\(selectedApps.count)")
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                    }
                } else {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 12, weight: .bold))
                }
            }
            .foregroundStyle(selectedApps.isEmpty ? Color.secondary : Color.accentColor)
            .frame(width: 38, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        selectedApps.isEmpty
                            ? Color.primary.opacity(0.045) : Color.accentColor.opacity(0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        selectedApps.isEmpty
                            ? Color.primary.opacity(0.08) : Color.accentColor.opacity(0.45),
                        lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(
            selectedApps.isEmpty
                ? "Filter by application"
                : "Filtering \(selectedApps.count) app\(selectedApps.count == 1 ? "" : "s") — click to change"
        )
        .popover(isPresented: $showAppFilterPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("FILTER BY APP")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !selectedApps.isEmpty {
                        Button("Clear") {
                            withAnimation(.easeOut(duration: 0.15)) { selectedApps.removeAll() }
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("Find an app…", text: $appSearchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selectedApps.removeAll() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.grid.2x2.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                        Text("All Applications")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("\(monitor.items.count)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Image(systemName: selectedApps.isEmpty ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 11))
                            .foregroundStyle(
                                selectedApps.isEmpty
                                    ? Color.accentColor : Color.secondary.opacity(0.3))
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider().opacity(0.1)

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredApps, id: \.self) { appName in
                            appFilterRow(appName)
                        }
                        if filteredApps.isEmpty {
                            Text("No matching apps")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        }
                    }
                }
                .frame(maxHeight: 230)
            }
            .padding(12)
            .frame(width: 240)
            .onAppear { appSearchText = "" }
        }
    }

    private func appFilterRow(_ appName: String) -> some View {
        let isSelected = selectedApps.contains(appName)
        let count = appCount(for: appName)

        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                if isSelected {
                    _ = selectedApps.remove(appName)
                } else {
                    _ = selectedApps.insert(appName)
                }
            }
        } label: {
            HStack(spacing: 8) {
                if let icon = appIcon(for: appName) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "app.dashed")
                        .frame(width: 16, height: 16)
                        .foregroundStyle(.secondary)
                }
                Text(appName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(
                        isSelected ? Color.accentColor : Color.secondary.opacity(0.3))
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help("\(count) clip\(count == 1 ? "" : "s") from \(appName)")
    }

// MARK: - Attached preview window views

/// Card shown in the separate preview panel docked beside the main list.
/// Reads live from the monitor (pin state etc. never goes stale); copy feedback
/// is per-item via `.id(item.id)` at the use site.
struct PreviewPanelCard: View {
    let item: ClipboardItem
    @EnvironmentObject var monitor: GlintMonitor
    @State private var isCopied: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header Info
            HStack(spacing: 12) {
                if let icon = item.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.sourceApp ?? "Unknown Application")
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(1)
                    Text(item.bundleID ?? "no bundle identifier")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Dismiss Panel Close Button
                Button(action: {
                    monitor.selectedPreviewID = nil
                    focusGlintMain()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundColor(.secondary.opacity(0.65))
                }
                .buttonStyle(.plain)
                .help("Close preview (esc)")
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            Text(previewMetaText(item))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .help("Copied \(item.timestamp.formatted(date: .abbreviated, time: .shortened))")

            Divider().opacity(0.1)

            // Preview Area
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch item.type {
                    case .text, .url:
                        if item.text.count > 20_000 {
                            Text(String(item.text.prefix(20_000)) + "\n… (truncated, full text pastes)")
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.03))
                                .cornerRadius(8)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.07), lineWidth: 1))
                        } else {
                            Text(item.text)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.03))
                                .cornerRadius(8)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.07), lineWidth: 1))
                        }

                    case .image:
                        PreviewImageView(item: item)

                    case .file:
                        if let urls = item.fileURLs {
                            ForEach(urls, id: \.self) { url in
                                HStack(spacing: 8) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                        .resizable()
                                        .frame(width: 22, height: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(url.lastPathComponent)
                                            .font(.system(size: 13, weight: .semibold))
                                        Text(url.path)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Button(action: {
                                        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
                                    }) {
                                        Image(systemName: "arrow.right.circle.fill")
                                            .font(.system(size: 15))
                                            .foregroundColor(.accentColor)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Reveal in Finder")
                                }
                                .padding(8)
                                .background(Color.primary.opacity(0.03))
                                .cornerRadius(6)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }

            Spacer()

            // Actions Footer
            Divider().opacity(0.1)

            HStack(spacing: 8) {
                Button(action: {
                    monitor.togglePin(for: item)
                    focusGlintMain()
                }) {
                    Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash.fill" : "pin.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary.opacity(0.8))
                        .padding(.vertical, 7)
                        .padding(.horizontal, 10)
                        .background(Color.primary.opacity(0.06))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help(item.isPinned ? "Unpin" : "Pin (⌘P)")

                Button(action: {
                    monitor.selectedPreviewID = nil
                    monitor.deleteItem(item)
                }) {
                    Label("Delete", systemImage: "trash.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.red.opacity(0.9))
                        .padding(.vertical, 7)
                        .padding(.horizontal, 10)
                        .background(Color.red.opacity(0.12))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help("Delete (⌘⌫)")

                Spacer()

                Button(action: {
                    monitor.playSound()
                    monitor.copyToClipboard(item, hideApp: false)
                    focusGlintMain()

                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                        isCopied = true
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                            isCopied = false
                        }
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark.circle.fill" : "doc.on.clipboard.fill")
                        Text(isCopied ? "Copied!" : "Copy")
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 11)
                    .background(isCopied ? Color.green : Color.accentColor)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help("Copy without dismissing (⏎ pastes and hides)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.primary.opacity(0.01))
        }
        .frame(width: GlintPreviewPanel.width)
        .background(Color.primary.opacity(0.015))
    }
}

/// Root view of the attached preview window. Content swaps live with selection;
/// showing/hiding (fade + slide) is owned by AppDelegate — no layout animation here.
struct PreviewHostView: View {
    @EnvironmentObject var monitor: GlintMonitor

    var body: some View {
        ZStack {
            VisualEffectView(material: .popover, blendingMode: .behindWindow)
            Color(NSColor.windowBackgroundColor).opacity(0.4)
            if let item = monitor.selectedPreviewItem {
                PreviewPanelCard(item: item)
                    .id(item.id)
            } else {
                Color.clear
            }
        }
        .ignoresSafeArea()
        .frame(width: GlintPreviewPanel.width)
        .frame(maxHeight: .infinity)
        .onExitCommand {
            // First Esc closes preview and hands focus back to the list.
            monitor.selectedPreviewID = nil
            focusGlintMain()
        }
        .onKeyPress(.leftArrow) {
            monitor.selectedPreviewID = nil
            focusGlintMain()
            return .handled
        }
        .onKeyPress(.return) {
            if let item = monitor.selectedPreviewItem {
                monitor.playSound()
                monitor.select(item)
                return .handled
            }
            return .ignored
        }
        // Navigation lives in the list: hand focus back and let the next press work there.
        .onKeyPress(.upArrow) { focusGlintMain(); return .handled }
        .onKeyPress(.downArrow) { focusGlintMain(); return .handled }
        .onKeyPress(.rightArrow) { focusGlintMain(); return .handled }
    }
}

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: emptyStateIcon)
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(Color.accentColor)
                .opacity(0.3)
            Text(emptyStateTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.85))
                .multilineTextAlignment(.center)
            if isFiltering {
                Text("Try a different search or clear the filters.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Show All Items") { clearAllFilters() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 2)
            } else if !monitor.isPaused {
                Text("Copy something and it will appear here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateIcon: String {
        if monitor.isPaused { return "zzz" }
        if !searchText.isEmpty { return "magnifyingglass" }
        switch selectedFilter {
        case .all: return "doc.on.clipboard"
        case .text: return "doc.text"
        case .url: return "link"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    private var emptyStateTitle: String {
        if monitor.isPaused { return "Monitoring paused" }
        if !searchText.isEmpty { return "No clips match “\(searchText)”" }
        if !selectedApps.isEmpty {
            let names = selectedApps.sorted()
            let label = names.count == 1 ? names[0] : "\(names.count) apps"
            let typePrefix = selectedFilter == .all ? "" : "\(selectedFilter.rawValue.lowercased()) "
            return "No \(typePrefix)clips from \(label)"
        }
        if selectedFilter != .all { return "No \(selectedFilter.rawValue.lowercased()) clips yet" }
        return "Nothing copied yet"
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.12)
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "tray.full.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(itemCountLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                    if isFiltering {
                        Text("FILTERED")
                            .font(.system(size: 8, weight: .black))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            .foregroundStyle(Color.accentColor)
                    }
                    if monitor.isPaused {
                        Text("PAUSED")
                            .font(.system(size: 8, weight: .black))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                            .foregroundStyle(Color.orange)
                    }
                }
                .foregroundStyle(.secondary)

                Spacer()

                HStack(spacing: 8) {
                    footerButton(
                        monitor.isPaused ? "play.fill" : "pause.fill",
                        help: monitor.isPaused ? "Resume monitoring" : "Pause monitoring",
                        color: monitor.isPaused ? .green : .orange
                    ) {
                        monitor.isPaused.toggle()
                        let message = monitor.isPaused ? "Monitoring Paused" : "Monitoring Resumed"
                        NotificationCenter.default.post(
                            name: NSNotification.Name("GlintShowHUD"), object: message)
                    }
                    footerButton("trash", help: "Clear history (unpinned items)", color: .red) {
                        monitor.clearHistory()
                    }
                    Rectangle()
                        .fill(Color.primary.opacity(0.1))
                        .frame(width: 1, height: 16)
                    footerButton("power", help: "Quit Glint", color: .secondary) {
                        NSApp.terminate(nil)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.02))
        }
    }

    private var itemCountLabel: String {
        isFiltering
            ? "\(filteredItems.count) of \(monitor.items.count) items"
            : "\(monitor.items.count) items"
    }

    private func footerButton(
        _ systemName: String, help: String, color: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(color.opacity(0.8))
        .help(help)
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

    /// ⇧⌘1–5 switch the type filter, even when the list is empty.
    private var filterShortcuts: some View {
        Group {
            ForEach(Array(ContentFilter.allCases.enumerated()), id: \.element.id) { index, filter in
                Button("") { selectFilter(filter) }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .shift])
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Loads the full-size preview off the main thread so opening the preview never
/// hitches on large screenshots, then crossfades in. Shows the fast thumbnail
/// instantly while the original decodes.
struct PreviewImageView: View {
    let item: ClipboardItem
    @State private var fullImage: NSImage? = nil
    @State private var failed = false

    var body: some View {
        Group {
            if let fullImage {
                Image(nsImage: fullImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .cornerRadius(8)
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                    .transition(.opacity)
            } else if let thumb = item.thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .cornerRadius(8)
                    .opacity(0.7)
            } else if failed {
                Text("Image preview unavailable")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .animation(.easeOut(duration: 0.18), value: fullImage != nil)
        .task(id: item.id) {
            // Thumbnail is cached/sync; the original can be multi-MB — decode in background.
            if fullImage != nil || failed { return }
            let originalName = item.originalImageName
            let thumbName = item.imageFileName
            let loaded: NSImage? = await Task.detached(priority: .userInitiated) {
                if let name = originalName,
                    let url = [GlintMonitor.shared.cacheFolder, GlintMonitor.shared.legacyCacheFolder]
                        .map({ $0.appendingPathComponent(name) })
                        .first(where: { FileManager.default.fileExists(atPath: $0.path) }),
                    let img = NSImage(contentsOf: url)
                {
                    return img
                }
                if let name = thumbName,
                    let url = [GlintMonitor.shared.cacheFolder, GlintMonitor.shared.legacyCacheFolder]
                        .map({ $0.appendingPathComponent(name) })
                        .first(where: { FileManager.default.fileExists(atPath: $0.path) }),
                    let img = NSImage(contentsOf: url)
                {
                    return img
                }
                return nil
            }.value
            if Task.isCancelled { return }
            if let loaded {
                // Prime the shared cache so rows/paste stay instant.
                if let name = (originalName ?? thumbName) as NSString? {
                    SharedCaches.thumbnails.setObject(loaded, forKey: name)
                }
                fullImage = loaded
            } else {
                failed = true
            }
        }
    }
}

struct GlintRow: View {
    let item: ClipboardItem
    let index: Int
    let searchText: String
    let isSelected: Bool
    var isKeyboardFocused: Bool = false
    let onPreviewToggle: () -> Void

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
                .focusable(false)
                .help(item.isPinned ? "Unpin" : "Pin (⌘P)")
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center) {
                    highlightedText(rowPreviewText(item.text), query: searchText)
                        .lineLimit(1)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary.opacity(0.9))

                    Spacer()

                    HStack(spacing: 8) {
                        if isHovering {
                            if item.type == .url, let url = URL(string: item.text) {
                                Button(action: { NSWorkspace.shared.open(url) }) {
                                    Image(systemName: "safari.fill")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.blue.opacity(0.85))
                                        .frame(width: 22, height: 22)
                                        .background(Color.blue.opacity(0.12))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .focusable(false)
                                .help("Open in browser")
                            }

                            Button(action: { monitor.deleteItem(item) }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.red.opacity(0.85))
                                    .frame(width: 22, height: 22)
                                    .background(Color.red.opacity(0.12))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .focusable(false)
                            .help("Delete")
                            .transition(.opacity.combined(with: .scale))
                        } else if index < 9 {
                            Text("⌘\(index + 1)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(isSelected ? .accentColor : (item.isPinned ? .accentColor.opacity(0.7) : .secondary.opacity(0.45)))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.primary.opacity(0.04))
                                .cornerRadius(4)
                        }

                        // Chevron toggles the attached preview (right = open, left = close)
                        Button(action: onPreviewToggle) {
                            Image(systemName: isSelected ? "chevron.left" : "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(isSelected ? .accentColor : .secondary.opacity(0.8))
                                .frame(width: 22, height: 22)
                                .background(isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .help(isSelected ? "Close preview" : "Open preview (→)")
                    }
                }

                HStack(spacing: 6) {
                    typeBadge(for: item.type)

                    Text(item.sourceApp ?? "Unknown")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Text("• \(item.relativeTime)")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.12)
                        : (isKeyboardFocused
                            ? Color.accentColor.opacity(0.06)
                            : (isHovering ? Color.primary.opacity(0.045) : Color.clear)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isSelected
                        ? Color.accentColor.opacity(0.35)
                        : (isKeyboardFocused
                            ? Color.accentColor.opacity(0.22)
                            : (item.isPinned ? Color.accentColor.opacity(0.16) : Color.clear)),
                    lineWidth: 1.2)
        )
        .overlay(alignment: .leading) {
            if isSelected || item.isPinned {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.accentColor.opacity(0.45))
                    .frame(width: 3, height: 26)
                    .padding(.leading, 3)
            }
        }
        // No scale/shadow animation on hover: scaling rows inside a LazyVStack
        // forces full-list relayout every frame and reads as jitter, not premium.
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .contentShape(Rectangle())
        .onHover { hovering in isHovering = hovering }
    }

    private func highlightedText(_ text: String, query: String) -> Text {
        guard !query.isEmpty else { return Text(text) }

        var attributed = AttributedString(text)
        let lowercasedText = text.lowercased()
        let lowercasedQuery = query.lowercased()

        var searchRange = lowercasedText.startIndex..<lowercasedText.endIndex
        while let range = lowercasedText.range(of: lowercasedQuery, range: searchRange) {
            if let start = AttributedString.Index(range.lowerBound, within: attributed),
               let end = AttributedString.Index(range.upperBound, within: attributed) {
                attributed[start..<end].backgroundColor = Color.accentColor.opacity(0.2)
                attributed[start..<end].foregroundColor = Color.accentColor
                attributed[start..<end].font = .system(size: 13, weight: .bold, design: .monospaced)
            }
            searchRange = range.upperBound..<lowercasedText.endIndex
        }
        return Text(attributed)
    }
}
