import AppKit
import SwiftUI

extension Color {
    /// A color from a "#rrggbb" string, or the fallback.
    init(hex: String, fallback: NSColor = .gray) {
        self.init(nsColor: NSColor(hex: hex) ?? fallback)
    }
}

/// The theme section at the top of the Appearance page: one theme, or a
/// light and a dark theme that follow the system appearance.
struct ThemeSection: View {
    @ObservedObject var store: SettingsStore
    @State private var picking: ThemeSlot?

    private var raw: String { store.value("theme") }

    var body: some View {
        let theme = raw.isEmpty ? nil : ThemeValue(raw)
        let paired = raw.contains("light:") || raw.contains("dark:")

        Section {
            Toggle("Match system appearance", isOn: Binding(
                get: { paired },
                set: { on in
                    guard let theme else { return }
                    if on {
                        store.set("theme", "light:\(theme.light),dark:\(theme.dark)")
                    } else {
                        // Keep the theme of the current appearance.
                        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        store.set("theme", dark ? theme.dark : theme.light)
                    }
                }
            ))
            .disabled(theme == nil)

            HStack(spacing: 12) {
                if paired, let theme {
                    ThemeSlotView(store: store, title: "Light", name: theme.light) { picking = .light }
                    ThemeSlotView(store: store, title: "Dark", name: theme.dark) { picking = .dark }
                } else {
                    ThemeSlotView(store: store, title: "Theme", name: theme?.light) { picking = .single }
                }
            }
            .padding(.vertical, 4)
        } header: {
            HStack {
                Text("Theme")
                Spacer()
                if store.isModified("theme") {
                    Button("Use Default") { store.reset("theme") }
                        .buttonStyle(.link)
                }
            }
        }
        .onAppear { store.loadThemes() }
        .sheet(item: $picking) { slot in
            ThemePickerSheet(store: store, slot: slot, current: raw)
        }
    }
}

/// Which theme the picker changes.
enum ThemeSlot: String, Identifiable {
    case single, light, dark
    var id: String { rawValue }
}

/// A theme with a small preview and a button to change it.
struct ThemeSlotView: View {
    @ObservedObject var store: SettingsStore
    let title: String
    let name: String?
    let change: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ThemeMiniPreview(theme: name.flatMap { store.theme(named: $0) })
                .frame(width: 104, height: 60)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(name ?? "Default")
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Change…", action: change)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
    }
}

/// A tiny drawing of a theme's colors.
struct ThemeMiniPreview: View {
    let theme: ThemeInfo?

    var body: some View {
        let bg = theme.map { Color(hex: $0.background) } ?? Color(hex: "#282c34")
        let palette = theme?.palette ?? []
        let fg = theme.map { Color(hex: $0.foreground) } ?? .white
        VStack(alignment: .leading, spacing: 5) {
            bars([(palette[safe: 2], 12), (fg, 40)])
            bars([(palette[safe: 1], 22), (palette[safe: 3], 18), (palette[safe: 4], 14)])
            bars([(palette[safe: 5], 30), (palette[safe: 6], 20)])
        }
        .padding(9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(bg))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
        .accessibilityHidden(true)
    }

    private func bars(_ items: [(Any?, CGFloat)]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                RoundedRectangle(cornerRadius: 2)
                    .fill(color(item.0))
                    .frame(width: item.1, height: 5)
            }
        }
    }

    private func color(_ value: Any?) -> Color {
        if let color = value as? Color { return color }
        if let hex = value as? String { return Color(hex: hex) }
        return .gray
    }
}

/// Browse themes with previews. Selecting a theme previews it in open
/// windows; Choose writes it, Cancel goes back.
struct ThemePickerSheet: View {
    @ObservedObject var store: SettingsStore
    let slot: ThemeSlot
    let current: String

