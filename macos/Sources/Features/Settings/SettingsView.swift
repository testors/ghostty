import SwiftUI

/// A page in the settings sidebar.
enum SettingsPage: Hashable {
    case category(SettingsCategory)
    case all
}

/// The root of the settings window: a sidebar of pages with search.
struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var selection: SettingsPage? = .category(.general)
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(SettingsCategory.visible) { category in
                        NavigationLink(value: SettingsPage.category(category)) {
                            Label(category.title, systemImage: category.systemImage)
                        }
                    }
                }

                Section {
                    NavigationLink(value: SettingsPage.all) {
                        Label("All Settings", systemImage: "list.bullet")
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search settings")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
            .safeAreaInset(edge: .bottom) {
                ConfigFileFooter(store: store)
            }
        } detail: {
            VStack(spacing: 0) {
                SettingsBanners(store: store)
                detail
            }
            .frame(minWidth: 520, minHeight: 400)
        }
        .environment(\.settingsNavigate) { page in
            search = ""
            selection = page
        }
    }

    @ViewBuilder
    private var detail: some View {
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            SearchResultsView(store: store, query: query)
        } else {
            switch selection ?? .category(.general) {
            case .all:
                AllSettingsView(store: store)
            case .category(.keybindings):
                KeybindingsView(store: store)
            case .category(let category):
                CategoryPageView(store: store, category: category)
                    .id(category)
            }
        }
    }
}

/// The main config file and a button to open it, below the sidebar.
struct ConfigFileFooter: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text((store.primaryPath as NSString).lastPathComponent)
                .font(.system(.caption, design: .monospaced))
            Text((store.primaryPath as NSString).deletingLastPathComponent.replacingOccurrences(
                of: NSHomeDirectory(), with: "~"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack {
                Button("Open in Editor") { store.openInEditor() }
                    .controlSize(.small)
                Button {
                    store.revealInFinder()
                } label: {
                    Image(systemName: "folder")
                }
                .controlSize(.small)
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}

/// Errors from the last change and problems in the configuration files.
struct SettingsBanners: View {
    @ObservedObject var store: SettingsStore
    @State private var showDiagnostics = false

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.lastError {
                banner(systemImage: "xmark.octagon.fill", tint: .red) {
                    Text(error).textSelection(.enabled)
                } trailing: {
                    Button("Dismiss") { store.lastError = nil }
                }
            }

            let diagnostics = store.snapshot.diagnostics
            if !diagnostics.isEmpty {
                banner(systemImage: "exclamationmark.triangle.fill", tint: .orange) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("^[\(diagnostics.count) problem](inflect: true) in the configuration")
                        if showDiagnostics {
                            ForEach(diagnostics, id: \.self) { message in
                                Text(message)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                } trailing: {
                    Button(showDiagnostics ? "Hide" : "Show") { showDiagnostics.toggle() }
                    Button("Open in Editor") { store.openInEditor() }
                }
            }
        }
    }

    private func banner<Content: View, Trailing: View>(
        systemImage: String,
        tint: Color,
        @ViewBuilder content: () -> Content,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            content().frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(tint.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// A page of settings for one category: curated sections, then every
/// other key of the category under "Advanced".
struct CategoryPageView: View {
    @ObservedObject var store: SettingsStore
    let category: SettingsCategory
    @State private var showAdvanced = false

    var body: some View {
        let sections = SettingsLayout.sections(for: category)
        let listed = Set(sections.flatMap(\.keys)).union(SettingsLayout.customKeys(for: category))
        let advanced = store.settings(in: category).filter { !listed.contains($0.key) }

        Form {
            switch category {
            case .appearance:
                ThemeSection(store: store)
            case .font:
                FontSection(store: store)
            default:
                EmptyView()
            }

            ForEach(sections) { section in
                let settings = section.keys.compactMap { store.schema(for: $0) }
                if !settings.isEmpty {
                    Section(section.title) {
                        ForEach(settings) { setting in
                            SettingRow(store: store, setting: setting)
                        }
                    }
                }
            }

            if !advanced.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showAdvanced) {
                        ForEach(advanced) { setting in
                            SettingRow(store: store, setting: setting)
                        }
                    } label: {
                        Text("Advanced (\(advanced.count))")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(category.title)
        .onAppear {
            // Pages without curated sections show everything.
            if sections.isEmpty { showAdvanced = true }
        }
    }
}

/// Every setting, generated from the schema, with filters.
struct AllSettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all
        case modified

        var id: String { rawValue }
    }

    var body: some View {
        let modifiedCount = store.schema.filter { store.isModified($0.key) }.count
        let settings = store.schema.filter { setting in
            switch filter {
            case .all: return true
            case .modified: return store.isModified(setting.key)
            }
        }

        Form {
            Section {
                ForEach(settings) { setting in
                    SettingRow(store: store, setting: setting, showKey: true)
                }
            } header: {
                Picker("Show", selection: $filter) {
                    Text("All (\(store.schema.count))").tag(Filter.all)
                    Text("Modified (\(modifiedCount))").tag(Filter.modified)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .formStyle(.grouped)
        .navigationTitle("All Settings")
    }
}

/// Settings matching a search, grouped by page. Settings whose name
/// matches come before those that only match their documentation.
struct SearchResultsView: View {
    @ObservedObject var store: SettingsStore
    let query: String
    @Environment(\.settingsNavigate) private var navigate

    var body: some View {
        let matches = store.schema.filter { $0.matches(query) }
        let byName = matches.filter { $0.nameMatches(query) }
        let byDoc = matches.filter { !$0.nameMatches(query) }

        Form {
            if matches.isEmpty {
                Text("No settings match “\(query)”")
                    .foregroundStyle(.secondary)
            }

            ForEach(SettingsCategory.allCases) { category in
                let settings = byName.filter { $0.category == category }
                if !settings.isEmpty {
                    Section {
                        ForEach(settings) { setting in
                            SettingRow(store: store, setting: setting)
                        }
                    } header: {
                        HStack {
                            Text(category.title)
                            Spacer()
                            Button("Show Page") { navigate(.category(category)) }
                                .buttonStyle(.link)
                        }
                    }
                }
            }

            if !byDoc.isEmpty {
                Section("Mentioned in descriptions") {
                    ForEach(byDoc) { setting in
                        SettingRow(store: store, setting: setting, showKey: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Results for “\(query)”")
    }
}