    @Environment(\.dismiss) private var dismiss
    @State private var filter: Filter
    @State private var search = ""
    @State private var selected: String?
    @State private var livePreview = true

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", dark = "Dark", light = "Light"
        var id: String { rawValue }
    }

    init(store: SettingsStore, slot: ThemeSlot, current: String) {
        self.store = store
        self.slot = slot
        self.current = current

        // The selection is set here and not in onAppear: the grid scrolls
        // to it in its own onAppear, which runs before the sheet's.
        let theme = current.isEmpty ? nil : ThemeValue(current)
        switch slot {
        case .single:
            _filter = State(initialValue: .all)
            _selected = State(initialValue: theme?.light)
        case .light:
            _filter = State(initialValue: .light)
            _selected = State(initialValue: theme?.light)
        case .dark:
            _filter = State(initialValue: .dark)
            _selected = State(initialValue: theme?.dark)
        }
    }

    private var currentTheme: ThemeValue? {
        current.isEmpty ? nil : ThemeValue(current)
    }

    private var title: String {
        switch slot {
        case .single: return "Choose Theme"
        case .light: return "Choose Light Theme"
        case .dark: return "Choose Dark Theme"
        }
    }

    /// The `theme` value written for the selection.
    private func value(for name: String) -> String {
        let theme = currentTheme ?? ThemeValue(light: name, dark: name)
        switch slot {
        case .single: return name
        case .light: return "light:\(name),dark:\(theme.dark)"
        case .dark: return "light:\(theme.light),dark:\(name)"
        }
    }

    private var themes: [ThemeInfo] {
        store.themes.filter { theme in
            switch filter {
            case .all: break
            case .dark: if !theme.dark { return false }
            case .light: if theme.dark { return false }
            }
            return search.isEmpty || theme.name.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text("Open windows preview the selection until you choose")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                TextField("", text: $search, prompt: Text("Search themes"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
            .padding(16)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    if store.themes.isEmpty {
                        ProgressView().padding(40)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 14) {
                            ForEach(themes) { theme in
                                ThemeCard(theme: theme, selected: theme.name == selected) {
                                    select(theme.name)
                                }
                                .id(theme.name)
                            }
                        }
                        .padding(16)
                    }
                }
                .onAppear { scrollToSelection(proxy) }
                .onChange(of: store.themes.count) { _ in scrollToSelection(proxy) }
            }

            Divider()

            HStack(spacing: 12) {
                Toggle("Live preview", isOn: $livePreview)
                    .onChange(of: livePreview) { on in
                        if on, let selected {
                            store.preview("theme", value(for: selected))
                        } else {
                            store.endPreview()
                        }
                    }
                if let selected {
                    Text("theme = \(value(for: selected))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Cancel") {
                    store.endPreview()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Choose") {
                    if let selected { store.set("theme", value(for: selected)) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
            }
            .padding(16)
        }
        .frame(width: 760, height: 600)
        .onAppear { store.loadThemes() }
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        guard let selected, !store.themes.isEmpty else { return }
        DispatchQueue.main.async { proxy.scrollTo(selected, anchor: .center) }
    }

    private func select(_ name: String) {
        selected = name
        if livePreview { store.preview("theme", value(for: name)) }
    }
}

/// A theme in the picker grid.
struct ThemeCard: View {
    let theme: ThemeInfo
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text("~").foregroundColor(Color(hex: theme.palette[safe: 2] ?? theme.foreground))
                        Text("❯").foregroundColor(Color(hex: theme.palette[safe: 4] ?? theme.foreground))
                        Text("ls -la").foregroundColor(Color(hex: theme.foreground))
                    }
                    HStack(spacing: 6) {
                        Text("err").foregroundColor(Color(hex: theme.palette[safe: 1] ?? theme.foreground))
                        Text("warn").foregroundColor(Color(hex: theme.palette[safe: 3] ?? theme.foreground))
                        Text("info").foregroundColor(Color(hex: theme.palette[safe: 5] ?? theme.foreground))
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 3) {
                        ForEach(1..<7, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(hex: theme.palette[safe: i] ?? theme.foreground))
                                .frame(height: 7)
                        }
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .padding(9)
                .frame(height: 86)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: theme.background)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 3 : 1)
                )

                Text(theme.name)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
